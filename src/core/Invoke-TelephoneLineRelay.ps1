# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$JobRoot = '',
    [switch]$Collector,
    [string]$StateRoot = '',
    [string]$LeadKey = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TelephoneLine.Common.ps1')

if ($Collector) {
    if ([string]::IsNullOrWhiteSpace($StateRoot) -or [string]::IsNullOrWhiteSpace($LeadKey)) {
        throw 'Collector requires StateRoot and LeadKey.'
    }
    Invoke-TelephoneLeadCollectorCore -StateRoot $StateRoot -LeadKey $LeadKey
    exit 0
}
if ([string]::IsNullOrWhiteSpace($JobRoot)) { throw 'JobRoot is required.' }

$paths = Get-TelephoneJobPaths -JobRoot $JobRoot
$dispatchRead = Read-TelephoneJson -Path $paths.dispatch -SchemaName 'dispatch'
$dispatch = $dispatchRead.value
$null = Write-TelephoneLifecycleStatus -Paths $paths -Phase 'execution' -Idle $false

while (-not [IO.File]::Exists($paths.receipt)) {
    $null = Sync-TelephoneCommandOwnerCompletion -Paths $paths
    if (-not [IO.File]::Exists($paths.receipt)) {
        Start-Sleep -Milliseconds 200
    }
}
if ([IO.File]::Exists($paths.delivery)) {
    $existingDelivery = (Read-TelephoneJson -Path $paths.delivery).value
    $expectedDelivery = [ordered]@{ protocol_version = 'telephone-line-delivery-v1' }
    if ([string]$existingDelivery.protocol_version -cne [string]$expectedDelivery.protocol_version) {
        throw 'Telephone delivery protocol drifted.'
    }
    $null = Write-TelephoneLifecycleStatus -Paths $paths -Phase 'delivered' -Idle $false
    $null = Invoke-TelephoneControlPlaneLifecycleWake -Dispatch $dispatch -JobRoot $JobRoot -Reason 'delivery-already-present'
    exit 0
}
if ([IO.File]::Exists($paths.relay_error)) {
    $existingRelayError = (Read-TelephoneJson -Path $paths.relay_error).value
    if ($existingRelayError.retrying -eq $false) {
        $null = Invoke-TelephoneControlPlaneLifecycleWake -Dispatch $dispatch -JobRoot $JobRoot -Reason 'relay-error-already-present'
        exit 1
    }
}

$receiptRead = Read-TelephoneJson -Path $paths.receipt -SchemaName 'receipt'
$receipt = Assert-TelephoneReceiptBound -ReceiptRead $receiptRead -DispatchRead $dispatchRead
$receiptIdentity = $receiptRead.identity
$leadBinding = Read-TelephoneLeadBinding -Lead $dispatch.lead
$leadSessionId = [string]$leadBinding.session_id
$nestedBinding = $null
if ($dispatch.Contains('nested_target') -and $null -ne $dispatch.nested_target) {
    $nestedBinding = Read-TelephoneLeadBinding -Lead $dispatch.nested_target
    if ([string]$nestedBinding.session_id -ceq $leadSessionId) {
        throw 'Nested target session must differ from the owning Lead session.'
    }
}

function Test-TelephoneRelayCrashAfter {
    param([Parameter(Mandatory = $true)][string]$Point)
    if ([string]$env:TELEPHONE_TEST_RELAY_CRASH_AFTER -ceq $Point) { exit 99 }
}

function Complete-TelephoneNestedTargetHop {
    $nestedWake = New-TelephoneWakeIdentity -LineJobId ([string]$dispatch.line_job_id) -ReceiptIdentity $receiptIdentity -LeadSessionId ([string]$nestedBinding.session_id) -Kind nested
    $nestedRunId = [string]$nestedWake.wake_run_id
    $nestedText = @"
# Telephone-line nested target callback

The external route produced a durable receipt. This nested callback is for the declared wireless smoke/reviewer/test target only. It does not judge project content, correctness, or acceptance. The owning Lead remains the frozen outer callback destination.

- line_job_id: $([string]$dispatch.line_job_id)
- nested_session_id: $([string]$nestedBinding.session_id)
- owner_session_id: $leadSessionId
- receipt: $([string]$receiptIdentity.path)
- receipt_sha256: $([string]$receiptIdentity.sha256)
- transport_complete: $([bool]$receipt.transport_complete)

Publish an official completed, failed, or interrupted terminal. Acknowledgment is not completion.
"@
    if (-not [IO.File]::Exists($paths.nested_wake_prompt)) {
        try { $null = Write-TelephoneTextCreateNew -Path $paths.nested_wake_prompt -Text $nestedText } catch [IO.IOException] { }
    }
    $nestedPromptIdentity = Get-TelephoneFileIdentity -Path $paths.nested_wake_prompt
    if (-not [IO.File]::Exists($paths.nested_wake_intent)) {
        $nestedIntent = [ordered]@{
            protocol_version = 'telephone-line-wake-intent-v1'
            line_job_id = [string]$dispatch.line_job_id
            lead_session_id = [string]$nestedBinding.session_id
            kind = 'nested'
            wake_run_id = $nestedRunId
            wake_key = [string]$nestedWake.wake_key
            receipt = $receiptIdentity
            wake_prompt = $nestedPromptIdentity
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        try { $null = Write-TelephoneJsonCreateNew -Path $paths.nested_wake_intent -Value $nestedIntent } catch [IO.IOException] { }
    }
    $frozenNestedIntent = (Read-TelephoneJson -Path $paths.nested_wake_intent).value
    if ([string]$frozenNestedIntent.wake_run_id -cne $nestedRunId -or [string]$frozenNestedIntent.lead_session_id -cne [string]$nestedBinding.session_id) {
        throw 'Frozen nested wake identity does not match this receipt.'
    }

    $nestedAttemptCreated = $false
    if (-not [IO.File]::Exists($paths.nested_wake_attempt)) {
        $nestedAttempt = [ordered]@{
            protocol_version = 'telephone-line-wake-attempt-v1'
            line_job_id = [string]$dispatch.line_job_id
            lead_session_id = [string]$nestedBinding.session_id
            kind = 'nested'
            wake_run_id = $nestedRunId
            wake_key = [string]$nestedWake.wake_key
            receipt = $receiptIdentity
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        try {
            $null = Write-TelephoneJsonCreateNew -Path $paths.nested_wake_attempt -Value $nestedAttempt
            $nestedAttemptCreated = $true
        } catch [IO.IOException] { }
    }

    $nestedLaunch = $null
    $nestedExtra = @($nestedBinding.launcher.arguments)
    $lineJobId = [string]$dispatch.line_job_id
    if ($nestedAttemptCreated) {
        $nestedLaunch = Invoke-TelephoneFrozenLeadLauncher -LauncherPath ([string]$nestedBinding.launcher.path) -ExtraArguments $nestedExtra -Worktree ([string]$nestedBinding.worktree) -PromptFile ([string]$paths.nested_wake_prompt) -SessionId ([string]$nestedBinding.session_id) -RunId $nestedRunId
        Test-TelephoneRelayCrashAfter -Point 'nested_send'
        $savedNested = Save-TelephoneNamedLaunchResult -Path $paths.nested_wake_launch_result -Launch $nestedLaunch -RunId $nestedRunId -WakeKey ([string]$nestedWake.wake_key) -LineJobId $lineJobId
        if ($null -ne $savedNested) { $nestedLaunch = $savedNested }
    } else {
        $nestedLaunch = Invoke-TelephoneNamedWakeAttach -LaunchResultPath $paths.nested_wake_launch_result -LauncherPath ([string]$nestedBinding.launcher.path) -ExtraArguments $nestedExtra -Worktree ([string]$nestedBinding.worktree) -PromptFile ([string]$paths.nested_wake_prompt) -SessionId ([string]$nestedBinding.session_id) -RunId $nestedRunId -WakeKey ([string]$nestedWake.wake_key) -LineJobId $lineJobId
    }
    $null = Wait-TelephoneLeadWakeAcknowledged -RunRoot ([string]$nestedLaunch.run_root) -ExpectedSessionId ([string]$nestedBinding.session_id) -ExpectedRunId $nestedRunId
    Test-TelephoneRelayCrashAfter -Point 'nested_ack'
    $official = Wait-TelephoneLeadOfficialTerminal -RunRoot ([string]$nestedLaunch.run_root) -ExpectedSessionId ([string]$nestedBinding.session_id)
    $nestedTerminal = [ordered]@{
        protocol_version = 'telephone-line-nested-terminal-v1'
        line_job_id = [string]$dispatch.line_job_id
        session_id = [string]$nestedBinding.session_id
        owner_session_id = $leadSessionId
        wake_run_id = $nestedRunId
        wake_key = [string]$nestedWake.wake_key
        lead_run_root = [string]$nestedLaunch.run_root
        state = [string]$official.state
        receipt = $receiptIdentity
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        automatic_rerun = $false
        replacement_started = $false
    }
    try { $null = Write-TelephoneJsonCreateNew -Path $paths.nested_terminal -Value $nestedTerminal } catch [IO.IOException] { }
    $written = (Read-TelephoneJson -Path $paths.nested_terminal).value
    if ([string]$written.session_id -cne [string]$nestedBinding.session_id) {
        throw 'Nested terminal belongs to another session.'
    }
    if ([string]$written.state -cnotin @('completed', 'failed', 'interrupted')) {
        throw 'Nested terminal is not official.'
    }
    Test-TelephoneRelayCrashAfter -Point 'nested_terminal'
}

if ($null -ne $nestedBinding) {
    $null = Write-TelephoneLifecycleStatus -Paths $paths -Phase 'nested_target' -Idle $false
    if (-not [IO.File]::Exists($paths.nested_terminal)) {
        try {
            Complete-TelephoneNestedTargetHop
        } catch {
            $nestedError = [ordered]@{
                protocol_version = 'telephone-line-relay-error-v1'
                line_job_id = [string]$dispatch.line_job_id
                dispatch = $dispatchRead.identity
                receipt = $receiptIdentity
                lead_session_id = [string]$nestedBinding.session_id
                kind = 'nested'
                retrying = $false
                error_code = 'LEAD_WAKE_AMBIGUOUS'
                error_message = Get-TelephonePublicErrorMessage -ErrorCode 'LEAD_WAKE_AMBIGUOUS'
                recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            }
            try { $null = Write-TelephoneJsonCreateNew -Path $paths.relay_error -Value $nestedError } catch [IO.IOException] { }
            $null = Invoke-TelephoneControlPlaneLifecycleWake -Dispatch $dispatch -JobRoot $JobRoot -Reason 'nested-relay-error'
            exit 1
        }
    } else {
        $existingNested = (Read-TelephoneJson -Path $paths.nested_terminal).value
        if ([string]$existingNested.session_id -cne [string]$nestedBinding.session_id) {
            throw 'Nested terminal belongs to another session.'
        }
        if ([string]$existingNested.state -cnotin @('completed', 'failed', 'interrupted')) {
            throw 'Nested terminal is not official.'
        }
    }
    $null = Write-TelephoneLifecycleStatus -Paths $paths -Phase 'owner_acceptance' -Idle $false
}

Test-TelephoneRelayCrashAfter -Point 'owner_send'

$stateRoot = Get-TelephoneStateRootFromJobRoot -JobRoot $JobRoot
$relayScript = Join-Path $PSScriptRoot 'Invoke-TelephoneLineRelay.ps1'
try {
    $enqueued = Add-TelephoneMailboxItem -StateRoot $stateRoot -DispatchRead $dispatchRead -ReceiptRead $receiptRead -JobPaths $paths
} catch {
    $errorCode = 'BATCH_CONTRACT_INVALID'
    $relayError = [ordered]@{
        protocol_version = 'telephone-line-relay-error-v1'
        line_job_id = [string]$dispatch.line_job_id
        dispatch = $dispatchRead.identity
        receipt = $receiptIdentity
        lead_session_id = $leadSessionId
        retrying = $false
        error_code = $errorCode
        error_message = Get-TelephonePublicErrorMessage -ErrorCode $errorCode
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try { $null = Write-TelephoneJsonCreateNew -Path $paths.relay_error -Value $relayError } catch [IO.IOException] { }
    $null = Invoke-TelephoneControlPlaneLifecycleWake -Dispatch $dispatch -JobRoot $JobRoot -Reason 'batch-contract-relay-error'
    exit 1
}

if ([bool]$enqueued.counted -eq $false) {
    $implicitFailClosed = $false
    try {
        $implicitFailClosed = ([bool]$enqueued.batch.implicit -eq $true -and [int]$enqueued.batch.n -eq 1)
    } catch { $implicitFailClosed = $false }
    if ($implicitFailClosed) {
        $implicitJob = [ordered]@{
            paths = $paths
            dispatch = $dispatch
            lead = $leadBinding
        }
        try {
            $implicitKey = [string](Get-TelephoneLeadCanonicalIdentity -Lead $leadBinding).identity_sha256
            $implicitMailbox = Get-TelephoneLeadMailboxPaths -StateRoot $stateRoot -LeadKey $implicitKey
            Invoke-TelephoneSingleJobWake -Job $implicitJob -ReceiptRead $receiptRead -MailboxPaths $implicitMailbox
        } catch { }
        if ([IO.File]::Exists($paths.delivery)) {
            $null = Write-TelephoneLifecycleStatus -Paths $paths -Phase 'delivered' -Idle $false
            $null = Invoke-TelephoneControlPlaneLifecycleWake -Dispatch $dispatch -JobRoot $JobRoot -Reason 'implicit-delivery-published'
            exit 0
        }
    }
    $errorCode = 'BATCH_CONTRACT_INVALID'
    if ([string]$enqueued.classification -ceq 'start_ambiguous') { $errorCode = 'COMMAND_START_AMBIGUOUS_NO_RERUN' }
    $relayError = [ordered]@{
        protocol_version = 'telephone-line-relay-error-v1'
        line_job_id = [string]$dispatch.line_job_id
        dispatch = $dispatchRead.identity
        receipt = $receiptIdentity
        lead_session_id = $leadSessionId
        retrying = $false
        error_code = $errorCode
        error_message = Get-TelephonePublicErrorMessage -ErrorCode $errorCode
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try { $null = Write-TelephoneJsonCreateNew -Path $paths.relay_error -Value $relayError } catch [IO.IOException] { }
    $null = Invoke-TelephoneControlPlaneLifecycleWake -Dispatch $dispatch -JobRoot $JobRoot -Reason 'uncounted-relay-error'
    exit 1
}

$leadKey = [string]$enqueued.lead_key
try {
    $null = Ensure-TelephoneLeadCollector -StateRoot $stateRoot -LeadKey $leadKey -RelayScript $relayScript
} catch { }

$delivered = Wait-TelephoneJobDelivery -JobPaths $paths -StateRoot $stateRoot -LeadKey $leadKey -RelayScript $relayScript
if ($delivered) {
    $null = Write-TelephoneLifecycleStatus -Paths $paths -Phase 'delivered' -Idle $false
    $null = Invoke-TelephoneControlPlaneLifecycleWake -Dispatch $dispatch -JobRoot $JobRoot -Reason 'delivery-published'
    exit 0
}
$null = Invoke-TelephoneControlPlaneLifecycleWake -Dispatch $dispatch -JobRoot $JobRoot -Reason 'callback-terminal-without-delivery'
exit 1

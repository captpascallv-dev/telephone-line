# SPDX-License-Identifier: MPL-2.0
# Focused extra-owner admission oracle. Reuses the existing FAKE-SOURCE recovery
# fixture construction. Invokes the exported Register-DirectCursorPartialSession.ps1.
# Not the 55-test or 42-assertion suites.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TestRoot,
    [Parameter(Mandatory = $true)][string]$ObservationPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'tests\adapters\AdapterTest.Common.ps1')
. (Join-Path $repoRoot 'src\adapters\direct-cursor\DirectCursor.Common.ps1')
$assertions = 0
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
$outsideRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('TelephoneLineDirectCursorExtraOwner-' + [Guid]::NewGuid().ToString('N'))
$workspace = Join-Path $outsideRoot 'admit-workspace'
$powerShellPath = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$registerEntry = Join-Path $repoRoot 'src\adapters\direct-cursor\Register-DirectCursorPartialSession.ps1'
$wrapper = Join-Path $repoRoot 'src\adapters\direct-cursor\invoke_cursor_agent.ps1'
$observations = [ordered]@{
    protocol_version = 'telephone-line-direct-cursor-extra-owner-admission-observations-v1'
    fixture_label = 'FAKE-SOURCE-NOT-FOR-SWS'
    exported_entrypoint = $registerEntry
    existing_55_not_rerun = $true
    correction1_42_not_rerun = $true
    cases = [Collections.Generic.List[object]]::new()
}

function Add-Observation {
    param([string]$Name, [object]$Value)
    $observations.cases.Add([ordered]@{ name = $Name; detail = $Value })
}

function Get-StateMutation {
    param([string]$StateRoot, [string]$SessionId, [string]$ReceiptPath, [byte[]]$OriginalReceipt)
    $admissionPath = Get-DirectCursorPartialAdmissionPath -StateRoot $StateRoot -NativeSessionId $SessionId
    $registryPath = Get-DirectCursorSessionRegistryPath -StateRoot $StateRoot
    $bindingPath = Join-Path $StateRoot ('sessions\' + $SessionId + '\binding.json')
    $afterReceipt = [IO.File]::ReadAllBytes($ReceiptPath)
    return [ordered]@{
        admission_exists = [IO.File]::Exists($admissionPath)
        admission_path = $admissionPath
        registry_exists = [IO.File]::Exists($registryPath)
        binding_exists = [IO.File]::Exists($bindingPath)
        receipt_mutated = (@(Compare-Object $OriginalReceipt $afterReceipt).Count -ne 0)
    }
}

try {
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $promptPath = Join-Path $testRoot 'prompt.txt'
    [IO.File]::WriteAllText($promptPath, 'DIRECT-CURSOR-RECOVERY-PROMPT', [Text.UTF8Encoding]::new($false))
    $utf8 = [Text.UTF8Encoding]::new($false)
    $oldSession = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
    $jobId = 'ffffffff-ffff-4fff-8fff-ffffffffffff'
    $ownerStart = [DateTimeOffset]::Parse('2020-01-01T00:00:00Z')
    $createdMs = [int64]($ownerStart.ToUnixTimeMilliseconds() + 5000)
    $updatedMs = [int64]($createdMs + 60000)
    $receiptEnd = $ownerStart.AddMinutes(5)
    $deadOwnerPid = 1
    $deadOwnerTicks = [int64]$ownerStart.UtcDateTime.Ticks
    $deadExtraTicks = [int64]$ownerStart.AddSeconds(2).UtcDateTime.Ticks

    $transcriptDir = Join-Path $testRoot ('transcripts\dddddddd-dddd-4ddd-8ddd-dddddddddddd')
    [IO.Directory]::CreateDirectory($transcriptDir) | Out-Null
    $sharedTranscript = Join-Path $transcriptDir 'shared.jsonl'
    $transcriptText = (@(
        '{"role":"user","message":{"content":[{"type":"text","text":"FAKE-SOURCE-NOT-FOR-SWS prompt"}]}}',
        '{"role":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}'
    ) -join "`n") + "`n"
    [IO.File]::WriteAllText($sharedTranscript, $transcriptText, $utf8)
    $promptIdentity = Get-DirectFileIdentity -Path $promptPath

    function New-FocusedSessionFiles {
        param([string]$SessionId)
        $tDir = Join-Path $testRoot ('transcripts\' + $SessionId)
        [IO.Directory]::CreateDirectory($tDir) | Out-Null
        $tPath = Join-Path $tDir ($SessionId + '.jsonl')
        [IO.File]::Copy($sharedTranscript, $tPath, $true)
        $mDir = Join-Path $testRoot ('meta\' + $SessionId)
        [IO.Directory]::CreateDirectory($mDir) | Out-Null
        $mPath = Join-Path $mDir 'meta.json'
        $meta = [ordered]@{
            schemaVersion = 1
            createdAtMs = $createdMs
            updatedAtMs = $updatedMs
            hasConversation = $true
            cwd = $workspace
        }
        [IO.File]::WriteAllText($mPath, (($meta | ConvertTo-Json -Compress) + "`n"), $utf8)
        return [ordered]@{ transcript = $tPath; meta = $mPath }
    }

    $requestPath = Join-Path $testRoot 'fake-request.json'
    $request = [ordered]@{
        protocol_version = 'telephone-line-direct-cursor-request-v1'
        job_id = $jobId
        workspace = $workspace
        prompt = $promptIdentity
        mode = 'ReadOnly'
        model = 'cursor-grok-4.6-xhigh'
        expected_account = ''
        expected_subscription = ''
        resume_session_id = ''
        allowed_write_paths = @()
        allow_write = $false
        allow_fast = $false
        timeout_seconds = 0
        max_output_bytes = 65536
        session_root = (Join-Path $testRoot 'cursor-sessions')
        wrapper = @{ path = $wrapper; bytes = 1; sha256 = ('0' * 64) }
        cursor_agent_root = ''
    }
    $null = Write-DirectJsonCreateNew -Path $requestPath -Value $request
    $requestIdentity = Get-DirectFileIdentity -Path $requestPath
    $receiptPath = Join-Path $testRoot 'fake-receipt.json'
    $receiptFake = [ordered]@{
        protocol_version = 'telephone-line-direct-cursor-receipt-v1'
        job_id = $jobId
        request = $requestIdentity
        transport_complete = $false
        transport_error = Get-DirectPublicError -ErrorCode 'ADAPTER_TRANSPORT_FAILED'
        cursor_success = $false
        native_session_id = ''
        cursor_result = [ordered]@{
            success = $false
            failure_code = 'adapter_transport_failure'
            failure_stage = 'cursor_execution'
            session_id = ''
        }
        stdout = $null
        stderr = $null
        owner = $null
        automatic_rerun = $false
        replacement_started = $false
        completed_at_utc = $receiptEnd.ToString('o')
    }
    $null = Write-DirectJsonCreateNew -Path $receiptPath -Value $receiptFake
    $oldBindingPath = Join-Path $testRoot 'fake-old-binding.json'
    $null = Write-DirectJsonCreateNew -Path $oldBindingPath -Value ([ordered]@{
        protocol_version = 'telephone-line-direct-cursor-binding-v1'
        native_session_id = $oldSession
        latest_job_id = [Guid]::NewGuid().ToString('D')
        workspace = $workspace
        mode = 'ReadOnly'
        allowed_write_paths = @()
        created_at_utc = $ownerStart.ToString('o')
    })
    $ownerPath = Join-Path $testRoot 'fake-dead-owner.json'
    $null = Write-DirectJsonCreateNew -Path $ownerPath -Value ([ordered]@{
        protocol_version = 'telephone-line-direct-cursor-owner-v1'
        pid = $deadOwnerPid
        start_time_utc_ticks = $deadOwnerTicks
        started_at_utc = $ownerStart.ToString('o')
    })
    $executionPath = Join-Path $testRoot 'fake-actual-execution.json'
    $null = Write-DirectJsonCreateNew -Path $executionPath -Value ([ordered]@{
        fixture_label = 'FAKE-SOURCE-NOT-FOR-SWS'
        job = $jobId
        model = 'cursor-grok-4.6-xhigh'
    })
    $originalReceiptBytes = [IO.File]::ReadAllBytes($receiptPath)

    function New-ExpectedEvidence {
        param(
            [string]$Path,
            [string]$TranscriptPath,
            [string]$MetaPath,
            [object[]]$DeadOwners,
            [object[]]$RecheckOwners
        )
        $doc = [ordered]@{
            fixture_label = 'FAKE-SOURCE-NOT-FOR-SWS'
            request = Get-DirectFileIdentity -Path $requestPath
            receipt = Get-DirectFileIdentity -Path $receiptPath
            transcript = Get-DirectFileIdentity -Path $TranscriptPath
            meta = Get-DirectFileIdentity -Path $MetaPath
            prompt = Get-DirectFileIdentity -Path $promptPath
            actual_execution = Get-DirectFileIdentity -Path $executionPath
            old_binding = Get-DirectFileIdentity -Path $oldBindingPath
        }
        if ($null -ne $DeadOwners) { $doc.dead_owners = @($DeadOwners) }
        if ($null -ne $RecheckOwners) { $doc.activation_recheck_owners = @($RecheckOwners) }
        $null = Write-DirectJsonCreateNew -Path $Path -Value $doc
        return $doc
    }

    $deadExtras = @(
        [ordered]@{ role = 'failed_job_owner'; pid = $deadOwnerPid; start_time_utc_ticks = $deadOwnerTicks }
        [ordered]@{ role = 'command_owner_observation'; pid = $deadOwnerPid; start_time_utc_ticks = $deadExtraTicks }
        [ordered]@{ role = 'cursor_node_observation'; pid = $deadOwnerPid; start_time_utc_ticks = $deadExtraTicks }
    )

    $positiveSession = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
    $positiveFiles = New-FocusedSessionFiles -SessionId $positiveSession
    $positiveExpected = Join-Path $testRoot 'expected-both-dead.json'
    $null = New-ExpectedEvidence -Path $positiveExpected -TranscriptPath $positiveFiles.transcript -MetaPath $positiveFiles.meta -DeadOwners $deadExtras -RecheckOwners $deadExtras
    $positiveRoot = Join-Path $testRoot 'admit-both-dead'
    $positive = Invoke-AdapterEntrypoint -Entrypoint $registerEntry -Arguments @(
        '-StateRoot', $positiveRoot,
        '-FailedRequestPath', $requestPath,
        '-FailedReceiptPath', $receiptPath,
        '-NativeTranscriptPath', $positiveFiles.transcript,
        '-NativeMetaPath', $positiveFiles.meta,
        '-ObservedSessionId', $positiveSession,
        '-OldBindingPath', $oldBindingPath,
        '-FailedOwnerPath', $ownerPath,
        '-ActualExecutionPath', $executionPath,
        '-ExpectedEvidencePath', $positiveExpected,
        '-FixtureLabel', 'FAKE-SOURCE-NOT-FOR-SWS'
    )
    Assert-AdapterTest ($positive.exit_code -eq 0) ("Positive extra-owner admission failed: " + $positive.stderr + ' ' + $positive.stdout)
    Assert-AdapterTest ([string](Get-DirectNoteValue -Object $positive.value -Name 'status') -ceq 'provisional') 'Positive extra-owner admission was not provisional.'
    Assert-AdapterTest ([bool](Get-DirectNoteValue -Object $positive.value -Name 'accepted_binding_written') -eq $false) 'Positive extra-owner admission wrote an accepted binding.'
    Assert-AdapterTest ([bool](Get-DirectNoteValue -Object $positive.value -Name 'receipt_fabricated') -eq $false) 'Positive extra-owner admission fabricated a receipt.'
    Assert-AdapterTest ([int](Get-DirectNoteValue -Object $positive.value -Name 'continuation_remaining') -eq 1) 'Positive extra-owner admission did not authorize one continuation.'
    $positiveMutation = Get-StateMutation -StateRoot $positiveRoot -SessionId $positiveSession -ReceiptPath $receiptPath -OriginalReceipt $originalReceiptBytes
    Assert-AdapterTest ([bool]$positiveMutation.admission_exists) 'Positive extra-owner admission did not write admission.json.'
    Assert-AdapterTest (-not [bool]$positiveMutation.binding_exists) 'Positive extra-owner admission created an ordinary accepted binding.json.'
    Assert-AdapterTest (-not [bool]$positiveMutation.receipt_mutated) 'Positive extra-owner admission mutated the original failed receipt.'
    $expectedDoc = (Get-Content -Raw -LiteralPath $positiveExpected | ConvertFrom-Json -AsHashtable)
    Assert-AdapterTest (@($expectedDoc.dead_owners).Count -ge 1) 'Positive expected evidence missing nonempty dead_owners.'
    Assert-AdapterTest (@($expectedDoc.activation_recheck_owners).Count -ge 1) 'Positive expected evidence missing nonempty activation_recheck_owners.'
    Add-Observation -Name 'extra_owner_both_nonempty_dead_positive' -Value ([ordered]@{
        exit_code = $positive.exit_code
        status = [string](Get-DirectNoteValue -Object $positive.value -Name 'status')
        continuation_remaining = [int](Get-DirectNoteValue -Object $positive.value -Name 'continuation_remaining')
        accepted_binding_written = [bool](Get-DirectNoteValue -Object $positive.value -Name 'accepted_binding_written')
        dead_owners_count = @($expectedDoc.dead_owners).Count
        activation_recheck_owners_count = @($expectedDoc.activation_recheck_owners).Count
        admission_exists = [bool]$positiveMutation.admission_exists
        binding_exists = [bool]$positiveMutation.binding_exists
        receipt_mutated = [bool]$positiveMutation.receipt_mutated
        stderr = [string]$positive.stderr
        exported_entrypoint = $registerEntry
    })

    $live = Start-Process -FilePath $powerShellPath -ArgumentList @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 90') -PassThru -WindowStyle Hidden
    try {
        $liveExtra = @(
            [ordered]@{ role = 'failed_job_owner'; pid = $deadOwnerPid; start_time_utc_ticks = $deadOwnerTicks }
            [ordered]@{
                role = 'command_owner_observation'
                pid = [int]$live.Id
                start_time_utc_ticks = [int64]$live.StartTime.ToUniversalTime().Ticks
            }
        )
        $liveSession = 'aabbccdd-dddd-4ddd-8ddd-dddddddddddd'
        $liveFiles = New-FocusedSessionFiles -SessionId $liveSession
        $liveExpected = Join-Path $testRoot 'expected-live-extra.json'
        $null = New-ExpectedEvidence -Path $liveExpected -TranscriptPath $liveFiles.transcript -MetaPath $liveFiles.meta -DeadOwners $liveExtra -RecheckOwners $liveExtra
        $liveRoot = Join-Path $testRoot 'admit-live-extra'
        [IO.Directory]::CreateDirectory($liveRoot) | Out-Null
        $liveAdmit = Invoke-AdapterEntrypoint -Entrypoint $registerEntry -Arguments @(
            '-StateRoot', $liveRoot,
            '-FailedRequestPath', $requestPath,
            '-FailedReceiptPath', $receiptPath,
            '-NativeTranscriptPath', $liveFiles.transcript,
            '-NativeMetaPath', $liveFiles.meta,
            '-ObservedSessionId', $liveSession,
            '-OldBindingPath', $oldBindingPath,
            '-FailedOwnerPath', $ownerPath,
            '-ActualExecutionPath', $executionPath,
            '-ExpectedEvidencePath', $liveExpected,
            '-FixtureLabel', 'FAKE-SOURCE-NOT-FOR-SWS'
        )
        Assert-AdapterTest ($liveAdmit.exit_code -ne 0) 'Live extra owner was admitted.'
        Assert-AdapterTest ([string]$liveAdmit.stderr -match 'Competing owner is still alive') 'Live extra owner was not refused as a competing owner.'
        Assert-AdapterTest ([string]$liveAdmit.stderr -notmatch 'Cannot overwrite variable PID') 'Live extra-owner path still assigned the automatic PID variable.'
        $liveMutation = Get-StateMutation -StateRoot $liveRoot -SessionId $liveSession -ReceiptPath $receiptPath -OriginalReceipt $originalReceiptBytes
        Assert-AdapterTest (-not [bool]$liveMutation.admission_exists) 'Live extra-owner refusal wrote admission.json.'
        Assert-AdapterTest (-not [bool]$liveMutation.registry_exists) 'Live extra-owner refusal wrote the session registry.'
        Assert-AdapterTest (-not [bool]$liveMutation.binding_exists) 'Live extra-owner refusal wrote binding.json.'
        Assert-AdapterTest (-not [bool]$liveMutation.receipt_mutated) 'Live extra-owner refusal mutated the original failed receipt.'
        Add-Observation -Name 'extra_owner_live_refusal_no_mutation' -Value ([ordered]@{
            exit_code = $liveAdmit.exit_code
            stderr = [string]$liveAdmit.stderr
            live_extra_pid = [int]$live.Id
            admission_exists = [bool]$liveMutation.admission_exists
            registry_exists = [bool]$liveMutation.registry_exists
            binding_exists = [bool]$liveMutation.binding_exists
            receipt_mutated = [bool]$liveMutation.receipt_mutated
            failed_owner_was_dead = $true
            both_arrays_nonempty = $true
        })

        $fallbackSession = 'bbccddee-dddd-4ddd-8ddd-dddddddddddd'
        $fallbackFiles = New-FocusedSessionFiles -SessionId $fallbackSession
        $fallbackExpected = Join-Path $testRoot 'expected-recheck-only-live.json'
        $null = New-ExpectedEvidence -Path $fallbackExpected -TranscriptPath $fallbackFiles.transcript -MetaPath $fallbackFiles.meta -DeadOwners $null -RecheckOwners $liveExtra
        $fallbackRoot = Join-Path $testRoot 'admit-recheck-only-live'
        [IO.Directory]::CreateDirectory($fallbackRoot) | Out-Null
        $fallbackAdmit = Invoke-AdapterEntrypoint -Entrypoint $registerEntry -Arguments @(
            '-StateRoot', $fallbackRoot,
            '-FailedRequestPath', $requestPath,
            '-FailedReceiptPath', $receiptPath,
            '-NativeTranscriptPath', $fallbackFiles.transcript,
            '-NativeMetaPath', $fallbackFiles.meta,
            '-ObservedSessionId', $fallbackSession,
            '-OldBindingPath', $oldBindingPath,
            '-FailedOwnerPath', $ownerPath,
            '-ActualExecutionPath', $executionPath,
            '-ExpectedEvidencePath', $fallbackExpected,
            '-FixtureLabel', 'FAKE-SOURCE-NOT-FOR-SWS'
        )
        Assert-AdapterTest ($fallbackAdmit.exit_code -ne 0) 'Live activation_recheck_owners extra was admitted.'
        Assert-AdapterTest ([string]$fallbackAdmit.stderr -match 'Competing owner is still alive') 'activation_recheck_owners live extra was not refused as a competing owner.'
        $fallbackMutation = Get-StateMutation -StateRoot $fallbackRoot -SessionId $fallbackSession -ReceiptPath $receiptPath -OriginalReceipt $originalReceiptBytes
        Assert-AdapterTest (-not [bool]$fallbackMutation.admission_exists) 'activation_recheck_owners refusal wrote admission.json.'
        Assert-AdapterTest (-not [bool]$fallbackMutation.receipt_mutated) 'activation_recheck_owners refusal mutated the original failed receipt.'
        Add-Observation -Name 'activation_recheck_owners_fallback_live_refusal' -Value ([ordered]@{
            exit_code = $fallbackAdmit.exit_code
            stderr = [string]$fallbackAdmit.stderr
            admission_exists = [bool]$fallbackMutation.admission_exists
            receipt_mutated = [bool]$fallbackMutation.receipt_mutated
            dead_owners_omitted = $true
            activation_recheck_owners_nonempty = $true
        })
    } finally {
        try { Stop-Process -Id $live.Id -Force -ErrorAction SilentlyContinue } catch { }
        try { $live.Dispose() } catch { }
    }

    $observations.assertion_count = $assertions
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ObservationPath)) | Out-Null
    [IO.File]::WriteAllText($ObservationPath, (($observations | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    Write-Output ("FOCUSED_EXTRA_OWNER_ASSERTIONS=" + $assertions)
    Write-Output ("FOCUSED_EXTRA_OWNER_OBSERVATIONS=" + $ObservationPath)
    exit 0
} finally {
    if ([IO.Directory]::Exists($outsideRoot)) {
        try { [IO.Directory]::Delete($outsideRoot, $true) } catch { }
    }
}

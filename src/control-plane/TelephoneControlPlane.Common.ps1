# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\core\TelephoneLine.Common.ps1')

function Get-TelephoneControlPlaneSha256 {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function ConvertTo-TelephoneControlPlaneJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Value, [switch]$Compress)
    if ($Compress) { return (($Value | ConvertTo-Json -Depth 64 -Compress) + "`n") }
    return (($Value | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n")
}

function Get-TelephoneControlPlaneValueIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
    $text = ConvertTo-TelephoneControlPlaneJson -Value $Value
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    return [ordered]@{
        path = [IO.Path]::GetFullPath($Path)
        bytes = [int64]$bytes.Length
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
}

function New-TelephoneControlPlaneDeterministicGuid {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Seed)
    $bytes = [Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($Seed))[0..15]
    $bytes[7] = (($bytes[7] -band 0x0f) -bor 0x40)
    $bytes[8] = (($bytes[8] -band 0x3f) -bor 0x80)
    return ([Guid]::new([byte[]]$bytes).ToString('D').ToLowerInvariant())
}

function Get-TelephoneControlPlanePaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ControlStateRoot,
        [Parameter(Mandatory = $true)][string]$Project,
        [string]$ProjectEpoch = '',
        [string]$WaveId = ''
    )
    $root = [IO.Path]::GetFullPath($ControlStateRoot).TrimEnd('\')
    $projectKey = Get-TelephoneControlPlaneSha256 -Text $Project
    $projectRoot = Join-Path (Join-Path $root 'projects') $projectKey
    $epochKey = if ([string]::IsNullOrWhiteSpace($ProjectEpoch)) { '' } else { Get-TelephoneControlPlaneSha256 -Text $ProjectEpoch }
    $waveKey = if ([string]::IsNullOrWhiteSpace($WaveId)) { '' } else { Get-TelephoneControlPlaneSha256 -Text $WaveId }
    $waveRoot = if ([string]::IsNullOrWhiteSpace($epochKey) -or [string]::IsNullOrWhiteSpace($waveKey)) { '' } else { Join-Path (Join-Path (Join-Path $projectRoot 'waves') $epochKey) $waveKey }
    return [ordered]@{
        root = $root
        project_key = $projectKey
        project_root = $projectRoot
        gate = Join-Path $projectRoot 'update.lock'
        controller_gate = Join-Path $projectRoot 'controller.lock'
        pointer = Join-Path $projectRoot 'current-wave.json'
        current = Join-Path $projectRoot 'current.json'
        capsule = Join-Path $projectRoot 'continuation-capsule.json'
        history = Join-Path $projectRoot 'history-index.json'
        events = Join-Path $projectRoot 'events.jsonl'
        ledger = Join-Path $projectRoot 'ledger'
        conflicts = Join-Path $projectRoot 'conflicts'
        descriptor = Join-Path $projectRoot 'dashboard-project-descriptor.json'
        manifest_root = Join-Path $projectRoot 'waves'
        wave_root = $waveRoot
        manifest = $(if ([string]::IsNullOrWhiteSpace($waveRoot)) { '' } else { Join-Path $waveRoot 'wave-manifest.json' })
        actions = $(if ([string]::IsNullOrWhiteSpace($waveRoot)) { '' } else { Join-Path $waveRoot 'actions' })
        lane_attempts = $(if ([string]::IsNullOrWhiteSpace($waveRoot)) { '' } else { Join-Path $waveRoot 'lane-attempts' })
        launch_intent = $(if ([string]::IsNullOrWhiteSpace($waveRoot)) { '' } else { Join-Path $waveRoot 'wave-launch-intent.json' })
        launch_result = $(if ([string]::IsNullOrWhiteSpace($waveRoot)) { '' } else { Join-Path $waveRoot 'wave-launch-result.json' })
    }
}

function Get-TelephoneControlPlaneOptionalIdentity {
    [CmdletBinding()]
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return $null }
    return (Get-TelephoneFileIdentity -Path $Path)
}

function Get-TelephoneControlPlaneOwnerSnapshot {
    [CmdletBinding()]
    param([AllowNull()][object]$Owner)
    if ($null -eq $Owner) { return $null }
    $pidValue = 0
    $ticks = 0L
    try { $pidValue = [int]$Owner.pid; $ticks = [int64]$Owner.start_time_utc_ticks } catch { return $null }
    if ($pidValue -le 0 -or $ticks -le 0) { return $null }
    return [ordered]@{ pid = $pidValue; start_time_utc_ticks = $ticks; alive = [bool](Test-TelephoneOwnerAlive -Owner $Owner) }
}

function Get-TelephoneControlPlaneLeadOwner {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Lead)
    if (-not $Lead.Contains('owner_file') -or [string]::IsNullOrWhiteSpace([string]$Lead.owner_file)) { return $null }
    $path = [IO.Path]::GetFullPath([string]$Lead.owner_file)
    if (-not [IO.File]::Exists($path)) { return $null }
    try { return (Get-TelephoneControlPlaneOwnerSnapshot -Owner (Read-TelephoneJson -Path $path).value) } catch { return $null }
}

function Get-TelephoneControlPlaneNewestEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Paths, [string]$Fallback)
    $latest = [DateTimeOffset]::MinValue
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.File]::Exists($path)) { continue }
        $stamp = [DateTimeOffset](Get-Item -LiteralPath $path).LastWriteTimeUtc
        if ($stamp -gt $latest) { $latest = $stamp }
    }
    if ($latest -eq [DateTimeOffset]::MinValue) {
        try { $latest = [DateTimeOffset]::Parse([string]$Fallback).ToUniversalTime() } catch { $latest = [DateTimeOffset]::UtcNow }
    }
    $now = [DateTimeOffset]::UtcNow
    return [ordered]@{ at_utc = $latest.ToUniversalTime().ToString('o'); age_seconds = [math]::Max(0, [math]::Floor(($now - $latest).TotalSeconds)) }
}

function Get-TelephoneControlPlaneLaneAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Lane,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$WavePaths
    )
    $packageKey = Get-TelephoneControlPlaneSha256 -Text ([string]$Lane.package_id)
    $pointerPath = Join-Path ([string]$WavePaths.lane_attempts) ($packageKey + '.json')
    if (-not [IO.File]::Exists($pointerPath)) {
        return [ordered]@{
            attempt = 1
            line_job_id = [string]$Lane.line_job_id
            retry_of_line_job_id = $null
            request = $Lane.request
            pointer = $null
        }
    }
    $read = Read-TelephoneJson -Path $pointerPath -SchemaName 'control-plane-lane-attempt'
    if ([string]$read.value.package_id -cne [string]$Lane.package_id -or [string]$read.value.original_line_job_id -cne [string]$Lane.line_job_id) {
        throw 'Control-plane lane attempt pointer diverged from the immutable manifest.'
    }
    return [ordered]@{
        attempt = [int]$read.value.attempt
        line_job_id = [string]$read.value.line_job_id
        retry_of_line_job_id = [string]$read.value.retry_of_line_job_id
        request = $read.value.request
        pointer = $read.identity
    }
}

function Get-TelephoneControlPlaneLaneState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Lane,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$WavePaths,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Manifest,
        [Parameter(Mandatory = $true)][object]$ManifestIdentity,
        [string]$GeneratedAtUtc
    )
    $attempt = Get-TelephoneControlPlaneLaneAttempt -Lane $Lane -WavePaths $WavePaths
    $lineJobId = [string]$attempt.line_job_id
    $jobRoot = Join-Path (Join-Path ([string]$Lane.telephone_state_root) 'jobs') $lineJobId
    $paths = Get-TelephoneJobPaths -JobRoot $jobRoot
    $launchOwnerState='none';$launchOwnerInvalid=$false;$launchEvidencePaths=[Collections.Generic.List[string]]::new()
    if ($Lane.Contains('launch_owner') -and [string]$Lane.launch_owner.kind -ceq 'wired_supervisor') {
        try {
            Assert-TelephoneFileIdentity -Expected $Lane.launch_owner.request -Actual (Get-TelephoneFileIdentity -Path ([string]$Lane.launch_owner.request.path)) -Label 'Lane supervisor request'
            $supervisorRoot=[IO.Path]::GetFullPath([string]$Lane.launch_owner.state_root).TrimEnd('\');$recordName=([string]$Lane.launch_owner.run_id+'.json')
            foreach($kind in @('inbox','claimed','outbox')){
                $recordPath=Join-Path (Join-Path $supervisorRoot $kind) $recordName;[void]$launchEvidencePaths.Add($recordPath)
                if(-not[IO.File]::Exists($recordPath)){continue}
                $record=(Read-TelephoneJson -Path $recordPath).value
                if([string]$record.run_id-cne[string]$Lane.launch_owner.run_id-or[string]$record.request_sha256-cne[string]$Lane.launch_owner.request_sha256-or[string]$record.project-cne[string]$Manifest.project){throw 'supervisor record identity mismatch'}
                if($kind-ceq'outbox'){$launchOwnerState=$(if([string]$record.terminal-ceq'completed'){'completed'}else{'failed'})}
                elseif($kind-ceq'claimed' -and $launchOwnerState-cne'completed'){$launchOwnerState='running'}
                elseif($kind-ceq'inbox' -and $launchOwnerState-ceq'none'){$launchOwnerState='queued'}
            }
        } catch { $launchOwnerInvalid=$true }
    }
    $commandOwner = $null
    if ([IO.File]::Exists([string]$paths.command_owner)) {
        try { $commandOwner = (Read-TelephoneJson -Path ([string]$paths.command_owner)).value } catch { $commandOwner = $null }
    } elseif ([IO.File]::Exists([string]$paths.command_launch)) {
        try { $commandOwner = (Read-TelephoneJson -Path ([string]$paths.command_launch)).value.owner } catch { $commandOwner = $null }
    }
    $owner = Get-TelephoneControlPlaneOwnerSnapshot -Owner $commandOwner
    $relayOwner = $null
    if ([IO.File]::Exists([string]$paths.relay_owner)) {
        try { $relayOwner = (Read-TelephoneJson -Path ([string]$paths.relay_owner)).value } catch { $relayOwner = $null }
    }
    $callbackActive = [bool](Test-TelephoneOwnerAlive -Owner $relayOwner)
    $receipt = $null
    $receiptIdentity = $null
    $receiptRead = $null
    $receiptInvalid = $false
    if ([IO.File]::Exists([string]$paths.receipt)) {
        try {
            $receiptRead = Read-TelephoneJson -Path ([string]$paths.receipt) -SchemaName 'receipt'
            $receipt = $receiptRead.value
            $receiptIdentity = $receiptRead.identity
        } catch { $receiptInvalid = $true }
    }
    $dispatchInvalid = $false; $dispatchValue = $null; $dispatchRead=$null
    if ([IO.File]::Exists([string]$paths.dispatch)) {
        try {
            $dispatchRead = Read-TelephoneJson -Path ([string]$paths.dispatch) -SchemaName 'dispatch'; $dispatchValue = $dispatchRead.value
            $batch = Resolve-TelephoneDispatchBatch -Dispatch $dispatchValue -LineJobId $lineJobId
            if ([string]$dispatchValue.line_job_id -cne $lineJobId -or [string]$dispatchValue.project -cne [string]$Manifest.project -or [string]$dispatchValue.route -cne [string]$Lane.route -or [string]$dispatchValue.lead.session_id -cne [string]$Manifest.lead.session_id -or [string]$batch.package_id -cne [string]$Lane.package_id) { throw 'dispatch identity mismatch' }
            if (-not [IO.Path]::GetFullPath([string]$dispatchValue.command.working_directory).Equals([IO.Path]::GetFullPath([string]$Lane.workspace), [StringComparison]::OrdinalIgnoreCase)) { throw 'dispatch workspace mismatch' }
        } catch { $dispatchInvalid = $true }
    }
    if($null-ne$receiptRead-and-not$receiptInvalid){
        try{if($dispatchInvalid-or$null-eq$dispatchRead){throw 'receipt dispatch prerequisite missing'};$null=Assert-TelephoneReceiptBound -ReceiptRead $receiptRead -DispatchRead $dispatchRead}catch{$receiptInvalid=$true;$receipt=$null}
    }
    $deliveryIdentity = Get-TelephoneControlPlaneOptionalIdentity -Path ([string]$paths.delivery); $deliveryValid = $false; $deliveryInvalid = $false
    if ($null -ne $deliveryIdentity) {
        try {
            if ($receiptInvalid -or $null -eq $receiptIdentity -or $dispatchInvalid -or $null -eq $dispatchValue) { throw 'delivery prerequisites missing' }
            $delivery = (Read-TelephoneJson -Path ([string]$paths.delivery)).value
            if ([string]$delivery.protocol_version -cnotin @('telephone-line-delivery-v1','huhu-telephone-line-delivery-v1') -or [string]$delivery.line_job_id -cne $lineJobId -or [string]$delivery.lead_session_id -cne [string]$Manifest.lead.session_id) { throw 'delivery identity mismatch' }
            if (-not $delivery.Contains('control_plane') -or $null -eq $delivery.control_plane) { throw 'control-plane delivery binding missing' }
            $deliveryBinding=$delivery.control_plane;$dispatchIdentity=Get-TelephoneFileIdentity -Path ([string]$paths.dispatch)
            if ([string]$deliveryBinding.protocol_version -cne 'telephone-line-control-plane-delivery-binding-v1' -or [string]$deliveryBinding.project -cne [string]$Manifest.project -or [string]$deliveryBinding.project_epoch -cne [string]$Manifest.project_epoch -or [string]$deliveryBinding.wave_id -cne [string]$Manifest.wave_id -or [string]$deliveryBinding.activation_generation -cne [string]$Manifest.activation_generation -or [string]$deliveryBinding.lead_run_id -cne [string]$Manifest.lead.run_id -or [string]$deliveryBinding.package_id -cne [string]$Lane.package_id -or [string]$deliveryBinding.batch_id -cne [string]$batch.batch_id -or [int]$deliveryBinding.attempt -ne [int]$attempt.attempt -or [string]$deliveryBinding.route -cne [string]$Lane.route -or [string]$deliveryBinding.workspace -cne [string]$Lane.workspace -or [string]$deliveryBinding.write_lease_id -cne [string]$Lane.write_lease_id -or [string]$deliveryBinding.dispatch_sha256 -cne [string]$dispatchIdentity.sha256 -or [string]$deliveryBinding.receipt_sha256 -cne [string]$receiptIdentity.sha256) { throw 'control-plane delivery lineage mismatch' }
            $deliveryValid = $true
        } catch { $deliveryInvalid = $true }
    }
    $relayErrorIdentity = Get-TelephoneControlPlaneOptionalIdentity -Path ([string]$paths.relay_error)
    $handledPath = Join-Path $jobRoot 'handled-by-lead.json'; $handledValid = $false; $handledInvalid = $false
    if ([IO.File]::Exists($handledPath)) {
        try {
            if (-not $deliveryValid) { throw 'handled delivery missing' }
            $handled = (Read-TelephoneJson -Path $handledPath).value
            if ([string]$handled.protocol_version -cne 'telephone-line-control-plane-handled-v1' -or [string]$handled.line_job_id -cne $lineJobId -or [string]$handled.lead_session_id -cne [string]$Manifest.lead.session_id -or [string]$handled.lead_run_id -cne [string]$Manifest.lead.run_id -or [string]$handled.manifest_sha256 -cne [string]$ManifestIdentity.sha256 -or [string]$handled.receipt_sha256 -cne [string]$receiptIdentity.sha256 -or [string]$handled.delivery_sha256 -cne [string]$deliveryIdentity.sha256 -or [int]$handled.attempt -ne [int]$attempt.attempt -or [string]$handled.package_id -cne [string]$Lane.package_id -or [string]$handled.batch_id -cne [string]$batch.batch_id -or [string]$handled.route -cne [string]$Lane.route -or [string]$handled.workspace -cne [string]$Lane.workspace -or [string]$handled.write_lease_id -cne [string]$Lane.write_lease_id) { throw 'handled identity mismatch' }
            $handledValid = $true
        } catch { $handledInvalid = $true }
    }
    $sharedHostPath = Join-Path $jobRoot 'shared-host-failure.json'
    $sharedHostIdentity = Get-TelephoneControlPlaneOptionalIdentity -Path $sharedHostPath
    $sharedHostValid = $false
    if ($null -ne $sharedHostIdentity) {
        try {
            $shared = (Read-TelephoneJson -Path $sharedHostPath).value
            $sharedHostValid = ([string]$shared.protocol_version -ceq 'telephone-line-control-plane-shared-host-failure-v1' -and [string]$shared.line_job_id -ceq $lineJobId -and [string]$shared.failure_class -ceq 'shared_host')
        } catch { $sharedHostValid = $false }
    }
    $evidencePaths = @(
        [string]$paths.dispatch, [string]$paths.command_start_intent, [string]$paths.command_launch, [string]$paths.command_owner,
        [string]$paths.receipt, [string]$paths.relay_owner, [string]$paths.relay_error, [string]$paths.delivery, $handledPath, $sharedHostPath
    ) + @($launchEvidencePaths)
    $evidence = Get-TelephoneControlPlaneNewestEvidence -Paths $evidencePaths -Fallback $GeneratedAtUtc
    $launchGrace = if ($Lane.Contains('launch_grace_seconds')) { [int]$Lane.launch_grace_seconds } else { 30 }
    $callbackGrace = if ($Lane.Contains('callback_grace_seconds')) { [int]$Lane.callback_grace_seconds } else { 60 }
    $state = 'declared'
    $failure = 'none'
    $diagnostic = 'DECLARED'
    if ($launchOwnerInvalid) {
        $state = 'unknown'; $failure = 'state_conflict'; $diagnostic = 'SUPERVISOR_LAUNCH_EVIDENCE_INVALID'
    } elseif ($dispatchInvalid -or $deliveryInvalid -or $handledInvalid) {
        $state = 'unknown'; $failure = 'state_conflict'; $diagnostic = $(if ($handledInvalid) { 'HANDLED_EVIDENCE_INVALID' } elseif ($deliveryInvalid) { 'DELIVERY_EVIDENCE_INVALID' } else { 'DISPATCH_EVIDENCE_INVALID' })
    } elseif ($null -ne $sharedHostIdentity -and -not $sharedHostValid) {
        $state = 'unknown'; $failure = 'state_conflict'; $diagnostic = 'SHARED_HOST_EVIDENCE_INVALID'
    } elseif ($sharedHostValid) {
        $state = 'failed'; $failure = 'shared_host'; $diagnostic = 'SHARED_HOST_FAILURE'
    } elseif ($receiptInvalid) {
        $state = 'unknown'; $failure = 'state_conflict'; $diagnostic = 'RECEIPT_INVALID'
    } elseif ($handledValid) {
        $state = 'handled'; $diagnostic = 'HANDLED'
    } elseif ($deliveryValid) {
        $state = 'delivered'; $diagnostic = 'DELIVERED'
    } elseif ($null -ne $receipt) {
        if ($null -ne $relayErrorIdentity) {
            $state = 'failed'; $failure = 'telephone_transport'; $diagnostic = 'RELAY_ERROR'
        } else {
            $classification = Get-TelephoneReceiptClassification -Paths $paths -Receipt $receipt
            if ($classification -cin @('execution_failure', 'start_failed')) {
                $state = 'failed'; $failure = 'executor_session'; $diagnostic = 'EXECUTOR_OR_QUALIFIED_START_FAILURE'
            } elseif ($classification -cin @('start_ambiguous', 'start_failed_unqualified')) {
                $state = 'unknown'; $failure = 'state_conflict'; $diagnostic = 'START_STATE_CONFLICT'
            } elseif ($callbackActive) {
                $state = 'callback_running'; $diagnostic = 'CALLBACK_RUNNING'
            } elseif ([double]$evidence.age_seconds -gt $callbackGrace) {
                $state = 'failed'; $failure = 'telephone_transport'; $diagnostic = 'CALLBACK_LOST_AFTER_GRACE'
            } else {
                $state = 'receipt_ready'; $diagnostic = 'RECEIPT_READY_WITHIN_CALLBACK_GRACE'
            }
        }
    } elseif ($null -ne $owner -and [bool]$owner.alive) {
        $state = 'executing'; $diagnostic = 'EXECUTOR_OWNER_ALIVE'
    } elseif ([IO.File]::Exists([string]$paths.command_start_intent) -or [IO.File]::Exists([string]$paths.dispatch)) {
        if ([double]$evidence.age_seconds -gt $launchGrace) {
            $state = 'failed'; $failure = 'executor_session'; $diagnostic = 'EXECUTOR_STALLED_AFTER_LAUNCH_GRACE'
        } else {
            $state = 'starting'; $diagnostic = 'STARTING_WITHIN_LAUNCH_GRACE'
        }
    } elseif ([IO.Directory]::Exists($jobRoot)) {
        $state = 'unknown'; $failure = 'state_conflict'; $diagnostic = 'JOB_ROOT_WITHOUT_DURABLE_DISPATCH'
    } elseif ($launchOwnerState -ceq 'failed') { $state='failed';$failure='executor_session';$diagnostic='SUPERVISOR_LAUNCH_FAILED' }
    elseif ($launchOwnerState -ceq 'completed') { $state='unknown';$failure='state_conflict';$diagnostic='SUPERVISOR_COMPLETED_WITHOUT_DISPATCH' }
    elseif ($launchOwnerState -cin @('queued','running')) { $state='starting';$diagnostic=('SUPERVISOR_LAUNCH_'+$launchOwnerState.ToUpperInvariant()) }
    $identityInput = [ordered]@{
        package_id = [string]$Lane.package_id
        attempt = [int]$attempt.attempt
        line_job_id = $lineJobId
        retry_of_line_job_id = $attempt.retry_of_line_job_id
        request = $attempt.request
        card = $Lane.card
        workspace = [string]$Lane.workspace
        write_lease_id = [string]$Lane.write_lease_id
        evidence = @($evidencePaths | ForEach-Object { Get-TelephoneControlPlaneOptionalIdentity -Path $_ })
        owner_alive = ($null -ne $owner -and [bool]$owner.alive)
        callback_active = $callbackActive
    }
    return [ordered]@{
        package_id = [string]$Lane.package_id
        role = [string]$Lane.role
        route = [string]$Lane.route
        original_line_job_id = [string]$Lane.line_job_id
        line_job_id = $lineJobId
        attempt = [int]$attempt.attempt
        retry_of_line_job_id = $attempt.retry_of_line_job_id
        state = $state
        failure_class = $failure
        diagnostic_code = $diagnostic
        owner = $owner
        receipt = $receiptIdentity
        delivery = $deliveryIdentity
        relay_error = $relayErrorIdentity
        shared_host_evidence = $sharedHostIdentity
        callback_active = $callbackActive
        last_evidence_at_utc = [string]$evidence.at_utc
        evidence_age_seconds = [int64]$evidence.age_seconds
        launch_grace_seconds = $launchGrace
        callback_grace_seconds = $callbackGrace
        request = $attempt.request
        card = $Lane.card
        workspace = [string]$Lane.workspace
        allowed_write_paths = @($Lane.allowed_write_paths)
        write_lease_id = [string]$Lane.write_lease_id
        evidence_fingerprint = Get-TelephoneControlPlaneSha256 -Text (ConvertTo-TelephoneControlPlaneJson -Value $identityInput -Compress)
    }
}

function Get-TelephoneControlPlaneActionStates {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Manifest, [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths, [Parameter(Mandatory = $true)][object]$ManifestIdentity)
    $rows = [Collections.Generic.List[object]]::new()
    $statesById = @{}
    foreach ($action in @($Manifest.actions | Sort-Object { [int]$_.sequence })) {
        $key = Get-TelephoneControlPlaneSha256 -Text (([string]$ManifestIdentity.sha256) + '|' + [string]$action.idempotency_key)
        $intentPath = Join-Path ([string]$Paths.actions) ($key + '.intent.json')
        $baseResultPath = Join-Path ([string]$Paths.actions) ($key + '.result.json')
        $retryResultPath = Join-Path ([string]$Paths.actions) ($key + '.retry1.result.json')
        $ownerPath = Join-Path ([string]$Paths.actions) ($key + '.owner.json')
        $blockedPath = Join-Path ([string]$Paths.actions) ($key + '.blocked.json')
        $state = 'pending'; $reason = 'WAITING_TRIGGER'; $resultIdentity = $null; $retryCount = 0
        $blockedActive=$false;$blockedReason='';$blockedInvalid=$false
        if([IO.File]::Exists($blockedPath)){
            try{$blockedRecord=(Read-TelephoneJson -Path $blockedPath).value;if([string]$blockedRecord.protocol_version-cne'telephone-line-control-plane-action-blocked-v1'-or[string]$blockedRecord.action_id-cne[string]$action.action_id-or[string]$blockedRecord.idempotency_key-cne[string]$action.idempotency_key-or[string]$blockedRecord.manifest_sha256-cne[string]$ManifestIdentity.sha256){throw 'blocked action identity mismatch'};$blockedActive=[bool]$blockedRecord.active;$blockedReason=[string]$blockedRecord.code}catch{$blockedInvalid=$true}
        }
        $result = $null
        foreach ($candidate in @($retryResultPath, $baseResultPath)) {
            if (-not [IO.File]::Exists($candidate)) { continue }
            try { $result = (Read-TelephoneJson -Path $candidate -SchemaName 'control-plane-action-result'); $resultIdentity = $result.identity; break } catch { $state = 'conflict'; $reason = 'ACTION_RESULT_INVALID'; break }
        }
        if ($null -ne $result) {
            $retryCount = [int]$result.value.retry_count
            if ([string]$result.value.status -ceq 'completed') { $state = 'completed'; $reason = 'POSTCONDITION_COMPLETED' }
            elseif ([string]$result.value.status -ceq 'failed') {
                if ([string]$action.contract.retry_policy -ceq 'safe_once_if_no_effect' -and $retryCount -lt 1) { $state = 'retryable_failed'; $reason = 'ACTION_FAILED_SAFE_RETRY_AVAILABLE' }
                else { $state = 'exhausted'; $reason = 'ACTION_FAILED_NO_RETRY_REMAINING' }
            } else { $state = 'conflict'; $reason = 'ACTION_RESULT_NONTERMINAL_STATUS' }
        } elseif($blockedInvalid){$state='conflict';$reason='ACTION_BLOCKED_RECORD_INVALID'
        } elseif ([IO.File]::Exists($intentPath)) {
            $owner = $null
            if ([IO.File]::Exists($ownerPath)) { try { $owner = (Read-TelephoneJson -Path $ownerPath).value } catch { } }
            if ($null -ne $owner -and (Test-TelephoneOwnerAlive -Owner $owner)) { $state = 'running'; $reason = 'ACTION_OWNER_ALIVE' }
            elseif ($blockedActive) { $state = 'blocked'; $reason = $blockedReason }
            else { $state = 'conflict'; $reason = 'ACTION_INTENT_WITHOUT_OWNER_OR_RESULT' }
        } elseif ($blockedActive) { $state = 'blocked'; $reason = $blockedReason }
        foreach ($dependency in @($action.depends_on)) {
            if (-not $statesById.ContainsKey([string]$dependency)) {
                if ($state -ceq 'pending') { $state = 'conflict'; $reason = 'ACTION_DEPENDENCY_UNKNOWN' }
                continue
            }
            $dependencyState=[string]$statesById[[string]$dependency]
            if ($dependencyState -cin @('retryable_failed','blocked','conflict','exhausted')) {
                if ($state -ceq 'pending') { $state = 'blocked'; $reason = 'ACTION_DEPENDENCY_FAILED' }
            } elseif ($dependencyState -cne 'completed' -and $state -ceq 'pending') {
                $reason = 'WAITING_DEPENDENCY'
            }
        }
        $row = [ordered]@{ action_id=[string]$action.action_id; kind=[string]$action.kind; sequence=[int]$action.sequence; idempotency_key=[string]$action.idempotency_key; state=$state; reason=$reason; retry_count=$retryCount; result=$resultIdentity }
        [void]$rows.Add($row); $statesById[[string]$action.action_id] = $state
    }
    return @($rows.ToArray())
}

function Add-TelephoneControlPlaneEventOnce {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][Collections.IDictionary]$Event)
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $gate = Open-TelephoneExclusiveGate -Path ($Path + '.lock') -WaitMilliseconds 10000
    if ($null -eq $gate) { throw 'Control-plane event ledger is already being updated.' }
    try {
        if ([IO.File]::Exists($Path)) {
            foreach ($line in [IO.File]::ReadAllLines($Path, [Text.UTF8Encoding]::new($false))) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { if ([string](ConvertFrom-Json -InputObject $line -AsHashtable -Depth 32 -DateKind String).event_id -ceq [string]$Event.event_id) { return $false } } catch { throw 'Control-plane event ledger is corrupt.' }
            }
        }
        $lineBytes = [Text.UTF8Encoding]::new($false).GetBytes(((ConvertTo-Json $Event -Depth 32 -Compress) + "`n"))
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try { $stream.Write($lineBytes, 0, $lineBytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        return $true
    } finally { $gate.Dispose() }
}

function Get-TelephoneControlPlaneJsonFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Value)
    return (Get-TelephoneControlPlaneSha256 -Text (ConvertTo-TelephoneControlPlaneJson -Value $Value -Compress))
}

function Get-TelephoneControlPlaneLatestTransition {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Paths)
    if (-not [IO.Directory]::Exists([string]$Paths.ledger)) { return $null }
    $best = $null
    $invalid = [Collections.Generic.List[string]]::new()
    foreach ($file in [IO.Directory]::EnumerateFiles([string]$Paths.ledger, '*.json')) {
        try {
            $read = Read-TelephoneJson -Path $file -SchemaName 'control-plane-transition'
            if ($null -eq $best -or [int]$read.value.projection_version -gt [int]$best.value.projection_version) { $best = $read }
        } catch { [void]$invalid.Add($file); continue }
    }
    $markerPath=Join-Path ([string]$Paths.conflicts) 'ledger-transition.json'
    if ($invalid.Count -gt 0) {
        [IO.Directory]::CreateDirectory([string]$Paths.conflicts) | Out-Null
        $record = [ordered]@{ protocol_version = 'telephone-line-control-plane-conflict-v1'; code = 'CORRUPT_LEDGER_TRANSITION_SKIPPED'; active=$true; paths = @($invalid); observed_at_utc = [DateTimeOffset]::UtcNow.ToString('o'); resolved_at_utc=$null; requires_pascal = $false; reconstructed_from_prior_transition = ($null -ne $best) }
        $null = Write-TelephoneJsonReplace -Path $markerPath -Value $record
    } elseif([IO.File]::Exists($markerPath)) {
        try{$prior=(Read-TelephoneJson -Path $markerPath).value;$wasActive=if($prior.Contains('active')){[bool]$prior.active}else{$true};if($wasActive){$resolved=[ordered]@{protocol_version='telephone-line-control-plane-conflict-v1';code='CORRUPT_LEDGER_TRANSITION_SKIPPED';active=$false;paths=@($prior.paths);observed_at_utc=[string]$prior.observed_at_utc;resolved_at_utc=[DateTimeOffset]::UtcNow.ToString('o');requires_pascal=$false;reconstructed_from_prior_transition=[bool]$prior.reconstructed_from_prior_transition};$null=Write-TelephoneJsonReplace -Path $markerPath -Value $resolved}}catch{}
    }
    return $best
}

function Get-TelephoneControlPlaneMaxLedgerVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Paths)
    $max = 0
    if ([IO.Directory]::Exists([string]$Paths.ledger)) {
        foreach ($file in [IO.Directory]::EnumerateFiles([string]$Paths.ledger, '*.json')) {
            $name = [IO.Path]::GetFileName($file)
            if ($name -match '^(\d{10})-') { $max = [math]::Max($max, [int]$Matches[1]) }
        }
    }
    return $max
}

function Repair-TelephoneControlPlanePointerFromRegistration {
    [CmdletBinding()]
    param([Collections.IDictionary]$Manifest, [object]$ManifestIdentity, [Collections.IDictionary]$Paths)
    if (-not $Manifest.Contains('supervisor_state_root')) { return $null }
    $registrationRoot = Join-Path ([IO.Path]::GetFullPath([string]$Manifest.supervisor_state_root).TrimEnd('\')) 'control-plane\registrations'
    $registrationPath = Join-Path $registrationRoot ((Get-TelephoneControlPlaneSha256 -Text ([string]$Manifest.project)) + '.json')
    if (-not [IO.File]::Exists($registrationPath)) { return $null }
    try {
        $registration = (Read-TelephoneJson -Path $registrationPath).value
        Assert-TelephoneFileIdentity -Expected $registration.manifest -Actual $ManifestIdentity -Label 'Registered current manifest'
        $pointer = [ordered]@{
            protocol_version = 'telephone-line-control-plane-current-pointer-v1'; project = [string]$Manifest.project; project_epoch = [string]$Manifest.project_epoch; wave_id = [string]$Manifest.wave_id
            batch_id = [string]$Manifest.batch_id; activation_generation=[string]$Manifest.activation_generation; manifest = $ManifestIdentity; previous_pointer = $null; activated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        return (Write-TelephoneJsonReplace -Path ([string]$Paths.pointer) -Value $pointer)
    } catch { return $null }
}

function Restore-TelephoneControlPlaneFromLedger {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Paths)
    $latest = Get-TelephoneControlPlaneLatestTransition -Paths $Paths
    if ($null -eq $latest) { return $null }
    $value = $latest.value
    $value.event.transition = $latest.identity
    $value.current.last_transition = $value.event
    Assert-TelephoneJsonSchema -JsonText (ConvertTo-TelephoneControlPlaneJson -Value $value.current) -SchemaName 'control-plane-current-state' -Label 'reconstructed current state'
    Assert-TelephoneJsonSchema -JsonText (ConvertTo-TelephoneControlPlaneJson -Value $value.capsule) -SchemaName 'control-plane-continuation-capsule' -Label 'reconstructed continuation capsule'
    Assert-TelephoneJsonSchema -JsonText (ConvertTo-TelephoneControlPlaneJson -Value $value.history) -SchemaName 'control-plane-history-index' -Label 'reconstructed history index'
    $null = Write-TelephoneJsonReplace -Path ([string]$Paths.history) -Value $value.history
    $null = Write-TelephoneJsonReplace -Path ([string]$Paths.capsule) -Value $value.capsule
    $currentIdentity = Write-TelephoneJsonReplace -Path ([string]$Paths.current) -Value $value.current
    $null = Add-TelephoneControlPlaneEventOnce -Path ([string]$Paths.events) -Event $value.event
    return [ordered]@{ current = $value.current; current_identity = $currentIdentity; transition = $latest.identity; reconstructed = $true }
}

function Read-TelephoneControlPlaneCurrentOrRestore {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Paths)
    if (-not [IO.File]::Exists([string]$Paths.current)) { return (Restore-TelephoneControlPlaneFromLedger -Paths $Paths) }
    try {
        $read = Read-TelephoneJson -Path ([string]$Paths.current) -SchemaName 'control-plane-current-state'
        return [ordered]@{ current = $read.value; current_identity = $read.identity; reconstructed = $false }
    } catch {
        $restored = Restore-TelephoneControlPlaneFromLedger -Paths $Paths
        if ($null -ne $restored) { return $restored }
        [IO.Directory]::CreateDirectory([string]$Paths.conflicts) | Out-Null
        $conflict = [ordered]@{
            protocol_version = 'telephone-line-control-plane-conflict-v1'
            code = 'CURRENT_STATE_CORRUPT_NO_LEDGER_RECONSTRUCTION'
            path = [string]$Paths.current
            observed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            requires_pascal = $true
        }
        $null = Write-TelephoneJsonReplace -Path (Join-Path ([string]$Paths.conflicts) 'current-state.json') -Value $conflict
        throw 'CONTROL_PLANE_CURRENT_STATE_CONFLICT'
    }
}

function Register-TelephoneControlPlaneDashboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Manifest,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [string]$DashboardConfigPath = ''
    )
    $descriptor = [ordered]@{
        protocol_version = 'telephone-line-dashboard-project-descriptor-v1'
        project = [string]$Manifest.project
        state_root = [string]$Manifest.control_state_root
        current_state_file = [string]$Paths.current
        current_pointer_file = [string]$Paths.pointer
        manifest_file = [string]$Paths.manifest
        registration_file = Join-Path (Join-Path (Join-Path ([string]$Manifest.supervisor_state_root) 'control-plane') 'registrations') ((Get-TelephoneControlPlaneSha256 -Text ([string]$Manifest.project)) + '.json')
        activation_generation = [string]$Manifest.activation_generation
        terminal_state = 'active'
    }
    $descriptorIdentity = Write-TelephoneJsonReplace -Path ([string]$Paths.descriptor) -Value $descriptor
    if ([string]::IsNullOrWhiteSpace($DashboardConfigPath)) { return [ordered]@{ descriptor = $descriptorIdentity; config = $null; registered = $false } }
    $configPath = [IO.Path]::GetFullPath($DashboardConfigPath)
    $gate = Open-TelephoneExclusiveGate -Path ($configPath + '.lock') -WaitMilliseconds 10000
    if ($null -eq $gate) { throw 'Dashboard configuration is already being updated.' }
    try {
        $config = if ([IO.File]::Exists($configPath)) { (Read-TelephoneJson -Path $configPath -SchemaName 'dashboard-config').value } else { [ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @() } }
        $rows = [Collections.Generic.List[object]]::new()
        $replaced = $false
        foreach ($row in @($config.projects)) {
            $same = $false
            try {
                $existing = (Read-TelephoneJson -Path ([string]$row.descriptor_file) -SchemaName 'dashboard-project-descriptor').value
                $same = ([string]$existing.project -ceq [string]$Manifest.project)
            } catch { }
            if ($same) {
                if (-not $replaced) { [void]$rows.Add([ordered]@{ descriptor_file = [string]$descriptorIdentity.path }); $replaced = $true }
            } else { [void]$rows.Add($row) }
        }
        if (-not $replaced) { [void]$rows.Add([ordered]@{ descriptor_file = [string]$descriptorIdentity.path }) }
        $next = [ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @($rows.ToArray()) }
        $text = ConvertTo-TelephoneControlPlaneJson -Value $next
        Assert-TelephoneJsonSchema -JsonText $text -SchemaName 'dashboard-config' -Label 'dashboard config'
        $configIdentity = Write-TelephoneJsonReplace -Path $configPath -Value $next
        return [ordered]@{ descriptor = $descriptorIdentity; config = $configIdentity; registered = $true }
    } finally { $gate.Dispose() }
}

function Register-TelephoneControlPlaneSupervisor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Manifest,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [Parameter(Mandatory = $true)][object]$ManifestIdentity
    )
    if (-not $Manifest.Contains('supervisor_state_root') -or [string]::IsNullOrWhiteSpace([string]$Manifest.supervisor_state_root)) { return $null }
    $root = [IO.Path]::GetFullPath([string]$Manifest.supervisor_state_root).TrimEnd('\')
    $registrations = Join-Path (Join-Path $root 'control-plane') 'registrations'
    [IO.Directory]::CreateDirectory($registrations) | Out-Null
    $record = [ordered]@{
        protocol_version = 'telephone-line-control-plane-registration-v1'
        project = [string]$Manifest.project
        control_state_root = [string]$Manifest.control_state_root
        current_pointer = [string]$Paths.pointer
        current_state = [string]$Paths.current
        dashboard_descriptor = [string]$Paths.descriptor
        manifest = $ManifestIdentity
        activation_generation = [string]$Manifest.activation_generation
        install_root = [string]$Manifest.install_root
        enabled = $true
        registered_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $path = Join-Path $registrations ((Get-TelephoneControlPlaneSha256 -Text ([string]$Manifest.project)) + '.json')
    return (Write-TelephoneJsonReplace -Path $path -Value $record)
}

function Update-TelephoneControlPlaneState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ManifestFile)
    $manifestRead = Read-TelephoneJson -Path $ManifestFile -SchemaName 'control-plane-wave-manifest'
    $manifest = $manifestRead.value
    $paths = Get-TelephoneControlPlanePaths -ControlStateRoot ([string]$manifest.control_state_root) -Project ([string]$manifest.project) -ProjectEpoch ([string]$manifest.project_epoch) -WaveId ([string]$manifest.wave_id)
    [IO.Directory]::CreateDirectory([string]$paths.project_root) | Out-Null
    $pointerRead = $null
    try { $pointerRead = Read-TelephoneJson -Path ([string]$paths.pointer) -SchemaName 'control-plane-current-pointer' } catch {
        $repaired = Repair-TelephoneControlPlanePointerFromRegistration -Manifest $manifest -ManifestIdentity $manifestRead.identity -Paths $paths
        if ($null -eq $repaired) { throw 'CONTROL_PLANE_CURRENT_POINTER_CONFLICT' }
        $pointerRead = Read-TelephoneJson -Path ([string]$paths.pointer) -SchemaName 'control-plane-current-pointer'
    }
    if ([string]$pointerRead.value.manifest.sha256 -cne [string]$manifestRead.identity.sha256 -or -not [IO.Path]::GetFullPath([string]$pointerRead.value.manifest.path).Equals([IO.Path]::GetFullPath($ManifestFile), [StringComparison]::OrdinalIgnoreCase)) {
        $existing = Read-TelephoneControlPlaneCurrentOrRestore -Paths $paths
        return [ordered]@{
            changed = $false; inactive_wave = $true; current = $existing.current; current_identity = $existing.current_identity
            capsule_identity = Get-TelephoneControlPlaneOptionalIdentity -Path ([string]$paths.capsule)
            history_identity = Get-TelephoneControlPlaneOptionalIdentity -Path ([string]$paths.history)
            paths = $paths
        }
    }
    if ([string]$pointerRead.value.activation_generation -cne [string]$manifest.activation_generation) { throw 'CONTROL_PLANE_ACTIVATION_GENERATION_CONFLICT' }
    $gate = Open-TelephoneExclusiveGate -Path ([string]$paths.gate) -WaitMilliseconds 10000
    if ($null -eq $gate) { throw 'Control-plane state update is already owned.' }
    try {
        $previousRead = Read-TelephoneControlPlaneCurrentOrRestore -Paths $paths
        $previous = if ($null -eq $previousRead) { $null } else { $previousRead.current }
        $null=Get-TelephoneControlPlaneLatestTransition -Paths $paths
        $lanes = @($manifest.lanes | ForEach-Object { Get-TelephoneControlPlaneLaneState -Lane $_ -WavePaths $paths -Manifest $manifest -ManifestIdentity $manifestRead.identity -GeneratedAtUtc ([string]$manifest.generated_at_utc) })
        $actionStates = @(Get-TelephoneControlPlaneActionStates -Manifest $manifest -Paths $paths -ManifestIdentity $manifestRead.identity)
        $completed = @($lanes | Where-Object { [string]$_.state -cin @('delivered', 'handled') })
        $failed = @($lanes | Where-Object { [string]$_.state -cin @('failed', 'unknown') })
        $inFlight = @($lanes | Where-Object { [string]$_.state -cin @('starting', 'executing', 'receipt_ready', 'callback_running') })
        $actionConflicts = @($actionStates | Where-Object { [string]$_.state -cin @('retryable_failed','blocked','conflict','exhausted') })
        $allActionsCompleted=($actionStates.Count-eq0-or@($actionStates|Where-Object{[string]$_.state-cne'completed'}).Count-eq0)
        $allHandled = ($lanes.Count -gt 0 -and @($lanes | Where-Object { [string]$_.state -cne 'handled' }).Count -eq 0)
        $terminal = ($allHandled -and $allActionsCompleted -and [string]$manifest.next_transition.kind -ceq 'terminal' -and [bool]$manifest.next_transition.authorized)
        $overall = 'declared'; $phase = 'lead'
        if ($terminal) { $overall = 'terminal'; $phase = 'closed' }
        elseif ($failed.Count -gt 0) { $overall = $(if (@($failed | Where-Object { [string]$_.state -ceq 'unknown' }).Count -gt 0) { 'unknown' } else { 'failed' }); $phase = 'modify' }
        elseif (@($lanes | Where-Object { [string]$_.state -ceq 'executing' }).Count -gt 0) { $overall = 'executing'; $phase = 'execute' }
        elseif (@($lanes | Where-Object { [string]$_.state -ceq 'starting' }).Count -gt 0) { $overall = 'starting'; $phase = 'execute' }
        elseif (@($lanes | Where-Object { [string]$_.state -cin @('receipt_ready', 'callback_running') }).Count -gt 0) { $overall = 'awaiting_callback'; $phase = 'execute' }
        elseif ($completed.Count -gt 0) { $overall = 'accepting'; $phase = 'review' }
        $findings = [Collections.Generic.List[string]]::new()
        foreach ($lane in $failed) {
            foreach ($code in @([string]$lane.diagnostic_code, $(switch ([string]$lane.failure_class) {
                'telephone_transport' { 'TELEPHONE_TRANSPORT_FAILURE' }
                'executor_session' { 'EXECUTOR_SESSION_FAILURE' }
                'shared_host' { 'SHARED_HOST_FAILURE' }
                default { 'STATE_CONFLICT' }
            }))) { if (-not [string]::IsNullOrWhiteSpace($code) -and -not $findings.Contains($code)) { [void]$findings.Add($code) } }
        }
        foreach ($actionState in $actionStates) {
            $actionFinding = switch ([string]$actionState.state) {
                'retryable_failed' { 'ACTION_RETRYABLE_FAILED' }
                'blocked' { 'ACTION_BLOCKED' }
                'conflict' { 'ACTION_CONFLICT' }
                'exhausted' { 'ACTION_EXHAUSTED' }
                default { '' }
            }
            if (-not [string]::IsNullOrWhiteSpace($actionFinding) -and -not $findings.Contains($actionFinding)) { [void]$findings.Add($actionFinding) }
        }
        $ledgerConflictPath=Join-Path ([string]$paths.conflicts) 'ledger-transition.json';$ledgerConflictActive=$false
        if([IO.File]::Exists($ledgerConflictPath)){try{$ledgerMarker=(Read-TelephoneJson -Path $ledgerConflictPath).value;$ledgerConflictActive=$(if($ledgerMarker.Contains('active')){[bool]$ledgerMarker.active}else{$true})}catch{$ledgerConflictActive=$true}}
        if($ledgerConflictActive-and-not$findings.Contains('CONTROL_PLANE_LEDGER_CONFLICT')){[void]$findings.Add('CONTROL_PLANE_LEDGER_CONFLICT')}
        if (-not $terminal -and $actionConflicts.Count -gt 0) { $overall = 'unknown'; $phase = 'modify' }
        $ledgerConflict = $findings.Contains('CONTROL_PLANE_LEDGER_CONFLICT')
        $projectionStatus = $(if ($ledgerConflict -or @($failed | Where-Object { [string]$_.failure_class -ceq 'state_conflict' }).Count -gt 0 -or @($actionStates | Where-Object { [string]$_.state -cin @('conflict','exhausted') }).Count -gt 0) { 'conflict' } elseif ($failed.Count -gt 0 -or $actionConflicts.Count -gt 0) { 'unknown' } else { 'healthy' })
        $requiresPascal = ($ledgerConflict -or @($failed | Where-Object { [string]$_.failure_class -cin @('shared_host', 'state_conflict') }).Count -gt 0 -or @($actionStates | Where-Object { [string]$_.state -cin @('conflict','exhausted') }).Count -gt 0)
        $leadOwner = Get-TelephoneControlPlaneLeadOwner -Lead $manifest.lead
        $fingerprintLanes = @($lanes | ForEach-Object {
            [ordered]@{
                package_id = [string]$_.package_id; role = [string]$_.role; route = [string]$_.route; original_line_job_id = [string]$_.original_line_job_id; line_job_id = [string]$_.line_job_id
                attempt = [int]$_.attempt; retry_of_line_job_id = $_.retry_of_line_job_id; state = [string]$_.state; failure_class = [string]$_.failure_class; diagnostic_code = [string]$_.diagnostic_code
                owner = $_.owner; receipt = $_.receipt; delivery = $_.delivery; relay_error = $_.relay_error; shared_host_evidence = $_.shared_host_evidence; callback_active = [bool]$_.callback_active
                last_evidence_at_utc = [string]$_.last_evidence_at_utc; request = $_.request; card = $_.card; workspace = [string]$_.workspace; allowed_write_paths = @($_.allowed_write_paths)
                write_lease_id = [string]$_.write_lease_id; evidence_fingerprint = [string]$_.evidence_fingerprint
            }
        })
        $fingerprintInput = [ordered]@{
            project = [string]$manifest.project; project_epoch = [string]$manifest.project_epoch; wave_id = [string]$manifest.wave_id; batch_id = [string]$manifest.batch_id; activation_generation=[string]$manifest.activation_generation
            manifest = $manifestRead.identity; current_pointer = $pointerRead.identity; lead = [ordered]@{ transport = [string]$manifest.lead.transport; session_id = [string]$manifest.lead.session_id; run_id = [string]$manifest.lead.run_id; owner = $leadOwner }
            overall_state = $overall; lanes = $fingerprintLanes; actions = $actionStates; next_transition = $manifest.next_transition; requires_pascal = $requiresPascal; terminal = $terminal; projection_status = $projectionStatus; findings = @($findings)
        }
        $fingerprint = Get-TelephoneControlPlaneJsonFingerprint -Value $fingerprintInput
        if ($null -ne $previous -and [string]$previous.projection_fingerprint -ceq $fingerprint) {
            try {
                $capsuleRead = Read-TelephoneJson -Path ([string]$paths.capsule) -SchemaName 'control-plane-continuation-capsule'
                $historyRead = Read-TelephoneJson -Path ([string]$paths.history) -SchemaName 'control-plane-history-index'
            } catch {
                $restored = Restore-TelephoneControlPlaneFromLedger -Paths $paths
                if ($null -eq $restored) { throw 'CONTROL_PLANE_CHECKPOINT_CONFLICT' }
                $previous = $restored.current; $previousRead = $restored
                $capsuleRead = Read-TelephoneJson -Path ([string]$paths.capsule) -SchemaName 'control-plane-continuation-capsule'
                $historyRead = Read-TelephoneJson -Path ([string]$paths.history) -SchemaName 'control-plane-history-index'
            }
            return [ordered]@{
                changed = $false; inactive_wave = $false; current = $previous; current_identity = $previousRead.current_identity
                capsule_identity = $capsuleRead.identity; history_identity = $historyRead.identity; paths = $paths
            }
        }
        $previousVersion = if ($null -eq $previous) { 0 } else { [int]$previous.projection_version }
        $version = [math]::Max($previousVersion, (Get-TelephoneControlPlaneMaxLedgerVersion -Paths $paths)) + 1
        $now = [DateTimeOffset]::UtcNow.ToString('o')
        $eventId = Get-TelephoneControlPlaneSha256 -Text (([string]$manifest.project) + '|' + ([string]$manifest.project_epoch) + '|' + ([string]$manifest.wave_id) + '|' + $fingerprint + '|' + $version)
        $event = [ordered]@{
            protocol_version = 'telephone-line-control-plane-event-v1'; event_id = $eventId; project = [string]$manifest.project; project_epoch = [string]$manifest.project_epoch
            wave_id = [string]$manifest.wave_id; projection_version = $version; projection_fingerprint = $fingerprint; kind = ('projection-' + $overall)
            idempotency_key = ('state:' + $fingerprint); at_utc = $now; transition = $null
        }
        $history = $null
        if ([IO.File]::Exists([string]$paths.history)) {
            try { $history = (Read-TelephoneJson -Path ([string]$paths.history) -SchemaName 'control-plane-history-index').value } catch {
                $restored = Restore-TelephoneControlPlaneFromLedger -Paths $paths
                if ($null -eq $restored) { throw 'CONTROL_PLANE_HISTORY_CONFLICT' }
                $history = (Read-TelephoneJson -Path ([string]$paths.history) -SchemaName 'control-plane-history-index').value
            }
        }
        $waveRows = [Collections.Generic.List[object]]::new()
        if ($null -ne $history) {
            foreach ($row in @($history.waves)) {
                if ([string]$row.project_epoch -ceq [string]$manifest.project_epoch -and [string]$row.wave_id -ceq [string]$manifest.wave_id) { continue }
                [void]$waveRows.Add($row)
            }
        }
        [void]$waveRows.Add([ordered]@{
            project_epoch = [string]$manifest.project_epoch; wave_id = [string]$manifest.wave_id; batch_id = [string]$manifest.batch_id; manifest = $manifestRead.identity
            latest_projection_version = $version; latest_projection_fingerprint = $fingerprint; overall_state = $overall; terminal = [bool]$terminal
            completed_count = $completed.Count; failed_count = $failed.Count; updated_at_utc = $now
        })
        $historyValue = [ordered]@{
            protocol_version = 'telephone-line-control-plane-history-index-v1'; project = [string]$manifest.project; latest_projection_version = $version
            current_project_epoch = [string]$manifest.project_epoch; current_wave_id = [string]$manifest.wave_id; waves = @($waveRows.ToArray()); updated_at_utc = $now
        }
        $capsule = [ordered]@{
            protocol_version = 'telephone-line-control-plane-continuation-capsule-v1'; project = [string]$manifest.project; project_epoch = [string]$manifest.project_epoch
            authority = $manifest.authority; manifest = $manifestRead.identity; source_spec = $manifest.source_spec; current_pointer = $pointerRead.identity; activation_generation=[string]$manifest.activation_generation
            lead = [ordered]@{ transport = [string]$manifest.lead.transport; session_id = [string]$manifest.lead.session_id; run_id = [string]$manifest.lead.run_id; owner = $leadOwner }
            wave_id = [string]$manifest.wave_id; batch_id = [string]$manifest.batch_id; projection_version = $version; projection_fingerprint = $fingerprint
            lanes = $lanes; actions = $actionStates; next_transition = $manifest.next_transition; recovery_postconditions = @($manifest.actions | ForEach-Object { [ordered]@{ action_id = [string]$_.action_id; kind = [string]$_.kind; contract_fingerprint = [string]$_.contract.contract_fingerprint; expected_postcondition = $_.contract.expected_postcondition } })
            created_at_utc = $now
        }
        $historyIdentityPredicted = Get-TelephoneControlPlaneValueIdentity -Path ([string]$paths.history) -Value $historyValue
        $capsuleIdentityPredicted = Get-TelephoneControlPlaneValueIdentity -Path ([string]$paths.capsule) -Value $capsule
        $current = [ordered]@{
            protocol_version = 'telephone-line-control-plane-current-state-v1'; projection_version = $version; projection_fingerprint = $fingerprint
            project = [string]$manifest.project; project_epoch = [string]$manifest.project_epoch; goal_summary = [string]$manifest.goal_summary; authority = $manifest.authority; manifest = $manifestRead.identity; current_pointer = $pointerRead.identity; activation_generation=[string]$manifest.activation_generation
            lead = [ordered]@{ transport = [string]$manifest.lead.transport; session_id = [string]$manifest.lead.session_id; run_id = [string]$manifest.lead.run_id; owner = $leadOwner }
            wave_id = [string]$manifest.wave_id; batch_id = [string]$manifest.batch_id; batch_n = [int]$manifest.batch_n; dashboard_phase = $phase; overall_state = $overall; lanes = $lanes; actions = $actionStates
            completed_count = $completed.Count; failed_count = $failed.Count; in_flight_count = $inFlight.Count; last_transition = $event; next_transition = $manifest.next_transition
            requires_pascal = [bool]$requiresPascal; terminal = [bool]$terminal; projection_status = $projectionStatus; findings = @($findings)
            continuation_capsule = $capsuleIdentityPredicted; history_index = $historyIdentityPredicted; stale_after_seconds = [int]$manifest.projection_stale_after_seconds; updated_at_utc = $now
        }
        $transitionName = ('{0:D10}-{1}.json' -f $version, $fingerprint)
        $transitionPath = Join-Path ([string]$paths.ledger) $transitionName
        [IO.Directory]::CreateDirectory([string]$paths.ledger) | Out-Null
        $transition = [ordered]@{
            protocol_version = 'telephone-line-control-plane-transition-v1'; project = [string]$manifest.project; project_epoch = [string]$manifest.project_epoch; wave_id = [string]$manifest.wave_id
            projection_version = $version; projection_fingerprint = $fingerprint; manifest = $manifestRead.identity; current_pointer = $pointerRead.identity
            event = $event; current = $current; capsule = $capsule; history = $historyValue; created_at_utc = $now
        }
        $transitionText = ConvertTo-TelephoneControlPlaneJson -Value $transition
        Assert-TelephoneJsonSchema -JsonText $transitionText -SchemaName 'control-plane-transition' -Label 'control-plane transition'
        $transitionIdentity = if ([IO.File]::Exists($transitionPath)) {
            $existing = Get-TelephoneFileIdentity -Path $transitionPath
            $expected = Get-TelephoneControlPlaneValueIdentity -Path $transitionPath -Value $transition
            if ([string]$existing.sha256 -cne [string]$expected.sha256) { throw 'CONTROL_PLANE_TRANSITION_DIVERGENCE' }
            $existing
        } else { Write-TelephoneJsonCreateNew -Path $transitionPath -Value $transition }
        $event.transition = $transitionIdentity; $current.last_transition = $event
        Assert-TelephoneJsonSchema -JsonText (ConvertTo-TelephoneControlPlaneJson -Value $event) -SchemaName 'control-plane-event' -Label 'control-plane event'
        $null = Add-TelephoneControlPlaneEventOnce -Path ([string]$paths.events) -Event $event
        $historyIdentity = Write-TelephoneJsonReplace -Path ([string]$paths.history) -Value $historyValue
        $capsuleIdentity = Write-TelephoneJsonReplace -Path ([string]$paths.capsule) -Value $capsule
        $current.continuation_capsule = $capsuleIdentity; $current.history_index = $historyIdentity
        $currentText = ConvertTo-TelephoneControlPlaneJson -Value $current
        Assert-TelephoneJsonSchema -JsonText $currentText -SchemaName 'control-plane-current-state' -Label 'control-plane current state'
        $currentIdentity = Write-TelephoneJsonReplace -Path ([string]$paths.current) -Value $current
        return [ordered]@{ changed = $true; inactive_wave = $false; current = $current; current_identity = $currentIdentity; capsule_identity = $capsuleIdentity; history_identity = $historyIdentity; transition_identity = $transitionIdentity; paths = $paths }
    } finally { $gate.Dispose() }
}

function Get-TelephoneControlPlaneDoctorReport {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProductRoot, [string]$SupervisorStateRoot = '')
    $root = [IO.Path]::GetFullPath($ProductRoot).TrimEnd('\')
    $required = @(
        'src\control-plane\TelephoneControlPlane.Common.ps1', 'src\control-plane\Update-TelephoneCurrentState.ps1',
        'src\control-plane\Invoke-TelephoneContinuityController.ps1', 'src\control-plane\New-TelephoneWaveManifest.ps1',
        'src\control-plane\Start-TelephoneControlPlaneWave.ps1', 'src\control-plane\Invoke-TelephoneControlPlaneWake.ps1',
        'src\packaging\Test-TelephoneOpenSourceReadiness.ps1', 'docs\control-plane.md',
        'schemas\control-plane-wave-spec.schema.json', 'schemas\control-plane-wave-manifest.schema.json', 'schemas\control-plane-current-pointer.schema.json',
        'schemas\control-plane-current-state.schema.json', 'schemas\control-plane-continuation-capsule.schema.json', 'schemas\control-plane-action-intent.schema.json',
        'schemas\control-plane-action-result.schema.json', 'schemas\control-plane-event.schema.json', 'schemas\control-plane-transition.schema.json',
        'schemas\control-plane-history-index.schema.json', 'schemas\control-plane-lane-attempt.schema.json', 'schemas\control-plane-performance-evidence.schema.json',
        'schemas\control-plane-failure-matrix-evidence.schema.json', 'schemas\control-plane-release-gates-evidence.schema.json'
    )
    $missing = @($required | Where-Object { -not [IO.File]::Exists((Join-Path $root $_)) })
    $schemaErrors = [Collections.Generic.List[string]]::new()
    foreach ($rel in @($required | Where-Object { $_ -like 'schemas\*.json' })) {
        try { $null = [IO.File]::ReadAllText((Join-Path $root $rel)) | ConvertFrom-Json -Depth 64 } catch { [void]$schemaErrors.Add($rel) }
    }
    $markers = [ordered]@{
        supervisor_reconciles_registered_projects = $false
        command_host_wakes_controller = $false
        relay_wakes_controller = $false
        launcher_creates_durable_batch_intent = $false
        controller_has_transition_lock = $false
        controller_rejects_custom_automatic_actions = $false
        dashboard_binds_current_pointer = $false
    }
    $markerFiles = [ordered]@{
        supervisor_reconciles_registered_projects = @('src\supervisor\Invoke-TelephoneSupervisor.ps1', 'Invoke-TelephoneControlPlaneRegisteredProjects')
        command_host_wakes_controller = @('src\core\Invoke-TelephoneLineCommandHost.ps1', 'Invoke-TelephoneControlPlaneLifecycleWake')
        relay_wakes_controller = @('src\core\Invoke-TelephoneLineRelay.ps1', 'Invoke-TelephoneControlPlaneLifecycleWake')
        launcher_creates_durable_batch_intent = @('src\control-plane\Start-TelephoneControlPlaneWave.ps1', 'wave-launch-intent')
        controller_has_transition_lock = @('src\control-plane\Invoke-TelephoneContinuityController.ps1', 'controller_gate')
        controller_rejects_custom_automatic_actions = @('src\control-plane\Invoke-TelephoneContinuityController.ps1', 'CUSTOM_ACTION_NOT_AUTOMATIC')
        dashboard_binds_current_pointer = @('src\control-plane\TelephoneControlPlane.Common.ps1', 'Register-TelephoneControlPlaneDashboard')
    }
    foreach ($name in $markerFiles.Keys) {
        $path = Join-Path $root ([string]$markerFiles[$name][0]); $needle = [string]$markerFiles[$name][1]
        $markers[$name] = ([IO.File]::Exists($path) -and [IO.File]::ReadAllText($path).IndexOf($needle, [StringComparison]::Ordinal) -ge 0)
    }
    $parseErrors = [Collections.Generic.List[string]]::new()
    foreach ($rel in @($required | Where-Object { $_ -like '*.ps1' })) {
        $tokens = $null; $errors = $null; [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root $rel), [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { [void]$parseErrors.Add($rel) }
    }
    $registrations = 0; $registrationErrors = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($SupervisorStateRoot)) {
        $regRoot = Join-Path (Join-Path ([IO.Path]::GetFullPath($SupervisorStateRoot).TrimEnd('\')) 'control-plane') 'registrations'
        if ([IO.Directory]::Exists($regRoot)) {
            foreach ($file in [IO.Directory]::EnumerateFiles($regRoot, '*.json')) {
                try { $null = Read-TelephoneJson -Path $file; $registrations += 1 } catch { [void]$registrationErrors.Add($file) }
            }
        }
    }
    $verified = ($missing.Count -eq 0 -and $schemaErrors.Count -eq 0 -and $parseErrors.Count -eq 0 -and @($markers.Values | Where-Object { $_ -ne $true }).Count -eq 0 -and $registrationErrors.Count -eq 0)
    return [ordered]@{
        bundled_present = ($missing.Count -eq 0); required_files = $required.Count; missing = @($missing)
        schemas_valid = ($schemaErrors.Count -eq 0); schema_errors = @($schemaErrors); powershell_parse_valid = ($parseErrors.Count -eq 0); powershell_parse_errors = @($parseErrors)
        consumer_path_markers = $markers; controller_is_authority_bounded = [bool]$verified; current_state_is_single_projection = [bool]$markers.dashboard_binds_current_pointer
        registration_count = $registrations; registration_errors = @($registrationErrors); destructive_shared_host_tests_automatic = $false
    }
}

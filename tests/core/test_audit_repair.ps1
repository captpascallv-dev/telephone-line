# SPDX-License-Identifier: MPL-2.0
# Correction-1 focused proofs. Isolated fixtures only; no live install, Task
# Scheduler, App, or paid PI mutation. Does not rerun hop-1/hop-2 suites for a
# green count. Missing writer identity is UNKNOWN; ownerless claimed is UNKNOWN.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'src\core\TelephoneLine.Common.ps1')
. (Join-Path $repoRoot 'src\dashboard\TelephoneDashboard.Common.ps1')
. (Join-Path $repoRoot 'src\dashboard\TelephoneDashboard.Projection.ps1')
. (Join-Path $repoRoot 'src\supervisor\TelephoneSupervisor.Common.ps1')
. (Join-Path $repoRoot 'src\install\TelephoneLineInstall.Common.ps1')
$pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$assertions = 0
$previousDashState = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_STATE', 'Process')
$previousDashOpt = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', 'Process')
$previousLeadState = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_LEAD_STATE_ROOT', 'Process')
$previousTaskBackend = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_TASK_BACKEND', 'Process')
$previousTaskStore = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_TASK_STORE', 'Process')
$previousSupState = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_SUPERVISOR_STATE_ROOT', 'Process')
$previousLineState = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_STATE_ROOT', 'Process')
$previousInstallRoot = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_INSTALL_ROOT', 'Process')

function Assert-Repair {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Get-RepairSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

function Wait-RepairPath {
    param([Parameter(Mandatory = $true)][string]$Path, [int]$Milliseconds = 15000, [scriptblock]$Probe = $null)
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($Milliseconds)
    do {
        if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
            if ($null -eq $Probe) { return $true }
            try { if (& $Probe) { return $true } } catch { }
        }
        Start-Sleep -Milliseconds 50
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    return $false
}

try {
    $env:TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY = '1'
    $env:TELEPHONE_LINE_DASHBOARD_OPT_OUT = '1'
    $dashState = Join-Path $testRoot 'dashboard-runtime'
    [IO.Directory]::CreateDirectory($dashState) | Out-Null
    $env:TELEPHONE_LINE_DASHBOARD_STATE = $dashState

    $origStderrSrc = 'C:\Users\Pascal\Documents\Codex\2026-08-16\pascal-master-task-20260816\control\handoffs\MASTER_SECRETARY_SUCCESSOR_REVIEW_20260907\new-secretary\telephone-direct-grok-repair-20260907\runtime-lead\state\cli-r2\telephone-315730a2-2619-4529-bd7e-9758eb2c68b1\codex-stderr.txt'
    $origStderrText = "thread-store conflict: session already has an active writer`n"
    if ([IO.File]::Exists($origStderrSrc)) {
        $origStderrText = [IO.File]::ReadAllText($origStderrSrc)
    }
    Assert-Repair ($origStderrText -match 'thread-store conflict') 'Original stderr lost the conflict phrase.'
    Assert-Repair ($origStderrText -match 'already has an active writer') 'Original stderr lost the writer phrase.'
    Assert-Repair ($origStderrText -notmatch '(?i)pid[=:\s]+\d+') 'Original stderr unexpectedly contained a pid.'

    $dualLauncher = Join-Path $testRoot 'dual-wake.ps1'
    $turnLog = Join-Path $testRoot 'turn-starts.jsonl'
    [IO.File]::WriteAllText($dualLauncher, @'
param([string]$WorktreePath,[string]$PromptFile,[string]$ResumeSessionId,[string]$RunId,[string]$StateRootOverride)
$ErrorActionPreference = "Stop"
$run = [IO.Path]::GetFullPath((Join-Path $StateRootOverride $RunId))
[IO.Directory]::CreateDirectory($run) | Out-Null
$turn = [string]$env:TELEPHONE_TEST_LEAD_TURNS
if (-not [string]::IsNullOrWhiteSpace($turn)) {
    $row = [ordered]@{ run_id = $RunId; at_utc = [DateTimeOffset]::UtcNow.ToString("o") }
    [IO.File]::AppendAllText($turn, (($row | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}
if ($RunId -match "-retry-") {
    $events = Join-Path $run "codex-events.jsonl"
    $utf8 = [Text.UTF8Encoding]::new($false)
    $leadRun = [ordered]@{
        protocol_version = "huhu-concerto-cli-lead-run-v1"
        run_id = $RunId
        requested_run_id = $RunId
        worktree = [IO.Path]::GetFullPath($WorktreePath).TrimEnd("\")
        resume_session_id = $ResumeSessionId
        events_path = $events
        created_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
    }
    [IO.File]::WriteAllText((Join-Path $run "lead-run.json"), (($leadRun | ConvertTo-Json -Depth 8) + "`n"), $utf8)
    $eventText = '{"type":"thread.started","thread_id":"' + $ResumeSessionId + '"}' + "`n" + '{"type":"turn.started"}' + "`n"
    [IO.File]::WriteAllText($events, $eventText, $utf8)
    [ordered]@{ run_root = $run; state = "running"; exit_code = 0; wake_run_id = $RunId } | ConvertTo-Json -Compress
    exit 0
}
$stderr = [string]$env:TELEPHONE_TEST_ORIG_STDERR
if ([string]::IsNullOrWhiteSpace($stderr)) { $stderr = "thread-store conflict: session already has an active writer`n" }
[IO.File]::WriteAllText((Join-Path $run "codex-events.jsonl"), "", [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $run "codex-stderr.txt"), $stderr, [Text.UTF8Encoding]::new($false))
[ordered]@{ exit_code = 1; completed_at_utc = [DateTimeOffset]::UtcNow.ToString("o") } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run "host-terminal.json") -Encoding utf8NoBOM
[Console]::Error.Write($stderr)
exit 1
'@, [Text.UTF8Encoding]::new($false))
    $env:TELEPHONE_TEST_LEAD_TURNS = $turnLog
    $env:TELEPHONE_TEST_ORIG_STDERR = $origStderrText

    $leadState = Join-Path $testRoot 'lead-state'
    [IO.Directory]::CreateDirectory($leadState) | Out-Null
    $env:TELEPHONE_LINE_LEAD_STATE_ROOT = $leadState
    $work = Join-Path $testRoot 'worktree'
    [IO.Directory]::CreateDirectory($work) | Out-Null
    $prompt = Join-Path $testRoot 'wake.md'
    [IO.File]::WriteAllText($prompt, "wake`n", [Text.UTF8Encoding]::new($false))

    $jobId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1'
    $session = '01a07aae-1026-79a0-aa0c-c9fdc2f083d6'
    $runId = 'telephone-' + $jobId
    try {
        Invoke-TelephoneFrozenLeadLauncher -LauncherPath $dualLauncher -ExtraArguments @('-StateRootOverride', $leadState) -Worktree $work -PromptFile $prompt -SessionId $session -RunId $runId
        throw 'No-PID pre-turn launcher was treated as success.'
    } catch {
        Assert-Repair ([string]$_.Exception.Message -ceq 'LEAD_WAKE_PRE_TURN_CONFLICT') 'No-PID conflict did not throw LEAD_WAKE_PRE_TURN_CONFLICT.'
    }
    $diag = Get-TelephoneLastLeadLaunchDiagnostic
    Assert-Repair ($null -ne $diag) 'Launch diagnostic was not stashed.'
    Assert-Repair ([string]$diag.error_code -ceq 'LEAD_WAKE_PRE_TURN_CONFLICT') 'Diagnostic code was replaced.'
    Assert-Repair ([string]$diag.stderr -match 'active writer') 'Original stderr was not persisted.'
    Assert-Repair ([int]$diag.exit_code -eq 1) 'Host exit was not persisted.'

    $conflictRoot = Join-Path $leadState $runId
    $conflict = Test-TelephoneLeadPreTurnActiveWriterConflict -RunRoot $conflictRoot -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-Repair ([bool]$conflict.matched) 'Actual no-PID stderr was not classified as pre-turn writer conflict.'
    Assert-Repair ([string]$conflict.writer_identity_status -ceq 'UNKNOWN') 'Missing writer identity was not UNKNOWN.'
    Assert-Repair (-not [bool]$conflict.retry_eligible) 'Missing writer identity was treated as retry-eligible/released.'
    Assert-Repair ($null -eq $conflict.writer) 'Missing writer identity invented a writer object.'
    $barePidOwner = Get-TelephoneLeadWriterOwnerFromStderr -Text $origStderrText -RunRoot $conflictRoot -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-Repair ($null -eq $barePidOwner) 'No-PID stderr still resolved a live process snapshot as the original writer.'

    $jobRoot = Join-Path $testRoot ('jobs\' + $jobId)
    [IO.Directory]::CreateDirectory($jobRoot) | Out-Null
    $paths = Get-TelephoneJobPaths -JobRoot $jobRoot
    $leadBinding = [ordered]@{
        protocol_version = 'telephone-line-lead-binding-v1'
        session_id = $session
        worktree = $work
        launcher = [ordered]@{ path = $dualLauncher; arguments = @('-StateRootOverride', $leadState) }
    }
    $bindingId = Write-TelephoneJsonCreateNew -Path $paths.lead_binding -Value $leadBinding
    $requestPath = Join-Path $testRoot 'request.json'
    $request = [ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = $jobId
        project = 'audit-repair'
        stage = 'focused'
        role = 'execution'
        route = 'direct-cursor'
        summary = 'trusted-consumption-fixture'
        lead = $leadBinding
        command = [ordered]@{ executable = $pwsh; working_directory = $work; arguments = @('-NoLogo'); stdin = $null }
    }
    $null = Write-TelephoneJsonCreateNew -Path $requestPath -Value $request
    $requestId = Get-TelephoneFileIdentity -Path $requestPath
    $dispatch = [ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = $jobId
        project = 'audit-repair'
        stage = 'focused'
        role = 'execution'
        route = 'direct-cursor'
        summary = 'trusted-consumption-fixture'
        lead = $leadBinding
        command = [ordered]@{ executable = $pwsh; working_directory = $work; arguments = @('-NoLogo'); stdin = $null }
        source_request = $requestId
        lead_binding = $bindingId
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        absolute_task_timeout = $false
        project_judgment = $false
    }
    $dispatchId = Write-TelephoneJsonCreateNew -Path $paths.dispatch -Value $dispatch
    $receipt = [ordered]@{
        protocol_version = 'telephone-line-receipt-v1'
        line_job_id = $jobId
        project = 'audit-repair'
        stage = 'focused'
        role = 'execution'
        route = 'direct-cursor'
        summary = 'trusted-consumption-fixture'
        dispatch = $dispatchId
        transport_complete = $true
        command_exit_code = 0
        command_error_code = $null
        command_error_message = $null
        stdout = @{ path = (Join-Path $jobRoot 'out.txt'); bytes = 0; sha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' }
        stderr = @{ path = (Join-Path $jobRoot 'err.txt'); bytes = 0; sha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' }
        started_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        absolute_task_timeout = $false
        automatic_rerun = $false
        project_judgment = $false
    }
    [IO.File]::WriteAllText((Join-Path $jobRoot 'out.txt'), '', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $jobRoot 'err.txt'), '', [Text.UTF8Encoding]::new($false))
    $null = Write-TelephoneJsonCreateNew -Path $paths.receipt -Value $receipt
    $receiptRead = Read-TelephoneJson -Path $paths.receipt -SchemaName 'receipt'
    $wake = New-TelephoneWakeIdentity -LineJobId $jobId -ReceiptIdentity $receiptRead.identity -LeadSessionId $session
    Assert-Repair ([string]$wake.wake_run_id -ceq $runId) 'Wake run id drifted from telephone-{job}.'

    $relayError = [ordered]@{
        protocol_version = 'telephone-line-relay-error-v1'
        line_job_id = $jobId
        lead_session_id = $session
        retrying = $false
        error_code = 'LEAD_WAKE_FAILED'
        error_message = 'old failure'
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $null = Write-TelephoneJsonCreateNew -Path $paths.relay_error -Value $relayError
    $mailboxRef = [ordered]@{
        protocol_version = 'telephone-line-mailbox-ref-v1'
        lead_identity_sha256 = '59f66ca4e9d6cc27db865fb141f844289081bdbfeeb0d6cc14757b9485cbcf3d'
        batch_id = $jobId
        item_id = 'isolated-mailbox-item'
        item_path = (Join-Path $testRoot 'mailbox-item.json')
    }
    $null = Write-TelephoneJsonCreateNew -Path $paths.mailbox_ref -Value $mailboxRef

    $jobObj = [ordered]@{ paths = $paths; dispatch = $dispatch; lead = $leadBinding }
    Invoke-TelephoneSingleJobWake -Job $jobObj -ReceiptRead $receiptRead
    Assert-Repair (-not [IO.File]::Exists($paths.delivery)) 'Collector wrote delivery after no-PID UNKNOWN conflict.'
    Assert-Repair ([IO.File]::Exists($paths.relay_error)) 'Collector dropped relay-error after UNKNOWN conflict.'
    $relayAfter = (Read-TelephoneJson -Path $paths.relay_error).value
    Assert-Repair ([bool]$relayAfter.retrying) 'Coordinator did not keep retrying diagnostic for verified pre-turn failure.'
    Assert-Repair ([IO.Directory]::Exists((Join-Path $jobRoot 'relay-error.history'))) 'Original relay-error bytes were not preserved in history.'
    Assert-Repair (-not [IO.File]::Exists($paths.wake_launch_result)) 'UNKNOWN conflict wrote a launch-result as if accepted.'

    $self = Get-Process -Id $PID
    try {
        $liveOwner = [ordered]@{
            pid = [int]$PID
            start_time_utc_ticks = [int64]$self.StartTime.ToUniversalTime().Ticks
            started_at_utc = $self.StartTime.ToUniversalTime().ToString('o')
            executable_path = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
            session_id = $session
            run_id = $runId
        }
    } finally { $self.Dispose() }
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $conflictRoot 'writer-owner.json') -Value $liveOwner
    $aliveConflict = Test-TelephoneLeadPreTurnActiveWriterConflict -RunRoot $conflictRoot -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-Repair ([bool]$aliveConflict.writer_alive) 'Bound current writer was not treated as alive.'
    Assert-Repair (-not [bool]$aliveConflict.retry_eligible) 'Live bound writer was retry-eligible.'
    try {
        Invoke-TelephoneNamedWakeAttach -LaunchResultPath $paths.wake_launch_result -LauncherPath $dualLauncher -ExtraArguments @('-StateRootOverride', $leadState) -Worktree $work -PromptFile $prompt -SessionId $session -RunId $runId -WakeKey ([string]$wake.wake_key) -LineJobId $jobId
        throw 'Live writer was not fail-closed.'
    } catch {
        Assert-Repair ([string]$_.Exception.Message -ceq 'LEAD_WAKE_PRE_TURN_CONFLICT') 'Live writer did not throw LEAD_WAKE_PRE_TURN_CONFLICT.'
    }
    Assert-Repair (-not [IO.File]::Exists((Join-Path $jobRoot 'wake-retry.json'))) 'Live writer wrote a retry record.'

    [IO.File]::Delete((Join-Path $conflictRoot 'writer-owner.json'))
    $released = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'exit 0') -PassThru -WindowStyle Hidden
    $released.WaitForExit()
    $releasedOwner = [ordered]@{
        pid = [int]$released.Id
        start_time_utc_ticks = [int64]$released.StartTime.ToUniversalTime().Ticks
        started_at_utc = $released.StartTime.ToUniversalTime().ToString('o')
        executable_path = [string]$pwsh
        session_id = $session
        run_id = $runId
    }
    $released.Dispose()
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $conflictRoot 'writer-owner.json') -Value $releasedOwner
    $releasedConflict = Test-TelephoneLeadPreTurnActiveWriterConflict -RunRoot $conflictRoot -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-Repair ([string]$releasedConflict.writer_identity_status -ceq 'bound') 'Released writer-owner was not bound.'
    Assert-Repair (-not [bool]$releasedConflict.writer_alive) 'Dead bound writer was treated as alive.'
    Assert-Repair ([bool]$releasedConflict.retry_eligible) 'Released bound writer was not retry-eligible.'

    Invoke-TelephoneSingleJobWake -Job $jobObj -ReceiptRead $receiptRead
    Assert-Repair ([IO.File]::Exists($paths.delivery)) 'Collector did not write delivery after released-writer retry.'
    $delivery = (Read-TelephoneJson -Path $paths.delivery).value
    Assert-Repair ([string]$delivery.wake_key -ceq [string]$wake.wake_key) 'Delivery did not keep the original wake key.'
    Assert-Repair ([string]$delivery.wake_run_id -ceq [string]$wake.wake_run_id) 'Delivery replaced the immutable original wake run id.'
    Assert-Repair ([string]$delivery.attempt_run_id -ceq ($runId + '-retry-1')) 'Ack/delivery did not bind the retry attempt run id.'
    Assert-Repair ([string]$delivery.delivery_kind -ceq 'AUTOMATIC_WAKE_ACK') 'Retry delivery was not automatic wake ack.'
    $retryRoot = Join-Path $leadState ($runId + '-retry-1')
    Assert-Repair ([IO.File]::Exists((Join-Path $retryRoot 'lead-run.json'))) 'Retry did not write native lead-run.json.'
    $nativeMeta = (Read-TelephoneJson -Path (Join-Path $retryRoot 'lead-run.json')).value
    Assert-Repair ([string]$nativeMeta.protocol_version -ceq 'huhu-concerto-cli-lead-run-v1') 'Retry native metadata protocol drifted.'
    Assert-Repair ([string]$nativeMeta.run_id -ceq ($runId + '-retry-1')) 'Native metadata bound the original wake run instead of the attempt.'
    Assert-Repair ([IO.File]::Exists((Join-Path $retryRoot 'lead-wake-ack.json'))) 'Ack was not established for the retry attempt.'
    $ack = (Read-TelephoneJson -Path (Join-Path $retryRoot 'lead-wake-ack.json')).value
    Assert-Repair ([string]$ack.run_id -ceq ($runId + '-retry-1')) 'Canonical ack omitted the attempt run id.'
    $retryIndex = (Read-TelephoneJson -Path (Join-Path $jobRoot 'wake-retry.json')).value
    Assert-Repair ([string]$retryIndex.original_wake_run_id -ceq $runId) 'Retry index dropped the original wake run id.'
    Assert-Repair ([int]$retryIndex.current_attempt -eq 1) 'Retry index current attempt was not 1.'
    Assert-Repair ([IO.File]::Exists((Join-Path $jobRoot 'wake-attempts\attempt-1-intent.json'))) 'Attempt intent was not persisted.'
    Assert-Repair ([IO.File]::Exists((Join-Path $jobRoot 'wake-attempts\attempt-1-result.json'))) 'Attempt result was not persisted.'

    [IO.File]::Delete($paths.wake_launch_result)
    $reattach = Invoke-TelephoneNamedWakeAttach -LaunchResultPath $paths.wake_launch_result -LauncherPath $dualLauncher -ExtraArguments @('-StateRootOverride', $leadState) -Worktree $work -PromptFile $prompt -SessionId $session -RunId $runId -WakeKey ([string]$wake.wake_key) -LineJobId $jobId
    Assert-Repair ([string]$reattach.wake_run_id -ceq ($runId + '-retry-1') -or [string]$reattach.run_root -ceq $retryRoot) 'Lost launch-result did not reattach the accepted retry.'
    $turnText = ''
    if ([IO.File]::Exists($turnLog)) { $turnText = [IO.File]::ReadAllText($turnLog) }
    Assert-Repair ($turnText -match [regex]::Escape($runId + '-retry-1')) 'Retry-1 was not recorded as a model start.'
    Assert-Repair ($turnText -notmatch '-retry-2') 'Lost launch-result after accepted retry started retry-2.'

    $okLauncher = Join-Path $testRoot 'ok-exit.ps1'
    [IO.File]::WriteAllText($okLauncher, @'
param([string]$WorktreePath,[string]$PromptFile,[string]$ResumeSessionId,[string]$RunId,[string]$StateRootOverride)
$run = [IO.Path]::GetFullPath((Join-Path $StateRootOverride $RunId))
[IO.Directory]::CreateDirectory($run) | Out-Null
[ordered]@{ run_root = $run; state = "completed"; exit_code = 0 } | ConvertTo-Json -Compress
exit 0
'@, [Text.UTF8Encoding]::new($false))
    $okRun = 'ok-run-1'
    $launchOk = Invoke-TelephoneFrozenLeadLauncher -LauncherPath $okLauncher -ExtraArguments @('-StateRootOverride', $leadState) -Worktree $work -PromptFile $prompt -SessionId 'sess-ok' -RunId $okRun
    Assert-Repair (-not [string]::IsNullOrWhiteSpace([string]$launchOk.run_root)) 'Successful launcher lost run_root.'
    $stale = Get-TelephoneLastLeadLaunchDiagnostic
    Assert-Repair ($null -eq $stale) 'Stale pre-turn diagnostic reclassified a later success.'

    $evidence = [ordered]@{
        protocol_version = 'telephone-explicit-consumption-evidence-v1'
        kind = 'EXPLICIT_PASCAL_MANUAL_RECOVERY_EXISTING_ORIGINAL_LEAD'
        lead_session_id = $session
        wake_key = [string]$wake.wake_key
        original_wake_run_id = [string]$wake.wake_run_id
        automatic_callback_success = $false
        receipt = @{ sha256 = [string]$receiptRead.identity.sha256 }
    }
    $evidencePath = Join-Path $testRoot 'consumption.json'
    $null = Write-TelephoneJsonCreateNew -Path $evidencePath -Value $evidence
    $evidenceSha = [string](Get-TelephoneFileIdentity -Path $evidencePath).sha256
    $manualJob = Join-Path $testRoot 'jobs\manual-close'
    [IO.Directory]::CreateDirectory($manualJob) | Out-Null
    foreach ($name in @('dispatch.json', 'receipt.json', 'lead-binding.json', 'relay-error.json', 'mailbox-ref.json', 'out.txt', 'err.txt')) {
        $src = Join-Path $jobRoot $name
        if ([IO.File]::Exists($src)) { Copy-Item -LiteralPath $src -Destination (Join-Path $manualJob $name) -Force }
    }
    $manualPaths = Get-TelephoneJobPaths -JobRoot $manualJob
    $wrongEv = Complete-TelephoneTrustedManualConsumption -JobRoot $manualJob -ExpectedReceiptSha256 ([string]$receiptRead.identity.sha256) -ExpectedWakeKey ([string]$wake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $evidencePath -ExpectedEvidenceSha256 ('0' * 64)
    Assert-Repair (-not [bool]$wrongEv.ok) 'Wrong evidence SHA was accepted.'
    $selfClaim = [ordered]@{
        protocol_version = 'telephone-explicit-consumption-evidence-v1'
        kind = 'EXPLICIT_PASCAL_MANUAL_RECOVERY_EXISTING_ORIGINAL_LEAD'
        lead_session_id = $session
        wake_key = [string]$wake.wake_key
        automatic_callback_success = $false
        receipt = @{ sha256 = [string]$receiptRead.identity.sha256 }
        invented = $true
    }
    $selfPath = Join-Path $testRoot 'self-claim.json'
    $null = Write-TelephoneJsonCreateNew -Path $selfPath -Value $selfClaim
    $selfSha = [string](Get-TelephoneFileIdentity -Path $selfPath).sha256
    $selfReject = Complete-TelephoneTrustedManualConsumption -JobRoot $manualJob -ExpectedReceiptSha256 ([string]$receiptRead.identity.sha256) -ExpectedWakeKey ([string]$wake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $selfPath -ExpectedEvidenceSha256 $evidenceSha
    Assert-Repair (-not [bool]$selfReject.ok) 'Arbitrary matching self-claim was accepted as the authorized evidence identity.'
    $autoPath = Join-Path $testRoot 'auto-claim.json'
    $autoEvidence = [ordered]@{
        protocol_version = 'telephone-explicit-consumption-evidence-v1'
        kind = 'EXPLICIT_PASCAL_MANUAL_RECOVERY_EXISTING_ORIGINAL_LEAD'
        lead_session_id = $session
        wake_key = [string]$wake.wake_key
        automatic_callback_success = $true
        receipt = @{ sha256 = [string]$receiptRead.identity.sha256 }
    }
    $null = Write-TelephoneJsonCreateNew -Path $autoPath -Value $autoEvidence
    $autoSha = [string](Get-TelephoneFileIdentity -Path $autoPath).sha256
    $autoReject = Complete-TelephoneTrustedManualConsumption -JobRoot $manualJob -ExpectedReceiptSha256 ([string]$receiptRead.identity.sha256) -ExpectedWakeKey ([string]$wake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $autoPath -ExpectedEvidenceSha256 $autoSha -Execute
    Assert-Repair (-not [bool]$autoReject.ok) 'Automatic-callback claim was accepted as trusted consumption.'
    $dry = Complete-TelephoneTrustedManualConsumption -JobRoot $manualJob -ExpectedReceiptSha256 ([string]$receiptRead.identity.sha256) -ExpectedWakeKey ([string]$wake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $evidencePath -ExpectedEvidenceSha256 $evidenceSha
    Assert-Repair ([string]$dry.code -ceq 'DRY_RUN') 'Dry-run did not actually validate.'
    Assert-Repair ([string]$dry.reason -ceq 'validated_unexecuted') 'Dry-run did not report validated_unexecuted.'
    Assert-Repair (-not [IO.File]::Exists($manualPaths.delivery)) 'Dry-run wrote delivery.json.'
    $closed = Complete-TelephoneTrustedManualConsumption -JobRoot $manualJob -ExpectedReceiptSha256 ([string]$receiptRead.identity.sha256) -ExpectedWakeKey ([string]$wake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $evidencePath -ExpectedEvidenceSha256 $evidenceSha -Execute
    Assert-Repair ([bool]$closed.ok) 'Trusted consumption failed.'
    Assert-Repair ([IO.File]::Exists($manualPaths.delivery)) 'Delivery was not written before lifecycle closeout.'
    Assert-Repair ([bool]$closed.mailbox_closeout) 'Mailbox closeout was not written.'
    Assert-Repair ([IO.File]::Exists((Join-Path $manualJob 'mailbox-closeout.json'))) 'Mailbox closeout file missing.'
    Assert-Repair ([IO.File]::Exists($manualPaths.relay_error)) 'Old failure file was removed.'
    $repeat = Complete-TelephoneTrustedManualConsumption -JobRoot $manualJob -ExpectedReceiptSha256 ([string]$receiptRead.identity.sha256) -ExpectedWakeKey ([string]$wake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $evidencePath -ExpectedEvidenceSha256 $evidenceSha -Execute
    Assert-Repair ([string]$repeat.code -ceq 'ALREADY_CLOSED') 'Repeat consumption was not idempotent.'
    $wrongClosed = Complete-TelephoneTrustedManualConsumption -JobRoot $manualJob -ExpectedReceiptSha256 ([string]$receiptRead.identity.sha256) -ExpectedWakeKey ('1' * 64) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $evidencePath -ExpectedEvidenceSha256 $evidenceSha -Execute
    Assert-Repair (-not [bool]$wrongClosed.ok) 'ALREADY_CLOSED accepted a mismatched wake key.'

    $retryingPaths = Get-TelephoneJobPaths -JobRoot (Join-Path $testRoot 'jobs\retrying')
    [IO.Directory]::CreateDirectory($retryingPaths.root) | Out-Null
    $retryErr = [ordered]@{ protocol_version = 'telephone-line-relay-error-v1'; retrying = $true; error_code = 'LEAD_WAKE_PRE_TURN_CONFLICT' }
    $null = Write-TelephoneJsonCreateNew -Path $retryingPaths.relay_error -Value $retryErr
    Assert-Repair (-not (Test-TelephoneRelayErrorBlocksWait -JobPaths $retryingPaths)) 'Retrying pre-turn relay-error blocked wait.'

    $supRoot = Join-Path $testRoot 'supervisor'
    $runUuid = 'bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeee2'
    $supRequest = [ordered]@{
        protocol_version = 'telephone-line-wired-supervisor-request-v1'
        run_id = $runUuid
        request_sha256 = ('a' * 64)
        project = 'claimed-reconcile'
        stage = 'focused'
        lead_session_id = $session
        worktree = $work
        command = [ordered]@{ executable = $pwsh; working_directory = $work; arguments = @('-NoLogo') }
        installed_version = [ordered]@{ version_id = ('b' * 64); source_sha256 = ('b' * 64); install_root = $testRoot }
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $supRequest.request_sha256 = Get-TelephoneSupervisorRequestHash -Request $supRequest
    $null = Initialize-TelephoneSupervisorLayout -StateRoot $supRoot
    $claimedPath = Get-TelephoneSupervisorRecordPath -StateRoot $supRoot -Kind claimed -RunId $runUuid
    $null = Write-TelephoneJsonCreateNew -Path $claimedPath -Value $supRequest
    $reconciled = @(Reconcile-TelephoneSupervisorClaimed -StateRoot $supRoot)
    Assert-Repair ($reconciled.Count -eq 1) 'Claimed-without-owner was silently skipped.'
    Assert-Repair ([string]$reconciled[0].decision -ceq 'UNKNOWN') 'Ownerless claimed was treated as proven-not-started.'
    $outboxPath = Get-TelephoneSupervisorRecordPath -StateRoot $supRoot -Kind outbox -RunId $runUuid
    Assert-Repair (-not [IO.File]::Exists($outboxPath)) 'UNKNOWN claimed wrote a failed outbox.'
    Assert-Repair ([IO.File]::Exists($claimedPath)) 'UNKNOWN claimed deleted the claim.'
    $claimedReconcile = Join-Path $supRoot ('runs\' + $runUuid + '\claimed-reconcile.json')
    Assert-Repair ([IO.File]::Exists($claimedReconcile)) 'UNKNOWN claimed did not persist reconcile evidence.'

    $lineState = Join-Path $testRoot 'line-state'
    [IO.Directory]::CreateDirectory((Join-Path $lineState 'jobs')) | Out-Null
    $regJob = Register-TelephoneDashboardLineSource -LineStateRoot $lineState -LineJobId $jobId -Project 'audit-repair' -LeadSessionId $session -LeadRunId $runId -Route 'direct-cursor' -DashboardStateRoot $dashState
    Assert-Repair ([bool]$regJob.registered) 'Per-job line source was not registered.'
    $regRoot = Register-TelephoneDashboardLineSource -LineStateRoot $lineState -DashboardStateRoot $dashState
    Assert-Repair ([bool]$regRoot.registered) 'Root register failed.'
    $srcDoc = (Read-TelephoneJson -Path ([string]$regJob.path)).value
    $jobRows = @($srcDoc.sources | Where-Object { $_ -is [Collections.IDictionary] -and [string]$_['line_job_id'] -ceq $jobId })
    Assert-Repair ($jobRows.Count -eq 1) 'Root-only register deleted the per-job row.'
    $malformedPath = [string]$regJob.path
    [IO.File]::WriteAllText($malformedPath, '{not-json', [Text.UTF8Encoding]::new($false))
    $malReg = Register-TelephoneDashboardLineSource -LineStateRoot $lineState -LineJobId $jobId -Project 'audit-repair' -LeadSessionId $session -LeadRunId $runId -Route 'direct-cursor' -DashboardStateRoot $dashState
    Assert-Repair (-not [bool]$malReg.registered) 'Malformed sources were silently replaced with a healthy registry.'
    Assert-Repair ([IO.File]::Exists((Join-Path $dashState 'line-sources.malformed.json'))) 'Malformed sources were not preserved.'
    $null = Write-TelephoneJsonReplace -Path $malformedPath -Value ([ordered]@{
        protocol_version = 'telephone-line-dashboard-line-sources-v1'
        updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        last_success_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        last_read_error_at_utc = ''
        sources = @([ordered]@{
            state_root = $lineState
            line_job_id = $jobId
            project = 'audit-repair'
            lead_session_id = $session
            lead_run_id = $runId
            route = 'direct-cursor'
            registered_at_utc = [DateTimeOffset]::UtcNow.AddSeconds(-400).ToString('o')
        })
    })
    $watchScript = Join-Path $repoRoot 'src\dashboard\Watch-TelephoneDashboard.ps1'
    $watchProc = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $watchScript, '-StateRoot', $dashState, '-Headless', '-Once') -Wait -PassThru -WindowStyle Hidden
    $watchCode = [int]$watchProc.ExitCode
    $watchProc.Dispose()
    Assert-Repair ($watchCode -eq 0) ('Isolated Watch -StateRoot -Headless -Once EXIT' + [string]$watchCode)
    Assert-Repair ([IO.File]::Exists((Join-Path $dashState 'projection.json'))) 'Watch did not publish projection.'
    $afterWatch = (Read-TelephoneJson -Path $malformedPath).value
    Assert-Repair (-not [string]::IsNullOrWhiteSpace([string]$afterWatch.last_success_at_utc)) 'Watch success did not record last_success.'
    $projection = Get-TelephoneDashboardProjection -DashboardStateRoot $dashState
    Assert-Repair (-not [bool]$projection.source_stale) 'Healthy job was marked source_stale from registration age.'
    $jsonText = (($projection | ConvertTo-Json -Depth 32).Replace("`r`n", "`n") + "`n")
    Assert-TelephoneJsonSchema -JsonText $jsonText -SchemaName 'dashboard-projection' -Label 'audit-repair projection'
    $summary = Format-TelephoneDashboardSummary -Projection $projection
    Assert-Repair ($summary -match 'Truth: stale=') 'Summary did not share timestamp truth with projection.'

    $liveJob = [ordered]@{
        job_id = $jobId
        job_root = $jobRoot
        command_alive = $false
        relay_alive = $false
        delivery = $false
        receipt = [ordered]@{ present = $true; valid = $true }
        findings = @([ordered]@{ code = 'RECEIPT_AWAITING_DELIVERY'; severity = 'info' })
        direct_route = $true
    }
    $hiddenLive = Test-TelephoneDashboardDirectHistoryRetired -Job $liveJob -AllJobs @($liveJob) -Descriptor ([ordered]@{ project = 'audit-repair'; successor_line_job_id = 'cccccccc-bbbb-cccc-dddd-eeeeeeeeeee3' }) -DirectByJobId @{} -ProofJobIds @('cccccccc-bbbb-cccc-dddd-eeeeeeeeeee3') -ProofDirectSessions @('other')
    Assert-Repair (-not [bool]$hiddenLive) 'Receipt-awaiting live job was hidden by history/retired.'
    Assert-Repair (Test-TelephoneDashboardJobMustRemainVisible -Job $liveJob) 'Receipt-awaiting job was not marked remain-visible.'
    $unknownJob = [ordered]@{
        job_id = 'dddddddd-bbbb-cccc-dddd-eeeeeeeeeee4'
        job_root = (Join-Path $testRoot 'jobs\unknown')
        command_alive = $false
        relay_alive = $false
        delivery = $false
        receipt = [ordered]@{ present = $false; valid = $false }
        findings = @([ordered]@{ code = 'UNKNOWN'; severity = 'fail_closed' })
        direct_route = $true
    }
    Assert-Repair (Test-TelephoneDashboardJobMustRemainVisible -Job $unknownJob) 'UNKNOWN job without a live process was hidden.'

    $showPath = Join-Path $repoRoot '_audit_correction1_artifacts_20260909\private-candidate\cockpit\Show-PascalGlobalAutopilotStatus.ps1'
    $showText = [IO.File]::ReadAllText($showPath)
    $cut = $showText.IndexOf('if ($LibraryOnly) { return }')
    $start = $showText.IndexOf('$script:ThreadIdCache')
    Assert-Repair (($cut -gt 0) -and ($start -gt 0) -and ($cut -gt $start)) 'Show library marker was missing.'
    Invoke-Expression $showText.Substring($start, ($cut - $start))
    $directId = 'eeeeeeee-bbbb-cccc-dddd-eeeeeeeeeee5'
    $directRoot = Join-Path $testRoot ('direct-jobs\' + $directId)
    [IO.Directory]::CreateDirectory($directRoot) | Out-Null
    $directRequest = [ordered]@{
        protocol_version = 'telephone-line-direct-cursor-request-v1'
        job_id = $directId
        workspace = $work
    }
    [IO.File]::WriteAllText((Join-Path $directRoot 'request.json'), (($directRequest | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    $dispatchForMap = $dispatch | ConvertTo-Json -Depth 16 | ConvertFrom-Json
    $projectOkObj = [pscustomobject]@{
        current_line_job_id = $jobId
        current_direct_job_id = $directId
        current_direct_job_root = $directRoot
        dispatch_project_id = 'audit-repair'
        id = 'other-id'
        lead_thread_id = $session
        worktree = $work
    }
    $bindOk = Get-StatusRegisteredDirectBinding -Dispatch $dispatchForMap -Project $projectOkObj
    Assert-Repair ($null -ne $bindOk) 'Correct session/workspace/job alias mapping was rejected.'
    $projectWrongObj = [pscustomobject]@{
        current_line_job_id = $jobId
        current_direct_job_id = $directId
        current_direct_job_root = $directRoot
        dispatch_project_id = 'audit-repair'
        id = 'other-id'
        lead_thread_id = 'wrong-session'
        worktree = $work
    }
    $bindWrong = Get-StatusRegisteredDirectBinding -Dispatch $dispatchForMap -Project $projectWrongObj
    Assert-Repair ($null -eq $bindWrong) 'Wrong session was accepted by global mapping.'

    $reproCollection = Join-Path $testRoot 'repro-collection.json'
    [IO.File]::WriteAllText($reproCollection, "{`"repro`":`"8201ad6c-empty-session`"}`n", [Text.UTF8Encoding]::new($false))
    $reproSha = Get-RepairSha256 -Path $reproCollection
    $reproProject = [pscustomobject]@{
        registry_status = 'ACTIVE'
        current_state = 'COLLECTED_ROOT_DECISION_PENDING'
        current_collection_path = $reproCollection
        current_collection_sha256 = $reproSha
        current_stage = 'correction-1'
        ordinary_acceptance = 'INCOMPLETE_NOT_ACCEPTABLE_FOR_FINAL_REVIEW'
        current_final_review_packet_path = ''
        current_final_review_packet_sha256 = ''
    }
    $reproAcceptance = Get-StatusAcceptanceResponsibility -Project $reproProject -CollectionMatched $true
    Assert-Repair ([string]$reproAcceptance.code -ceq 'correction_active') ('R3 repro did not bind correction owner: ' + [string]$reproAcceptance.code)
    Assert-Repair ([string]$reproAcceptance.flow_label -notmatch 'Root') 'R3 repro still named Root as acceptor.'
    Assert-Repair ([string]$reproAcceptance.owner -ceq '原 Lead') 'R3 repro owner was not the original Lead.'
    Assert-Repair ([string]$reproAcceptance.flow_label -match '修正') 'R3 repro did not say correction was in progress.'
    $leadWaitProject = [pscustomobject]@{
        registry_status = 'ACTIVE'
        current_state = 'COLLECTED_ROOT_DECISION_PENDING'
        current_collection_path = $reproCollection
        current_collection_sha256 = $reproSha
        current_stage = 'executor-receipt'
        ordinary_acceptance = ''
        current_final_review_packet_path = ''
        current_final_review_packet_sha256 = ''
    }
    $leadWait = Get-StatusAcceptanceResponsibility -Project $leadWaitProject -CollectionMatched $true
    Assert-Repair ([string]$leadWait.code -ceq 'awaiting_lead_engineering') 'Executor receipt was not mapped to original Lead engineering acceptance.'
    Assert-Repair ([string]$leadWait.flow_label -notmatch 'Root') 'Executor receipt still named Root.'
    $packetPath = Join-Path $testRoot 'FINAL_REVIEW_PACKET.md'
    [IO.File]::WriteAllText($packetPath, "isolated packet`n", [Text.UTF8Encoding]::new($false))
    $packetSha = Get-RepairSha256 -Path $packetPath
    $packetProject = [pscustomobject]@{
        registry_status = 'ACTIVE'
        current_state = 'COLLECTED_ROOT_DECISION_PENDING'
        current_collection_path = $reproCollection
        current_collection_sha256 = $reproSha
        current_stage = 'final-review'
        ordinary_acceptance = 'accepted'
        current_final_review_packet_path = $packetPath
        current_final_review_packet_sha256 = $packetSha
    }
    $packetGroup = [pscustomobject]@{
        current_run = [pscustomobject]@{
            owner_alive = $false
            protocol_ok = $true
            final_exists = $true
            final_failed = $false
        }
    }
    $maxWait = Get-StatusAcceptanceResponsibility -Project $packetProject -Group $packetGroup -CollectionMatched $true
    Assert-Repair ([string]$maxWait.code -ceq 'awaiting_pascal_max') 'Ready packet plus Lead terminal was not mapped to Pascal Max.'
    Assert-Repair ([string]$maxWait.owner -ceq 'Pascal') 'Pascal was not the Max-review owner.'
    Assert-Repair ([string]$maxWait.flow_label -match 'Max') 'Pascal Max review label was missing.'

    $wrapperDir = Join-Path $testRoot 'wrapper-owner\src\supervisor'
    [IO.Directory]::CreateDirectory($wrapperDir) | Out-Null
    $targetName = 'Start-TelephoneSupervisorHostVisible.ps1'
    $targetScript = Join-Path $wrapperDir $targetName
    [IO.File]::WriteAllText($targetScript, "# isolated wrapper target`n", [Text.UTF8Encoding]::new($false))
    $exe = Join-Path $wrapperDir 'SupervisorNoConsoleHost.exe'
    $exeBytes = [Collections.Generic.List[byte]]::new()
    foreach ($b in [byte[]](77, 90, 0, 0)) { [void]$exeBytes.Add($b) }
    foreach ($b in [Text.Encoding]::UTF8.GetBytes($targetName)) { [void]$exeBytes.Add($b) }
    [IO.File]::WriteAllBytes($exe, [byte[]]$exeBytes)
    $exeSha = Get-RepairSha256 -Path $exe
    $installRoot = [IO.Path]::GetFullPath((Join-Path $testRoot 'wrapper-owner'))
    $sidecar = Join-Path $wrapperDir 'wrapper-identity.json'
    $null = Write-TelephoneJsonCreateNew -Path $sidecar -Value ([ordered]@{
        protocol_version = 'telephone-line-supervisor-wrapper-identity-v1'
        install_root = $installRoot
        wrapper_path = $exe
        sha256 = $exeSha
        target_script = $targetScript
        working_directory = $installRoot
    })
    $owned = Get-TelephoneSupervisorInstallRootFromWrapperIdentity -ActionScript $exe
    Assert-Repair ($owned.Equals($installRoot, [StringComparison]::OrdinalIgnoreCase)) 'Verified wrapper identity did not resolve install root.'
    $hashOnly = Join-Path $testRoot 'wrapper-hash-only\src\supervisor'
    [IO.Directory]::CreateDirectory($hashOnly) | Out-Null
    $hashExe = Join-Path $hashOnly 'SupervisorNoConsoleHost.exe'
    [IO.File]::WriteAllBytes($hashExe, [byte[]](77, 90, 1, 2, 3, 4))
    $hashSidecar = Join-Path $hashOnly 'wrapper-identity.json'
    $null = Write-TelephoneJsonCreateNew -Path $hashSidecar -Value ([ordered]@{
        protocol_version = 'telephone-line-supervisor-wrapper-identity-v1'
        install_root = [IO.Path]::GetFullPath((Join-Path $testRoot 'wrapper-hash-only'))
        wrapper_path = $hashExe
        sha256 = (Get-RepairSha256 -Path $hashExe)
    })
    $hashOwned = Get-TelephoneSupervisorInstallRootFromWrapperIdentity -ActionScript $hashExe
    Assert-Repair ([string]::IsNullOrWhiteSpace($hashOwned)) 'Hash-only sidecar without target/bytes bind was accepted.'
    $foreignExe = Join-Path $testRoot 'foreign-host.exe'
    [IO.File]::WriteAllBytes($foreignExe, [byte[]](77, 90, 9, 9))
    $filenameOnly = Get-TelephoneSupervisorInstallRootFromActionScript -ActionScript $foreignExe
    Assert-Repair ([string]::IsNullOrWhiteSpace($filenameOnly)) 'Filename-only EXE bypassed wrapper identity.'
    $bareNamed = Join-Path $testRoot 'SupervisorNoConsoleHost.exe'
    [IO.File]::WriteAllBytes($bareNamed, [byte[]](77, 90, 8, 8))
    $bareRoot = Get-TelephoneSupervisorInstallRootFromActionScript -ActionScript $bareNamed
    Assert-Repair ([string]::IsNullOrWhiteSpace($bareRoot)) 'SupervisorNoConsoleHost.exe filename alone resolved an install root.'

    $realWrapperCopy = Join-Path $repoRoot '_audit_correction1_artifacts_20260909\private-candidate\wrapper\SupervisorNoConsoleHost.exe'
    $realSidecar = $realWrapperCopy + '.identity.json'
    Assert-Repair ([IO.File]::Exists($realWrapperCopy)) 'Real wrapper EXE copy was missing from the correction artifact.'
    Assert-Repair ([IO.File]::Exists($realSidecar)) 'Real wrapper sidecar was missing.'
    $expectedLiveRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'TelephoneLine'))
    $realOwned = Get-TelephoneSupervisorInstallRootFromWrapperIdentity -ActionScript $realWrapperCopy
    Assert-Repair ($realOwned.Equals($expectedLiveRoot, [StringComparison]::OrdinalIgnoreCase)) ('Real wrapper identity did not bind install root: [' + [string]$realOwned + ']')
    $wrapperParseOut = Join-Path $repoRoot '_audit_correction1_artifacts_20260909\wrapper-parse.raw.txt'
    [IO.File]::WriteAllText($wrapperParseOut, ((([ordered]@{
        parsed_install_root = [string]$realOwned
        expected_install_root = $expectedLiveRoot
        bound = (-not [string]::IsNullOrWhiteSpace([string]$realOwned))
        filename_alone = [string]$bareRoot
        wrapper_copy = $realWrapperCopy
        sidecar = $realSidecar
    } | ConvertTo-Json -Compress) + "`n")), [Text.UTF8Encoding]::new($false))

    $foreignSup = Join-Path $testRoot 'foreign-supervisor'
    [IO.Directory]::CreateDirectory($foreignSup) | Out-Null
    $marker = Join-Path $foreignSup 'FOREIGN.txt'
    [IO.File]::WriteAllText($marker, 'do-not-recycle', [Text.UTF8Encoding]::new($false))
    $ourInstall = Join-Path $testRoot 'our-install'
    [IO.Directory]::CreateDirectory((Join-Path $ourInstall 'src\supervisor')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $ourInstall 'src\supervisor\Invoke-TelephoneSupervisor.ps1'), "# isolated`n", [Text.UTF8Encoding]::new($false))
    $manifest = [ordered]@{
        protocol_version = 'telephone-line-install-manifest-v1'
        product_id = 'telephone-line'
        install_root = '.'
        source_identity = @{ path = $repoRoot; bytes = 1; sha256 = ('c' * 64) }
        path_appended = $false
        files = @()
    }
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $ourInstall 'install-manifest.json') -Value $manifest
    $taskStore = Join-Path $testRoot 'task-store'
    [IO.Directory]::CreateDirectory($taskStore) | Out-Null
    $taskBound = Join-Path $testRoot 'task-bound-supervisor'
    [IO.Directory]::CreateDirectory($taskBound) | Out-Null
    $ownTask = [ordered]@{
        task_name = 'TelephoneLineWiredSupervisor'
        registered = $true
        install_root = $ourInstall
        action_script = (Join-Path $ourInstall 'src\supervisor\Invoke-TelephoneSupervisor.ps1')
        action_arguments = '-InstallRoot "' + $ourInstall + '" -StateRoot "' + $taskBound + '"'
    }
    [IO.File]::WriteAllText((Join-Path $taskStore 'task.json'), (($ownTask | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $env:TELEPHONE_LINE_TASK_BACKEND = (Join-Path $repoRoot 'tests\supervisor\fixtures\mock-scheduler.ps1')
    $env:TELEPHONE_LINE_TASK_STORE = $taskStore
    $env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT = $foreignSup
    $ourState = Join-Path $testRoot 'our-state'
    [IO.Directory]::CreateDirectory($ourState) | Out-Null
    $env:TELEPHONE_LINE_STATE_ROOT = $ourState
    $gate = Test-TelephoneSupervisorTaskAvailableForInstallRoot -InstallRoot $ourInstall
    Assert-Repair ([bool]$gate.registered) 'Own mock task was not seen as registered.'
    Assert-Repair ([bool]$gate.available) 'Own mock task was not treated as owned.'
    $unForeign = Invoke-TelephoneLineUninstall -InstallRoot $ourInstall -RemoveState
    Assert-Repair ([string]$unForeign.code -ceq 'SUPERVISOR_STATE_FOREIGN') ('Own task + foreign env was not refused: ' + [string]$unForeign.code)
    Assert-Repair ([IO.File]::Exists($marker)) 'Foreign supervisor state was recycled despite refusal.'
    Assert-Repair ([IO.File]::Exists((Join-Path $ourInstall 'install-manifest.json'))) 'Install was uninstalled after foreign-state refusal.'

    [IO.File]::Delete((Join-Path $taskStore 'task.json'))
    $env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT = $foreignSup
    $unAbsent = Invoke-TelephoneLineUninstall -InstallRoot $ourInstall -RemoveState
    Assert-Repair ([IO.File]::Exists($marker)) 'Absent task recycled foreign supervisor state.'
    Assert-Repair ([bool]$unAbsent.ok -or [string]$unAbsent.code -cin @('UNINSTALLED', 'UNMANAGED_CONTENT_REMAINS', 'ALREADY_CURRENT')) ('Absent-task uninstall unexpected code: ' + [string]$unAbsent.code)

    $defaults = Get-Content -LiteralPath (Join-Path $repoRoot '_audit_correction1_artifacts_20260909\private-candidate\defaults\TELEPHONE_NEW_LEAD_DEFAULTS.json') -Raw | ConvertFrom-Json
    Assert-Repair ([string]$defaults.codex_command -match 'telephone-cli\\0\.153\.4-fd4c151a\\codex\.exe') 'Isolated defaults still named the deleted App path.'
    Assert-Repair ([string]$defaults.model -ceq 'gpt-6-astra') 'Defaults model policy drifted.'
    Assert-Repair ([string]$defaults.reasoning_effort -ceq 'high') 'Defaults effort policy drifted.'
    Assert-Repair ([string]$defaults.service_tier -ceq 'default') 'Defaults service policy drifted.'
    Assert-Repair ([string]$defaults.default_executor_route -ceq 'direct-cursor') 'Defaults route policy drifted.'

    $tutu = Get-Content -LiteralPath (Join-Path $repoRoot '_audit_correction1_artifacts_20260909\private-candidate\tutu\scripts\New-TutuPiDirectCursorDispatch.ps1') -Raw
    Assert-Repair ($tutu -match 'pending_registered_task_is_not_success') 'Tutu dispatch still equated pending task with success.'
    Assert-Repair ($tutu -match 'success = \$false') 'Tutu dispatch result lacked explicit non-success.'

    $tutuIso = Join-Path $testRoot 'tutu-iso'
    [IO.Directory]::CreateDirectory((Join-Path $tutuIso 'scripts')) | Out-Null
    foreach ($name in @('TutuPi.Common.ps1', 'Invoke-TutuPiCodexHost.ps1', 'Start-TutuPiCodexLead.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repoRoot ('_audit_correction1_artifacts_20260909\private-candidate\tutu\scripts\' + $name)) -Destination (Join-Path $tutuIso ('scripts\' + $name)) -Force
    }
    $tutuHome = Join-Path $tutuIso 'codex-home'
    [IO.Directory]::CreateDirectory($tutuHome) | Out-Null
    [IO.File]::WriteAllText((Join-Path $tutuHome 'config.toml'), "[features.context_management]`nexperimental_mode = true`n", [Text.UTF8Encoding]::new($false))
    $accountId = 'isolated-pi-account'
    [IO.File]::WriteAllText((Join-Path $tutuHome 'auth.json'), ('{"account_id":"' + $accountId + '"}' + "`n"), [Text.UTF8Encoding]::new($false))
    [IO.Directory]::CreateDirectory((Join-Path $tutuIso 'state\lead')) | Out-Null
    $pinSha = (([Security.Cryptography.SHA256]::Create().ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($accountId)) | ForEach-Object { $_.ToString('x2') }) -join '')
    $pinDoc = [ordered]@{
        protocol_version = 'tutu-pi-account-pin-v1'
        account_id_sha256 = $pinSha
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText((Join-Path $tutuIso 'state\lead\account-pin.json'), (($pinDoc | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    $failCmd = $pwsh
    $piWork = Join-Path $tutuIso 'work'
    [IO.Directory]::CreateDirectory($piWork) | Out-Null
    $piRun = Join-Path $tutuIso 'state\lead\runs\pi-fail-1'
    [IO.Directory]::CreateDirectory($piRun) | Out-Null
    $piPrompt = Join-Path $tutuIso 'prompt.md'
    [IO.File]::WriteAllText($piPrompt, "isolated pi failure`n", [Text.UTF8Encoding]::new($false))
    $hostProc = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tutuIso 'scripts\Invoke-TutuPiCodexHost.ps1'), '-CodexCommand', $failCmd, '-PromptFile', $piPrompt, '-RunRoot', $piRun, '-WorktreePath', $piWork, '-ReferenceAuthPath', (Join-Path $tutuHome 'auth.json')) -Wait -PassThru -WindowStyle Hidden
    $hostCode = [int]$hostProc.ExitCode
    $hostProc.Dispose()
    Assert-Repair ([IO.File]::Exists((Join-Path $piRun 'codex.stderr.log'))) 'Isolated PI host did not persist stderr.'
    $piStderr = [IO.File]::ReadAllText((Join-Path $piRun 'codex.stderr.log'))
    Assert-Repair (-not [string]::IsNullOrWhiteSpace($piStderr)) 'Isolated PI host dropped original stderr.'
    Assert-Repair ([IO.File]::Exists((Join-Path $piRun 'result.json'))) 'Isolated PI host did not write result.json.'
    $piResult = Get-Content -LiteralPath (Join-Path $piRun 'result.json') -Raw | ConvertFrom-Json
    Assert-Repair ([int]$piResult.exit_code -ne 0) 'Isolated PI host did not preserve failed exit.'
    Assert-Repair ($hostCode -ne 0) 'Isolated PI host process did not fail closed.'
    Assert-Repair ([string]$piResult.stderr.Length -gt 0 -or $piStderr.Length -gt 0) 'Isolated PI result dropped stderr semantics.'

    $drainLife = Join-Path $testRoot 'drain-lifecycle.json'
    $drainSleeper = Join-Path $testRoot 'drain-sleep.ps1'
    [IO.File]::WriteAllText($drainSleeper, "Start-Sleep -Seconds 6`n", [Text.UTF8Encoding]::new($false))
    $drainDriver = Join-Path $testRoot 'drain-driver.ps1'
    [IO.File]::WriteAllText($drainDriver, @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
. '$($repoRoot.Replace('''', ''''''))\src\core\TelephoneLine.Common.ps1'
Invoke-TelephoneLeadDrainedProcess -FileName '$($pwsh.Replace('''', ''''''))' -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','$($drainSleeper.Replace('''', ''''''))') -WorkingDirectory '$($testRoot.Replace('''', ''''''))' -LifecyclePath '$($drainLife.Replace('''', ''''''))' | Out-Null
"@, [Text.UTF8Encoding]::new($false))
    $drainProc = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $drainDriver) -PassThru -WindowStyle Hidden
    $sawRunning = Wait-RepairPath -Path $drainLife -Milliseconds 8000 -Probe {
        $doc = Get-Content -LiteralPath $drainLife -Raw | ConvertFrom-Json
        return -not [bool]$doc.process_exited -and [int]$doc.pid -gt 0
    }
    Assert-Repair ([bool]$sawRunning) 'Drain lifecycle was not observable while the host was still running.'
    $null = $drainProc.WaitForExit(20000)
    $drainProc.Dispose()
    $lifeFinal = Get-Content -LiteralPath $drainLife -Raw | ConvertFrom-Json
    Assert-Repair ([bool]$lifeFinal.process_exited) 'Drain lifecycle never recorded process exit.'
    Assert-Repair ([int]$lifeFinal.pid -gt 0) 'Drain lifecycle lost pid identity.'

    $supIso = Join-Path $testRoot 'supervisor-iso'
    $null = Initialize-TelephoneSupervisorLayout -StateRoot $supIso
    $markerDir = Join-Path $testRoot 'sup-marker'
    [IO.Directory]::CreateDirectory($markerDir) | Out-Null
    $supRunId = 'ffffffff-bbbb-cccc-dddd-eeeeeeeeeee6'
    $leadFix = Join-Path $repoRoot 'tests\supervisor\fixtures\mock-wired-lead.ps1'
    $supReq = [ordered]@{
        protocol_version = 'telephone-line-wired-supervisor-request-v1'
        run_id = $supRunId
        project = 'correction1-entry'
        stage = 'focused'
        lead_session_id = $session
        lead_run_id = ('run-' + $supRunId)
        summary = 'isolated supervisor-owned initial run'
        worktree = $testRoot
        command = [ordered]@{
            executable = $pwsh
            working_directory = $testRoot
            arguments = @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', $leadFix, '-StateRoot', $supIso, '-RunId', $supRunId,
                '-MarkerDirectory', $markerDir, '-HoldMilliseconds', '200', '-ExitImmediately'
            )
        }
        installed_version = [ordered]@{
            version_id = ('d' * 64)
            source_sha256 = ('d' * 64)
            install_root = $repoRoot
        }
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $supReq['request_sha256'] = Get-TelephoneSupervisorRequestHash -Request $supReq
    $env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT = $supIso
    $env:TELEPHONE_LINE_INSTALL_ROOT = $repoRoot
    $published = Publish-TelephoneSupervisorInbox -StateRoot $supIso -Request $supReq
    Assert-Repair ([bool]$published.published) 'Supervisor inbox publish failed.'
    $supInfo = [Diagnostics.ProcessStartInfo]::new()
    $supInfo.FileName = $pwsh
    $supInfo.UseShellExecute = $false
    $supInfo.RedirectStandardOutput = $true
    $supInfo.RedirectStandardError = $true
    $supInfo.CreateNoWindow = $true
    foreach ($arg in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repoRoot 'src\supervisor\Invoke-TelephoneSupervisor.ps1'), '-InstallRoot', $repoRoot, '-StateRoot', $supIso)) {
        [void]$supInfo.ArgumentList.Add([string]$arg)
    }
    $supProc = [Diagnostics.Process]::Start($supInfo)
    $supOut = $supProc.StandardOutput.ReadToEnd()
    $supErr = $supProc.StandardError.ReadToEnd()
    if (-not $supProc.WaitForExit(120000)) {
        try { $supProc.Kill() } catch { }
        throw 'Isolated supervisor process did not exit within 120s.'
    }
    $supProc.Dispose()
    $null = $supOut
    $null = $supErr
    $intentPath = Join-Path $supIso ('runs\' + $supRunId + '\host-start-intent.json')
    $launchIntentPath = Join-Path $supIso ('runs\' + $supRunId + '\launch-intent.json')
    Assert-Repair (Wait-RepairPath -Path $intentPath -Milliseconds 20000) 'Supervisor process did not persist host-start-intent.'
    Assert-Repair (Wait-RepairPath -Path $launchIntentPath -Milliseconds 20000) 'Run host did not persist launch-intent.'
    $launchIntent = (Read-TelephoneJson -Path $launchIntentPath).value
    Assert-Repair ([int]$launchIntent.pid -gt 0) 'Launch intent lacked pid.'
    Assert-Repair (-not [string]::IsNullOrWhiteSpace([string]$launchIntent.executable_path)) 'Launch intent lacked executable_path.'

    $isoJobSrc = 'C:\Users\Pascal\Documents\Codex\2026-08-16\pascal-master-task-20260816\control\handoffs\MASTER_SECRETARY_SUCCESSOR_REVIEW_20260907\new-secretary\telephone-public-onboarding-repair-20260909\product-hardening\state\telephone-line\jobs\315730a2-2619-4529-bd7e-9758eb2c68b1'
    $isoJob = Join-Path $testRoot 'isolated-job-315730a2'
    [IO.Directory]::CreateDirectory($isoJob) | Out-Null
    foreach ($name in @('dispatch.json', 'receipt.json', 'mailbox-ref.json', 'relay-error.json')) {
        Copy-Item -LiteralPath (Join-Path $isoJobSrc $name) -Destination (Join-Path $isoJob $name) -Force
    }
    $origEvidence = 'C:\Users\Pascal\Documents\Codex\2026-08-16\pascal-master-task-20260816\control\handoffs\MASTER_SECRETARY_SUCCESSOR_REVIEW_20260907\new-secretary\telephone-public-onboarding-repair-20260909\product-hardening\audit-driven-repair-20260909\ORIGINAL_RECEIPT_CONSUMPTION.json'
    $origEvidenceSha = [string](Get-TelephoneFileIdentity -Path $origEvidence).sha256
    $isoDry = Complete-TelephoneTrustedManualConsumption -JobRoot $isoJob -ExpectedReceiptSha256 '68cfb7560ba403a420004182ce5b1b8bc26a71a21e071b8f1c529498eb479c3c' -ExpectedWakeKey '3e3850e977361de93e2deb0ed8ae55ed3c14c275ed31def12eb7b38fafdfa51a' -ExpectedLeadSessionId $session -ConsumptionEvidencePath $origEvidence -ExpectedEvidenceSha256 $origEvidenceSha
    Assert-Repair ([string]$isoDry.code -ceq 'DRY_RUN') 'Copied real job dry-run did not validate.'
    $isoExec = Complete-TelephoneTrustedManualConsumption -JobRoot $isoJob -ExpectedReceiptSha256 '68cfb7560ba403a420004182ce5b1b8bc26a71a21e071b8f1c529498eb479c3c' -ExpectedWakeKey '3e3850e977361de93e2deb0ed8ae55ed3c14c275ed31def12eb7b38fafdfa51a' -ExpectedLeadSessionId $session -ConsumptionEvidencePath $origEvidence -ExpectedEvidenceSha256 $origEvidenceSha -Execute
    Assert-Repair ([bool]$isoExec.ok) 'Copied real job trusted consumption failed.'
    Assert-Repair ([IO.File]::Exists((Join-Path $isoJob 'mailbox-closeout.json'))) 'Copied real job lacked mailbox closeout.'
    Assert-Repair ([IO.File]::Exists((Join-Path $isoJob 'relay-error.json'))) 'Copied real job failure bytes were not preserved.'
    Assert-Repair (-not [IO.File]::Exists((Join-Path $isoJobSrc 'delivery.json'))) 'Isolated consumption mutated the live job.'

    . (Join-Path $repoRoot 'src\adapters\direct-cursor\DirectCursor.Common.ps1')
    $frozenSession = 'dc5b8047-c25d-4a9d-abef-0a83fb09556a'
    $emptyGate = Test-DirectCursorFollowUpSessionGate -RequestedSessionId $frozenSession -ReturnedSessionId ''
    Assert-Repair (-not [bool]$emptyGate.reject) 'Empty returned session was treated as a frozen-session mismatch.'
    $matchGate = Test-DirectCursorFollowUpSessionGate -RequestedSessionId $frozenSession -ReturnedSessionId $frozenSession
    Assert-Repair ([bool]$matchGate.returned_verified) 'Matching returned session was not verified.'
    $wrongGate = Test-DirectCursorFollowUpSessionGate -RequestedSessionId $frozenSession -ReturnedSessionId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    Assert-Repair ([bool]$wrongGate.reject) 'Genuine returned-session mismatch was not rejected.'

    $adapterIso = Join-Path $testRoot 'adapter-iso'
    $adapterWork = Join-Path $adapterIso 'workspace'
    $adapterState = Join-Path $adapterIso 'direct-state'
    $fakeAgent = Join-Path $adapterIso 'fake-cursor-agent'
    $fakeVer = Join-Path $fakeAgent 'versions\iso-fail'
    foreach ($d in @($adapterWork, $adapterState, $fakeVer)) { [IO.Directory]::CreateDirectory($d) | Out-Null }
    [IO.File]::WriteAllText((Join-Path $adapterWork 'keep.txt'), "isolated`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fakeAgent 'cursor-agent.ps1'), "# isolated fake cursor-agent wrapper`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fakeVer 'index.js'), "process.stderr.write('unused-index\n'); process.exit(7);`n", [Text.UTF8Encoding]::new($false))
    $nodeExe = Join-Path $fakeVer 'node.exe'
    $nodeCode = @'
using System;
public static class IsolatedAdapterFailNode {
    public static int Main(string[] args) {
        string joined = string.Join(" ", args);
        if (joined.IndexOf("--version", StringComparison.Ordinal) >= 0) {
            Console.Out.WriteLine("2026.1.0");
            return 0;
        }
        if (joined.IndexOf("models", StringComparison.Ordinal) >= 0) {
            Console.Out.WriteLine("cursor-grok-4.6-xhigh - Grok 4.6");
            return 0;
        }
        Console.Out.WriteLine("{\"type\":\"system\"}");
        Console.Error.WriteLine("ISOLATED_ADAPTER_FAILURE_MARKER");
        Console.Error.Write(new string('x', 4096));
        Console.Error.WriteLine();
        return 7;
    }
}
'@
    $compiledDir = Join-Path $env:LOCALAPPDATA 'Temp'
    [IO.Directory]::CreateDirectory($compiledDir) | Out-Null
    $compiled = Join-Path $compiledDir ('telephone-iso-node-' + [Guid]::NewGuid().ToString('N') + '.exe')
    $prevTmp = $env:TMP
    $prevTemp = $env:TEMP
    try {
        $env:TMP = $compiledDir
        $env:TEMP = $compiledDir
        try {
            Add-Type -TypeDefinition $nodeCode -OutputAssembly $compiled -OutputType ConsoleApplication
        } catch {
            $csc = @(
                (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
                (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
            ) | Where-Object { [IO.File]::Exists($_) } | Select-Object -First 1
            Assert-Repair (-not [string]::IsNullOrWhiteSpace([string]$csc)) ('Isolated node compile unavailable: ' + $_.Exception.Message)
            $csPath = Join-Path $compiledDir ('telephone-iso-node-' + [Guid]::NewGuid().ToString('N') + '.cs')
            [IO.File]::WriteAllText($csPath, $nodeCode, [Text.UTF8Encoding]::new($false))
            $cscOut = & $csc /nologo /t:exe /out:$compiled $csPath 2>&1 | Out-String
            Assert-Repair ([IO.File]::Exists($compiled)) ('Isolated fake node.exe did not compile: ' + $cscOut)
        }
    } finally {
        $env:TMP = $prevTmp
        $env:TEMP = $prevTemp
    }
    Copy-Item -LiteralPath $compiled -Destination $nodeExe -Force
    $runtimeCfg = $compiled + '.runtimeconfig.json'
    if ([IO.File]::Exists($runtimeCfg)) {
        Copy-Item -LiteralPath $runtimeCfg -Destination ($nodeExe + '.runtimeconfig.json') -Force
    }
    Assert-Repair ([IO.File]::Exists($nodeExe)) 'Isolated fake node.exe is missing.'
    $promptIso = Join-Path $adapterIso 'prompt.md'
    [IO.File]::WriteAllText($promptIso, "isolated adapter failure fixture`n", [Text.UTF8Encoding]::new($false))
    $workFull = [IO.Path]::GetFullPath($adapterWork).TrimEnd('\')
    $sessionStore = Join-Path $adapterState 'cursor-sessions'
    [IO.Directory]::CreateDirectory($sessionStore) | Out-Null
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $sessionStore 'sessions.json') -Value ([ordered]@{
        schema_version = 1
        sessions = @(
            [ordered]@{
                session_id = $frozenSession
                model_id = 'cursor-grok-4.6-xhigh'
                workspace = $workFull
                mode = 'ReadOnly'
                allowed_write_paths = @()
                last_dispatch_id = '00000000-0000-0000-0000-000000000001'
                last_normalized_request_sha256 = ('0' * 64)
                created_at = [DateTimeOffset]::UtcNow.ToString('o')
                last_used_at = [DateTimeOffset]::UtcNow.ToString('o')
            }
        )
    })
    $bindDir = Join-Path $adapterState ('sessions\' + $frozenSession)
    [IO.Directory]::CreateDirectory($bindDir) | Out-Null
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $bindDir 'binding.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-direct-cursor-binding-v1'
        native_session_id = $frozenSession
        latest_job_id = '00000000-0000-0000-0000-000000000000'
        workspace = $adapterWork
        mode = 'ReadOnly'
        allowed_write_paths = @()
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $adapterJob = [Guid]::NewGuid().ToString('D')
    $routeScript = Join-Path $repoRoot 'src\adapters\direct-cursor\Invoke-DirectCursorRoute.ps1'
    $adapterOut = Join-Path $adapterIso 'route-stdout.txt'
    $adapterErr = Join-Path $adapterIso 'route-stderr.txt'
    $routeInfo = [Diagnostics.ProcessStartInfo]::new()
    $routeInfo.FileName = $pwsh
    $routeInfo.UseShellExecute = $false
    $routeInfo.RedirectStandardOutput = $true
    $routeInfo.RedirectStandardError = $true
    $routeInfo.CreateNoWindow = $true
    foreach ($a in @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $routeScript,
        '-Operation', 'follow_up',
        '-NativeSessionId', $frozenSession,
        '-StateRoot', $adapterState,
        '-WorkspacePath', $adapterWork,
        '-PromptFile', $promptIso,
        '-Mode', 'ReadOnly',
        '-JobId', $adapterJob,
        '-CursorAgentRoot', $fakeAgent,
        '-WaitTimeoutSeconds', '60'
    )) { [void]$routeInfo.ArgumentList.Add($a) }
    $routeProc = [Diagnostics.Process]::Start($routeInfo)
    $stdoutTask = $routeProc.StandardOutput.ReadToEndAsync()
    $stderrTask = $routeProc.StandardError.ReadToEndAsync()
    $null = $routeProc.WaitForExit(90000)
    $adapterStdout = [string]$stdoutTask.GetAwaiter().GetResult()
    $adapterStderr = [string]$stderrTask.GetAwaiter().GetResult()
    $routeCode = [int]$routeProc.ExitCode
    $routeProc.Dispose()
    [IO.File]::WriteAllText($adapterOut, $adapterStdout, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($adapterErr, $adapterStderr, [Text.UTF8Encoding]::new($false))
    Assert-Repair ($routeCode -ne 0) ('Isolated adapter follow_up exited 0 after failure: ' + [string]$routeCode)
    Assert-Repair ($adapterStderr -notmatch 'does not match the frozen session') 'Failed follow_up was hidden behind a frozen-session mismatch.'
    $adapterJson = $adapterStdout | ConvertFrom-Json
    Assert-Repair ([string]$adapterJson.native_session_id -eq '') 'Failed adapter labeled a returned native session.'
    Assert-Repair ([string]$adapterJson.requested_native_session_id -ceq $frozenSession) 'Failed adapter dropped the requested session identity.'
    Assert-Repair ([bool]$adapterJson.returned_session_verified -ne $true) 'Failed adapter marked the requested session as verified.'
    Assert-Repair ([bool]$adapterJson.cursor_success -ne $true) 'Failed adapter reported cursor_success.'
    $cursorResultPath = Join-Path $adapterState ('jobs\' + $adapterJob + '\cursor-result.json')
    Assert-Repair ([IO.File]::Exists($cursorResultPath)) 'Isolated adapter did not persist cursor-result.json.'
    $cursorResult = Get-Content -LiteralPath $cursorResultPath -Raw | ConvertFrom-Json
    Assert-Repair ([bool]$cursorResult.success -ne $true) 'Isolated agent reported success.'
    Assert-Repair ([string]$cursorResult.session_id -eq '') 'Isolated agent filled session_id from the requested identity.'
    Assert-Repair ($null -ne $cursorResult.evidence) 'Isolated agent discarded failure evidence.'
    $stderrBytes = [int64]0
    if ($null -ne $cursorResult.PSObject.Properties['stderr_bytes'] -and $null -ne $cursorResult.stderr_bytes) {
        $stderrBytes = [int64]$cursorResult.stderr_bytes
    }
    $hasSpool = $false
    if ($null -ne $cursorResult.evidence) {
        if ($cursorResult.evidence -is [Collections.IDictionary]) {
            $hasSpool = $cursorResult.evidence.Contains('stderr_spool') -or $cursorResult.evidence.Contains('stderr')
        } else {
            $hasSpool = $null -ne $cursorResult.evidence.PSObject.Properties['stderr_spool'] -or $null -ne $cursorResult.evidence.PSObject.Properties['stderr']
        }
    }
    Assert-Repair (($stderrBytes -gt 0) -or $hasSpool) 'Isolated agent did not retain stderr byte evidence.'
    $diagFiles = @(Get-ChildItem -LiteralPath (Join-Path $adapterState 'cursor-sessions\diagnostics') -Recurse -Filter 'process-diagnostic.json' -ErrorAction SilentlyContinue)
    Assert-Repair ($diagFiles.Count -ge 1) 'Isolated adapter did not persist process diagnostics.'
    $intents = @(Get-ChildItem -LiteralPath (Join-Path $adapterState 'jobs') -Recurse -Filter 'launch-intent.json')
    Assert-Repair ($intents.Count -eq 1) ('Isolated adapter launched more than once: ' + [string]$intents.Count)
    $stderrSpool = @(Get-ChildItem -LiteralPath (Join-Path $adapterState 'cursor-sessions\diagnostics') -Recurse -Filter 'stderr.bin' -ErrorAction SilentlyContinue)
    Assert-Repair ($stderrSpool.Count -ge 1) 'Isolated adapter did not spool stderr.'
    $foundMarker = $false
    foreach ($bin in $stderrSpool) {
        $spoolText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($bin.FullName))
        if ($spoolText -match 'ISOLATED_ADAPTER_FAILURE_MARKER') { $foundMarker = $true }
    }
    Assert-Repair ([bool]$foundMarker) 'Isolated stderr spool lost the original exception marker.'
    $memCap = 65536
    foreach ($bin in @(Get-ChildItem -LiteralPath (Join-Path $adapterState 'cursor-sessions\diagnostics') -Recurse -Filter '*.bin' -ErrorAction SilentlyContinue)) {
        Assert-Repair ($bin.Length -lt 1048576) ('Isolated spool was unbounded: ' + $bin.Name + ' ' + [string]$bin.Length)
    }
    $null = $memCap

    Write-Output ('AUDIT_REPAIR_ASSERTIONS=' + $assertions)
} finally {
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_STATE', $previousDashState, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', $previousDashOpt, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_LEAD_STATE_ROOT', $previousLeadState, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_TASK_BACKEND', $previousTaskBackend, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_TASK_STORE', $previousTaskStore, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_SUPERVISOR_STATE_ROOT', $previousSupState, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_STATE_ROOT', $previousLineState, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_INSTALL_ROOT', $previousInstallRoot, 'Process')
    Remove-Item Env:TELEPHONE_TEST_LEAD_TURNS -ErrorAction SilentlyContinue
    Remove-Item Env:TELEPHONE_TEST_ORIG_STDERR -ErrorAction SilentlyContinue
}

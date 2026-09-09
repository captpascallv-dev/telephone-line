# SPDX-License-Identifier: MPL-2.0
# Correction-7 focused proofs. Isolated fixtures only; no live install, Task
# Scheduler, App, paid PI, or live mailbox mutation. Does not replay the unsafe
# 315730a2 mailbox-ref Execute, Collect-Probe-2dbc8dd, or unchanged D3/D5 suites.
# Does not rerun the prior 310/290/full-suite classification for its own sake.
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

function Invoke-RepairSupervisor {
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    foreach ($arg in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repoRoot 'src\supervisor\Invoke-TelephoneSupervisor.ps1'), '-InstallRoot', $repoRoot, '-StateRoot', $StateRoot)) {
        [void]$info.ArgumentList.Add([string]$arg)
    }
    $proc = [Diagnostics.Process]::Start($info)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    if (-not $proc.WaitForExit(120000)) {
        try { $proc.Kill() } catch { }
        throw 'Supervisor process did not exit within 120s.'
    }
    $code = [int]$proc.ExitCode
    $proc.Dispose()
    return [ordered]@{ exit_code = $code; stdout = [string]$stdout; stderr = [string]$stderr }
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
    $promptBytes = [IO.File]::ReadAllBytes($PromptFile)
    $promptSha = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($promptBytes))).ToLowerInvariant()
    $leadRun = [ordered]@{
        protocol_version = "huhu-concerto-cli-lead-run-v1"
        run_id = $RunId
        requested_run_id = $RunId
        worktree = [IO.Path]::GetFullPath($WorktreePath).TrimEnd("\")
        resume_session_id = $ResumeSessionId
        events_path = $events
        prompt = [ordered]@{ path = [IO.Path]::GetFullPath($PromptFile); bytes = [int64]$promptBytes.Length; sha256 = $promptSha }
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
    [IO.File]::WriteAllText($prompt, ("# Telephone-line durable receipt delivery`n`n- receipt_sha256: " + [string]$receiptRead.identity.sha256 + "`n- wake_key: " + [string]$wake.wake_key + "`n"), [Text.UTF8Encoding]::new($false))

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

    $producerRun = 'producer-' + $runId
    $producerRoot = Join-Path $leadState $producerRun
    [IO.Directory]::CreateDirectory($producerRoot) | Out-Null
    $producerSleep = Join-Path $testRoot 'producer-sleep.ps1'
    [IO.File]::WriteAllText($producerSleep, "Start-Sleep -Seconds 45`n", [Text.UTF8Encoding]::new($false))
    $producerOwner = Join-Path $producerRoot 'owner.json'
    $producerDriver = Join-Path $testRoot 'producer-driver.ps1'
    [IO.File]::WriteAllText($producerDriver, @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
. '$($repoRoot.Replace('''', ''''''))\src\core\TelephoneLine.Common.ps1'
Invoke-TelephoneLeadDrainedProcess -FileName '$($pwsh.Replace('''', ''''''))' -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','$($producerSleep.Replace('''', ''''''))') -WorkingDirectory '$($testRoot.Replace('''', ''''''))' -OwnerPath '$($producerOwner.Replace('''', ''''''))' -SessionId '$session' -RunId '$producerRun' -Role 'writer' | Out-Null
"@, [Text.UTF8Encoding]::new($false))
    $producerProc = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $producerDriver) -PassThru -WindowStyle Hidden
    $sawProducer = Wait-RepairPath -Path $producerOwner -Milliseconds 8000 -Probe {
        $doc = (Read-TelephoneJson -Path $producerOwner).value
        return ([int]$doc.pid -gt 0 -and [string]$doc.session_id -ceq $session -and [string]$doc.run_id -ceq $producerRun -and -not [string]::IsNullOrWhiteSpace([string]$doc.executable_path))
    }
    Assert-Repair ([bool]$sawProducer) 'Actual same-session producer did not persist bound owner identity.'
    $noiseRoot = Join-Path $leadState 'historical-noise-dead'
    [IO.Directory]::CreateDirectory($noiseRoot) | Out-Null
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $noiseRoot 'owner.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-bound-owner-v1'
        pid = 13
        start_time_utc_ticks = [int64]1
        started_at_utc = '2020-01-01T00:00:00Z'
        executable_path = $pwsh
        session_id = $session
        run_id = 'historical-noise-dead'
        role = 'host'
    })
    $foreignRoot = Join-Path $leadState 'foreign-session-dead'
    [IO.Directory]::CreateDirectory($foreignRoot) | Out-Null
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $foreignRoot 'owner.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-bound-owner-v1'
        pid = 17
        start_time_utc_ticks = [int64]2
        started_at_utc = '2020-01-01T00:00:01Z'
        executable_path = $pwsh
        session_id = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
        run_id = 'foreign-session-dead'
        role = 'host'
    })
    $aliveConflict = Test-TelephoneLeadPreTurnActiveWriterConflict -RunRoot $conflictRoot -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-Repair ([string]$aliveConflict.writer_identity_status -ceq 'bound') 'Sibling producer was not discovered as the prior writer.'
    Assert-Repair ([bool]$aliveConflict.writer_alive) 'Bound current writer was not treated as alive.'
    Assert-Repair (-not [bool]$aliveConflict.retry_eligible) 'Live bound writer was retry-eligible.'
    Assert-Repair ([int]$aliveConflict.writer.pid -ne [int]$PID) 'Discovery claimed the rejected test process as the conflicting writer.'
    try {
        Invoke-TelephoneNamedWakeAttach -LaunchResultPath $paths.wake_launch_result -LauncherPath $dualLauncher -ExtraArguments @('-StateRootOverride', $leadState) -Worktree $work -PromptFile $prompt -SessionId $session -RunId $runId -WakeKey ([string]$wake.wake_key) -LineJobId $jobId
        throw 'Live writer was not fail-closed.'
    } catch {
        Assert-Repair ([string]$_.Exception.Message -ceq 'LEAD_WAKE_PRE_TURN_CONFLICT') 'Live writer did not throw LEAD_WAKE_PRE_TURN_CONFLICT.'
    }
    Assert-Repair (-not [IO.File]::Exists((Join-Path $jobRoot 'wake-retry.json'))) 'Live writer wrote a retry record.'

    $producerOwnerDoc = (Read-TelephoneJson -Path $producerOwner).value
    $producerPid = [int]$producerOwnerDoc.pid
    try {
        try { Stop-Process -Id $producerPid -Force -ErrorAction SilentlyContinue } catch { }
        $null = $producerProc.WaitForExit(15000)
    } finally {
        try { if (-not $producerProc.HasExited) { $producerProc.Kill() } } catch { }
        $producerProc.Dispose()
    }
    $releasedConflict = Test-TelephoneLeadPreTurnActiveWriterConflict -RunRoot $conflictRoot -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-Repair ([string]$releasedConflict.writer_identity_status -ceq 'bound') 'Released sibling writer was not bound.'
    Assert-Repair (-not [bool]$releasedConflict.writer_alive) 'Dead bound writer was treated as alive.'
    Assert-Repair ([bool]$releasedConflict.retry_eligible) 'Released bound writer was not retry-eligible.'
    Assert-Repair ([int]$releasedConflict.writer.pid -eq $producerPid) 'Released writer bound historical noise instead of the conflict-time producer.'

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

    $lingerLauncher = Join-Path $testRoot 'linger-host.ps1'
    [IO.File]::WriteAllText($lingerLauncher, @'
param([string]$WorktreePath,[string]$PromptFile,[string]$ResumeSessionId,[string]$RunId,[string]$StateRootOverride)
$ErrorActionPreference = "Stop"
$run = [IO.Path]::GetFullPath((Join-Path $StateRootOverride $RunId))
[IO.Directory]::CreateDirectory($run) | Out-Null
$turn = [string]$env:TELEPHONE_TEST_LEAD_TURNS
if (-not [string]::IsNullOrWhiteSpace($turn)) {
    $row = [ordered]@{ run_id = $RunId; at_utc = [DateTimeOffset]::UtcNow.ToString("o") }
    [IO.File]::AppendAllText($turn, (($row | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}
$utf8 = [Text.UTF8Encoding]::new($false)
$promptBytes = [IO.File]::ReadAllBytes($PromptFile)
$promptSha = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($promptBytes))).ToLowerInvariant()
$leadRun = [ordered]@{
    protocol_version = "huhu-concerto-cli-lead-run-v1"
    run_id = $RunId
    requested_run_id = $RunId
    worktree = [IO.Path]::GetFullPath($WorktreePath).TrimEnd("\")
    resume_session_id = $ResumeSessionId
    events_path = (Join-Path $run "codex-events.jsonl")
    prompt = [ordered]@{ path = [IO.Path]::GetFullPath($PromptFile); bytes = [int64]$promptBytes.Length; sha256 = $promptSha }
    created_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
}
[IO.File]::WriteAllText((Join-Path $run "lead-run.json"), (($leadRun | ConvertTo-Json -Depth 8) + "`n"), $utf8)
$eventText = '{"type":"thread.started","thread_id":"' + $ResumeSessionId + '"}' + "`n" + '{"type":"turn.started","turn_id":"t1"}' + "`n" + '{"type":"turn.completed","turn_id":"t1","session_id":"' + $ResumeSessionId + '"}' + "`n"
[IO.File]::WriteAllText((Join-Path $run "codex-events.jsonl"), $eventText, $utf8)
Start-Sleep -Seconds 8
[ordered]@{ run_root = $run; state = "completed"; exit_code = 0 } | ConvertTo-Json -Compress
exit 0
'@, [Text.UTF8Encoding]::new($false))
    $lingerRun = 'linger-native-1'
    $lingerStarted = [DateTimeOffset]::UtcNow
    $lingerLaunch = Invoke-TelephoneFrozenLeadLauncher -LauncherPath $lingerLauncher -ExtraArguments @('-StateRootOverride', $leadState) -Worktree $work -PromptFile $prompt -SessionId $session -RunId $lingerRun
    $lingerElapsed = ([DateTimeOffset]::UtcNow - $lingerStarted).TotalSeconds
    Assert-Repair ([string]$lingerLaunch.state -ceq 'native_complete_host_lingering') ('Native-complete linger did not return through FrozenLeadLauncher: ' + [string]$lingerLaunch.state)
    Assert-Repair (-not [bool]$lingerLaunch.process_exited) 'Lingering host was treated as exited.'
    Assert-Repair ([bool]$lingerLaunch.native_turn_complete) 'Native-complete flag was dropped.'
    Assert-Repair ($lingerElapsed -lt 12) ('Launcher still waited for host exit: ' + [string]$lingerElapsed + 's')
    $lingerJob = Join-Path $testRoot 'jobs\linger'
    [IO.Directory]::CreateDirectory($lingerJob) | Out-Null
    foreach ($name in @('dispatch.json', 'receipt.json', 'lead-binding.json', 'out.txt', 'err.txt')) {
        $src = Join-Path $jobRoot $name
        if ([IO.File]::Exists($src)) { Copy-Item -LiteralPath $src -Destination (Join-Path $lingerJob $name) -Force }
    }
    $lingerPaths = Get-TelephoneJobPaths -JobRoot $lingerJob
    $lingerDispatch = (Read-TelephoneJson -Path $lingerPaths.dispatch).value
    Complete-TelephoneOwnerJobDelivery -JobPaths $lingerPaths -Dispatch $lingerDispatch -Launch $lingerLaunch -WakeIdentity $wake -LeadSessionId $session
    Assert-Repair ([IO.File]::Exists($lingerPaths.delivery)) 'Coordinator did not write delivery after native-complete linger.'
    $lingerAckPath = Join-Path $leadState ($lingerRun + '\lead-wake-ack.json')
    Assert-Repair ([IO.File]::Exists($lingerAckPath)) 'Linger coordinator did not persist receipt-bound ack.'
    $lingerAck = (Read-TelephoneJson -Path $lingerAckPath).value
    Assert-Repair ([string]$lingerAck.wake_key -ceq [string]$wake.wake_key) 'Linger ack omitted the intended wake key.'
    Assert-Repair ([string]$lingerAck.receipt_sha256 -ceq [string]$receiptRead.identity.sha256) 'Linger ack omitted the intended receipt SHA.'
    $lingerTurns = [IO.File]::ReadAllText($turnLog)
    $lingerStartCount = @([regex]::Matches($lingerTurns, [regex]::Escape($lingerRun))).Count
    Assert-Repair ($lingerStartCount -eq 1) ('Native-complete linger duplicate model-start: ' + [string]$lingerStartCount)
    $lingerDelivery = (Read-TelephoneJson -Path $lingerPaths.delivery).value
    Assert-Repair ($null -ne $lingerDelivery.owned_drain_terminal) 'Coordinator did not record owned drain observation.'
    Assert-Repair ([bool]$lingerDelivery.owned_drain_terminal.pending) 'Native-complete linger drain was fabricated as terminal.'
    Assert-Repair (-not [bool]$lingerDelivery.owned_drain_terminal.host_terminal) 'Lingering host was marked host_terminal without durable EOF.'
    Assert-Repair ([bool]$lingerDelivery.automatic_callback_success) 'Receipt wake ack was withheld because drain was still pending.'
    Assert-Repair ([bool]$lingerDelivery.owned_drain_pending) 'Delivery did not keep host-drain pending separate from receipt consumption.'

    $incompleteLauncher = Join-Path $testRoot 'incomplete-host.ps1'
    [IO.File]::WriteAllText($incompleteLauncher, @'
param([string]$WorktreePath,[string]$PromptFile,[string]$ResumeSessionId,[string]$RunId,[string]$StateRootOverride)
$run = [IO.Path]::GetFullPath((Join-Path $StateRootOverride $RunId))
[IO.Directory]::CreateDirectory($run) | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $run "codex-events.jsonl"), ('{"type":"thread.started","thread_id":"' + $ResumeSessionId + '"}' + "`n"), $utf8)
Start-Sleep -Seconds 2
exit 0
'@, [Text.UTF8Encoding]::new($false))
    try {
        Invoke-TelephoneFrozenLeadLauncher -LauncherPath $incompleteLauncher -ExtraArguments @('-StateRootOverride', $leadState) -Worktree $work -PromptFile $prompt -SessionId $session -RunId 'incomplete-native-1'
        throw 'Incomplete native stream was treated as success.'
    } catch {
        Assert-Repair ([string]$_.Exception.Message -cne 'LEAD_WAKE_PRE_TURN_CONFLICT') 'Incomplete host was misclassified as a writer conflict.'
        Assert-Repair ([string]$_.Exception.Message -cin @('LEAD_WAKE_FAILED', 'LEAD_WAKE_INCOMPLETE_HOST')) ('Incomplete host unexpected code: ' + [string]$_.Exception.Message)
    }

    $foreignLauncher = Join-Path $testRoot 'foreign-complete.ps1'
    [IO.File]::WriteAllText($foreignLauncher, @'
param([string]$WorktreePath,[string]$PromptFile,[string]$ResumeSessionId,[string]$RunId,[string]$StateRootOverride)
$run = [IO.Path]::GetFullPath((Join-Path $StateRootOverride $RunId))
[IO.Directory]::CreateDirectory($run) | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$other = "ffffffff-ffff-ffff-ffff-ffffffffffff"
$eventText = '{"type":"thread.started","thread_id":"' + $other + '"}' + "`n" + '{"type":"turn.started","turn_id":"t1"}' + "`n" + '{"type":"turn.completed","turn_id":"t1","session_id":"' + $other + '"}' + "`n"
[IO.File]::WriteAllText((Join-Path $run "codex-events.jsonl"), $eventText, $utf8)
Start-Sleep -Seconds 2
exit 0
'@, [Text.UTF8Encoding]::new($false))
    try {
        $foreignLaunch = Invoke-TelephoneFrozenLeadLauncher -LauncherPath $foreignLauncher -ExtraArguments @('-StateRootOverride', $leadState) -Worktree $work -PromptFile $prompt -SessionId $session -RunId 'foreign-native-1'
        Assert-Repair ([string]$foreignLaunch.state -cne 'native_complete_host_lingering') 'Foreign-session complete unblocked the own-session launcher.'
        throw 'Foreign complete was treated as a successful own-session wake.'
    } catch {
        if ([string]$_.Exception.Message -ceq 'Foreign complete was treated as a successful own-session wake.') { throw }
        Assert-Repair ([string]$_.Exception.Message -cin @('LEAD_WAKE_FAILED', 'LEAD_WAKE_INCOMPLETE_HOST')) ('Foreign host unexpected code: ' + [string]$_.Exception.Message)
    }

    $isolatedCanonical = Get-TelephoneLeadCanonicalIdentity -Lead $leadBinding
    $isolatedLeadKey = [string]$isolatedCanonical.identity_sha256
    $isolatedItemId = Get-TelephoneMailboxItemId -LeadKey $isolatedLeadKey -LineJobId $jobId -ReceiptSha256 ([string]$receiptRead.identity.sha256)
    $isolatedMailbox = Get-TelephoneLeadMailboxPaths -StateRoot $testRoot -LeadKey $isolatedLeadKey
    [IO.Directory]::CreateDirectory([string]$isolatedMailbox.mailbox) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path ([string]$isolatedMailbox.batches) $jobId)) | Out-Null
    $canonicalMailboxItem = [IO.Path]::GetFullPath((Join-Path ([string]$isolatedMailbox.mailbox) ($isolatedItemId + '.json')))
    $null = Write-TelephoneJsonCreateNew -Path $canonicalMailboxItem -Value ([ordered]@{
        protocol_version = 'telephone-line-mailbox-item-v1'
        item_id = $isolatedItemId
        batch_id = $jobId
        line_job_id = $jobId
        lead_session_id = $session
        lead_identity_sha256 = $isolatedLeadKey
        classification = 'pending'
        receipt = @{ sha256 = [string]$receiptRead.identity.sha256 }
        dispatch = @{ sha256 = [string]$dispatchId.sha256 }
    })
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path (Join-Path ([string]$isolatedMailbox.batches) $jobId) 'collection.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-batch-collection-v1'
        batch_id = $jobId
        n = 1
        counted = 1
        closed = $false
        state = 'open'
    })
    $null = Write-TelephoneJsonCreateNew -Path ([string]$isolatedMailbox.truth) -Value ([ordered]@{
        protocol_version = 'telephone-line-mailbox-truth-v1'
        lead_identity_sha256 = $isolatedLeadKey
        observational = $true
        batches = @([ordered]@{ protocol_version = 'telephone-line-mailbox-truth-batch-v1'; batch_id = $jobId; n = 1; counted = 1; closed = $false; state = 'open'; extra_field = 'early-keep' })
    })
    $null = Write-TelephoneJsonReplace -Path $paths.mailbox_ref -Value ([ordered]@{
        protocol_version = 'telephone-line-mailbox-ref-v1'
        lead_identity_sha256 = $isolatedLeadKey
        batch_id = $jobId
        item_id = $isolatedItemId
        item_path = $canonicalMailboxItem
    })

    $evidence = [ordered]@{
        protocol_version = 'telephone-explicit-consumption-evidence-v1'
        kind = 'EXPLICIT_PASCAL_MANUAL_RECOVERY_EXISTING_ORIGINAL_LEAD'
        lead_session_id = $session
        wake_key = [string]$wake.wake_key
        original_wake_run_id = [string]$wake.wake_run_id
        actual_consuming_run_root = $retryRoot
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

    $retained = Join-Path $testRoot 'crash-retained'
    [IO.Directory]::CreateDirectory($retained) | Out-Null
    foreach ($name in @('trusted-consumption.json', 'lifecycle-status.json', 'mailbox-closeout.json')) {
        $src = Join-Path $manualJob $name
        if ([IO.File]::Exists($src)) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $retained $name) -Force
            [IO.File]::Delete($src)
        }
    }
    Assert-Repair ([IO.File]::Exists($manualPaths.delivery)) 'Crash fixture lost the committed delivery.'
    Assert-Repair (-not [IO.File]::Exists($manualPaths.trusted_consumption)) 'Crash fixture still had trusted-consumption.'
    $crashRepair = Complete-TelephoneTrustedManualConsumption -JobRoot $manualJob -ExpectedReceiptSha256 ([string]$receiptRead.identity.sha256) -ExpectedWakeKey ([string]$wake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $evidencePath -ExpectedEvidenceSha256 $evidenceSha -Execute
    Assert-Repair ([bool]$crashRepair.ok) 'Crash closeout repair failed.'
    Assert-Repair ([string]$crashRepair.code -ceq 'MANUAL_CLOSED') ('Crash closeout returned false closed: ' + [string]$crashRepair.code)
    Assert-Repair ([string]$crashRepair.reason -ceq 'trusted_closeout_repaired') 'Crash closeout did not report repair.'
    Assert-Repair ([IO.File]::Exists($manualPaths.trusted_consumption)) 'Crash repair did not restore trusted-consumption.'
    Assert-Repair ([IO.File]::Exists($manualPaths.lifecycle_status)) 'Crash repair did not restore lifecycle.'
    Assert-Repair ([IO.File]::Exists((Join-Path $manualJob 'mailbox-closeout.json'))) 'Crash repair did not restore mailbox-closeout.'
    Assert-Repair ([IO.File]::Exists($manualPaths.relay_error)) 'Crash repair removed original failure bytes.'
    Assert-Repair ([IO.File]::Exists((Join-Path $retained 'trusted-consumption.json'))) 'Original closeout bytes were not retained.'

    $thinJob = Join-Path $testRoot 'jobs\thin-delivery'
    [IO.Directory]::CreateDirectory($thinJob) | Out-Null
    foreach ($name in @('dispatch.json', 'receipt.json', 'lead-binding.json', 'relay-error.json', 'mailbox-ref.json', 'out.txt', 'err.txt')) {
        $src = Join-Path $jobRoot $name
        if ([IO.File]::Exists($src)) { Copy-Item -LiteralPath $src -Destination (Join-Path $thinJob $name) -Force }
    }
    $thinPaths = Get-TelephoneJobPaths -JobRoot $thinJob
    $null = Write-TelephoneJsonCreateNew -Path $thinPaths.delivery -Value ([ordered]@{
        protocol_version = 'telephone-line-delivery-v1'
        delivery_kind = 'MANUAL_TRUSTED_CONSUMPTION'
        lead_session_id = $session
        wake_key = [string]$wake.wake_key
    })
    $thinClosed = Complete-TelephoneTrustedManualConsumption -JobRoot $thinJob -ExpectedReceiptSha256 ([string]$receiptRead.identity.sha256) -ExpectedWakeKey ([string]$wake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $evidencePath -ExpectedEvidenceSha256 $evidenceSha -Execute
    Assert-Repair (-not [bool]$thinClosed.ok) 'Delivery missing receipt/evidence was accepted.'
    Assert-Repair ([string]$thinClosed.code -cne 'ALREADY_CLOSED') 'Incomplete delivery identity returned ALREADY_CLOSED.'

    $autoJob = Join-Path $testRoot 'jobs\auto-delivery'
    [IO.Directory]::CreateDirectory($autoJob) | Out-Null
    foreach ($name in @('dispatch.json', 'receipt.json', 'lead-binding.json', 'relay-error.json', 'mailbox-ref.json', 'out.txt', 'err.txt')) {
        $src = Join-Path $jobRoot $name
        if ([IO.File]::Exists($src)) { Copy-Item -LiteralPath $src -Destination (Join-Path $autoJob $name) -Force }
    }
    $autoPaths = Get-TelephoneJobPaths -JobRoot $autoJob
    $null = Write-TelephoneJsonCreateNew -Path $autoPaths.delivery -Value ([ordered]@{
        protocol_version = 'telephone-line-delivery-v1'
        delivery_kind = 'AUTOMATIC_WAKE_ACK'
        lead_session_id = $session
        wake_key = [string]$wake.wake_key
        receipt_sha256 = [string]$receiptRead.identity.sha256
        automatic_callback_success = $true
    })
    $autoRace = Complete-TelephoneTrustedManualConsumption -JobRoot $autoJob -ExpectedReceiptSha256 ([string]$receiptRead.identity.sha256) -ExpectedWakeKey ([string]$wake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $evidencePath -ExpectedEvidenceSha256 $evidenceSha -Execute
    Assert-Repair (-not [bool]$autoRace.ok) 'Automatic delivery was labeled trusted-manual closed.'
    Assert-Repair ([string]$autoRace.reason -ceq 'automatic_delivery_present') ('Automatic race unexpected reason: ' + [string]$autoRace.reason)

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
    $lineJobCopy = Join-Path $lineState ('jobs\' + $jobId)
    [IO.Directory]::CreateDirectory($lineJobCopy) | Out-Null
    foreach ($name in @('dispatch.json', 'receipt.json', 'lead-binding.json', 'delivery.json', 'relay-error.json')) {
        $src = Join-Path $jobRoot $name
        if ([IO.File]::Exists($src)) { Copy-Item -LiteralPath $src -Destination (Join-Path $lineJobCopy $name) -Force }
    }
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
    Assert-Repair ([IO.File]::Exists((Join-Path $dashState 'line-sources.last-valid.json'))) 'Last-valid associations were not retained.'
    $restored = (Read-TelephoneJson -Path $malformedPath).value
    Assert-Repair (-not [string]::IsNullOrWhiteSpace([string]$restored.last_read_error_at_utc)) 'Malformed register cleared the source-discovery error.'
    $restoredJobs = @($restored.sources | Where-Object { $_ -is [Collections.IDictionary] -and [string]$_['line_job_id'] -ceq $jobId })
    Assert-Repair ($restoredJobs.Count -eq 1) 'Malformed register replaced last-valid associations with an empty healthy view.'
    $watchScript = Join-Path $repoRoot 'src\dashboard\Watch-TelephoneDashboard.ps1'
    $watchProc = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $watchScript, '-StateRoot', $dashState, '-Headless', '-Once') -Wait -PassThru -WindowStyle Hidden
    $watchCode = [int]$watchProc.ExitCode
    $watchProc.Dispose()
    Assert-Repair ($watchCode -eq 0) ('Isolated Watch -StateRoot -Headless -Once EXIT' + [string]$watchCode)
    Assert-Repair ([IO.File]::Exists((Join-Path $dashState 'projection.json'))) 'Watch did not publish projection.'
    $afterWatch = (Read-TelephoneJson -Path $malformedPath).value
    Assert-Repair (-not [string]::IsNullOrWhiteSpace([string]$afterWatch.last_read_error_at_utc)) 'Watcher success cleared source-discovery failure.'
    Assert-Repair (-not [string]::IsNullOrWhiteSpace([string]$afterWatch.last_success_at_utc)) 'Watch success did not record last_success.'
    $projection = Get-TelephoneDashboardProjection -DashboardStateRoot $dashState
    Assert-Repair ([bool]$projection.source_stale) 'Source-discovery error was not projected as source_stale.'
    $repairReg = Register-TelephoneDashboardLineSource -LineStateRoot $lineState -LineJobId $jobId -Project 'audit-repair' -LeadSessionId $session -LeadRunId $runId -Route 'direct-cursor' -DashboardStateRoot $dashState
    Assert-Repair ([bool]$repairReg.registered) 'Repair register failed after last-valid restore.'
    $watchProc2 = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $watchScript, '-StateRoot', $dashState, '-Headless', '-Once') -Wait -PassThru -WindowStyle Hidden
    $watchCode2 = [int]$watchProc2.ExitCode
    $watchProc2.Dispose()
    Assert-Repair ($watchCode2 -eq 0) ('Repair Watch EXIT' + [string]$watchCode2)
    $afterRepair = (Read-TelephoneJson -Path $malformedPath).value
    Assert-Repair ([string]::IsNullOrWhiteSpace([string]$afterRepair.last_read_error_at_utc)) 'Successful repair left source-discovery error set.'
    $projection = Get-TelephoneDashboardProjection -DashboardStateRoot $dashState
    Assert-Repair (-not [bool]$projection.source_stale) 'Healthy repaired sources remained source_stale.'
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

    $showPath = Join-Path $repoRoot '_audit_correction7_artifacts_20260909\private-candidate\cockpit\Show-PascalGlobalAutopilotStatus.ps1'
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
        model = 'cursor-grok-4.6-xhigh'
        route = 'direct-cursor'
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
        worker_telephone_job_ids = @($jobId)
        worker_direct_cursor_job_ids = @($directId)
    }
    $bindOk = Get-StatusRegisteredDirectBinding -Dispatch $dispatchForMap -Project $projectOkObj
    Assert-Repair ($null -ne $bindOk) 'Correct session/workspace/job alias mapping was rejected.'
    $reqForIdent = Get-Content -LiteralPath (Join-Path $directRoot 'request.json') -Raw | ConvertFrom-Json
    $identOk = Get-StatusJobIdentity -Dispatch $dispatchForMap -Request $reqForIdent -Route 'direct-cursor'
    Assert-Repair ([string]$identOk.state -ceq 'ok') ('Registered exact pair still unregistered: ' + [string]$identOk.state)
    Assert-Repair ([string]$identOk.label -notmatch '未登记') ('Registered executor identity stayed unregistered: ' + [string]$identOk.label)
    $projectAliasMismatch = [pscustomobject]@{
        current_line_job_id = $jobId
        current_direct_job_id = $directId
        current_direct_job_root = $directRoot
        dispatch_project_id = 'audit-repair'
        id = 'other-id'
        lead_thread_id = $session
        worktree = $work
        worker_telephone_job_ids = @('ffffffff-ffff-ffff-ffff-ffffffffffff')
        worker_direct_cursor_job_ids = @($directId)
    }
    $bindAlias = Get-StatusRegisteredDirectBinding -Dispatch $dispatchForMap -Project $projectAliasMismatch
    Assert-Repair ($null -eq $bindAlias) 'Worker array mismatch was accepted as the current exact pair.'
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
    $packetHead = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $packetTree = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $packetReceipt = ('c' * 64)
    $packetJob = $jobId
    [IO.File]::WriteAllText($packetPath, ("isolated packet`nrun-final-1`n" + $packetHead + "`n" + $packetTree + "`n" + $packetReceipt + "`n" + $packetJob + "`n"), [Text.UTF8Encoding]::new($false))
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
        current_run_id = 'run-final-1'
    }
    $packetGroup = [pscustomobject]@{
        current_run = [pscustomobject]@{
            run_id = 'run-final-1'
            owner_alive = $false
            protocol_ok = $true
            final_exists = $true
            final_failed = $false
        }
    }
    $maxWaitOther = Get-StatusAcceptanceResponsibility -Project $packetProject -Group $packetGroup -CollectionMatched $true
    Assert-Repair ([string]$maxWaitOther.code -cne 'awaiting_pascal_max') 'Other-project packet+terminal was treated as Pascal-Max without this authority metadata.'
    $packetProject = [pscustomobject]@{
        registry_status = 'ACTIVE'
        current_state = 'COLLECTED_ROOT_DECISION_PENDING'
        current_collection_path = $reproCollection
        current_collection_sha256 = $reproSha
        current_stage = 'final-review'
        ordinary_acceptance = 'accepted'
        current_final_review_packet_path = $packetPath
        current_final_review_packet_sha256 = $packetSha
        current_run_id = 'run-final-1'
        current_candidate_head = $packetHead
        current_candidate_tree = $packetTree
        current_receipt_sha256 = $packetReceipt
        current_line_job_id = $packetJob
        final_review_arranged_by = 'Pascal, previous independent Astra Max auditor'
        final_review_dispatch_by_lead_forbidden = $true
    }
    $maxWait = Get-StatusAcceptanceResponsibility -Project $packetProject -Group $packetGroup -CollectionMatched $true
    Assert-Repair ([string]$maxWait.code -ceq 'awaiting_pascal_max') 'Ready packet plus Lead terminal was not mapped to Pascal Max.'
    Assert-Repair ([string]$maxWait.owner -ceq 'Pascal') 'Pascal was not the Max-review owner.'
    Assert-Repair ([string]$maxWait.flow_label -match 'Max') 'Pascal Max review label was missing.'

    $rowSrc = 'C:\Users\Pascal\Documents\Codex\2026-08-16\pascal-master-task-20260816\control\handoffs\MASTER_SECRETARY_SUCCESSOR_REVIEW_20260907\new-secretary\telephone-public-onboarding-repair-20260909\product-hardening\audit-driven-repair-20260909\correction-3\dashboard-row.before.json'
    $rowCopy = Join-Path $testRoot 'dashboard-row.before.json'
    Copy-Item -LiteralPath $rowSrc -Destination $rowCopy -Force
    $registryPath = Join-Path $testRoot 'heartbeat-registry.json'
    $rowDoc = Get-Content -LiteralPath $rowCopy -Raw | ConvertFrom-Json
    $null = Write-TelephoneJsonCreateNew -Path $registryPath -Value ([ordered]@{
        protocol_version = 'pascal-master-heartbeat-registry-v1'
        projects = @($rowDoc)
    })
    $mappedProjects = @(Get-StatusRegisteredProjects -Config ([pscustomobject]@{ projects = @(); project_registry_paths = @($registryPath) }))
    Assert-Repair ($mappedProjects.Count -eq 1) 'Copied current-row registry did not map a project.'
    $mapped = $mappedProjects[0]
    Assert-Repair ([string]$mapped.current_stage -match 'AUDIT_DRIVEN') 'Copied current-row lost the AUDIT_DRIVEN stage.'
    $stageOnlyReject = Test-StatusLeadCorrectionOrEngineeringReject -Project ([pscustomobject]@{ current_stage = [string]$mapped.current_stage })
    Assert-Repair (-not [bool]$stageOnlyReject) 'AUDIT_DRIVEN stage title was treated as an engineering FAIL.'
    Assert-Repair ([bool](Test-StatusLeadCorrectionOrEngineeringReject -Project $mapped)) 'Copied current-row FAIL acceptance was not bound.'
    $collectedState = Get-StatusCollectedDecisionState -Project $mapped
    Assert-Repair ([string]$collectedState -cne 'waiting_root') 'Non-ROOT_DECISION_PENDING collected hash was forced to waiting_root.'
    $currentResp = Get-StatusAcceptanceResponsibility -Project $mapped
    Assert-Repair ([string]$currentResp.code -ceq 'correction_active') ('Copied current-row was not bound to correction owner: ' + [string]$currentResp.code)
    Assert-Repair (-not [bool]$currentResp.awaiting_pascal_max) 'Copied current-row without a ready packet was labeled Pascal-Max.'
    $stalePacket = Join-Path $testRoot 'STALE_FINAL_REVIEW_PACKET.md'
    [IO.File]::WriteAllText($stalePacket, ("stale prior packet`n" + [string]$mapped.current_line_job_id + "`nold-head`n"), [Text.UTF8Encoding]::new($false))
    $staleSha = Get-RepairSha256 -Path $stalePacket
    foreach ($pair in @(
        @{ Name = 'current_final_review_packet_path'; Value = $stalePacket },
        @{ Name = 'current_final_review_packet_sha256'; Value = $staleSha },
        @{ Name = 'current_candidate_head'; Value = '7f14ec4dfed7b24d2fe8be49ef1c1939962a8825' },
        @{ Name = 'current_candidate_tree'; Value = '1731fd5eab9e1ffca5dc7d0c98519bacecf5a988' },
        @{ Name = 'current_receipt_sha256'; Value = '20fc43e6ee206e2dffa0a0492055b14757d37e4527b1c1d9d302e9bc721c0b15' }
    )) {
        $rowDoc | Add-Member -NotePropertyName ([string]$pair.Name) -NotePropertyValue $pair.Value -Force
    }
    $staleRegistry = Join-Path $testRoot 'heartbeat-registry-stale-packet.json'
    $null = Write-TelephoneJsonCreateNew -Path $staleRegistry -Value ([ordered]@{
        protocol_version = 'pascal-master-heartbeat-registry-v1'
        projects = @($rowDoc)
    })
    $staleMapped = @(Get-StatusRegisteredProjects -Config ([pscustomobject]@{ projects = @(); project_registry_paths = @($staleRegistry) }))[0]
    $staleGroup = [pscustomobject]@{
        current_run = [pscustomobject]@{
            run_id = [string]$staleMapped.current_run_id
            owner_alive = $false
            protocol_ok = $true
            final_exists = $true
            final_failed = $false
        }
    }
    $staleResp = Get-StatusAcceptanceResponsibility -Project $staleMapped -Group $staleGroup
    Assert-Repair ([string]$staleResp.code -ceq 'correction_active') ('Stale packet outranked current engineering FAIL: ' + [string]$staleResp.code)
    Assert-Repair (-not [bool]$staleResp.awaiting_pascal_max) 'Stale prior packet plus old final was treated as Pascal-Max ready.'
    Assert-Repair (-not (Test-StatusFinalReviewPacketActuallyReady -Project $staleMapped)) 'Stale packet hash was accepted as the current round packet.'
    $missingRunProject = [pscustomobject]@{
        ordinary_acceptance = 'accepted'
        current_final_review_packet_path = $packetPath
        current_final_review_packet_sha256 = $packetSha
        current_run_id = ''
        final_review_arranged_by = 'Pascal, previous independent Astra Max auditor'
        final_review_dispatch_by_lead_forbidden = $true
    }
    $missingRunGroup = [pscustomobject]@{
        current_run = [pscustomobject]@{
            run_id = ''
            owner_alive = $false
            protocol_ok = $true
            final_exists = $true
            final_failed = $false
        }
    }
    $missingRunResp = Get-StatusAcceptanceResponsibility -Project $missingRunProject -Group $missingRunGroup -CollectionMatched $true
    Assert-Repair ([string]$missingRunResp.code -cne 'awaiting_pascal_max') 'Missing current run identity still produced Pascal-Max ready.'
    $noBindPacket = [pscustomobject]@{
        current_final_review_packet_path = $packetPath
        current_final_review_packet_sha256 = $packetSha
    }
    Assert-Repair (-not (Test-StatusFinalReviewPacketActuallyReady -Project $noBindPacket)) 'Packet without current candidate/receipt/job linkage was treated as ready.'
    $eligibleOnly = [pscustomobject]@{
        registry_status = 'ACTIVE'
        current_state = 'COLLECTED'
        current_collection_path = $reproCollection
        current_collection_sha256 = $reproSha
        current_collection_status = 'acceptance_eligible'
    }
    Assert-Repair ([string](Get-StatusCollectedDecisionState -Project $eligibleOnly) -cne 'waiting_root') 'acceptance_eligible/COLLECTED without ROOT_DECISION_PENDING was shown as Root pending.'

    $wrapperDir = Join-Path $testRoot 'wrapper-owner\src\supervisor'
    [IO.Directory]::CreateDirectory($wrapperDir) | Out-Null
    $targetName = 'Start-TelephoneSupervisorHostVisible.ps1'
    $targetScript = Join-Path $wrapperDir $targetName
    [IO.File]::WriteAllText($targetScript, "# isolated wrapper target`n", [Text.UTF8Encoding]::new($false))
    $exe = Join-Path $wrapperDir 'SupervisorNoConsoleHost.exe'
    $exeBytes = [Collections.Generic.List[byte]]::new()
    foreach ($b in [byte[]](77, 90, 0, 0)) { [void]$exeBytes.Add($b) }
    foreach ($b in [Text.Encoding]::UTF8.GetBytes($targetScript)) { [void]$exeBytes.Add($b) }
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

    $realWrapperCopy = Join-Path $repoRoot '_audit_correction3_artifacts_20260909\private-candidate\wrapper\SupervisorNoConsoleHost.exe'
    $realSidecar = $realWrapperCopy + '.identity.json'
    Assert-Repair ([IO.File]::Exists($realWrapperCopy)) 'Real wrapper EXE copy was missing from the correction artifact.'
    Assert-Repair ([IO.File]::Exists($realSidecar)) 'Real wrapper sidecar was missing.'
    $expectedLiveRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'TelephoneLine'))
    $realOwned = Get-TelephoneSupervisorInstallRootFromWrapperIdentity -ActionScript $realWrapperCopy
    Assert-Repair ($realOwned.Equals($expectedLiveRoot, [StringComparison]::OrdinalIgnoreCase)) ('Real wrapper identity did not bind install root: [' + [string]$realOwned + ']')
    $wrongRoot = [IO.Path]::GetFullPath((Join-Path $testRoot 'wrapper-wrong-root'))
    $wrongDir = Join-Path $wrongRoot 'src\supervisor'
    [IO.Directory]::CreateDirectory($wrongDir) | Out-Null
    $wrongExe = Join-Path $wrongDir 'SupervisorNoConsoleHost.exe'
    Copy-Item -LiteralPath $realWrapperCopy -Destination $wrongExe -Force
    $wrongTarget = Join-Path $wrongDir 'Start-TelephoneSupervisorHostVisible.ps1'
    [IO.File]::WriteAllText($wrongTarget, "# same-basename foreign root`n", [Text.UTF8Encoding]::new($false))
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $wrongDir 'wrapper-identity.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-supervisor-wrapper-identity-v1'
        install_root = $wrongRoot
        wrapper_path = $wrongExe
        sha256 = (Get-RepairSha256 -Path $wrongExe)
        target_script = $wrongTarget
        working_directory = $wrongRoot
    })
    $wrongOwned = Get-TelephoneSupervisorInstallRootFromWrapperIdentity -ActionScript $wrongExe
    Assert-Repair ([string]::IsNullOrWhiteSpace($wrongOwned)) 'Same EXE plus wrong-root same-basename sidecar was accepted.'
    $wrapperParseOut = Join-Path $testRoot 'wrapper-parse.raw.txt'
    [IO.File]::WriteAllText($wrapperParseOut, ((([ordered]@{
        parsed_install_root = [string]$realOwned
        expected_install_root = $expectedLiveRoot
        bound = (-not [string]::IsNullOrWhiteSpace([string]$realOwned))
        filename_alone = [string]$bareRoot
        wrong_root_rejected = [string]::IsNullOrWhiteSpace($wrongOwned)
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

    $defaults = Get-Content -LiteralPath (Join-Path $repoRoot '_audit_correction2_artifacts_20260909\private-candidate\defaults\TELEPHONE_NEW_LEAD_DEFAULTS.json') -Raw | ConvertFrom-Json
    Assert-Repair ([string]$defaults.codex_command -match 'telephone-cli\\0\.153\.4-fd4c151a\\codex\.exe') 'Isolated defaults still named the deleted App path.'
    Assert-Repair ([string]$defaults.model -ceq 'gpt-6-astra') 'Defaults model policy drifted.'
    Assert-Repair ([string]$defaults.reasoning_effort -ceq 'high') 'Defaults effort policy drifted.'
    Assert-Repair ([string]$defaults.service_tier -ceq 'default') 'Defaults service policy drifted.'
    Assert-Repair ([string]$defaults.default_executor_route -ceq 'direct-cursor') 'Defaults route policy drifted.'

    $tutu = Get-Content -LiteralPath (Join-Path $repoRoot '_audit_correction2_artifacts_20260909\private-candidate\tutu\scripts\New-TutuPiDirectCursorDispatch.ps1') -Raw
    Assert-Repair ($tutu -match 'pending_registered_task_is_not_success') 'Tutu dispatch still equated pending task with success.'
    Assert-Repair ($tutu -match 'success = \$false') 'Tutu dispatch result lacked explicit non-success.'

    $tutuIso = Join-Path $testRoot 'tutu-iso'
    [IO.Directory]::CreateDirectory((Join-Path $tutuIso 'scripts')) | Out-Null
    foreach ($name in @('TutuPi.Common.ps1', 'Invoke-TutuPiCodexHost.ps1', 'Start-TutuPiCodexLead.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repoRoot ('_audit_correction2_artifacts_20260909\private-candidate\tutu\scripts\' + $name)) -Destination (Join-Path $tutuIso ('scripts\' + $name)) -Force
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

    $isoState = Join-Path $testRoot 'iso-mailbox-state'
    $isoJobId = 'bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeee6'
    $isoJob = Join-Path $isoState ('jobs\' + $isoJobId)
    $isoConsume = Join-Path $isoState 'consuming-run'
    foreach ($d in @($isoJob, $isoConsume)) { [IO.Directory]::CreateDirectory($d) | Out-Null }
    $isoPaths = Get-TelephoneJobPaths -JobRoot $isoJob
    $isoLeadBinding = [ordered]@{
        protocol_version = 'telephone-line-lead-binding-v1'
        session_id = $session
        worktree = $work
        launcher = [ordered]@{ path = $dualLauncher; arguments = @() }
    }
    $isoBindingId = Write-TelephoneJsonCreateNew -Path $isoPaths.lead_binding -Value $isoLeadBinding
    $isoRequestPath = Join-Path $isoState 'request.json'
    $isoRequest = [ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = $isoJobId
        project = 'audit-repair'
        stage = 'focused'
        role = 'execution'
        route = 'direct-cursor'
        summary = 'isolated-mailbox'
        lead = $isoLeadBinding
        command = [ordered]@{ executable = $pwsh; working_directory = $work; arguments = @('-NoLogo'); stdin = $null }
    }
    $null = Write-TelephoneJsonCreateNew -Path $isoRequestPath -Value $isoRequest
    $isoRequestId = Get-TelephoneFileIdentity -Path $isoRequestPath
    $isoDispatch = [ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = $isoJobId
        project = 'audit-repair'
        stage = 'focused'
        role = 'execution'
        route = 'direct-cursor'
        summary = 'isolated-mailbox'
        lead = $isoLeadBinding
        command = [ordered]@{ executable = $pwsh; working_directory = $work; arguments = @('-NoLogo'); stdin = $null }
        source_request = $isoRequestId
        lead_binding = $isoBindingId
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        absolute_task_timeout = $false
        project_judgment = $false
    }
    $null = Write-TelephoneJsonCreateNew -Path $isoPaths.dispatch -Value $isoDispatch
    $isoDispatchId = Get-TelephoneFileIdentity -Path $isoPaths.dispatch
    $isoReceipt = [ordered]@{
        protocol_version = 'telephone-line-receipt-v1'
        line_job_id = $isoJobId
        project = 'audit-repair'
        stage = 'focused'
        role = 'execution'
        route = 'direct-cursor'
        summary = 'isolated-mailbox'
        dispatch = $isoDispatchId
        transport_complete = $true
        command_exit_code = 0
        command_error_code = $null
        command_error_message = $null
        stdout = @{ path = (Join-Path $isoJob 'out.txt'); bytes = 0; sha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' }
        stderr = @{ path = (Join-Path $isoJob 'err.txt'); bytes = 0; sha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' }
        started_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        absolute_task_timeout = $false
        automatic_rerun = $false
        project_judgment = $false
    }
    [IO.File]::WriteAllText((Join-Path $isoJob 'out.txt'), '', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $isoJob 'err.txt'), '', [Text.UTF8Encoding]::new($false))
    $null = Write-TelephoneJsonCreateNew -Path $isoPaths.receipt -Value $isoReceipt
    $isoReceiptRead = Read-TelephoneJson -Path $isoPaths.receipt -SchemaName 'receipt'
    $isoWake = New-TelephoneWakeIdentity -LineJobId $isoJobId -ReceiptIdentity $isoReceiptRead.identity -LeadSessionId $session
    $isoCanonical = Get-TelephoneLeadCanonicalIdentity -Lead $isoLeadBinding
    $isoLeadKey = [string]$isoCanonical.identity_sha256
    $isoItemId = Get-TelephoneMailboxItemId -LeadKey $isoLeadKey -LineJobId $isoJobId -ReceiptSha256 ([string]$isoReceiptRead.identity.sha256)
    $isoLead = Join-Path $isoState ('leads\' + $isoLeadKey)
    $isoMailboxDir = Join-Path $isoLead 'mailbox'
    $isoBatchDir = Join-Path $isoLead ('batches\' + $isoJobId)
    foreach ($d in @($isoLead, $isoMailboxDir, $isoBatchDir)) { [IO.Directory]::CreateDirectory($d) | Out-Null }
    $isoItemPath = Join-Path $isoMailboxDir ($isoItemId + '.json')
    $isoPrompt = Join-Path $isoConsume 'prompt.md'
    [IO.File]::WriteAllText($isoPrompt, ("# Telephone-line durable receipt delivery`n`n- line_job_id: $isoJobId`n- receipt_sha256: " + [string]$isoReceiptRead.identity.sha256 + "`n- wake_key: " + [string]$isoWake.wake_key + "`n"), [Text.UTF8Encoding]::new($false))
    $isoPromptId = Get-TelephoneFileIdentity -Path $isoPrompt
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $isoConsume 'lead-run.json') -Value ([ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = 'consuming-run-1'
        requested_run_id = 'consuming-run-1'
        resume_session_id = $session
        events_path = (Join-Path $isoConsume 'codex-events.jsonl')
        prompt = $isoPromptId
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    [IO.File]::WriteAllText((Join-Path $isoConsume 'codex-events.jsonl'), ('{"type":"thread.started","thread_id":"' + $session + '"}' + "`n" + '{"type":"turn.started"}' + "`n"), [Text.UTF8Encoding]::new($false))
    $isoItem = [ordered]@{
        protocol_version = 'telephone-line-mailbox-item-v1'
        item_id = $isoItemId
        batch_id = $isoJobId
        line_job_id = $isoJobId
        lead_session_id = $session
        lead_identity_sha256 = $isoLeadKey
        classification = 'success'
        receipt = @{ sha256 = [string]$isoReceiptRead.identity.sha256 }
        dispatch = @{ sha256 = [string]$isoDispatchId.sha256 }
    }
    $null = Write-TelephoneJsonCreateNew -Path $isoItemPath -Value $isoItem
    $isoSiblingId = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
    $isoSiblingPath = Join-Path $isoMailboxDir ($isoSiblingId + '.json')
    $null = Write-TelephoneJsonCreateNew -Path $isoSiblingPath -Value ([ordered]@{
        protocol_version = 'telephone-line-mailbox-item-v1'
        item_id = $isoSiblingId
        batch_id = $isoJobId
        line_job_id = 'cccccccc-cccc-cccc-dddd-eeeeeeeeeee7'
        lead_identity_sha256 = $isoLeadKey
        classification = 'pending'
    })
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $isoBatchDir 'collection.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-batch-collection-v1'
        batch_id = $isoJobId
        n = 2
        counted = 2
        closed = $false
        acceptance_eligible = $false
        state = 'awaiting_delivery'
        extra_collection_field = 'keep-collection'
    })
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $isoLead 'truth.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-mailbox-truth-v1'
        lead_identity_sha256 = $isoLeadKey
        observational = $true
        batches = @([ordered]@{ protocol_version = 'telephone-line-mailbox-truth-batch-v1'; batch_id = $isoJobId; n = 2; counted = 2; closed = $false; state = 'open'; extra_field = 'keep-me' })
    })
    $null = Write-TelephoneJsonCreateNew -Path $isoPaths.mailbox_ref -Value ([ordered]@{
        protocol_version = 'telephone-line-mailbox-ref-v1'
        lead_identity_sha256 = $isoLeadKey
        batch_id = $isoJobId
        item_id = $isoItemId
        item_path = $isoItemPath
    })
    $null = Write-TelephoneJsonCreateNew -Path $isoPaths.relay_error -Value ([ordered]@{
        protocol_version = 'telephone-line-relay-error-v1'
        line_job_id = $isoJobId
        lead_session_id = $session
        retrying = $false
        error_code = 'LEAD_WAKE_FAILED'
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $isoEvidence = Join-Path $isoState 'consumption-evidence.json'
    $null = Write-TelephoneJsonCreateNew -Path $isoEvidence -Value ([ordered]@{
        protocol_version = 'telephone-line-trusted-consumption-evidence-v1'
        kind = 'EXPLICIT_PASCAL_MANUAL_RECOVERY_EXISTING_ORIGINAL_LEAD'
        automatic_callback_success = $false
        lead_session_id = $session
        wake_key = [string]$isoWake.wake_key
        original_wake_run_id = [string]$isoWake.wake_run_id
        actual_consuming_run_root = $isoConsume
        receipt = @{ sha256 = [string]$isoReceiptRead.identity.sha256 }
    })
    $isoEvidenceSha = [string](Get-TelephoneFileIdentity -Path $isoEvidence).sha256
    $isoItemOriginal = [IO.File]::ReadAllBytes($isoItemPath)
    $wrongItemDoc = (Read-TelephoneJson -Path $isoItemPath).value
    $wrongItemDoc['receipt'] = @{ sha256 = ('c' * 64) }
    $null = Write-TelephoneJsonReplace -Path $isoItemPath -Value $wrongItemDoc
    $wrongSha = Get-RepairSha256 -Path $isoItemPath
    $wrongDry = Complete-TelephoneTrustedManualConsumption -JobRoot $isoJob -ExpectedReceiptSha256 ([string]$isoReceiptRead.identity.sha256) -ExpectedWakeKey ([string]$isoWake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $isoEvidence -ExpectedEvidenceSha256 $isoEvidenceSha
    Assert-Repair (-not [bool]$wrongDry.ok) 'Wrong mailbox item receipt was accepted.'
    Assert-Repair ([string]$wrongDry.reason -ceq 'mailbox_item_receipt_mismatch') ('Wrong-receipt reason drifted: ' + [string]$wrongDry.reason)
    Assert-Repair ((Get-RepairSha256 -Path $isoItemPath) -ceq $wrongSha) 'Wrong-receipt dry-run mutated the mailbox item.'
    [IO.File]::WriteAllBytes($isoItemPath, $isoItemOriginal)
    $isoDry = Complete-TelephoneTrustedManualConsumption -JobRoot $isoJob -ExpectedReceiptSha256 ([string]$isoReceiptRead.identity.sha256) -ExpectedWakeKey ([string]$isoWake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $isoEvidence -ExpectedEvidenceSha256 $isoEvidenceSha
    Assert-Repair ([string]$isoDry.code -ceq 'DRY_RUN') 'Isolated rebound mailbox dry-run did not validate.'
    $isoExec = Complete-TelephoneTrustedManualConsumption -JobRoot $isoJob -ExpectedReceiptSha256 ([string]$isoReceiptRead.identity.sha256) -ExpectedWakeKey ([string]$isoWake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $isoEvidence -ExpectedEvidenceSha256 $isoEvidenceSha -Execute
    Assert-Repair ([bool]$isoExec.ok) ('Isolated rebound mailbox execute failed: ' + [string]$isoExec.reason)
    $isoItemAfter = (Read-TelephoneJson -Path $isoItemPath).value
    Assert-Repair ([bool]$isoItemAfter.trusted_manual_closeout) 'Isolated mailbox item was not closed.'
    $isoSiblingAfter = (Read-TelephoneJson -Path $isoSiblingPath).value
    Assert-Repair (-not [bool]$(if ($isoSiblingAfter.Contains('trusted_manual_closeout')) { $isoSiblingAfter['trusted_manual_closeout'] } else { $false })) 'Closing one item marked a sibling closed.'
    $isoTruthAfter = (Read-TelephoneJson -Path (Join-Path $isoLead 'truth.json')).value
    $isoBatchRow = @($isoTruthAfter.batches | Where-Object { [string]$_.batch_id -ceq $isoJobId })[0]
    Assert-Repair (-not [bool]$isoBatchRow.closed) 'One-item closeout closed a multi-item batch.'
    Assert-Repair ([string]$isoBatchRow.extra_field -ceq 'keep-me') 'Mailbox truth replace dropped sibling/current fields.'
    $isoCollectionAfter = (Read-TelephoneJson -Path (Join-Path $isoBatchDir 'collection.json')).value
    Assert-Repair ([string]$isoCollectionAfter.state -ceq 'lead_consumed_pending_siblings') ('Collection did not leave awaiting_delivery: ' + [string]$isoCollectionAfter.state)
    Assert-Repair (-not [bool]$isoCollectionAfter.closed) 'Sibling-pending closeout closed collection.'
    Assert-Repair (-not [bool]$isoCollectionAfter.acceptance_eligible) 'Trusted closeout marked incomplete collection acceptance_eligible.'
    Assert-Repair ([string]$isoCollectionAfter.extra_collection_field -ceq 'keep-collection') 'Collection merge replaced unrelated batch fields.'
    $isoObserved = @(Get-TelephoneMailboxObservationalBatches -StateRoot $isoState)
    $isoObservedRow = @($isoObserved | Where-Object { [string]$_.batch_id -ceq $isoJobId })[0]
    Assert-Repair ($null -ne $isoObservedRow) 'Observational consumer lost the batch after closeout.'
    Assert-Repair ([string]$isoObservedRow.state -ceq 'lead_consumed_pending_siblings') ('Observational consumer stayed on stale collection: ' + [string]$isoObservedRow.state)
    Assert-Repair (-not [bool]$isoObservedRow.closed) 'Observational consumer closed a pending-sibling batch.'
    Assert-Repair (-not [bool]$isoObservedRow.acceptance_eligible) 'Observational consumer marked incomplete collection eligible.'
    $repeatIso = Complete-TelephoneTrustedManualConsumption -JobRoot $isoJob -ExpectedReceiptSha256 ([string]$isoReceiptRead.identity.sha256) -ExpectedWakeKey ([string]$isoWake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $isoEvidence -ExpectedEvidenceSha256 $isoEvidenceSha -Execute
    Assert-Repair ([string]$repeatIso.code -ceq 'ALREADY_CLOSED') 'Repeat closeout was not idempotent after actual mailbox convergence.'
    $isoCloseoutPath = Join-Path $isoJob 'mailbox-closeout.json'
    $isoCloseoutBackup = [IO.File]::ReadAllBytes($isoCloseoutPath)
    $wrongMarker = (Read-TelephoneJson -Path $isoCloseoutPath).value
    $wrongMarker['receipt_sha256'] = ('d' * 64)
    $wrongMarker['line_job_id'] = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
    $null = Write-TelephoneJsonReplace -Path $isoCloseoutPath -Value $wrongMarker
    $wrongMarkerRun = Complete-TelephoneTrustedManualConsumption -JobRoot $isoJob -ExpectedReceiptSha256 ([string]$isoReceiptRead.identity.sha256) -ExpectedWakeKey ([string]$isoWake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $isoEvidence -ExpectedEvidenceSha256 $isoEvidenceSha -Execute
    Assert-Repair ([string]$wrongMarkerRun.code -cne 'ALREADY_CLOSED') 'Wrong closeout marker identity was treated as fully closed.'
    Assert-Repair ([bool]$wrongMarkerRun.ok) ('Own partial closeout with wrong marker was not repaired: ' + [string]$wrongMarkerRun.code + ' ' + [string]$wrongMarkerRun.reason)
    $repairedCloseout = (Read-TelephoneJson -Path $isoCloseoutPath).value
    Assert-Repair ([string]$repairedCloseout.receipt_sha256 -ceq [string]$isoReceiptRead.identity.sha256) 'Repaired closeout did not restore the own receipt identity.'
    Assert-Repair ([string]$repairedCloseout.evidence_sha256 -ceq $isoEvidenceSha) 'Repaired closeout did not restore the own evidence identity.'
    $repeatAfterMarker = Complete-TelephoneTrustedManualConsumption -JobRoot $isoJob -ExpectedReceiptSha256 ([string]$isoReceiptRead.identity.sha256) -ExpectedWakeKey ([string]$isoWake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $isoEvidence -ExpectedEvidenceSha256 $isoEvidenceSha -Execute
    Assert-Repair ([string]$repeatAfterMarker.code -ceq 'ALREADY_CLOSED') 'Repeat after marker repair was not idempotent.'
    $isoObservedAgain = @(Get-TelephoneMailboxObservationalBatches -StateRoot $isoState)
    $isoObservedAgainRow = @($isoObservedAgain | Where-Object { [string]$_.batch_id -ceq $isoJobId })[0]
    Assert-Repair ([string]$isoObservedAgainRow.state -ceq 'lead_consumed_pending_siblings') 'Observational consumer drifted after marker repair.'
    $null = $isoCloseoutBackup

    $liveMailboxItem = 'C:\Users\Pascal\Documents\Codex\2026-08-16\pascal-master-task-20260816\control\handoffs\MASTER_SECRETARY_SUCCESSOR_REVIEW_20260907\new-secretary\telephone-public-onboarding-repair-20260909\product-hardening\state\telephone-line\leads\59f66ca4e9d6cc27db865fb141f844289081bdbfeeb0d6cc14757b9485cbcf3d\mailbox\e17f72781f1979c755ed5b0ac9959ce61fe9f371393f28b8905ff325ba4736c0.json'
    $liveTruth = 'C:\Users\Pascal\Documents\Codex\2026-08-16\pascal-master-task-20260816\control\handoffs\MASTER_SECRETARY_SUCCESSOR_REVIEW_20260907\new-secretary\telephone-public-onboarding-repair-20260909\product-hardening\state\telephone-line\leads\59f66ca4e9d6cc27db865fb141f844289081bdbfeeb0d6cc14757b9485cbcf3d\truth.json'
    $liveBatch = 'C:\Users\Pascal\Documents\Codex\2026-08-16\pascal-master-task-20260816\control\handoffs\MASTER_SECRETARY_SUCCESSOR_REVIEW_20260907\new-secretary\telephone-public-onboarding-repair-20260909\product-hardening\state\telephone-line\leads\59f66ca4e9d6cc27db865fb141f844289081bdbfeeb0d6cc14757b9485cbcf3d\batches\315730a2-2619-4529-bd7e-9758eb2c68b1\collection.json'
    $liveJobRoot = 'C:\Users\Pascal\Documents\Codex\2026-08-16\pascal-master-task-20260816\control\handoffs\MASTER_SECRETARY_SUCCESSOR_REVIEW_20260907\new-secretary\telephone-public-onboarding-repair-20260909\product-hardening\state\telephone-line\jobs\315730a2-2619-4529-bd7e-9758eb2c68b1'
    $beforeItem = Get-RepairSha256 -Path $liveMailboxItem
    $beforeTruth = Get-RepairSha256 -Path $liveTruth
    $beforeBatch = Get-RepairSha256 -Path $liveBatch
    $beforeJobDelivery = [IO.File]::Exists((Join-Path $liveJobRoot 'delivery.json'))
    $negJob = Join-Path $isoState 'jobs\live-pointer-negative'
    [IO.Directory]::CreateDirectory($negJob) | Out-Null
    foreach ($name in @('dispatch.json', 'receipt.json', 'relay-error.json')) {
        Copy-Item -LiteralPath (Join-Path $isoJob $name) -Destination (Join-Path $negJob $name) -Force
    }
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $negJob 'mailbox-ref.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-mailbox-ref-v1'
        lead_identity_sha256 = $isoLeadKey
        batch_id = $isoJobId
        item_id = $isoItemId
        item_path = $liveMailboxItem
    })
    $negExec = Complete-TelephoneTrustedManualConsumption -JobRoot $negJob -ExpectedReceiptSha256 ([string]$isoReceiptRead.identity.sha256) -ExpectedWakeKey ([string]$isoWake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $isoEvidence -ExpectedEvidenceSha256 $isoEvidenceSha -Execute
    Assert-Repair (-not [bool]$negExec.ok) 'Live absolute mailbox pointer was executed.'
    Assert-Repair ([string]$negExec.reason -ceq 'mailbox_item_outside_state_root' -or [string]$negExec.reason -ceq 'mailbox_item_path_mismatch') ('Live pointer reject reason drifted: ' + [string]$negExec.reason)
    Assert-Repair (-not [IO.File]::Exists((Join-Path $negJob 'delivery.json'))) 'Rejected live pointer wrote isolated delivery.'
    Assert-Repair (-not [IO.File]::Exists((Join-Path $negJob 'mailbox-closeout.json'))) 'Rejected live pointer wrote mailbox-closeout.'
    Assert-Repair ((Get-RepairSha256 -Path $liveMailboxItem) -ceq $beforeItem) 'Live mailbox item fingerprint changed.'
    Assert-Repair ((Get-RepairSha256 -Path $liveTruth) -ceq $beforeTruth) 'Live mailbox truth fingerprint changed.'
    Assert-Repair ((Get-RepairSha256 -Path $liveBatch) -ceq $beforeBatch) 'Live mailbox batch fingerprint changed.'
    Assert-Repair ([IO.File]::Exists((Join-Path $liveJobRoot 'delivery.json')) -eq $beforeJobDelivery) 'Live job delivery presence changed.'

    $crashJob = Join-Path $isoState 'jobs\crash-partial'
    [IO.Directory]::CreateDirectory($crashJob) | Out-Null
    foreach ($name in @('dispatch.json', 'receipt.json', 'relay-error.json')) {
        Copy-Item -LiteralPath (Join-Path $isoJob $name) -Destination (Join-Path $crashJob $name) -Force
    }
    $crashItemId = $isoItemId
    $crashItemPath = $isoItemPath
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $crashJob 'mailbox-ref.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-mailbox-ref-v1'
        lead_identity_sha256 = $isoLeadKey
        batch_id = $isoJobId
        item_id = $crashItemId
        item_path = $crashItemPath
    })
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $crashJob 'delivery.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-delivery-v1'
        line_job_id = $isoJobId
        lead_session_id = $session
        wake_key = [string]$isoWake.wake_key
        receipt_sha256 = [string]$isoReceiptRead.identity.sha256
        delivery_kind = 'MANUAL_TRUSTED_CONSUMPTION'
        consumption_evidence = @{ sha256 = $isoEvidenceSha }
    })
    $crashRepair = Complete-TelephoneTrustedManualConsumption -JobRoot $crashJob -ExpectedReceiptSha256 ([string]$isoReceiptRead.identity.sha256) -ExpectedWakeKey ([string]$isoWake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $isoEvidence -ExpectedEvidenceSha256 $isoEvidenceSha -Execute
    Assert-Repair ([bool]$crashRepair.ok) ('Partial mailbox crash was not repaired: ' + [string]$crashRepair.reason)
    $crashItemAfter = (Read-TelephoneJson -Path $crashItemPath).value
    Assert-Repair ([bool]$crashItemAfter.trusted_manual_closeout) 'Crash repair did not close the remaining item.'

    $okConsume = Test-TelephoneTrustedConsumingRun -ConsumingRoot $isoConsume -ExpectedSessionId $session -ForbiddenRunId ([string]$isoWake.wake_run_id) -ExpectedReceiptSha256 ([string]$isoReceiptRead.identity.sha256) -ExpectedWakeKey ([string]$isoWake.wake_key)
    Assert-Repair ([bool]$okConsume.ok) ('Authorized consuming run/input was rejected: ' + [string]$okConsume.reason)
    $allocRoot = Join-Path $isoState 'allocation-only-run'
    [IO.Directory]::CreateDirectory($allocRoot) | Out-Null
    Copy-Item -LiteralPath $isoPrompt -Destination (Join-Path $allocRoot 'prompt.md') -Force
    $allocPromptId = Get-TelephoneFileIdentity -Path (Join-Path $allocRoot 'prompt.md')
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $allocRoot 'lead-run.json') -Value ([ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = 'allocation-only-1'
        requested_run_id = 'allocation-only-1'
        resume_session_id = $session
        events_path = (Join-Path $allocRoot 'codex-events.jsonl')
        prompt = $allocPromptId
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    [IO.File]::WriteAllText((Join-Path $allocRoot 'codex-events.jsonl'), ('{"type":"thread.started","thread_id":"' + $session + '"}' + "`n"), [Text.UTF8Encoding]::new($false))
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $allocRoot 'host-terminal.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-host-terminal-v1'
        run_id = 'allocation-only-1'
        session_id = $session
        exit_code = 1
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $allocConsume = Test-TelephoneTrustedConsumingRun -ConsumingRoot $allocRoot -ExpectedSessionId $session -ExpectedReceiptSha256 ([string]$isoReceiptRead.identity.sha256) -ExpectedWakeKey ([string]$isoWake.wake_key)
    Assert-Repair (-not [bool]$allocConsume.ok) 'Thread allocation plus pre-turn host failure was accepted as consuming run.'
    Assert-Repair ([string]$allocConsume.reason -ceq 'consuming_run_rejected_pre_turn') ('Allocation-only pre-turn reason drifted: ' + [string]$allocConsume.reason)
    $threadOnlyRoot = Join-Path $isoState 'thread-only-run'
    [IO.Directory]::CreateDirectory($threadOnlyRoot) | Out-Null
    Copy-Item -LiteralPath $isoPrompt -Destination (Join-Path $threadOnlyRoot 'prompt.md') -Force
    $threadPromptId = Get-TelephoneFileIdentity -Path (Join-Path $threadOnlyRoot 'prompt.md')
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $threadOnlyRoot 'lead-run.json') -Value ([ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = 'thread-only-1'
        requested_run_id = 'thread-only-1'
        resume_session_id = $session
        events_path = (Join-Path $threadOnlyRoot 'codex-events.jsonl')
        prompt = $threadPromptId
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    [IO.File]::WriteAllText((Join-Path $threadOnlyRoot 'codex-events.jsonl'), ('{"type":"thread.started","thread_id":"' + $session + '"}' + "`n"), [Text.UTF8Encoding]::new($false))
    $threadOnly = Test-TelephoneTrustedConsumingRun -ConsumingRoot $threadOnlyRoot -ExpectedSessionId $session -ExpectedReceiptSha256 ([string]$isoReceiptRead.identity.sha256) -ExpectedWakeKey ([string]$isoWake.wake_key)
    Assert-Repair (-not [bool]$threadOnly.ok) 'Thread allocation without a turn was accepted as consuming run.'
    Assert-Repair ([string]$threadOnly.reason -ceq 'consuming_run_allocation_only') ('Allocation-only reason drifted: ' + [string]$threadOnly.reason)
    $wrongConsume = Test-TelephoneTrustedConsumingRun -ConsumingRoot $isoConsume -ExpectedSessionId $session -ForbiddenRunId 'consuming-run-1' -ExpectedReceiptSha256 ([string]$isoReceiptRead.identity.sha256) -ExpectedWakeKey ([string]$isoWake.wake_key)
    Assert-Repair (-not [bool]$wrongConsume.ok) 'Forbidden original/consuming run id was accepted.'
    $wrongReceiptPrompt = Join-Path $testRoot 'wrong-receipt-prompt.md'
    [IO.File]::WriteAllText($wrongReceiptPrompt, "other receipt`n", [Text.UTF8Encoding]::new($false))
    $wrongRoot = Join-Path $testRoot 'wrong-receipt-run'
    [IO.Directory]::CreateDirectory($wrongRoot) | Out-Null
    $wrongPromptId = Get-TelephoneFileIdentity -Path $wrongReceiptPrompt
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $wrongRoot 'lead-run.json') -Value ([ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = 'wrong-receipt-run'
        requested_run_id = 'wrong-receipt-run'
        resume_session_id = $session
        events_path = (Join-Path $wrongRoot 'codex-events.jsonl')
        prompt = $wrongPromptId
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $wrongBind = Test-TelephoneTrustedConsumingRun -ConsumingRoot $wrongRoot -ExpectedSessionId $session -ExpectedReceiptSha256 ([string]$isoReceiptRead.identity.sha256) -ExpectedWakeKey ([string]$isoWake.wake_key)
    Assert-Repair (-not [bool]$wrongBind.ok) 'Unrelated same-session run without receipt input was accepted as consuming run.'

    $foreignTurnSessionRoot = Join-Path $isoState 'foreign-turn-session'
    [IO.Directory]::CreateDirectory($foreignTurnSessionRoot) | Out-Null
    Copy-Item -LiteralPath $isoPrompt -Destination (Join-Path $foreignTurnSessionRoot 'prompt.md') -Force
    $foreignTurnSessionPrompt = Get-TelephoneFileIdentity -Path (Join-Path $foreignTurnSessionRoot 'prompt.md')
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $foreignTurnSessionRoot 'lead-run.json') -Value ([ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = 'foreign-turn-session-1'
        requested_run_id = 'foreign-turn-session-1'
        resume_session_id = $session
        events_path = (Join-Path $foreignTurnSessionRoot 'codex-events.jsonl')
        prompt = $foreignTurnSessionPrompt
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    [IO.File]::WriteAllText((Join-Path $foreignTurnSessionRoot 'codex-events.jsonl'), ('{"type":"thread.started","thread_id":"' + $session + '"}' + "`n" + '{"type":"turn.completed","session_id":"ffffffff-ffff-ffff-ffff-ffffffffffff","turn_id":"foreign-turn"}' + "`n"), [Text.UTF8Encoding]::new($false))
    $foreignTurnSession = Test-TelephoneTrustedConsumingRun -ConsumingRoot $foreignTurnSessionRoot -ExpectedSessionId $session -ExpectedReceiptSha256 ([string]$isoReceiptRead.identity.sha256) -ExpectedWakeKey ([string]$isoWake.wake_key)
    Assert-Repair (-not [bool]$foreignTurnSession.ok) 'A foreign-session qualifying turn was accepted as the consuming run.'
    Assert-Repair ([string]$foreignTurnSession.reason -ceq 'consuming_run_wrong_session') ('Foreign-session turn reason drifted: ' + [string]$foreignTurnSession.reason)

    $foreignTurnRunRoot = Join-Path $isoState 'foreign-turn-run'
    [IO.Directory]::CreateDirectory($foreignTurnRunRoot) | Out-Null
    Copy-Item -LiteralPath $isoPrompt -Destination (Join-Path $foreignTurnRunRoot 'prompt.md') -Force
    $foreignTurnRunPrompt = Get-TelephoneFileIdentity -Path (Join-Path $foreignTurnRunRoot 'prompt.md')
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $foreignTurnRunRoot 'lead-run.json') -Value ([ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = 'expected-run'
        requested_run_id = 'expected-run'
        resume_session_id = $session
        events_path = (Join-Path $foreignTurnRunRoot 'codex-events.jsonl')
        prompt = $foreignTurnRunPrompt
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    [IO.File]::WriteAllText((Join-Path $foreignTurnRunRoot 'codex-events.jsonl'), ('{"type":"thread.started","thread_id":"' + $session + '","run_id":"expected-run"}' + "`n" + '{"type":"turn.completed","session_id":"' + $session + '","run_id":"unrelated-run","turn_id":"foreign-turn"}' + "`n"), [Text.UTF8Encoding]::new($false))
    $foreignTurnRun = Test-TelephoneTrustedConsumingRun -ConsumingRoot $foreignTurnRunRoot -ExpectedSessionId $session -ExpectedReceiptSha256 ([string]$isoReceiptRead.identity.sha256) -ExpectedWakeKey ([string]$isoWake.wake_key)
    Assert-Repair (-not [bool]$foreignTurnRun.ok) 'A foreign-run qualifying turn was accepted as the consuming run.'
    Assert-Repair ([string]$foreignTurnRun.reason -ceq 'consuming_run_event_foreign') ('Foreign-run turn reason drifted: ' + [string]$foreignTurnRun.reason)

    $streamSelf = Get-Process -Id $PID
    try {
        $streamExe = ''
        try { $streamExe = [string]$streamSelf.MainModule.FileName } catch { $streamExe = [string]$streamSelf.Path }
        $streamTicks = [int64]$streamSelf.StartTime.ToUniversalTime().Ticks
        $streamIdentity = [ordered]@{
            pid = [int]$PID
            start_time_utc_ticks = $streamTicks
            executable_path = $streamExe
            session_id = $session
            run_id = 'same-run'
        }
        $foreignStreamRoot = Join-Path $testRoot 'stream-foreign-producer'
        [IO.Directory]::CreateDirectory($foreignStreamRoot) | Out-Null
        $foreignHandoff = [ordered]@{
            pid = 2147483646
            target_pid = 2147483646
            start_time_utc_ticks = [int64]1
            executable_path = $streamExe
            session_id = $session
            run_id = 'same-run'
            pending = $false
            process_exited = $true
            stdout_eof = $true
            stderr_eof = $true
        }
        [IO.File]::WriteAllText((Join-Path $foreignStreamRoot 'host-drain-handoff.json'), (($foreignHandoff | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        $foreignStream = Get-TelephoneLeadOwnedStreamObservation -RunRoot $foreignStreamRoot -Identity $streamIdentity -Role host -SessionId $session -RunId 'same-run'
        Assert-Repair ([string]$foreignStream.observation -ceq 'handoff_foreign_producer') ('Foreign producer handoff was accepted: ' + [string]$foreignStream.observation)
        Assert-Repair (-not [bool]$foreignStream.stdout_eof) 'Foreign producer handoff fabricated stdout EOF.'
        Assert-Repair (-not [bool]$foreignStream.stderr_eof) 'Foreign producer handoff fabricated stderr EOF.'
        $exactStreamRoot = Join-Path $testRoot 'stream-exact-producer'
        [IO.Directory]::CreateDirectory($exactStreamRoot) | Out-Null
        $exactHandoff = [ordered]@{
            pid = [int]$streamIdentity.pid
            target_pid = [int]$streamIdentity.pid
            start_time_utc_ticks = [int64]$streamIdentity.start_time_utc_ticks
            executable_path = $streamExe
            session_id = $session
            run_id = 'same-run'
            pending = $false
            process_exited = $true
            stdout_eof = $true
            stderr_eof = $true
        }
        [IO.File]::WriteAllText((Join-Path $exactStreamRoot 'host-drain-handoff.json'), (($exactHandoff | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        $exactStream = Get-TelephoneLeadOwnedStreamObservation -RunRoot $exactStreamRoot -Identity $streamIdentity -Role host -SessionId $session -RunId 'same-run'
        Assert-Repair ([string]$exactStream.observation -ceq 'handoff_complete') ('Exact producer handoff was not accepted: ' + [string]$exactStream.observation)
        Assert-Repair ([bool]$exactStream.stdout_eof) 'Exact producer handoff lost stdout EOF.'
        Assert-Repair ([bool]$exactStream.stderr_eof) 'Exact producer handoff lost stderr EOF.'
        $lostReaderRoot = Join-Path $testRoot 'stream-lost-reader'
        [IO.Directory]::CreateDirectory($lostReaderRoot) | Out-Null
        $lostHandoff = [ordered]@{
            pid = [int]$streamIdentity.pid
            target_pid = [int]$streamIdentity.pid
            start_time_utc_ticks = $streamTicks
            executable_path = $streamExe
            session_id = $session
            run_id = 'same-run'
            owner_pid = 999999
            owner_start_time_utc_ticks = [int64]1
            owner_executable_path = $streamExe
            pending = $true
            process_exited = $false
            stdout_eof = $false
            stderr_eof = $false
        }
        [IO.File]::WriteAllText((Join-Path $lostReaderRoot 'host-drain-handoff.json'), (($lostHandoff | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        $lostStream = Get-TelephoneLeadOwnedStreamObservation -RunRoot $lostReaderRoot -Identity $streamIdentity -Role host -SessionId $session -RunId 'same-run'
        Assert-Repair ([string]$lostStream.observation -ceq 'handoff_pending') ('Lost-reader handoff was treated as complete: ' + [string]$lostStream.observation)
        Assert-Repair (-not [bool]$lostStream.stdout_eof) 'Lost-reader handoff fabricated stdout EOF.'
        Assert-Repair (-not (Test-TelephoneLeadDrainCoordinatorAlive -RunRoot $lostReaderRoot)) 'Dead coordinator was treated as recoverable.'
    } finally {
        $streamSelf.Dispose()
    }

    # D5 isolated adapter follow_up is an unchanged proof class; not rerun here.
    $v23Launcher = Join-Path $repoRoot '_audit_correction7_artifacts_20260909\private-candidate\launchers\Invoke-V23_11WiredLead.ps1'
    $v23Helper = Join-Path $repoRoot '_audit_correction7_artifacts_20260909\private-candidate\launchers\DirectCursor.Common.ps1'
    Assert-Repair ([IO.File]::Exists($v23Launcher)) 'Candidate V23 launcher copy was missing.'
    Assert-Repair ([IO.File]::Exists($v23Helper)) 'Candidate DirectCursor helper copy was missing.'
    $env:TELEPHONE_LINE_DIRECTCURSOR_COMMON = $v23Helper
    $env:TELEPHONE_LINE_INSTALL_ROOT = $repoRoot
    $v23State = Join-Path $testRoot 'v23-state'
    $v23Work = Join-Path $testRoot 'v23-work'
    foreach ($d in @($v23State, $v23Work)) { [IO.Directory]::CreateDirectory($d) | Out-Null }
    $fakeCliSrc = @'
using System;
using System.Threading;
public static class IsolatedLeadCli {
    public static int Main(string[] args) {
        string joined = string.Join(" ", args);
        if (joined.IndexOf("--version", StringComparison.Ordinal) >= 0) {
            Console.Out.WriteLine("0.153.4");
            return 0;
        }
        string mode = Environment.GetEnvironmentVariable("TELEPHONE_FAKE_LEAD_MODE");
        if (string.IsNullOrEmpty(mode)) { mode = "consume"; }
        string session = "";
        for (int i = 0; i < args.Length - 1; i++) {
            if (string.Equals(args[i], "resume", StringComparison.OrdinalIgnoreCase)) { session = args[i + 1]; }
        }
        if (mode == "conflict") {
            Console.Error.Write("thread-store conflict: session already has an active writer\n");
            return 1;
        }
        Console.Out.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"" + session + "\"}");
        Console.Out.WriteLine("{\"type\":\"turn.started\",\"turn_id\":\"t1\"}");
        Console.Out.WriteLine("{\"type\":\"turn.completed\",\"turn_id\":\"t1\",\"session_id\":\"" + session + "\"}");
        Console.Out.Flush();
        if (mode == "linger") { Thread.Sleep(12000); }
        else { Thread.Sleep(400); }
        return 0;
    }
}
'@
    $fakeCli = Join-Path $testRoot 'fake-lead-cli.exe'
    $compiledDir = Join-Path $env:LOCALAPPDATA 'Temp'
    [IO.Directory]::CreateDirectory($compiledDir) | Out-Null
    $prevTmp = $env:TMP
    $prevTemp = $env:TEMP
    try {
        $env:TMP = $compiledDir
        $env:TEMP = $compiledDir
        try {
            Add-Type -TypeDefinition $fakeCliSrc -OutputAssembly $fakeCli -OutputType ConsoleApplication
        } catch {
            $csc = @(
                (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
                (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
            ) | Where-Object { [IO.File]::Exists($_) } | Select-Object -First 1
            Assert-Repair (-not [string]::IsNullOrWhiteSpace([string]$csc)) 'No C# compiler for isolated fake Lead CLI.'
            $srcPath = Join-Path $testRoot 'fake-lead-cli.cs'
            [IO.File]::WriteAllText($srcPath, $fakeCliSrc, [Text.UTF8Encoding]::new($false))
            & $csc /nologo /t:exe /out:$fakeCli $srcPath
            Assert-Repair ($LASTEXITCODE -eq 0 -and [IO.File]::Exists($fakeCli)) 'csc failed to build isolated fake Lead CLI.'
        }
    } finally {
        $env:TMP = $prevTmp
        $env:TEMP = $prevTemp
    }
    $v23Reg = Join-Path $testRoot 'v23-registry.json'
    $v23Project = 'v23-isolated-project'
    $null = Write-TelephoneJsonCreateNew -Path $v23Reg -Value ([ordered]@{
        projects = @([ordered]@{
            project_id = $v23Project
            lead_native_session_id = $session
            lead_model_id = 'gpt-5.4-mini'
            lead_reasoning_effort = 'low'
            lead_codex_command = $fakeCli
            lead_cli_argument_profile = 'codex-standard-20260907'
        })
    })
    $v23Extra = @(
        '-StateRootOverride', $v23State,
        '-ResumeSessionRegistryPath', $v23Reg,
        '-ResumeSessionProjectId', $v23Project,
        '-CodexCommand', $fakeCli,
        '-Model', 'gpt-5.4-mini',
        '-ReasoningEffort', 'low'
    )
    $v23Prompt = Join-Path $testRoot 'v23-prompt.md'
    [IO.File]::WriteAllText($v23Prompt, ("# Telephone-line durable receipt delivery`n`n- receipt_sha256: " + [string]$receiptRead.identity.sha256 + "`n- wake_key: " + [string]$wake.wake_key + "`n"), [Text.UTF8Encoding]::new($false))
    $env:TELEPHONE_FAKE_LEAD_MODE = 'consume'
    $freshId = 'v23-fresh-1'
    $freshLaunch = Invoke-TelephoneFrozenLeadLauncher -LauncherPath $v23Launcher -ExtraArguments $v23Extra -Worktree $v23Work -PromptFile $v23Prompt -SessionId $session -RunId $freshId
    Assert-Repair (-not [string]::IsNullOrWhiteSpace([string]$freshLaunch.run_root) -or [string]$freshLaunch.state -ceq 'native_complete_host_lingering') ('Actual V23 fresh launch did not admit: ' + ($freshLaunch | ConvertTo-Json -Compress))
    $freshRoot = Join-Path $v23State $freshId
    Assert-Repair ([IO.File]::Exists((Join-Path $freshRoot 'lead-run.json'))) 'Actual V23 fresh run did not write native metadata.'
    Assert-Repair ([IO.File]::Exists((Join-Path $freshRoot 'cli-child.json'))) 'Actual V23 fresh run did not reach the fake CLI.'
    $freshCli = (Read-TelephoneJson -Path (Join-Path $freshRoot 'cli-child.json')).value
    Assert-Repair ([int]$freshCli.pid -gt 0) 'Actual V23 CLI child pid was missing.'
    $null = Wait-TelephoneLeadOwnedDrainTerminal -RunRoot $freshRoot -WaitMilliseconds 30000
    try {
        Invoke-TelephoneFrozenLeadLauncher -LauncherPath $v23Launcher -ExtraArguments $v23Extra -Worktree $v23Work -PromptFile $v23Prompt -SessionId $session -RunId $freshId
        throw 'Existing V23 runRoot was admitted again.'
    } catch {
        Assert-Repair ([string]$_.Exception.Message -ceq 'LEAD_WAKE_FAILED') ('Existing V23 collision did not fail closed: ' + [string]$_.Exception.Message)
    }
    $foreignId = 'v23-foreign-1'
    $foreignRoot = Join-Path $v23State $foreignId
    [IO.Directory]::CreateDirectory($foreignRoot) | Out-Null
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $foreignRoot 'owner.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-bound-owner-v1'
        pid = 19
        start_time_utc_ticks = [int64]3
        started_at_utc = '2020-01-01T00:00:02Z'
        executable_path = $pwsh
        session_id = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
        run_id = $foreignId
        role = 'host'
    })
    try {
        Invoke-TelephoneFrozenLeadLauncher -LauncherPath $v23Launcher -ExtraArguments $v23Extra -Worktree $v23Work -PromptFile $v23Prompt -SessionId $session -RunId $foreignId
        throw 'Foreign V23 owner was admitted.'
    } catch {
        Assert-Repair ([string]$_.Exception.Message -ceq 'LEAD_WAKE_FAILED') ('Foreign V23 claim did not fail closed: ' + [string]$_.Exception.Message)
    }
    $env:TELEPHONE_FAKE_LEAD_MODE = 'linger'
    $producerId = 'v23-producer-1'
    $producerLaunch = Invoke-TelephoneFrozenLeadLauncher -LauncherPath $v23Launcher -ExtraArguments $v23Extra -Worktree $v23Work -PromptFile $v23Prompt -SessionId $session -RunId $producerId
    Assert-Repair ([string]$producerLaunch.state -ceq 'native_complete_host_lingering' -or ($producerLaunch -is [Collections.IDictionary] -and $producerLaunch.Contains('process_exited') -and -not [bool]$producerLaunch['process_exited'])) 'Actual V23 producer did not linger after native complete.'
    $producerRoot = Join-Path $v23State $producerId
    Assert-Repair ([IO.File]::Exists((Join-Path $producerRoot 'cli-child.json'))) 'Actual V23 producer did not persist CLI child identity.'
    $producerChild = (Read-TelephoneJson -Path (Join-Path $producerRoot 'cli-child.json')).value
    $env:TELEPHONE_FAKE_LEAD_MODE = 'conflict'
    $conflictId = 'v23-conflict-1'
    try {
        Invoke-TelephoneFrozenLeadLauncher -LauncherPath $v23Launcher -ExtraArguments $v23Extra -Worktree $v23Work -PromptFile $v23Prompt -SessionId $session -RunId $conflictId
        throw 'Actual V23 conflict launch was treated as success.'
    } catch {
        Assert-Repair ([string]$_.Exception.Message -ceq 'LEAD_WAKE_PRE_TURN_CONFLICT') ('Actual V23 conflict did not throw LEAD_WAKE_PRE_TURN_CONFLICT: ' + [string]$_.Exception.Message)
    }
    $conflictRoot = Join-Path $v23State $conflictId
    $v23Conflict = Test-TelephoneLeadPreTurnActiveWriterConflict -RunRoot $conflictRoot -ExpectedSessionId $session -ExpectedRunId $conflictId
    Assert-Repair ([bool]$v23Conflict.matched) 'Actual V23 conflict was not classified as pre-turn writer conflict.'
    Assert-Repair ([string]$v23Conflict.writer_identity_status -ceq 'bound') 'Actual V23 producer was not bound as the conflicting writer.'
    Assert-Repair ([int]$v23Conflict.writer.pid -eq [int]$producerChild.pid) 'Actual V23 writer pid was not the producer CLI child.'
    try { Stop-Process -Id ([int]$producerChild.pid) -Force -ErrorAction SilentlyContinue } catch { }
    $null = Wait-TelephoneLeadOwnedDrainTerminal -RunRoot $producerRoot -WaitMilliseconds 30000
    $releasedV23 = Test-TelephoneLeadPreTurnActiveWriterConflict -RunRoot $conflictRoot -ExpectedSessionId $session -ExpectedRunId $conflictId
    Assert-Repair ([bool]$releasedV23.retry_eligible) 'Released actual V23 writer was not retry-eligible.'
    $env:TELEPHONE_FAKE_LEAD_MODE = 'consume'
    $retryId = 'v23-retry-1'
    $retryLaunch = Invoke-TelephoneFrozenLeadLauncher -LauncherPath $v23Launcher -ExtraArguments $v23Extra -Worktree $v23Work -PromptFile $v23Prompt -SessionId $session -RunId $retryId
    $retryRoot = $(if (-not [string]::IsNullOrWhiteSpace([string]$retryLaunch.run_root)) { [string]$retryLaunch.run_root } else { Join-Path $v23State $retryId })
    $retryJob = Join-Path $testRoot 'jobs\v23-retry'
    [IO.Directory]::CreateDirectory($retryJob) | Out-Null
    foreach ($name in @('dispatch.json', 'receipt.json', 'lead-binding.json', 'out.txt', 'err.txt')) {
        $src = Join-Path $jobRoot $name
        if ([IO.File]::Exists($src)) { Copy-Item -LiteralPath $src -Destination (Join-Path $retryJob $name) -Force }
    }
    $retryPaths = Get-TelephoneJobPaths -JobRoot $retryJob
    $retryDispatch = (Read-TelephoneJson -Path $retryPaths.dispatch).value
    if ([string]::IsNullOrWhiteSpace([string]$retryLaunch.run_root)) {
        $retryLaunch = [ordered]@{ run_root = $retryRoot; state = $(if ([string]$retryLaunch.state) { [string]$retryLaunch.state } else { 'native_complete_host_lingering' }); wake_run_id = $retryId; process_exited = [bool]$retryLaunch.process_exited; native_turn_complete = $true }
    }
    Complete-TelephoneOwnerJobDelivery -JobPaths $retryPaths -Dispatch $retryDispatch -Launch $retryLaunch -WakeIdentity $wake -LeadSessionId $session
    Assert-Repair ([IO.File]::Exists((Join-Path $retryRoot 'lead-wake-ack.json'))) 'Actual V23 retry did not persist receipt-bound ack.'
    $v23Ack = (Read-TelephoneJson -Path (Join-Path $retryRoot 'lead-wake-ack.json')).value
    Assert-Repair ([string]$v23Ack.receipt_sha256 -ceq [string]$receiptRead.identity.sha256) 'Actual V23 ack omitted the frozen receipt.'
    $null = Wait-TelephoneLeadOwnedDrainTerminal -RunRoot $retryRoot -WaitMilliseconds 30000
    Remove-Item Env:TELEPHONE_FAKE_LEAD_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:TELEPHONE_LINE_DIRECTCURSOR_COMMON -ErrorAction SilentlyContinue

    $emptyDrain = Join-Path $testRoot 'empty-drain-run'
    [IO.Directory]::CreateDirectory($emptyDrain) | Out-Null
    $emptyWait = Wait-TelephoneLeadOwnedDrainTerminal -RunRoot $emptyDrain -WaitMilliseconds 800
    Assert-Repair ([bool]$emptyWait.pending) 'Empty drain directory was not pending.'
    Assert-Repair (-not [bool]$emptyWait.host_terminal) 'Empty drain directory fabricated host_terminal.'
    Assert-Repair (-not [bool]$emptyWait.child_terminal) 'Empty drain directory fabricated child_terminal.'
    Assert-Repair (-not [bool]$emptyWait.process_exited) 'Empty drain directory fabricated process_exited.'
    Assert-Repair ([string]$emptyWait.identity_status -ceq 'UNKNOWN') ('Empty drain identity was not UNKNOWN: ' + [string]$emptyWait.identity_status)

    $lingerRoot = Join-Path $testRoot 'linger-drain-run'
    [IO.Directory]::CreateDirectory($lingerRoot) | Out-Null
    $lingerProc = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 60') -PassThru -WindowStyle Hidden
    try {
        $lingerSnap = Get-TelephoneLeadProcessSnapshot -ProcessId ([int]$lingerProc.Id)
        Assert-Repair ($null -ne $lingerSnap) 'Lingering owned host snapshot was missing.'
        $lingerExe = [string]$lingerSnap.executable_path
        if ([string]::IsNullOrWhiteSpace($lingerExe)) { $lingerExe = $pwsh }
        $lingerOwner = [ordered]@{
            protocol_version = 'telephone-line-bound-owner-v1'
            pid = [int]$lingerSnap.pid
            start_time_utc_ticks = [int64]$lingerSnap.start_time_utc_ticks
            started_at_utc = [string]$lingerSnap.started_at_utc
            executable_path = $lingerExe
            session_id = $session
            run_id = 'linger-drain-1'
        }
        $null = Write-TelephoneJsonCreateNew -Path (Join-Path $lingerRoot 'owner.json') -Value $lingerOwner
        $null = Write-TelephoneJsonCreateNew -Path (Join-Path $lingerRoot 'host-drain-lifecycle.json') -Value ([ordered]@{
            protocol_version = 'telephone-line-drained-process-v1'
            pid = [int]$lingerSnap.pid
            start_time_utc_ticks = [int64]$lingerSnap.start_time_utc_ticks
            executable_path = $lingerExe
            session_id = $session
            run_id = 'linger-drain-1'
            process_exited = $false
            stdout_eof = $false
            stderr_eof = $false
            native_turn_complete = $true
            recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        })
        $lingerWait = Wait-TelephoneLeadOwnedDrainTerminal -RunRoot $lingerRoot -WaitMilliseconds 1200
        Assert-Repair ([bool]$lingerWait.pending) 'Lingering owned host was treated as drain terminal.'
        Assert-Repair (-not [bool]$lingerWait.host_terminal) 'Lingering owned host fabricated host_terminal.'
        Assert-Repair (-not [bool]$lingerWait.process_exited) 'Lingering owned host fabricated process_exited.'
        Assert-Repair ([bool]$lingerWait.host_alive) 'Lingering owned host was not observed alive.'
        $stillLive = $null
        try { $stillLive = Get-Process -Id ([int]$lingerProc.Id) -ErrorAction SilentlyContinue } catch { $stillLive = $null }
        Assert-Repair ($null -ne $stillLive) 'Lingering-host proof killed the process as recovery.'
        if ($null -ne $stillLive) { $stillLive.Dispose() }
    } finally {
        try { Stop-Process -Id ([int]$lingerProc.Id) -Force -ErrorAction SilentlyContinue } catch { }
        try { $lingerProc.Dispose() } catch { }
    }

    $curSnap = Get-TelephoneLeadProcessSnapshot -ProcessId $PID
    Assert-Repair ($null -ne $curSnap) 'Current host process snapshot was missing for the foreign-lifecycle negative.'
    $curExe = [string]$curSnap.executable_path
    if ([string]::IsNullOrWhiteSpace($curExe)) { $curExe = $pwsh }
    $foreignLifeRoot = Join-Path $testRoot 'foreign-lifecycle-run'
    [IO.Directory]::CreateDirectory($foreignLifeRoot) | Out-Null
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $foreignLifeRoot 'lead-run.json') -Value ([ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = 'current-live-1'
        requested_run_id = 'current-live-1'
        resume_session_id = $session
        session_id = $session
        events_path = (Join-Path $foreignLifeRoot 'codex-events.jsonl')
        cli_child_expected = $false
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    [IO.File]::WriteAllText((Join-Path $foreignLifeRoot 'codex-events.jsonl'), '', [Text.UTF8Encoding]::new($false))
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $foreignLifeRoot 'owner.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-bound-owner-v1'
        pid = [int]$curSnap.pid
        start_time_utc_ticks = [int64]$curSnap.start_time_utc_ticks
        started_at_utc = [string]$curSnap.started_at_utc
        executable_path = $curExe
        session_id = $session
        run_id = 'current-live-1'
        role = 'host'
    })
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $foreignLifeRoot 'host-drain-lifecycle.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-drained-process-v1'
        pid = 424242
        start_time_utc_ticks = [int64]123456
        executable_path = $pwsh
        session_id = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
        run_id = 'other-run-dead'
        process_exited = $true
        stdout_eof = $true
        stderr_eof = $true
        native_turn_complete = $true
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $foreignWait = Wait-TelephoneLeadOwnedDrainTerminal -RunRoot $foreignLifeRoot -WaitMilliseconds 800
    Assert-Repair ([bool]$foreignWait.host_alive) 'Current live host was not observed alive beside a foreign lifecycle file.'
    Assert-Repair ([bool]$foreignWait.pending) 'Foreign session/run lifecycle made the current alive host drain complete.'
    Assert-Repair (-not [bool]$foreignWait.host_terminal) 'Foreign lifecycle fabricated host_terminal for the current host.'
    Assert-Repair (-not [bool]$foreignWait.process_exited) 'Foreign lifecycle fabricated process_exited for the current host.'
    Assert-Repair ([string]$foreignWait.identity_status -ceq 'BOUND') ('Current host identity was not BOUND: ' + [string]$foreignWait.identity_status)

    $entryRun = 'entry-native-1'
    $entryLauncher = Join-Path $testRoot 'entry-native-host.ps1'
    [IO.File]::WriteAllText($entryLauncher, @'
param([string]$WorktreePath,[string]$PromptFile,[string]$ResumeSessionId,[string]$RunId,[string]$StateRootOverride)
$ErrorActionPreference = "Stop"
$run = [IO.Path]::GetFullPath((Join-Path $StateRootOverride $RunId))
[IO.Directory]::CreateDirectory($run) | Out-Null
$turn = [string]$env:TELEPHONE_TEST_LEAD_TURNS
if (-not [string]::IsNullOrWhiteSpace($turn)) {
    $row = [ordered]@{ run_id = $RunId; at_utc = [DateTimeOffset]::UtcNow.ToString("o") }
    [IO.File]::AppendAllText($turn, (($row | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}
$utf8 = [Text.UTF8Encoding]::new($false)
$hostExe = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$promptBytes = [IO.File]::ReadAllBytes($PromptFile)
$promptSha = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($promptBytes))).ToLowerInvariant()
$child = Start-Process -FilePath $hostExe -ArgumentList @("-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 90") -PassThru -WindowStyle Hidden
$childProc = Get-Process -Id ([int]$child.Id)
try {
    $cliDoc = [ordered]@{
        protocol_version = "telephone-line-bound-owner-v1"
        pid = [int]$childProc.Id
        start_time_utc_ticks = [int64]$childProc.StartTime.ToUniversalTime().Ticks
        started_at_utc = $childProc.StartTime.ToUniversalTime().ToString("o")
        executable_path = $hostExe
        session_id = $ResumeSessionId
        run_id = $RunId
        role = "cli"
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
    }
} finally { $childProc.Dispose() }
[IO.File]::WriteAllText((Join-Path $run "cli-child.json"), (($cliDoc | ConvertTo-Json -Depth 8) + "`n"), $utf8)
$leadRun = [ordered]@{
    protocol_version = "huhu-concerto-cli-lead-run-v1"
    run_id = $RunId
    requested_run_id = $RunId
    worktree = [IO.Path]::GetFullPath($WorktreePath).TrimEnd("\")
    resume_session_id = $ResumeSessionId
    session_id = $ResumeSessionId
    events_path = (Join-Path $run "codex-events.jsonl")
    prompt = [ordered]@{ path = [IO.Path]::GetFullPath($PromptFile); bytes = [int64]$promptBytes.Length; sha256 = $promptSha }
    cli_child_expected = $true
    cli_child_started = $true
    created_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
}
[IO.File]::WriteAllText((Join-Path $run "lead-run.json"), (($leadRun | ConvertTo-Json -Depth 8) + "`n"), $utf8)
[IO.File]::WriteAllText((Join-Path $run "native-output.txt"), ("native-turn-bytes-" + $RunId + "`n"), $utf8)
$eventText = '{"type":"thread.started","thread_id":"' + $ResumeSessionId + '"}' + "`n" + '{"type":"turn.started","turn_id":"t-entry"}' + "`n" + '{"type":"turn.completed","turn_id":"t-entry","session_id":"' + $ResumeSessionId + '"}' + "`n"
[IO.File]::WriteAllText((Join-Path $run "codex-events.jsonl"), $eventText, $utf8)
Start-Sleep -Seconds 90
[ordered]@{ run_root = $run; state = "completed"; exit_code = 0 } | ConvertTo-Json -Compress
exit 0
'@, [Text.UTF8Encoding]::new($false))
    $entryAck = Join-Path $leadState ($entryRun + '\lead-wake-ack.json')
    $entryDelivery = Join-Path $testRoot 'jobs\entry-native-delivery.json'
    [IO.Directory]::CreateDirectory((Join-Path $testRoot 'jobs')) | Out-Null
    $entryHostPid = 0
    $entryChildPid = 0
    $entryForeign = $null
    try {
        $entryForeign = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 90') -PassThru -WindowStyle Hidden
        $entryStarted = [DateTimeOffset]::UtcNow
        $entryLaunch = Invoke-TelephoneFrozenLeadLauncher -LauncherPath $entryLauncher -ExtraArguments @('-StateRootOverride', $leadState) -Worktree $work -PromptFile $prompt -SessionId $session -RunId $entryRun
        $entryElapsed = ([DateTimeOffset]::UtcNow - $entryStarted).TotalSeconds
        Assert-Repair ([string]$entryLaunch.state -ceq 'native_complete_host_lingering') ('Normal-entry linger did not return through FrozenLeadLauncher: ' + [string]$entryLaunch.state)
        Assert-Repair ($entryElapsed -lt 12) ('Normal-entry launcher still waited for host exit: ' + [string]$entryElapsed + 's')
        $entryRoot = [IO.Path]::GetFullPath((Join-Path $leadState $entryRun)).TrimEnd('\')
        Assert-Repair ([IO.File]::Exists((Join-Path $entryRoot 'cli-child.json'))) 'Normal-entry launcher did not persist cli-child identity.'
        Assert-Repair ([IO.File]::Exists((Join-Path $entryRoot 'native-output.txt'))) 'Normal-entry launcher did not persist native-output.txt.'
        $entryNativeBytes = [IO.File]::ReadAllBytes((Join-Path $entryRoot 'native-output.txt'))
        $entryNativeSha = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($entryNativeBytes))).ToLowerInvariant()
        $entryOwner = (Read-TelephoneJson -Path (Join-Path $entryRoot 'owner.json')).value
        $entryChild = (Read-TelephoneJson -Path (Join-Path $entryRoot 'cli-child.json')).value
        $entryHostPid = [int]$entryOwner.pid
        $entryChildPid = [int]$entryChild.pid
        $entryHostTicks = [int64]$entryOwner.start_time_utc_ticks
        $entryChildTicks = [int64]$entryChild.start_time_utc_ticks
        $entryHostExe = [string]$entryOwner.executable_path
        $entryChildExe = [string]$entryChild.executable_path
        $entryHostLive = Get-TelephoneLeadProcessSnapshot -ProcessId $entryHostPid
        $entryChildLive = Get-TelephoneLeadProcessSnapshot -ProcessId $entryChildPid
        Assert-Repair ($null -ne $entryHostLive) 'Normal-entry host was not alive before supervisor entry.'
        Assert-Repair ($null -ne $entryChildLive) 'Normal-entry CLI child was not alive before supervisor entry.'
        Assert-Repair (([int64]$entryHostLive.start_time_utc_ticks) -eq $entryHostTicks) 'Normal-entry host ticks drifted before supervisor entry.'
        Assert-Repair (([int64]$entryChildLive.start_time_utc_ticks) -eq $entryChildTicks) 'Normal-entry child ticks drifted before supervisor entry.'
        Assert-Repair ([string]::Equals([string]$entryHostLive.executable_path, $entryHostExe, [StringComparison]::OrdinalIgnoreCase) -or [string]::IsNullOrWhiteSpace([string]$entryHostLive.executable_path)) 'Normal-entry host executable drifted before supervisor entry.'
        Assert-Repair ([string]::Equals([string]$entryChildLive.executable_path, $entryChildExe, [StringComparison]::OrdinalIgnoreCase) -or [string]::IsNullOrWhiteSpace([string]$entryChildLive.executable_path)) 'Normal-entry child executable drifted before supervisor entry.'
        $entryAckRecord = Wait-TelephoneLeadWakeAcknowledged -RunRoot $entryRoot -ExpectedSessionId $session -ExpectedRunId $entryRun -StartupTimeoutSeconds 15
        Assert-Repair ([string]$entryAckRecord.event -ceq 'turn.started') 'Production wake ack did not bind the launcher turn.started.'
        $ackBefore = Get-RepairSha256 -Path $entryAck
        $turnsBefore = @([regex]::Matches([IO.File]::ReadAllText($turnLog), [regex]::Escape($entryRun))).Count
        Assert-Repair ($turnsBefore -eq 1) ('Normal-entry launcher duplicate model-start before recovery: ' + [string]$turnsBefore)
        $entryLineState = Join-Path $testRoot 'entry-line-state'
        $entryJob = Join-Path $entryLineState ('jobs\cccccccc-bbbb-cccc-dddd-eeeeeeeeeee6')
        [IO.Directory]::CreateDirectory($entryJob) | Out-Null
        $entrySupRunId = 'cccccccc-bbbb-cccc-dddd-eeeeeeeeeee6'
        $null = Save-TelephoneNamedLaunchResult -Path (Join-Path $entryJob 'wake-launch-result.json') -Launch $entryLaunch -RunId $entryRun -WakeKey 'entry-native-wake' -LineJobId $entrySupRunId
        $null = Write-TelephoneJsonCreateNew -Path (Join-Path $entryJob 'supervisor-lineage.json') -Value ([ordered]@{
            protocol_version = 'telephone-line-supervisor-lineage-v1'
            supervisor_run_id = $entrySupRunId
            line_job_id = $entrySupRunId
            lead_session_id = $session
            lead_identity_sha256 = ('e' * 64)
            batch_id = 'entry-native-batch'
            package_id = 'entry-native-package'
        })
        $entrySup = Join-Path $testRoot 'entry-supervisor-iso'
        $null = Initialize-TelephoneSupervisorLayout -StateRoot $entrySup
        $entryCore = Join-Path $repoRoot 'src\core\Start-TelephoneLineJob.ps1'
        $entryReq = [ordered]@{
            protocol_version = 'telephone-line-wired-supervisor-request-v1'
            run_id = $entrySupRunId
            project = 'correction7-entry'
            stage = 'focused'
            lead_session_id = $session
            lead_run_id = $entryRun
            summary = 'claimed nested drain recovery'
            worktree = $work
            command = [ordered]@{
                executable = $pwsh
                working_directory = $work
                arguments = @(
                    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                    '-File', $entryCore, '-RequestFile', (Join-Path $entryJob 'dispatch.json'),
                    '-StateRoot', $entryLineState
                )
            }
            installed_version = [ordered]@{
                version_id = ('d' * 64)
                source_sha256 = ('d' * 64)
                install_root = $repoRoot
            }
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        Assert-Repair (-not [string]::Equals([IO.Path]::GetFullPath([string]$entryReq.command.working_directory).TrimEnd('\'), $entryRoot, [StringComparison]::OrdinalIgnoreCase)) 'Entry request substituted nested run root as cwd.'
        Assert-Repair (-not [string]::Equals([IO.Path]::GetFullPath([string]$entryReq.worktree).TrimEnd('\'), $entryRoot, [StringComparison]::OrdinalIgnoreCase)) 'Entry request substituted nested run root as worktree.'
        $entryReq['request_sha256'] = Get-TelephoneSupervisorRequestHash -Request $entryReq
        $null = Assert-TelephoneSupervisorRequestValue -Request $entryReq
        $claimedPath = Get-TelephoneSupervisorRecordPath -StateRoot $entrySup -Kind claimed -RunId $entrySupRunId
        $claimedBytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-TelephoneSupervisorJson -Value $entryReq))
        $null = Write-TelephoneBytesCreateNew -Path $claimedPath -Bytes $claimedBytes
        $null = Write-TelephoneSupervisorRunOwner -StateRoot $entrySup -Owner ([ordered]@{
            protocol_version = 'telephone-line-wired-supervisor-owner-v1'
            kind = 'run'
            run_id = $entrySupRunId
            request_sha256 = [string]$entryReq.request_sha256
            pid = 999999
            start_time_utc_ticks = [int64]1
            started_at_utc = '2020-01-01T00:00:00Z'
            lead_session_id = $session
            lead_run_id = $entryRun
        })
        $leadDecoy = Join-Path $testRoot 'lead-state-decoy'
        [IO.Directory]::CreateDirectory($leadDecoy) | Out-Null
        $previousEntryLead = $env:TELEPHONE_LINE_LEAD_STATE_ROOT
        $previousEntryLine = $env:TELEPHONE_LINE_STATE_ROOT
        $env:TELEPHONE_LINE_LEAD_STATE_ROOT = $leadDecoy
        $env:TELEPHONE_LINE_STATE_ROOT = $leadDecoy
        $env:TELEPHONE_LINE_INSTALL_ROOT = $repoRoot
        $entrySupResult = Invoke-RepairSupervisor -StateRoot $entrySup
        $null = $entrySupResult
        $nestedProof = Join-Path $entrySup ('runs\' + $entrySupRunId + '\owned-nested-drain-reconcile.json')
        Assert-Repair ([IO.File]::Exists($nestedProof)) 'Normal-entry supervisor did not persist nested drain reconcile proof.'
        $nestedDoc = (Read-TelephoneJson -Path $nestedProof).value
        Assert-Repair ([string]$nestedDoc.nested_run_root -ceq $entryRoot) ('Normal-entry resolved the wrong nested root: ' + [string]$nestedDoc.nested_run_root)
        Assert-Repair ([bool]$nestedDoc.recovered) ('Normal-entry supervisor nested drain did not recover: ' + [string]$nestedDoc.refused)
        Assert-Repair ([string]$nestedDoc.decision -ceq 'owned_nested_drain_incomplete') ('Recoverable drain was treated as finished before reader EOF: ' + [string]$nestedDoc.decision)
        $hostAfter = $null
        try { $hostAfter = Get-Process -Id $entryHostPid -ErrorAction SilentlyContinue } catch { $hostAfter = $null }
        Assert-Repair ($null -eq $hostAfter) 'Normal-entry supervisor left the owned lingering host running.'
        $childAfter = $null
        try { $childAfter = Get-Process -Id $entryChildPid -ErrorAction SilentlyContinue } catch { $childAfter = $null }
        Assert-Repair ($null -eq $childAfter) 'Normal-entry supervisor left the owned CLI child running.'
        $foreignAfter = $null
        try { $foreignAfter = Get-Process -Id ([int]$entryForeign.Id) -ErrorAction SilentlyContinue } catch { $foreignAfter = $null }
        Assert-Repair ($null -ne $foreignAfter) 'Normal-entry supervisor touched a foreign process.'
        if ($null -ne $foreignAfter) { $foreignAfter.Dispose() }
        $recoveredDrain = Wait-TelephoneLeadOwnedDrainTerminal -RunRoot $entryRoot -WaitMilliseconds 8000
        Assert-Repair (-not [bool]$recoveredDrain.pending) ('Owned readers did not reach a terminal drain: ' + [string]$recoveredDrain.pending)
        Assert-Repair ([bool]$recoveredDrain.host_terminal) 'Owned host drain did not become terminal after reader completion.'
        Assert-Repair ([bool]$recoveredDrain.stdout_eof) 'Owned host drain lost stdout EOF.'
        Assert-Repair ([bool]$recoveredDrain.stderr_eof) 'Owned host drain lost stderr EOF.'
        $hostObs = Get-TelephoneLeadOwnedStreamObservation -RunRoot $entryRoot -Identity $entryOwner -Role host -SessionId $session -RunId $entryRun
        Assert-Repair ([string]$hostObs.observation -ceq 'handoff_complete' -or [string]$hostObs.observation -ceq 'open_drain_readers') ('Owned host stream was not exact-producer EOF: ' + [string]$hostObs.observation)
        Assert-Repair ([bool]$hostObs.stdout_eof) 'Owned host observation lost stdout EOF.'
        Assert-Repair ($null -ne $hostObs.last_output) 'Owned host observation lost durable last output.'
        Assert-Repair ([string]$hostObs.last_output.sha256 -ceq $entryNativeSha) 'Owned host observation last output did not match launcher native-output.txt.'
        $entrySupResult2 = Invoke-RepairSupervisor -StateRoot $entrySup
        $null = $entrySupResult2
        $nestedDoc2 = (Read-TelephoneJson -Path $nestedProof).value
        Assert-Repair ([string]$nestedDoc2.decision -ceq 'owned_nested_drain_complete') ('Second supervisor entry did not observe recoverable drain completion: ' + [string]$nestedDoc2.decision)
        Assert-Repair (-not [bool]$nestedDoc2.drain_pending) 'Completed drain stayed pending on the second supervisor entry.'
        $entryContinue = Invoke-TelephoneLeadWakeReconcile -LaunchResultPath (Join-Path $entryJob 'wake-launch-result.json') -RunId $entryRun -SessionId $session -ExtraArguments @('-StateRootOverride', $leadState) -Worktree $work
        Assert-Repair ([string]$entryContinue.decision -cin @('recovered_attach', 'attached')) ('Same-session continuation relaunched instead of attaching: ' + [string]$entryContinue.decision)
        $turnsAfter = @([regex]::Matches([IO.File]::ReadAllText($turnLog), [regex]::Escape($entryRun))).Count
        Assert-Repair ($turnsAfter -eq 1) ('Normal-entry recovery duplicate model-start: ' + [string]$turnsAfter)
        Assert-Repair ((Get-RepairSha256 -Path $entryAck) -ceq $ackBefore) 'Supervisor recovery mutated the production wake ack.'
        Assert-Repair ((Get-RepairSha256 -Path (Join-Path $entryRoot 'native-output.txt')) -ceq $entryNativeSha) 'Supervisor recovery mutated launcher native-output.txt.'
        $entryOutbox = Get-TelephoneSupervisorRecordPath -StateRoot $entrySup -Kind outbox -RunId $entrySupRunId
        Assert-Repair (-not [IO.File]::Exists($entryOutbox)) 'Nested native-complete recovery wrote SUPERVISOR_OWNER_DEAD_NO_RERUN.'
        $env:TELEPHONE_LINE_LEAD_STATE_ROOT = $previousEntryLead
        $env:TELEPHONE_LINE_STATE_ROOT = $previousEntryLine
    } finally {
        if ($entryHostPid -gt 0) { try { Stop-Process -Id $entryHostPid -Force -ErrorAction SilentlyContinue } catch { } }
        if ($entryChildPid -gt 0) { try { Stop-Process -Id $entryChildPid -Force -ErrorAction SilentlyContinue } catch { } }
        if ($null -ne $entryForeign) { try { Stop-Process -Id ([int]$entryForeign.Id) -Force -ErrorAction SilentlyContinue } catch { }; try { $entryForeign.Dispose() } catch { } }
    }

    $d4Root = Join-Path $testRoot 'd4-current-row'
    $d4Work = Join-Path $d4Root 'worktree'
    $d4Jobs = Join-Path $d4Root 'jobs'
    $d4DirectParent = Join-Path $d4Root 'direct-jobs'
    $d4LeadParent = Join-Path $d4Root 'lead-runs'
    $d4CurrentId = '11111111-bbbb-cccc-dddd-eeeeeeee0001'
    $d4StaleId = '11111111-bbbb-cccc-dddd-eeeeeeee0002'
    $d4UnrelatedId = '11111111-bbbb-cccc-dddd-eeeeeeee0003'
    $d4LiveId = '11111111-bbbb-cccc-dddd-eeeeeeee0004'
    $d4UnknownId = '11111111-bbbb-cccc-dddd-eeeeeeee0005'
    $d4DirectId = '22222222-bbbb-cccc-dddd-eeeeeeee0001'
    $d4DirectRoot = Join-Path $d4DirectParent $d4DirectId
    $d4UnrelatedSession = '99999999-9999-9999-9999-999999999999'
    foreach ($d in @($d4Work, $d4Jobs, $d4DirectParent, $d4LeadParent, $d4DirectRoot)) { [IO.Directory]::CreateDirectory($d) | Out-Null }
    $d4Utf8 = [Text.UTF8Encoding]::new($false)
    function Write-D4Json {
        param([string]$Path, [object]$Value)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
        [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 16) + "`n"), $d4Utf8)
    }
    $d4Lead = [ordered]@{
        protocol_version = 'telephone-line-lead-binding-v1'
        session_id = $session
        worktree = $d4Work
        launcher = [ordered]@{ path = $dualLauncher; arguments = @() }
    }
    $d4Command = [ordered]@{ executable = $pwsh; working_directory = $d4Work; arguments = @('-NoLogo') }
    foreach ($pair in @(
        @{ Id = $d4StaleId; Batch = 'd4-stale-batch'; Created = '2026-09-09T10:00:00Z'; Session = $session },
        @{ Id = $d4CurrentId; Batch = 'd4-current-batch'; Created = '2026-09-09T12:00:00Z'; Session = $session },
        @{ Id = $d4UnrelatedId; Batch = 'd4-unrelated-batch'; Created = '2026-09-09T11:30:00Z'; Session = $d4UnrelatedSession },
        @{ Id = $d4LiveId; Batch = 'd4-live-batch'; Created = '2026-09-09T11:40:00Z'; Session = $session },
        @{ Id = $d4UnknownId; Batch = 'd4-unknown-batch'; Created = '2026-09-09T11:50:00Z'; Session = $session }
    )) {
        $jobDir = Join-Path $d4Jobs ([string]$pair.Id)
        [IO.Directory]::CreateDirectory($jobDir) | Out-Null
        $lead = [ordered]@{
            protocol_version = 'telephone-line-lead-binding-v1'
            session_id = [string]$pair.Session
            worktree = $d4Work
            launcher = [ordered]@{ path = $dualLauncher; arguments = @() }
        }
        Write-D4Json -Path (Join-Path $jobDir 'dispatch.json') -Value ([ordered]@{
            protocol_version = 'telephone-line-dispatch-v1'
            line_job_id = [string]$pair.Id
            project = 'd4-current-row'
            stage = 'focused'
            role = 'execution'
            route = 'direct-cursor'
            summary = ('d4-' + [string]$pair.Id)
            batch = [ordered]@{ batch_id = [string]$pair.Batch; implicit = $false }
            lead = $lead
            command = $d4Command
            created_at_utc = [string]$pair.Created
        })
        Write-D4Json -Path (Join-Path $jobDir 'receipt.json') -Value ([ordered]@{
            protocol_version = 'telephone-line-receipt-v1'
            line_job_id = [string]$pair.Id
            project = 'd4-current-row'
            transport_complete = $true
        })
        [IO.File]::WriteAllText((Join-Path $jobDir 'out.txt'), '', $d4Utf8)
        [IO.File]::WriteAllText((Join-Path $jobDir 'err.txt'), '', $d4Utf8)
    }
    $d4LiveJob = Join-Path $d4Jobs $d4LiveId
    Write-D4Json -Path (Join-Path $d4LiveJob 'owner.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-bound-owner-v1'
        pid = [int]$curSnap.pid
        start_time_utc_ticks = [int64]$curSnap.start_time_utc_ticks
        started_at_utc = [string]$curSnap.started_at_utc
        executable_path = $curExe
        session_id = $session
        run_id = 'd4-live-owner'
    })
    Write-D4Json -Path (Join-Path $d4DirectRoot 'request.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-direct-cursor-request-v1'
        job_id = $d4DirectId
        workspace = $d4Work
        model = 'cursor-grok-4.6-xhigh'
        reasoning_effort = 'xhigh'
        route = 'direct-cursor'
        created_at_utc = '2026-09-09T12:00:00Z'
    })
    $d4StaleReceiptPath = Join-Path (Join-Path $d4Jobs $d4StaleId) 'receipt.json'
    $d4StaleReceiptSha = (Get-FileHash -LiteralPath $d4StaleReceiptPath -Algorithm SHA256).Hash
    $d4Registry = Join-Path $d4Root 'heartbeat-registry.json'
    Write-D4Json -Path $d4Registry -Value ([ordered]@{
        protocol_version = 'pascal-master-heartbeat-registry-v1'
        projects = @([ordered]@{
            project_id = 'd4-current-row'
            dispatch_project_id = 'd4-current-row'
            display_name = 'd4-current-row'
            worktree = $d4Work
            status = 'ACTIVE'
            lead_model = 'cursor-grok-4.6-xhigh'
            lead_thread_id = $session
            current_line_job_id = $d4CurrentId
            current_direct_job_id = $d4DirectId
            current_direct_job_root = $d4DirectRoot
            worker_telephone_job_ids = @($d4CurrentId)
            worker_direct_cursor_job_ids = @($d4DirectId)
            telephone_state_roots = @($d4Root)
            lead_run_parent_roots = @($d4LeadParent)
            current_stage = 'AUDIT_DRIVEN'
            ordinary_acceptance = 'FAIL'
        })
    })
    $d4Config = [pscustomobject]@{
        discovery_roots = @($d4Root)
        project_registry_paths = @($d4Registry)
    }
    $d4SnapBefore = Get-StatusSnapshot -Config $d4Config
    $d4IdsBefore = @($d4SnapBefore.jobs | ForEach-Object { [string]$_.id })
    Assert-Repair ($d4IdsBefore -contains $d4CurrentId) 'Actual current-row snapshot lost the registered current pair.'
    Assert-Repair ($d4IdsBefore -contains $d4StaleId) 'Stale pair was hidden before trusted consumption evidence existed.'
    Assert-Repair ($d4IdsBefore -contains $d4UnrelatedId) 'Unrelated session job lost visibility.'
    Assert-Repair ($d4IdsBefore -contains $d4LiveId) 'Live owned job lost visibility.'
    Assert-Repair ($d4IdsBefore -contains $d4UnknownId) 'Unknown job lost visibility.'
    $d4CurrentRow = @($d4SnapBefore.jobs | Where-Object { [string]$_.id -ceq $d4CurrentId })[0]
    Assert-Repair ([string]$d4CurrentRow.identity_state -ceq 'ok') ('Registered exact pair stayed unregistered through snapshot: ' + [string]$d4CurrentRow.identity_label)
    Assert-Repair ([string]$d4CurrentRow.identity_label -notmatch '未登记') ('Registered executor identity stayed unregistered: ' + [string]$d4CurrentRow.identity_label)
    $d4Consume = Join-Path $d4LeadParent 'consume-stale'
    [IO.Directory]::CreateDirectory($d4Consume) | Out-Null
    $d4Prompt = Join-Path $d4Consume 'prompt.md'
    [IO.File]::WriteAllText($d4Prompt, ("# Telephone-line durable receipt delivery`n`n- line_job_id: $d4StaleId`n- receipt_sha256: $d4StaleReceiptSha`n"), $d4Utf8)
    $d4PromptId = Get-TelephoneFileIdentity -Path $d4Prompt
    Write-D4Json -Path (Join-Path $d4Consume 'lead-run.json') -Value ([ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = 'd4-consume-stale'
        requested_run_id = 'd4-consume-stale'
        resume_session_id = $session
        worktree = $d4Work
        events_path = (Join-Path $d4Consume 'codex-events.jsonl')
        prompt = [ordered]@{ path = $d4Prompt; bytes = [int64]$d4PromptId.bytes; sha256 = [string]$d4PromptId.sha256 }
        created_at_utc = '2026-09-09T11:00:00Z'
    })
    [IO.File]::WriteAllText((Join-Path $d4Consume 'codex-events.jsonl'), ('{"type":"thread.started","thread_id":"' + $session + '"}' + "`n" + '{"type":"turn.started","turn_id":"t-d4"}' + "`n" + '{"type":"turn.completed","turn_id":"t-d4","session_id":"' + $session + '"}' + "`n"), $d4Utf8)
    [IO.File]::WriteAllText((Join-Path $d4Consume 'lead-final.txt'), "success = True`nTELEPHONE_LINE_V0_1_LOCAL_RC_READY_FOR_PASCAL`n", $d4Utf8)
    Write-D4Json -Path (Join-Path $d4Consume 'host-terminal.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-host-terminal-v1'
        run_id = 'd4-consume-stale'
        session_id = $session
        exit_code = 0
        completed_at_utc = '2026-09-09T11:05:00Z'
    })
    $d4FinalPath = Join-Path $d4Consume 'lead-final.txt'
    $d4RunMetaPath = Join-Path $d4Consume 'lead-run.json'
    $d4TermPath = Join-Path $d4Consume 'host-terminal.json'
    [IO.File]::SetLastWriteTimeUtc($d4FinalPath, [DateTimeOffset]::Parse('2026-09-09T11:05:00Z').UtcDateTime)
    [IO.File]::SetLastWriteTimeUtc($d4RunMetaPath, [DateTimeOffset]::Parse('2026-09-09T11:00:00Z').UtcDateTime)
    [IO.File]::SetLastWriteTimeUtc($d4TermPath, [DateTimeOffset]::Parse('2026-09-09T11:05:00Z').UtcDateTime)
    $d4SnapAfter = Get-StatusSnapshot -Config $d4Config
    $d4IdsAfter = @($d4SnapAfter.jobs | ForEach-Object { [string]$_.id })
    Assert-Repair ($d4IdsAfter -contains $d4CurrentId) 'Current pair disappeared after stale consumption fold.'
    Assert-Repair ($d4IdsAfter -notcontains $d4StaleId) 'Stale pair remained visible after hash-bound trusted consumption.'
    Assert-Repair ($d4IdsAfter -contains $d4UnrelatedId) 'Unrelated session job was folded with the stale pair.'
    Assert-Repair ($d4IdsAfter -contains $d4LiveId) 'Live owned job was folded after stale consumption.'
    Assert-Repair ($d4IdsAfter -contains $d4UnknownId) 'Unknown job was folded after stale consumption.'
    $d4ProofDir = Join-Path $repoRoot '_audit_correction7_artifacts_20260909\proof-final'
    [IO.Directory]::CreateDirectory($d4ProofDir) | Out-Null
    $d4Proof = [ordered]@{
        protocol_version = 'telephone-correction5-d4-current-row-v1'
        before_job_ids = @($d4IdsBefore)
        after_job_ids = @($d4IdsAfter)
        current_identity_label = [string]$d4CurrentRow.identity_label
        current_identity_state = [string]$d4CurrentRow.identity_state
        current_route_job_id = [string]$d4CurrentRow.route_job_id
        after_jobs = @($d4SnapAfter.jobs | ForEach-Object {
            [ordered]@{ id = [string]$_.id; identity_state = [string]$_.identity_state; identity_label = [string]$_.identity_label; source = [string]$_.source; session_id = [string]$_.session_id }
        })
    }
    [IO.File]::WriteAllText((Join-Path $d4ProofDir 'd4-current-row.json'), (($d4Proof | ConvertTo-Json -Depth 16) + "`n"), $d4Utf8)
    [IO.File]::WriteAllText((Join-Path $testRoot 'd4-current-row.json'), (($d4Proof | ConvertTo-Json -Depth 16) + "`n"), $d4Utf8)

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

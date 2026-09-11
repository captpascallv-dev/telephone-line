# SPDX-License-Identifier: MPL-2.0
# Focused Lead-runtime hardening checks. Isolated fixtures only; no shared App,
# users, or Task Scheduler mutation. Does not repeat packaging/install/supervisor suites.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'src\core\TelephoneLine.Common.ps1')
. (Join-Path $repoRoot 'src\dashboard\TelephoneDashboard.Common.ps1')
. (Join-Path $repoRoot 'src\dashboard\TelephoneDashboard.Projection.ps1')
$pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$assertions = 0
$tracked = [Collections.Generic.List[object]]::new()
$sleeper = $null
$previousStable = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_STABLE_CLI', 'Process')
$previousPolicy = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_STABLE_CLI_POLICY', 'Process')
$previousLeadState = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_LEAD_STATE_ROOT', 'Process')
$previousSupervisorRunId = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_SUPERVISOR_RUN_ID', 'Process')
[Environment]::SetEnvironmentVariable('TELEPHONE_LINE_SUPERVISOR_RUN_ID', '', 'Process')

function Assert-Hardening {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Add-HardeningTracked {
    param($Owner)
    if ($null -eq $Owner) { return }
    if ($Owner -isnot [Collections.IDictionary] -or -not $Owner.Contains('pid')) { return }
    [void]$tracked.Add($Owner)
}

try {
    $env:TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY = '1'
    $env:TELEPHONE_LINE_DASHBOARD_OPT_OUT = '1'

    $missing = Invoke-TelephoneLeadCreateProcessProbe -Executable (Join-Path $testRoot 'missing-cli\codex.exe')
    Assert-Hardening (-not [bool]$missing.path_exists) 'Missing CLI was reported as present.'
    Assert-Hardening ([string]$missing.error_code -ceq 'LEAD_CLI_UNLAUNCHABLE') 'Missing CLI did not keep LEAD_CLI_UNLAUNCHABLE.'
    Assert-Hardening ([string]$missing.stage -ceq 'path') 'Missing CLI stage was not path.'

    $replaced = Join-Path $testRoot 'replaced.exe'
    [IO.File]::WriteAllText($replaced, "not-an-executable`n", [Text.UTF8Encoding]::new($false))
    $replacedProbe = Invoke-TelephoneLeadCreateProcessProbe -Executable $replaced
    Assert-Hardening ([bool]$replacedProbe.path_exists) 'Replaced file was not seen on disk.'
    Assert-Hardening (-not [bool]$replacedProbe.create_process_ok) 'Text-as-exe CreateProcess was treated as success.'
    Assert-Hardening ([string]$replacedProbe.error_code -ceq 'LEAD_CLI_UNLAUNCHABLE') 'Replaced executable did not retain pending unlaunchable code.'
    Assert-Hardening ([string]$replacedProbe.win32_error -ne '') 'Replaced executable lacked Win32/stage evidence.'

    $pwshProbe = Invoke-TelephoneLeadCreateProcessProbe -Executable $pwsh
    Assert-Hardening ([bool]$pwshProbe.create_process_ok) 'pwsh --version CreateProcess failed.'
    Assert-Hardening ([int]$pwshProbe.exit_code -eq 0) 'pwsh --version exit was not 0.'
    Assert-Hardening (-not [string]::IsNullOrWhiteSpace([string]$pwshProbe.version_text)) 'pwsh --version stdout was empty.'

    $vanished = Join-Path $testRoot 'gone-app-version\8e5b6932251c2c1c\codex.exe'
    $env:TELEPHONE_LINE_STABLE_CLI = $pwsh
    $resolved = Resolve-TelephoneLeadCliExecutable -FrozenExecutable $vanished -Probe
    Assert-Hardening ([bool]$resolved.launchable) 'Configured stable CLI was not used after frozen path vanished.'
    Assert-Hardening ([bool]$resolved.reconciled) 'Vanished frozen path was not marked reconciled.'
    Assert-Hardening ([string]::Equals([string]$resolved.executable, $pwsh, [StringComparison]::OrdinalIgnoreCase)) 'Reconcile did not select the configured executable.'

    $drainScript = Join-Path $testRoot 'drain-child.ps1'
    [IO.File]::WriteAllText($drainScript, @'
$ErrorActionPreference = "Stop"
$stdout = New-Object System.Text.StringBuilder
$stderr = New-Object System.Text.StringBuilder
1..40 | ForEach-Object { [void]$stdout.Append(("O" * 256) + "`n"); [void]$stderr.Append(("E" * 256) + "`n") }
[Console]::Out.Write($stdout.ToString())
[Console]::Error.Write($stderr.ToString())
exit 0
'@, [Text.UTF8Encoding]::new($false))
    $drain = Invoke-TelephoneLeadDrainedProcess -FileName $pwsh -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $drainScript)
    Assert-Hardening ([bool]$drain.process_exited) 'Drain child did not exit.'
    Assert-Hardening ([int]$drain.exit_code -eq 0) 'Drain child exit was not 0.'
    Assert-Hardening ([bool]$drain.stdout_eof) 'Stdout EOF was not observed.'
    Assert-Hardening ([bool]$drain.stderr_eof) 'Stderr EOF was not observed.'
    Assert-Hardening ([bool]$drain.process_exited -and [bool]$drain.stdout_eof -and [bool]$drain.stderr_eof) 'Exit and EOF were not independently true together.'
    Assert-Hardening (([string]$drain.stdout).Length -gt 1000) 'Drain stdout was unexpectedly small.'

    $session = '01a083ac-dbc3-70c1-a085-f451005dfc48'
    $runId = 'telephone-hardening-turn-check'
    $runRoot = Join-Path $testRoot $runId
    [IO.Directory]::CreateDirectory($runRoot) | Out-Null
    $created = [DateTimeOffset]::Parse('2026-09-09T03:00:00Z').ToString('o')
    $eventsPath = Join-Path $runRoot 'codex-events.jsonl'
    $leadRun = [ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = $runId
        requested_run_id = $runId
        worktree = $testRoot
        resume_session_id = $session
        events_path = $eventsPath
        created_at_utc = $created
    }
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $runRoot 'lead-run.json') -Value $leadRun
    $oldComplete = '{"type":"thread.started","thread_id":"' + $session + '","timestamp":"2026-09-09T01:00:00Z"}' + "`n" + '{"type":"turn.started","turn_id":"old-turn","timestamp":"2026-09-09T01:00:01Z"}' + "`n" + '{"type":"turn.completed","turn_id":"old-turn","timestamp":"2026-09-09T01:51:44Z"}' + "`n"
    [IO.File]::WriteAllText($eventsPath, $oldComplete, [Text.UTF8Encoding]::new($false))
    $oldLife = Get-TelephoneLeadRunLifecycle -RunRoot $runRoot -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-Hardening (-not [bool]$oldLife.native_turn_complete) 'Historical task_complete/turn.completed was treated as this run.'
    $current = '{"type":"thread.started","thread_id":"' + $session + '","timestamp":"2026-09-09T03:01:00Z"}' + "`n" + '{"type":"turn.started","turn_id":"01a08432-6559-7490-ba17-c57a8f5a81f3","timestamp":"2026-09-09T03:01:01Z"}' + "`n" + '{"type":"turn.completed","turn_id":"01a08432-6559-7490-ba17-c57a8f5a81f3","timestamp":"2026-09-09T03:35:14Z"}' + "`n"
    [IO.File]::WriteAllText($eventsPath, $current, [Text.UTF8Encoding]::new($false))
    $curLife = Get-TelephoneLeadRunLifecycle -RunRoot $runRoot -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-Hardening ([bool]$curLife.native_turn_complete) 'Current matching turn.completed was not recognized.'
    Assert-Hardening ([string]$curLife.current_turn_id -ceq '01a08432-6559-7490-ba17-c57a8f5a81f3') 'Current turn id was not bound.'
    $wrong = '{"type":"thread.started","thread_id":"00000000-0000-0000-0000-000000000000","timestamp":"2026-09-09T03:01:00Z"}' + "`n" + '{"type":"turn.started","timestamp":"2026-09-09T03:01:01Z"}' + "`n" + '{"type":"turn.completed","timestamp":"2026-09-09T03:02:00Z"}' + "`n"
    [IO.File]::WriteAllText($eventsPath, $wrong, [Text.UTF8Encoding]::new($false))
    $wrongLife = Get-TelephoneLeadRunLifecycle -RunRoot $runRoot -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-Hardening (-not [bool]$wrongLife.native_turn_complete) 'Wrong session complete was accepted.'
    [IO.File]::WriteAllText($eventsPath, '{"type":"thread.started","thread_id":"' + $session + '"}' + "`n" + '{"type":"turn.started"}' + "`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $runRoot 'lead-final.txt'), "final-only`n", [Text.UTF8Encoding]::new($false))
    $finalOnly = Get-TelephoneLeadRunLifecycle -RunRoot $runRoot -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-Hardening ([bool]$finalOnly.final_only) 'lead-final without current turn.completed was not final_only.'
    Assert-Hardening (-not [bool]$finalOnly.native_turn_complete) 'final-only was treated as native completion.'

    $self = Get-Process -Id $PID
    try {
        $reuseOwner = [ordered]@{
            pid = [int]$PID
            start_time_utc_ticks = ([int64]$self.StartTime.ToUniversalTime().Ticks - 1)
            executable_path = $pwsh
        }
    } finally { $self.Dispose() }
    $live = Get-TelephoneLeadProcessSnapshot -ProcessId $PID
    Assert-Hardening (-not (Test-TelephoneLeadProcessIdentityMatch -Expected $reuseOwner -Actual $live)) 'PID reuse with different start ticks was accepted.'
    $fakeLife = [ordered]@{
        session_id = $session
        run_id = $runId
        binding_ok = $true
        native_turn_complete = $true
        final_only = $false
        rejected = ''
        cli_child_alive = $false
        owner_alive = $true
        owner = $reuseOwner
    }
    $reuseStop = Stop-TelephoneLeadCompletedOwnProcess -Lifecycle $fakeLife -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-Hardening (-not [bool]$reuseStop.recovered) 'PID-reuse owner was stopped.'
    Assert-Hardening ([string]$reuseStop.refused -ceq 'pid_reuse_or_exe_mismatch') 'PID reuse refusal reason drifted.'

    $sleeperScript = Join-Path $testRoot 'sleeper.ps1'
    [IO.File]::WriteAllText($sleeperScript, "Start-Sleep -Seconds 60`n", [Text.UTF8Encoding]::new($false))
    $sleeper = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $sleeperScript) -PassThru -WindowStyle Hidden
    Add-HardeningTracked -Owner ([ordered]@{ pid = [int]$sleeper.Id; start_time_utc_ticks = [int64]$sleeper.StartTime.ToUniversalTime().Ticks })
    $recoverRun = 'telephone-hardening-recover'
    $recoverRoot = Join-Path $testRoot $recoverRun
    [IO.Directory]::CreateDirectory($recoverRoot) | Out-Null
    $recoverEvents = Join-Path $recoverRoot 'codex-events.jsonl'
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $recoverRoot 'lead-run.json') -Value ([ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = $recoverRun
        requested_run_id = $recoverRun
        worktree = $testRoot
        resume_session_id = $session
        events_path = $recoverEvents
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    [IO.File]::WriteAllText($recoverEvents, '{"type":"thread.started","thread_id":"' + $session + '"}' + "`n" + '{"type":"turn.started","turn_id":"current-turn"}' + "`n" + '{"type":"turn.completed","turn_id":"current-turn"}' + "`n", [Text.UTF8Encoding]::new($false))
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $recoverRoot 'owner.json') -Value ([ordered]@{
        pid = [int]$sleeper.Id
        start_time_utc_ticks = [int64]$sleeper.StartTime.ToUniversalTime().Ticks
        started_at_utc = $sleeper.StartTime.ToUniversalTime().ToString('o')
        executable_path = $pwsh
    })
    $recoverLife = Get-TelephoneLeadRunLifecycle -RunRoot $recoverRoot -ExpectedSessionId $session -ExpectedRunId $recoverRun
    Assert-Hardening ([bool]$recoverLife.native_turn_complete) 'Recovery fixture native turn was not complete.'
    Assert-Hardening ([bool]$recoverLife.owner_alive) 'Recovery fixture owner was not alive.'
    $stopped = Stop-TelephoneLeadCompletedOwnProcess -Lifecycle $recoverLife -ExpectedSessionId $session -ExpectedRunId $recoverRun
    Assert-Hardening ([bool]$stopped.recovered) 'Completed-own-process recovery did not stop the exact sleeper.'
    Start-Sleep -Milliseconds 200
    Assert-Hardening (-not (Test-TelephoneOwnerAlive -Owner ([ordered]@{ pid = [int]$sleeper.Id; start_time_utc_ticks = [int64]$sleeper.StartTime.ToUniversalTime().Ticks }))) 'Recovered sleeper was still alive.'

    $spy = Join-Path $testRoot 'spy-launcher.ps1'
    $counter = Join-Path $testRoot 'launcher-count.txt'
    [IO.File]::WriteAllText($counter, '0', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($spy, @"
param([string]`$WorktreePath,[string]`$PromptFile,[string]`$ResumeSessionId,[string]`$RunId,[string]`$StateRootOverride,[string]`$CodexCommand)
`$ErrorActionPreference='Stop'
`$n=[int][IO.File]::ReadAllText('$($counter.Replace('\','\\'))')
[IO.File]::WriteAllText('$($counter.Replace('\','\\'))', ([string](`$n+1)))
[IO.File]::WriteAllText('$($testRoot.Replace('\','\\'))\spy-codex-command.txt', [string]`$CodexCommand)
`$root = Join-Path `$StateRootOverride `$RunId
[IO.Directory]::CreateDirectory(`$root) | Out-Null
[ordered]@{ run_id=`$RunId; run_root=`$root; state='spy' } | ConvertTo-Json -Compress
"@, [Text.UTF8Encoding]::new($false))
    $attachRoot = Join-Path $testRoot 'lead-runs'
    [IO.Directory]::CreateDirectory($attachRoot) | Out-Null
    $oldWake = 'old-wake-run'
    $oldWakeRoot = Join-Path $attachRoot $oldWake
    [IO.Directory]::CreateDirectory($oldWakeRoot) | Out-Null
    $oldEvents = Join-Path $oldWakeRoot 'codex-events.jsonl'
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $oldWakeRoot 'lead-run.json') -Value ([ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = $oldWake
        requested_run_id = $oldWake
        worktree = $testRoot
        resume_session_id = $session
        events_path = $oldEvents
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    [IO.File]::WriteAllText($oldEvents, '{"type":"thread.started","thread_id":"' + $session + '"}' + "`n" + '{"type":"turn.started"}' + "`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $oldWakeRoot 'lead-final.txt'), "done`n", [Text.UTF8Encoding]::new($false))
    $launchResult = Join-Path $testRoot 'wake-launch-result.json'
    $isolated = $false
    try {
        $null = Invoke-TelephoneNamedWakeAttach -LaunchResultPath $launchResult -LauncherPath $spy -ExtraArguments @('-StateRootOverride', $attachRoot) -Worktree $testRoot -PromptFile (Join-Path $testRoot 'prompt.md') -SessionId $session -RunId $oldWake -WakeKey 'wk' -LineJobId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1'
    } catch {
        $isolated = ([string]$_.Exception.Message -ceq 'LEAD_WAKE_AMBIGUOUS')
    }
    Assert-Hardening $isolated 'Incomplete old wake was not isolated as LEAD_WAKE_AMBIGUOUS.'
    Assert-Hardening (([int][IO.File]::ReadAllText($counter)) -eq 0) 'Incomplete old wake silently relaunched the launcher.'
    Assert-Hardening (-not [IO.File]::Exists($launchResult)) 'Ambiguous wake wrote a launch-result.'

    [IO.File]::WriteAllText((Join-Path $testRoot 'prompt.md'), "wake`n", [Text.UTF8Encoding]::new($false))
    $nextId = 'next-eligible-run'
    $nextLaunch = Invoke-TelephoneNamedWakeAttach -LaunchResultPath (Join-Path $testRoot 'next-launch-result.json') -LauncherPath $spy -ExtraArguments @('-StateRootOverride', $attachRoot) -Worktree $testRoot -PromptFile (Join-Path $testRoot 'prompt.md') -SessionId $session -RunId $nextId -WakeKey 'wk2' -LineJobId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee2'
    Assert-Hardening (([int][IO.File]::ReadAllText($counter)) -eq 1) 'Next eligible wake did not invoke the launcher once.'
    $nextIdOk = $false
    if ($nextLaunch -is [Collections.IDictionary] -and $nextLaunch.Contains('wake_run_id') -and [string]$nextLaunch.wake_run_id -ceq $nextId) { $nextIdOk = $true }
    Assert-Hardening $nextIdOk 'Next eligible launch-result run_id drifted.'
    Assert-Hardening (-not [string]::IsNullOrWhiteSpace([string]$nextLaunch.run_root)) 'Next eligible launch-result lacked run_root.'

    $completeWake = 'complete-wake-run'
    $completeRoot = Join-Path $attachRoot $completeWake
    [IO.Directory]::CreateDirectory($completeRoot) | Out-Null
    $completeEvents = Join-Path $completeRoot 'codex-events.jsonl'
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $completeRoot 'lead-run.json') -Value ([ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = $completeWake
        requested_run_id = $completeWake
        worktree = $testRoot
        resume_session_id = $session
        events_path = $completeEvents
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    [IO.File]::WriteAllText($completeEvents, '{"type":"thread.started","thread_id":"' + $session + '"}' + "`n" + '{"type":"turn.started","turn_id":"t1"}' + "`n" + '{"type":"turn.completed","turn_id":"t1"}' + "`n", [Text.UTF8Encoding]::new($false))
    $attached = Invoke-TelephoneNamedWakeAttach -LaunchResultPath (Join-Path $testRoot 'complete-launch-result.json') -LauncherPath $spy -ExtraArguments @('-StateRootOverride', $attachRoot) -Worktree $testRoot -PromptFile (Join-Path $testRoot 'prompt.md') -SessionId $session -RunId $completeWake -WakeKey 'wk3' -LineJobId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee3'
    Assert-Hardening (([int][IO.File]::ReadAllText($counter)) -eq 1) 'Native-complete attach relaunched the launcher.'
    Assert-Hardening ([string]$attached.state -ceq 'recovered_native_complete_host_incomplete') 'Native-complete attach state drifted.'

    $env:TELEPHONE_LINE_STABLE_CLI = $pwsh
    $reconcileId = 'reconcile-cli-run'
    $reconcileLaunch = Invoke-TelephoneNamedWakeAttach -LaunchResultPath (Join-Path $testRoot 'reconcile-launch-result.json') -LauncherPath $spy -ExtraArguments @('-StateRootOverride', $attachRoot, '-CodexCommand', $vanished) -Worktree $testRoot -PromptFile (Join-Path $testRoot 'prompt.md') -SessionId $session -RunId $reconcileId -WakeKey 'wk4' -LineJobId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee5'
    Assert-Hardening (([int][IO.File]::ReadAllText($counter)) -eq 2) 'Configured stable CLI reconcile did not launch once.'
    $seenCmd = [IO.File]::ReadAllText((Join-Path $testRoot 'spy-codex-command.txt')).Trim()
    Assert-Hardening ([string]::Equals($seenCmd, $pwsh, [StringComparison]::OrdinalIgnoreCase)) 'Frozen vanished CodexCommand was not reconciled for this start.'
    Assert-Hardening ([IO.File]::Exists((Join-Path $testRoot 'cli-diagnostic.json'))) 'CLI diagnostic was not written beside the launch-result.'
    $reconcileIdOk = $false
    if ($reconcileLaunch -is [Collections.IDictionary] -and $reconcileLaunch.Contains('wake_run_id') -and [string]$reconcileLaunch.wake_run_id -ceq $reconcileId) { $reconcileIdOk = $true }
    Assert-Hardening $reconcileIdOk 'Reconciled wake run_id drifted.'
    $env:TELEPHONE_LINE_STABLE_CLI = ''

    $jobRoot = Join-Path $testRoot 'dash-job'
    [IO.Directory]::CreateDirectory($jobRoot) | Out-Null
    $jobId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee4'
    $dispatchPath = Join-Path $jobRoot 'dispatch.json'
    $bindingPath = Join-Path $jobRoot 'lead-binding.json'
    $requestPath = Join-Path $jobRoot 'source-request.json'
    $binding = [ordered]@{
        protocol_version = 'telephone-line-lead-binding-v1'
        session_id = $session
        worktree = $testRoot
        launcher = [ordered]@{ path = $spy; arguments = @() }
    }
    $bindingId = Write-TelephoneJsonCreateNew -Path $bindingPath -Value $binding
    $requestId = Write-TelephoneJsonCreateNew -Path $requestPath -Value ([ordered]@{ protocol_version = 'telephone-line-dispatch-v1'; line_job_id = $jobId })
    $dispatch = [ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = $jobId
        project = 'hardening'
        stage = 'SIMULATION'
        role = 'execution'
        route = 'mock-route'
        summary = 'dash'
        lead = $binding
        command = [ordered]@{
            executable = $pwsh
            working_directory = $testRoot
            arguments = @('-NoLogo')
            stdin = $null
        }
        source_request = [ordered]@{ path = [string]$requestId.path; bytes = [int64]$requestId.bytes; sha256 = [string]$requestId.sha256 }
        lead_binding = [ordered]@{ path = [string]$bindingId.path; bytes = [int64]$bindingId.bytes; sha256 = [string]$bindingId.sha256 }
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        absolute_task_timeout = $false
        project_judgment = $false
    }
    $dispatchId = Write-TelephoneJsonCreateNew -Path $dispatchPath -Value $dispatch
    $receipt = [ordered]@{
        protocol_version = 'telephone-line-receipt-v1'
        line_job_id = $jobId
        project = 'hardening'
        stage = 'SIMULATION'
        role = 'execution'
        route = 'mock-route'
        summary = 'dash'
        dispatch = [ordered]@{ path = [string]$dispatchId.path; bytes = [int64]$dispatchId.bytes; sha256 = [string]$dispatchId.sha256 }
        transport_complete = $true
        command_exit_code = 0
        command_error_code = $null
        command_error_message = $null
        stdout = $null
        stderr = $null
        started_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        absolute_task_timeout = $false
        automatic_rerun = $false
        project_judgment = $false
    }
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $jobRoot 'receipt.json') -Value $receipt
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $jobRoot 'wake-reconcile.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-wake-reconcile-v1'
        native_turn_complete = $true
        host_terminal_present = $false
        decision = 'recovered_attach'
    })
    $scan = Get-TelephoneDashboardJobScan -JobRoot $jobRoot
    $codes = @($scan.findings | ForEach-Object { [string]$_.code })
    Assert-Hardening ($codes -contains 'RECEIPT_AWAITING_DELIVERY') 'Dashboard missed receipt awaiting delivery.'
    Assert-Hardening ($codes -contains 'TURN_DONE_HOST_INCOMPLETE') 'Dashboard missed host-incomplete truth.'
    Assert-Hardening ($codes -contains 'CALLBACK_MISSING') 'Dashboard dropped existing callback-missing fail-closed finding.'

    $unknownRoot = Join-Path $testRoot 'unknown-job'
    [IO.Directory]::CreateDirectory($unknownRoot) | Out-Null
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $unknownRoot 'dispatch.json') -Value $dispatch
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $unknownRoot 'lead-binding.json') -Value $binding
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $unknownRoot 'command-owner.json') -Value $reuseOwner
    $unknownScan = Get-TelephoneDashboardJobScan -JobRoot $unknownRoot
    $unknownCodes = @($unknownScan.findings | ForEach-Object { [string]$_.code })
    Assert-Hardening ($unknownCodes -contains 'UNKNOWN_EXECUTION') 'Dashboard missed unknown execution.'

    $policyPath = Join-Path $testRoot 'stable-cli-policy.json'
    $null = Write-TelephoneJsonCreateNew -Path $policyPath -Value ([ordered]@{
        protocol_version = 'telephone-line-stable-cli-policy-v1'
        executable = $pwsh
    })
    $env:TELEPHONE_LINE_STABLE_CLI = ''
    $env:TELEPHONE_LINE_STABLE_CLI_POLICY = $policyPath
    $fromPolicy = Get-TelephoneLeadStableCliPolicy
    Assert-Hardening ([bool]$fromPolicy.present) 'Policy file was not read.'
    Assert-Hardening ([string]::Equals([string]$fromPolicy.executable, $pwsh, [StringComparison]::OrdinalIgnoreCase)) 'Policy executable drifted.'

    $holderRoot = Join-Path $testRoot 'independent-parent'
    [IO.Directory]::CreateDirectory($holderRoot) | Out-Null
    $lateSession = [Guid]::NewGuid().ToString('D')
    $lateRun = 'independent-parent-drain'
    $lateRunRoot = Join-Path $holderRoot $lateRun
    [IO.Directory]::CreateDirectory($lateRunRoot) | Out-Null
    $childScript = Join-Path $holderRoot 'late-child.ps1'
    [IO.File]::WriteAllText($childScript, @"
Set-StrictMode -Version Latest
`$session = '$lateSession'
`$runId = '$lateRun'
Write-Output ('{"type":"thread.started","thread_id":"' + `$session + '"}')
Start-Sleep -Milliseconds 50
Write-Output ('{"type":"turn.started","turn_id":"indep-turn","session_id":"' + `$session + '","run_id":"' + `$runId + '"}')
Start-Sleep -Milliseconds 50
Write-Output ('{"type":"turn.completed","turn_id":"indep-turn","session_id":"' + `$session + '","run_id":"' + `$runId + '"}')
[Console]::Out.Flush()
Start-Sleep -Seconds 2
Write-Output 'LATE-STDOUT-INDEPENDENT'
[Console]::Out.Flush()
[Console]::Error.WriteLine('LATE-STDERR-INDEPENDENT')
[Console]::Error.Flush()
exit 11
"@, [Text.UTF8Encoding]::new($false))
    $holderScript = Join-Path $holderRoot 'drain-holder.ps1'
    $holderOut = Join-Path $holderRoot 'holder-result.json'
    $eventsPath = Join-Path $lateRunRoot 'codex-events.jsonl'
    $errPath = Join-Path $lateRunRoot 'codex-stderr.txt'
    $lifePath = Join-Path $lateRunRoot 'cli-drain-lifecycle.json'
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $lateRunRoot 'lead-run.json') -Value ([ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = $lateRun
        requested_run_id = $lateRun
        worktree = $holderRoot
        resume_session_id = $lateSession
        events_path = $eventsPath
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    [IO.File]::WriteAllText($holderScript, @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
. '$($repoRoot.Replace('\','\\'))\src\core\TelephoneLine.Common.ps1'
`$captured = Invoke-TelephoneLeadDrainedProcess -FileName '$($pwsh.Replace('\','\\'))' -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','$($childScript.Replace('\','\\'))') -WorkingDirectory '$($holderRoot.Replace('\','\\'))' -StdoutPath '$($eventsPath.Replace('\','\\'))' -StderrPath '$($errPath.Replace('\','\\'))' -LifecyclePath '$($lifePath.Replace('\','\\'))' -OwnerPath '$((Join-Path $lateRunRoot 'owner.json').Replace('\','\\'))' -EventsPath '$($eventsPath.Replace('\','\\'))' -SessionId '$lateSession' -RunId '$lateRun' -Role 'cli' -ReturnOnNativeComplete
if (`$captured -is [Collections.IDictionary] -and ((`$captured.Contains('returned_on_native_complete') -and [bool]`$captured.returned_on_native_complete) -or (`$captured.Contains('drain_handoff_pending') -and [bool]`$captured.drain_handoff_pending))) {
    `$measured = Wait-TelephoneLeadOpenDrainUntilMeasured -ProcessId ([int]`$captured.pid) -SessionId '$lateSession' -RunId '$lateRun' -LifecyclePath '$($lifePath.Replace('\','\\'))'
    if (`$null -ne `$measured -and `$measured -is [Collections.IDictionary]) {
        `$captured.process_exited = [bool]`$measured.process_exited
        `$captured.stdout_eof = [bool]`$measured.stdout_eof
        `$captured.stderr_eof = [bool]`$measured.stderr_eof
        if (`$measured.Contains('exit_code') -and `$null -ne `$measured.exit_code) { `$captured.exit_code = [int]`$measured.exit_code }
        `$captured.drain_handoff_pending = `$false
    }
}
[IO.File]::WriteAllText('$($holderOut.Replace('\','\\'))', ((`$captured | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new(`$false))
exit 0
"@, [Text.UTF8Encoding]::new($false))
    $holder = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$holderScript) -PassThru -WindowStyle Hidden
    Add-HardeningTracked -Owner ([ordered]@{ pid = [int]$holder.Id; start_time_utc_ticks = [int64]$holder.StartTime.ToUniversalTime().Ticks })
    Assert-Hardening ($holder.WaitForExit(30000)) 'Independent drain parent did not exit.'
    Assert-Hardening ([int]$holder.ExitCode -eq 0) 'Independent drain parent did not exit 0 after measured EOF.'
    Assert-Hardening ([IO.File]::Exists($holderOut)) 'Independent drain parent did not persist its result after exit.'
    $holderDoc = Get-Content -LiteralPath $holderOut -Raw | ConvertFrom-Json -AsHashtable
    Assert-Hardening ([bool]$holderDoc.process_exited -and [bool]$holderDoc.stdout_eof -and [bool]$holderDoc.stderr_eof) 'Independent parent did not retain measured exit and EOF after it disappeared.'
    Assert-Hardening ([int]$holderDoc.exit_code -eq 11) 'Independent parent did not retain the child OS exit.'
    $stdoutText = [IO.File]::ReadAllText($eventsPath)
    $stderrText = [IO.File]::ReadAllText($errPath)
    Assert-Hardening ($stdoutText.Contains('LATE-STDOUT-INDEPENDENT')) 'Independent parent truncated stdout after native complete.'
    Assert-Hardening ($stderrText.Contains('LATE-STDERR-INDEPENDENT')) 'Independent parent truncated stderr after native complete.'
    $pending = [ordered]@{
        pid = [int]$holderDoc.pid
        start_time_utc_ticks = [int64]$holderDoc.start_time_utc_ticks
        started_at_utc = [string]$holderDoc.started_at_utc
        executable_path = [string]$holderDoc.executable_path
    }
    Write-TelephoneLeadDrainLifecycleFile -Path $lifePath -Identity $pending -ProcessExited $false -StdoutEof $false -StderrEof $false -NativeTurnComplete $true -Role 'cli' -SessionId $lateSession -RunId $lateRun
    $lifeAfter = Get-Content -LiteralPath $lifePath -Raw | ConvertFrom-Json -AsHashtable
    Assert-Hardening ([bool]$lifeAfter.process_exited -and [bool]$lifeAfter.stdout_eof -and [bool]$lifeAfter.stderr_eof) 'Old pending snapshot overwrote the independent measured terminal.'

    $foreignHold = Join-Path $testRoot 'foreign-hold.ps1'
    [IO.File]::WriteAllText($foreignHold, "Start-Sleep -Seconds 30`n", [Text.UTF8Encoding]::new($false))
    $foreignProc = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$foreignHold) -PassThru -WindowStyle Hidden
    Add-HardeningTracked -Owner ([ordered]@{ pid = [int]$foreignProc.Id; start_time_utc_ticks = [int64]$foreignProc.StartTime.ToUniversalTime().Ticks })
    $foreignId = [ordered]@{
        pid = [int]$foreignProc.Id
        start_time_utc_ticks = ([int64]$foreignProc.StartTime.ToUniversalTime().Ticks - 1)
        executable_path = $pwsh
    }
    $foreignStop = Stop-TelephoneLeadExactOwnedIdentity -Identity $foreignId
    Assert-Hardening (-not [bool]$foreignStop.stopped) 'Foreign PID identity was stopped.'
    Assert-Hardening ([string]$foreignStop.refused -ceq 'pid_reuse_or_exe_mismatch') 'Foreign PID refusal drifted.'

    Write-Output (([ordered]@{
        protocol_version = 'telephone-line-lead-runtime-hardening-test-v1'
        success = $true
        assertions = [int]$assertions
        test_root = $testRoot
    } | ConvertTo-Json -Compress))
}
finally {
    foreach ($owner in @($tracked)) {
        try {
            if (Test-TelephoneOwnerAlive -Owner $owner) { Stop-Process -Id ([int]$owner.pid) -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
    if ($null -ne $sleeper) { try { $sleeper.Dispose() } catch { } }
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_STABLE_CLI', $previousStable, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_STABLE_CLI_POLICY', $previousPolicy, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_LEAD_STATE_ROOT', $previousLeadState, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_SUPERVISOR_RUN_ID', $previousSupervisorRunId, 'Process')
}

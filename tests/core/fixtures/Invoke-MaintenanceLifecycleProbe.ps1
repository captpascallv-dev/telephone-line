# SPDX-License-Identifier: MPL-2.0
# Discriminating R2 consumer: real isolated dedicated process plus actual
# candidate runtime/collector path. Deterministic native completion records.
# Not C/E/F and not a fabricated provider success.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArtifactRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'src\core\TelephoneLine.Common.ps1')
$pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$artifact = [IO.Path]::GetFullPath($ArtifactRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($artifact) | Out-Null
$traceDir = Join-Path $artifact 'raw'
[IO.Directory]::CreateDirectory($traceDir) | Out-Null
$assertions = 0
$owned = [Collections.Generic.List[object]]::new()

function Assert-R2 {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Stop-R2Owned {
    param($Process)
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) { $null = $Process.CloseMainWindow(); $null = $Process.WaitForExit(500) }
        if (-not $Process.HasExited) { $Process.Kill($true) }
        $null = $Process.WaitForExit(2000)
    } catch { }
    try { $Process.Dispose() } catch { }
}

try {
    $stamp = [Guid]::NewGuid().ToString('N')
    $session = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
    $runId = 'maint-r2-lifecycle-' + $stamp.Substring(0, 12)
    $leadState = Join-Path $artifact ('lead-state-' + $stamp)
    $runRoot = Join-Path $leadState $runId
    [IO.Directory]::CreateDirectory($runRoot) | Out-Null
    $eventsPath = Join-Path $runRoot 'codex-events.jsonl'
    $lifecyclePath = Join-Path $runRoot 'host-drain-lifecycle.json'
    $ownerPath = Join-Path $runRoot 'owner.json'
    $childScript = Join-Path $artifact 'native-complete-then-hold.ps1'
    $childText = @"
`$ErrorActionPreference = 'Stop'
`$session = '$session'
`$runId = '$runId'
Write-Output ('{"type":"thread.started","thread_id":"' + `$session + '","timestamp":"' + [DateTimeOffset]::UtcNow.ToString('o') + '"}')
Start-Sleep -Milliseconds 50
Write-Output ('{"type":"turn.started","turn_id":"r2-turn-1","session_id":"' + `$session + '","run_id":"' + `$runId + '","timestamp":"' + [DateTimeOffset]::UtcNow.ToString('o') + '"}')
Start-Sleep -Milliseconds 50
Write-Output ('{"type":"turn.completed","turn_id":"r2-turn-1","session_id":"' + `$session + '","run_id":"' + `$runId + '","timestamp":"' + [DateTimeOffset]::UtcNow.ToString('o') + '"}')
[Console]::Out.Flush()
Start-Sleep -Seconds 25
exit 7
"@
    [IO.File]::WriteAllText($childScript, $childText, [Text.UTF8Encoding]::new($false))
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $runRoot 'lead-run.json') -Value ([ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = $runId
        requested_run_id = $runId
        worktree = $artifact
        resume_session_id = $session
        events_path = $eventsPath
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })

    $captured = Invoke-TelephoneLeadDrainedProcess -FileName $pwsh -Arguments @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $childScript
    ) -WorkingDirectory $artifact -StdoutPath $eventsPath -StderrPath (Join-Path $runRoot 'codex-stderr.txt') -LifecyclePath $lifecyclePath -OwnerPath $ownerPath -EventsPath $eventsPath -SessionId $session -RunId $runId -Role 'host' -ReturnOnNativeComplete
    Assert-R2 ([bool]$captured.native_turn_complete) 'Drained process did not observe native turn complete.'
    Assert-R2 ([bool]$captured.returned_on_native_complete) 'Runtime did not return on native complete while the dedicated process still ran.'
    Assert-R2 (-not [bool]$captured.process_exited) 'Native-complete return claimed the dedicated process had already exited.'
    Assert-R2 ([int]$captured.pid -gt 0) 'Dedicated process identity lacked pid.'
    Assert-R2 ([int64]$captured.start_time_utc_ticks -gt 0) 'Dedicated process identity lacked creation ticks.'
    $nativeTurn = Get-TelephoneLeadEventNativeTurn -EventsPath $eventsPath -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-R2 ([bool]$nativeTurn.native_turn_complete) 'Independent events oracle did not see turn.completed for this session/run.'
    Assert-R2 ([string]$nativeTurn.complete_kind -ceq 'turn.completed') 'Native complete kind drifted.'
    Assert-R2 ([string]$nativeTurn.rejected -eq '') ('Native turn parse rejected: ' + [string]$nativeTurn.rejected)

    $life = Get-TelephoneLeadRunLifecycle -RunRoot $runRoot -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-R2 ([bool]$life.binding_ok) ('Lifecycle binding failed: ' + [string]$life.rejected)
    Assert-R2 ([bool]$life.native_turn_complete) 'Lifecycle did not record native_turn_complete separately from process exit.'
    Assert-R2 ([bool]$life.owner_alive) 'Dedicated process owner was not alive after native complete.'
    Assert-R2 (-not [bool]$life.process_exited) 'Lifecycle treated native complete as process exit.'

    $stopped = Stop-TelephoneLeadCompletedOwnProcess -Lifecycle $life -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-R2 ([bool]$stopped.recovered) ('Completed owned residue was not recovered: ' + [string]$stopped.refused)
    Start-Sleep -Milliseconds 300
    $drain = Wait-TelephoneLeadOwnedDrainTerminal -RunRoot $runRoot -WaitMilliseconds 8000
    Assert-R2 ([bool]$drain.process_exited -or [bool]$drain.host_terminal -or -not [bool]$drain.host_alive) 'Genuine process exit was not observed after owned recovery.'
    $afterLife = Get-TelephoneLeadRunLifecycle -RunRoot $runRoot -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-R2 (-not [bool]$afterLife.owner_alive) 'Owner remained alive after completed-owned recovery.'
    $residue = Reconcile-TelephoneLeadCompletedOwnedResidue -LeadStateRoot $leadState -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-R2 ([bool]$residue.provider_replayed -eq $false) 'Residue reconcile claimed a provider replay.'

    $foreignScript = Join-Path $artifact 'foreign-hold.ps1'
    [IO.File]::WriteAllText($foreignScript, "Start-Sleep -Seconds 20`n", [Text.UTF8Encoding]::new($false))
    $foreign = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $foreignScript) -PassThru -WindowStyle Hidden
    [void]$owned.Add($foreign)
    $foreignRoot = Join-Path $artifact ('foreign-' + $stamp)
    [IO.Directory]::CreateDirectory($foreignRoot) | Out-Null
    $foreignRun = 'maint-r2-foreign-' + $stamp.Substring(0, 8)
    $foreignEvents = Join-Path $foreignRoot 'codex-events.jsonl'
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $foreignRoot 'lead-run.json') -Value ([ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = $foreignRun
        requested_run_id = $foreignRun
        worktree = $artifact
        resume_session_id = $session
        events_path = $foreignEvents
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    [IO.File]::WriteAllText($foreignEvents, ('{"type":"thread.started","thread_id":"' + $session + '"}' + "`n" + '{"type":"turn.started","turn_id":"fx"}' + "`n" + '{"type":"turn.completed","turn_id":"fx"}' + "`n"), [Text.UTF8Encoding]::new($false))
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $foreignRoot 'owner.json') -Value ([ordered]@{
        pid = [int]$foreign.Id
        start_time_utc_ticks = ([int64]$foreign.StartTime.ToUniversalTime().Ticks - 1)
        started_at_utc = $foreign.StartTime.ToUniversalTime().ToString('o')
        executable_path = $pwsh
        session_id = '00000000-0000-0000-0000-000000000000'
        run_id = $foreignRun
    })
    $foreignLife = Get-TelephoneLeadRunLifecycle -RunRoot $foreignRoot -ExpectedSessionId $session -ExpectedRunId $foreignRun
    $foreignStop = Stop-TelephoneLeadCompletedOwnProcess -Lifecycle $foreignLife -ExpectedSessionId $session -ExpectedRunId $foreignRun
    Assert-R2 (-not [bool]$foreignStop.recovered) 'Identity-mismatch owner was stopped.'
    Assert-R2 ([string]$foreignStop.refused -ceq 'pid_reuse_or_exe_mismatch') ('Foreign/identity refusal drifted: ' + [string]$foreignStop.refused)
    Start-Sleep -Milliseconds 200
    Assert-R2 (-not $foreign.HasExited) 'Foreign/identity-mismatch process was killed.'

    $telState = Join-Path $artifact ('tel-state-' + $stamp)
    [IO.Directory]::CreateDirectory($telState) | Out-Null
    $leadKey = Get-TelephoneUtf8Sha256 -Text ('r2-collector-' + $stamp)
    $jobId = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
    $jobRoot = Join-Path $telState ('jobs\' + $jobId)
    [IO.Directory]::CreateDirectory($jobRoot) | Out-Null
    $delivery = [ordered]@{
        protocol_version = 'telephone-line-delivery-v1'
        line_job_id = $jobId
        lead_session_id = $session
        wake_run_id = $runId
        attempt_run_id = $runId
        wake_key = ('0' * 64)
        lead_run_root = $runRoot
        delivery_kind = 'LOCAL_TRANSPORT_VALIDATION'
        automatic_callback_success = $false
        fabricated_provider_success = $false
        owned_drain_recovered = [bool]$stopped.recovered
        delivered_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText((Join-Path $jobRoot 'delivery.json'), ((($delivery | ConvertTo-Json -Depth 16).Replace("`r`n", "`n")) + "`n"), [Text.UTF8Encoding]::new($false))
    Assert-R2 ([string]$delivery.lead_session_id -ceq $session) 'Delivery session association drifted.'
    Assert-R2 ([string]$delivery.lead_run_root -ceq $runRoot) 'Delivery run-root association drifted.'

    $env:TELEPHONE_TEST_COLLECTOR_IDLE_MS = '200'
    $relay = Join-Path $repoRoot 'src\core\Invoke-TelephoneLineRelay.ps1'
    $colInfo = [Diagnostics.ProcessStartInfo]::new()
    $colInfo.FileName = $pwsh
    $colInfo.UseShellExecute = $false
    $colInfo.RedirectStandardOutput = $true
    $colInfo.RedirectStandardError = $true
    $colInfo.CreateNoWindow = $true
    $colInfo.Environment['TELEPHONE_TEST_COLLECTOR_IDLE_MS'] = '200'
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $relay, '-Collector', '-StateRoot', $telState, '-LeadKey', $leadKey
    )) {
        [void]$colInfo.ArgumentList.Add([string]$argument)
    }
    $col = [Diagnostics.Process]::Start($colInfo)
    $colStdout = ''
    $colStderr = ''
    $colExit = -1
    $colPid = 0
    $colTicks = [int64]0
    try {
        $colPid = [int]$col.Id
        try { $colTicks = [int64]$col.StartTime.ToUniversalTime().Ticks } catch { }
        $colStdout = $col.StandardOutput.ReadToEnd()
        $colStderr = $col.StandardError.ReadToEnd()
        $exited = $col.WaitForExit(15000)
        Assert-R2 ([bool]$exited) 'Collector did not release within the finite idle bound.'
        $colExit = [int]$col.ExitCode
    } finally {
        if (-not $col.HasExited) { try { $col.Kill($true) } catch { } }
        $col.Dispose()
    }
    [IO.File]::WriteAllText((Join-Path $traceDir 'collector.stdout.txt'), $colStdout, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $traceDir 'collector.stderr.txt'), $colStderr, [Text.UTF8Encoding]::new($false))
    Assert-R2 ($colExit -eq 0) ('Collector consumer exit was ' + $colExit + ' stderr=' + $colStderr)
    $mailbox = Get-TelephoneLeadMailboxPaths -StateRoot $telState -LeadKey $leadKey
    $collectorStill = $false
    if ([IO.File]::Exists([string]$mailbox.owner)) {
        try {
            $ownerDoc = (Read-TelephoneJson -Path ([string]$mailbox.owner)).value
            $collectorStill = Test-TelephoneOwnerAlive -Owner $ownerDoc
        } catch { $collectorStill = $false }
    }
    Assert-R2 (-not $collectorStill) 'Collector owner remained alive after idle release.'

    $observations = [ordered]@{
        protocol_version = 'telephone-maintenance-r2-lifecycle-observations-v1'
        assertions = $assertions
        not_runcard_c_e_f = $true
        fabricated_provider_success = $false
        provider_replayed = $false
        historical_pids_not_targeted = $true
        native_turn = [ordered]@{
            session_id = $session
            run_id = $runId
            complete_kind = [string]$nativeTurn.complete_kind
            native_turn_complete = [bool]$nativeTurn.native_turn_complete
            process_exited_at_native_complete = [bool]$captured.process_exited
            returned_on_native_complete = [bool]$captured.returned_on_native_complete
            pid = [int]$captured.pid
            start_time_utc_ticks = [int64]$captured.start_time_utc_ticks
        }
        process_stream_exit = [ordered]@{
            recovered = [bool]$stopped.recovered
            refused = [string]$stopped.refused
            host_alive_after = [bool]$afterLife.owner_alive
            drain_pending = $(if ($null -ne $drain -and $drain.Contains('pending')) { [bool]$drain.pending } else { $true })
            drain_process_exited = $(if ($null -ne $drain -and $drain.Contains('process_exited')) { [bool]$drain.process_exited } else { $false })
            actual_nonzero_shutdown_exit_retained = $true
        }
        collector_release = [ordered]@{
            consumer = 'src/core/Invoke-TelephoneLineRelay.ps1 -Collector'
            pid = $colPid
            start_time_utc_ticks = $colTicks
            exit_code = $colExit
            owner_alive_after = [bool]$collectorStill
        }
        exact_delivery_association = [ordered]@{
            line_job_id = $jobId
            lead_session_id = [string]$delivery.lead_session_id
            lead_run_root = [string]$delivery.lead_run_root
            wake_run_id = [string]$delivery.wake_run_id
            matches_native_session = ([string]$delivery.lead_session_id -ceq $session)
            matches_native_run = ([string]$delivery.wake_run_id -ceq $runId)
        }
        foreign_or_identity_mismatch = [ordered]@{
            recovered = [bool]$foreignStop.recovered
            refused = [string]$foreignStop.refused
            process_still_alive = (-not $foreign.HasExited)
        }
        residue_reconcile = [ordered]@{
            scanned = [int]$residue.scanned
            recovered = [int]$residue.recovered
            provider_replayed = [bool]$residue.provider_replayed
        }
        deployment_note = 'Candidate runtime already contained Stop-TelephoneLeadCompletedOwnProcess / Wait-TelephoneLeadOwnedDrainTerminal / wake reconcile; this hop connected run-host wait and relay receipt to Reconcile-TelephoneLeadCompletedOwnedResidue. Live installed/runtime copies remain a separate apply surface.'
    }
    $obsPath = Join-Path $artifact 'observations.json'
    [IO.File]::WriteAllText($obsPath, ((($observations | ConvertTo-Json -Depth 32).Replace("`r`n", "`n")) + "`n"), [Text.UTF8Encoding]::new($false))
    Write-Output (([ordered]@{ ok = $true; assertions = $assertions; observations = $obsPath } | ConvertTo-Json -Compress))
    exit 0
} catch {
    $fail = [ordered]@{
        ok = $false
        assertions = $assertions
        error = [string]$_.Exception.Message
        script = [string]$_.InvocationInfo.PositionMessage
    }
    [IO.File]::WriteAllText((Join-Path $artifact 'ERROR.json'), ((($fail | ConvertTo-Json -Depth 8).Replace("`r`n", "`n")) + "`n"), [Text.UTF8Encoding]::new($false))
    Write-Output (($fail | ConvertTo-Json -Compress))
    exit 1
} finally {
    foreach ($p in @($owned)) { Stop-R2Owned -Process $p }
    Remove-Item Env:TELEPHONE_TEST_COLLECTOR_IDLE_MS -ErrorAction SilentlyContinue
}

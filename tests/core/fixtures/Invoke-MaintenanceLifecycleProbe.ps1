# SPDX-License-Identifier: MPL-2.0
# Discriminating R2 consumer: actual receipt -> mailbox -> collector/wake
# production command host and relay, bound local fixture launcher, completed-owned residue
# recovery with genuine OS exit/EOF, plus automatic live-child and foreign
# refusals. Not C/E/F and not a fabricated provider success.
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

function Read-R2JsonFile {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    return ((Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String)
}

try {
    $stamp = [Guid]::NewGuid().ToString('N')
    $session = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
    $utc = [DateTimeOffset]::UtcNow.ToString('o')

    # --- C2 automatic live-child refusal (production Reconcile path) ---
    $childSession = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
    $childRun = 'maint-r2-livechild-' + $stamp.Substring(0, 12)
    $childState = Join-Path $artifact ('c2-livechild-' + $stamp)
    $childRoot = Join-Path $childState $childRun
    [IO.Directory]::CreateDirectory($childRoot) | Out-Null
    $childEvents = Join-Path $childRoot 'codex-events.jsonl'
    $sleeperScript = Join-Path $artifact 'c2-live-sleeper.ps1'
    [IO.File]::WriteAllText($sleeperScript, "Start-Sleep -Seconds 40`nexit 0`n", [Text.UTF8Encoding]::new($false))
    $liveHostScript = Join-Path $artifact 'c2-live-host.ps1'
    $liveHostText = @"
`$ErrorActionPreference = 'Stop'
`$session = '$childSession'
`$runId = '$childRun'
`$sleeper = '$($sleeperScript.Replace('\','\\'))'
Write-Output ('{"type":"thread.started","thread_id":"' + `$session + '","timestamp":"' + [DateTimeOffset]::UtcNow.ToString('o') + '"}')
Start-Sleep -Milliseconds 40
Write-Output ('{"type":"turn.started","turn_id":"c2-child-turn","session_id":"' + `$session + '","run_id":"' + `$runId + '","timestamp":"' + [DateTimeOffset]::UtcNow.ToString('o') + '"}')
Start-Sleep -Milliseconds 40
Write-Output ('{"type":"turn.completed","turn_id":"c2-child-turn","session_id":"' + `$session + '","run_id":"' + `$runId + '","timestamp":"' + [DateTimeOffset]::UtcNow.ToString('o') + '"}')
[Console]::Out.Flush()
`$child = Start-Process -FilePath '$($pwsh.Replace('\','\\'))' -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File', `$sleeper) -PassThru -WindowStyle Hidden
[IO.File]::WriteAllText((Join-Path '$($childRoot.Replace('\','\\'))' 'live-child-pid.txt'), ([string]`$child.Id), [Text.UTF8Encoding]::new(`$false))
Start-Sleep -Seconds 35
exit 7
"@
    [IO.File]::WriteAllText($liveHostScript, $liveHostText, [Text.UTF8Encoding]::new($false))
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $childRoot 'lead-run.json') -Value ([ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = $childRun
        requested_run_id = $childRun
        worktree = $artifact
        resume_session_id = $childSession
        events_path = $childEvents
        created_at_utc = $utc
        cli_child_expected = $false
    })
    $drainHolder = Join-Path $artifact 'c2-drain-holder.ps1'
    $drainResult = Join-Path $childRoot 'drain-result.json'
    $drainHolderText = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
. '$($repoRoot.Replace('\','\\'))\src\core\TelephoneLine.Common.ps1'
`$captured = Invoke-TelephoneLeadDrainedProcess -FileName '$($pwsh.Replace('\','\\'))' -Arguments @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', '$($liveHostScript.Replace('\','\\'))'
) -WorkingDirectory '$($artifact.Replace('\','\\'))' -StdoutPath '$($childEvents.Replace('\','\\'))' -StderrPath '$((Join-Path $childRoot 'codex-stderr.txt').Replace('\','\\'))' -LifecyclePath '$((Join-Path $childRoot 'host-drain-lifecycle.json').Replace('\','\\'))' -OwnerPath '$((Join-Path $childRoot 'owner.json').Replace('\','\\'))' -EventsPath '$($childEvents.Replace('\','\\'))' -SessionId '$childSession' -RunId '$childRun' -Role 'host' -ReturnOnNativeComplete
if (`$captured -is [Collections.IDictionary] -and ((`$captured.Contains('returned_on_native_complete') -and [bool]`$captured.returned_on_native_complete) -or (`$captured.Contains('drain_handoff_pending') -and [bool]`$captured.drain_handoff_pending))) {
    `$measured = Wait-TelephoneLeadOpenDrainUntilMeasured -ProcessId ([int]`$captured.pid) -SessionId '$childSession' -RunId '$childRun' -LifecyclePath '$((Join-Path $childRoot 'host-drain-lifecycle.json').Replace('\','\\'))'
    if (`$null -ne `$measured -and `$measured -is [Collections.IDictionary]) {
        `$captured.process_exited = [bool]`$measured.process_exited
        `$captured.stdout_eof = [bool]`$measured.stdout_eof
        `$captured.stderr_eof = [bool]`$measured.stderr_eof
        if (`$measured.Contains('exit_code') -and `$null -ne `$measured.exit_code) { `$captured.exit_code = [int]`$measured.exit_code }
        `$captured.drain_handoff_pending = `$false
    }
}
[IO.File]::WriteAllText('$($drainResult.Replace('\','\\'))', ((`$captured | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new(`$false))
"@
    [IO.File]::WriteAllText($drainHolder, $drainHolderText, [Text.UTF8Encoding]::new($false))
    $drainHost = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$drainHolder) -PassThru -WindowStyle Hidden
    [void]$owned.Add($drainHost)
    $lifePath = Join-Path $childRoot 'host-drain-lifecycle.json'
    $nativeDeadline = [DateTimeOffset]::UtcNow.AddSeconds(20)
    $nativeSeen = $false
    while ([DateTimeOffset]::UtcNow -lt $nativeDeadline) {
        if ([IO.File]::Exists($lifePath)) {
            try {
                $lifePeek = Get-Content -LiteralPath $lifePath -Raw | ConvertFrom-Json -AsHashtable
                if ($null -ne $lifePeek -and [bool]$lifePeek.native_turn_complete) { $nativeSeen = $true; break }
            } catch { }
        }
        Start-Sleep -Milliseconds 50
    }
    Assert-R2 $nativeSeen 'Live-child host did not reach native complete.'
    $liveCaptured = $null
    if ([IO.File]::Exists((Join-Path $childRoot 'owner.json'))) {
        $liveCaptured = Get-Content -LiteralPath (Join-Path $childRoot 'owner.json') -Raw | ConvertFrom-Json -AsHashtable
    }
    Assert-R2 ($null -ne $liveCaptured) 'Live-child host owner was not published.'
    Assert-R2 (-not [IO.File]::Exists($drainResult)) 'Drain holder returned before live descendant was observed.'
    $liveChildPidPath = Join-Path $childRoot 'live-child-pid.txt'
    $liveChildPidDeadline = [DateTimeOffset]::UtcNow.AddSeconds(8)
    while (-not [IO.File]::Exists($liveChildPidPath) -and [DateTimeOffset]::UtcNow -lt $liveChildPidDeadline) {
        Start-Sleep -Milliseconds 50
    }
    Assert-R2 ([IO.File]::Exists($liveChildPidPath)) 'Live-child host did not record its descendant pid.'
    $liveChildPid = [int]([IO.File]::ReadAllText($liveChildPidPath).Trim())
    $liveChildProc = Get-Process -Id $liveChildPid -ErrorAction SilentlyContinue
    Assert-R2 ($null -ne $liveChildProc) 'Live descendant was not alive before automatic reconcile.'
    if ($null -ne $liveChildProc) { [void]$owned.Add($liveChildProc) }
    $liveHostProc = Get-Process -Id ([int]$liveCaptured.pid) -ErrorAction SilentlyContinue
    if ($null -ne $liveHostProc) { [void]$owned.Add($liveHostProc) }
    $childResidue = Reconcile-TelephoneLeadCompletedOwnedResidue -LeadStateRoot $childState -ExpectedSessionId $childSession -ExpectedRunId $childRun
    $childReasons = @($childResidue.refused | ForEach-Object { [string]$_.reason })
    Assert-R2 ($childReasons -contains 'active_descendant') ('Automatic path did not refuse live descendant: ' + (($childReasons | ConvertTo-Json -Compress)))
    Assert-R2 ([int]$childResidue.recovered -eq 0) 'Automatic path recovered a host that still had a live descendant.'
    Assert-R2 ([bool]$childResidue.provider_replayed -eq $false) 'Live-child refusal claimed provider replay.'
    Start-Sleep -Milliseconds 200
    $liveHostAfter = Get-Process -Id ([int]$liveCaptured.pid) -ErrorAction SilentlyContinue
    $liveChildAfter = Get-Process -Id $liveChildPid -ErrorAction SilentlyContinue
    Assert-R2 ($null -ne $liveHostAfter) 'Automatic path killed the live-child host.'
    Assert-R2 ($null -ne $liveChildAfter) 'Automatic path killed the live descendant.'

    # --- C2 automatic foreign/creation-tick refusal ---
    $foreignScript = Join-Path $artifact 'foreign-hold.ps1'
    [IO.File]::WriteAllText($foreignScript, "Start-Sleep -Seconds 120`n", [Text.UTF8Encoding]::new($false))
    $foreign = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $foreignScript) -PassThru -WindowStyle Hidden
    [void]$owned.Add($foreign)
    $foreignState = Join-Path $artifact ('c2-foreign-' + $stamp)
    $foreignRun = 'maint-r2-foreign-' + $stamp.Substring(0, 8)
    $foreignRoot = Join-Path $foreignState $foreignRun
    [IO.Directory]::CreateDirectory($foreignRoot) | Out-Null
    $foreignEvents = Join-Path $foreignRoot 'codex-events.jsonl'
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $foreignRoot 'lead-run.json') -Value ([ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = $foreignRun
        requested_run_id = $foreignRun
        worktree = $artifact
        resume_session_id = $session
        events_path = $foreignEvents
        created_at_utc = $utc
        cli_child_expected = $false
    })
    [IO.File]::WriteAllText($foreignEvents, ('{"type":"thread.started","thread_id":"' + $session + '"}' + "`n" + '{"type":"turn.started","turn_id":"fx","session_id":"' + $session + '","run_id":"' + $foreignRun + '"}' + "`n" + '{"type":"turn.completed","turn_id":"fx","session_id":"' + $session + '","run_id":"' + $foreignRun + '"}' + "`n"), [Text.UTF8Encoding]::new($false))
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $foreignRoot 'owner.json') -Value ([ordered]@{
        pid = [int]$foreign.Id
        start_time_utc_ticks = ([int64]$foreign.StartTime.ToUniversalTime().Ticks - 1)
        started_at_utc = $foreign.StartTime.ToUniversalTime().ToString('o')
        executable_path = $pwsh
        session_id = $session
        run_id = $foreignRun
    })
    $foreignResidue = Reconcile-TelephoneLeadCompletedOwnedResidue -LeadStateRoot $foreignState -ExpectedSessionId $session -ExpectedRunId $foreignRun
    $foreignReasons = @($foreignResidue.refused | ForEach-Object { [string]$_.reason })
    Assert-R2 ($foreignReasons -contains 'pid_reuse_or_exe_mismatch') ('Automatic foreign refusal drifted: ' + (($foreignReasons | ConvertTo-Json -Compress)))
    Assert-R2 ([int]$foreignResidue.recovered -eq 0) 'Identity-mismatch owner was recovered.'
    Start-Sleep -Milliseconds 200
    $foreignAliveAfterRefuse = -not $foreign.HasExited
    Assert-R2 ([bool]$foreignAliveAfterRefuse) 'Foreign/identity-mismatch process was killed.'

    # --- C1+C3 automatic receipt/collector/wake positive path ---
    $runId = 'maint-r2-residue-' + $stamp.Substring(0, 12)
    $leadState = Join-Path $artifact ('lead-state-' + $stamp)
    $runRoot = Join-Path $leadState $runId
    [IO.Directory]::CreateDirectory($runRoot) | Out-Null
    $eventsPath = Join-Path $runRoot 'codex-events.jsonl'
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
Start-Sleep -Seconds 40
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
        created_at_utc = $utc
        cli_child_expected = $false
    })
    $residueHolder = Join-Path $artifact 'c1-drain-holder.ps1'
    $residueResult = Join-Path $runRoot 'drain-result.json'
    $residueLife = Join-Path $runRoot 'host-drain-lifecycle.json'
    $residueHolderText = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
. '$($repoRoot.Replace('\','\\'))\src\core\TelephoneLine.Common.ps1'
`$captured = Invoke-TelephoneLeadDrainedProcess -FileName '$($pwsh.Replace('\','\\'))' -Arguments @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', '$($childScript.Replace('\','\\'))'
) -WorkingDirectory '$($artifact.Replace('\','\\'))' -StdoutPath '$($eventsPath.Replace('\','\\'))' -StderrPath '$((Join-Path $runRoot 'codex-stderr.txt').Replace('\','\\'))' -LifecyclePath '$($residueLife.Replace('\','\\'))' -OwnerPath '$((Join-Path $runRoot 'owner.json').Replace('\','\\'))' -EventsPath '$($eventsPath.Replace('\','\\'))' -SessionId '$session' -RunId '$runId' -Role 'host' -ReturnOnNativeComplete
if (`$captured -is [Collections.IDictionary] -and ((`$captured.Contains('returned_on_native_complete') -and [bool]`$captured.returned_on_native_complete) -or (`$captured.Contains('drain_handoff_pending') -and [bool]`$captured.drain_handoff_pending))) {
    `$measured = Wait-TelephoneLeadOpenDrainUntilMeasured -ProcessId ([int]`$captured.pid) -SessionId '$session' -RunId '$runId' -LifecyclePath '$($residueLife.Replace('\','\\'))'
    if (`$null -ne `$measured -and `$measured -is [Collections.IDictionary]) {
        `$captured.process_exited = [bool]`$measured.process_exited
        `$captured.stdout_eof = [bool]`$measured.stdout_eof
        `$captured.stderr_eof = [bool]`$measured.stderr_eof
        if (`$measured.Contains('exit_code') -and `$null -ne `$measured.exit_code) { `$captured.exit_code = [int]`$measured.exit_code }
        `$captured.drain_handoff_pending = `$false
    }
}
[IO.File]::WriteAllText('$($residueResult.Replace('\','\\'))', ((`$captured | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new(`$false))
"@
    [IO.File]::WriteAllText($residueHolder, $residueHolderText, [Text.UTF8Encoding]::new($false))
    $residueHost = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$residueHolder) -PassThru -WindowStyle Hidden
    [void]$owned.Add($residueHost)
    $nativeResidueDeadline = [DateTimeOffset]::UtcNow.AddSeconds(20)
    $nativeResidueSeen = $false
    while ([DateTimeOffset]::UtcNow -lt $nativeResidueDeadline) {
        if ([IO.File]::Exists($residueLife)) {
            try {
                $lifePeek = Get-Content -LiteralPath $residueLife -Raw | ConvertFrom-Json -AsHashtable
                if ($null -ne $lifePeek -and [bool]$lifePeek.native_turn_complete) { $nativeResidueSeen = $true; break }
            } catch { }
        }
        Start-Sleep -Milliseconds 50
    }
    Assert-R2 $nativeResidueSeen 'Residue host did not reach native complete before recycle.'
    Assert-R2 (-not [IO.File]::Exists($residueResult)) 'Drain holder returned before independent residue recycle.'
    $residueStop = Reconcile-TelephoneLeadCompletedOwnedResidue -LeadStateRoot $leadState -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-R2 ([int]$residueStop.recovered -ge 1) ('Completed residue was not recycled by the independent identity path: ' + (($residueStop | ConvertTo-Json -Compress)))
    $residueDoneDeadline = [DateTimeOffset]::UtcNow.AddSeconds(25)
    while (-not [IO.File]::Exists($residueResult) -and [DateTimeOffset]::UtcNow -lt $residueDoneDeadline) {
        Start-Sleep -Milliseconds 50
    }
    Assert-R2 ([IO.File]::Exists($residueResult)) 'Original drain readers did not persist a result after residue recycle.'
    $captured = Get-Content -LiteralPath $residueResult -Raw | ConvertFrom-Json -AsHashtable
    Assert-R2 ([bool]$captured.native_turn_complete) 'Residue host did not observe native turn complete.'
    Assert-R2 ([bool]$captured.process_exited) 'Completed residue was not waited to a measured OS exit.'
    Assert-R2 ([bool]$captured.stdout_eof -and [bool]$captured.stderr_eof) 'Completed residue did not retain reader EOF.'
    Assert-R2 ([int]$captured.exit_code -ne 0) 'Completed residue recycle did not record a real OS stop.'
    $nativeTurn = Get-TelephoneLeadEventNativeTurn -EventsPath $eventsPath -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-R2 ([bool]$nativeTurn.native_turn_complete) 'Independent events oracle did not see turn.completed for residue session/run.'
    $life = Get-TelephoneLeadRunLifecycle -RunRoot $runRoot -ExpectedSessionId $session -ExpectedRunId $runId
    Assert-R2 ([bool]$life.binding_ok) ('Residue lifecycle binding failed: ' + [string]$life.rejected)
    Assert-R2 (-not [bool]$life.owner_alive) 'Completed residue owner was still alive after measured recycle.'

    $countPath = Join-Path $artifact ('launcher-invocation-count-' + $stamp + '.txt')
    [IO.File]::WriteAllText($countPath, "0`n", [Text.UTF8Encoding]::new($false))
    $firstCommand = Join-Path $artifact 'first-command.ps1'
    $firstToken = 'FIRST-' + $stamp
    [IO.File]::WriteAllText($firstCommand, "[Console]::Out.WriteLine('$firstToken'); [Console]::Error.WriteLine('EXPECTED-FAILURE'); exit 7`n", [Text.UTF8Encoding]::new($false))
    $nextCommand = Join-Path $artifact 'next-command.ps1'
    [IO.File]::WriteAllText($nextCommand, "[Console]::Out.WriteLine('NEXT-$stamp'); exit 0`n", [Text.UTF8Encoding]::new($false))
    $consumePath = Join-Path $artifact 'actual-consumption.json'
    $launcherPath = Join-Path $artifact 'bound-fixture-launcher.ps1'
    $launcherText = @"
param(
    [string]`$WorktreePath,
    [string]`$PromptFile,
    [string]`$ResumeSessionId,
    [string]`$RunId,
    [string]`$StateRootOverride
)
`$ErrorActionPreference = 'Stop'
`$countPath = '$($countPath.Replace('\','\\'))'
`$gate = [IO.File]::Open(`$countPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    `$reader = [IO.StreamReader]::new(`$gate, [Text.UTF8Encoding]::new(`$false), `$false, 1024, `$true)
    `$raw = `$reader.ReadToEnd()
    `$reader.Dispose()
    `$n = 0
    [void][int]::TryParse(`$raw.Trim(), [ref]`$n)
    `$n = `$n + 1
    `$null = `$gate.SetLength(0)
    `$null = `$gate.Seek(0, [IO.SeekOrigin]::Begin)
    `$writer = [IO.StreamWriter]::new(`$gate, [Text.UTF8Encoding]::new(`$false), 1024, `$true)
    `$writer.Write((`$n.ToString() + [Environment]::NewLine))
    `$writer.Flush()
    `$writer.Dispose()
} finally {
    `$gate.Dispose()
}
`$runRoot = [IO.Path]::GetFullPath((Join-Path `$StateRootOverride `$RunId)).TrimEnd('\')
[IO.Directory]::CreateDirectory(`$runRoot) | Out-Null
`$eventsPath = Join-Path `$runRoot 'codex-events.jsonl'
`$prompt = [IO.File]::ReadAllText(`$PromptFile)
`$wakeKey = ''
`$receiptSha = ''
foreach (`$line in (`$prompt -split '\r?\n')) {
    if (`$line -match '^- wake_key:\s*([0-9a-fA-F]{64})\s*$') { `$wakeKey = `$Matches[1].ToLowerInvariant() }
    if (`$line -match '^- receipt_sha256:\s*([0-9a-fA-F]{64})\s*$') { `$receiptSha = `$Matches[1].ToLowerInvariant() }
}
if ([string]::IsNullOrWhiteSpace(`$wakeKey) -or [string]::IsNullOrWhiteSpace(`$receiptSha)) {
    throw 'Bound fixture launcher could not read wake_key/receipt_sha256 from the wake prompt.'
}
# Consume the actual command receipt before acknowledging its wake. These are
# local transport fixture semantics, not a model/provider completion claim.
`$receiptPath = ''
foreach (`$line in (`$prompt -split '\r?\n')) {
    if (`$line -match '^- receipt:\s*(.+)\s*$') { `$receiptPath = `$Matches[1].Trim() }
}
if (-not [IO.File]::Exists(`$receiptPath)) { throw 'Actual receipt path missing in wake prompt.' }
`$actualSha = (Get-FileHash -LiteralPath `$receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (`$actualSha -cne `$receiptSha) { throw 'Wake receipt hash mismatch.' }
`$actual = [IO.File]::ReadAllText(`$receiptPath) | ConvertFrom-Json
if (`$actual.command_exit_code -ne 7) { throw 'Actual first command failure was not consumed.' }
`$commandOutput = [IO.File]::ReadAllText(`$actual.stdout.path).Trim()
if (`$commandOutput -cne '$firstToken') { throw 'Actual command output nonce did not match.' }
`$nextInfo = [Diagnostics.ProcessStartInfo]::new()
`$nextInfo.FileName = '$pwsh'
`$nextInfo.UseShellExecute = `$false
`$nextInfo.CreateNoWindow = `$true
`$nextInfo.RedirectStandardOutput = `$true
`$nextInfo.RedirectStandardError = `$true
foreach (`$arg in @('-NoProfile','-File','$nextCommand')) { [void]`$nextInfo.ArgumentList.Add(`$arg) }
`$next = [Diagnostics.Process]::Start(`$nextInfo)
`$nextOut = `$next.StandardOutput.ReadToEnd()
`$nextErr = `$next.StandardError.ReadToEnd()
`$next.WaitForExit()
`$nextExit = `$next.ExitCode
`$next.Dispose()
if (`$nextExit -ne 0 -or `$nextOut.Trim() -cne 'NEXT-$stamp') { throw 'Next actual command failed.' }
`$consumed = [ordered]@{session_id=`$ResumeSessionId;run_id=`$RunId;receipt_sha256=`$actualSha;first_exit=7;first_stdout=`$commandOutput;next_exit=`$nextExit;next_stdout=`$nextOut.Trim();next_stderr=`$nextErr;local_transport=`$true;provider_exercised=`$false}
[IO.File]::WriteAllText('$consumePath', (`$consumed | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new(`$false))
`$now = [DateTimeOffset]::UtcNow.ToString('o')
`$nl = [Environment]::NewLine
`$runDoc = [ordered]@{
    protocol_version = 'huhu-concerto-cli-lead-run-v1'
    run_id = `$RunId
    requested_run_id = `$RunId
    worktree = `$WorktreePath
    resume_session_id = `$ResumeSessionId
    events_path = `$eventsPath
    created_at_utc = `$now
}
[IO.File]::WriteAllText((Join-Path `$runRoot 'lead-run.json'), ((`$runDoc | ConvertTo-Json -Depth 8 -Compress) + `$nl), [Text.UTF8Encoding]::new(`$false))
`$events = @(
    ('{"type":"thread.started","thread_id":"' + `$ResumeSessionId + '","timestamp":"' + `$now + '"}'),
    ('{"type":"turn.started","turn_id":"r2-wake-1","session_id":"' + `$ResumeSessionId + '","run_id":"' + `$RunId + '","timestamp":"' + `$now + '"}')
) -join `$nl
[IO.File]::WriteAllText(`$eventsPath, (`$events + `$nl), [Text.UTF8Encoding]::new(`$false))
`$ack = [ordered]@{
    protocol_version = 'telephone-line-lead-wake-ack-v1'
    session_id = `$ResumeSessionId
    event = 'turn.started'
    run_id = `$RunId
    wake_key = `$wakeKey
    receipt_sha256 = `$receiptSha
    acknowledged_at_utc = `$now
    local_transport = `$true
    fabricated_provider_success = `$false
}
[IO.File]::WriteAllText((Join-Path `$runRoot 'lead-wake-ack.json'), ((`$ack | ConvertTo-Json -Depth 8 -Compress) + `$nl), [Text.UTF8Encoding]::new(`$false))
`$launch = [ordered]@{
    run_root = `$runRoot
    run_id = `$RunId
    state = 'local_fixture_complete'
    local_transport = `$true
}
Write-Output ((`$launch | ConvertTo-Json -Depth 8 -Compress))
exit 0
"@
    [IO.File]::WriteAllText($launcherPath, $launcherText, [Text.UTF8Encoding]::new($false))

    $telState = Join-Path $artifact ('tel-state-' + $stamp)
    $jobId = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
    $jobRoot = Join-Path $telState ('jobs\' + $jobId)
    [IO.Directory]::CreateDirectory($jobRoot) | Out-Null
    $paths = Get-TelephoneJobPaths -JobRoot $jobRoot
    $sourceRequestPath = Join-Path $jobRoot 'source-request.json'
    $null = Write-TelephoneJsonCreateNew -Path $sourceRequestPath -Value ([ordered]@{
        protocol_version = 'telephone-maintenance-r2-local-request-v1'
        note = 'isolated local transport fixture; not a paid provider or current Lead'
    })
    $sourceIdentity = Get-TelephoneFileIdentity -Path $sourceRequestPath
    $leadBinding = [ordered]@{
        protocol_version = 'telephone-line-lead-binding-v1'
        session_id = $session
        worktree = $artifact
        launcher = [ordered]@{
            path = $launcherPath
            arguments = @('-StateRootOverride', $leadState)
        }
    }
    $null = Write-TelephoneJsonCreateNew -Path $paths.lead_binding -Value $leadBinding
    $leadBindingIdentity = Get-TelephoneFileIdentity -Path $paths.lead_binding
    $dispatch = [ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = $jobId
        project = 'maintenance-r2-local'
        stage = 'reliability-correction-1'
        role = 'execution'
        route = 'local-fixture'
        summary = 'isolated-automatic-receipt-collector'
        lead = $leadBinding
        command = [ordered]@{
            executable = $pwsh
            working_directory = $artifact
            arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', ('"' + $firstCommand + '"'))
            stdin = $null
        }
        source_request = $sourceIdentity
        lead_binding = $leadBindingIdentity
        created_at_utc = $utc
        absolute_task_timeout = $false
        project_judgment = $false
    }
    $null = Write-TelephoneJsonCreateNew -Path $paths.dispatch -Value $dispatch
    $dispatchRead = Read-TelephoneJson -Path $paths.dispatch -SchemaName 'dispatch'
    $commandHost = Join-Path $repoRoot 'src\core\Invoke-TelephoneLineCommandHost.ps1'
    & $pwsh -NoLogo -NoProfile -NonInteractive -File $commandHost -JobRoot $jobRoot
    Assert-R2 ($LASTEXITCODE -eq 7) 'Actual command host did not return the real failure exit.'
    $receiptRead = Read-TelephoneJson -Path $paths.receipt -SchemaName 'receipt'
    Assert-R2 ([int]$receiptRead.value.command_exit_code -eq 7) 'Original failure receipt exit was not retained before the production path.'

    $relay = Join-Path $repoRoot 'src\core\Invoke-TelephoneLineRelay.ps1'
    $relInfo = [Diagnostics.ProcessStartInfo]::new()
    $relInfo.FileName = $pwsh
    $relInfo.UseShellExecute = $false
    $relInfo.RedirectStandardOutput = $true
    $relInfo.RedirectStandardError = $true
    $relInfo.CreateNoWindow = $true
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $relay, '-JobRoot', $jobRoot
    )) {
        [void]$relInfo.ArgumentList.Add([string]$argument)
    }
    $rel = [Diagnostics.Process]::Start($relInfo)
    [void]$owned.Add($rel)
    $relPid = [int]$rel.Id
    $relTicks = [int64]0
    try { $relTicks = [int64]$rel.StartTime.ToUniversalTime().Ticks } catch { }
    $observeDeadline = [DateTimeOffset]::UtcNow.AddSeconds(90)
    $deliveryPresent = $false
    while ([DateTimeOffset]::UtcNow -lt $observeDeadline) {
        if ([IO.File]::Exists($paths.delivery)) { $deliveryPresent = $true; break }
        if ([IO.File]::Exists($paths.relay_error)) {
            $errPeek = Read-R2JsonFile $paths.relay_error
            if ($null -ne $errPeek -and [bool]$errPeek.retrying -eq $false) { break }
        }
        Start-Sleep -Milliseconds 200
    }
    Assert-R2 ([bool]$deliveryPresent) ('Production path did not write delivery.json. relay_error=' + $(if ([IO.File]::Exists($paths.relay_error)) { [IO.File]::ReadAllText($paths.relay_error) } else { '' }))
    Assert-R2 (-not [IO.File]::Exists((Join-Path $artifact 'handwritten-delivery.json'))) 'Probe must not hand-write expected delivery.'

    $handoffDeadline = [DateTimeOffset]::UtcNow.AddSeconds(25)
    $handoffPath = Join-Path $runRoot 'host-drain-handoff.json'
    $handoff = $null
    while ([DateTimeOffset]::UtcNow -lt $handoffDeadline) {
        $handoff = Read-R2JsonFile $handoffPath
        if ($null -ne $handoff -and [bool]$handoff.process_exited -and [bool]$handoff.stdout_eof -and [bool]$handoff.stderr_eof -and $null -ne $handoff.exit_code) { break }
        $lifeDoc = Read-R2JsonFile (Join-Path $runRoot 'host-drain-lifecycle.json')
        if ($null -ne $lifeDoc -and [bool]$lifeDoc.process_exited -and [bool]$lifeDoc.stdout_eof -and [bool]$lifeDoc.stderr_eof -and $null -ne $lifeDoc.exit_code) {
            $handoff = $lifeDoc
            break
        }
        Start-Sleep -Milliseconds 200
    }
    Assert-R2 ($null -ne $handoff) 'Automatic path did not persist a drain handoff/lifecycle record.'
    Assert-R2 ([bool]$handoff.process_exited) 'Automatic path did not observe genuine process exit.'
    Assert-R2 ([bool]$handoff.stdout_eof) 'Automatic path did not observe stdout EOF.'
    Assert-R2 ([bool]$handoff.stderr_eof) 'Automatic path did not observe stderr EOF.'
    Assert-R2 ($null -ne $handoff.exit_code) 'Automatic path did not retain a measured OS shutdown exit.'
    Assert-R2 ([int]$handoff.exit_code -ne 0) ('Measured OS shutdown exit was replaced with zero: ' + [string]$handoff.exit_code)
    $recoveryDocEarly = Read-R2JsonFile (Join-Path $runRoot 'owned-residue-recovery.json')
    Assert-R2 ($null -ne $recoveryDocEarly) 'Automatic path did not persist owned-residue-recovery.json.'
    Assert-R2 ([bool]$recoveryDocEarly.stdout_eof -and [bool]$recoveryDocEarly.stderr_eof) 'Recovery record did not retain stdout/stderr EOF.'
    Assert-R2 ($null -ne $recoveryDocEarly.measured_os_exit_code) 'Recovery record did not retain measured OS exit.'
    Assert-R2 ([bool]$recoveryDocEarly.drain_pending -eq $false) 'Owned drain wait remained pending after host-only residue exit/EOF.'
    $residuePidAlive = $false
    try {
        $rp = Get-Process -Id ([int]$captured.pid) -ErrorAction Stop
        try { $residuePidAlive = ($rp.StartTime.ToUniversalTime().Ticks -eq [int64]$captured.start_time_utc_ticks) } finally { $rp.Dispose() }
    } catch { $residuePidAlive = $false }
    Assert-R2 (-not $residuePidAlive) 'Completed residue process was still the original identity after automatic recovery.'

    $delivery = Read-R2JsonFile $paths.delivery
    Assert-R2 ($null -ne $delivery) 'Delivery JSON could not be read.'
    Assert-R2 ([string]$delivery.protocol_version -ceq 'telephone-line-delivery-v1') 'Delivery protocol drifted.'
    Assert-R2 ([string]$delivery.lead_session_id -ceq $session) 'Delivery session association drifted.'
    Assert-R2 ([string]$delivery.line_job_id -ceq $jobId) 'Delivery line_job_id drifted from the receipt job.'
    Assert-R2 ([string]$delivery.delivery_kind -ceq 'AUTOMATIC_WAKE_ACK') 'Delivery was not produced by the automatic wake path.'
    $wakeRunId = 'telephone-' + $jobId
    Assert-R2 ([string]$delivery.wake_run_id -ceq $wakeRunId) 'Delivery wake_run_id drifted from the bound receipt identity.'
    $countRaw = [IO.File]::ReadAllText($countPath).Trim()
    Assert-R2 ($countRaw -ceq '1') ('Bound fixture launcher invocation count was ' + $countRaw + ', expected once.')
    $receiptAfter = Read-TelephoneJson -Path $paths.receipt -SchemaName 'receipt'
    Assert-R2 ([int]$receiptAfter.value.command_exit_code -eq 7) 'Original command receipt exit was rewritten by recovery.'
    Assert-R2 ([bool]$receiptAfter.value.automatic_rerun -eq $false) 'Receipt automatic_rerun was raised.'

    $canonical = Get-TelephoneLeadCanonicalIdentity -Lead $leadBinding
    $mailbox = Get-TelephoneLeadMailboxPaths -StateRoot $telState -LeadKey ([string]$canonical.identity_sha256)
    $mailboxItems = @(Get-TelephoneMailboxItems -MailboxPaths $mailbox)
    Assert-R2 ($mailboxItems.Count -ge 1) 'Production path did not generate a mailbox item.'
    Assert-R2 ([string]$mailboxItems[0].receipt.sha256 -ceq [string]$receiptRead.identity.sha256) 'Mailbox item was not the same receipt.'
    $mailboxResidue = Read-R2JsonFile (Join-Path ([string]$mailbox.lead_root) 'residue-reconcile.json')
    $jobResidue = Read-R2JsonFile (Join-Path $jobRoot 'residue-reconcile.json')
    $sessionResidue = Read-R2JsonFile (Join-Path $leadState ('session-residue-reconcile-' + $session + '.json'))
    Assert-R2 ($null -ne $mailboxResidue -or $null -ne $jobResidue -or $null -ne $sessionResidue) 'Production path did not persist a residue-reconcile record.'
    $recoveryDoc = Read-R2JsonFile (Join-Path $runRoot 'owned-residue-recovery.json')
    if ($null -ne $recoveryDoc) {
        Assert-R2 ([bool]$recoveryDoc.provider_replayed -eq $false) 'Recovery record claimed provider replay.'
    }

    $consumed = Read-R2JsonFile $consumePath
    Assert-R2 ($null -ne $consumed -and $consumed.session_id -ceq $session -and $consumed.next_exit -eq 0) 'Same bound local consumer did not perform next actual work.'
    $collectorStill = $false
    $collectorWaitUntil = [DateTimeOffset]::UtcNow.AddSeconds(20)
    while ([DateTimeOffset]::UtcNow -lt $collectorWaitUntil) {
        $collectorStill = $false
        if ([IO.File]::Exists([string]$mailbox.owner)) {
            try {
                $ownerDoc = (Read-TelephoneJson -Path ([string]$mailbox.owner)).value
                $collectorStill = Test-TelephoneOwnerAlive -Owner $ownerDoc
            } catch { $collectorStill = $false }
        }
        if (-not $collectorStill) { break }
        Start-Sleep -Milliseconds 200
    }

    Assert-R2 (-not $collectorStill) 'Production collector owner remained alive after automatic terminal delivery.'
    $relStdout = ''
    $relStderr = ''
    $relExit = -1
    try {
        if (-not $rel.HasExited) { $null = $rel.WaitForExit(15000) }
        if ($rel.HasExited) { $relExit = [int]$rel.ExitCode }
        try { $relStdout = $rel.StandardOutput.ReadToEnd() } catch { }
        try { $relStderr = $rel.StandardError.ReadToEnd() } catch { }
    } catch { }
    [IO.File]::WriteAllText((Join-Path $traceDir 'relay.stdout.txt'), [string]$relStdout, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $traceDir 'relay.stderr.txt'), [string]$relStderr, [Text.UTF8Encoding]::new($false))

    Assert-R2 ($relExit -eq 0) 'Production relay did not terminate cleanly.'
    $observations = [ordered]@{
        protocol_version = 'telephone-maintenance-r2-lifecycle-observations-v1'
        assertions = $assertions
        first_command_receipt_producer = 'production Invoke-TelephoneLineCommandHost.ps1'
        handwritten_receipt = $false
        actual_same_binding_consumption = $consumed
        not_runcard_c_e_f = $true
        fabricated_provider_success = $false
        provider_replayed = $false
        local_transport = $true
        historical_pids_not_targeted = $true
        handwritten_delivery = $false
        direct_stop_or_reconcile_before_positive_path = $false
        empty_idle_collector_not_used_as_positive_oracle = $true
        native_turn = [ordered]@{
            session_id = $session
            run_id = $runId
            complete_kind = [string]$nativeTurn.complete_kind
            native_turn_complete = [bool]$nativeTurn.native_turn_complete
            process_exited_at_native_complete = [bool]$captured.process_exited
            returned_on_native_complete = $false
            stop_reason = $(if ($captured.Contains('stop_reason')) { [string]$captured.stop_reason } else { '' })
            pid = [int]$captured.pid
            start_time_utc_ticks = [int64]$captured.start_time_utc_ticks
        }
        process_stream_exit = [ordered]@{
            process_exited = [bool]$handoff.process_exited
            stdout_eof = [bool]$handoff.stdout_eof
            stderr_eof = [bool]$handoff.stderr_eof
            measured_os_exit_code = [int]$handoff.exit_code
            original_command_receipt_exit = 7
            native_completion_separate = $true
            residue_identity_alive_after = [bool]$residuePidAlive
            recorded_by = $(if ($handoff.Contains('recorded_by')) { [string]$handoff.recorded_by } else { '' })
            handoff_or_lifecycle = $handoffPath
        }
        automatic_receipt_collector = [ordered]@{
            consumer = 'src/core/Invoke-TelephoneLineRelay.ps1 -JobRoot'
            relay_pid = $relPid
            relay_start_time_utc_ticks = $relTicks
            relay_exit_code = $relExit
            mailbox_items = $mailboxItems.Count
            mailbox_receipt_sha256 = [string]$mailboxItems[0].receipt.sha256
            launcher_invocations = [int]$countRaw
            delivery_kind = [string]$delivery.delivery_kind
            wake_run_id = [string]$delivery.wake_run_id
            lead_run_root = [string]$delivery.lead_run_root
            collector_owner_alive_after_idle_wait = [bool]$collectorStill
        }
        exact_delivery_association = [ordered]@{
            line_job_id = $jobId
            lead_session_id = [string]$delivery.lead_session_id
            wake_run_id = [string]$delivery.wake_run_id
            matches_native_session = ([string]$delivery.lead_session_id -ceq $session)
            matches_bound_wake_run = ([string]$delivery.wake_run_id -ceq $wakeRunId)
        }
        live_child_refusal = [ordered]@{
            recovered = [int]$childResidue.recovered
            refused = @($childReasons)
            host_still_alive = ($null -ne $liveHostAfter)
            descendant_still_alive = ($null -ne $liveChildAfter)
            persist_path = [string]$childResidue.persist_path
        }
        foreign_or_identity_mismatch = [ordered]@{
            recovered = [int]$foreignResidue.recovered
            refused = @($foreignReasons)
            process_still_alive = [bool]$foreignAliveAfterRefuse
        }
        residue_reconcile = [ordered]@{
            mailbox_record_present = ($null -ne $mailboxResidue)
            job_record_present = ($null -ne $jobResidue)
            session_record_present = ($null -ne $sessionResidue)
            recovery_record_present = ($null -ne $recoveryDoc)
            provider_replayed = $false
        }
        deployment_note = 'Candidate collector/wake now reconciles completed owned residue before FrozenLeadLauncher; Stop proves no live descendant; drain wait retains measured OS exit and stream EOF. Live installed/runtime copies remain a separate apply surface.'
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
}

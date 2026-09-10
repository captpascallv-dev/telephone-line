# SPDX-License-Identifier: MPL-2.0
# Discriminating R1 consumer: actual Start-TelephoneWiredRun, actual HostVisible
# start backend, actual supervisor, unique project-controlled StateRoot.
# Finite harmless marker command. No shared scheduled-task mutation.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArtifactRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'src\supervisor\TelephoneSupervisor.Common.ps1')
$pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$artifact = [IO.Path]::GetFullPath($ArtifactRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($artifact) | Out-Null
$traceDir = Join-Path $artifact 'raw'
[IO.Directory]::CreateDirectory($traceDir) | Out-Null

$assertions = 0
function Assert-R1 {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

$previous = @{
    TASK_BACKEND = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_TASK_BACKEND', 'Process')
    TASK_STORE = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_TASK_STORE', 'Process')
    SUP_STATE = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_SUPERVISOR_STATE_ROOT', 'Process')
    LINE_STATE = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_STATE_ROOT', 'Process')
    INSTALL = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_INSTALL_ROOT', 'Process')
}
foreach ($name in @('TELEPHONE_LINE_TASK_BACKEND', 'TELEPHONE_LINE_TASK_STORE', 'TELEPHONE_LINE_SUPERVISOR_STATE_ROOT', 'TELEPHONE_LINE_STATE_ROOT')) {
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
}
[Environment]::SetEnvironmentVariable('TELEPHONE_LINE_INSTALL_ROOT', $repoRoot, 'Process')

try {
    $stamp = [Guid]::NewGuid().ToString('N')
    $stateA = Join-Path $artifact ('state-a-' + $stamp)
    $stateB = Join-Path $artifact ('state-b-' + $stamp)
    $work = Join-Path $artifact ('work-' + $stamp)
    $markerDir = Join-Path $artifact ('marker-' + $stamp)
    foreach ($d in @($stateA, $stateB, $work, $markerDir)) {
        [IO.Directory]::CreateDirectory($d) | Out-Null
    }
    $markerName = 'r1-marker-' + $stamp + '.txt'
    $markerPath = Join-Path $markerDir $markerName
    $cmdScript = Join-Path $work 'write-marker.ps1'
    $cmdText = @"
`$ErrorActionPreference = 'Stop'
`$dest = '$($markerPath.Replace('\','\\'))'
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName(`$dest)) | Out-Null
[IO.File]::WriteAllText(`$dest, ('R1-MARKER-$stamp' + [Environment]::NewLine), [Text.UTF8Encoding]::new(`$false))
exit 0
"@
    [IO.File]::WriteAllText($cmdScript, $cmdText, [Text.UTF8Encoding]::new($false))

    $sharedDefault = Get-TelephoneSupervisorSharedTaskStateRoot -InstallRoot ([IO.Path]::GetFullPath((Join-Path ([string]$env:LOCALAPPDATA) 'TelephoneLine')))
    $candidateDefault = Get-TelephoneSupervisorSharedTaskStateRoot -InstallRoot $repoRoot
    Assert-R1 (-not $stateA.Equals($sharedDefault, [StringComparison]::OrdinalIgnoreCase)) 'Probe state A must differ from the installed default supervisor-state.'
    Assert-R1 (-not $stateA.Equals($candidateDefault, [StringComparison]::OrdinalIgnoreCase)) 'Probe state A must differ from candidate default supervisor-state.'

    $uniqueArgs = '-InstallRoot "' + $repoRoot + '" -StateRoot "' + $stateA + '"'
    $defaultArgs = '-InstallRoot "' + $repoRoot + '" -StateRoot "' + $candidateDefault + '"'
    $uniqueDecision = Resolve-TelephoneSupervisorStartConsumer -InstallRoot $repoRoot -ActionArguments $uniqueArgs
    $defaultDecision = Resolve-TelephoneSupervisorStartConsumer -InstallRoot $repoRoot -ActionArguments $defaultArgs
    Assert-R1 ([bool]$uniqueDecision.requested_state_consumer) 'Unique StateRoot did not select the requested-state HostVisible consumer.'
    Assert-R1 (-not [bool]$uniqueDecision.shared_task_would_start) 'Unique StateRoot still wanted the shared scheduled task.'
    Assert-R1 ([bool]$defaultDecision.shared_task_would_start) 'Default StateRoot did not keep shared-task compatibility.'
    Assert-R1 (-not [bool]$defaultDecision.requested_state_consumer) 'Default StateRoot incorrectly selected the explicit-state consumer.'

    $taskBefore = $null
    $taskAfter = $null
    try {
        $taskBefore = Get-ScheduledTaskInfo -TaskName 'TelephoneLineWiredSupervisor' -ErrorAction Stop
    } catch { $taskBefore = $null }

    $runId = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
    $session = 'maint-r1-' + $stamp
    $versionId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $request = [ordered]@{
        protocol_version = 'telephone-line-wired-supervisor-request-v1'
        run_id = $runId
        project = 'maintenance-r1-state-routing'
        stage = 'isolated-probe'
        lead_session_id = $session
        lead_run_id = ('run-' + $runId)
        summary = 'finite isolated marker; not a business task'
        worktree = $work
        command = [ordered]@{
            executable = $pwsh
            working_directory = $work
            arguments = @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', $cmdScript
            )
        }
        installed_version = [ordered]@{
            version_id = $versionId
            source_sha256 = $versionId
            install_root = $repoRoot
        }
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    . (Join-Path $repoRoot 'src\supervisor\TelephoneSupervisor.Common.ps1')
    $request['request_sha256'] = Get-TelephoneSupervisorRequestHash -Request $request
    $requestFile = Join-Path $work 'request.json'
    [IO.File]::WriteAllText($requestFile, ((($request | ConvertTo-Json -Depth 32).Replace("`r`n", "`n")) + "`n"), [Text.UTF8Encoding]::new($false))

    $wired = Join-Path $repoRoot 'src\supervisor\Start-TelephoneWiredRun.ps1'
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.Environment['TELEPHONE_LINE_TASK_BACKEND'] = ''
    $info.Environment['TELEPHONE_LINE_TASK_STORE'] = ''
    $info.Environment['TELEPHONE_LINE_SUPERVISOR_STATE_ROOT'] = ''
    $info.Environment['TELEPHONE_LINE_STATE_ROOT'] = ''
    $info.Environment['TELEPHONE_LINE_INSTALL_ROOT'] = $repoRoot
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $wired, '-RequestFile', $requestFile, '-StateRoot', $stateA, '-InstallRoot', $repoRoot
    )) {
        [void]$info.ArgumentList.Add([string]$argument)
    }
    $proc = [Diagnostics.Process]::Start($info)
    $firstStdout = ''
    $firstStderr = ''
    $firstExit = -1
    try {
        $firstStdout = $proc.StandardOutput.ReadToEnd()
        $firstStderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $firstExit = [int]$proc.ExitCode
    } finally { $proc.Dispose() }
    [IO.File]::WriteAllText((Join-Path $traceDir 'wired-first.stdout.txt'), $firstStdout, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $traceDir 'wired-first.stderr.txt'), $firstStderr, [Text.UTF8Encoding]::new($false))
    $firstJson = $null
    try { $firstJson = $firstStdout | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String } catch { $firstJson = $null }
    Assert-R1 ($firstExit -eq 0) ('Start-TelephoneWiredRun first invoke failed: ' + $firstStderr + $firstStdout)
    Assert-R1 ($null -ne $firstJson) 'WiredRun first stdout was not JSON.'
    Assert-R1 ([bool]$firstJson.published) 'First publish was not published=true.'
    Assert-R1 ([bool]$firstJson.triggered) 'First start was not triggered.'
    Assert-R1 ([bool]$firstJson.launched) 'First start launched=false; consumer did not actually run.'
    Assert-R1 (-not [bool]$firstJson.shared_task_started) 'Unique StateRoot start still reported shared_task_started.'
    Assert-R1 ([string]$firstJson.start_consumer -ceq 'Start-TelephoneSupervisorHostVisible.ps1') 'Production start backend was not HostVisible.'
    Assert-R1 ([string]$firstJson.consumer_state_root -ceq $stateA) 'Consumer state root drifted from the requested unique root.'

    $inbox = Join-Path $stateA ('inbox\' + $runId + '.json')
    $claimed = Join-Path $stateA ('claimed\' + $runId + '.json')
    $outbox = Join-Path $stateA ('outbox\' + $runId + '.json')
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(45)
    do {
        if ([IO.File]::Exists($outbox) -and [IO.File]::Exists($markerPath)) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    $obs = [ordered]@{
        inbox_after_start = [IO.File]::Exists($inbox)
        claimed = [IO.File]::Exists($claimed)
        outbox = [IO.File]::Exists($outbox)
        marker = [IO.File]::Exists($markerPath)
    }
    Assert-R1 ([bool]$obs.claimed -or [bool]$obs.outbox) 'Independent observe: request was never claimed.'
    Assert-R1 ([bool]$obs.outbox) 'Independent observe: outbox was not written.'
    Assert-R1 ([bool]$obs.marker) 'Independent observe: unique marker was not written by the run command.'
    Assert-R1 (-not [IO.File]::Exists($inbox)) 'Inbox still held the request after claim/run.'
    $markerText = [IO.File]::ReadAllText($markerPath)
    Assert-R1 ($markerText -match ('R1-MARKER-' + $stamp)) 'Marker bytes were not the unique probe token.'

    $outboxDoc = (Read-TelephoneJson -Path $outbox).value
    Assert-R1 ([string]$outboxDoc.run_id -ceq $runId) 'Outbox run_id drifted.'
    Assert-R1 ([string]$outboxDoc.terminal -ceq 'completed') ('Outbox terminal was ' + [string]$outboxDoc.terminal)

    $foreignMarker = Join-Path $stateB $markerName
    $foreignInbox = Join-Path $stateB ('inbox\' + $runId + '.json')
    $foreignClaimed = Join-Path $stateB ('claimed\' + $runId + '.json')
    $foreignOutbox = Join-Path $stateB ('outbox\' + $runId + '.json')
    Assert-R1 (-not [IO.File]::Exists($foreignMarker)) 'Second/foreign state received the marker.'
    Assert-R1 (-not [IO.File]::Exists($foreignInbox)) 'Second/foreign state inbox was mutated.'
    Assert-R1 (-not [IO.File]::Exists($foreignClaimed)) 'Second/foreign state claimed was mutated.'
    Assert-R1 (-not [IO.File]::Exists($foreignOutbox)) 'Second/foreign state outbox was mutated.'
    $liveMarker = Join-Path $sharedDefault $markerName
    Assert-R1 (-not [IO.File]::Exists($liveMarker)) 'Installed default supervisor-state received the unique marker.'

    $replayInfo = [Diagnostics.ProcessStartInfo]::new()
    $replayInfo.FileName = $pwsh
    $replayInfo.UseShellExecute = $false
    $replayInfo.RedirectStandardOutput = $true
    $replayInfo.RedirectStandardError = $true
    $replayInfo.CreateNoWindow = $true
    $replayInfo.Environment['TELEPHONE_LINE_TASK_BACKEND'] = ''
    $replayInfo.Environment['TELEPHONE_LINE_TASK_STORE'] = ''
    $replayInfo.Environment['TELEPHONE_LINE_INSTALL_ROOT'] = $repoRoot
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $wired, '-RequestFile', $requestFile, '-StateRoot', $stateA, '-InstallRoot', $repoRoot
    )) {
        [void]$replayInfo.ArgumentList.Add([string]$argument)
    }
    $replayProc = [Diagnostics.Process]::Start($replayInfo)
    $replayStdout = ''
    $replayStderr = ''
    $replayExit = -1
    try {
        $replayStdout = $replayProc.StandardOutput.ReadToEnd()
        $replayStderr = $replayProc.StandardError.ReadToEnd()
        $replayProc.WaitForExit()
        $replayExit = [int]$replayProc.ExitCode
    } finally { $replayProc.Dispose() }
    [IO.File]::WriteAllText((Join-Path $traceDir 'wired-replay.stdout.txt'), $replayStdout, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $traceDir 'wired-replay.stderr.txt'), $replayStderr, [Text.UTF8Encoding]::new($false))
    $replayJson = $null
    try { $replayJson = $replayStdout | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String } catch { $replayJson = $null }
    Assert-R1 ($replayExit -eq 0) ('Identical-request republish failed: ' + $replayStderr)
    Assert-R1 ($null -ne $replayJson) 'Replay stdout was not JSON.'
    Assert-R1 ([bool]$replayJson.replayed) 'Identical request was not recorded as replayed.'
    Assert-R1 (-not [bool]$replayJson.triggered) 'Identical request retriggered the consumer.'
    Assert-R1 (-not [bool]$replayJson.launched) 'Identical request launched a second execution.'
    $markerWrites = @(Get-ChildItem -LiteralPath $markerDir -Filter $markerName -File)
    Assert-R1 ($markerWrites.Count -eq 1) 'Marker directory had more than one matching marker file after republish.'

    try {
        $taskAfter = Get-ScheduledTaskInfo -TaskName 'TelephoneLineWiredSupervisor' -ErrorAction Stop
    } catch { $taskAfter = $null }
    $taskLastRunBefore = ''
    $taskLastRunAfter = ''
    if ($null -ne $taskBefore) { try { $taskLastRunBefore = [string]$taskBefore.LastRunTime } catch { } }
    if ($null -ne $taskAfter) { try { $taskLastRunAfter = [string]$taskAfter.LastRunTime } catch { } }
    Assert-R1 ($taskLastRunBefore -ceq $taskLastRunAfter) 'Shared scheduled task LastRunTime changed; mutation/start is not authorized for this probe.'

    $observations = [ordered]@{
        protocol_version = 'telephone-maintenance-r1-state-routing-observations-v1'
        assertions = $assertions
        unique_state_root = $stateA
        foreign_state_root = $stateB
        installed_default_state_root = $sharedDefault
        candidate_default_state_root = $candidateDefault
        run_id = $runId
        marker_path = $markerPath
        marker_token = ('R1-MARKER-' + $stamp)
        unique_start_decision = $uniqueDecision
        default_start_decision = $defaultDecision
        first = $firstJson
        replay = $replayJson
        independent = [ordered]@{
            inbox_after_complete = [IO.File]::Exists($inbox)
            claimed = [IO.File]::Exists($claimed)
            outbox = [IO.File]::Exists($outbox)
            outbox_terminal = $(if ($null -ne $outboxDoc -and $outboxDoc.Contains('terminal')) { [string]$outboxDoc.terminal } else { '' })
            marker_exists = [IO.File]::Exists($markerPath)
            foreign_marker = [IO.File]::Exists($foreignMarker)
            foreign_inbox = [IO.File]::Exists($foreignInbox)
            live_default_marker = [IO.File]::Exists($liveMarker)
        }
        scheduled_task = [ordered]@{
            name = 'TelephoneLineWiredSupervisor'
            last_run_before = $taskLastRunBefore
            last_run_after = $taskLastRunAfter
            mutated = $false
        }
        remaining_default_path_dependency = [ordered]@{
            consumer = 'shared-scheduled-task'
            live_wrapper = 'SupervisorNoConsoleHost.exe has no requested-state argument'
            live_host_visible_until_apply = 'installed Start-TelephoneSupervisorHostVisible.ps1 still hardcodes install/supervisor-state until this candidate is applied'
            no_shared_task_mutation_this_hop = $true
        }
        oracle_not_only_launched_true = $true
        mocked_task_operation = $false
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
    foreach ($pair in @($previous.GetEnumerator())) {
        $envName = switch ([string]$pair.Key) {
            'TASK_BACKEND' { 'TELEPHONE_LINE_TASK_BACKEND' }
            'TASK_STORE' { 'TELEPHONE_LINE_TASK_STORE' }
            'SUP_STATE' { 'TELEPHONE_LINE_SUPERVISOR_STATE_ROOT' }
            'LINE_STATE' { 'TELEPHONE_LINE_STATE_ROOT' }
            'INSTALL' { 'TELEPHONE_LINE_INSTALL_ROOT' }
            default { '' }
        }
        if (-not [string]::IsNullOrWhiteSpace($envName)) {
            [Environment]::SetEnvironmentVariable($envName, [string]$pair.Value, 'Process')
        }
    }
}

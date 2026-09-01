# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$StateRoot,
    [string]$RunId,
    [string]$MarkerDirectory,
    [int]$HoldMilliseconds = 8000,
    [switch]$ExitImmediately,
    [switch]$SpawnSuccessor,
    [switch]$BatchFanIn,
    [string]$BatchSpecFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($MarkerDirectory)) {
    $MarkerDirectory = [string]$env:TELEPHONE_LINE_SUPERVISOR_MARKER_DIR
}
if ([string]::IsNullOrWhiteSpace($MarkerDirectory)) { throw 'Mock wired lead marker directory is required.' }
$markerRoot = [IO.Path]::GetFullPath($MarkerDirectory).TrimEnd('\')
if (-not [IO.Directory]::Exists($markerRoot)) { [IO.Directory]::CreateDirectory($markerRoot) | Out-Null }
$pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$self = Get-Process -Id $PID
try {
    $leadPid = [int]$PID
    $leadTicks = [int64]$self.StartTime.ToUniversalTime().Ticks
} finally {
    $self.Dispose()
}

if ($BatchFanIn) {
    if ([string]::IsNullOrWhiteSpace($BatchSpecFile) -or -not [IO.File]::Exists($BatchSpecFile)) {
        throw 'Batch fan-in spec file is required.'
    }
    [IO.File]::WriteAllText((Join-Path $markerRoot ('lead-' + [string]$RunId + '.json')), ((([ordered]@{
        run_id = [string]$RunId
        lead_pid = $leadPid
        lead_start_time_utc_ticks = $leadTicks
        batch_fan_in = $true
        in_job_probe = $true
        launch_pending = $true
    }) | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    try {
    $spec = Get-Content -LiteralPath $BatchSpecFile -Raw | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    if ($spec -isnot [Collections.IDictionary]) { throw 'Batch fan-in spec is invalid.' }
    $telState = [string]$spec.tel_state
    $starter = [string]$spec.starter
    $binding = $spec.binding
    $batchId = [string]$spec.batch_id
    $packageIds = @($spec.package_ids | ForEach-Object { [string]$_ })
    $project = if ($spec.Contains('project')) { [string]$spec.project } else { 'wired-mailbox' }
    $worktree = [string]$spec.worktree
    $retryOf = ''
    if ($spec.Contains('retry_of') -and -not [string]::IsNullOrWhiteSpace([string]$spec.retry_of)) { $retryOf = [string]$spec.retry_of }
    if ($spec.Contains('telephone_state_root') -and -not [string]::IsNullOrWhiteSpace([string]$spec.telephone_state_root)) { $telState = [string]$spec.telephone_state_root }
    $env:TELEPHONE_LINE_STATE_ROOT = $telState
    if ($spec.Contains('lead_log') -and -not [string]::IsNullOrWhiteSpace([string]$spec.lead_log)) { $env:TELEPHONE_TEST_LEAD_LOG = [string]$spec.lead_log }
    if ($spec.Contains('lead_runs') -and -not [string]::IsNullOrWhiteSpace([string]$spec.lead_runs)) { $env:TELEPHONE_TEST_LEAD_RUNS = [string]$spec.lead_runs }
    if ($spec.Contains('collector_idle_ms') -and -not [string]::IsNullOrWhiteSpace([string]$spec.collector_idle_ms)) {
        $env:TELEPHONE_TEST_COLLECTOR_IDLE_MS = [string]$spec.collector_idle_ms
    }
    [IO.Directory]::CreateDirectory($telState) | Out-Null
    [IO.Directory]::CreateDirectory($worktree) | Out-Null
    $prepared = [Collections.Generic.List[object]]::new()
    foreach ($row in @($spec.packages)) {
        $packageId = [string]$row.id
        $jobId = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        $requestPath = Join-Path $worktree ('request-' + $packageId + '-' + $jobId + '.json')
        $batch = [ordered]@{
            protocol_version = 'telephone-line-batch-v1'
            batch_id = $batchId
            package_id = $packageId
            package_ids = @($packageIds)
            n = [int]$packageIds.Count
        }
        if (-not [string]::IsNullOrWhiteSpace($retryOf)) { $batch['retry_of'] = $retryOf }
        $arguments = [Collections.Generic.List[string]]::new()
        [void]$arguments.Add('-NoLogo'); [void]$arguments.Add('-NoProfile'); [void]$arguments.Add('-NonInteractive')
        [void]$arguments.Add('-ExecutionPolicy'); [void]$arguments.Add('Bypass'); [void]$arguments.Add('-File')
        $routePath = [string]$spec.mock_route
        if ($row.Contains('hold_path') -and -not [string]::IsNullOrWhiteSpace([string]$row.hold_path)) {
            $routePath = [string]$spec.hold_route
            [void]$arguments.Add($routePath)
            [void]$arguments.Add('-CounterPath'); [void]$arguments.Add([string]$row.counter)
            [void]$arguments.Add('-HoldPath'); [void]$arguments.Add([string]$row.hold_path)
        } else {
            [void]$arguments.Add($routePath)
            [void]$arguments.Add('-CounterPath'); [void]$arguments.Add([string]$row.counter)
        }
        [void]$arguments.Add('-DelayMilliseconds'); [void]$arguments.Add('0')
        [void]$arguments.Add('-FinalText'); [void]$arguments.Add('DONE-' + $packageId)
        [void]$arguments.Add('-ExitCode'); [void]$arguments.Add([string][int]$row.exit)
        $request = [ordered]@{
            protocol_version = 'telephone-line-dispatch-v1'
            line_job_id = $jobId
            project = $project
            stage = 'SIMULATION'
            role = 'execution'
            route = 'mock-route'
            summary = ('wired mailbox ' + $packageId)
            lead = $binding
            batch = $batch
            command = [ordered]@{
                executable = $pwsh
                working_directory = $worktree
                arguments = @($arguments)
            }
        }
        [IO.File]::WriteAllText($requestPath, (($request | ConvertTo-Json -Depth 32).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
        [void]$prepared.Add([ordered]@{
            package_id = $packageId
            line_job_id = $jobId
            job_root = Join-Path $telState ('jobs\' + $jobId)
            request_path = $requestPath
            force_start_failed = [bool]$row.fail
            counter = [string]$row.counter
        })
    }
    $jobsEarly = [ordered]@{}
    foreach ($row in $prepared) {
        $jobsEarly[[string]$row.package_id] = [ordered]@{
            package_id = [string]$row.package_id
            line_job_id = [string]$row.line_job_id
            job_root = [string]$row.job_root
            counter = [string]$row.counter
        }
    }
    [IO.File]::WriteAllText((Join-Path $markerRoot ('lead-' + [string]$RunId + '.json')), ((([ordered]@{
        run_id = [string]$RunId
        lead_pid = $leadPid
        lead_start_time_utc_ticks = $leadTicks
        batch_id = $batchId
        jobs = $jobsEarly
        in_job_probe = $true
        batch_fan_in = $true
        launch_pending = $true
    }) | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $handles = [Collections.Generic.List[object]]::new()
    $startedAtUtc = [ordered]@{}
    foreach ($row in $prepared) {
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $pwsh
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $starter, '-RequestFile', [string]$row.request_path, '-StateRoot', $telState)) {
            [void]$info.ArgumentList.Add([string]$argument)
        }
        if ([bool]$row.force_start_failed) {
            $info.Environment['TELEPHONE_TEST_FORCE_COMMAND_START_FAILED'] = [string]$row.package_id
        } else {
            $info.Environment['TELEPHONE_TEST_FORCE_COMMAND_START_FAILED'] = ''
        }
        $process = [Diagnostics.Process]::Start($info)
        if ($null -eq $process) { throw ('Near-simultaneous start failed: ' + [string]$row.package_id) }
        $stamp = $null
        try {
            $process.Refresh()
            $stamp = [DateTimeOffset]::new($process.StartTime.ToUniversalTime())
        } catch { $stamp = $null }
        if ($null -eq $stamp) {
            $live = Get-Process -Id ([int]$process.Id) -ErrorAction SilentlyContinue
            if ($null -ne $live) {
                try { $stamp = [DateTimeOffset]::new($live.StartTime.ToUniversalTime()) } finally { $live.Dispose() }
            }
        }
        if ($null -eq $stamp) { $stamp = [DateTimeOffset]::UtcNow }
        $startedAtUtc[[string]$row.package_id] = $stamp.ToString('o')
        [void]$handles.Add([ordered]@{
            row = $row
            process = $process
            started_at_utc = $stamp
        })
        $process.Dispose()
    }
    $startMs = [Collections.Generic.List[int64]]::new()
    foreach ($handle in $handles) { [void]$startMs.Add([int64]$handle.started_at_utc.ToUnixTimeMilliseconds()) }
    $spanMs = [int]((($startMs | Measure-Object -Maximum).Maximum) - (($startMs | Measure-Object -Minimum).Minimum))
    $jobs = $jobsEarly
    $evidence = [ordered]@{
        run_id = [string]$RunId
        lead_pid = $leadPid
        lead_start_time_utc_ticks = $leadTicks
        batch_id = $batchId
        launch_span_ms = $spanMs
        launch_started_at_utc = $startedAtUtc
        jobs = $jobs
        in_job_probe = $true
        batch_fan_in = $true
    }
    [IO.File]::WriteAllText((Join-Path $markerRoot ('lead-' + [string]$RunId + '.json')), (($evidence | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    exit 0
    } catch {
        [IO.File]::WriteAllText((Join-Path $markerRoot ('lead-' + [string]$RunId + '.json')), ((([ordered]@{
            run_id = [string]$RunId
            lead_pid = $leadPid
            lead_start_time_utc_ticks = $leadTicks
            batch_fan_in = $true
            error = [string]$_.Exception.Message
        }) | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
        throw
    }
}

$childScript = Join-Path $PSScriptRoot 'mock-owned-child.ps1'
$childMarker = Join-Path $markerRoot ('child-' + [string]$RunId + '.json')
$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = $pwsh
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$childArgs = @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $childScript, '-MarkerFile', $childMarker, '-HoldMilliseconds', ([string]$HoldMilliseconds)
)
if ($SpawnSuccessor) { $childArgs += '-SpawnSuccessor' }
foreach ($argument in $childArgs) {
    [void]$info.ArgumentList.Add([string]$argument)
}
$child = [Diagnostics.Process]::Start($info)
try {
    $evidence = [ordered]@{
        run_id = [string]$RunId
        lead_pid = $leadPid
        lead_start_time_utc_ticks = $leadTicks
        child_pid = [int]$child.Id
        in_job_probe = $true
    }
    [IO.File]::WriteAllText((Join-Path $markerRoot ('lead-' + [string]$RunId + '.json')), (($evidence | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
} catch { }
if ($ExitImmediately) {
    $child.Dispose()
    exit 0
}
$stopFile = Join-Path $markerRoot ('stop-' + [string]$RunId)
$deadline = [DateTimeOffset]::UtcNow.AddMilliseconds([Math]::Max(200, [int]$HoldMilliseconds))
while ([DateTimeOffset]::UtcNow -lt $deadline -and -not [IO.File]::Exists($stopFile)) {
    Start-Sleep -Milliseconds 50
}
if (-not $child.HasExited) {
    try { $null = $child.WaitForExit(2000) } catch { }
}
if (-not $child.HasExited) {
    try { Stop-Process -Id ([int]$child.Id) -Force -ErrorAction SilentlyContinue } catch { }
}
$child.Dispose()
exit 0

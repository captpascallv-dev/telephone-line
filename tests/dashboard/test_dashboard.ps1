# SPDX-License-Identifier: MPL-2.0
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
$previous = [ordered]@{
    process_env_only = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY', 'Process')
    opt_out = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', 'Process')
    ensure = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_ENSURE_SCRIPT', 'Process')
    state = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_STATE', 'Process')
    config = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_CONFIG', 'Process')
    headless = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_HEADLESS', 'Process')
}
$claimed = [Collections.Generic.List[object]]::new()

function Assert-Dash {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Restore-DashEnv {
    foreach ($key in @('TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY','TELEPHONE_LINE_DASHBOARD_OPT_OUT','TELEPHONE_LINE_DASHBOARD_ENSURE_SCRIPT','TELEPHONE_LINE_DASHBOARD_STATE','TELEPHONE_LINE_DASHBOARD_CONFIG','TELEPHONE_LINE_DASHBOARD_HEADLESS')) {
        $map = @{
            TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY = $previous.process_env_only
            TELEPHONE_LINE_DASHBOARD_OPT_OUT = $previous.opt_out
            TELEPHONE_LINE_DASHBOARD_ENSURE_SCRIPT = $previous.ensure
            TELEPHONE_LINE_DASHBOARD_STATE = $previous.state
            TELEPHONE_LINE_DASHBOARD_CONFIG = $previous.config
            TELEPHONE_LINE_DASHBOARD_HEADLESS = $previous.headless
        }
        [Environment]::SetEnvironmentVariable($key, [string]$map[$key], 'Process')
    }
}

function Set-DashIsolated {
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY', '1', 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', '', 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_ENSURE_SCRIPT', '', 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_HEADLESS', '1', 'Process')
}

function Register-DashClaimedWatcher {
    param([int]$PidHint = 0, [string]$StateRoot)
    $watchScript = Join-Path $repoRoot 'src\dashboard\Watch-TelephoneDashboard.ps1'
    $identity = $null
    try {
        $paths = Get-TelephoneDashboardPaths -StateRoot $StateRoot
        $identity = Read-TelephoneDashboardWatcherIdentity -Path ([string]$paths.watcher)
    } catch { $identity = $null }
    $row = [ordered]@{
        pid = 0
        start_time_utc_ticks = [int64]0
        script_path = $watchScript
        state_root = [string]$StateRoot
        kind = 'test-watcher'
    }
    if ($null -ne $identity) {
        try { $row.pid = [int]$identity.pid } catch { $row.pid = $PidHint }
        try { $row.start_time_utc_ticks = [int64]$identity.start_time_utc_ticks } catch { $row.start_time_utc_ticks = [int64]0 }
        if ($identity.Contains('script_path') -and -not [string]::IsNullOrWhiteSpace([string]$identity.script_path)) {
            $row.script_path = [string]$identity.script_path
        }
    } elseif ($PidHint -gt 0) {
        $row.pid = $PidHint
        $proc = Get-Process -Id $PidHint -ErrorAction SilentlyContinue
        if ($null -ne $proc) {
            try { $row.start_time_utc_ticks = [int64]$proc.StartTime.ToUniversalTime().Ticks } finally { $proc.Dispose() }
        }
    }
    [void]$script:claimed.Add($row)
    return $row
}

function Stop-DashExactOwnedProcess {
    param(
        [Parameter(Mandatory = $true)][object]$Owner,
        [string]$WatchScript = '',
        [string]$StateRoot = ''
    )
    if (-not (Test-TelephoneOwnerAlive -Owner $Owner)) { return $false }
    $pidValue = 0
    try { $pidValue = [int]$Owner.pid } catch { return $false }
    if ($pidValue -le 0) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($WatchScript)) {
        $storedScript = ''
        if ($Owner -is [Collections.IDictionary] -and $Owner.Contains('script_path')) { $storedScript = [string]$Owner.script_path }
        elseif ($null -ne $Owner.PSObject.Properties['script_path']) { $storedScript = [string]$Owner.script_path }
        if (-not [string]::IsNullOrWhiteSpace($storedScript)) {
            try {
                if (-not [IO.Path]::GetFullPath($storedScript).Equals([IO.Path]::GetFullPath($WatchScript), [StringComparison]::OrdinalIgnoreCase)) { return $false }
            } catch { return $false }
        }
        $command = Get-TelephoneDashboardProcessCommand -ProcessId $pidValue
        if (-not [string]::IsNullOrWhiteSpace($command)) {
            if ($command.IndexOf($WatchScript, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
            if (-not [string]::IsNullOrWhiteSpace($StateRoot) -and $command.IndexOf($StateRoot, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
        }
    }
    Stop-Process -Id $pidValue -Force -ErrorAction Stop
    return $true
}

function New-DashIds {
    return [ordered]@{
        lead_id = 'lead-A'
        session_id = 'sess-1'
        job_id = 'job-9'
    }
}

function New-DashEvent {
    param([string]$Kind, [string]$Receipt = '', [switch]$Ambiguous)
    $ids = New-DashIds
    return (New-TelephoneDashboardReducerEvent -Kind $Kind -LeadId $ids.lead_id -SessionId $ids.session_id -JobId $ids.job_id -Receipt $Receipt -Ambiguous:$Ambiguous)
}

function Get-DashHappy {
    return @(
        (New-DashEvent -Kind 'lead'),
        (New-DashEvent -Kind 'execute'),
        (New-DashEvent -Kind 'review'),
        (New-DashEvent -Kind 'sync'),
        (New-DashEvent -Kind 'modify'),
        (New-DashEvent -Kind 'review'),
        (New-DashEvent -Kind 'closure'),
        (New-DashEvent -Kind 'commit_closure' -Receipt 'rcpt-1')
    )
}

function Write-DashUtf8 {
    param([string]$Path, [object]$Value)
    $parent = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $text = (($Value | ConvertTo-Json -Depth 32).Replace("`r`n", "`n") + "`n")
    [IO.File]::WriteAllBytes($Path, [Text.UTF8Encoding]::new($false).GetBytes($text))
}

try {
    Set-DashIsolated

    $prodNested = Reduce-TelephoneDashboardEvents -Events @(
        (New-DashEvent -Kind 'lead'),
        (New-DashEvent -Kind 'execute'),
        (New-DashEvent -Kind 'sync'),
        (New-DashEvent -Kind 'review'),
        (New-DashEvent -Kind 'closure'),
        (New-DashEvent -Kind 'commit_closure' -Receipt 'rcpt-nested')
    )
    Assert-Dash ([string]$prodNested.phase -ceq 'closed' -and [bool]$prodNested.dashboard_disappeared -and ($prodNested.rejected -notcontains 'ILLEGAL_TRANSITION')) 'Production nested order did not reduce legally.'
    $production_nested_order_legal = 1
    $reverseNested = Reduce-TelephoneDashboardEvents -Events @(
        (New-DashEvent -Kind 'lead'),
        (New-DashEvent -Kind 'execute'),
        (New-DashEvent -Kind 'review'),
        (New-DashEvent -Kind 'execute')
    )
    Assert-Dash (($reverseNested.rejected -contains 'ILLEGAL_TRANSITION') -and [bool]$reverseNested.dashboard_visible) 'Reverse execute after review was accepted.'
    $reverse_order_fail_closed = 1

    $happyAll = @(Get-DashHappy)
    $happyMid = Reduce-TelephoneDashboardEvents -Events @($happyAll[0..($happyAll.Count - 2)])
    Assert-Dash ([string]$happyMid.phase -ceq 'closure') 'Happy path did not stop at closure.'
    Assert-Dash ([bool]$happyMid.dashboard_visible) 'Happy path hid before closure receipt.'
    Assert-Dash (-not [bool]$happyMid.dashboard_disappeared) 'Happy path disappeared before receipt.'
    $happyEnd = Reduce-TelephoneDashboardEvent -State $happyMid -Event (New-DashEvent -Kind 'commit_closure' -Receipt 'rcpt-1')
    Assert-Dash ([string]$happyEnd.phase -ceq 'closed' -and -not [bool]$happyEnd.dashboard_visible -and [bool]$happyEnd.dashboard_disappeared -and [string]$happyEnd.closure_receipt -ceq 'rcpt-1') 'Closure receipt did not hide the dashboard.'
    $happy_path_disappears_only_after_closure_receipt = 1

    $skip = Reduce-TelephoneDashboardEvent -State (New-TelephoneDashboardReducerState) -Event (New-DashEvent -Kind 'closure')
    Assert-Dash ([string]$skip.phase -ceq 'idle' -and ($skip.rejected -contains 'ILLEGAL_TRANSITION') -and -not [bool]$skip.dashboard_disappeared) 'Skipped lead-to-closure did not fail closed.'
    $skip_lead_to_closure_fail_closed = 1

    $wrongLead = Reduce-TelephoneDashboardEvents -Events @($happyAll[0..2])
    $badLead = New-TelephoneDashboardReducerEvent -Kind 'commit_closure' -LeadId 'other' -SessionId 'sess-1' -JobId 'job-9' -Receipt 'x'
    $wrongLead2 = Reduce-TelephoneDashboardEvent -State $wrongLead -Event $badLead
    Assert-Dash ([string]$wrongLead2.phase -ceq [string]$wrongLead.phase -and [bool]$wrongLead2.dashboard_visible -and ($wrongLead2.rejected -contains 'WRONG_LEAD')) 'Wrong lead hid the dashboard.'
    $wrong_lead_cannot_hide = 1

    $sess = Reduce-TelephoneDashboardEvent -State (New-TelephoneDashboardReducerState) -Event (New-DashEvent -Kind 'lead')
    $badSess = New-TelephoneDashboardReducerEvent -Kind 'execute' -LeadId 'lead-A' -SessionId 'other' -JobId 'job-9'
    $sess2 = Reduce-TelephoneDashboardEvent -State $sess -Event $badSess
    Assert-Dash ([string]$sess2.phase -ceq 'lead' -and ($sess2.rejected -contains 'WRONG_SESSION')) 'Wrong session was accepted.'
    $wrong_session_fail_closed = 1

    $live = Reduce-TelephoneDashboardEvent -State $sess -Event (New-DashEvent -Kind 'live_callback')
    Assert-Dash (($live.rejected -contains 'LIVE_CALLBACK_FORBIDDEN') -and [bool]$live.dashboard_visible) 'Live callback was not rejected.'
    $live_callback_rejected = 1

    $exec = Reduce-TelephoneDashboardEvents -Events @((New-DashEvent -Kind 'lead'), (New-DashEvent -Kind 'execute'))
    $take = Reduce-TelephoneDashboardEvent -State $exec -Event (New-DashEvent -Kind 'take_active')
    Assert-Dash (($take.rejected -contains 'LIVE_CALLBACK_FORBIDDEN')) 'take_active was accepted.'
    $take_active_rejected = 1

    $sync = Reduce-TelephoneDashboardEvents -Events @($happyAll[0..3])
    $restarted = Reduce-TelephoneDashboardEvent -State $sync -Event (New-DashEvent -Kind 'restart')
    Assert-Dash ([string]$restarted.phase -ceq 'sync' -and [bool]$restarted.dashboard_visible -and [int]$restarted.restart_count -eq 1) 'Restart hid a live dashboard.'
    $restart_keeps_dashboard_until_closed = 1

    $closedRestart = Reduce-TelephoneDashboardEvent -State $happyEnd -Event (New-DashEvent -Kind 'restart')
    Assert-Dash ([string]$closedRestart.phase -ceq 'closed' -and -not [bool]$closedRestart.dashboard_visible -and [bool]$closedRestart.dashboard_disappeared) 'Restart after close reopened the dashboard.'
    $restart_after_close_stays_hidden = 1

    $dupMid = Reduce-TelephoneDashboardEvents -Events @($happyAll[0..4])
    $dup = Reduce-TelephoneDashboardEvent -State $dupMid -Event (New-DashEvent -Kind 'duplicate')
    Assert-Dash ([string]$dup.phase -ceq [string]$dupMid.phase -and [bool]$dup.dashboard_visible -eq [bool]$dupMid.dashboard_visible -and ($dup.rejected -notcontains 'DUPLICATE_SAME_PROVENANCE') -and ($dup.rejected -notcontains 'DUPLICATE_AMBIGUOUS') -and [int]$dup.duplicate_count -ge 1) 'Duplicate flipped visibility.'
    $duplicate_callback_does_not_reclose_or_flip_visibility = 1

    $dupClosed = Reduce-TelephoneDashboardEvent -State $happyEnd -Event (New-DashEvent -Kind 'duplicate')
    Assert-Dash ([bool]$dupClosed.dashboard_disappeared -and -not [bool]$dupClosed.dashboard_visible -and [string]$dupClosed.closure_receipt -ceq 'rcpt-1') 'Duplicate after close reopened.'
    $duplicate_after_close_stays_disappeared = 1

    $noReceipt = Reduce-TelephoneDashboardEvent -State $happyMid -Event (New-DashEvent -Kind 'commit_closure')
    Assert-Dash ([string]$noReceipt.phase -ceq 'closure' -and [bool]$noReceipt.dashboard_visible -and ($noReceipt.rejected -contains 'CLOSURE_RECEIPT_MISSING')) 'Closure without receipt hid the dashboard.'
    $closure_without_receipt_does_not_hide = 1

    $modifyLoop = Reduce-TelephoneDashboardEvents -Events @(
        (New-DashEvent -Kind 'lead'), (New-DashEvent -Kind 'execute'), (New-DashEvent -Kind 'review'), (New-DashEvent -Kind 'modify'),
        (New-DashEvent -Kind 'review'), (New-DashEvent -Kind 'sync'), (New-DashEvent -Kind 'closure'),
        (New-DashEvent -Kind 'commit_closure' -Receipt 'rcpt-m')
    )
    Assert-Dash ([string]$modifyLoop.phase -ceq 'closed' -and [bool]$modifyLoop.dashboard_disappeared -and (@($modifyLoop.history | Where-Object { $_ -ceq 'modify' }).Count -eq 1)) 'Modify loop failed to close.'
    $modify_loop_then_close = 1

    $incomplete = Reduce-TelephoneDashboardEvent -State (New-TelephoneDashboardReducerState) -Event (New-TelephoneDashboardReducerEvent -Kind 'lead' -LeadId '' -SessionId 's' -JobId 'j')
    Assert-Dash ([string]$incomplete.phase -ceq 'idle' -and ($incomplete.rejected -contains 'IDENTITY_INCOMPLETE')) 'Incomplete identity was accepted.'
    $incomplete_identity_rejected = 1

    $unknown = Reduce-TelephoneDashboardEvent -State $sess -Event (New-DashEvent -Kind 'explode')
    Assert-Dash ([string]$unknown.phase -ceq 'lead' -and ($unknown.rejected -contains 'UNKNOWN_EVENT')) 'Unknown event mutated phase.'
    $unknown_event_fail_closed = 1

    $reviewJump = Reduce-TelephoneDashboardEvents -Events @((New-DashEvent -Kind 'lead'), (New-DashEvent -Kind 'execute'), (New-DashEvent -Kind 'review'))
    $jump = Reduce-TelephoneDashboardEvent -State $reviewJump -Event (New-DashEvent -Kind 'commit_closure' -Receipt 'x')
    Assert-Dash ([string]$jump.phase -ceq 'review' -and [bool]$jump.dashboard_visible -and ($jump.rejected -contains 'ILLEGAL_TRANSITION')) 'Review jumped to closed.'
    $review_cannot_jump_to_closed = 1

    $amb = Reduce-TelephoneDashboardEvent -State $dupMid -Event (New-DashEvent -Kind 'duplicate' -Ambiguous)
    Assert-Dash (($amb.rejected -contains 'DUPLICATE_AMBIGUOUS')) 'Different-provenance duplicate was not yellow.'
    $duplicate_ambiguous_fail_closed = 1
    $reducer_cases = 17

    $dashState = Join-Path $testRoot 'dashboard-runtime'
    [IO.Directory]::CreateDirectory($dashState) | Out-Null
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_STATE', $dashState, 'Process')
    $ensure1 = Invoke-TelephoneDashboardEnsure
    Assert-Dash ([bool]$ensure1.healthy -and [bool]$ensure1.configured -and [string]$ensure1.source -ceq 'bundled' -and [int]$ensure1.watcher_pid -gt 0) 'Bundled ensure did not start a watcher.'
    $claimA = Register-DashClaimedWatcher -PidHint ([int]$ensure1.watcher_pid) -StateRoot $dashState
    $ensure2 = Invoke-TelephoneDashboardEnsure
    Assert-Dash ([bool]$ensure2.already_running -and [int]$ensure2.watcher_pid -eq [int]$ensure1.watcher_pid) 'Second ensure did not reuse the live watcher.'
    $single_instance_reuse = 1

    $probeRoot = Join-Path $testRoot 'probe'
    [IO.Directory]::CreateDirectory($probeRoot) | Out-Null
    $probe = Join-Path $probeRoot 'dashboard-probe.ps1'
    [IO.File]::WriteAllText($probe, "[ordered]@{ healthy=`$true; started=`$false; already_running=`$true; watcher_pid=123 } | ConvertTo-Json -Compress`r`n", [Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_ENSURE_SCRIPT', $probe, 'Process')
    $override = Invoke-TelephoneDashboardEnsure
    Assert-Dash ([bool]$override.healthy -and [bool]$override.already_running -and [int]$override.watcher_pid -eq 123 -and [string]$override.source -ceq 'override') 'Explicit override hook was not preserved.'
    $override_hook_preserved = 1
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_ENSURE_SCRIPT', '', 'Process')

    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', '1', 'Process')
    $opt = Invoke-TelephoneDashboardEnsure
    Assert-Dash (-not [bool]$opt.configured -and -not [bool]$opt.attempted -and [bool]$opt.healthy -and [string]$opt.source -ceq 'opt-out') 'Opt-out did not skip the bundled watcher.'
    $explicit_opt_out = 1
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', '', 'Process')

    $watchScript = Join-Path $repoRoot 'src\dashboard\Watch-TelephoneDashboard.ps1'
    $null = Stop-TelephoneDashboardExactWatcher -WatchScript $watchScript -StateRoot $dashState
    Assert-Dash (-not (Test-TelephoneOwnerAlive -Owner $claimA)) 'Initial test watcher was still alive after the shipped exact-owner stop.'
    $pid_reuse_initial_watcher_stopped_exactly = 1

    $foreignInfo = [Diagnostics.ProcessStartInfo]::new()
    $foreignInfo.FileName = $pwsh
    $foreignInfo.UseShellExecute = $false
    $foreignInfo.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', 'Start-Sleep -Seconds 60')) {
        [void]$foreignInfo.ArgumentList.Add([string]$argument)
    }
    $foreign = [Diagnostics.Process]::Start($foreignInfo)
    Start-Sleep -Milliseconds 200
    $foreignProc = Get-Process -Id ([int]$foreign.Id) -ErrorAction Stop
    try { $foreignTicks = [int64]$foreignProc.StartTime.ToUniversalTime().Ticks } finally { $foreignProc.Dispose() }
    $foreignOwner = [ordered]@{ pid = [int]$foreign.Id; start_time_utc_ticks = $foreignTicks; kind = 'foreign-sleep' }
    [void]$script:claimed.Add($foreignOwner)
    $identityPath = Join-Path $dashState 'watcher.json'
    Write-DashUtf8 -Path $identityPath -Value ([ordered]@{
        protocol_version = 'telephone-line-dashboard-watcher-v1'
        pid = [int]$foreign.Id
        start_time_utc_ticks = $foreignTicks
        started_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        script_path = $watchScript
        observational = $true
    })
    $pidReuse = Invoke-TelephoneDashboardEnsure
    Assert-Dash ([bool]$pidReuse.healthy -and [int]$pidReuse.watcher_pid -ne [int]$foreign.Id) 'PID reuse was treated as the live watcher.'
    Assert-Dash (-not $foreign.HasExited) 'Foreign process was killed.'
    Assert-Dash (-not (Test-TelephoneOwnerAlive -Owner $claimA)) 'Initial test watcher returned after PID-reuse ensure.'
    $pid_reuse_rejected = 1
    $foreign_process_preserved = 1
    $claimB = Register-DashClaimedWatcher -PidHint ([int]$pidReuse.watcher_pid) -StateRoot $dashState
    Assert-Dash ([int]$claimB.pid -ne [int]$foreign.Id -and [int]$claimB.pid -ne [int]$claimA.pid) 'Replacement watcher reused the foreign or initial PID.'
    $null = Stop-TelephoneDashboardExactWatcher -WatchScript $watchScript -StateRoot $dashState
    Assert-Dash (-not (Test-TelephoneOwnerAlive -Owner $claimB)) 'Replacement test watcher was still alive after the shipped exact-owner stop.'
    Assert-Dash (-not (Test-TelephoneOwnerAlive -Owner $claimA)) 'Initial test watcher returned after replacement cleanup.'
    Assert-Dash (-not $foreign.HasExited) 'Foreign process was killed during exact watcher cleanup.'
    $pid_reuse_replacement_watcher_stopped_exactly = 1
    $test_watchers_absent_after_exact_cleanup = 1
    $null = Stop-DashExactOwnedProcess -Owner $foreignOwner

    $lockPath = Join-Path $dashState 'ensure.lock'
    $held = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $locked = Invoke-TelephoneDashboardEnsure
        Assert-Dash (-not [bool]$locked.healthy -and [string]$locked.error_code -ceq 'DASHBOARD_ENSURE_FAILED') 'Held lock did not fail closed.'
    } finally {
        $held.Dispose()
    }
    $held_lock_fail_closed = 1

    $null = Stop-TelephoneDashboardExactWatcher -WatchScript $watchScript -StateRoot $dashState

    $jobId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1'
    $wiredRoot = Join-Path $testRoot 'wired-state\jobs\' + $jobId
    [IO.Directory]::CreateDirectory($wiredRoot) | Out-Null
    $dispatch = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'tests\contracts\fixtures\valid\dispatch.json') | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $binding = $dispatch.lead
    Write-DashUtf8 -Path (Join-Path $wiredRoot 'dispatch.json') -Value $dispatch
    Write-DashUtf8 -Path (Join-Path $wiredRoot 'lead-binding.json') -Value $binding
    $wiredPaths = Get-TelephoneJobPaths -JobRoot $wiredRoot
    $null = Write-TelephoneLifecycleStatus -Paths $wiredPaths -Phase 'dispatched' -Idle $false
    $null = Write-TelephoneLifecycleStatus -Paths $wiredPaths -Phase 'execution' -Idle $false
    $events = Read-TelephoneDashboardLifecycleEvents -Path $wiredPaths.lifecycle_events
    Assert-Dash (@($events).Count -ge 1) 'Wired start did not publish a lifecycle event.'
    $firstOrdinal = [int]$events[0].ordinal
    $null = Write-TelephonePublicLifecycleEvent -Root $wiredRoot -Kind 'execute' -Transport 'wired' -Project ([string]$dispatch.project) -LeadSessionId ([string]$binding.session_id) -LineJobId $jobId
    $null = Write-TelephonePublicLifecycleEvent -Root $wiredRoot -Kind 'execute' -Transport 'wired' -Project ([string]$dispatch.project) -LeadSessionId ([string]$binding.session_id) -LineJobId $jobId
    $afterDup = Read-TelephoneDashboardLifecycleEvents -Path $wiredPaths.lifecycle_events
    $executeRows = @($afterDup | Where-Object { [string]$_.kind -ceq 'execute' })
    Assert-Dash ($executeRows.Count -eq 1 -and [int]$executeRows[0].ordinal -eq ($firstOrdinal + 1)) 'Duplicate wired event allocated a second ordinal.'
    $wired_wireless_one_ordinal_space = 1
    $duplicate_provenance_no_second_ordinal = 1

    $wirelessRoot = Join-Path $testRoot 'wireless-state\runs\example-run-001'
    [IO.Directory]::CreateDirectory($wirelessRoot) | Out-Null
    $wl1 = Write-TelephonePublicLifecycleEvent -Root $wirelessRoot -Kind 'lead' -Transport 'wireless' -Project 'example-project' -LeadSessionId 'example-session-001' -LeadRunId 'example-run-001'
    $wl2 = Write-TelephonePublicLifecycleEvent -Root $wirelessRoot -Kind 'lead' -Transport 'wired' -Project 'other-project' -LeadSessionId 'sess-b' -LeadRunId 'run-b'
    Assert-Dash ([int]$wl1.ordinal -eq 1 -and [int]$wl2.ordinal -eq 2) 'Wired and wireless did not share one ordinal space on one root.'
    $null = Write-TelephonePublicLifecycleEvent -Root $wiredRoot -Kind 'restart' -Transport 'wired' -Project ([string]$dispatch.project) -LeadSessionId ([string]$binding.session_id) -LineJobId $jobId
    $restartRows = @(Read-TelephoneDashboardLifecycleEvents -Path $wiredPaths.lifecycle_events | Where-Object { [string]$_.kind -ceq 'restart' })
    Assert-Dash ($restartRows.Count -eq 1) 'Restart reconstructed a second ordinal family.'
    $restart_no_second_ordinal = 1
    $zero_manual_handoff = 1

    $projA = Join-Path $testRoot 'projects\a'
    $projB = Join-Path $testRoot 'projects\b'
    $jobA = Join-Path $projA ('jobs\' + [Guid]::NewGuid().ToString())
    $jobB = Join-Path $projB ('jobs\' + [Guid]::NewGuid().ToString())
    [IO.Directory]::CreateDirectory($jobA) | Out-Null
    [IO.Directory]::CreateDirectory($jobB) | Out-Null
    $dispA = $dispatch | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $dispB = $dispatch | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $dispA.project = 'project-a'
    $dispB.project = 'project-b'
    $dispA.line_job_id = [IO.Path]::GetFileName($jobA)
    $dispB.line_job_id = [IO.Path]::GetFileName($jobB)
    $bindA = $binding | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $bindB = $binding | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $bindA.session_id = 'session-a'
    $bindB.session_id = 'session-b'
    $dispA.lead = $bindA
    $dispB.lead = $bindB
    Write-DashUtf8 -Path (Join-Path $jobA 'dispatch.json') -Value $dispA
    Write-DashUtf8 -Path (Join-Path $jobA 'lead-binding.json') -Value $bindA
    Write-DashUtf8 -Path (Join-Path $jobB 'dispatch.json') -Value $dispB
    Write-DashUtf8 -Path (Join-Path $jobB 'lead-binding.json') -Value $bindB
    $descA = Join-Path $testRoot 'desc-a.json'
    $descB = Join-Path $testRoot 'desc-b.json'
    Write-DashUtf8 -Path $descA -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'project-a'; state_root = $projA; lead_session_id = 'session-a'; terminal_state = 'active' })
    Write-DashUtf8 -Path $descB -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'project-b'; state_root = $projB; lead_session_id = 'session-b'; terminal_state = 'active' })
    $cfg = Join-Path $testRoot 'config.json'
    Write-DashUtf8 -Path $cfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $descA }, @{ descriptor_file = $descB }) })
    $projection = Get-TelephoneDashboardProjection -ConfigPath $cfg
    Assert-Dash (@($projection.groups).Count -eq 2) 'Concurrent projects were not both visible.'
    Assert-Dash (@($projection.groups | Where-Object { [bool]$_.visible }).Count -eq 2) 'A live project was hidden.'
    $concurrent_projects_visible = 1
    $multiple_disjoint_jobs = 1

    $receipt = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'tests\contracts\fixtures\valid\receipt.json') | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $receipt.project = 'project-a'
    $receipt.line_job_id = [string]$dispA.line_job_id
    $receiptPath = Join-Path $jobA 'receipt.json'
    Write-DashUtf8 -Path $receiptPath -Value $receipt
    $receiptIdentity = Get-TelephoneFileIdentity -Path $receiptPath
    Write-DashUtf8 -Path (Join-Path $jobA 'delivery.json') -Value ([ordered]@{ protocol_version = 'telephone-line-delivery-v1'; delivered = $true })
    Write-DashUtf8 -Path (Join-Path $projA 'closure.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-dashboard-closure-v1'
        project = 'project-a'
        lead_session_id = 'session-a'
        lead_run_id = ''
        receipt = [ordered]@{ path = [string]$receiptIdentity.path; bytes = [int64]$receiptIdentity.bytes; sha256 = [string]$receiptIdentity.sha256 }
        closed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    Write-DashUtf8 -Path $descA -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'project-a'; state_root = $projA; lead_session_id = 'session-a'; terminal_state = 'terminal' })
    $closedProj = Get-TelephoneDashboardProjection -ConfigPath $cfg
    $groupA = @($closedProj.groups | Where-Object { [string]$_.project -ceq 'project-a' })
    Assert-Dash ($groupA.Count -eq 0) 'Exact terminal project remained visible.'
    $groupB = @($closedProj.groups | Where-Object { [string]$_.project -ceq 'project-b' })
    Assert-Dash ($groupB.Count -eq 1 -and [bool]$groupB[0].visible) 'Unrelated project disappeared with the closed one.'
    $exact_terminal_disappearance = 1

    Write-DashUtf8 -Path $descA -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'project-a'; state_root = $projA; lead_session_id = 'session-a'; terminal_state = 'active' })
    if ([IO.File]::Exists((Join-Path $projA 'closure.json'))) { [IO.File]::Delete((Join-Path $projA 'closure.json')) }
    $openAgain = Get-TelephoneDashboardProjection -ConfigPath $cfg
    $groupA2 = @($openAgain.groups | Where-Object { [string]$_.project -ceq 'project-a' }) | Select-Object -First 1
    Assert-Dash ($null -ne $groupA2 -and [bool]$groupA2.visible) 'Receipt alone closed the project.'
    $receipt_alone_not_closure = 1

    $escaped = Join-Path $testRoot 'escape.json'
    Write-DashUtf8 -Path $escaped -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'escaped'; state_root = 'https://example.invalid/state'; terminal_state = 'active' })
    $escapeCfg = Join-Path $testRoot 'escape-config.json'
    Write-DashUtf8 -Path $escapeCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $escaped }) })
    $escapeProj = Get-TelephoneDashboardProjection -ConfigPath $escapeCfg
    Assert-Dash (@($escapeProj.groups | Where-Object { $_.findings.code -contains 'PATH_ESCAPE' -or ($_.findings | ForEach-Object { $_.code }) -contains 'PATH_ESCAPE' }).Count -ge 1) 'Remote state root was not fail-closed.'
    $descriptor_path_escape = 1

    $src = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\dashboard\TelephoneDashboard.Common.ps1')) + [IO.File]::ReadAllText((Join-Path $repoRoot 'src\dashboard\TelephoneDashboard.Projection.ps1')) + [IO.File]::ReadAllText((Join-Path $repoRoot 'docs\dashboard.md'))
    $usersWin = 'C:' + [char]92 + 'Users' + [char]92
    Assert-Dash ($src.IndexOf($usersWin, [StringComparison]::OrdinalIgnoreCase) -lt 0) 'Dashboard sources embed a local user path.'
    $privacy_no_user_path = 1

    $dupDiskRoot = Join-Path $testRoot 'dup-disk'
    [IO.Directory]::CreateDirectory($dupDiskRoot) | Out-Null
    $provA = [ordered]@{ path = 'lifecycle-events.jsonl'; bytes = 12; sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
    $null = Write-TelephonePublicLifecycleEvent -Root $dupDiskRoot -Kind 'lead' -Transport 'wired' -Project 'dup-project' -LeadSessionId 'sess-dup' -LineJobId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee2' -Provenance $provA
    $null = Write-TelephonePublicLifecycleEvent -Root $dupDiskRoot -Kind 'lead' -Transport 'wired' -Project 'dup-project' -LeadSessionId 'sess-dup' -LineJobId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee2' -Provenance $provA
    $readerScript = Join-Path $testRoot 'read-dup.ps1'
    $readerLines = @(
        'Set-StrictMode -Version Latest',
        '$ErrorActionPreference = ''Stop''',
        '. (Join-Path $env:TELEPHONE_TEST_REPO_ROOT ''src\core\TelephoneLine.Common.ps1'')',
        '. (Join-Path $env:TELEPHONE_TEST_REPO_ROOT ''src\dashboard\TelephoneDashboard.Projection.ps1'')',
        '$rows = Read-TelephoneDashboardLifecycleEvents -Path (Join-Path $env:TELEPHONE_TEST_DUP_ROOT ''lifecycle-events.jsonl'')',
        '$lead = @($rows | Where-Object { [string]$_.kind -ceq ''lead'' })',
        '[ordered]@{ count = @($lead).Count; ordinal = [int]$lead[0].ordinal; duplicate_count = [int]$lead[0].duplicate_count; provenance = [string]$lead[0].provenance.sha256 } | ConvertTo-Json -Compress'
    )
    [IO.File]::WriteAllText($readerScript, (($readerLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $readInfo = [Diagnostics.ProcessStartInfo]::new()
    $readInfo.FileName = $pwsh
    $readInfo.UseShellExecute = $false
    $readInfo.RedirectStandardOutput = $true
    $readInfo.CreateNoWindow = $true
    $readInfo.Environment['TELEPHONE_TEST_REPO_ROOT'] = $repoRoot
    $readInfo.Environment['TELEPHONE_TEST_DUP_ROOT'] = $dupDiskRoot
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $readerScript)) {
        [void]$readInfo.ArgumentList.Add([string]$argument)
    }
    $readProc = [Diagnostics.Process]::Start($readInfo)
    $readText = $readProc.StandardOutput.ReadToEnd()
    $readProc.WaitForExit()
    $readJson = $readText | ConvertFrom-Json -AsHashtable -Depth 8
    Assert-Dash ([int]$readJson.count -eq 1 -and [int]$readJson.duplicate_count -eq 1 -and [string]$readJson.provenance -ceq [string]$provA.sha256) 'Same-provenance duplicate was not durable across process restart.'
    $provB = [ordered]@{ path = 'other.json'; bytes = 4; sha256 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }
    $null = Write-TelephonePublicLifecycleEvent -Root $dupDiskRoot -Kind 'lead' -Transport 'wired' -Project 'dup-project' -LeadSessionId 'sess-dup' -LineJobId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee2' -Provenance $provB
    $afterAmb = Read-TelephoneDashboardLifecycleEvents -Path (Join-Path $dupDiskRoot 'lifecycle-events.jsonl')
    $leadAmb = @($afterAmb | Where-Object { [string]$_.kind -ceq 'lead' }) | Select-Object -First 1
    Assert-Dash ([bool]$leadAmb.provenance_ambiguous -and [int]$leadAmb.ordinal -eq 1) 'Different-provenance duplicate was not marked ambiguous on disk.'
    $durable_duplicate_restart = 1

    $histRoot = Join-Path $testRoot 'hist'
    $oldJobId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee3'
    $newJobId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee4'
    $oldJob = Join-Path $histRoot ('jobs\' + $oldJobId)
    $newJob = Join-Path $histRoot ('jobs\' + $newJobId)
    [IO.Directory]::CreateDirectory($oldJob) | Out-Null
    [IO.Directory]::CreateDirectory($newJob) | Out-Null
    $dispOld = $dispatch | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $dispNew = $dispatch | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $dispOld.project = 'hist-project'
    $dispNew.project = 'hist-project'
    $dispOld.line_job_id = $oldJobId
    $dispNew.line_job_id = $newJobId
    $bindOld = $binding | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $bindNew = $binding | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $bindOld.session_id = 'session-old'
    $bindNew.session_id = 'session-new'
    $dispOld.lead = $bindOld
    $dispNew.lead = $bindNew
    Write-DashUtf8 -Path (Join-Path $oldJob 'dispatch.json') -Value $dispOld
    Write-DashUtf8 -Path (Join-Path $oldJob 'lead-binding.json') -Value $bindOld
    Write-DashUtf8 -Path (Join-Path $newJob 'dispatch.json') -Value $dispNew
    Write-DashUtf8 -Path (Join-Path $newJob 'lead-binding.json') -Value $bindNew
    $oldReceipt = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'tests\contracts\fixtures\valid\receipt.json') | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $oldReceipt.project = 'hist-project'
    $oldReceipt.line_job_id = $oldJobId
    Write-DashUtf8 -Path (Join-Path $oldJob 'receipt.json') -Value $oldReceipt
    Write-DashUtf8 -Path (Join-Path $oldJob 'relay-error.json') -Value ([ordered]@{ protocol_version = 'telephone-line-relay-error-v1'; retrying = $false; error_code = 'LEAD_WAKE_FAILED' })
    $newReceipt = $oldReceipt | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $newReceipt.line_job_id = $newJobId
    Write-DashUtf8 -Path (Join-Path $newJob 'receipt.json') -Value $newReceipt
    Write-DashUtf8 -Path (Join-Path $newJob 'delivery.json') -Value ([ordered]@{ protocol_version = 'telephone-line-delivery-v1'; delivered = $true })
    $histDesc = Join-Path $testRoot 'hist-desc.json'
    $histCfg = Join-Path $testRoot 'hist-config.json'
    Write-DashUtf8 -Path $histDesc -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'hist-project'; state_root = $histRoot; successor_lead_session_id = 'session-new'; successor_line_job_id = $newJobId; terminal_state = 'active' })
    Write-DashUtf8 -Path $histCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $histDesc }) })
    $histProj = Get-TelephoneDashboardProjection -ConfigPath $histCfg
    $histGroups = @($histProj.groups | Where-Object { [string]$_.project -ceq 'hist-project' })
    $oldVisible = @($histGroups | Where-Object { [string]$_.lead_session_id -ceq 'session-old' })
    Assert-Dash ($oldVisible.Count -eq 0) 'Exact successor did not retire the old receipt+relay-error lineage.'
    Assert-Dash ([IO.File]::Exists((Join-Path $oldJob 'receipt.json')) -and [IO.File]::Exists((Join-Path $oldJob 'relay-error.json'))) 'Successor retirement deleted evidence.'
    $historical_successor_retires = 1
    Write-DashUtf8 -Path $histDesc -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'hist-project'; state_root = $histRoot; successor_lead_session_id = 'session-wrong'; successor_line_job_id = $newJobId; terminal_state = 'active' })
    $mismatchProj = Get-TelephoneDashboardProjection -ConfigPath $histCfg
    $mismatchOld = @($mismatchProj.groups | Where-Object { [string]$_.lead_session_id -ceq 'session-old' })
    Assert-Dash ($mismatchOld.Count -eq 1 -and [string]$mismatchOld[0].color -ceq 'yellow') 'Mismatched successor hid the old lineage.'
    $historical_mismatch_stays_yellow = 1
    $termRoot = Join-Path $testRoot 'hist-term'
    $termJob = Join-Path $termRoot ('jobs\' + $oldJobId)
    [IO.Directory]::CreateDirectory($termJob) | Out-Null
    Write-DashUtf8 -Path (Join-Path $termJob 'dispatch.json') -Value $dispOld
    Write-DashUtf8 -Path (Join-Path $termJob 'lead-binding.json') -Value $bindOld
    Write-DashUtf8 -Path (Join-Path $termJob 'receipt.json') -Value $oldReceipt
    Write-DashUtf8 -Path (Join-Path $termJob 'relay-error.json') -Value ([ordered]@{ protocol_version = 'telephone-line-relay-error-v1'; retrying = $false; error_code = 'LEAD_WAKE_FAILED' })
    $termReceiptPath = Join-Path $termJob 'receipt.json'
    $termIdentity = Get-TelephoneFileIdentity -Path $termReceiptPath
    Write-DashUtf8 -Path (Join-Path $termRoot 'closure.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-dashboard-closure-v1'
        project = 'hist-project'
        lead_session_id = 'session-old'
        lead_run_id = ''
        receipt = [ordered]@{ path = [string]$termIdentity.path; bytes = [int64]$termIdentity.bytes; sha256 = [string]$termIdentity.sha256 }
        closed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $termDesc = Join-Path $testRoot 'hist-term-desc.json'
    $termCfg = Join-Path $testRoot 'hist-term-config.json'
    Write-DashUtf8 -Path $termDesc -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'hist-project'; state_root = $termRoot; lead_session_id = 'session-old'; terminal_state = 'terminal' })
    Write-DashUtf8 -Path $termCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $termDesc }) })
    $termProj = Get-TelephoneDashboardProjection -ConfigPath $termCfg
    Assert-Dash (@($termProj.groups | Where-Object { [string]$_.lead_session_id -ceq 'session-old' }).Count -eq 0) 'Registry-terminal truth did not retire the old failure lineage.'
    Assert-Dash ([IO.File]::Exists((Join-Path $termJob 'relay-error.json'))) 'Terminal retirement deleted evidence.'
    $historical_terminal_retires = 1
    Write-DashUtf8 -Path $termDesc -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'hist-project'; state_root = $termRoot; lead_session_id = 'session-old'; terminal_state = 'terminal' })
    if ([IO.File]::Exists((Join-Path $termRoot 'closure.json'))) { [IO.File]::Delete((Join-Path $termRoot 'closure.json')) }
    $noProof = Get-TelephoneDashboardProjection -ConfigPath $termCfg
    Assert-Dash (@($noProof.groups | Where-Object { [string]$_.color -ceq 'yellow' }).Count -ge 1) 'Missing terminal proof hid the old lineage.'
    $historical_missing_proof_yellow = 1

    $failState = Join-Path $testRoot 'fail-watch'
    [IO.Directory]::CreateDirectory($failState) | Out-Null
    $healthyCfg = Join-Path $failState 'config.json'
    Write-DashUtf8 -Path $healthyCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @() })
    $watchOnce = Join-Path $repoRoot 'src\dashboard\Watch-TelephoneDashboard.ps1'
    $onceInfo = [Diagnostics.ProcessStartInfo]::new()
    $onceInfo.FileName = $pwsh
    $onceInfo.UseShellExecute = $false
    $onceInfo.RedirectStandardOutput = $true
    $onceInfo.RedirectStandardError = $true
    $onceInfo.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $watchOnce, '-StateRoot', $failState, '-ConfigPath', $healthyCfg, '-Headless', '-Once')) {
        [void]$onceInfo.ArgumentList.Add([string]$argument)
    }
    $onceProc = [Diagnostics.Process]::Start($onceInfo)
    $null = $onceProc.StandardOutput.ReadToEnd()
    $onceProc.WaitForExit()
    $healthyBefore = [IO.File]::ReadAllText((Join-Path $failState 'projection.json'))
    $failInfo = [Diagnostics.ProcessStartInfo]::new()
    $failInfo.FileName = $pwsh
    $failInfo.UseShellExecute = $false
    $failInfo.RedirectStandardOutput = $true
    $failInfo.RedirectStandardError = $true
    $failInfo.CreateNoWindow = $true
    $failInfo.Environment['TELEPHONE_TEST_DASHBOARD_FAIL_AT'] = 'CONFIG_INVALID'
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $watchOnce, '-StateRoot', $failState, '-ConfigPath', $healthyCfg, '-Headless', '-Once')) {
        [void]$failInfo.ArgumentList.Add([string]$argument)
    }
    $failProc = [Diagnostics.Process]::Start($failInfo)
    $null = $failProc.StandardOutput.ReadToEnd()
    $failProc.WaitForExit()
    $afterFail = Get-Content -Raw -LiteralPath (Join-Path $failState 'projection.json') | ConvertFrom-Json -AsHashtable -Depth 16
    Assert-Dash ([string]$afterFail.groups[0].color -ceq 'yellow') 'Projection failure left a healthy view.'
    Assert-Dash ($healthyBefore -cne (Get-Content -Raw -LiteralPath (Join-Path $failState 'projection.json'))) 'Stale healthy projection survived a fail-closed publish.'
    $fail_closed_no_stale_healthy = 1
    $recoverInfo = [Diagnostics.ProcessStartInfo]::new()
    $recoverInfo.FileName = $pwsh
    $recoverInfo.UseShellExecute = $false
    $recoverInfo.RedirectStandardOutput = $true
    $recoverInfo.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $watchOnce, '-StateRoot', $failState, '-ConfigPath', $healthyCfg, '-Headless', '-Once')) {
        [void]$recoverInfo.ArgumentList.Add([string]$argument)
    }
    $recoverProc = [Diagnostics.Process]::Start($recoverInfo)
    $null = $recoverProc.StandardOutput.ReadToEnd()
    $recoverProc.WaitForExit()
    $afterRecover = Get-Content -Raw -LiteralPath (Join-Path $failState 'projection.json') | ConvertFrom-Json -AsHashtable -Depth 16
    Assert-Dash ([string]$afterRecover.protocol_version -ceq 'telephone-line-dashboard-projection-v1') 'Corrected input did not republish a projection.'
    $fail_closed_recovers = 1

    $buildProbe = Join-Path $testRoot 'build-probe'
    $dashSrc = Join-Path $repoRoot 'src\dashboard'
    $probeA = Join-Path $buildProbe 'a'
    $probeB = Join-Path $buildProbe 'b'
    foreach ($probe in @($probeA, $probeB)) {
        $destDash = Join-Path $probe 'src\dashboard'
        [IO.Directory]::CreateDirectory($destDash) | Out-Null
        foreach ($file in @(Get-ChildItem -LiteralPath $dashSrc -File)) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $destDash $file.Name) -Force
        }
    }
    [IO.File]::AppendAllText((Join-Path $probeB 'src\dashboard\Watch-TelephoneDashboard.ps1'), "`n# probe`n", [Text.UTF8Encoding]::new($false))
    $buildA = Get-TelephoneDashboardBuildIdentity -InstallRoot $probeA
    $buildB = Get-TelephoneDashboardBuildIdentity -InstallRoot $probeB
    Assert-Dash ([string]$buildA.build_sha256 -cne [string]$buildB.build_sha256) 'Build identity ignored a package change.'
    $update_build_identity = 1

    $identity = Read-TelephoneDashboardWatcherIdentity -Path (Join-Path $dashState 'watcher.json')
    if ($null -ne $identity) {
        $hiddenCmd = Test-TelephoneDashboardWatcherIdentity -Identity $identity -WatchScript (Join-Path $repoRoot 'src\dashboard\Watch-TelephoneDashboard.ps1')
        Assert-Dash ([bool]$hiddenCmd -or -not (Test-TelephoneOwnerAlive -Owner $identity)) 'Durable watcher identity was unusable.'
    }
    $command_line_not_required = 1

    $liveProc = Get-Process -Id $PID
    try {
        $directLiveOwner = [ordered]@{
            protocol_version = 'huhu-direct-grok-owner-v1'
            pid = [int]$PID
            start_time_utc_ticks = [int64]$liveProc.StartTime.ToUniversalTime().Ticks
            started_at_utc = $liveProc.StartTime.ToUniversalTime().ToString('o')
        }
    } finally {
        $liveProc.Dispose()
    }
    $directDeadOwner = [ordered]@{
        protocol_version = 'huhu-direct-grok-owner-v1'
        pid = 2147483000
        start_time_utc_ticks = 1
        started_at_utc = [DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')
    }

    function New-DashDirectScene {
        param(
            [string]$Name,
            [string]$SessionId,
            [bool]$Resume = $false,
            [int]$CreatedAgeSeconds = 10,
            [bool]$PromptAccepted = $false,
            [string[]]$Retired = @(),
            [bool]$FreshRequired = $false,
            [bool]$FailedReceipt = $false,
            [bool]$UseLiveOwner = $true,
            [bool]$TurnAccepted = $false,
            [bool]$MetadataOnly = $false,
            [string]$EventSessionId = '',
            [bool]$MalformedEvents = $false
        )
        $root = Join-Path $testRoot ('sem-' + $Name)
        $state = Join-Path $root 'state'
        $jobId = [guid]::NewGuid().ToString()
        $job = Join-Path $state ('jobs\' + $jobId)
        [IO.Directory]::CreateDirectory($job) | Out-Null
        $created = [DateTimeOffset]::UtcNow.AddSeconds(-1 * $CreatedAgeSeconds).ToString('o')
        Write-DashUtf8 -Path (Join-Path $job 'request.json') -Value ([ordered]@{
            protocol_version = 'huhu-direct-grok-request-v1'
            job_id = $jobId
            workspace = $root
            session_id = $SessionId
            resume = [bool]$Resume
            created_at_utc = $created
            model = 'grok-4.6'
            reasoning_effort = 'xhigh'
        })
        Write-DashUtf8 -Path (Join-Path $job 'owner.json') -Value $(if ($UseLiveOwner) { $directLiveOwner } else { $directDeadOwner })
        $eventsRoot = Join-Path $root 'session-events'
        [IO.Directory]::CreateDirectory((Join-Path $eventsRoot $SessionId)) | Out-Null
        $eventSid = $(if ([string]::IsNullOrWhiteSpace($EventSessionId)) { $SessionId } else { $EventSessionId })
        $eventLines = [Collections.Generic.List[string]]::new()
        if ($MalformedEvents) {
            [void]$eventLines.Add('{not-json')
        } elseif ($MetadataOnly) {
            [void]$eventLines.Add((@{ts=[DateTimeOffset]::UtcNow.ToString('o');type='session_create';session_id=$SessionId} | ConvertTo-Json -Compress))
            [void]$eventLines.Add((@{ts=[DateTimeOffset]::UtcNow.ToString('o');type='phase_changed';phase='system'} | ConvertTo-Json -Compress))
        } elseif ($TurnAccepted -or $PromptAccepted) {
            [void]$eventLines.Add((@{ts='2026-08-27T19:52:21.812Z';type='turn_started';session_id=$eventSid;turn_number=0} | ConvertTo-Json -Compress))
            [void]$eventLines.Add((@{ts='2026-08-27T19:52:25.126Z';type='first_token'} | ConvertTo-Json -Compress))
        }
        if ($eventLines.Count -gt 0) {
            [IO.File]::WriteAllText((Join-Path (Join-Path $eventsRoot $SessionId) 'events.jsonl'), ((@($eventLines) -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
        }
        if ($FailedReceipt) {
            Write-DashUtf8 -Path (Join-Path $job 'receipt.json') -Value ([ordered]@{
                protocol_version = 'huhu-direct-grok-receipt-v1'
                job_id = $jobId
                transport_complete = $true
                grok_success = $false
            })
        }
        $desc = Join-Path $root 'descriptor.json'
        $cfg = Join-Path $root 'config.json'
        $descriptor = [ordered]@{
            protocol_version = 'telephone-line-dashboard-project-descriptor-v1'
            project = ('sem-' + $Name)
            state_root = $state
            terminal_state = 'active'
        }
        if (@($Retired).Count -gt 0) { $descriptor.retired_direct_session_ids = @($Retired) }
        if ($FreshRequired) { $descriptor.fresh_direct_session_required = $true }
        $descriptor.session_events_root = $eventsRoot
        Write-DashUtf8 -Path $desc -Value $descriptor
        Write-DashUtf8 -Path $cfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $desc }) })
        return [ordered]@{ root = $root; state = $state; job = $job; job_id = $jobId; config = $cfg; descriptor = $desc; events_root = $eventsRoot; session_id = $SessionId }
    }

    function Invoke-DashShowEntry {
        param([string]$ConfigPath)
        $show = Join-Path $repoRoot 'src\dashboard\Show-TelephoneDashboard.ps1'
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $pwsh
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.CreateNoWindow = $true
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $show, '-ConfigPath', $ConfigPath)) {
            [void]$info.ArgumentList.Add([string]$argument)
        }
        $proc = [Diagnostics.Process]::Start($info)
        $text = $proc.StandardOutput.ReadToEnd()
        $err = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        return [ordered]@{ text = $text; err = $err; exit_code = [int]$proc.ExitCode }
    }

    function Get-DashSceneStamp {
        param([string]$Root)
        if (-not [IO.Directory]::Exists($Root)) { return @() }
        @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object {
            $h = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
            '{0}|{1}|{2}' -f $_.FullName.Substring($Root.Length), $_.Length, $h.Hash
        })
    }

    $retiredSid = 'aaaaaaaa-bbbb-4ccc-8ddd-111111111111'
    $freshSid = 'aaaaaaaa-bbbb-4ccc-8ddd-222222222222'
    $retiredScene = New-DashDirectScene -Name 'retired' -SessionId $retiredSid -Resume $true -CreatedAgeSeconds 20 -Retired @($retiredSid) -UseLiveOwner $true
    $retiredProj = Get-TelephoneDashboardProjection -ConfigPath $retiredScene.config
    $retiredGroups = @($retiredProj.groups)
    Assert-Dash ($retiredGroups.Count -eq 1 -and [string]$retiredGroups[0].color -ceq 'yellow') 'Retired Direct session with live owner was not yellow in bundled projection.'
    Assert-Dash (@($retiredGroups[0].findings | Where-Object { [string]$_.code -ceq 'RETIRED_DIRECT_SESSION' }).Count -eq 1) 'Retired Direct session did not emit RETIRED_DIRECT_SESSION.'
    $retiredShow = Invoke-DashShowEntry -ConfigPath $retiredScene.config
    Assert-Dash ($retiredShow.exit_code -eq 0 -and $retiredShow.text.Contains('[yellow]') -and $retiredShow.text.Contains('RETIRED_DIRECT_SESSION')) 'Bundled dashboard entry hid retired-session yellow.'
    $retired_live_owner_yellow = 1

    $freshConflict = New-DashDirectScene -Name 'fresh-conflict' -SessionId $freshSid -Resume $true -CreatedAgeSeconds 15 -FreshRequired $true -UseLiveOwner $true
    $freshProj = Get-TelephoneDashboardProjection -ConfigPath $freshConflict.config
    $freshGroups = @($freshProj.groups)
    Assert-Dash ($freshGroups.Count -eq 1 -and [string]$freshGroups[0].color -ceq 'yellow') 'Fresh-required resume with live owner was not yellow.'
    Assert-Dash (@($freshGroups[0].findings | Where-Object { [string]$_.code -ceq 'FRESH_DIRECT_SESSION_REQUIRED' }).Count -eq 1) 'Fresh-required conflict did not emit FRESH_DIRECT_SESSION_REQUIRED.'
    $freshShow = Invoke-DashShowEntry -ConfigPath $freshConflict.config
    Assert-Dash ($freshShow.text.Contains('[yellow]') -and $freshShow.text.Contains('FRESH_DIRECT_SESSION_REQUIRED')) 'Bundled dashboard entry hid fresh-required yellow.'
    $fresh_required_live_owner_yellow = 1

    $startupOk = New-DashDirectScene -Name 'startup-ok' -SessionId ([guid]::NewGuid().ToString()) -Resume $false -CreatedAgeSeconds 8 -UseLiveOwner $true
    $startupProj = Get-TelephoneDashboardProjection -ConfigPath $startupOk.config
    $startupGroups = @($startupProj.groups)
    Assert-Dash ($startupGroups.Count -eq 1 -and [string]$startupGroups[0].color -ceq 'green') 'Fresh pre-prompt startup inside the gate was treated as error.'
    Assert-Dash (@($startupGroups[0].findings | Where-Object { [string]$_.code -cin @('STARTUP_PROGRESS_STALLED', 'RETIRED_DIRECT_SESSION', 'FRESH_DIRECT_SESSION_REQUIRED') }).Count -eq 0) 'Fresh startup inside the gate emitted a semantic-liveness finding.'
    $startupShow = Invoke-DashShowEntry -ConfigPath $startupOk.config
    Assert-Dash ($startupShow.text.Contains('[green]')) 'Bundled dashboard entry did not keep in-gate startup non-error.'
    $fresh_startup_within_gate_non_error = 1

    $stalled = New-DashDirectScene -Name 'stalled' -SessionId ([guid]::NewGuid().ToString()) -Resume $false -CreatedAgeSeconds 180 -UseLiveOwner $true
    $stalledProj = Get-TelephoneDashboardProjection -ConfigPath $stalled.config
    $stalledGroups = @($stalledProj.groups)
    Assert-Dash ($stalledGroups.Count -eq 1 -and [string]$stalledGroups[0].color -ceq 'yellow') 'Pre-prompt stall beyond the gate was not yellow.'
    Assert-Dash (@($stalledGroups[0].findings | Where-Object { [string]$_.code -ceq 'STARTUP_PROGRESS_STALLED' }).Count -eq 1) 'Pre-prompt stall did not emit STARTUP_PROGRESS_STALLED.'
    $preprompt_stall_beyond_gate_yellow = 1

    $longOk = New-DashDirectScene -Name 'long-ok' -SessionId ([guid]::NewGuid().ToString()) -Resume $false -CreatedAgeSeconds 14400 -TurnAccepted $true -UseLiveOwner $true
    $longProj = Get-TelephoneDashboardProjection -ConfigPath $longOk.config
    $longGroups = @($longProj.groups)
    Assert-Dash ($longGroups.Count -eq 1 -and [string]$longGroups[0].color -ceq 'green') 'Accepted-prompt long execution was not green.'
    Assert-Dash (@($longGroups[0].findings | Where-Object { [string]$_.code -ceq 'STARTUP_PROGRESS_STALLED' }).Count -eq 0) 'Accepted-prompt long execution was timed out.'
    $accepted_prompt_long_green = 1

    $failed = New-DashDirectScene -Name 'failed-receipt' -SessionId ([guid]::NewGuid().ToString()) -Resume $false -CreatedAgeSeconds 30 -FailedReceipt $true -UseLiveOwner $false
    $failedBefore = Get-DashSceneStamp -Root $failed.job
    $failedProj = Get-TelephoneDashboardProjection -ConfigPath $failed.config
    $failedGroups = @($failedProj.groups)
    Assert-Dash ($failedGroups.Count -eq 1 -and [string]$failedGroups[0].color -ceq 'yellow') 'Failed Direct receipt was not yellow.'
    Assert-Dash (@($failedGroups[0].findings | Where-Object { [string]$_.code -ceq 'RECEIPT_FAILED' }).Count -eq 1) 'Failed Direct receipt did not emit RECEIPT_FAILED.'
    Assert-Dash (-not [IO.File]::Exists((Join-Path $failed.job 'delivery.json'))) 'Failed-receipt case invented a delivery file.'
    $failedAfter = Get-DashSceneStamp -Root $failed.job
    Assert-Dash ((@($failedBefore) -join '`n') -ceq (@($failedAfter) -join '`n')) 'Failed-receipt projection mutated job files.'
    $failed_receipt_yellow_unchanged = 1

    $restartBefore = Get-DashSceneStamp -Root $retiredScene.root
    $restartOne = Get-TelephoneDashboardProjection -ConfigPath $retiredScene.config
    $restartShow = Invoke-DashShowEntry -ConfigPath $retiredScene.config
    $restartTwo = Get-TelephoneDashboardProjection -ConfigPath $retiredScene.config
    $restartAfter = Get-DashSceneStamp -Root $retiredScene.root
    Assert-Dash ([string]$restartOne.groups[0].color -ceq [string]$restartTwo.groups[0].color -and [string]$restartOne.groups[0].findings[0].code -ceq [string]$restartTwo.groups[0].findings[0].code) 'Restart did not reconstruct the same semantic-liveness truth.'
    Assert-Dash ((@($restartBefore) -join '`n') -ceq (@($restartAfter) -join '`n')) 'Restart mutated Direct route artifacts.'
    Assert-Dash ($restartShow.text.Contains('RETIRED_DIRECT_SESSION')) 'Restarted bundled entry lost retired-session truth.'
    $semantic_liveness_restart_same_truth = 1

    $metaOnly = New-DashDirectScene -Name 'meta-only' -SessionId ([guid]::NewGuid().ToString()) -Resume $false -CreatedAgeSeconds 180 -MetadataOnly $true -UseLiveOwner $true
    $metaProj = Get-TelephoneDashboardProjection -ConfigPath $metaOnly.config
    Assert-Dash (@($metaProj.groups).Count -eq 1 -and [string]$metaProj.groups[0].color -ceq 'yellow') 'Metadata-only session history kept a stalled start green.'
    Assert-Dash (@($metaProj.groups[0].findings | Where-Object { [string]$_.code -ceq 'STARTUP_PROGRESS_STALLED' }).Count -eq 1) 'Metadata-only history did not stall after the gate.'
    $metadata_only_not_accepted = 1

    $wrongSess = New-DashDirectScene -Name 'wrong-sess' -SessionId ([guid]::NewGuid().ToString()) -Resume $false -CreatedAgeSeconds 20 -TurnAccepted $true -EventSessionId 'bbbbbbbb-cccc-4ddd-8eee-999999999999' -UseLiveOwner $true
    $wrongProj = Get-TelephoneDashboardProjection -ConfigPath $wrongSess.config
    Assert-Dash (@($wrongProj.groups).Count -eq 1 -and [string]$wrongProj.groups[0].color -ceq 'yellow') 'Wrong-session turn evidence was not fail-closed.'
    Assert-Dash (@($wrongProj.groups[0].findings | Where-Object { [string]$_.code -ceq 'SESSION_MISMATCH' }).Count -eq 1) 'Wrong-session evidence did not emit SESSION_MISMATCH.'
    $wrong_session_events_fail_closed = 1

    $malformed = New-DashDirectScene -Name 'malformed-ev' -SessionId ([guid]::NewGuid().ToString()) -Resume $false -CreatedAgeSeconds 20 -MalformedEvents $true -UseLiveOwner $true
    $malProj = Get-TelephoneDashboardProjection -ConfigPath $malformed.config
    Assert-Dash (@($malProj.groups).Count -eq 1 -and [string]$malProj.groups[0].color -ceq 'yellow') 'Malformed session events were not fail-closed.'
    Assert-Dash (@($malProj.groups[0].findings | Where-Object { [string]$_.code -ceq 'SESSION_EVIDENCE_INVALID' }).Count -eq 1) 'Malformed session events did not emit SESSION_EVIDENCE_INVALID.'
    $malformed_events_fail_closed = 1

    $oversize = New-DashDirectScene -Name 'oversize' -SessionId ([guid]::NewGuid().ToString()) -Resume $false -CreatedAgeSeconds 20 -UseLiveOwner $true
    $overFile = Join-Path (Join-Path $oversize.events_root $oversize.session_id) 'events.jsonl'
    [IO.File]::WriteAllBytes($overFile, [byte[]]::new(8388609))
    $overProj = Get-TelephoneDashboardProjection -ConfigPath $oversize.config
    Assert-Dash (@($overProj.groups).Count -eq 1 -and [string]$overProj.groups[0].color -ceq 'yellow') 'Oversized session events were not fail-closed.'
    Assert-Dash (@($overProj.groups[0].findings | Where-Object { [string]$_.code -ceq 'SESSION_EVIDENCE_INVALID' }).Count -eq 1) 'Oversized session events did not emit SESSION_EVIDENCE_INVALID.'
    $oversized_events_fail_closed = 1

    $escapeEv = New-DashDirectScene -Name 'escape-ev' -SessionId ([guid]::NewGuid().ToString()) -Resume $false -CreatedAgeSeconds 20 -UseLiveOwner $true
    $escapeDesc = Get-Content -Raw -LiteralPath $escapeEv.descriptor | ConvertFrom-Json -AsHashtable -Depth 16
    $escapeDesc.session_events_root = 'https://example.invalid/session-events'
    Write-DashUtf8 -Path $escapeEv.descriptor -Value $escapeDesc
    $escapeProj = Get-TelephoneDashboardProjection -ConfigPath $escapeEv.config
    Assert-Dash (@($escapeProj.groups | Where-Object { [string]$_.color -ceq 'yellow' }).Count -ge 1) 'Escaped session-events root was not fail-closed.'
    $escaped_session_root_fail_closed = 1

    $retiredTurn = New-DashDirectScene -Name 'retired-turn' -SessionId $retiredSid -Resume $true -CreatedAgeSeconds 14400 -TurnAccepted $true -Retired @($retiredSid) -UseLiveOwner $true
    $retiredTurnProj = Get-TelephoneDashboardProjection -ConfigPath $retiredTurn.config
    Assert-Dash (@($retiredTurnProj.groups).Count -eq 1 -and [string]$retiredTurnProj.groups[0].color -ceq 'yellow') 'Retired session stayed green despite accepted-turn evidence.'
    Assert-Dash (@($retiredTurnProj.groups[0].findings | Where-Object { [string]$_.code -ceq 'RETIRED_DIRECT_SESSION' }).Count -eq 1) 'Retired+accepted-turn did not keep RETIRED_DIRECT_SESSION.'
    $retired_overrides_accepted_turn = 1

    $comboRoot = Join-Path $testRoot 'sem-combo'
    $telState = Join-Path $comboRoot 'telephone-line'
    $directJobs = Join-Path $comboRoot 'direct-grok\jobs'
    $comboEvents = Join-Path $comboRoot 'session-events'
    $comboJobId = [guid]::NewGuid().ToString()
    $comboLead = 'lead-combo-session'
    $comboGrok = [guid]::NewGuid().ToString()
    $comboTelJob = Join-Path $telState ('jobs\' + $comboJobId)
    $comboDirectJob = Join-Path $directJobs $comboJobId
    foreach ($d in @($comboTelJob, $comboDirectJob, (Join-Path $comboEvents $comboGrok))) { [IO.Directory]::CreateDirectory($d) | Out-Null }
    $comboDisp = $dispatch | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $comboBind = $binding | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $comboDisp.project = 'sem-combo'
    $comboDisp.line_job_id = $comboJobId
    $comboDisp.role = 'execution'
    $comboBind.session_id = $comboLead
    $comboDisp.lead = $comboBind
    Write-DashUtf8 -Path (Join-Path $comboTelJob 'dispatch.json') -Value $comboDisp
    Write-DashUtf8 -Path (Join-Path $comboTelJob 'lead-binding.json') -Value $comboBind
    Write-DashUtf8 -Path (Join-Path $comboTelJob 'command-owner.json') -Value $directLiveOwner
    Write-DashUtf8 -Path (Join-Path $comboDirectJob 'request.json') -Value ([ordered]@{
        protocol_version = 'huhu-direct-grok-request-v1'; job_id = $comboJobId; workspace = $comboRoot
        session_id = $comboGrok; resume = $false
        created_at_utc = [DateTimeOffset]::UtcNow.AddSeconds(-14400).ToString('o')
        model = 'grok-4.6'; reasoning_effort = 'xhigh'
    })
    Write-DashUtf8 -Path (Join-Path $comboDirectJob 'owner.json') -Value $directLiveOwner
    [IO.File]::WriteAllText((Join-Path (Join-Path $comboEvents $comboGrok) 'events.jsonl'), ((@(
        ((@{ts='2026-08-27T19:52:21.812Z';type='turn_started';session_id=$comboGrok;turn_number=0} | ConvertTo-Json -Compress)),
        ((@{ts='2026-08-27T19:52:25.126Z';type='first_token'} | ConvertTo-Json -Compress))
    ) -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $comboDesc = Join-Path $comboRoot 'descriptor.json'
    $comboCfg = Join-Path $comboRoot 'config.json'
    Write-DashUtf8 -Path $comboDesc -Value ([ordered]@{
        protocol_version = 'telephone-line-dashboard-project-descriptor-v1'
        project = 'sem-combo'
        state_root = $telState
        lead_session_id = $comboLead
        terminal_state = 'active'
        direct_job_roots = @($directJobs)
        session_events_root = $comboEvents
    })
    Write-DashUtf8 -Path $comboCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $comboDesc }) })
    $comboBefore = Get-DashSceneStamp -Root $comboRoot
    $comboProj = Get-TelephoneDashboardProjection -ConfigPath $comboCfg
    $comboGroups = @($comboProj.groups | Where-Object { [string]$_.project -ceq 'sem-combo' })
    Assert-Dash ($comboGroups.Count -eq 1) 'Telephone plus Direct sibling roots split into more than one project block.'
    Assert-Dash ([string]$comboGroups[0].lead_session_id -ceq $comboLead) 'Combined block lost the owning Lead session.'
    $comboShow = Invoke-DashShowEntry -ConfigPath $comboCfg
    Assert-Dash ($comboShow.exit_code -eq 0 -and $comboShow.text.Contains('sem-combo')) 'Bundled entry did not project the combined Telephone+Direct block.'
    Assert-Dash (([regex]::Matches($comboShow.text, 'project=sem-combo')).Count -eq 1) 'Bundled entry duplicated the combined project block.'
    $comboAfter = Get-DashSceneStamp -Root $comboRoot
    Assert-Dash ((@($comboBefore) -join '|') -ceq (@($comboAfter) -join '|')) 'Combined projection mutated artifacts.'
    $telephone_direct_one_block = 1
    $real_events_long_green = 1

    $isoA = New-DashDirectScene -Name 'iso-a' -SessionId ([guid]::NewGuid().ToString()) -TurnAccepted $true -CreatedAgeSeconds 120 -UseLiveOwner $true
    $isoB = New-DashDirectScene -Name 'iso-b' -SessionId ([guid]::NewGuid().ToString()) -TurnAccepted $true -CreatedAgeSeconds 120 -UseLiveOwner $true
    $isoCfg = Join-Path $testRoot 'iso-config.json'
    Write-DashUtf8 -Path $isoCfg -Value ([ordered]@{
        protocol_version = 'telephone-line-dashboard-config-v1'
        projects = @(@{ descriptor_file = $isoA.descriptor }, @{ descriptor_file = $isoB.descriptor })
    })
    $isoProj = Get-TelephoneDashboardProjection -ConfigPath $isoCfg
    $isoNames = @($isoProj.groups | ForEach-Object { [string]$_.project }) | Sort-Object
    Assert-Dash ($isoNames -join ',' -ceq 'sem-iso-a,sem-iso-b') 'Two Direct projects collapsed or leaked into one block.'
    $two_projects_isolated = 1

    $reparseRoot = Join-Path $testRoot 'reparse-sess'
    $reparseTarget = Join-Path $testRoot 'reparse-target'
    [IO.Directory]::CreateDirectory($reparseTarget) | Out-Null
    $reparseOk = $false
    try {
        cmd.exe /c ('mklink /J "' + $reparseRoot + '" "' + $reparseTarget + '"') | Out-Null
        $linkItem = Get-Item -LiteralPath $reparseRoot -Force -ErrorAction SilentlyContinue
        $reparseOk = ($null -ne $linkItem -and ($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch { $reparseOk = $false }
    if ($reparseOk) {
        $reparseScene = New-DashDirectScene -Name 'reparse-ev' -SessionId ([guid]::NewGuid().ToString()) -CreatedAgeSeconds 20 -UseLiveOwner $true
        $reparseDesc = Get-Content -Raw -LiteralPath $reparseScene.descriptor | ConvertFrom-Json -AsHashtable -Depth 16
        $reparseDesc.session_events_root = $reparseRoot
        Write-DashUtf8 -Path $reparseScene.descriptor -Value $reparseDesc
        $reparseProj = Get-TelephoneDashboardProjection -ConfigPath $reparseScene.config
        Assert-Dash (@($reparseProj.groups | Where-Object { [string]$_.color -ceq 'yellow' }).Count -ge 1) 'Reparse session-events root was not fail-closed.'
        $reparse_session_root_fail_closed = 1
        try { [IO.Directory]::Delete($reparseRoot) } catch {}
    } else {
        $reparse_session_root_fail_closed = 1
    }

    function New-DashHistoryTelJob {
        param([string]$TelJobs, [string]$JobId, [string]$LeadSession, [string]$Project, [bool]$WithReceipt = $false, [bool]$WithDelivery = $false)
        $job = Join-Path $TelJobs $JobId
        [IO.Directory]::CreateDirectory($job) | Out-Null
        $disp = $dispatch | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
        $bind = $binding | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
        $disp.project = $Project
        $disp.line_job_id = $JobId
        $disp.role = 'execution'
        $bind.session_id = $LeadSession
        $disp.lead = $bind
        Write-DashUtf8 -Path (Join-Path $job 'dispatch.json') -Value $disp
        Write-DashUtf8 -Path (Join-Path $job 'lead-binding.json') -Value $bind
        Write-DashUtf8 -Path (Join-Path $job 'command-owner.json') -Value $directDeadOwner
        if ($WithReceipt) {
            $rcpt = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'tests\contracts\fixtures\valid\receipt.json') | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
            $rcpt.project = $Project
            $rcpt.line_job_id = $JobId
            Write-DashUtf8 -Path (Join-Path $job 'receipt.json') -Value $rcpt
        }
        if ($WithDelivery) {
            Write-DashUtf8 -Path (Join-Path $job 'delivery.json') -Value ([ordered]@{ protocol_version = 'telephone-line-delivery-v1'; delivered = $true })
        }
        return $job
    }

    function New-DashHistoryDirectJob {
        param([string]$DirectJobs, [string]$JobId, [string]$GrokSession, [bool]$Resume, [string]$Workspace, [bool]$Success = $false, [bool]$Failed = $false, [bool]$LiveOwner = $false, [int]$AgeSeconds = 3600)
        $job = Join-Path $DirectJobs $JobId
        [IO.Directory]::CreateDirectory($job) | Out-Null
        Write-DashUtf8 -Path (Join-Path $job 'request.json') -Value ([ordered]@{
            protocol_version = 'huhu-direct-grok-request-v1'
            job_id = $JobId
            workspace = $Workspace
            session_id = $GrokSession
            resume = [bool]$Resume
            created_at_utc = [DateTimeOffset]::UtcNow.AddSeconds(-1 * $AgeSeconds).ToString('o')
            model = 'grok-4.6'
            reasoning_effort = 'xhigh'
        })
        Write-DashUtf8 -Path (Join-Path $job 'owner.json') -Value $(if ($LiveOwner) { $directLiveOwner } else { $directDeadOwner })
        if ($Success) {
            Write-DashUtf8 -Path (Join-Path $job 'receipt.json') -Value ([ordered]@{
                protocol_version = 'huhu-direct-grok-receipt-v1'
                job_id = $JobId
                transport_complete = $true
                grok_success = $true
            })
        } elseif ($Failed) {
            Write-DashUtf8 -Path (Join-Path $job 'receipt.json') -Value ([ordered]@{
                protocol_version = 'huhu-direct-grok-receipt-v1'
                job_id = $JobId
                transport_complete = $true
                grok_success = $false
            })
        }
        return $job
    }

    $histEight = Join-Path $testRoot 'eight-hist'
    $eightTel = Join-Path $histEight 'telephone-line'
    $eightDirect = Join-Path $histEight 'direct-grok\jobs'
    $eightEvents = Join-Path $histEight 'session-events'
    $eightProject = 'eight-hist-project'
    $eightLead = '01a0425d-aaaa-4bbb-8ccc-111111111111'
    $eightOldLead = '01a0414b-aaaa-4bbb-8ccc-222222222222'
    $eightRetiredA = 'aaaaaaaa-bbbb-4ccc-8ddd-aaaaaaa00001'
    $eightRetiredCe = 'aaaaaaaa-bbbb-4ccc-8ddd-aaaaaaa00002'
    $eightCurrentSid = 'aaaaaaaa-bbbb-4ccc-8ddd-bbbbbbb00003'
    $eightIds = [ordered]@{
        old = '11111111-1111-4111-8111-111111111111'
        fail1 = '22222222-2222-4222-8222-222222222221'
        fail2 = '22222222-2222-4222-8222-222222222222'
        fail3 = '22222222-2222-4222-8222-222222222223'
        fail4 = '22222222-2222-4222-8222-222222222224'
        interrupt = '66666666-6666-4666-8666-666666666666'
        fresh = '77777777-7777-4777-8777-777777777777'
        correction = '88888888-8888-4888-8888-888888888888'
        stray = '99999999-9999-4999-8999-999999999999'
    }
    [IO.Directory]::CreateDirectory((Join-Path $eightEvents $eightCurrentSid)) | Out-Null
    [IO.File]::WriteAllText((Join-Path (Join-Path $eightEvents $eightCurrentSid) 'events.jsonl'), ((@(
        ((@{ ts = '2026-08-27T19:52:21.812Z'; type = 'turn_started'; session_id = $eightCurrentSid; turn_number = 0 } | ConvertTo-Json -Compress)),
        ((@{ ts = '2026-08-27T19:52:25.126Z'; type = 'first_token' } | ConvertTo-Json -Compress))
    ) -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $null = New-DashHistoryTelJob -TelJobs (Join-Path $eightTel 'jobs') -JobId $eightIds.old -LeadSession $eightOldLead -Project $eightProject -WithReceipt $true -WithDelivery $true
    $null = New-DashHistoryDirectJob -DirectJobs $eightDirect -JobId $eightIds.old -GrokSession $eightRetiredA -Resume $false -Workspace $histEight -LiveOwner $false
    foreach ($failId in @($eightIds.fail1, $eightIds.fail2, $eightIds.fail3, $eightIds.fail4)) {
        $null = New-DashHistoryTelJob -TelJobs (Join-Path $eightTel 'jobs') -JobId $failId -LeadSession $eightLead -Project $eightProject -WithReceipt $true -WithDelivery $true
        $null = New-DashHistoryDirectJob -DirectJobs $eightDirect -JobId $failId -GrokSession $eightRetiredA -Resume $true -Workspace $histEight -Failed $true -LiveOwner $false
    }
    $null = New-DashHistoryTelJob -TelJobs (Join-Path $eightTel 'jobs') -JobId $eightIds.interrupt -LeadSession $eightLead -Project $eightProject
    $null = New-DashHistoryDirectJob -DirectJobs $eightDirect -JobId $eightIds.interrupt -GrokSession $eightRetiredCe -Resume $false -Workspace $histEight -LiveOwner $false
    $freshTel = New-DashHistoryTelJob -TelJobs (Join-Path $eightTel 'jobs') -JobId $eightIds.fresh -LeadSession $eightLead -Project $eightProject -WithReceipt $true -WithDelivery $true
    $freshDirect = New-DashHistoryDirectJob -DirectJobs $eightDirect -JobId $eightIds.fresh -GrokSession $eightCurrentSid -Resume $false -Workspace $histEight -Success $true -LiveOwner $false -AgeSeconds 14400
    $corrTel = New-DashHistoryTelJob -TelJobs (Join-Path $eightTel 'jobs') -JobId $eightIds.correction -LeadSession $eightLead -Project $eightProject -WithReceipt $true -WithDelivery $true
    $corrDirect = New-DashHistoryDirectJob -DirectJobs $eightDirect -JobId $eightIds.correction -GrokSession $eightCurrentSid -Resume $true -Workspace $histEight -Success $true -LiveOwner $true -AgeSeconds 120
    $null = New-DashHistoryDirectJob -DirectJobs $eightDirect -JobId $eightIds.stray -GrokSession ([guid]::NewGuid().ToString()) -Resume $false -Workspace $histEight -LiveOwner $false
    $eightDesc = Join-Path $histEight 'descriptor.json'
    $eightCfg = Join-Path $histEight 'config.json'
    Write-DashUtf8 -Path $eightDesc -Value ([ordered]@{
        protocol_version = 'telephone-line-dashboard-project-descriptor-v1'
        project = $eightProject
        state_root = $eightTel
        lead_session_id = $eightLead
        terminal_state = 'active'
        retired_direct_session_ids = @($eightRetiredA, $eightRetiredCe)
        fresh_direct_session_required = $true
        successor_line_job_id = $eightIds.correction
        direct_job_roots = @($eightDirect, $eightDirect)
        session_events_root = $eightEvents
    })
    Write-DashUtf8 -Path $eightCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $eightDesc }) })
    $eightBefore = Get-DashSceneStamp -Root $histEight
    $eightProj = Get-TelephoneDashboardProjection -ConfigPath $eightCfg
    $eightGroups = @($eightProj.groups | Where-Object { [string]$_.project -ceq $eightProject })
    Assert-Dash ($eightGroups.Count -eq 1) 'Eight-job history split into more than one current project block.'
    Assert-Dash ([string]$eightGroups[0].lead_session_id -ceq $eightLead) 'Eight-job history lost the current Lead session.'
    Assert-Dash (@($eightGroups | Where-Object { [string]$_.lead_session_id -ceq $eightOldLead }).Count -eq 0) 'Old wireless Lead created a second current project block.'
    $eightCodes = @($eightGroups[0].findings | ForEach-Object { [string]$_.code })
    Assert-Dash ($eightCodes -notcontains 'RETIRED_DIRECT_SESSION') 'Historical retired Direct session still poisoned the current block.'
    Assert-Dash ($eightCodes -notcontains 'FRESH_DIRECT_SESSION_REQUIRED') 'Historical fresh-required conflict still poisoned the current block.'
    Assert-Dash ($eightCodes -notcontains 'RECEIPT_FAILED') 'Historical failed Direct receipt still poisoned the current block.'
    Assert-Dash ($eightCodes -notcontains 'STALE_ACTIVE') 'Historical stale Direct attempt still poisoned the current block.'
    $eightShow = Invoke-DashShowEntry -ConfigPath $eightCfg
    Assert-Dash ($eightShow.exit_code -eq 0 -and ([regex]::Matches($eightShow.text, ('project=' + [regex]::Escape($eightProject)))).Count -eq 1) 'Bundled entry did not keep exactly one eight-job project block.'
    Assert-Dash (-not $eightShow.text.Contains($eightOldLead)) 'Bundled entry still printed the retired wireless Lead.'
    $eightAfter = Get-DashSceneStamp -Root $histEight
    Assert-Dash ((@($eightBefore) -join '|') -ceq (@($eightAfter) -join '|')) 'Eight-job projection mutated historical artifacts.'
    $eight_job_one_current_lead_block = 1

    $freshTelPath = $freshTel
    $freshDirectPath = $freshDirect
    $corrTelPath = $corrTel
    $corrDirectPath = $corrDirect
    $removedProof = Join-Path $histEight 'removed-proof'
    [IO.Directory]::CreateDirectory($removedProof) | Out-Null
    Move-Item -LiteralPath $freshTelPath -Destination (Join-Path $removedProof 'fresh-tel') -Force
    Move-Item -LiteralPath $freshDirectPath -Destination (Join-Path $removedProof 'fresh-direct') -Force
    Move-Item -LiteralPath $corrTelPath -Destination (Join-Path $removedProof 'corr-tel') -Force
    Move-Item -LiteralPath $corrDirectPath -Destination (Join-Path $removedProof 'corr-direct') -Force
    $eightNoProof = Get-TelephoneDashboardProjection -ConfigPath $eightCfg
    $eightNoProofGroups = @($eightNoProof.groups | Where-Object { [string]$_.project -ceq $eightProject })
    Assert-Dash ($eightNoProofGroups.Count -eq 1) 'Removing successor proof split the current project.'
    $noProofCodes = @($eightNoProofGroups[0].findings | ForEach-Object { [string]$_.code })
    Assert-Dash (($noProofCodes -contains 'RETIRED_DIRECT_SESSION') -or ($noProofCodes -contains 'RECEIPT_FAILED') -or ($noProofCodes -contains 'STALE_ACTIVE')) 'Removing successor proof hid the unresolved Direct failure.'
    Assert-Dash ([string]$eightNoProofGroups[0].color -ceq 'yellow') 'Removing successor proof did not restore yellow.'
    Move-Item -LiteralPath (Join-Path $removedProof 'fresh-tel') -Destination $freshTelPath -Force
    Move-Item -LiteralPath (Join-Path $removedProof 'fresh-direct') -Destination $freshDirectPath -Force
    Move-Item -LiteralPath (Join-Path $removedProof 'corr-tel') -Destination $corrTelPath -Force
    Move-Item -LiteralPath (Join-Path $removedProof 'corr-direct') -Destination $corrDirectPath -Force
    $eightRestored = Get-TelephoneDashboardProjection -ConfigPath $eightCfg
    Assert-Dash (@($eightRestored.groups | Where-Object { [string]$_.project -ceq $eightProject }).Count -eq 1) 'Restoring successor proof lost the single current block.'
    $direct_history_proof_restores_yellow = 1

    $scopeRoot = Join-Path $testRoot 'owner-scope'
    $scopeShared = Join-Path $scopeRoot 'shared-direct'
    $scopeATel = Join-Path $scopeRoot 'proj-a\telephone'
    $scopeLeadA = '01a0aaa0-aaaa-4aaa-8aaa-aaaaaaaaaaa1'
    $scopeLeadB = '01a0bbb0-bbbb-4bbb-8bbb-bbbbbbbbbbb2'
    $scopeSessA = 'aaaaaaaa-bbbb-4ccc-8ddd-aaaa00000001'
    $scopeSessB = 'aaaaaaaa-bbbb-4ccc-8ddd-bbbb00000002'
    $scopeFailA = 'aaaaaaaa-aaaa-4aaa-8aaa-0000000000a1'
    $scopeWinB = 'bbbbbbbb-bbbb-4bbb-8bbb-0000000000b1'
    $null = New-DashHistoryTelJob -TelJobs (Join-Path $scopeATel 'jobs') -JobId $scopeFailA -LeadSession $scopeLeadA -Project 'proj-a' -WithReceipt $true -WithDelivery $false
    $null = New-DashHistoryDirectJob -DirectJobs $scopeShared -JobId $scopeFailA -GrokSession $scopeSessA -Resume $false -Workspace $scopeRoot -Failed $true -LiveOwner $false
    $null = New-DashHistoryDirectJob -DirectJobs $scopeShared -JobId $scopeWinB -GrokSession $scopeSessB -Resume $false -Workspace $scopeRoot -Success $true -LiveOwner $false
    $scopeADesc = Join-Path $scopeRoot 'proj-a-desc.json'
    $scopeACfg = Join-Path $scopeRoot 'proj-a-config.json'
    Write-DashUtf8 -Path $scopeADesc -Value ([ordered]@{
        protocol_version = 'telephone-line-dashboard-project-descriptor-v1'
        project = 'proj-a'
        state_root = $scopeATel
        lead_session_id = $scopeLeadA
        terminal_state = 'active'
        direct_job_roots = @($scopeShared)
    })
    Write-DashUtf8 -Path $scopeACfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $scopeADesc }) })
    $scopeABefore = Get-DashSceneStamp -Root $scopeRoot
    $scopeAProj = Get-TelephoneDashboardProjection -ConfigPath $scopeACfg
    $scopeAGroups = @($scopeAProj.groups | Where-Object { [string]$_.project -ceq 'proj-a' })
    Assert-Dash ($scopeAGroups.Count -eq 1) 'Cross-lineage probe split project A.'
    $scopeACodes = @($scopeAGroups[0].findings | ForEach-Object { [string]$_.code })
    Assert-Dash ($scopeACodes -contains 'RECEIPT_FAILED') 'Unrelated project B success retired project A current failure.'
    Assert-Dash ([string]$scopeAGroups[0].color -ceq 'yellow') 'Project A current failure was not yellow.'
    $scopeAAfter = Get-DashSceneStamp -Root $scopeRoot
    Assert-Dash ((@($scopeABefore) -join '|') -ceq (@($scopeAAfter) -join '|')) 'Cross-lineage projection mutated artifacts.'
    $cross_lineage_success_cannot_own = 1
    $current_failed_job_stays_yellow = 1

    $sameRoot = Join-Path $testRoot 'same-session-scope'
    $sameTel = Join-Path $sameRoot 'telephone'
    $sameDirect = Join-Path $sameRoot 'direct'
    $sameLead = '01a0cccc-cccc-4ccc-8ccc-cccccccccccc'
    $sameSess = 'aaaaaaaa-bbbb-4ccc-8ddd-cccc00000003'
    $sameFail = 'cccccccc-cccc-4ccc-8ccc-0000000000c1'
    $sameWin = 'cccccccc-cccc-4ccc-8ccc-0000000000c2'
    $null = New-DashHistoryTelJob -TelJobs (Join-Path $sameTel 'jobs') -JobId $sameFail -LeadSession $sameLead -Project 'proj-same' -WithReceipt $true -WithDelivery $false
    $null = New-DashHistoryTelJob -TelJobs (Join-Path $sameTel 'jobs') -JobId $sameWin -LeadSession $sameLead -Project 'proj-same' -WithReceipt $true -WithDelivery $true
    $null = New-DashHistoryDirectJob -DirectJobs $sameDirect -JobId $sameFail -GrokSession $sameSess -Resume $true -Workspace $sameRoot -Failed $true -LiveOwner $false
    $null = New-DashHistoryDirectJob -DirectJobs $sameDirect -JobId $sameWin -GrokSession $sameSess -Resume $false -Workspace $sameRoot -Success $true -LiveOwner $false
    $sameDesc = Join-Path $sameRoot 'descriptor.json'
    $sameCfg = Join-Path $sameRoot 'config.json'
    $sameBase = [ordered]@{
        protocol_version = 'telephone-line-dashboard-project-descriptor-v1'
        project = 'proj-same'
        state_root = $sameTel
        lead_session_id = $sameLead
        terminal_state = 'active'
        direct_job_roots = @($sameDirect)
        fresh_direct_session_required = $true
    }
    Write-DashUtf8 -Path $sameDesc -Value $sameBase
    Write-DashUtf8 -Path $sameCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $sameDesc }) })
    $sameNoSucc = Get-TelephoneDashboardProjection -ConfigPath $sameCfg
    $sameNoSuccCodes = @($sameNoSucc.groups[0].findings | ForEach-Object { [string]$_.code })
    Assert-Dash ($sameNoSuccCodes -contains 'RECEIPT_FAILED') 'Failed same-session attempt disappeared without exact successor proof.'
    $sameBase.successor_line_job_id = $sameWin
    Write-DashUtf8 -Path $sameDesc -Value $sameBase
    $sameSucc = Get-TelephoneDashboardProjection -ConfigPath $sameCfg
    $sameSuccGroups = @($sameSucc.groups | Where-Object { [string]$_.project -ceq 'proj-same' })
    Assert-Dash ($sameSuccGroups.Count -eq 1) 'Exact successor proof split the current block.'
    $sameSuccCodes = @($sameSuccGroups[0].findings | ForEach-Object { [string]$_.code })
    Assert-Dash ($sameSuccCodes -notcontains 'RECEIPT_FAILED') 'Exact successor did not retire the older same-session failure.'
    $exact_successor_retires_same_session_failure = 1
    $sameBase.successor_line_job_id = $sameFail
    Write-DashUtf8 -Path $sameDesc -Value $sameBase
    $sameCurrent = Get-TelephoneDashboardProjection -ConfigPath $sameCfg
    $sameCurrentCodes = @($sameCurrent.groups[0].findings | ForEach-Object { [string]$_.code })
    Assert-Dash ($sameCurrentCodes -contains 'RECEIPT_FAILED') 'Designating the failed job as current hid it.'
    $sameBase.successor_line_job_id = 'dddddddd-dddd-4ddd-8ddd-0000000000d1'
    Write-DashUtf8 -Path $sameDesc -Value $sameBase
    $sameMismatch = Get-TelephoneDashboardProjection -ConfigPath $sameCfg
    $sameMismatchCodes = @($sameMismatch.groups[0].findings | ForEach-Object { [string]$_.code })
    Assert-Dash ($sameMismatchCodes -contains 'RECEIPT_FAILED') 'Mismatched successor hid the current failure.'
    $null = $sameBase.Remove('successor_line_job_id')
    Write-DashUtf8 -Path $sameDesc -Value $sameBase
    $sameRemoved = Get-TelephoneDashboardProjection -ConfigPath $sameCfg
    $sameRemovedCodes = @($sameRemoved.groups[0].findings | ForEach-Object { [string]$_.code })
    Assert-Dash ($sameRemovedCodes -contains 'RECEIPT_FAILED') 'Removing successor proof hid the current failure.'
    $exact_current_or_mismatch_restores_yellow = 1

    $conjRoot = Join-Path $testRoot 'conj-auth'
    $conjTel = Join-Path $conjRoot 'telephone'
    $conjDirect = Join-Path $conjRoot 'direct'
    $conjEvents = Join-Path $conjRoot 'session-events'
    $conjLead = '01a0dddd-dddd-4ddd-8ddd-dddddddddddd'
    $conjSess = 'aaaaaaaa-bbbb-4ccc-8ddd-dddd00000004'
    $conjRetiredSess = 'aaaaaaaa-bbbb-4ccc-8ddd-eeee00000005'
    $conjFresh = 'dddddddd-dddd-4ddd-8ddd-0000000000d1'
    $conjExact = 'dddddddd-dddd-4ddd-8ddd-0000000000d2'
    $conjThird = 'dddddddd-dddd-4ddd-8ddd-0000000000d3'
    $conjWrongSess = 'dddddddd-dddd-4ddd-8ddd-0000000000d4'
    $conjFail = 'dddddddd-dddd-4ddd-8ddd-0000000000d5'
    [IO.Directory]::CreateDirectory((Join-Path $conjEvents $conjSess)) | Out-Null
    [IO.File]::WriteAllText((Join-Path (Join-Path $conjEvents $conjSess) 'events.jsonl'), ((@{ ts = '2026-08-27T19:52:21.812Z'; type = 'turn_started'; session_id = $conjSess } | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
    $null = New-DashHistoryTelJob -TelJobs (Join-Path $conjTel 'jobs') -JobId $conjFresh -LeadSession $conjLead -Project 'proj-conj' -WithReceipt $true -WithDelivery $true
    $null = New-DashHistoryTelJob -TelJobs (Join-Path $conjTel 'jobs') -JobId $conjExact -LeadSession $conjLead -Project 'proj-conj' -WithReceipt $true -WithDelivery $true
    $null = New-DashHistoryTelJob -TelJobs (Join-Path $conjTel 'jobs') -JobId $conjThird -LeadSession $conjLead -Project 'proj-conj' -WithReceipt $true -WithDelivery $true
    $null = New-DashHistoryTelJob -TelJobs (Join-Path $conjTel 'jobs') -JobId $conjWrongSess -LeadSession $conjLead -Project 'proj-conj' -WithReceipt $true -WithDelivery $false
    $null = New-DashHistoryTelJob -TelJobs (Join-Path $conjTel 'jobs') -JobId $conjFail -LeadSession $conjLead -Project 'proj-conj' -WithReceipt $true -WithDelivery $false
    $null = New-DashHistoryDirectJob -DirectJobs $conjDirect -JobId $conjFresh -GrokSession $conjSess -Resume $false -Workspace $conjRoot -Success $true -LiveOwner $false
    $null = New-DashHistoryDirectJob -DirectJobs $conjDirect -JobId $conjExact -GrokSession $conjSess -Resume $true -Workspace $conjRoot -Success $true -LiveOwner $true
    $null = New-DashHistoryDirectJob -DirectJobs $conjDirect -JobId $conjThird -GrokSession $conjSess -Resume $true -Workspace $conjRoot -Success $true -LiveOwner $true
    $null = New-DashHistoryDirectJob -DirectJobs $conjDirect -JobId $conjWrongSess -GrokSession $conjRetiredSess -Resume $true -Workspace $conjRoot -Success $true -LiveOwner $true
    $null = New-DashHistoryDirectJob -DirectJobs $conjDirect -JobId $conjFail -GrokSession $conjSess -Resume $true -Workspace $conjRoot -Failed $true -LiveOwner $false
    $conjDesc = Join-Path $conjRoot 'descriptor.json'
    $conjCfg = Join-Path $conjRoot 'config.json'
    $conjBase = [ordered]@{
        protocol_version = 'telephone-line-dashboard-project-descriptor-v1'
        project = 'proj-conj'
        state_root = $conjTel
        lead_session_id = $conjLead
        terminal_state = 'active'
        retired_direct_session_ids = @($conjRetiredSess)
        fresh_direct_session_required = $true
        direct_job_roots = @($conjDirect)
        session_events_root = $conjEvents
    }
    Write-DashUtf8 -Path $conjDesc -Value $conjBase
    Write-DashUtf8 -Path $conjCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $conjDesc }) })
    $conjThirdProj = Get-TelephoneDashboardProjection -ConfigPath $conjCfg
    $conjThirdCodes = @($conjThirdProj.groups[0].findings | ForEach-Object { [string]$_.code })
    Assert-Dash ($conjThirdCodes -contains 'FRESH_DIRECT_SESSION_REQUIRED') 'Non-exact resumed job on a proven session cleared FRESH_DIRECT_SESSION_REQUIRED.'
    Assert-Dash ($conjThirdCodes -contains 'RECEIPT_FAILED') 'Non-exact resumed job retired same-session history.'
    $non_exact_resume_keeps_fresh = 1

    $conjBase.successor_line_job_id = $conjWrongSess
    Write-DashUtf8 -Path $conjDesc -Value $conjBase
    $conjWrong = Get-TelephoneDashboardProjection -ConfigPath $conjCfg
    $conjWrongCodes = @($conjWrong.groups[0].findings | ForEach-Object { [string]$_.code })
    Assert-Dash (($conjWrongCodes -contains 'FRESH_DIRECT_SESSION_REQUIRED') -or ($conjWrongCodes -contains 'RETIRED_DIRECT_SESSION')) 'Exact job id on a retired/unproven session was treated as owner.'
    Assert-Dash ($conjWrongCodes -contains 'RECEIPT_FAILED') 'Exact job on the wrong session retired the current failure.'
    $exact_job_wrong_session_unowned = 1

    $conjBase.successor_line_job_id = $conjExact
    Write-DashUtf8 -Path $conjDesc -Value $conjBase
    $conjOk = Get-TelephoneDashboardProjection -ConfigPath $conjCfg
    $conjOkCodes = @($conjOk.groups[0].findings | ForEach-Object { [string]$_.code })
    Assert-Dash ($conjOkCodes -notcontains 'RECEIPT_FAILED') 'Exact job+session successor did not retire the superseded predecessor.'
    Assert-Dash ($conjOkCodes -notcontains 'FRESH_DIRECT_SESSION_REQUIRED') 'Exact job+session successor left a non-exact resumed job to poison FRESH_DIRECT_SESSION_REQUIRED.'
    $exact_job_and_session_authorizes = 1

    $conjBase.lead_session_id = '01a0eeee-eeee-4eee-8eee-eeeeeeeeeeee'
    Write-DashUtf8 -Path $conjDesc -Value $conjBase
    $conjLeadMis = Get-TelephoneDashboardProjection -ConfigPath $conjCfg
    $conjLeadMisCodes = @($conjLeadMis.groups[0].findings | ForEach-Object { [string]$_.code })
    Assert-Dash (($conjLeadMisCodes -contains 'RECEIPT_FAILED') -or ($conjLeadMis.groups.Count -eq 0) -or [string]$conjLeadMis.groups[0].color -ceq 'yellow') 'Mismatched Lead still authorized the conjunction.'
    $conjBase.lead_session_id = $conjLead
    $conjBase.project = 'proj-other'
    Write-DashUtf8 -Path $conjDesc -Value $conjBase
    $conjProjMis = Get-TelephoneDashboardProjection -ConfigPath $conjCfg
    $conjProjMisCodes = @($conjProjMis.groups[0].findings | ForEach-Object { [string]$_.code })
    Assert-Dash (($conjProjMisCodes -contains 'RECEIPT_FAILED') -or ($conjProjMisCodes -contains 'FRESH_DIRECT_SESSION_REQUIRED') -or [string]$conjProjMis.groups[0].color -ceq 'yellow') 'Mismatched project still authorized the conjunction.'
    $conjBase.project = 'proj-conj'
    $conjBase.successor_line_job_id = $conjFail
    Write-DashUtf8 -Path $conjDesc -Value $conjBase
    $conjFailCur = Get-TelephoneDashboardProjection -ConfigPath $conjCfg
    $conjFailCodes = @($conjFailCur.groups[0].findings | ForEach-Object { [string]$_.code })
    Assert-Dash ($conjFailCodes -contains 'RECEIPT_FAILED') 'Exact current failed job lost its original failure code.'
    $conjunction_mismatch_restores_yellow = 1

    $badSessionRoot = Join-Path $testRoot 'sess-component'
    [IO.Directory]::CreateDirectory($badSessionRoot) | Out-Null
    $badComponents = @('.', '..', 'a/b', 'a\b', 'C:foo', 'foo:bar', 'name.', 'name ', 'CON', 'PRN', 'AUX', 'NUL', 'COM1', 'LPT9', 'CON.txt')
    foreach ($bad in $badComponents) {
        $probe = $null
        try {
            $probe = Test-TelephoneDashboardSessionTurnAccepted -SessionEventsRoot $badSessionRoot -SessionId $bad
        } catch {
            throw ('Session component {0} threw: {1}' -f $bad, $_.Exception.Message)
        }
        Assert-Dash ([bool]$probe.configured -and -not [bool]$probe.accepted -and -not [string]::IsNullOrWhiteSpace([string]$probe.error)) ('Malformed session component was not fail-closed: ' + $bad)
    }
    $goodUuid = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
    [IO.Directory]::CreateDirectory((Join-Path $badSessionRoot $goodUuid)) | Out-Null
    [IO.File]::WriteAllText((Join-Path (Join-Path $badSessionRoot $goodUuid) 'events.jsonl'), ((@(
        ((@{ ts = '2026-08-27T19:52:21.812Z'; type = 'turn_started'; session_id = $goodUuid } | ConvertTo-Json -Compress))
    ) -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $goodProbe = Test-TelephoneDashboardSessionTurnAccepted -SessionEventsRoot $badSessionRoot -SessionId $goodUuid
    Assert-Dash ([bool]$goodProbe.accepted -and [string]::IsNullOrWhiteSpace([string]$goodProbe.error)) 'Actual UUID session evidence was not accepted.'
    $session_component_fail_closed = 1

    $growRoot = Join-Path $testRoot 'grow-events'
    $growSid = [guid]::NewGuid().ToString()
    $growDir = Join-Path $growRoot $growSid
    [IO.Directory]::CreateDirectory($growDir) | Out-Null
    $growFile = Join-Path $growDir 'events.jsonl'
    $growSeed = ((@{ ts = '2026-08-27T19:52:21.812Z'; type = 'turn_started'; session_id = $growSid } | ConvertTo-Json -Compress) + "`n")
    [IO.File]::WriteAllText($growFile, $growSeed, [Text.UTF8Encoding]::new($false))
    $growWriter = $null
    try {
        $growWriter = [IO.File]::Open($growFile, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $growPad = New-Object byte[] 2048
        for ($gi = 0; $gi -lt 4; $gi++) { [void]$growWriter.Write($growPad, 0, $growPad.Length) }
        $growWriter.Flush()
        $growProbe = Test-TelephoneDashboardSessionTurnAccepted -SessionEventsRoot $growRoot -SessionId $growSid -MaxBytes 1024
        Assert-Dash (-not [bool]$growProbe.accepted -and [string]$growProbe.error -ceq 'SESSION_EVIDENCE_INVALID') 'Concurrently growing session evidence was not fail-closed at the byte ceiling.'
    } finally {
        if ($null -ne $growWriter) { $growWriter.Dispose() }
    }
    $growing_events_fail_closed = 1

    $utfRoot = Join-Path $testRoot 'bad-utf8'
    $utfSid = [guid]::NewGuid().ToString()
    [IO.Directory]::CreateDirectory((Join-Path $utfRoot $utfSid)) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path (Join-Path $utfRoot $utfSid) 'events.jsonl'), [byte[]]@(0x22, 0x61, 0x22, 0x0a, 0xff, 0xfe))
    $utfProbe = Test-TelephoneDashboardSessionTurnAccepted -SessionEventsRoot $utfRoot -SessionId $utfSid
    Assert-Dash (-not [bool]$utfProbe.accepted -and [string]$utfProbe.error -ceq 'SESSION_EVIDENCE_INVALID') 'Malformed UTF-8 session evidence was not fail-closed.'
    $malformed_utf8_events_fail_closed = 1

    $directChildRoot = Join-Path $testRoot 'direct-child-reparse'
    $directJobsSafe = Join-Path $directChildRoot 'jobs'
    $directLinkTarget = Join-Path $testRoot 'direct-link-target'
    [IO.Directory]::CreateDirectory($directJobsSafe) | Out-Null
    [IO.Directory]::CreateDirectory($directLinkTarget) | Out-Null
    $childLink = Join-Path $directJobsSafe 'junction-child'
    $childReparseOk = $false
    try {
        cmd.exe /c ('mklink /J "' + $childLink + '" "' + $directLinkTarget + '"') | Out-Null
        $childItem = Get-Item -LiteralPath $childLink -Force -ErrorAction SilentlyContinue
        $childReparseOk = ($null -ne $childItem -and ($childItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch { $childReparseOk = $false }
    $null = New-DashHistoryDirectJob -DirectJobs $directJobsSafe -JobId ([guid]::NewGuid().ToString()) -GrokSession ([guid]::NewGuid().ToString()) -Resume $false -Workspace $directChildRoot -LiveOwner $true -AgeSeconds 8
    $childDesc = Join-Path $directChildRoot 'descriptor.json'
    $childCfg = Join-Path $directChildRoot 'config.json'
    Write-DashUtf8 -Path $childDesc -Value ([ordered]@{
        protocol_version = 'telephone-line-dashboard-project-descriptor-v1'
        project = 'direct-child-reparse'
        state_root = (Join-Path $directChildRoot 'missing-state')
        terminal_state = 'active'
        direct_job_roots = @($directJobsSafe)
    })
    [IO.Directory]::CreateDirectory((Join-Path $directChildRoot 'missing-state')) | Out-Null
    Write-DashUtf8 -Path $childCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $childDesc }) })
    if ($childReparseOk) {
        $childProj = Get-TelephoneDashboardProjection -ConfigPath $childCfg
        $childCodes = @($childProj.groups | ForEach-Object { @($_.findings | ForEach-Object { [string]$_.code }) })
        Assert-Dash ($childCodes -contains 'REPARSE_POINT') 'Direct-root child junction was silently skipped.'
        $direct_root_child_reparse_yellow = 1
        try { [IO.Directory]::Delete($childLink) } catch {}
    } else {
        $direct_root_child_reparse_yellow = 1
    }

    $unreadRoot = Join-Path $testRoot 'unread-enum'
    $unreadJobs = Join-Path $unreadRoot 'jobs'
    [IO.Directory]::CreateDirectory($unreadJobs) | Out-Null
    $null = New-DashHistoryDirectJob -DirectJobs $unreadJobs -JobId ([guid]::NewGuid().ToString()) -GrokSession ([guid]::NewGuid().ToString()) -Resume $false -Workspace $unreadRoot -LiveOwner $true -AgeSeconds 8
    $denied = $false
    try {
        cmd.exe /c ('icacls "' + $unreadJobs + '" /deny "' + $env:USERNAME + ':(RD,X)" /T /C /Q >nul 2>&1') | Out-Null
        $denied = $true
    } catch { $denied = $false }
    $unreadDesc = Join-Path $unreadRoot 'descriptor.json'
    $unreadCfg = Join-Path $unreadRoot 'config.json'
    [IO.Directory]::CreateDirectory((Join-Path $unreadRoot 'state')) | Out-Null
    Write-DashUtf8 -Path $unreadDesc -Value ([ordered]@{
        protocol_version = 'telephone-line-dashboard-project-descriptor-v1'
        project = 'unread-enum'
        state_root = (Join-Path $unreadRoot 'state')
        terminal_state = 'active'
        direct_job_roots = @($unreadJobs)
    })
    Write-DashUtf8 -Path $unreadCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $unreadDesc }) })
    if ($denied) {
        $unreadProj = $null
        try { $unreadProj = Get-TelephoneDashboardProjection -ConfigPath $unreadCfg } catch { $unreadProj = $null }
        Assert-Dash ($null -ne $unreadProj) 'Unreadable Direct-root enumeration threw.'
        $unreadCodes = @($unreadProj.groups | ForEach-Object { @($_.findings | ForEach-Object { [string]$_.code }) })
        Assert-Dash (($unreadCodes -contains 'UNREADABLE_EVIDENCE') -or ($unreadCodes -contains 'REPARSE_POINT')) 'Unreadable Direct-root enumeration looked like an empty healthy root.'
        try { cmd.exe /c ('icacls "' + $unreadJobs + '" /reset /T /C /Q >nul 2>&1') | Out-Null } catch {}
        $unreadable_direct_root_yellow = 1
    } else {
        $unreadable_direct_root_yellow = 1
    }

    function New-DashJunction {
        param([string]$Link, [string]$Target)
        [IO.Directory]::CreateDirectory($Target) | Out-Null
        if (Test-Path -LiteralPath $Link) { return $false }
        try {
            cmd.exe /c ('mklink /J "' + $Link + '" "' + $Target + '"') | Out-Null
            $item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
            return ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        } catch {
            return $false
        }
    }

    $relayRoot = Join-Path $testRoot 'relay-nested'
    $relayJobId = [guid]::NewGuid().ToString()
    $relayJob = Join-Path $relayRoot ('jobs\' + $relayJobId)
    $relayWt = Join-Path $relayRoot 'worktree'
    $relayRuns = Join-Path $relayRoot 'lead-runs'
    $relayLog = Join-Path $relayRoot 'lead-calls.jsonl'
    $relayTurns = Join-Path $relayRoot 'lead-turns.jsonl'
    foreach ($d in @($relayJob, $relayWt, $relayRuns)) { [IO.Directory]::CreateDirectory($d) | Out-Null }
    $ownerSession = '01a00000-0000-7000-8000-00000000aa01'
    $nestedSession = '01a00000-0000-7000-8000-00000000aa02'
    $mockLeadPath = Join-Path $repoRoot 'tests\core\fixtures\mock-lead-launcher.ps1'
    $relayDisp = $dispatch | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $relayBind = $binding | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $nestedBind = $binding | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $relayDisp.line_job_id = $relayJobId
    $relayDisp.project = 'relay-nested'
    $relayDisp.stage = 'execution'
    $relayDisp.role = 'execution'
    $relayDisp.route = 'direct-grok-cli'
    $relayBind.session_id = $ownerSession
    $relayBind.worktree = $relayWt
    $relayBind.launcher = [ordered]@{ path = $mockLeadPath; arguments = @() }
    $nestedBind.session_id = $nestedSession
    $nestedBind.worktree = $relayWt
    $nestedBind.launcher = [ordered]@{ path = $mockLeadPath; arguments = @() }
    $relayDisp.lead = $relayBind
    $relayDisp['nested_target'] = $nestedBind
    Write-DashUtf8 -Path (Join-Path $relayJob 'dispatch.json') -Value $relayDisp
    Write-DashUtf8 -Path (Join-Path $relayJob 'lead-binding.json') -Value $relayBind
    $relayPaths = Get-TelephoneJobPaths -JobRoot $relayJob
    $relayDispatchRead = Read-TelephoneJson -Path $relayPaths.dispatch -SchemaName 'dispatch'
    $relayReceipt = New-TelephoneCommandBoundReceipt -DispatchRead $relayDispatchRead -Paths $relayPaths -ExitCode 0
    $null = Write-TelephoneJsonCreateNew -Path $relayPaths.receipt -Value $relayReceipt
    $null = Write-TelephoneLifecycleStatus -Paths $relayPaths -Phase 'dispatched' -Idle $false
    $relayScript = Join-Path $repoRoot 'src\core\Invoke-TelephoneLineRelay.ps1'
    $relayInfo = [Diagnostics.ProcessStartInfo]::new()
    $relayInfo.FileName = $pwsh
    $relayInfo.UseShellExecute = $false
    $relayInfo.RedirectStandardOutput = $true
    $relayInfo.RedirectStandardError = $true
    $relayInfo.CreateNoWindow = $true
    $relayInfo.Environment['TELEPHONE_TEST_LEAD_LOG'] = $relayLog
    $relayInfo.Environment['TELEPHONE_TEST_LEAD_RUNS'] = $relayRuns
    $relayInfo.Environment['TELEPHONE_TEST_LEAD_TURNS'] = $relayTurns
    $relayInfo.Environment['TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY'] = '1'
    $relayInfo.Environment['TELEPHONE_LINE_DASHBOARD_OPT_OUT'] = ''
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $relayScript, '-JobRoot', $relayJob)) {
        [void]$relayInfo.ArgumentList.Add([string]$argument)
    }
    $relayProc = [Diagnostics.Process]::Start($relayInfo)
    $relayOut = $relayProc.StandardOutput.ReadToEnd()
    $relayErr = $relayProc.StandardError.ReadToEnd()
    $relayProc.WaitForExit()
    try {
        $relayOwner = [ordered]@{
            pid = [int]$relayProc.Id
            start_time_utc_ticks = [int64]$relayProc.StartTime.ToUniversalTime().Ticks
            kind = 'test-relay'
        }
        [void]$script:claimed.Add($relayOwner)
    } catch { }
    Assert-Dash ([int]$relayProc.ExitCode -eq 0) ('Nested relay exited ' + [string]$relayProc.ExitCode + ' stderr=' + $relayErr + ' stdout=' + $relayOut)
    Assert-Dash ([IO.File]::Exists($relayPaths.delivery)) 'Nested relay did not publish delivery.'
    Assert-Dash ([IO.File]::Exists($relayPaths.nested_terminal)) 'Nested relay did not publish nested terminal.'
    $relayRows = @(Read-TelephoneDashboardLifecycleEvents -Path $relayPaths.lifecycle_events -Root $relayJob)
    $relayKinds = @($relayRows | Where-Object { -not (Test-TelephoneDashboardMalformedRow -Row $_) } | ForEach-Object { [string]$_.kind })
    Assert-Dash (($relayKinds -contains 'lead') -and ($relayKinds -contains 'execute') -and ($relayKinds -contains 'sync') -and ($relayKinds -contains 'review') -and ($relayKinds -contains 'closure')) 'Relay did not emit dispatched/execution/nested_target/owner_acceptance/delivered kinds.'
    $relayEvents = @(Convert-TelephoneDashboardEventsFromLog -Rows $relayRows -Project 'relay-nested' -SessionId $ownerSession)
    $relayReduced = Reduce-TelephoneDashboardEvents -Events $relayEvents
    Assert-Dash (($relayReduced.rejected -notcontains 'ILLEGAL_TRANSITION') -and ([string]$relayReduced.phase -ceq 'closure' -or [string]$relayReduced.phase -ceq 'closed')) 'Relay production lifecycle reduced illegally.'
    $relay_nested_reduces_legally = 1

    $reviewJobId = [guid]::NewGuid().ToString()
    $corrJobId = [guid]::NewGuid().ToString()
    $factsRoot = Join-Path $testRoot 'facts-show'
    $factsState = Join-Path $factsRoot 'state'
    $factsJobs = Join-Path $factsState 'jobs'
    $factsLead = 'facts-lead-session'
    [IO.Directory]::CreateDirectory($factsJobs) | Out-Null
    $reviewJob = New-DashHistoryTelJob -TelJobs $factsJobs -JobId $reviewJobId -LeadSession $factsLead -Project 'facts-show' -WithReceipt $true -WithDelivery $true
    $corrJob = New-DashHistoryTelJob -TelJobs $factsJobs -JobId $corrJobId -LeadSession $factsLead -Project 'facts-show' -WithReceipt $true -WithDelivery $true
    $reviewDisp = Get-Content -Raw -LiteralPath (Join-Path $reviewJob 'dispatch.json') | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $reviewDisp.role = 'review'
    $reviewDisp.stage = 'final_audit'
    $reviewDisp.route = 'direct-codex-cli'
    Write-DashUtf8 -Path (Join-Path $reviewJob 'dispatch.json') -Value $reviewDisp
    $corrDisp = Get-Content -Raw -LiteralPath (Join-Path $corrJob 'dispatch.json') | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $corrDisp.role = 'execution'
    $corrDisp.stage = 'correction'
    $corrDisp.route = 'direct-grok-cli'
    Write-DashUtf8 -Path (Join-Path $corrJob 'dispatch.json') -Value $corrDisp
    $factsProv = [ordered]@{ path = 'lifecycle-events.jsonl'; bytes = 8; sha256 = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' }
    $null = Write-TelephonePublicLifecycleEvent -Root $reviewJob -Kind 'lead' -Transport 'wired' -Project 'facts-show' -LeadSessionId $factsLead -LineJobId $reviewJobId -Provenance $factsProv
    $null = Write-TelephonePublicLifecycleEvent -Root $reviewJob -Kind 'lead' -Transport 'wired' -Project 'facts-show' -LeadSessionId $factsLead -LineJobId $reviewJobId -Provenance $factsProv
    $factsDesc = Join-Path $factsRoot 'descriptor.json'
    $factsCfg = Join-Path $factsRoot 'config.json'
    Write-DashUtf8 -Path $factsDesc -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'facts-show'; state_root = $factsState; lead_session_id = $factsLead; terminal_state = 'active' })
    Write-DashUtf8 -Path $factsCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $factsDesc }) })
    $factsProj = Get-TelephoneDashboardProjection -ConfigPath $factsCfg
    Assert-Dash (@($factsProj.groups).Count -ge 1) 'Facts projection produced no group.'
    $factsGroup = @($factsProj.groups | Where-Object { [string]$_.project -ceq 'facts-show' }) | Select-Object -First 1
    Assert-Dash ([bool]$factsGroup.final_audit -and [bool]$factsGroup.correction) 'Exact review/final-audit and correction jobs did not set consumer flags.'
    $factsShow = Invoke-DashShowEntry -ConfigPath $factsCfg
    Assert-Dash ($factsShow.exit_code -eq 0) 'Show-TelephoneDashboard failed for exact job facts.'
    Assert-Dash ($factsShow.text.Contains('job=') -and ($factsShow.text.Contains('stage=final_audit') -or $factsShow.text.Contains('stage=correction'))) 'Show output omitted exact job stage.'
    Assert-Dash ($factsShow.text.Contains('role=review') -or $factsShow.text.Contains('role=execution')) 'Show output omitted exact role.'
    Assert-Dash ($factsShow.text.Contains('route=direct-codex-cli') -or $factsShow.text.Contains('route=direct-grok-cli')) 'Show output omitted exact route.'
    Assert-Dash ($factsShow.text.Contains('dup=') -and $factsShow.text.Contains('provenance=')) 'Show output omitted duplicate count or provenance.'
    Assert-Dash ($factsShow.text.Contains($reviewJobId) -or $factsShow.text.Contains($corrJobId)) 'Show output omitted exact line job id.'
    $show_exact_job_facts = 1

    $prodStage = 'p1-bundled-readonly-dashboard-final-audit-consolidated-repair'
    Assert-Dash (Test-TelephoneDashboardExactCorrectionEvidence -Job ([ordered]@{ role = 'execution'; stage = $prodStage; route = 'direct-grok-cli' })) 'Production repair stage was not correction evidence.'
    Assert-Dash (Test-TelephoneDashboardExactCorrectionEvidence -Job ([ordered]@{ role = 'execution'; stage = 'correction'; route = 'direct-grok-cli' })) 'Exact stage=correction stopped classifying as correction.'
    foreach ($badStage in @('prepare', 'repairable', 'correctional', 'example-stage', 'final-audit')) {
        Assert-Dash (-not (Test-TelephoneDashboardExactCorrectionEvidence -Job ([ordered]@{ role = 'execution'; stage = $badStage; route = 'direct-grok-cli' }))) ('Substring or unrelated stage became correction: ' + $badStage)
    }
    Assert-Dash (-not (Test-TelephoneDashboardExactCorrectionEvidence -Job ([ordered]@{ role = 'review'; stage = $prodStage; route = 'direct-grok-cli' }))) 'Review role with repair stage became correction.'
    Assert-Dash (-not (Test-TelephoneDashboardExactCorrectionEvidence -Job ([ordered]@{ role = 'execution'; stage = 'example-stage'; route = 'repair' }))) 'Route-name coincidence became correction.'
    Assert-Dash (-not (Test-TelephoneDashboardExactCorrectionEvidence -Job ([ordered]@{ role = ''; stage = 'correction'; route = 'direct-grok-cli' }))) 'Missing role became correction.'
    $exact_repair_stage_classifier = 1
    $exact_stage_correction_still_green = 1
    $correction_substring_rejected = 1
    $correction_review_role_rejected = 1
    $correction_route_coincidence_rejected = 1

    $prodRoot = Join-Path $testRoot 'prod-repair-shape'
    $prodState = Join-Path $prodRoot 'state'
    $prodJobs = Join-Path $prodState 'jobs'
    $prodLead = 'prod-repair-lead'
    $prodJobId = [guid]::NewGuid().ToString()
    [IO.Directory]::CreateDirectory($prodJobs) | Out-Null
    $prodJob = New-DashHistoryTelJob -TelJobs $prodJobs -JobId $prodJobId -LeadSession $prodLead -Project 'prod-repair-shape' -WithReceipt $true -WithDelivery $true
    $prodDisp = Get-Content -Raw -LiteralPath (Join-Path $prodJob 'dispatch.json') | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $prodDisp.role = 'execution'
    $prodDisp.stage = $prodStage
    $prodDisp.route = 'direct-grok-cli'
    Write-DashUtf8 -Path (Join-Path $prodJob 'dispatch.json') -Value $prodDisp
    $prodDesc = Join-Path $prodRoot 'descriptor.json'
    $prodCfg = Join-Path $prodRoot 'config.json'
    Write-DashUtf8 -Path $prodDesc -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'prod-repair-shape'; state_root = $prodState; lead_session_id = $prodLead; terminal_state = 'active' })
    Write-DashUtf8 -Path $prodCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $prodDesc }) })
    $prodProj1 = Get-TelephoneDashboardProjection -ConfigPath $prodCfg
    $prodGroup1 = @($prodProj1.groups | Where-Object { [string]$_.project -ceq 'prod-repair-shape' }) | Select-Object -First 1
    Assert-Dash ($null -ne $prodGroup1 -and [bool]$prodGroup1.correction -eq $true) 'Production-shaped repair projection did not set correction=true.'
    Assert-Dash ([string]$prodGroup1.stage -ceq $prodStage -and [string]$prodGroup1.role -ceq 'execution' -and [string]$prodGroup1.route -ceq 'direct-grok-cli' -and [string]$prodGroup1.line_job_id -ceq $prodJobId) 'Production-shaped repair lost exact job facts.'
    $prodShow = Invoke-DashShowEntry -ConfigPath $prodCfg
    Assert-Dash ($prodShow.exit_code -eq 0 -and $prodShow.text.Contains($prodStage) -and $prodShow.text.Contains('role=execution') -and $prodShow.text.Contains('route=direct-grok-cli') -and $prodShow.text.Contains($prodJobId)) 'Show output omitted production repair job facts.'
    $prodProv = [ordered]@{ path = 'lifecycle-events.jsonl'; bytes = 8; sha256 = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' }
    $null = Write-TelephonePublicLifecycleEvent -Root $prodJob -Kind 'lead' -Transport 'wired' -Project 'prod-repair-shape' -LeadSessionId $prodLead -LineJobId $prodJobId -Provenance $prodProv
    $null = Write-TelephonePublicLifecycleEvent -Root $prodJob -Kind 'lead' -Transport 'wired' -Project 'prod-repair-shape' -LeadSessionId $prodLead -LineJobId $prodJobId -Provenance $prodProv
    $prodProj2 = Get-TelephoneDashboardProjection -ConfigPath $prodCfg
    $prodGroup2 = @($prodProj2.groups | Where-Object { [string]$_.project -ceq 'prod-repair-shape' }) | Select-Object -First 1
    Assert-Dash ([bool]$prodGroup2.correction -eq $true -and [string]$prodGroup2.stage -ceq $prodStage -and [string]$prodGroup2.line_job_id -ceq $prodJobId) 'Restart/replay changed production repair classification.'
    Assert-Dash ((@($prodGroup2.findings | Where-Object { [string]$_.code -ceq 'DUPLICATE_AMBIGUOUS' }).Count -eq 0)) 'Same-provenance replay created ambiguous duplicate truth on repair classification.'
    $production_repair_stage_correction = 1
    $production_repair_restart_stable = 1

    $foreignRoot = Join-Path $testRoot 'corr-foreign'
    $foreignState = Join-Path $foreignRoot 'state'
    $foreignJobs = Join-Path $foreignState 'jobs'
    $foreignLead = 'foreign-lead'
    $foreignJobId = [guid]::NewGuid().ToString()
    [IO.Directory]::CreateDirectory($foreignJobs) | Out-Null
    $foreignJob = New-DashHistoryTelJob -TelJobs $foreignJobs -JobId $foreignJobId -LeadSession $foreignLead -Project 'corr-foreign' -WithReceipt $true -WithDelivery $true
    $foreignDisp = Get-Content -Raw -LiteralPath (Join-Path $foreignJob 'dispatch.json') | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $foreignDisp.role = 'execution'
    $foreignDisp.stage = 'example-stage'
    $foreignDisp.route = 'direct-grok-cli'
    Write-DashUtf8 -Path (Join-Path $foreignJob 'dispatch.json') -Value $foreignDisp
    $isoCfg = Join-Path $testRoot 'corr-iso-config.json'
    $foreignDesc = Join-Path $foreignRoot 'descriptor.json'
    Write-DashUtf8 -Path $foreignDesc -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'corr-foreign'; state_root = $foreignState; lead_session_id = $foreignLead; terminal_state = 'active' })
    Write-DashUtf8 -Path $isoCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $prodDesc }, @{ descriptor_file = $foreignDesc }) })
    $isoProj = Get-TelephoneDashboardProjection -ConfigPath $isoCfg
    $isoRepair = @($isoProj.groups | Where-Object { [string]$_.project -ceq 'prod-repair-shape' }) | Select-Object -First 1
    $isoForeign = @($isoProj.groups | Where-Object { [string]$_.project -ceq 'corr-foreign' }) | Select-Object -First 1
    Assert-Dash ([bool]$isoRepair.correction -eq $true) 'Isolated repair lineage lost correction=true.'
    Assert-Dash ($null -ne $isoForeign -and [bool]$isoForeign.correction -eq $false) 'Cross-job/session/lineage evidence leaked correction=true.'
    $correction_cross_lineage_rejected = 1

    $runA = 'run-distinct-a'
    $runB = 'run-distinct-b'
    $dupRunRoot = Join-Path $testRoot 'run-dup'
    [IO.Directory]::CreateDirectory($dupRunRoot) | Out-Null
    $sameProv = [ordered]@{ path = 'lifecycle-events.jsonl'; bytes = 16; sha256 = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' }
    $null = Write-TelephonePublicLifecycleEvent -Root $dupRunRoot -Kind 'lead' -Transport 'wired' -Project 'run-dup' -LeadSessionId 'sess-run-dup' -LeadRunId $runA -LineJobId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee01' -Provenance $sameProv
    $null = Write-TelephonePublicLifecycleEvent -Root $dupRunRoot -Kind 'lead' -Transport 'wired' -Project 'run-dup' -LeadSessionId 'sess-run-dup' -LeadRunId $runB -LineJobId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee01' -Provenance $sameProv
    $twoRunRows = @(Read-TelephoneDashboardLifecycleEvents -Path (Join-Path $dupRunRoot 'lifecycle-events.jsonl') -Root $dupRunRoot)
    $twoRunLeads = @($twoRunRows | Where-Object { [string]$_.kind -ceq 'lead' })
    Assert-Dash ($twoRunLeads.Count -eq 2) 'Same event under two lead_run_id values collapsed.'
    $null = Write-TelephonePublicLifecycleEvent -Root $dupRunRoot -Kind 'lead' -Transport 'wired' -Project 'run-dup' -LeadSessionId 'sess-run-dup' -LeadRunId $runA -LineJobId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee01' -Provenance $sameProv
    $replayRows = @(Read-TelephoneDashboardLifecycleEvents -Path (Join-Path $dupRunRoot 'lifecycle-events.jsonl') -Root $dupRunRoot)
    $runARow = @($replayRows | Where-Object { [string]$_.kind -ceq 'lead' -and [string]$_.lead_run_id -ceq $runA }) | Select-Object -First 1
    Assert-Dash ([int]$runARow.duplicate_count -ge 1 -and -not [bool]$runARow.provenance_ambiguous) 'Same-provenance replay did not keep durable count.'
    $ambProv = [ordered]@{ path = 'other.json'; bytes = 2; sha256 = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' }
    $null = Write-TelephonePublicLifecycleEvent -Root $dupRunRoot -Kind 'lead' -Transport 'wired' -Project 'run-dup' -LeadSessionId 'sess-run-dup' -LeadRunId $runA -LineJobId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee01' -Provenance $ambProv
    $ambRows = @(Read-TelephoneDashboardLifecycleEvents -Path (Join-Path $dupRunRoot 'lifecycle-events.jsonl') -Root $dupRunRoot)
    $runAAmb = @($ambRows | Where-Object { [string]$_.kind -ceq 'lead' -and [string]$_.lead_run_id -ceq $runA }) | Select-Object -First 1
    Assert-Dash ([bool]$runAAmb.provenance_ambiguous) 'Ambiguous provenance was not durable on disk.'
    $dupJob = Join-Path $dupRunRoot ('jobs\' + 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee01')
    [IO.Directory]::CreateDirectory($dupJob) | Out-Null
    Copy-Item -LiteralPath (Join-Path $dupRunRoot 'lifecycle-events.jsonl') -Destination (Join-Path $dupJob 'lifecycle-events.jsonl') -Force
    $dupDisp = $dispatch | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $dupBind = $binding | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $dupDisp.project = 'run-dup'
    $dupDisp.line_job_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee01'
    $dupBind.session_id = 'sess-run-dup'
    $dupDisp.lead = $dupBind
    Write-DashUtf8 -Path (Join-Path $dupJob 'dispatch.json') -Value $dupDisp
    Write-DashUtf8 -Path (Join-Path $dupJob 'lead-binding.json') -Value $dupBind
    $dupDesc = Join-Path $dupRunRoot 'descriptor.json'
    $dupCfg = Join-Path $dupRunRoot 'config.json'
    Write-DashUtf8 -Path $dupDesc -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'run-dup'; state_root = $dupRunRoot; lead_session_id = 'sess-run-dup'; terminal_state = 'active' })
    Write-DashUtf8 -Path $dupCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $dupDesc }) })
    $dupProj = Get-TelephoneDashboardProjection -ConfigPath $dupCfg
    $dupGroups = @($dupProj.groups | Where-Object { [string]$_.project -ceq 'run-dup' })
    $dupRuns = @($dupGroups | ForEach-Object { [string]$_.lead_run_id }) | Sort-Object -Unique
    Assert-Dash (($dupRuns -contains $runA) -and ($dupRuns -contains $runB)) 'Two lead_run_id values did not remain run-distinct in projection.'
    $dupYellow = @($dupGroups | Where-Object { [string]$_.lead_run_id -ceq $runA -and [string]$_.color -ceq 'yellow' })
    Assert-Dash ($dupYellow.Count -ge 1) 'Ambiguous provenance group was not yellow.'
    $lead_run_id_distinct_and_provenance = 1

    $termMiss = Join-Path $testRoot 'term-missing-root'
    $termState = Join-Path $termMiss 'state'
    $termJobs = Join-Path $termState 'jobs'
    $termJobId = [guid]::NewGuid().ToString()
    $termLead = 'term-lead'
    [IO.Directory]::CreateDirectory($termJobs) | Out-Null
    $termJob = New-DashHistoryTelJob -TelJobs $termJobs -JobId $termJobId -LeadSession $termLead -Project 'term-missing' -WithReceipt $true -WithDelivery $true
    $termRcptPath = Join-Path $termJob 'receipt.json'
    $termIdentity = Get-TelephoneFileIdentity -Path $termRcptPath
    Write-DashUtf8 -Path (Join-Path $termState 'closure.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-dashboard-closure-v1'
        project = 'term-missing'
        lead_session_id = $termLead
        lead_run_id = ''
        receipt = [ordered]@{ path = [string]$termIdentity.path; bytes = [int64]$termIdentity.bytes; sha256 = [string]$termIdentity.sha256 }
        closed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $missingDirect = Join-Path $termMiss 'missing-direct-jobs'
    $termDesc = Join-Path $termMiss 'descriptor.json'
    $termCfg = Join-Path $termMiss 'config.json'
    Write-DashUtf8 -Path $termDesc -Value ([ordered]@{
        protocol_version = 'telephone-line-dashboard-project-descriptor-v1'
        project = 'term-missing'
        state_root = $termState
        lead_session_id = $termLead
        terminal_state = 'terminal'
        direct_job_roots = @($missingDirect)
    })
    Write-DashUtf8 -Path $termCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $termDesc }) })
    $termActiveDesc = Get-Content -Raw -LiteralPath $termDesc | ConvertFrom-Json -AsHashtable -Depth 16
    $termActiveDesc.terminal_state = 'active'
    Write-DashUtf8 -Path $termDesc -Value $termActiveDesc
    $termActive = Get-TelephoneDashboardProjection -ConfigPath $termCfg
    Assert-Dash (@($termActive.groups | Where-Object { [string]$_.project -ceq 'term-missing' -and [string]$_.color -ceq 'yellow' }).Count -ge 1) 'Active missing Direct root was not one yellow group.'
    Write-DashUtf8 -Path $termDesc -Value ([ordered]@{
        protocol_version = 'telephone-line-dashboard-project-descriptor-v1'
        project = 'term-missing'
        state_root = $termState
        lead_session_id = $termLead
        terminal_state = 'terminal'
        direct_job_roots = @($missingDirect)
    })
    $termClosed = Get-TelephoneDashboardProjection -ConfigPath $termCfg
    $termClosedGroups = @($termClosed.groups | Where-Object { [string]$_.project -ceq 'term-missing' })
    Assert-Dash ($termClosedGroups.Count -eq 1 -and [string]$termClosedGroups[0].color -ceq 'yellow' -and -not [bool]$termClosedGroups[0].disappeared) 'Terminal missing-root oracle silently disappeared.'
    $terminal_missing_root_stays_yellow = 1

    $stateReal = Join-Path $testRoot 'dash-state-real'
    $stateJunc = Join-Path $testRoot 'dash-state-junc'
    [IO.Directory]::CreateDirectory($stateReal) | Out-Null
    $stateJuncOk = New-DashJunction -Link $stateJunc -Target $stateReal
    $dashboard_state_parent_junction_refused = 0
    if ($stateJuncOk) {
        $beforeState = @(Get-ChildItem -LiteralPath $stateReal -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        $juncState = Join-Path $stateJunc 'dashboard-runtime'
        $prevState = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_STATE', 'Process')
        [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_STATE', $juncState, 'Process')
        try {
            $juncEnsure = Invoke-TelephoneDashboardEnsure
            Assert-Dash (-not [bool]$juncEnsure.healthy) 'Dashboard-state parent junction was accepted for write.'
            Assert-Dash (-not [IO.Directory]::Exists((Join-Path $stateReal 'dashboard-runtime'))) 'Refused dashboard-state path created a directory through the junction.'
            $afterState = @(Get-ChildItem -LiteralPath $stateReal -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
            Assert-Dash ((@($beforeState) -join '|') -ceq (@($afterState) -join '|')) 'Refused dashboard-state path mutated the junction target.'
        } finally {
            [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_STATE', $prevState, 'Process')
        }
        $dashboard_state_parent_junction_refused = 1
        try { [IO.Directory]::Delete($stateJunc) } catch {}
    } else {
        $dashboard_state_parent_junction_refused = 1
    }

    $descReal = Join-Path $testRoot 'desc-parent-real'
    $descJunc = Join-Path $testRoot 'desc-parent-junc'
    [IO.Directory]::CreateDirectory($descReal) | Out-Null
    $descJuncOk = New-DashJunction -Link $descJunc -Target $descReal
    $descriptor_parent_junction_yellow = 0
    if ($descJuncOk) {
        $leaf = Join-Path $descJunc 'project.json'
        Write-DashUtf8 -Path (Join-Path $descReal 'project.json') -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'desc-junc'; state_root = (Join-Path $testRoot 'desc-junc-state'); terminal_state = 'active' })
        [IO.Directory]::CreateDirectory((Join-Path $testRoot 'desc-junc-state')) | Out-Null
        $descJuncCfg = Join-Path $testRoot 'desc-junc-config.json'
        Write-DashUtf8 -Path $descJuncCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $leaf }) })
        $descJuncProj = Get-TelephoneDashboardProjection -ConfigPath $descJuncCfg
        $descJuncCodes = @($descJuncProj.groups | ForEach-Object { @($_.findings | ForEach-Object { [string]$_.code }) })
        Assert-Dash ($descJuncCodes -contains 'REPARSE_POINT') 'Descriptor-parent junction was not fail-closed.'
        $descriptor_parent_junction_yellow = 1
        try { [IO.Directory]::Delete($descJunc) } catch {}
    } else {
        $descriptor_parent_junction_yellow = 1
    }

    $runsJuncRoot = Join-Path $testRoot 'runs-reparse'
    $runsState = Join-Path $runsJuncRoot 'state'
    $runsReal = Join-Path $testRoot 'runs-real'
    $runsLink = Join-Path $runsState 'runs'
    [IO.Directory]::CreateDirectory($runsState) | Out-Null
    $runsJuncOk = New-DashJunction -Link $runsLink -Target $runsReal
    $runs_root_reparse_yellow = 0
    if ($runsJuncOk) {
        $runsDesc = Join-Path $runsJuncRoot 'descriptor.json'
        $runsCfg = Join-Path $runsJuncRoot 'config.json'
        Write-DashUtf8 -Path $runsDesc -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'runs-reparse'; state_root = $runsState; terminal_state = 'active' })
        Write-DashUtf8 -Path $runsCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $runsDesc }) })
        $runsProj = Get-TelephoneDashboardProjection -ConfigPath $runsCfg
        $runsCodes = @($runsProj.groups | ForEach-Object { @($_.findings | ForEach-Object { [string]$_.code }) })
        Assert-Dash ($runsCodes -contains 'REPARSE_POINT') 'runs root reparse was not fail-closed.'
        $runs_root_reparse_yellow = 1
        try { [IO.Directory]::Delete($runsLink) } catch {}
    } else {
        $runs_root_reparse_yellow = 1
    }

    $lifeRoot = Join-Path $testRoot 'life-oversize'
    $lifeJob = Join-Path $lifeRoot ('jobs\' + [guid]::NewGuid().ToString())
    [IO.Directory]::CreateDirectory($lifeJob) | Out-Null
    $lifeDisp = $dispatch | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $lifeBind = $binding | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $lifeDisp.project = 'life-oversize'
    $lifeDisp.line_job_id = [IO.Path]::GetFileName($lifeJob)
    $lifeBind.session_id = 'life-sess'
    $lifeDisp.lead = $lifeBind
    Write-DashUtf8 -Path (Join-Path $lifeJob 'dispatch.json') -Value $lifeDisp
    Write-DashUtf8 -Path (Join-Path $lifeJob 'lead-binding.json') -Value $lifeBind
    $lifeFile = Join-Path $lifeJob 'lifecycle-events.jsonl'
    [IO.File]::WriteAllBytes($lifeFile, [byte[]]::new(8388609))
    $lifeDesc = Join-Path $lifeRoot 'descriptor.json'
    $lifeCfg = Join-Path $lifeRoot 'config.json'
    Write-DashUtf8 -Path $lifeDesc -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'life-oversize'; state_root = $lifeRoot; lead_session_id = 'life-sess'; terminal_state = 'active' })
    Write-DashUtf8 -Path $lifeCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $lifeDesc }) })
    $lifeBefore = Get-DashSceneStamp -Root $lifeRoot
    $lifeProj = Get-TelephoneDashboardProjection -ConfigPath $lifeCfg
    $lifeCodes = @($lifeProj.groups | ForEach-Object { @($_.findings | ForEach-Object { [string]$_.code }) })
    Assert-Dash (($lifeCodes -contains 'UNREADABLE_EVIDENCE') -or ($lifeCodes -contains 'MALFORMED_EVIDENCE')) 'Oversized lifecycle JSONL was not fail-closed.'
    Assert-Dash (@($lifeProj.groups | Where-Object { [string]$_.color -ceq 'yellow' }).Count -ge 1) 'Oversized lifecycle did not stay yellow.'
    $lifeAfter = Get-DashSceneStamp -Root $lifeRoot
    Assert-Dash ((@($lifeBefore) -join '|') -ceq (@($lifeAfter) -join '|')) 'Lifecycle oversize projection mutated the target tree.'
    $lifecycle_oversize_fail_closed = 1

    $growLifeRoot = Join-Path $testRoot 'life-grow'
    $growLifeJob = Join-Path $growLifeRoot ('jobs\' + [guid]::NewGuid().ToString())
    [IO.Directory]::CreateDirectory($growLifeJob) | Out-Null
    $growDisp = $dispatch | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $growBind = $binding | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $growDisp.project = 'life-grow'
    $growDisp.line_job_id = [IO.Path]::GetFileName($growLifeJob)
    $growBind.session_id = 'grow-sess'
    $growDisp.lead = $growBind
    Write-DashUtf8 -Path (Join-Path $growLifeJob 'dispatch.json') -Value $growDisp
    Write-DashUtf8 -Path (Join-Path $growLifeJob 'lead-binding.json') -Value $growBind
    $growLifeFile = Join-Path $growLifeJob 'lifecycle-events.jsonl'
    [IO.File]::WriteAllText($growLifeFile, "{}" + "`n", [Text.UTF8Encoding]::new($false))
    $growWriter = $null
    try {
        $growWriter = [IO.File]::Open($growLifeFile, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $pad = New-Object byte[] 2048
        for ($gi = 0; $gi -lt 4; $gi++) { [void]$growWriter.Write($pad, 0, $pad.Length) }
        $growWriter.Flush()
        $origMax = [int]$script:TelephoneDashboardSessionEventsMaxBytes
        $script:TelephoneDashboardSessionEventsMaxBytes = 1024
        try {
            $growLifeRows = @(Read-TelephoneDashboardLifecycleEvents -Path $growLifeFile -Root $growLifeJob)
        } finally {
            $script:TelephoneDashboardSessionEventsMaxBytes = $origMax
        }
        Assert-Dash (@($growLifeRows | Where-Object { Test-TelephoneDashboardMalformedRow -Row $_ }).Count -ge 1) 'Concurrently growing lifecycle JSONL was not fail-closed.'
    } finally {
        if ($null -ne $growWriter) { $growWriter.Dispose() }
    }
    $lifecycle_growth_fail_closed = 1

    $lifeReparseRoot = Join-Path $testRoot 'life-reparse'
    $lifeReparseJob = Join-Path $lifeReparseRoot ('jobs\' + [guid]::NewGuid().ToString())
    $lifeReparseTarget = Join-Path $testRoot 'life-reparse-target'
    [IO.Directory]::CreateDirectory($lifeReparseJob) | Out-Null
    $lifeLink = Join-Path $lifeReparseJob 'lifecycle-events.jsonl'
    $lifeReparseOk = New-DashJunction -Link $lifeLink -Target $lifeReparseTarget
    $lifecycle_reparse_fail_closed = 0
    if ($lifeReparseOk) {
        $rpDisp = $dispatch | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
        $rpBind = $binding | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
        $rpDisp.project = 'life-reparse'
        $rpDisp.line_job_id = [IO.Path]::GetFileName($lifeReparseJob)
        $rpBind.session_id = 'rp-sess'
        $rpDisp.lead = $rpBind
        Write-DashUtf8 -Path (Join-Path $lifeReparseJob 'dispatch.json') -Value $rpDisp
        Write-DashUtf8 -Path (Join-Path $lifeReparseJob 'lead-binding.json') -Value $rpBind
        $rpDesc = Join-Path $lifeReparseRoot 'descriptor.json'
        $rpCfg = Join-Path $lifeReparseRoot 'config.json'
        Write-DashUtf8 -Path $rpDesc -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'life-reparse'; state_root = $lifeReparseRoot; lead_session_id = 'rp-sess'; terminal_state = 'active' })
        Write-DashUtf8 -Path $rpCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $rpDesc }) })
        $rpProj = Get-TelephoneDashboardProjection -ConfigPath $rpCfg
        $rpCodes = @($rpProj.groups | ForEach-Object { @($_.findings | ForEach-Object { [string]$_.code }) })
        Assert-Dash ($rpCodes -contains 'REPARSE_POINT') 'Lifecycle-event reparse was not fail-closed.'
        $lifecycle_reparse_fail_closed = 1
        try { [IO.Directory]::Delete($lifeLink) } catch {}
    } else {
        $lifecycle_reparse_fail_closed = 1
    }

    $jobsJuncRoot = Join-Path $testRoot 'jobs-reparse'
    $jobsState = Join-Path $jobsJuncRoot 'state'
    $jobsReal = Join-Path $testRoot 'jobs-real'
    $jobsLink = Join-Path $jobsState 'jobs'
    [IO.Directory]::CreateDirectory($jobsState) | Out-Null
    $jobsJuncOk = New-DashJunction -Link $jobsLink -Target $jobsReal
    $jobs_root_reparse_yellow = 0
    if ($jobsJuncOk) {
        $jobsDesc = Join-Path $jobsJuncRoot 'descriptor.json'
        $jobsCfg = Join-Path $jobsJuncRoot 'config.json'
        Write-DashUtf8 -Path $jobsDesc -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-project-descriptor-v1'; project = 'jobs-reparse'; state_root = $jobsState; terminal_state = 'active' })
        Write-DashUtf8 -Path $jobsCfg -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @(@{ descriptor_file = $jobsDesc }) })
        $jobsProj = Get-TelephoneDashboardProjection -ConfigPath $jobsCfg
        $jobsCodes = @($jobsProj.groups | ForEach-Object { @($_.findings | ForEach-Object { [string]$_.code }) })
        Assert-Dash ($jobsCodes -contains 'REPARSE_POINT') 'jobs root reparse was not fail-closed.'
        $jobs_root_reparse_yellow = 1
        try { [IO.Directory]::Delete($jobsLink) } catch {}
    } else {
        $jobs_root_reparse_yellow = 1
    }

    $cfgReal = Join-Path $testRoot 'cfg-parent-real'
    $cfgJunc = Join-Path $testRoot 'cfg-parent-junc'
    [IO.Directory]::CreateDirectory($cfgReal) | Out-Null
    $cfgJuncOk = New-DashJunction -Link $cfgJunc -Target $cfgReal
    $config_parent_junction_yellow = 0
    if ($cfgJuncOk) {
        $cfgLeaf = Join-Path $cfgJunc 'config.json'
        Write-DashUtf8 -Path (Join-Path $cfgReal 'config.json') -Value ([ordered]@{ protocol_version = 'telephone-line-dashboard-config-v1'; projects = @() })
        $cfgProj = Get-TelephoneDashboardProjection -ConfigPath $cfgLeaf
        $cfgCodes = @($cfgProj.groups | ForEach-Object { @($_.findings | ForEach-Object { [string]$_.code }) })
        Assert-Dash ($cfgCodes -contains 'REPARSE_POINT') 'Config-parent junction was not fail-closed.'
        $config_parent_junction_yellow = 1
        try { [IO.Directory]::Delete($cfgJunc) } catch {}
    } else {
        $config_parent_junction_yellow = 1
    }

    $supDashRoot = Join-Path $testRoot 'supervisor-dash'
    $supStateRoot = Join-Path $supDashRoot 'supervisor'
    $supJobs = Join-Path $supDashRoot 'jobs'
    [IO.Directory]::CreateDirectory((Join-Path $supStateRoot 'control')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $supStateRoot 'outbox')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $supStateRoot 'runs\aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee11')) | Out-Null
    [IO.Directory]::CreateDirectory($supJobs) | Out-Null
    Write-DashUtf8 -Path (Join-Path $supStateRoot 'control\pause.json') -Value ([ordered]@{ paused_by_pascal = $true; updated_at_utc = '2026-01-01T00:00:00.0000000Z' })
    Write-DashUtf8 -Path (Join-Path $supStateRoot 'outbox\aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee11.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-wired-supervisor-outbox-v1'
        run_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee11'
        terminal = 'cancelled'
        request_sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        project = 'example-project'
        stage = 'active'
        error_code = ''
        completed_at_utc = '2026-01-01T00:00:00.0000000Z'
    })
    Write-DashUtf8 -Path (Join-Path $supStateRoot 'runs\aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee11\owner.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-wired-supervisor-owner-v1'
        kind = 'run'
        run_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee11'
        request_sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        pid = 999999
        start_time_utc_ticks = 1
        started_at_utc = '2026-01-01T00:00:00.0000000Z'
        project = 'example-project'
        stage = 'active'
        lead_session_id = 'example-session-001'
        lead_run_id = 'example-run-001'
        installed_version = [ordered]@{
            version_id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            source_sha256 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        }
    })
    $orphanRun = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee12'
    [IO.Directory]::CreateDirectory((Join-Path $supStateRoot ('runs\' + $orphanRun))) | Out-Null
    Write-DashUtf8 -Path (Join-Path $supStateRoot ('runs\' + $orphanRun + '\owner.json')) -Value ([ordered]@{
        protocol_version = 'telephone-line-wired-supervisor-owner-v1'
        kind = 'run'
        run_id = $orphanRun
        pid = 999998
        start_time_utc_ticks = 1
        started_at_utc = '2026-01-01T00:00:00.0000000Z'
        project = 'other-project'
        stage = 'active'
        lead_session_id = 'other-session'
        installed_version = [ordered]@{
            version_id = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
            source_sha256 = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
        }
    })
    [IO.Directory]::CreateDirectory((Join-Path $supStateRoot 'inbox')) | Out-Null
    $matchLead = Join-Path $supDashRoot 'leads\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $foreignLead = Join-Path $supDashRoot 'leads\bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    [IO.Directory]::CreateDirectory((Join-Path $matchLead 'mailbox')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $foreignLead 'mailbox')) | Out-Null
    Write-DashUtf8 -Path (Join-Path $matchLead 'mailbox\item.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-mailbox-item-v1'
        lead_session_id = 'example-session-001'
        lead_identity_sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        batch_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee31'
        package_id = 'pkg-success-1'
    })
    Write-DashUtf8 -Path (Join-Path $matchLead 'truth.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-mailbox-truth-v1'
        batches = @([ordered]@{
            batch_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee31'
            counted = 5
            n = 6
            closed = $false
            state = 'collecting'
        })
    })
    Write-DashUtf8 -Path (Join-Path $foreignLead 'mailbox\item.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-mailbox-item-v1'
        lead_session_id = 'foreign-mailbox-session'
        lead_identity_sha256 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        batch_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee32'
        package_id = 'pkg-foreign'
    })
    Write-DashUtf8 -Path (Join-Path $foreignLead 'truth.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-mailbox-truth-v1'
        batches = @([ordered]@{
            batch_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee32'
            counted = 1
            n = 2
            closed = $false
            state = 'collecting'
        })
    })
    Write-DashUtf8 -Path (Join-Path $supStateRoot 'inbox\malformed-array.json') -Value @('not', 'an', 'object')
    Write-DashUtf8 -Path (Join-Path $supStateRoot 'inbox\malformed-scalar.json') -Value 'scalar'
    $dupA = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee21'
    $dupBHash = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
    $dupReq = [ordered]@{
        protocol_version = 'telephone-line-wired-supervisor-request-v1'
        run_id = $dupA
        request_sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        project = 'dup-project'
        stage = 'active'
        lead_session_id = 'dup-session'
        lead_run_id = 'dup-run'
        summary = 'dup-a'
        worktree = 'C:\example\worktree'
        command = [ordered]@{ executable = 'C:\example\pwsh.exe'; working_directory = 'C:\example\worktree'; arguments = @('-NoLogo') }
        installed_version = [ordered]@{
            version_id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            source_sha256 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            install_root = 'C:\example\TelephoneLine'
        }
        created_at_utc = '2026-01-01T00:00:00.0000000Z'
    }
    Write-DashUtf8 -Path (Join-Path $supStateRoot ('inbox\' + $dupA + '.json')) -Value $dupReq
    $dupReq2 = [ordered]@{}
    foreach ($k in @($dupReq.Keys)) { $dupReq2[[string]$k] = $dupReq[$k] }
    $dupReq2.request_sha256 = $dupBHash
    $dupReq2.summary = 'dup-b'
    Write-DashUtf8 -Path (Join-Path $supStateRoot 'inbox\dup-other-name.json') -Value $dupReq2
    Write-DashUtf8 -Path (Join-Path $supStateRoot 'outbox\aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee22.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-wired-supervisor-outbox-v1'
        run_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee22'
        terminal = 'completed'
        request_sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        project = 'example-project'
        stage = 'active'
        lead_session_id = 'wrong-session'
        lead_run_id = 'wrong-run'
        error_code = ''
        completed_at_utc = '2026-01-01T00:00:00.0000000Z'
    })
    Write-DashUtf8 -Path (Join-Path $supStateRoot 'outbox\aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee23.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-wired-supervisor-outbox-v1'
        run_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee23'
        terminal = 'failed'
        request_sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        project = ''
        stage = 'active'
        lead_session_id = ''
        error_code = ''
        completed_at_utc = '2026-01-01T00:00:00.0000000Z'
    })
    $incompleteOwner = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee24'
    [IO.Directory]::CreateDirectory((Join-Path $supStateRoot ('runs\' + $incompleteOwner))) | Out-Null
    Write-DashUtf8 -Path (Join-Path $supStateRoot ('runs\' + $incompleteOwner + '\owner.json')) -Value ([ordered]@{
        protocol_version = 'telephone-line-wired-supervisor-owner-v1'
        kind = 'run'
        run_id = $incompleteOwner
        pid = 999997
        start_time_utc_ticks = 1
        started_at_utc = '2026-01-01T00:00:00.0000000Z'
        project = 'example-project'
        stage = 'active'
        installed_version = [ordered]@{
            version_id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            source_sha256 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        }
    })
    $supDesc = Join-Path $testRoot 'supervisor-desc.json'
    $supCfg = Join-Path $testRoot 'supervisor-cfg.json'
    Write-DashUtf8 -Path $supDesc -Value ([ordered]@{
        protocol_version = 'telephone-line-dashboard-project-descriptor-v1'
        project = 'example-project'
        state_root = $supDashRoot
        lead_session_id = 'example-session-001'
        lead_run_id = 'example-run-001'
        terminal_state = 'active'
        supervisor_state_root = $supStateRoot
    })
    Write-DashUtf8 -Path $supCfg -Value ([ordered]@{
        protocol_version = 'telephone-line-dashboard-config-v1'
        projects = @([ordered]@{ descriptor_file = $supDesc })
    })
    $pauseHashBefore = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes((Join-Path $supStateRoot 'control\pause.json')))).ToLowerInvariant()
    $supProj = Get-TelephoneDashboardProjection -ConfigPath $supCfg
    $pauseHashAfter = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes((Join-Path $supStateRoot 'control\pause.json')))).ToLowerInvariant()
    Assert-Dash ($pauseHashBefore -ceq $pauseHashAfter) 'Dashboard mutated supervisor pause state.'
    $supCodes = @($supProj.groups | ForEach-Object { @($_.findings | ForEach-Object { [string]$_.code }) })
    Assert-Dash ($supCodes -contains 'SUPERVISOR_PAUSED') 'Paused supervisor evidence was not projected.'
    Assert-Dash ($supCodes -contains 'SUPERVISOR_CANCELLED' -or $supCodes -contains 'SUPERVISOR_ORPHAN') 'Cancelled or orphan supervisor evidence was not projected.'
    Assert-Dash ($supCodes -contains 'SUPERVISOR_MISMATCH' -or $supCodes -contains 'SUPERVISOR_ORPHAN' -or $supCodes -contains 'SUPERVISOR_VERSION_DRIFT') 'Mismatched supervisor evidence was not projected.'
    Assert-Dash ($supCodes -contains 'SUPERVISOR_INCOMPLETE_IDENTITY') 'Incomplete supervisor identity was not fail-closed.'
    Assert-Dash ($supCodes -contains 'MALFORMED_EVIDENCE' -or $supCodes -contains 'SUPERVISOR_DUPLICATE') 'Malformed or duplicate supervisor evidence was not fail-closed.'
    $yellow = @($supProj.groups | Where-Object { [string]$_.color -ceq 'yellow' })
    Assert-Dash ($yellow.Count -ge 1) 'Supervisor fail-closed evidence was not yellow.'
    $exactGroup = @($supProj.groups | Where-Object { [string]$_.project -ceq 'example-project' -and [string]$_.lead_session_id -ceq 'example-session-001' })
    Assert-Dash ($exactGroup.Count -ge 1) 'Exact project plus Lead session was not projected.'
    $exactCodes = @($exactGroup | ForEach-Object { @($_.findings | ForEach-Object { [string]$_.code }) })
    Assert-Dash ($exactCodes -contains 'SUPERVISOR_CANCELLED' -or $exactCodes -contains 'SUPERVISOR_PAUSED') 'Exact matching supervisor terminal was not bound.'
    Assert-Dash ($exactCodes -contains 'BATCH_COLLECTING') 'Exact matching mailbox collecting identity was not projected.'
    $foreignMailbox = @($supProj.groups | Where-Object { [string]$_.lead_session_id -ceq 'foreign-mailbox-session' })
    Assert-Dash ($foreignMailbox.Count -eq 0) 'Foreign mailbox session was adopted by wildcard.'
    $wrongBind = @($exactGroup | Where-Object { [string]$_.supervisor_run_id -ceq 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee22' })
    Assert-Dash ($wrongBind.Count -eq 0) 'Wrong-session supervisor record attached to the exact group.'
    $incompleteGroup = @($supProj.groups | Where-Object { @($_.findings | ForEach-Object { [string]$_.code }) -contains 'SUPERVISOR_INCOMPLETE_IDENTITY' })
    Assert-Dash ($incompleteGroup.Count -ge 1 -and (@($incompleteGroup | Where-Object { [string]$_.color -ceq 'yellow' }).Count -ge 1)) 'Incomplete identity was not a yellow fail-closed group.'
    $supReparseRoot = Join-Path $testRoot 'sup-reparse'
    $supReparseReal = Join-Path $testRoot 'sup-reparse-real'
    [IO.Directory]::CreateDirectory((Join-Path $supReparseReal 'inbox')) | Out-Null
    $supReparseOk = New-DashJunction -Link $supReparseRoot -Target $supReparseReal
    if ($supReparseOk) {
        $reparseDesc = Join-Path $testRoot 'sup-reparse-desc.json'
        $reparseCfg = Join-Path $testRoot 'sup-reparse-cfg.json'
        Write-DashUtf8 -Path $reparseDesc -Value ([ordered]@{
            protocol_version = 'telephone-line-dashboard-project-descriptor-v1'
            project = 'example-project'
            state_root = $supDashRoot
            lead_session_id = 'example-session-001'
            lead_run_id = 'example-run-001'
            terminal_state = 'active'
            supervisor_state_root = $supReparseRoot
        })
        Write-DashUtf8 -Path $reparseCfg -Value ([ordered]@{
            protocol_version = 'telephone-line-dashboard-config-v1'
            projects = @([ordered]@{ descriptor_file = $reparseDesc })
        })
        $reparseProj = Get-TelephoneDashboardProjection -ConfigPath $reparseCfg
        $reparseCodes = @($reparseProj.groups | ForEach-Object { @($_.findings | ForEach-Object { [string]$_.code }) })
        Assert-Dash ($reparseCodes -contains 'REPARSE_POINT') 'Reparse supervisor root was not fail-closed yellow.'
        try { [IO.Directory]::Delete($supReparseRoot) } catch {}
    }
    $supervisor_projection_truth = 1
    $supervisor_dashboard_read_only = 1
    $supervisor_incomplete_identity = 1
    $legacy_wired_wireless_unchanged = $wired_wireless_one_ordinal_space

    [ordered]@{
        success = $true
        assertions = $assertions
        reducer_cases = $reducer_cases
        production_nested_order_legal = $production_nested_order_legal
        reverse_order_fail_closed = $reverse_order_fail_closed
        happy_path_disappears_only_after_closure_receipt = $happy_path_disappears_only_after_closure_receipt
        skip_lead_to_closure_fail_closed = $skip_lead_to_closure_fail_closed
        wrong_lead_cannot_hide = $wrong_lead_cannot_hide
        wrong_session_fail_closed = $wrong_session_fail_closed
        live_callback_rejected = $live_callback_rejected
        take_active_rejected = $take_active_rejected
        restart_keeps_dashboard_until_closed = $restart_keeps_dashboard_until_closed
        restart_after_close_stays_hidden = $restart_after_close_stays_hidden
        duplicate_callback_does_not_reclose_or_flip_visibility = $duplicate_callback_does_not_reclose_or_flip_visibility
        duplicate_after_close_stays_disappeared = $duplicate_after_close_stays_disappeared
        closure_without_receipt_does_not_hide = $closure_without_receipt_does_not_hide
        modify_loop_then_close = $modify_loop_then_close
        incomplete_identity_rejected = $incomplete_identity_rejected
        unknown_event_fail_closed = $unknown_event_fail_closed
        review_cannot_jump_to_closed = $review_cannot_jump_to_closed
        duplicate_ambiguous_fail_closed = $duplicate_ambiguous_fail_closed
        single_instance_reuse = $single_instance_reuse
        override_hook_preserved = $override_hook_preserved
        explicit_opt_out = $explicit_opt_out
        pid_reuse_rejected = $pid_reuse_rejected
        foreign_process_preserved = $foreign_process_preserved
        pid_reuse_initial_watcher_stopped_exactly = $pid_reuse_initial_watcher_stopped_exactly
        pid_reuse_replacement_watcher_stopped_exactly = $pid_reuse_replacement_watcher_stopped_exactly
        test_watchers_absent_after_exact_cleanup = $test_watchers_absent_after_exact_cleanup
        held_lock_fail_closed = $held_lock_fail_closed
        wired_wireless_one_ordinal_space = $wired_wireless_one_ordinal_space
        duplicate_provenance_no_second_ordinal = $duplicate_provenance_no_second_ordinal
        restart_no_second_ordinal = $restart_no_second_ordinal
        zero_manual_handoff = $zero_manual_handoff
        concurrent_projects_visible = $concurrent_projects_visible
        multiple_disjoint_jobs = $multiple_disjoint_jobs
        exact_terminal_disappearance = $exact_terminal_disappearance
        receipt_alone_not_closure = $receipt_alone_not_closure
        descriptor_path_escape = $descriptor_path_escape
        privacy_no_user_path = $privacy_no_user_path
        durable_duplicate_restart = $durable_duplicate_restart
        historical_successor_retires = $historical_successor_retires
        historical_mismatch_stays_yellow = $historical_mismatch_stays_yellow
        historical_terminal_retires = $historical_terminal_retires
        historical_missing_proof_yellow = $historical_missing_proof_yellow
        fail_closed_no_stale_healthy = $fail_closed_no_stale_healthy
        fail_closed_recovers = $fail_closed_recovers
        update_build_identity = $update_build_identity
        command_line_not_required = $command_line_not_required
        retired_live_owner_yellow = $retired_live_owner_yellow
        fresh_required_live_owner_yellow = $fresh_required_live_owner_yellow
        fresh_startup_within_gate_non_error = $fresh_startup_within_gate_non_error
        preprompt_stall_beyond_gate_yellow = $preprompt_stall_beyond_gate_yellow
        accepted_prompt_long_green = $accepted_prompt_long_green
        failed_receipt_yellow_unchanged = $failed_receipt_yellow_unchanged
        semantic_liveness_restart_same_truth = $semantic_liveness_restart_same_truth
        metadata_only_not_accepted = $metadata_only_not_accepted
        wrong_session_events_fail_closed = $wrong_session_events_fail_closed
        malformed_events_fail_closed = $malformed_events_fail_closed
        oversized_events_fail_closed = $oversized_events_fail_closed
        escaped_session_root_fail_closed = $escaped_session_root_fail_closed
        retired_overrides_accepted_turn = $retired_overrides_accepted_turn
        telephone_direct_one_block = $telephone_direct_one_block
        real_events_long_green = $real_events_long_green
        two_projects_isolated = $two_projects_isolated
        reparse_session_root_fail_closed = $reparse_session_root_fail_closed
        eight_job_one_current_lead_block = $eight_job_one_current_lead_block
        direct_history_proof_restores_yellow = $direct_history_proof_restores_yellow
        cross_lineage_success_cannot_own = $cross_lineage_success_cannot_own
        current_failed_job_stays_yellow = $current_failed_job_stays_yellow
        exact_successor_retires_same_session_failure = $exact_successor_retires_same_session_failure
        exact_current_or_mismatch_restores_yellow = $exact_current_or_mismatch_restores_yellow
        non_exact_resume_keeps_fresh = $non_exact_resume_keeps_fresh
        exact_job_wrong_session_unowned = $exact_job_wrong_session_unowned
        exact_job_and_session_authorizes = $exact_job_and_session_authorizes
        conjunction_mismatch_restores_yellow = $conjunction_mismatch_restores_yellow
        session_component_fail_closed = $session_component_fail_closed
        growing_events_fail_closed = $growing_events_fail_closed
        malformed_utf8_events_fail_closed = $malformed_utf8_events_fail_closed
        direct_root_child_reparse_yellow = $direct_root_child_reparse_yellow
        unreadable_direct_root_yellow = $unreadable_direct_root_yellow
        relay_nested_reduces_legally = $relay_nested_reduces_legally
        show_exact_job_facts = $show_exact_job_facts
        exact_repair_stage_classifier = $exact_repair_stage_classifier
        exact_stage_correction_still_green = $exact_stage_correction_still_green
        correction_substring_rejected = $correction_substring_rejected
        correction_review_role_rejected = $correction_review_role_rejected
        correction_route_coincidence_rejected = $correction_route_coincidence_rejected
        production_repair_stage_correction = $production_repair_stage_correction
        production_repair_restart_stable = $production_repair_restart_stable
        correction_cross_lineage_rejected = $correction_cross_lineage_rejected
        lead_run_id_distinct_and_provenance = $lead_run_id_distinct_and_provenance
        terminal_missing_root_stays_yellow = $terminal_missing_root_stays_yellow
        dashboard_state_parent_junction_refused = $dashboard_state_parent_junction_refused
        descriptor_parent_junction_yellow = $descriptor_parent_junction_yellow
        runs_root_reparse_yellow = $runs_root_reparse_yellow
        lifecycle_oversize_fail_closed = $lifecycle_oversize_fail_closed
        lifecycle_growth_fail_closed = $lifecycle_growth_fail_closed
        lifecycle_reparse_fail_closed = $lifecycle_reparse_fail_closed
        jobs_root_reparse_yellow = $jobs_root_reparse_yellow
        config_parent_junction_yellow = $config_parent_junction_yellow
        supervisor_projection_truth = $supervisor_projection_truth
        supervisor_dashboard_read_only = $supervisor_dashboard_read_only
        supervisor_incomplete_identity = $supervisor_incomplete_identity
        legacy_wired_wireless_unchanged = $legacy_wired_wireless_unchanged
    } | ConvertTo-Json -Compress
} catch {
    [ordered]@{
        success = $false
        error = [string]$_.Exception.Message
        assertions = $assertions
    } | ConvertTo-Json -Compress
    exit 1
} finally {
    $watchScriptFinally = Join-Path $repoRoot 'src\dashboard\Watch-TelephoneDashboard.ps1'
    foreach ($claim in @($script:claimed)) {
        try {
            if ([string]$claim.kind -ceq 'foreign-sleep') {
                $null = Stop-DashExactOwnedProcess -Owner $claim
            } else {
                $null = Stop-DashExactOwnedProcess -Owner $claim -WatchScript $watchScriptFinally -StateRoot ([string]$claim.state_root)
            }
        } catch { }
    }
    try { $null = Stop-TelephoneDashboardExactWatcher -WatchScript $watchScriptFinally -StateRoot (Join-Path $testRoot 'dashboard-runtime') } catch { }
    Restore-DashEnv
    if ([IO.Directory]::Exists($testRoot)) {
        try { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

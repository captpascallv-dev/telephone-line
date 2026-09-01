# SPDX-License-Identifier: MPL-2.0
# Current Understanding (execution, 2026-08-27 caller preservation):
# 1. Phase: close proven caller-kill FAIL on candidate c1aab14; preserve accepted runtime/source and passing proofs; amend the same one commit over 6c9d25e.
# 2. Denominator: cleanup stops only test-owned start/resume PID+ticks identities; invocation ancestors and unowned command-line matches are never added to the kill set. No product-semantic change.
# 3. Only next step: identity-correct ownership in this test, prove the parent caller survives, amend the same candidate.
# 4. Frozen non-goals: no production source mutation, activation, smoke, App Server/dashboard writes.
# 5. Exit: caller-preservation + AEC zero test-owned residue + frozen focused union, clean one commit over 6c9d25e, self_accepted=false; not project PASS.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TestRoot,
    [switch]$CallerPreservationHarness
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PreviousDashboardProcessEnvOnly = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY', 'Process')
$script:PreviousDashboardOptOut = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', 'Process')
[Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY', '1', 'Process')
[Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', '1', 'Process')
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$powerShellPath = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
$selfProcessId = [int]$PID

if ($CallerPreservationHarness) {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $selfProc = Get-Process -Id $selfProcessId
    try {
        $caller = [ordered]@{
            pid = [int]$selfProcessId
            start_time_utc_ticks = [int64]$selfProc.StartTime.ToUniversalTime().Ticks
        }
    } finally {
        $selfProc.Dispose()
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $powerShellPath
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-TestRoot', $testRoot)) {
        [void]$info.ArgumentList.Add([string]$argument)
    }
    $child = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $child.StandardOutput.ReadToEnd()
        $stderr = $child.StandardError.ReadToEnd()
        $child.WaitForExit()
        $childCode = [int]$child.ExitCode
    } finally {
        $child.Dispose()
    }
    $after = Get-Process -Id $selfProcessId -ErrorAction SilentlyContinue
    if ($null -eq $after) { throw 'Caller process vanished during the child test.' }
    try {
        $afterTicks = [int64]$after.StartTime.ToUniversalTime().Ticks
    } finally {
        $after.Dispose()
    }
    if ($afterTicks -ne [int64]$caller.start_time_utc_ticks) { throw 'Caller process identity changed during the child test.' }
    $hits = [Collections.Generic.List[object]]::new()
    $filter = "Name = 'pwsh.exe' OR Name = 'powershell.exe'"
    foreach ($cim in @(Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction SilentlyContinue)) {
        $pidValue = [int]$cim.ProcessId
        if ($pidValue -eq $selfProcessId) { continue }
        $command = [string]$cim.CommandLine
        if ([string]::IsNullOrWhiteSpace($command)) { continue }
        if ($command.IndexOf($testRoot, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $hits.Add([ordered]@{ pid = $pidValue })
    }
    if ($childCode -ne 0) { throw "Child autonomous-chain test failed ($childCode): $stderr $stdout" }
    if ([IO.Directory]::Exists($testRoot)) { throw 'Child test left the isolated root behind.' }
    if ($hits.Count -ne 0) { throw ('Child test left matching processes: ' + (($hits | ConvertTo-Json -Compress))) }
    $childJson = $null
    try { $childJson = $stdout | ConvertFrom-Json -AsHashtable -Depth 16 } catch { }
    [ordered]@{
        success = $true
        caller_preserved = 1
        caller_pid = [int]$caller.pid
        caller_start_time_utc_ticks = [int64]$caller.start_time_utc_ticks
        child_success = if ($null -ne $childJson -and $childJson.Contains('success')) { [bool]$childJson.success } else { $true }
        child_assertions = if ($null -ne $childJson -and $childJson.Contains('assertions')) { [int]$childJson.assertions } else { 0 }
        residue_root_processes = 0
        test_root_absent = 1
    } | ConvertTo-Json -Compress
    exit 0
}

. (Join-Path $repoRoot 'src\core\TelephoneLine.Common.ps1')
. (Join-Path $repoRoot 'tests\adapters\AdapterTest.Common.ps1')
$starter = Join-Path $repoRoot 'src\core\Start-TelephoneLineJob.ps1'
$resume = Join-Path $repoRoot 'src\core\Resume-TelephoneLines.ps1'
$mockRoute = Join-Path $PSScriptRoot 'fixtures\mock-route.ps1'
$mockLead = Join-Path $PSScriptRoot 'fixtures\mock-lead-launcher.ps1'
$ownerSession = '01a00000-0000-7000-8000-00000000own1'
$targetSession = '01a00000-0000-7000-8000-00000000tgt1'
$assertions = 0
$trackedOwners = [Collections.Generic.List[object]]::new()
$crashRecoveries = 0
$duplicateTurns = 0
$ancestorIdentities = [Collections.Generic.List[object]]::new()

function Assert-Aec {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Wait-AecPath {
    param([string]$Path, [int]$Seconds = 30)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($Seconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if ([IO.File]::Exists($Path)) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for $Path"
}

function Get-AecSessionTurnCount {
    param([string]$Path, [string]$SessionId)
    if (-not [IO.File]::Exists($Path)) { return 0 }
    $count = 0
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $row = $line | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
        if ([string]$row.session_id -ceq $SessionId) { $count += 1 }
    }
    return $count
}

function Get-AecProcessIdentity {
    param([int]$ProcessId)
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $proc) { return $null }
    try {
        return [ordered]@{
            pid = [int]$ProcessId
            start_time_utc_ticks = [int64]$proc.StartTime.ToUniversalTime().Ticks
        }
    } finally {
        $proc.Dispose()
    }
}

function Initialize-AecAncestors {
    $current = $selfProcessId
    for ($i = 0; $i -lt 16; $i++) {
        $identity = Get-AecProcessIdentity -ProcessId $current
        if ($null -eq $identity) { break }
        $already = $false
        foreach ($existing in @($ancestorIdentities)) {
            if ([int]$existing.pid -eq [int]$identity.pid -and [int64]$existing.start_time_utc_ticks -eq [int64]$identity.start_time_utc_ticks) { $already = $true; break }
        }
        if (-not $already) { [void]$ancestorIdentities.Add($identity) }
        $cim = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = " + [int]$current) -ErrorAction SilentlyContinue
        if ($null -eq $cim) { break }
        $parentId = [int]$cim.ParentProcessId
        if ($parentId -le 0 -or $parentId -eq $current) { break }
        $current = $parentId
    }
}

function Test-AecIsProtectedIdentity {
    param($Owner)
    if ($null -eq $Owner -or $Owner -isnot [Collections.IDictionary] -or -not $Owner.Contains('pid')) { return $false }
    $pidValue = [int]$Owner.pid
    $ticks = [int64]0
    $hasTicks = $Owner.Contains('start_time_utc_ticks')
    if ($hasTicks) { $ticks = [int64]$Owner.start_time_utc_ticks }
    foreach ($ancestor in @($ancestorIdentities)) {
        if ([int]$ancestor.pid -ne $pidValue) { continue }
        if ($hasTicks -and [int64]$ancestor.start_time_utc_ticks -ne $ticks) { continue }
        return $true
    }
    return $false
}

function Add-AecTracked {
    param($Owner, [string]$Kind)
    if ($null -eq $Owner) { return }
    if ($Owner -isnot [Collections.IDictionary] -or -not $Owner.Contains('pid')) { return }
    if (Test-AecIsProtectedIdentity -Owner $Owner) { return }
    $pidValue = [int]$Owner.pid
    $ticks = [int64]0
    if ($Owner.Contains('start_time_utc_ticks')) { $ticks = [int64]$Owner.start_time_utc_ticks }
    foreach ($existing in @($trackedOwners)) {
        if ([int]$existing.pid -eq $pidValue -and [int64]$existing.start_time_utc_ticks -eq $ticks) { return }
    }
    $trackedOwners.Add([ordered]@{
        pid = $pidValue
        start_time_utc_ticks = $ticks
        kind = [string]$Kind
    })
}

function Get-AecLiveTracked {
    $live = [Collections.Generic.List[object]]::new()
    foreach ($owner in @($trackedOwners)) {
        if (Test-TelephoneOwnerAlive -Owner $owner) { [void]$live.Add($owner) }
    }
    return @($live)
}

function Get-AecRootProcesses {
    param([switch]$IncludeProtected)
    $rootNorm = $testRoot
    $rows = [Collections.Generic.List[object]]::new()
    $filter = "Name = 'pwsh.exe' OR Name = 'powershell.exe'"
    foreach ($cim in @(Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction SilentlyContinue)) {
        $pidValue = [int]$cim.ProcessId
        $command = [string]$cim.CommandLine
        if ([string]::IsNullOrWhiteSpace($command)) { continue }
        if ($command.IndexOf($rootNorm, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
        if ($null -eq $proc) { continue }
        try {
            $ticks = [int64]$proc.StartTime.ToUniversalTime().Ticks
        } catch {
            continue
        } finally {
            if ($null -ne $proc) { $proc.Dispose() }
        }
        $identity = [ordered]@{ pid = $pidValue; start_time_utc_ticks = $ticks; kind = 'root_command' }
        if (-not $IncludeProtected -and (Test-AecIsProtectedIdentity -Owner $identity)) { continue }
        $rows.Add($identity)
    }
    return @($rows)
}

function Scan-AecDurableOwners {
    param([string]$JobRoot)
    if ([string]::IsNullOrWhiteSpace($JobRoot) -or -not [IO.Directory]::Exists($JobRoot)) { return }
    $paths = Get-TelephoneJobPaths -JobRoot $JobRoot
    foreach ($name in @('command_owner', 'relay_owner')) {
        $path = [string]$paths[$name]
        if ([IO.File]::Exists($path)) {
            try { Add-AecTracked -Owner (Read-TelephoneJson -Path $path).value -Kind $name } catch { }
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $JobRoot -File -Filter 'relay-resume-*.json' -ErrorAction SilentlyContinue)) {
        try { Add-AecTracked -Owner (Read-TelephoneJson -Path $file.FullName).value -Kind 'relay_resume' } catch { }
    }
}

function Scan-AecLeadOwners {
    param([string]$LeadRuns)
    if ([string]::IsNullOrWhiteSpace($LeadRuns) -or -not [IO.Directory]::Exists($LeadRuns)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $LeadRuns -Recurse -File -Filter 'owner.json' -ErrorAction SilentlyContinue)) {
        try { Add-AecTracked -Owner (Read-TelephoneJson -Path $file.FullName).value -Kind 'lead_owner' } catch { }
    }
}

function Wait-AecTrackedQuiescence {
    param([int]$Seconds = 20)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($Seconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $liveTracked = @(Get-AecLiveTracked)
        if ($liveTracked.Count -eq 0) { return @() }
        Start-Sleep -Milliseconds 100
    }
    return @(Get-AecLiveTracked)
}

function Scan-AecMailboxOwners {
    param([string]$StateRoot)
    if ([string]::IsNullOrWhiteSpace($StateRoot)) { return }
    $leadsRoot = Join-Path $StateRoot 'leads'
    if (-not [IO.Directory]::Exists($leadsRoot)) { return }
    foreach ($leadDir in @(Get-ChildItem -LiteralPath $leadsRoot -Directory -ErrorAction SilentlyContinue)) {
        $ownerPath = Join-Path $leadDir.FullName 'owner.json'
        if ([IO.File]::Exists($ownerPath)) {
            try { Add-AecTracked -Owner (Read-TelephoneJson -Path $ownerPath).value -Kind 'mailbox_owner' } catch { }
        }
    }
}

function Observe-AecAfterTerminal {
    param([string]$JobRoot, [string]$LeadRuns)
    Scan-AecDurableOwners -JobRoot $JobRoot
    Scan-AecLeadOwners -LeadRuns $LeadRuns
    try {
        $stateRoot = Get-TelephoneStateRootFromJobRoot -JobRoot $JobRoot
        Scan-AecMailboxOwners -StateRoot $stateRoot
    } catch { }
    $live = @(Wait-AecTrackedQuiescence -Seconds 20)
    $unowned = @(Get-AecRootProcesses)
    Assert-Aec ($live.Count -eq 0) ("Test-owned processes did not naturally quiesce after terminal: " + (($live | ConvertTo-Json -Compress)))
    Assert-Aec ($unowned.Count -eq 0) ("Unowned root command-line processes survived terminal: " + (($unowned | ConvertTo-Json -Compress)))
}

function Invoke-AecResume {
    param([string]$StateRoot)
    $null = & $powerShellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $resume -StateRoot $StateRoot
    $jobsRoot = Join-Path $StateRoot 'jobs'
    if (-not [IO.Directory]::Exists($jobsRoot)) { return }
    foreach ($job in @(Get-ChildItem -LiteralPath $jobsRoot -Directory -ErrorAction SilentlyContinue)) {
        Scan-AecDurableOwners -JobRoot $job.FullName
    }
    Scan-AecMailboxOwners -StateRoot $StateRoot
}

function Stop-AecTracked {
    foreach ($owner in @($trackedOwners)) {
        if (-not (Test-TelephoneOwnerAlive -Owner $owner)) { continue }
        try { Stop-Process -Id ([int]$owner.pid) -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function New-AecCaseRoot {
    param([string]$Name)
    $root = Join-Path $testRoot $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $root 'worktree')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $root 'lead-runs')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $root 'telephone-state')) | Out-Null
    return $root
}

function Start-AecNestedJob {
    param(
        [Parameter(Mandatory = $true)][string]$CaseRoot,
        [string]$TerminalState = 'completed',
        [string]$HoldTerminal = '',
        [string]$CrashAfter = '',
        [bool]$IncludeNested = $true,
        [string]$NestedSession = $targetSession,
        [int]$DelayTerminalMs = 0
    )
    $stateRoot = Join-Path $CaseRoot 'telephone-state'
    $worktree = Join-Path $CaseRoot 'worktree'
    $turnLog = Join-Path $CaseRoot 'lead-turns.jsonl'
    $leadLog = Join-Path $CaseRoot 'lead-calls.jsonl'
    $leadRuns = Join-Path $CaseRoot 'lead-runs'
    $counter = Join-Path $CaseRoot 'route-count.txt'
    $env:TELEPHONE_TEST_LEAD_LOG = $leadLog
    $env:TELEPHONE_TEST_LEAD_RUNS = $leadRuns
    $env:TELEPHONE_TEST_LEAD_TURNS = $turnLog
    if ([string]::IsNullOrWhiteSpace($HoldTerminal)) {
        Remove-Item -Path env:TELEPHONE_TEST_LEAD_HOLD_TERMINAL -ErrorAction SilentlyContinue
    } else {
        $env:TELEPHONE_TEST_LEAD_HOLD_TERMINAL = $HoldTerminal
    }
    $env:TELEPHONE_TEST_LEAD_TERMINAL_STATE = $TerminalState
    if ([string]::IsNullOrWhiteSpace($CrashAfter)) {
        Remove-Item -Path env:TELEPHONE_TEST_RELAY_CRASH_AFTER -ErrorAction SilentlyContinue
    } else {
        $env:TELEPHONE_TEST_RELAY_CRASH_AFTER = $CrashAfter
    }
    if ([int]$DelayTerminalMs -gt 0) {
        $env:TELEPHONE_TEST_LEAD_DELAY_TERMINAL_MS = [string]$DelayTerminalMs
        $env:TELEPHONE_TEST_LEAD_DELAY_TERMINAL_SESSION = $targetSession
    } else {
        Remove-Item -Path env:TELEPHONE_TEST_LEAD_DELAY_TERMINAL_MS -ErrorAction SilentlyContinue
        Remove-Item -Path env:TELEPHONE_TEST_LEAD_DELAY_TERMINAL_SESSION -ErrorAction SilentlyContinue
    }
    $jobId = [Guid]::NewGuid().ToString('D')
    $requestPath = Join-Path $CaseRoot "request-$jobId.json"
    $request = [ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = $jobId
        project = 'telephone-aec'
        stage = 'NESTED'
        role = 'execution'
        route = 'mock-route'
        summary = 'nested-target-to-owner'
        lead = [ordered]@{
            protocol_version = 'telephone-line-lead-binding-v1'
            session_id = $ownerSession
            worktree = $worktree
            launcher = [ordered]@{
                path = $mockLead
                arguments = @()
            }
        }
        command = [ordered]@{
            executable = $powerShellPath
            working_directory = $CaseRoot
            arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $mockRoute, '-CounterPath', $counter, '-DelayMilliseconds', '50', '-FinalText', 'DONE-NESTED')
        }
    }
    if ([bool]$IncludeNested) {
        $request['nested_target'] = [ordered]@{
            protocol_version = 'telephone-line-lead-binding-v1'
            session_id = $NestedSession
            worktree = $worktree
            launcher = [ordered]@{
                path = $mockLead
                arguments = @()
            }
        }
    }
    $null = Write-TelephoneJsonCreateNew -Path $requestPath -Value $request
    $startedText = & $powerShellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $starter -RequestFile $requestPath -StateRoot $stateRoot
    if ($LASTEXITCODE -ne 0) { throw "Start-TelephoneLineJob failed: $startedText" }
    $started = ($startedText -join "`n") | ConvertFrom-Json -AsHashtable -Depth 16
    if ($started.Contains('command_owner')) { Add-AecTracked -Owner $started.command_owner -Kind 'command_owner' }
    if ($started.Contains('relay_owner')) { Add-AecTracked -Owner $started.relay_owner -Kind 'relay_owner' }
    Scan-AecDurableOwners -JobRoot ([string]$started.job_root)
    return [ordered]@{
        started = $started
        job_root = [string]$started.job_root
        paths = (Get-TelephoneJobPaths -JobRoot ([string]$started.job_root))
        turn_log = $turnLog
        state_root = $stateRoot
        lead_runs = $leadRuns
        counter = $counter
    }
}

try {
    Initialize-AecAncestors
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $commonSource = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\core\TelephoneLine.Common.ps1'), [Text.UTF8Encoding]::new($false, $true))
    $relaySource = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\core\Invoke-TelephoneLineRelay.ps1'), [Text.UTF8Encoding]::new($false, $true))
    $officialStart = $commonSource.IndexOf('function Wait-TelephoneLeadOfficialTerminal')
    $officialEnd = $commonSource.IndexOf('function Write-TelephoneLifecycleStatus')
    Assert-Aec ($officialStart -ge 0 -and $officialEnd -gt $officialStart) 'Official-terminal wait helper is missing.'
    $officialFn = $commonSource.Substring($officialStart, $officialEnd - $officialStart)
    Assert-Aec ($officialFn -notmatch 'StartupTimeoutSeconds') 'Official-terminal wait still takes a startup timeout.'
    Assert-Aec ($officialFn -notmatch 'AddSeconds') 'Official-terminal wait still computes a deadline.'
    Assert-Aec ($officialFn -notmatch 'startup window') 'Official-terminal wait still throws on elapsed time.'
    Assert-Aec ($relaySource -notmatch 'Wait-TelephoneLeadOfficialTerminal[^\r\n]*StartupTimeoutSeconds') 'Nested hop still passes a terminal timeout.'

    $direct = Start-AecNestedJob -CaseRoot (New-AecCaseRoot 'direct-owner') -IncludeNested $false
    Assert-Aec ([bool]$direct.started.dispatched) 'Direct owner dispatch did not start.'
    Wait-AecPath $direct.paths.delivery
    $directDelivery = (Read-TelephoneJson -Path $direct.paths.delivery).value
    Assert-Aec ([string]$directDelivery.lead_session_id -ceq $ownerSession) 'Direct owner delivery used another session.'
    Assert-Aec ((Get-AecSessionTurnCount $direct.turn_log $ownerSession) -eq 1) 'Direct owner was not woken exactly once.'
    Assert-Aec ((Get-AecSessionTurnCount $direct.turn_log $targetSession) -eq 0) 'Direct owner job woke a nested target.'
    Assert-Aec (-not [IO.File]::Exists($direct.paths.nested_terminal)) 'Direct owner job published a nested terminal.'
    $directStatus = (Read-TelephoneJson -Path $direct.paths.lifecycle_status).value
    Assert-Aec ([string]$directStatus.phase -ceq 'delivered') 'Direct owner lifecycle did not retire at delivery.'
    Assert-Aec ([bool]$directStatus.idle -eq $false) 'Direct owner lifecycle was idle at delivery.'
    Observe-AecAfterTerminal -JobRoot $direct.job_root -LeadRuns $direct.lead_runs

    $happy = Start-AecNestedJob -CaseRoot (New-AecCaseRoot 'nested-completed')
    Assert-Aec ([bool]$happy.started.dispatched) 'Nested dispatch did not start.'
    Wait-AecPath $happy.paths.receipt
    $midStatus = $null
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if ([IO.File]::Exists($happy.paths.lifecycle_status)) {
            $midStatus = (Read-TelephoneJson -Path $happy.paths.lifecycle_status).value
            if ([bool]$midStatus.idle -eq $false) { break }
        }
        Start-Sleep -Milliseconds 50
    }
    Assert-Aec ($null -ne $midStatus -and [bool]$midStatus.idle -eq $false) 'Nested hop projected an idle dashboard gap.'
    Wait-AecPath $happy.paths.nested_terminal 40
    Wait-AecPath $happy.paths.delivery 40
    Assert-Aec ([IO.File]::Exists($happy.paths.nested_terminal)) 'Owner delivery ran without a nested official terminal.'
    $nested = (Read-TelephoneJson -Path $happy.paths.nested_terminal).value
    Assert-Aec ([string]$nested.session_id -ceq $targetSession) 'Nested terminal did not bind the target session.'
    Assert-Aec ([string]$nested.state -ceq 'completed') 'Nested completed terminal was not official.'
    $delivery = (Read-TelephoneJson -Path $happy.paths.delivery).value
    Assert-Aec ([string]$delivery.lead_session_id -ceq $ownerSession) 'Owner delivery used the nested target session.'
    $targetTurns = Get-AecSessionTurnCount $happy.turn_log $targetSession
    $ownerTurns = Get-AecSessionTurnCount $happy.turn_log $ownerSession
    Assert-Aec ($targetTurns -eq 1) ("Nested target turns=$targetTurns")
    Assert-Aec ($ownerTurns -eq 1) ("Owning Lead turns=$ownerTurns")
    $status = (Read-TelephoneJson -Path $happy.paths.lifecycle_status).value
    Assert-Aec ([string]$status.phase -ceq 'delivered') 'Lifecycle did not retire at owner delivery.'
    $idleProbe = Test-TelephoneLifecycleIdleGap -JobRoot $happy.job_root
    Assert-Aec ([bool]$idleProbe.idle_gap -eq $false) 'Live nested hop was treated as an idle gap.'
    Invoke-AecResume -StateRoot $happy.state_root
    Start-Sleep -Milliseconds 300
    Assert-Aec ((Get-AecSessionTurnCount $happy.turn_log $targetSession) -eq 1) 'Resume started a second nested target turn.'
    Assert-Aec ((Get-AecSessionTurnCount $happy.turn_log $ownerSession) -eq 1) 'Resume started a second owner turn.'
    Observe-AecAfterTerminal -JobRoot $happy.job_root -LeadRuns $happy.lead_runs

    $delayed = Start-AecNestedJob -CaseRoot (New-AecCaseRoot 'nested-delayed-terminal') -DelayTerminalMs 3000
    Wait-AecPath $delayed.paths.nested_wake_attempt 40
    Start-Sleep -Milliseconds 1200
    Assert-Aec (-not [IO.File]::Exists($delayed.paths.nested_terminal)) 'Delayed nested target published a terminal before the official wait elapsed.'
    Assert-Aec (-not [IO.File]::Exists($delayed.paths.delivery)) 'Owner was woken before the delayed nested official terminal.'
    Assert-Aec (-not [IO.File]::Exists($delayed.paths.relay_error)) 'Elapsed nested official wait emitted a relay error.'
    Wait-AecPath $delayed.paths.nested_terminal 40
    Wait-AecPath $delayed.paths.delivery 40
    Assert-Aec ((Get-AecSessionTurnCount $delayed.turn_log $targetSession) -eq 1) 'Delayed nested target started extra turns.'
    Assert-Aec ((Get-AecSessionTurnCount $delayed.turn_log $ownerSession) -eq 1) 'Delayed nested owner was not woken once.'
    Observe-AecAfterTerminal -JobRoot $delayed.job_root -LeadRuns $delayed.lead_runs

    foreach ($term in @('failed', 'interrupted')) {
        $case = Start-AecNestedJob -CaseRoot (New-AecCaseRoot ("nested-" + $term)) -TerminalState $term
        Wait-AecPath $case.paths.nested_terminal 40
        Wait-AecPath $case.paths.delivery 40
        $nestedTerm = (Read-TelephoneJson -Path $case.paths.nested_terminal).value
        Assert-Aec ([string]$nestedTerm.state -ceq $term) ("Nested $term terminal was not official.")
        $termDelivery = (Read-TelephoneJson -Path $case.paths.delivery).value
        Assert-Aec ([string]$termDelivery.lead_session_id -ceq $ownerSession) ("Nested $term did not return to the owner.")
        Assert-Aec ((Get-AecSessionTurnCount $case.turn_log $targetSession) -eq 1) ("Nested $term target turns")
        Assert-Aec ((Get-AecSessionTurnCount $case.turn_log $ownerSession) -eq 1) ("Nested $term owner turns")
        Observe-AecAfterTerminal -JobRoot $case.job_root -LeadRuns $case.lead_runs
    }

    $mismatchRoot = New-AecCaseRoot 'identity-mismatch'
    $mismatchFailed = $false
    try {
        $null = Start-AecNestedJob -CaseRoot $mismatchRoot -NestedSession $ownerSession
    } catch {
        $mismatchFailed = $true
    }
    Assert-Aec $mismatchFailed 'Owner/target identity mismatch was accepted.'

    $ackOnly = Start-AecNestedJob -CaseRoot (New-AecCaseRoot 'ack-without-terminal') -HoldTerminal $targetSession
    Wait-AecPath $ackOnly.paths.receipt 30
    $ackDeadline = [DateTimeOffset]::UtcNow.AddSeconds(12)
    while ([DateTimeOffset]::UtcNow -lt $ackDeadline -and -not [IO.File]::Exists($ackOnly.paths.relay_error)) {
        Start-Sleep -Milliseconds 200
    }
    Assert-Aec ([IO.File]::Exists($ackOnly.paths.relay_error)) 'Ack without terminal was not fail-closed.'
    Assert-Aec (-not [IO.File]::Exists($ackOnly.paths.nested_terminal)) 'Ack was promoted to a nested official terminal.'
    Assert-Aec (-not [IO.File]::Exists($ackOnly.paths.delivery)) 'Owner was delivered after nested ack without a terminal.'
    Assert-Aec ((Get-AecSessionTurnCount $ackOnly.turn_log $ownerSession) -eq 0) 'Owner was woken after nested ack without a terminal.'
    Assert-Aec ((Get-AecSessionTurnCount $ackOnly.turn_log $targetSession) -le 1) 'Ack-without-terminal started extra nested turns.'
    Observe-AecAfterTerminal -JobRoot $ackOnly.job_root -LeadRuns $ackOnly.lead_runs

    foreach ($point in @('nested_send', 'nested_ack', 'nested_terminal', 'owner_send')) {
        $crash = Start-AecNestedJob -CaseRoot (New-AecCaseRoot ("crash-" + $point)) -CrashAfter $point
        Wait-AecPath $crash.paths.receipt 30
        $waitPath = switch ($point) {
            'nested_terminal' { $crash.paths.nested_terminal }
            'owner_send' { $crash.paths.nested_terminal }
            'nested_ack' { $crash.paths.nested_wake_launch_result }
            default { $crash.paths.nested_wake_attempt }
        }
        Wait-AecPath $waitPath 40
        Start-Sleep -Milliseconds 400
        Assert-Aec (-not [IO.File]::Exists($crash.paths.delivery)) ("Crash after $point still published owner delivery.")
        if ($null -ne $crash.started.relay_owner) {
            $crashRelay = $crash.started.relay_owner
            if (Test-TelephoneOwnerAlive -Owner $crashRelay) {
                try { Stop-Process -Id ([int]$crashRelay.pid) -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
        Remove-Item -Path env:TELEPHONE_TEST_RELAY_CRASH_AFTER -ErrorAction SilentlyContinue
        Invoke-AecResume -StateRoot $crash.state_root
        Invoke-AecResume -StateRoot $crash.state_root
        Wait-AecPath $crash.paths.delivery 40
        Wait-AecPath $crash.paths.nested_terminal 10
        $script:crashRecoveries += 1
        $tTurns = Get-AecSessionTurnCount $crash.turn_log $targetSession
        $oTurns = Get-AecSessionTurnCount $crash.turn_log $ownerSession
        if ($tTurns -ne 1 -or $oTurns -ne 1) { $script:duplicateTurns += 1 }
        Assert-Aec ($tTurns -eq 1) ("Crash after $point nested turns=$tTurns")
        Assert-Aec ($oTurns -eq 1) ("Crash after $point owner turns=$oTurns")
        $crashDelivery = (Read-TelephoneJson -Path $crash.paths.delivery).value
        Assert-Aec ([string]$crashDelivery.lead_session_id -ceq $ownerSession) ("Crash after $point delivered to the nested session.")
        Observe-AecAfterTerminal -JobRoot $crash.job_root -LeadRuns $crash.lead_runs
    }

    $gapRoot = Join-Path $testRoot 'synthetic-idle'
    [IO.Directory]::CreateDirectory($gapRoot) | Out-Null
    $gapPaths = Get-TelephoneJobPaths -JobRoot $gapRoot
    $null = Write-TelephoneJsonCreateNew -Path $gapPaths.dispatch -Value ([ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = [Guid]::NewGuid().ToString('D')
        project = 'telephone-aec'
        stage = 'IDLE'
        role = 'execution'
        route = 'mock-route'
        summary = 'synthetic-idle'
        lead = [ordered]@{
            protocol_version = 'telephone-line-lead-binding-v1'
            session_id = $ownerSession
            worktree = (Join-Path $testRoot 'direct-owner\worktree')
            launcher = [ordered]@{ path = $mockLead; arguments = @() }
        }
        command = [ordered]@{
            executable = $powerShellPath
            working_directory = $testRoot
            arguments = @()
            stdin = $null
        }
        source_request = @{ path = $testRoot; bytes = 1; sha256 = '00' }
        lead_binding = @{ path = $testRoot; bytes = 1; sha256 = '00' }
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        absolute_task_timeout = $false
        project_judgment = $false
    })
    $null = Write-TelephoneJsonCreateNew -Path $gapPaths.delivery -Value ([ordered]@{
        protocol_version = 'telephone-line-delivery-v1'
        line_job_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1'
        delivered_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $null = Write-TelephoneLifecycleStatus -Paths $gapPaths -Phase 'nested_target' -Idle $true
    $gap = Test-TelephoneLifecycleIdleGap -JobRoot $gapRoot
    Assert-Aec ([bool]$gap.idle_gap -eq $true) 'Synthetic mid-chain idle gap was not detected.'

    $finalLive = @(Wait-AecTrackedQuiescence -Seconds 20)
    $finalRootLive = @(Get-AecRootProcesses)
    $heldLocks = [Collections.Generic.List[string]]::new()
    if ([IO.Directory]::Exists($testRoot)) {
        foreach ($lockFile in @(Get-ChildItem -LiteralPath $testRoot -Recurse -File -Filter '*.lock' -ErrorAction SilentlyContinue)) {
            $stream = $null
            try {
                $stream = [IO.FileStream]::new($lockFile.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            } catch [IO.IOException] {
                [void]$heldLocks.Add($lockFile.FullName)
            } finally {
                if ($null -ne $stream) { $stream.Dispose() }
            }
        }
    }
    Assert-Aec ($finalLive.Count -eq 0) ("Tracked owners remained live: " + (($finalLive | ConvertTo-Json -Compress)))
    Assert-Aec ($finalRootLive.Count -eq 0) ("Unowned root processes remained live: " + (($finalRootLive | ConvertTo-Json -Compress)))
    Assert-Aec ($heldLocks.Count -eq 0) ("Held locks remained: " + (($heldLocks -join ';')))
    $caller = $null
    foreach ($ancestor in @($ancestorIdentities)) {
        if ([int]$ancestor.pid -eq $selfProcessId) { continue }
        $caller = $ancestor
        break
    }
    $callerPreserved = 0
    if ($null -ne $caller) {
        Assert-Aec (Test-TelephoneOwnerAlive -Owner $caller) 'Invocation caller/ancestor was terminated by the test.'
        $callerPreserved = 1
    }

    [ordered]@{
        success = $true
        nested_target_terminal_to_owner = 1
        owner_delivery_once = 1
        target_turns = $targetTurns
        owner_turns = $ownerTurns
        crash_recoveries = $crashRecoveries
        duplicate_turns = $duplicateTurns
        synthetic_idle_gap_closed = 1
        residue_live_owners = 0
        residue_root_processes = 0
        residue_held_locks = 0
        quiescence = 1
        caller_preserved = $callerPreserved
        caller_pid = if ($null -ne $caller) { [int]$caller.pid } else { 0 }
        caller_start_time_utc_ticks = if ($null -ne $caller) { [int64]$caller.start_time_utc_ticks } else { [int64]0 }
        assertions = $assertions
    } | ConvertTo-Json -Compress
} finally {
    Stop-AecTracked
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY', $script:PreviousDashboardProcessEnvOnly, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', $script:PreviousDashboardOptOut, 'Process')
    foreach ($name in @('TELEPHONE_TEST_LEAD_LOG', 'TELEPHONE_TEST_LEAD_RUNS', 'TELEPHONE_TEST_LEAD_TURNS', 'TELEPHONE_TEST_LEAD_THROW_AFTER_WAKE', 'TELEPHONE_TEST_LEAD_HOLD_TERMINAL', 'TELEPHONE_TEST_LEAD_TERMINAL_STATE', 'TELEPHONE_TEST_RELAY_CRASH_AFTER', 'TELEPHONE_TEST_LEAD_DELAY_TERMINAL_MS', 'TELEPHONE_TEST_LEAD_DELAY_TERMINAL_SESSION')) {
        Remove-Item -Path ('env:' + $name) -ErrorAction SilentlyContinue
    }
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

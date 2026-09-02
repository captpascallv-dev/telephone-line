# SPDX-License-Identifier: MPL-2.0
# Current Understanding (execution, 2026-08-27 core-test relay residue):
# 1. Phase: close Lead FAIL 6199bb7e leftover Resume relays on candidate d5d8c39; preserve accepted native wired ack and existing assertions; amend the same one commit over 6c9d25e.
# 2. Denominator: inventory every exact-TestRoot process including Resume relays; wait natural quiescence; stop only PID+ticks test-owned identities; never kill caller/ancestors; emit PASS JSON only after the isolated root is gone.
# 3. Only next step: harness-only cleanup in this test, one isolated core invocation, post-parent residue audit.
# 4. Frozen non-goals: no product source/fixture/schema/adapter/App Server/dashboard mutation; no black-box or other suite reruns.
# 5. Exit: parse + one core test, post-parent zeros, clean one commit over 6c9d25e, self_accepted=false; not project PASS.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PreviousDashboardProcessEnvOnly = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY', 'Process')
$script:PreviousDashboardOptOut = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', 'Process')
[Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY', '1', 'Process')
[Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', '1', 'Process')
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'src\core\TelephoneLine.Common.ps1')
$starter = Join-Path $repoRoot 'src\core\Start-TelephoneLineJob.ps1'
$resume = Join-Path $repoRoot 'src\core\Resume-TelephoneLines.ps1'
$commandHost = Join-Path $repoRoot 'src\core\Invoke-TelephoneLineCommandHost.ps1'
$mockRoute = Join-Path $PSScriptRoot 'fixtures\mock-route.ps1'
$mockStdinRoute = Join-Path $PSScriptRoot 'fixtures\mock-stdin-route.ps1'
$mockLead = Join-Path $PSScriptRoot 'fixtures\mock-lead-launcher.ps1'
$powerShellPath = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
$stateRoot = Join-Path $testRoot 'telephone-state'
$worktree = Join-Path $testRoot 'worktree'
$leadLog = Join-Path $testRoot 'lead-calls.jsonl'
$leadTurns = Join-Path $testRoot 'lead-turns.jsonl'
$leadRuns = Join-Path $testRoot 'lead-runs'
$counter = Join-Path $testRoot 'route-count.txt'
$sessionId = '01a00000-0000-7000-8000-000000000001'
$selfProcessId = [int]$PID
$trackedOwners = [Collections.Generic.List[object]]::new()
$ancestorIdentities = [Collections.Generic.List[object]]::new()
$cleanupCompleted = $false
$assertions = 0

function Assert-TelephoneTest {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Get-TelephoneTestProcessIdentity {
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

function Initialize-TelephoneTestAncestors {
    $current = $selfProcessId
    for ($i = 0; $i -lt 16; $i++) {
        $identity = Get-TelephoneTestProcessIdentity -ProcessId $current
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

function Test-TelephoneTestProtectedIdentity {
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

function Add-TelephoneTestTracked {
    param($Owner, [string]$Kind = 'process')
    if ($null -eq $Owner) { return }
    if ($Owner -isnot [Collections.IDictionary] -or -not $Owner.Contains('pid')) { return }
    if (Test-TelephoneTestProtectedIdentity -Owner $Owner) { return }
    $pidValue = [int]$Owner.pid
    $ticks = [int64]0
    if ($Owner.Contains('start_time_utc_ticks')) { $ticks = [int64]$Owner.start_time_utc_ticks }
    if ($ticks -eq 0) {
        $live = Get-TelephoneTestProcessIdentity -ProcessId $pidValue
        if ($null -ne $live) { $ticks = [int64]$live.start_time_utc_ticks }
    }
    foreach ($existing in @($trackedOwners)) {
        if ([int]$existing.pid -eq $pidValue -and [int64]$existing.start_time_utc_ticks -eq $ticks) { return }
    }
    $trackedOwners.Add([ordered]@{
        pid = $pidValue
        start_time_utc_ticks = $ticks
        kind = [string]$Kind
    })
}

function Get-TelephoneTestLiveTracked {
    $live = [Collections.Generic.List[object]]::new()
    foreach ($owner in @($trackedOwners)) {
        if (Test-TelephoneOwnerAlive -Owner $owner) { [void]$live.Add($owner) }
    }
    return @($live)
}

function Get-TelephoneTestRootProcesses {
    $rows = [Collections.Generic.List[object]]::new()
    $filter = "Name = 'pwsh.exe' OR Name = 'powershell.exe'"
    foreach ($cim in @(Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction SilentlyContinue)) {
        $pidValue = [int]$cim.ProcessId
        $command = [string]$cim.CommandLine
        if ([string]::IsNullOrWhiteSpace($command)) { continue }
        if ($command.IndexOf($testRoot, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $identity = Get-TelephoneTestProcessIdentity -ProcessId $pidValue
        if ($null -eq $identity) { continue }
        $identity['kind'] = 'root_command'
        if (Test-TelephoneTestProtectedIdentity -Owner $identity) { continue }
        $rows.Add($identity)
    }
    return @($rows)
}

function Scan-TelephoneTestDurableOwners {
    param([string]$JobRoot)
    if ([string]::IsNullOrWhiteSpace($JobRoot) -or -not [IO.Directory]::Exists($JobRoot)) { return }
    $paths = Get-TelephoneJobPaths -JobRoot $JobRoot
    foreach ($name in @('command_owner', 'relay_owner')) {
        $path = [string]$paths[$name]
        if ([IO.File]::Exists($path)) {
            try { Add-TelephoneTestTracked -Owner (Read-TelephoneJson -Path $path).value -Kind $name } catch { }
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $JobRoot -File -Filter 'relay-resume-*.json' -ErrorAction SilentlyContinue)) {
        try { Add-TelephoneTestTracked -Owner (Read-TelephoneJson -Path $file.FullName).value -Kind 'relay_resume' } catch { }
    }
}

function Scan-TelephoneTestLeadOwners {
    if (-not [IO.Directory]::Exists($leadRuns)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $leadRuns -Recurse -File -Filter 'owner.json' -ErrorAction SilentlyContinue)) {
        try { Add-TelephoneTestTracked -Owner (Read-TelephoneJson -Path $file.FullName).value -Kind 'lead_owner' } catch { }
    }
}

function Scan-TelephoneTestMailboxOwners {
    $leadsRoot = Join-Path $stateRoot 'leads'
    if (-not [IO.Directory]::Exists($leadsRoot)) { return }
    foreach ($leadDir in @(Get-ChildItem -LiteralPath $leadsRoot -Directory -ErrorAction SilentlyContinue)) {
        $ownerPath = Join-Path $leadDir.FullName 'owner.json'
        if ([IO.File]::Exists($ownerPath)) {
            try { Add-TelephoneTestTracked -Owner (Read-TelephoneJson -Path $ownerPath).value -Kind 'mailbox_owner' } catch { }
        }
    }
}

function Stop-TelephoneTestMailboxCollectors {
    Scan-TelephoneTestMailboxOwners
    foreach ($owner in @($trackedOwners)) {
        if ([string]$owner.kind -cne 'mailbox_owner') { continue }
        if (Test-TelephoneTestProtectedIdentity -Owner $owner) { continue }
        if (-not (Test-TelephoneOwnerAlive -Owner $owner)) { continue }
        try { Stop-Process -Id ([int]$owner.pid) -Force -ErrorAction SilentlyContinue } catch { }
    }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $live = $false
        foreach ($owner in @($trackedOwners)) {
            if ([string]$owner.kind -cne 'mailbox_owner') { continue }
            if (Test-TelephoneTestProtectedIdentity -Owner $owner) { continue }
            if (Test-TelephoneOwnerAlive -Owner $owner) { $live = $true; break }
        }
        if (-not $live) { return }
        Start-Sleep -Milliseconds 50
    }
}

function Scan-TelephoneTestState {
    $jobsRoot = Join-Path $stateRoot 'jobs'
    if ([IO.Directory]::Exists($jobsRoot)) {
        foreach ($job in @(Get-ChildItem -LiteralPath $jobsRoot -Directory -ErrorAction SilentlyContinue)) {
            Scan-TelephoneTestDurableOwners -JobRoot $job.FullName
        }
    }
    Scan-TelephoneTestLeadOwners
    Scan-TelephoneTestMailboxOwners
    foreach ($proc in @(Get-TelephoneTestRootProcesses)) {
        Add-TelephoneTestTracked -Owner $proc -Kind 'root_command'
    }
}

function Wait-TelephoneTestQuiescence {
    param([int]$Seconds = 20)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($Seconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        Scan-TelephoneTestState
        if (@(Get-TelephoneTestLiveTracked).Count -eq 0) { return @() }
        Start-Sleep -Milliseconds 100
    }
    Scan-TelephoneTestState
    return @(Get-TelephoneTestLiveTracked)
}

function Stop-TelephoneTestTracked {
    foreach ($owner in @($trackedOwners)) {
        if (Test-TelephoneTestProtectedIdentity -Owner $owner) { continue }
        if (-not (Test-TelephoneOwnerAlive -Owner $owner)) { continue }
        try { Stop-Process -Id ([int]$owner.pid) -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Get-TelephoneTestHeldLocks {
    $held = [Collections.Generic.List[string]]::new()
    if (-not [IO.Directory]::Exists($testRoot)) { return @() }
    foreach ($lockFile in @(Get-ChildItem -LiteralPath $testRoot -Recurse -File -Filter '*.lock' -ErrorAction SilentlyContinue)) {
        $stream = $null
        try {
            $stream = [IO.FileStream]::new($lockFile.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] {
            [void]$held.Add($lockFile.FullName)
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }
    return @($held)
}

function Get-TelephoneTestLiveDurableOwners {
    $live = [Collections.Generic.List[object]]::new()
    $jobsRoot = Join-Path $stateRoot 'jobs'
    $files = [Collections.Generic.List[string]]::new()
    if ([IO.Directory]::Exists($jobsRoot)) {
        foreach ($job in @(Get-ChildItem -LiteralPath $jobsRoot -Directory -ErrorAction SilentlyContinue)) {
            $paths = Get-TelephoneJobPaths -JobRoot $job.FullName
            foreach ($name in @('command_owner', 'relay_owner')) {
                if ([IO.File]::Exists([string]$paths[$name])) { [void]$files.Add([string]$paths[$name]) }
            }
            foreach ($file in @(Get-ChildItem -LiteralPath $job.FullName -File -Filter 'relay-resume-*.json' -ErrorAction SilentlyContinue)) {
                [void]$files.Add($file.FullName)
            }
        }
    }
    if ([IO.Directory]::Exists($leadRuns)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $leadRuns -Recurse -File -Filter 'owner.json' -ErrorAction SilentlyContinue)) {
            [void]$files.Add($file.FullName)
        }
    }
    $leadsRoot = Join-Path $stateRoot 'leads'
    if ([IO.Directory]::Exists($leadsRoot)) {
        foreach ($leadDir in @(Get-ChildItem -LiteralPath $leadsRoot -Directory -ErrorAction SilentlyContinue)) {
            $ownerPath = Join-Path $leadDir.FullName 'owner.json'
            if ([IO.File]::Exists($ownerPath)) { [void]$files.Add($ownerPath) }
        }
    }
    foreach ($path in @($files)) {
        try {
            $owner = (Read-TelephoneJson -Path $path).value
            if (Test-TelephoneTestProtectedIdentity -Owner $owner) { continue }
            if (Test-TelephoneOwnerAlive -Owner $owner) { [void]$live.Add([ordered]@{ path = $path; pid = [int]$owner.pid }) }
        } catch { }
    }
    return @($live)
}

function Complete-TelephoneTestCleanup {
    Scan-TelephoneTestState
    $null = Wait-TelephoneTestQuiescence -Seconds 20
    Stop-TelephoneTestTracked
    Start-Sleep -Milliseconds 250
    Scan-TelephoneTestState
    $stillLive = @(Get-TelephoneTestLiveTracked)
    if ($stillLive.Count -gt 0) {
        Stop-TelephoneTestTracked
        Start-Sleep -Milliseconds 250
        $stillLive = @(Get-TelephoneTestLiveTracked)
    }
    $rootLive = @(Get-TelephoneTestRootProcesses)
    $durableLive = @(Get-TelephoneTestLiveDurableOwners)
    $heldLocks = @(Get-TelephoneTestHeldLocks)
    if ($stillLive.Count -ne 0 -or $rootLive.Count -ne 0 -or $durableLive.Count -ne 0 -or $heldLocks.Count -ne 0) {
        throw ("Telephone core test residue remained: live=" + (($stillLive | ConvertTo-Json -Compress)) + "; root=" + (($rootLive | ConvertTo-Json -Compress)) + "; owners=" + (($durableLive | ConvertTo-Json -Compress)) + "; locks=" + (($heldLocks -join ';')))
    }
    foreach ($ancestor in @($ancestorIdentities)) {
        if (-not (Test-TelephoneOwnerAlive -Owner $ancestor)) {
            throw ("Invocation caller/ancestor was terminated by the test: pid=" + [int]$ancestor.pid)
        }
    }
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if (-not $testRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Isolated telephone core test root is not under the temp prefix: $testRoot"
    }
    if ([IO.Directory]::Exists($testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
    }
    if ([IO.Directory]::Exists($testRoot)) {
        throw "Isolated telephone core test root remained after cleanup: $testRoot"
    }
    $script:cleanupCompleted = $true
}

function Wait-TelephoneTestPath {
    # The product permits up to 30 seconds for a cold mailbox collector to
    # publish its owner.  Keep the smoke oracle above that startup contract so
    # a fresh hosted runner does not reject an otherwise healthy first wake.
    param([string]$Path, [int]$Seconds = 60)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($Seconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if ([IO.File]::Exists($Path)) { return }
        Start-Sleep -Milliseconds 100
    }
    $jobRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    $files = if ([IO.Directory]::Exists($jobRoot)) { @([IO.Directory]::GetFiles($jobRoot) | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ',' } else { '<missing-job-root>' }
    $stderrPath = Join-Path $jobRoot 'route-stderr.txt'
    $stderr = if ([IO.File]::Exists($stderrPath)) { [IO.File]::ReadAllText($stderrPath) } else { '<no-stderr>' }
    throw "Timed out waiting for test path: $Path; files=$files; stderr=$stderr"
}

function New-TelephoneTestRequest {
    param([string]$JobId, [string]$Role, [int]$DelayMilliseconds, [string]$LauncherPath = $mockLead, [string[]]$LauncherArguments = @())
    $requestPath = Join-Path $testRoot ("request-$JobId.json")
    $request = [ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = $JobId
        project = 'telephone-test'
        stage = 'SIMULATION'
        role = $Role
        route = 'mock-route'
        summary = "mock $Role"
        lead = [ordered]@{
            protocol_version = 'telephone-line-lead-binding-v1'
            session_id = $sessionId
            worktree = $worktree
            launcher = [ordered]@{
                path = $LauncherPath
                arguments = @($LauncherArguments)
            }
        }
        command = [ordered]@{
            executable = $powerShellPath
            working_directory = $testRoot
            arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $mockRoute, '-CounterPath', $counter, '-DelayMilliseconds', [string]$DelayMilliseconds, '-FinalText', "DONE-$Role")
        }
    }
    $null = Write-TelephoneJsonCreateNew -Path $requestPath -Value $request
    return $requestPath
}

function New-TelephoneTestDurableDispatch {
    param($RequestRead, [string]$LeadBindingPath)
    $request = $RequestRead.value
    $binding = Read-TelephoneLeadBinding -Lead $request.lead
    $bindingIdentity = Write-TelephoneJsonCreateNew -Path $LeadBindingPath -Value $binding
    $stdin = $null
    if ($request.command.Contains('stdin_file') -and -not [string]::IsNullOrWhiteSpace([string]$request.command.stdin_file)) {
        $stdin = Get-TelephoneFileIdentity -Path ([string]$request.command.stdin_file)
    }
    return [ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = [string]$request.line_job_id
        project = [string]$request.project
        stage = [string]$request.stage
        role = [string]$request.role
        route = [string]$request.route
        summary = [string]$request.summary
        lead = $binding
        command = [ordered]@{
            executable = [IO.Path]::GetFullPath([string]$request.command.executable)
            working_directory = [IO.Path]::GetFullPath([string]$request.command.working_directory).TrimEnd('\')
            arguments = @($request.command.arguments | ForEach-Object { [string]$_ })
            stdin = $stdin
        }
        source_request = $RequestRead.identity
        lead_binding = $bindingIdentity
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        absolute_task_timeout = $false
        project_judgment = $false
    }
}

function Get-TelephoneTestTurnCount {
    param([string]$RunId)
    if (-not [IO.File]::Exists($leadTurns)) { return 0 }
    $count = 0
    foreach ($line in [IO.File]::ReadAllLines($leadTurns)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $row = $line | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
        if ([string]$row.run_id -ceq $RunId) { $count += 1 }
    }
    return $count
}

function Get-TelephoneTestDurableSentinelCount {
    param([string]$JobRoot, [string[]]$Sentinels)
    $count = 0
    $names = @(
        'receipt.json', 'relay-error.json', 'wake-prompt.md', 'delivery.json',
        'delivery-claim.json', 'wake-intent.json', 'wake-attempt.json', 'wake-launch-result.json'
    )
    foreach ($name in $names) {
        $path = Join-Path $JobRoot $name
        if (-not [IO.File]::Exists($path)) { continue }
        $text = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false, $true))
        foreach ($sentinel in $Sentinels) {
            if (-not [string]::IsNullOrEmpty($sentinel) -and $text.Contains($sentinel)) { $count += 1 }
        }
    }
    return $count
}

function New-TelephoneTestSealedReceipt {
    param($DispatchRead)
    $dispatch = $DispatchRead.value
    return [ordered]@{
        protocol_version = 'telephone-line-receipt-v1'
        line_job_id = [string]$dispatch.line_job_id
        project = [string]$dispatch.project
        stage = [string]$dispatch.stage
        role = [string]$dispatch.role
        route = [string]$dispatch.route
        summary = [string]$dispatch.summary
        dispatch = $DispatchRead.identity
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
}

try {
    Initialize-TelephoneTestAncestors
    [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    [IO.Directory]::CreateDirectory($worktree) | Out-Null
    [IO.Directory]::CreateDirectory($leadRuns) | Out-Null
    $env:TELEPHONE_TEST_LEAD_LOG = $leadLog
    $env:TELEPHONE_TEST_LEAD_RUNS = $leadRuns
    $env:TELEPHONE_TEST_LEAD_TURNS = $leadTurns

    # Exercise the caller-visible durable contract without depending on scheduler
    # timing: a dead child does not transfer publication from its live host.
    $receiptLiveOwner = Get-TelephoneTestProcessIdentity -ProcessId $PID
    $receiptLiveOwner['started_at_utc'] = [DateTimeOffset]::UtcNow.ToString('o')
    $receiptDeadOwner = [ordered]@{
        pid = [int]$PID
        start_time_utc_ticks = [int64]($receiptLiveOwner.start_time_utc_ticks - 1)
        started_at_utc = $receiptLiveOwner.started_at_utc
    }
    Assert-TelephoneTest ((Test-TelephoneOwnerAlive -Owner $receiptLiveOwner) -and -not (Test-TelephoneOwnerAlive -Owner $receiptDeadOwner)) 'Receipt ordering fixture identities were not live/dead as intended.'
    foreach ($receiptCase in @(
        @{ name = 'exit-zero'; code = 0; exit_record = $true },
        @{ name = 'exit-seven'; code = 7; exit_record = $true },
        @{ name = 'exit-unknown'; code = $null; exit_record = $true },
        @{ name = 'output-only'; code = $null; exit_record = $false }
    )) {
        $receiptJob = [Guid]::NewGuid().ToString()
        # These are synthetic records, outside jobs/, and are never dispatched.
        $receiptRoot = Join-Path $testRoot ('receipt-order-' + $receiptCase.name)
        [IO.Directory]::CreateDirectory($receiptRoot) | Out-Null
        $receiptPaths = Get-TelephoneJobPaths -JobRoot $receiptRoot
        $receiptRequest = Read-TelephoneJson -Path (New-TelephoneTestRequest -JobId $receiptJob -Role execution -DelayMilliseconds 0)
        $receiptDispatch = New-TelephoneTestDurableDispatch -RequestRead $receiptRequest -LeadBindingPath $receiptPaths.lead_binding
        $null = Write-TelephoneJsonCreateNew -Path $receiptPaths.dispatch -Value $receiptDispatch
        $null = Write-TelephoneJsonCreateNew -Path $receiptPaths.command_owner -Value $receiptLiveOwner
        $null = Write-TelephoneJsonCreateNew -Path $receiptPaths.command_child -Value $receiptDeadOwner
        $null = Write-TelephoneTextCreateNew -Path $receiptPaths.stdout -Text "synthetic completed child output`n"
        Assert-TelephoneTest ((Sync-TelephoneCommandOwnerCompletion -Paths $receiptPaths) -ceq 'waiting_owner') 'Recovery preempted the live host before its exit record.'
        Assert-TelephoneTest (-not [IO.File]::Exists($receiptPaths.receipt)) 'Recovery sealed an unknown receipt while the host was still publishing.'
        if ($receiptCase.exit_record) {
            Write-TelephoneCommandChildExit -Paths $receiptPaths -Dispatch $receiptDispatch -ExitCode $receiptCase.code
        }
        Assert-TelephoneTest ((Sync-TelephoneCommandOwnerCompletion -Paths $receiptPaths) -ceq 'waiting_owner') 'Recovery preempted the live host after its exit record.'
        Assert-TelephoneTest (-not [IO.File]::Exists($receiptPaths.receipt)) 'A live host lost ownership of terminal publication.'
        $null = Write-TelephoneJsonReplace -Path $receiptPaths.command_owner -Value $receiptDeadOwner
        Assert-TelephoneTest ((Sync-TelephoneCommandOwnerCompletion -Paths $receiptPaths) -ceq 'reconciled') 'A dead host could not be reconciled from the same durable result.'
        $reconciledRead = Read-TelephoneJson -Path $receiptPaths.receipt -SchemaName 'receipt'
        Assert-TelephoneTest ($reconciledRead.value.transport_complete -eq $true) 'Reconciliation lost the completed transport.'
        if ($null -eq $receiptCase.code) {
            Assert-TelephoneTest ($null -eq $reconciledRead.value.command_exit_code) 'An unknown exit code was converted into success.'
        } else {
            Assert-TelephoneTest ($reconciledRead.value.command_exit_code -eq $receiptCase.code) 'Reconciliation changed the actual child exit code.'
        }
        Assert-TelephoneTest ((Sync-TelephoneCommandOwnerCompletion -Paths $receiptPaths) -ceq 'receipt') 'Repeated recovery did not preserve the existing receipt.'
        Assert-TelephoneTest ((Get-TelephoneFileIdentity -Path $receiptPaths.receipt).sha256 -ceq $reconciledRead.identity.sha256) 'Repeated recovery rewrote the sealed receipt.'
    }
    $receiptOwnerOrdering = 1
    $unknownExitPreserved = 1

    $ackRoot = Join-Path $testRoot 'origin-wake'
    [IO.Directory]::CreateDirectory($ackRoot) | Out-Null
    $ackPath = Join-Path $ackRoot 'lead-wake-ack.json'
    $ackBytes = [Text.UTF8Encoding]::new($false).GetBytes((([ordered]@{
        protocol_version = 'telephone-line-lead-wake-ack-v1'
        session_id = $sessionId
        event = 'turn.started'
        acknowledged_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress) + "`n"))
    $activeAck = [IO.FileStream]::new($ackPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try {
        $activeAck.Write($ackBytes, 0, $ackBytes.Length)
        $activeAck.Flush($true)
        $resolvedWhileLeadActive = Resolve-TelephoneLeadSessionId -Lead ([ordered]@{
            protocol_version = 'telephone-line-lead-binding-v1'
            session_id = $sessionId
            worktree = $worktree
            launcher = [ordered]@{ path = $mockLead; arguments = @() }
        })
        Assert-TelephoneTest ($resolvedWhileLeadActive -ceq $sessionId) 'The telephone line could not bind the exact Lead session from the frozen binding.'
        $wakeWhileLeadActive = Wait-TelephoneLeadWakeAcknowledged -RunRoot $ackRoot -ExpectedSessionId $sessionId -StartupTimeoutSeconds 2
        Assert-TelephoneTest ([string]$wakeWhileLeadActive.event -ceq 'turn.started') 'The telephone line could not acknowledge the exact resumed Lead while its acknowledgment file was still open.'
    } finally {
        $activeAck.Dispose()
    }

    function New-TelephoneTestLiveOwner {
        param([string]$RunRoot)
        $self = Get-Process -Id $PID
        try {
            $owner = [ordered]@{
                pid = [int]$PID
                start_time_utc_ticks = [int64]$self.StartTime.ToUniversalTime().Ticks
                started_at_utc = $self.StartTime.ToUniversalTime().ToString('o')
            }
        } finally { $self.Dispose() }
        [IO.File]::WriteAllText((Join-Path $RunRoot 'owner.json'), (($owner | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    }
    function New-TelephoneTestNativeRunMeta {
        param([string]$RunRoot, [string]$SessionId, [string]$RunId, [string]$EventsPath)
        $meta = [ordered]@{
            protocol_version = 'huhu-concerto-cli-lead-run-v1'
            run_id = $RunId
            requested_run_id = $RunId
            resume_session_id = $SessionId
            events_path = $EventsPath
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        [IO.File]::WriteAllText((Join-Path $RunRoot 'lead-run.json'), (($meta | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    }

    $nativeOpen = Join-Path $testRoot 'native-open'
    $nativeRunId = 'telephone-native-open-1'
    $nativeRoot = Join-Path $nativeOpen $nativeRunId
    [IO.Directory]::CreateDirectory($nativeRoot) | Out-Null
    New-TelephoneTestLiveOwner -RunRoot $nativeRoot
    $nativeEventsPath = Join-Path $nativeRoot 'codex-events.jsonl'
    New-TelephoneTestNativeRunMeta -RunRoot $nativeRoot -SessionId $sessionId -RunId $nativeRunId -EventsPath $nativeEventsPath
    $nativeStream = [IO.FileStream]::new($nativeEventsPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try {
        $utf8 = [Text.UTF8Encoding]::new($false)
        $threadBytes = $utf8.GetBytes(('{"type":"thread.started","thread_id":"' + $sessionId + '"}' + "`n"))
        $nativeStream.Write($threadBytes, 0, $threadBytes.Length)
        $nativeStream.Flush($true)
        $incomplete = $utf8.GetBytes('{"type":"turn.st')
        $nativeStream.Write($incomplete, 0, $incomplete.Length)
        $nativeStream.Flush($true)
        $premature = $null
        try { $premature = Wait-TelephoneLeadWakeAcknowledged -RunRoot $nativeRoot -ExpectedSessionId $sessionId -ExpectedRunId $nativeRunId -StartupTimeoutSeconds 1 } catch { $premature = $null }
        Assert-TelephoneTest ($null -eq $premature) 'Incomplete trailing JSONL was treated as a native acknowledgment.'
        $rest = $utf8.GetBytes('arted"}' + "`n")
        $nativeStream.Write($rest, 0, $rest.Length)
        $nativeStream.Flush($true)
        $nativeAck = Wait-TelephoneLeadWakeAcknowledged -RunRoot $nativeRoot -ExpectedSessionId $sessionId -ExpectedRunId $nativeRunId -StartupTimeoutSeconds 3
        Assert-TelephoneTest ([string]$nativeAck.event -ceq 'turn.started') 'Native thread.started/turn.started pair was not acknowledged while the event stream was still open.'
        Assert-TelephoneTest ([IO.File]::Exists((Join-Path $nativeRoot 'lead-wake-ack.json'))) 'Native acknowledgment was not persisted as canonical lead-wake-ack.json.'
        $replayAck = Wait-TelephoneLeadWakeAcknowledged -RunRoot $nativeRoot -ExpectedSessionId $sessionId -ExpectedRunId $nativeRunId -StartupTimeoutSeconds 2
        Assert-TelephoneTest ([string]$replayAck.event -ceq 'turn.started') 'Replay of the canonical native acknowledgment failed.'
    } finally {
        $nativeStream.Dispose()
    }
    $nativeOpenAck = 1

    $nativeNegatives = 0
    function Assert-TelephoneNativeNegative {
        param([string]$Name, [scriptblock]$Body)
        $failed = $false
        try { & $Body } catch { $failed = $true }
        Assert-TelephoneTest $failed ("Native negative $Name was accepted.")
        $script:nativeNegatives += 1
    }
    $negBase = Join-Path $testRoot 'native-neg'
    [IO.Directory]::CreateDirectory($negBase) | Out-Null
    Assert-TelephoneNativeNegative -Name 'wrong-run-binding' -Body {
        $root = Join-Path $negBase 'wrong-run'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        New-TelephoneTestLiveOwner -RunRoot $root
        $events = Join-Path $root 'codex-events.jsonl'
        $meta = [ordered]@{
            protocol_version = 'huhu-concerto-cli-lead-run-v1'
            run_id = 'other-run'
            requested_run_id = 'other-run'
            resume_session_id = $sessionId
            events_path = $events
        }
        [IO.File]::WriteAllText((Join-Path $root 'lead-run.json'), (($meta | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($events, ('{"type":"thread.started","thread_id":"' + $sessionId + '"}' + "`n" + '{"type":"turn.started"}' + "`n"), [Text.UTF8Encoding]::new($false))
        $null = Wait-TelephoneLeadWakeAcknowledged -RunRoot $root -ExpectedSessionId $sessionId -ExpectedRunId 'telephone-expected' -StartupTimeoutSeconds 1
    }
    Assert-TelephoneNativeNegative -Name 'missing-resume-session' -Body {
        $root = Join-Path $negBase 'missing-resume'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        New-TelephoneTestLiveOwner -RunRoot $root
        $events = Join-Path $root 'codex-events.jsonl'
        $meta = [ordered]@{
            protocol_version = 'huhu-concerto-cli-lead-run-v1'
            run_id = 'telephone-missing-resume'
            requested_run_id = 'telephone-missing-resume'
            events_path = $events
        }
        [IO.File]::WriteAllText((Join-Path $root 'lead-run.json'), (($meta | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($events, ('{"type":"thread.started","thread_id":"' + $sessionId + '"}' + "`n" + '{"type":"turn.started"}' + "`n"), [Text.UTF8Encoding]::new($false))
        $null = Wait-TelephoneLeadWakeAcknowledged -RunRoot $root -ExpectedSessionId $sessionId -ExpectedRunId 'telephone-missing-resume' -StartupTimeoutSeconds 1
    }
    Assert-TelephoneNativeNegative -Name 'wrong-thread' -Body {
        $root = Join-Path $negBase 'wrong-thread'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        New-TelephoneTestLiveOwner -RunRoot $root
        $events = Join-Path $root 'codex-events.jsonl'
        New-TelephoneTestNativeRunMeta -RunRoot $root -SessionId $sessionId -RunId 'telephone-wrong-thread' -EventsPath $events
        [IO.File]::WriteAllText($events, '{"type":"thread.started","thread_id":"01a00000-0000-7000-8000-000000000099"}' + "`n" + '{"type":"turn.started"}' + "`n", [Text.UTF8Encoding]::new($false))
        $null = Wait-TelephoneLeadWakeAcknowledged -RunRoot $root -ExpectedSessionId $sessionId -ExpectedRunId 'telephone-wrong-thread' -StartupTimeoutSeconds 1
    }
    Assert-TelephoneNativeNegative -Name 'turn-before-thread' -Body {
        $root = Join-Path $negBase 'turn-before'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        New-TelephoneTestLiveOwner -RunRoot $root
        $events = Join-Path $root 'codex-events.jsonl'
        New-TelephoneTestNativeRunMeta -RunRoot $root -SessionId $sessionId -RunId 'telephone-turn-before' -EventsPath $events
        [IO.File]::WriteAllText($events, '{"type":"turn.started"}' + "`n" + '{"type":"thread.started","thread_id":"' + $sessionId + '"}' + "`n", [Text.UTF8Encoding]::new($false))
        $null = Wait-TelephoneLeadWakeAcknowledged -RunRoot $root -ExpectedSessionId $sessionId -ExpectedRunId 'telephone-turn-before' -StartupTimeoutSeconds 1
    }
    Assert-TelephoneNativeNegative -Name 'turn-only' -Body {
        $root = Join-Path $negBase 'turn-only'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        New-TelephoneTestLiveOwner -RunRoot $root
        $events = Join-Path $root 'codex-events.jsonl'
        New-TelephoneTestNativeRunMeta -RunRoot $root -SessionId $sessionId -RunId 'telephone-turn-only' -EventsPath $events
        [IO.File]::WriteAllText($events, '{"type":"turn.started"}' + "`n", [Text.UTF8Encoding]::new($false))
        $null = Wait-TelephoneLeadWakeAcknowledged -RunRoot $root -ExpectedSessionId $sessionId -ExpectedRunId 'telephone-turn-only' -StartupTimeoutSeconds 1
    }
    Assert-TelephoneNativeNegative -Name 'malformed-complete-json' -Body {
        $root = Join-Path $negBase 'malformed'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        New-TelephoneTestLiveOwner -RunRoot $root
        $events = Join-Path $root 'codex-events.jsonl'
        New-TelephoneTestNativeRunMeta -RunRoot $root -SessionId $sessionId -RunId 'telephone-malformed' -EventsPath $events
        [IO.File]::WriteAllText($events, '{"type":"thread.started","thread_id":"' + $sessionId + '"}' + "`n" + '{not-json}' + "`n", [Text.UTF8Encoding]::new($false))
        $null = Wait-TelephoneLeadWakeAcknowledged -RunRoot $root -ExpectedSessionId $sessionId -ExpectedRunId 'telephone-malformed' -StartupTimeoutSeconds 1
    }
    Assert-TelephoneNativeNegative -Name 'competing-lineage' -Body {
        $root = Join-Path $negBase 'compete'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        New-TelephoneTestLiveOwner -RunRoot $root
        $events = Join-Path $root 'codex-events.jsonl'
        New-TelephoneTestNativeRunMeta -RunRoot $root -SessionId $sessionId -RunId 'telephone-compete' -EventsPath $events
        [IO.File]::WriteAllText($events, '{"type":"thread.started","thread_id":"' + $sessionId + '"}' + "`n" + '{"type":"thread.started","thread_id":"01a00000-0000-7000-8000-000000000098"}' + "`n" + '{"type":"turn.started"}' + "`n", [Text.UTF8Encoding]::new($false))
        $null = Wait-TelephoneLeadWakeAcknowledged -RunRoot $root -ExpectedSessionId $sessionId -ExpectedRunId 'telephone-compete' -StartupTimeoutSeconds 1
    }
    Assert-TelephoneNativeNegative -Name 'dead-before-ack' -Body {
        $root = Join-Path $negBase 'dead'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $dead = [ordered]@{ pid = 1; start_time_utc_ticks = [int64]1; started_at_utc = '2026-01-01T00:00:00.0000000+00:00' }
        [IO.File]::WriteAllText((Join-Path $root 'owner.json'), (($dead | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        $events = Join-Path $root 'codex-events.jsonl'
        New-TelephoneTestNativeRunMeta -RunRoot $root -SessionId $sessionId -RunId 'telephone-dead' -EventsPath $events
        [IO.File]::WriteAllText($events, '{"type":"thread.started","thread_id":"' + $sessionId + '"}' + "`n", [Text.UTF8Encoding]::new($false))
        $null = Wait-TelephoneLeadWakeAcknowledged -RunRoot $root -ExpectedSessionId $sessionId -ExpectedRunId 'telephone-dead' -StartupTimeoutSeconds 1
    }
    Assert-TelephoneNativeNegative -Name 'missing-run-metadata' -Body {
        $root = Join-Path $negBase 'missing-run'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        New-TelephoneTestLiveOwner -RunRoot $root
        $events = Join-Path $root 'codex-events.jsonl'
        [IO.File]::WriteAllText($events, ('{"type":"thread.started","thread_id":"' + $sessionId + '"}' + "`n" + '{"type":"turn.started"}' + "`n"), [Text.UTF8Encoding]::new($false))
        $null = Wait-TelephoneLeadWakeAcknowledged -RunRoot $root -ExpectedSessionId $sessionId -ExpectedRunId 'telephone-missing-run' -StartupTimeoutSeconds 1
    }
    $nativeNegativesClosed = [int]$nativeNegatives

    $detachedSleeper = Join-Path $testRoot 'detached-sleeper.ps1'
    $detachedProbe = Join-Path $testRoot 'detached-probe.ps1'
    [IO.File]::WriteAllText($detachedSleeper, "param([string]`$Ignored)`nStart-Sleep -Milliseconds 3000`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($detachedProbe, @'
param([string]$CommonPath, [string]$ChildPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $CommonPath
Start-TelephoneHiddenPowerShell -ScriptPath $ChildPath -Arguments @('-Ignored', 'probe') | ConvertTo-Json -Compress
'@, [Text.UTF8Encoding]::new($false))
    $probeInfo = [Diagnostics.ProcessStartInfo]::new()
    $probeInfo.FileName = $powerShellPath
    $probeInfo.UseShellExecute = $false
    $probeInfo.RedirectStandardOutput = $true
    $probeInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $detachedProbe, '-CommonPath', (Join-Path $repoRoot 'src\core\TelephoneLine.Common.ps1'), '-ChildPath', $detachedSleeper)) {
        [void]$probeInfo.ArgumentList.Add([string]$argument)
    }
    $probeClock = [Diagnostics.Stopwatch]::StartNew()
    $probeProcess = [Diagnostics.Process]::Start($probeInfo)
    try {
        $probeStdoutTask = $probeProcess.StandardOutput.ReadToEndAsync()
        $probeStderrTask = $probeProcess.StandardError.ReadToEndAsync()
        $probeProcess.WaitForExit()
        $probeStdout = $probeStdoutTask.GetAwaiter().GetResult()
        $probeStderr = $probeStderrTask.GetAwaiter().GetResult()
        $probeClock.Stop()
        Assert-TelephoneTest ($probeProcess.ExitCode -eq 0) "Detached worker probe failed: $probeStderr"
        $detachedOwner = $probeStdout | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
        Add-TelephoneTestTracked -Owner $detachedOwner -Kind 'detached'
        Assert-TelephoneTest ($probeClock.ElapsedMilliseconds -lt 1800) 'A hidden telephone worker kept the Lead command output pipe open.'
    } finally {
        $probeProcess.Dispose()
    }

    $job1 = [Guid]::NewGuid().ToString()
    $request1 = New-TelephoneTestRequest -JobId $job1 -Role execution -DelayMilliseconds 1400
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $start1Text = & $starter -RequestFile $request1 -StateRoot $stateRoot
    $clock.Stop()
    $start1 = ($start1Text -join "`n") | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    Add-TelephoneTestTracked -Owner $start1.command_owner -Kind 'command_owner'
    Add-TelephoneTestTracked -Owner $start1.relay_owner -Kind 'relay_owner'
    Assert-TelephoneTest ($clock.ElapsedMilliseconds -lt 1200) ("Lead dispatch did not return before the external route completed. elapsed_ms=" + $clock.ElapsedMilliseconds)
    Assert-TelephoneTest ($start1.lead_should_exit_now -eq $true) 'Starter did not tell Lead to exit immediately.'
    Assert-TelephoneTest ($start1.absolute_task_timeout -eq $false) 'Starter introduced an absolute task timeout.'
    Start-Sleep -Milliseconds 250
    Assert-TelephoneTest (-not [IO.File]::Exists($leadLog)) 'Lead was woken before the durable route receipt existed.'
    $job1Root = [string]$start1.job_root
    $dispatch1 = (Read-TelephoneJson -Path (Join-Path $job1Root 'dispatch.json') -SchemaName 'dispatch').value
    Assert-TelephoneTest ([string]$dispatch1.lead.session_id -ceq $sessionId) 'Starter did not freeze the exact Lead binding session.'
    Assert-TelephoneTest ([IO.File]::Exists((Join-Path $job1Root 'command-launch.json'))) 'Starter did not publish the exact command process launch.'
    Wait-TelephoneTestPath -Path (Join-Path $job1Root 'delivery.json')
    $receipt1Read = Read-TelephoneJson -Path (Join-Path $job1Root 'receipt.json') -SchemaName 'receipt'
    $receipt1 = $receipt1Read.value
    $delivery1 = (Read-TelephoneJson -Path (Join-Path $job1Root 'delivery.json')).value
    $receipt1Successful = ($receipt1.transport_complete -eq $true -and $receipt1.command_exit_code -eq 0)
    $receipt1Message = 'Successful route did not produce a successful durable receipt.'
    if (-not $receipt1Successful) {
        $childExit1Path = Join-Path $job1Root 'command-child-exit.json'
        $childExit1 = if ([IO.File]::Exists($childExit1Path)) { (Read-TelephoneJson -Path $childExit1Path).value.command_exit_code } else { $null }
        $receipt1Message += ' ' + ([ordered]@{
            transport_complete = $receipt1.transport_complete
            command_exit_code = $receipt1.command_exit_code
            command_error_code = $receipt1.command_error_code
            child_exit_present = [IO.File]::Exists($childExit1Path)
            child_exit_code = $childExit1
        } | ConvertTo-Json -Compress)
    }
    Assert-TelephoneTest $receipt1Successful $receipt1Message
    Assert-TelephoneTest ($receipt1.absolute_task_timeout -eq $false -and $receipt1.automatic_rerun -eq $false -and $receipt1.project_judgment -eq $false) 'Receipt crossed the transport-only boundary.'
    Assert-TelephoneTest ([string]$delivery1.lead_session_id -ceq $sessionId) 'Relay did not resolve the exact original Lead session.'
    Assert-TelephoneTest ([string]$delivery1.wake_acknowledgment.event -ceq 'turn.started') 'Delivery was published before the exact Lead wake was acknowledged.'
    $wakePrompt1 = [IO.File]::ReadAllText((Join-Path $job1Root 'wake-prompt.md'), [Text.UTF8Encoding]::new($false, $true))
    Assert-TelephoneTest ($wakePrompt1.Contains('does not judge') -and $wakePrompt1.Contains([string]$receipt1Read.identity.sha256)) 'Execution callback omitted transport-only receipt identity.'
    Assert-TelephoneTest (@([IO.File]::ReadAllLines($leadLog)).Count -eq 1) 'Successful receipt was not delivered exactly once.'
    $null = & $resume -StateRoot $stateRoot; Scan-TelephoneTestState
    Start-Sleep -Milliseconds 300
    Assert-TelephoneTest (@([IO.File]::ReadAllLines($leadLog)).Count -eq 1) 'Recovery redelivered an already delivered receipt.'

    $duplicateFailed = $false
    $duplicateMessage = ''
    try {
        $null = & $starter -RequestFile $request1 -StateRoot $stateRoot
    } catch {
        $duplicateFailed = $true
        $duplicateMessage = [string]$_.Exception.Message
    }
    Assert-TelephoneTest $duplicateFailed 'A duplicate line-job id started a second command.'
    Assert-TelephoneTest ($duplicateMessage -match 'Resume-TelephoneLines') 'Duplicate job id did not direct recovery.'
    Assert-TelephoneTest (@([IO.File]::ReadAllLines($counter)).Count -eq 1) 'Duplicate job id reran the external route.'

    $job2 = [Guid]::NewGuid().ToString()
    $request2 = New-TelephoneTestRequest -JobId $job2 -Role review -DelayMilliseconds 900
    $start2 = ((& $starter -RequestFile $request2 -StateRoot $stateRoot) -join "`n") | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    Add-TelephoneTestTracked -Owner $start2.command_owner -Kind 'command_owner'
    Add-TelephoneTestTracked -Owner $start2.relay_owner -Kind 'relay_owner'
    Stop-Process -Id ([int]$start2.relay_owner.pid) -Force -ErrorAction Stop
    Wait-TelephoneTestPath -Path (Join-Path ([string]$start2.job_root) 'receipt.json')
    $null = & $resume -StateRoot $stateRoot; Scan-TelephoneTestState
    $null = & $resume -StateRoot $stateRoot; Scan-TelephoneTestState
    Wait-TelephoneTestPath -Path (Join-Path ([string]$start2.job_root) 'delivery.json')
    $wakePrompt2 = [IO.File]::ReadAllText((Join-Path ([string]$start2.job_root) 'wake-prompt.md'), [Text.UTF8Encoding]::new($false, $true))
    Assert-TelephoneTest ($wakePrompt2.Contains('role: review') -and $wakePrompt2.Contains('does not judge')) 'Review callback omitted opaque role metadata.'
    Assert-TelephoneTest (@([IO.File]::ReadAllLines($leadLog)).Count -eq 2) 'Concurrent relay recovery did not deliver the second receipt exactly once.'
    $claimFiles = @(Get-ChildItem -LiteralPath ([string]$start2.job_root) -Filter 'delivery-claim.json')
    Assert-TelephoneTest ($claimFiles.Count -eq 1) 'More than one delivery claim was published.'

    $job3 = [Guid]::NewGuid().ToString()
    $job3Root = Join-Path (Join-Path $stateRoot 'jobs') $job3
    [IO.Directory]::CreateDirectory($job3Root) | Out-Null
    $paths3 = Get-TelephoneJobPaths -JobRoot $job3Root
    $request3 = New-TelephoneTestRequest -JobId $job3 -Role execution -DelayMilliseconds 0
    $request3Read = Read-TelephoneJson -Path $request3
    $dispatch3 = New-TelephoneTestDurableDispatch -RequestRead $request3Read -LeadBindingPath $paths3.lead_binding
    $null = Write-TelephoneJsonCreateNew -Path $paths3.dispatch -Value $dispatch3
    $null = Write-TelephoneJsonCreateNew -Path $paths3.command_owner -Value ([ordered]@{ pid = 2147483647; start_time_utc_ticks = 1; started_at_utc = [DateTimeOffset]::UtcNow.ToString('o') })
    $null = & $resume -StateRoot $stateRoot; Scan-TelephoneTestState
    Wait-TelephoneTestPath -Path $paths3.delivery
    $receipt3 = (Read-TelephoneJson -Path $paths3.receipt -SchemaName 'receipt').value
    Assert-TelephoneTest ($receipt3.transport_complete -eq $false -and [string]$receipt3.command_error_code -ceq 'COMMAND_HOST_INTERRUPTED') 'Interrupted command host was not reported without rerun.'
    Assert-TelephoneTest ($receipt3.automatic_rerun -eq $false) 'Interrupted external task was automatically rerun.'
    Assert-TelephoneTest (@([IO.File]::ReadAllLines($counter)).Count -eq 2) 'Telephone recovery unexpectedly reran an external route.'
    Assert-TelephoneTest (@([IO.File]::ReadAllLines($leadLog)).Count -eq 3) 'Interrupted receipt was not delivered exactly once.'

    $stdinText = "utf8 stdin `nsecond line"
    $stdinPath = Join-Path $testRoot 'route-input.json'
    [IO.File]::WriteAllText($stdinPath, $stdinText, [Text.UTF8Encoding]::new($false))
    $job4 = [Guid]::NewGuid().ToString()
    $request4Path = Join-Path $testRoot ("request-$job4.json")
    $request4 = [ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = $job4
        project = 'telephone-test'
        stage = 'SIMULATION'
        role = 'review'
        route = 'mock-stdin-route'
        summary = 'stdin transport'
        lead = [ordered]@{
            protocol_version = 'telephone-line-lead-binding-v1'
            session_id = $sessionId
            worktree = $worktree
            launcher = [ordered]@{ path = $mockLead; arguments = @() }
        }
        command = [ordered]@{
            executable = $powerShellPath
            working_directory = $testRoot
            arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $mockStdinRoute)
            stdin_file = $stdinPath
        }
    }
    $null = Write-TelephoneJsonCreateNew -Path $request4Path -Value $request4
    $start4 = ((& $starter -RequestFile $request4Path -StateRoot $stateRoot) -join "`n") | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    Add-TelephoneTestTracked -Owner $start4.command_owner -Kind 'command_owner'
    Add-TelephoneTestTracked -Owner $start4.relay_owner -Kind 'relay_owner'
    Wait-TelephoneTestPath -Path (Join-Path ([string]$start4.job_root) 'delivery.json')
    $stdinResult = [IO.File]::ReadAllText((Join-Path ([string]$start4.job_root) 'route-stdout.txt'), [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json -AsHashtable -Depth 8
    $expectedStdinBase64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($stdinText))
    Assert-TelephoneTest ([string]$stdinResult.stdin_base64 -ceq $expectedStdinBase64) "Telephone command stdin was not transported byte-for-byte as UTF-8 text: expected=$expectedStdinBase64 actual=$([string]$stdinResult.stdin_base64)"
    $dispatch4 = (Read-TelephoneJson -Path (Join-Path ([string]$start4.job_root) 'dispatch.json') -SchemaName 'dispatch').value
    $dispatch4Json = $dispatch4 | ConvertTo-Json -Depth 8 -Compress
    Assert-TelephoneTest (-not $dispatch4Json.Contains($stdinText.Replace("`n", '\n')) -and -not $dispatch4Json.Contains('utf8 stdin')) 'Stdin bytes were copied into dispatch metadata.'
    Assert-TelephoneTest (@([IO.File]::ReadAllLines($leadLog)).Count -eq 4) 'Stdin-backed route receipt was not delivered exactly once.'

    $mismatchFailed = $false
    try {
        $null = Resolve-TelephoneLeadSessionId -Lead ([ordered]@{
            session_id = '01a00000-0000-7000-8000-000000000099'
            worktree = $worktree
            launcher = [ordered]@{ path = $mockLead; arguments = @() }
            binding_file = (Join-Path $job1Root 'lead-binding.json')
        })
    } catch { $mismatchFailed = $true }
    Assert-TelephoneTest $mismatchFailed 'An explicit session id bypassed the frozen Lead binding.'

    $sessionOnlyFailed = $false
    try {
        $null = Resolve-TelephoneLeadSessionId -Lead ([ordered]@{
            session_id = $sessionId
        })
    } catch { $sessionOnlyFailed = $true }
    Assert-TelephoneTest $sessionOnlyFailed 'A session id without its exact Lead binding was accepted.'

    $boundDispatchPath = Join-Path $testRoot 'bound-dispatch.json'
    $boundDispatch = [ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'; line_job_id = [Guid]::NewGuid().ToString(); project = 'telephone-test'; stage = 'SIMULATION'; role = 'execution'; route = 'mock'; summary = 'bound'
    }
    $boundDispatchIdentity = Write-TelephoneJsonCreateNew -Path $boundDispatchPath -Value $boundDispatch
    $badReceiptPath = Join-Path $testRoot 'bad-receipt.json'
    $null = Write-TelephoneJsonCreateNew -Path $badReceiptPath -Value ([ordered]@{
        protocol_version = 'telephone-line-receipt-v1'; line_job_id = [Guid]::NewGuid().ToString(); project = 'telephone-test'; stage = 'SIMULATION'; role = 'execution'; route = 'mock'; summary = 'bound'; dispatch = $boundDispatchIdentity; transport_complete = $true; command_exit_code = 0; command_error_code = $null; command_error_message = $null; stdout = $null; stderr = $null; started_at_utc = [DateTimeOffset]::UtcNow.ToString('o'); completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o'); absolute_task_timeout = $false; automatic_rerun = $false; project_judgment = $false
    })
    $badReceiptFailed = $false
    try { $null = Assert-TelephoneReceiptBound -ReceiptRead (Read-TelephoneJson -Path $badReceiptPath) -DispatchRead (Read-TelephoneJson -Path $boundDispatchPath) } catch { $badReceiptFailed = $true }
    Assert-TelephoneTest $badReceiptFailed 'A receipt with another line_job_id passed the dispatch binding gate.'

    $pendingJob = [Guid]::NewGuid().ToString()
    $pendingRoot = Join-Path (Join-Path $stateRoot 'jobs') $pendingJob
    [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
    $pendingPaths = Get-TelephoneJobPaths -JobRoot $pendingRoot
    $pendingRequest = Read-TelephoneJson -Path (New-TelephoneTestRequest -JobId $pendingJob -Role execution -DelayMilliseconds 0)
    $pendingDispatch = New-TelephoneTestDurableDispatch -RequestRead $pendingRequest -LeadBindingPath $pendingPaths.lead_binding
    $pendingDispatchIdentity = Write-TelephoneJsonCreateNew -Path $pendingPaths.dispatch -Value $pendingDispatch
    $pendingCommandHostIdentity = Get-TelephoneFileIdentity -Path $commandHost
    $null = Write-TelephoneJsonCreateNew -Path $pendingPaths.command_start_intent -Value ([ordered]@{
        protocol_version = 'telephone-line-command-start-v1'; line_job_id = $pendingJob; dispatch = $pendingDispatchIdentity; command_host = $pendingCommandHostIdentity; created_at_utc = [DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')
    })
    $pendingGate = Open-TelephoneExclusiveGate -Path $pendingPaths.command_gate -WaitMilliseconds 0
    if ($null -eq $pendingGate) { throw 'The causal startup test could not hold the command gate.' }
    try {
        $lateHost = Start-TelephoneHiddenPowerShell -ScriptPath $commandHost -Arguments @('-JobRoot', $pendingRoot)
        Add-TelephoneTestTracked -Owner $lateHost -Kind 'command_host'
        $pendingSummary = ((& $resume -StateRoot $stateRoot -CommandStartupGraceSeconds 1) -join "`n") | ConvertFrom-Json -AsHashtable -Depth 16
        Scan-TelephoneTestState
        Assert-TelephoneTest (-not [IO.File]::Exists($pendingPaths.receipt)) 'Recovery sealed a false failure while a late command host was waiting on the startup gate.'
        Assert-TelephoneTest ([int]$pendingSummary.command_start_pending -ge 1 -and [int]$pendingSummary.command_start_ambiguous_receipts_created -eq 0) 'Recovery did not preserve the gated late-host startup as pending.'
    } finally {
        $pendingGate.Dispose()
    }
    Scan-TelephoneTestDurableOwners -JobRoot $pendingRoot
    Wait-TelephoneTestPath -Path $pendingPaths.delivery
    $pendingReceipt = (Read-TelephoneJson -Path $pendingPaths.receipt -SchemaName 'receipt').value
    Assert-TelephoneTest ($pendingReceipt.transport_complete -eq $true -and [int]$pendingReceipt.command_exit_code -eq 0) "The late command host did not win the startup gate and complete exactly once: $($pendingReceipt | ConvertTo-Json -Depth 16 -Compress)"
    Assert-TelephoneTest ([IO.File]::Exists($pendingPaths.command_owner)) 'The late command host ran without publishing its durable owner.'

    $abandonedJob = [Guid]::NewGuid().ToString()
    $abandonedRoot = Join-Path (Join-Path $stateRoot 'jobs') $abandonedJob
    [IO.Directory]::CreateDirectory($abandonedRoot) | Out-Null
    $abandonedPaths = Get-TelephoneJobPaths -JobRoot $abandonedRoot
    $abandonedRequest = Read-TelephoneJson -Path (New-TelephoneTestRequest -JobId $abandonedJob -Role execution -DelayMilliseconds 0)
    $abandonedDispatch = New-TelephoneTestDurableDispatch -RequestRead $abandonedRequest -LeadBindingPath $abandonedPaths.lead_binding
    $abandonedDispatchIdentity = Write-TelephoneJsonCreateNew -Path $abandonedPaths.dispatch -Value $abandonedDispatch
    $null = Write-TelephoneJsonCreateNew -Path $abandonedPaths.command_start_intent -Value ([ordered]@{
        protocol_version = 'telephone-line-command-start-v1'; line_job_id = $abandonedJob; dispatch = $abandonedDispatchIdentity; command_host = $pendingCommandHostIdentity; created_at_utc = [DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')
    })
    $abandonedSummary = ((& $resume -StateRoot $stateRoot -CommandStartupGraceSeconds 1) -join "`n") | ConvertFrom-Json -AsHashtable -Depth 16
    Scan-TelephoneTestState
    Wait-TelephoneTestPath -Path $abandonedPaths.delivery
    $abandonedReceipt = (Read-TelephoneJson -Path $abandonedPaths.receipt -SchemaName 'receipt').value
    Assert-TelephoneTest ($abandonedReceipt.transport_complete -eq $false -and [string]$abandonedReceipt.command_error_code -ceq 'COMMAND_START_AMBIGUOUS_NO_RERUN') 'A truly abandoned command startup did not produce a durable no-rerun terminal.'
    Assert-TelephoneTest ($abandonedReceipt.automatic_rerun -eq $false -and [int]$abandonedSummary.command_start_ambiguous_receipts_created -eq 1) 'An abandoned command startup was rerun or not reported.'
    Scan-TelephoneTestDurableOwners -JobRoot $abandonedRoot

    $launchPendingJob = [Guid]::NewGuid().ToString()
    $launchPendingRoot = Join-Path (Join-Path $stateRoot 'jobs') $launchPendingJob
    [IO.Directory]::CreateDirectory($launchPendingRoot) | Out-Null
    $launchPendingPaths = Get-TelephoneJobPaths -JobRoot $launchPendingRoot
    $launchPendingRequest = Read-TelephoneJson -Path (New-TelephoneTestRequest -JobId $launchPendingJob -Role execution -DelayMilliseconds 0)
    $launchPendingDispatch = New-TelephoneTestDurableDispatch -RequestRead $launchPendingRequest -LeadBindingPath $launchPendingPaths.lead_binding
    $launchPendingDispatchIdentity = Write-TelephoneJsonCreateNew -Path $launchPendingPaths.dispatch -Value $launchPendingDispatch
    $current = Get-Process -Id $PID
    try {
        $liveLaunchOwner = [ordered]@{ pid = [int]$PID; start_time_utc_ticks = [int64]$current.StartTime.ToUniversalTime().Ticks; started_at_utc = $current.StartTime.ToUniversalTime().ToString('o') }
    } finally { $current.Dispose() }
    $null = Write-TelephoneJsonCreateNew -Path $launchPendingPaths.command_start_intent -Value ([ordered]@{
        protocol_version = 'telephone-line-command-start-v1'; line_job_id = $launchPendingJob; dispatch = $launchPendingDispatchIdentity; command_host = $pendingCommandHostIdentity; created_at_utc = [DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')
    })
    $null = Write-TelephoneJsonCreateNew -Path $launchPendingPaths.command_launch -Value ([ordered]@{
        protocol_version = 'telephone-line-command-launch-v1'; line_job_id = $launchPendingJob; dispatch = $launchPendingDispatchIdentity; owner = $liveLaunchOwner; launched_at_utc = [DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')
    })
    $null = & $resume -StateRoot $stateRoot; Scan-TelephoneTestState
    Start-Sleep -Milliseconds 200
    Assert-TelephoneTest (-not [IO.File]::Exists($launchPendingPaths.receipt)) 'Recovery misclassified a live launched host before its self-owner publication.'
    Scan-TelephoneTestDurableOwners -JobRoot $launchPendingRoot

    $wakeErrorJob = [Guid]::NewGuid().ToString()
    $failingLauncher = Join-Path $testRoot 'failing-lead-launcher.ps1'
    [IO.File]::WriteAllText($failingLauncher, @"
# SPDX-License-Identifier: MPL-2.0
param([string]`$WorktreePath, [string]`$PromptFile, [string]`$ResumeSessionId, [string]`$RunId)
throw 'mock lead launcher refused to start'
"@, [Text.UTF8Encoding]::new($false))
    $wakeErrorRequest = New-TelephoneTestRequest -JobId $wakeErrorJob -Role review -DelayMilliseconds 0 -LauncherPath $failingLauncher
    $wakeErrorStart = ((& $starter -RequestFile $wakeErrorRequest -StateRoot $stateRoot) -join "`n") | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    Add-TelephoneTestTracked -Owner $wakeErrorStart.command_owner -Kind 'command_owner'
    Add-TelephoneTestTracked -Owner $wakeErrorStart.relay_owner -Kind 'relay_owner'
    $wakeErrorPaths = Get-TelephoneJobPaths -JobRoot ([string]$wakeErrorStart.job_root)
    Wait-TelephoneTestPath -Path $wakeErrorPaths.relay_error -Seconds 20
    $wakeError = (Read-TelephoneJson -Path $wakeErrorPaths.relay_error).value
    Assert-TelephoneTest ([string]$wakeError.protocol_version -ceq 'telephone-line-relay-error-v1' -and $wakeError.retrying -eq $false) 'A permanent Lead wake failure did not fail closed.'
    Assert-TelephoneTest ([string]$wakeError.error_code -ceq 'LEAD_WAKE_AMBIGUOUS' -or [string]$wakeError.error_code -ceq 'LEAD_WAKE_FAILED') 'A permanent Lead wake failure lacked a stable error code.'
    Assert-TelephoneTest (Test-TelephoneKnownPublicErrorMessage -Message ([string]$wakeError.error_message)) 'A permanent Lead wake failure stored a non-generic error message.'
    Assert-TelephoneTest (-not ([string]$wakeError.error_message).Contains('refused to start')) 'A permanent Lead wake failure stored raw launcher text.'
    Assert-TelephoneTest (-not [IO.File]::Exists($wakeErrorPaths.delivery)) 'Relay published delivery despite a permanently failing Lead launcher.'

    $missingLauncherFailed = $false
    try {
        $null = Read-TelephoneLeadBinding -Lead ([ordered]@{
            protocol_version = 'telephone-line-lead-binding-v1'
            session_id = $sessionId
            worktree = $worktree
            launcher = [ordered]@{ path = (Join-Path $testRoot 'missing-lead-launcher.ps1'); arguments = @() }
        })
    } catch { $missingLauncherFailed = $true }
    Assert-TelephoneTest $missingLauncherFailed 'A missing Lead launcher was accepted as a regular file.'

    $wrongAckFailed = $false
    try {
        $null = Wait-TelephoneLeadWakeAcknowledged -RunRoot $ackRoot -ExpectedSessionId 'other-session' -StartupTimeoutSeconds 1
    } catch { $wrongAckFailed = $true }
    Assert-TelephoneTest $wrongAckFailed 'A wake acknowledgment for another session was accepted.'

    $at = [char]64
    $promptSentinel = 'TLV01C2PROMPT' + [Guid]::NewGuid().ToString('N')
    $emailSentinel = 'tlv01c2.' + [Guid]::NewGuid().ToString('N') + $at + 'example.test'
    $pathSentinel = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('tlv01c2-' + [Guid]::NewGuid().ToString('N'))
    $rawSensitive = $promptSentinel + ' ' + $emailSentinel + ' ' + $pathSentinel
    $sanitized = Get-TelephoneSanitizedMessage -Message $rawSensitive
    Assert-TelephoneTest (Test-TelephoneKnownPublicErrorMessage -Message $sanitized) 'Unknown error text was not replaced with a generic public message.'
    Assert-TelephoneTest (
        (-not $sanitized.Contains($promptSentinel)) -and
        (-not $sanitized.Contains($emailSentinel)) -and
        (-not $sanitized.Contains($pathSentinel))
    ) 'Sanitizer retained a synthetic sensitive sentinel.'

    $hostFailJob = [Guid]::NewGuid().ToString()
    $hostFailRoot = Join-Path (Join-Path $stateRoot 'jobs') $hostFailJob
    [IO.Directory]::CreateDirectory($hostFailRoot) | Out-Null
    $hostFailPaths = Get-TelephoneJobPaths -JobRoot $hostFailRoot
    $hostFailRequest = Read-TelephoneJson -Path (New-TelephoneTestRequest -JobId $hostFailJob -Role execution -DelayMilliseconds 0)
    $hostFailDispatch = New-TelephoneTestDurableDispatch -RequestRead $hostFailRequest -LeadBindingPath $hostFailPaths.lead_binding
    $hostFailDispatch.command.stdin = [ordered]@{
        path = (Join-Path $pathSentinel ($promptSentinel + '-' + $emailSentinel))
        bytes = 1
        sha256 = ('0123456789abcdef' * 4)
    }
    $null = Write-TelephoneJsonCreateNew -Path $hostFailPaths.dispatch -Value $hostFailDispatch
    $hostFailOwner = Start-TelephoneHiddenPowerShell -ScriptPath $commandHost -Arguments @('-JobRoot', $hostFailRoot)
    Add-TelephoneTestTracked -Owner $hostFailOwner -Kind 'command_host'
    Wait-TelephoneTestPath -Path $hostFailPaths.receipt
    $hostFailReceipt = (Read-TelephoneJson -Path $hostFailPaths.receipt -SchemaName 'receipt').value
    Assert-TelephoneTest ($hostFailReceipt.transport_complete -eq $true -and [string]$hostFailReceipt.command_error_code -ceq 'COMMAND_HOST_ERROR') 'Command-host failure did not publish a stable transport error code.'
    Assert-TelephoneTest (Test-TelephoneKnownPublicErrorMessage -Message ([string]$hostFailReceipt.command_error_message)) 'Command-host failure did not publish a generic public error message.'
    $hostFailSentinelCount = Get-TelephoneTestDurableSentinelCount -JobRoot $hostFailRoot -Sentinels @($promptSentinel, $emailSentinel, $pathSentinel)
    Assert-TelephoneTest ($hostFailSentinelCount -eq 0) 'Command-host durable artifacts retained a synthetic sensitive sentinel.'

    $sensitiveWakeJob = [Guid]::NewGuid().ToString()
    $sensitiveLauncher = Join-Path $testRoot 'sensitive-lead-launcher.ps1'
    [IO.File]::WriteAllText($sensitiveLauncher, @"
# SPDX-License-Identifier: MPL-2.0
param([string]`$WorktreePath, [string]`$PromptFile, [string]`$ResumeSessionId, [string]`$RunId)
throw [string]`$env:TELEPHONE_TEST_LEAD_THROW_MESSAGE
"@, [Text.UTF8Encoding]::new($false))
    $env:TELEPHONE_TEST_LEAD_THROW_MESSAGE = $rawSensitive
    try {
        $sensitiveRequest = New-TelephoneTestRequest -JobId $sensitiveWakeJob -Role review -DelayMilliseconds 0 -LauncherPath $sensitiveLauncher
        $sensitiveStart = ((& $starter -RequestFile $sensitiveRequest -StateRoot $stateRoot) -join "`n") | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
        Add-TelephoneTestTracked -Owner $sensitiveStart.command_owner -Kind 'command_owner'
        Add-TelephoneTestTracked -Owner $sensitiveStart.relay_owner -Kind 'relay_owner'
        $sensitivePaths = Get-TelephoneJobPaths -JobRoot ([string]$sensitiveStart.job_root)
        Wait-TelephoneTestPath -Path $sensitivePaths.relay_error
        $sensitiveError = (Read-TelephoneJson -Path $sensitivePaths.relay_error).value
        Assert-TelephoneTest ($sensitiveError.retrying -eq $false -and (Test-TelephoneKnownPublicErrorMessage -Message ([string]$sensitiveError.error_message))) 'Lead-launcher failure did not publish fail-closed generic error state.'
        $sensitiveSentinelCount = Get-TelephoneTestDurableSentinelCount -JobRoot $sensitivePaths.root -Sentinels @($promptSentinel, $emailSentinel, $pathSentinel)
        Assert-TelephoneTest ($sensitiveSentinelCount -eq 0) 'Lead-launcher durable artifacts retained a synthetic sensitive sentinel.'
        Assert-TelephoneTest (-not [IO.File]::Exists($sensitivePaths.delivery)) 'Lead-launcher failure published a delivery.'
    } finally {
        Remove-Item Env:TELEPHONE_TEST_LEAD_THROW_MESSAGE -ErrorAction SilentlyContinue
    }
    $durableSensitiveErrorAbsent = 1

    $idempotentRunId = 'telephone-idempotent-' + [Guid]::NewGuid().ToString('N')
    $idempotentPrompt = Join-Path $testRoot 'idempotent-wake.md'
    [IO.File]::WriteAllText($idempotentPrompt, 'wake', [Text.UTF8Encoding]::new($false))
    $null = & $mockLead -WorktreePath $worktree -PromptFile $idempotentPrompt -ResumeSessionId $sessionId -RunId $idempotentRunId
    $null = & $mockLead -WorktreePath $worktree -PromptFile $idempotentPrompt -ResumeSessionId $sessionId -RunId $idempotentRunId
    Assert-TelephoneTest ((Get-TelephoneTestTurnCount -RunId $idempotentRunId) -eq 1) 'Launcher contract created a second Lead turn for the same wake identity.'

    $relayScript = Join-Path $repoRoot 'src\core\Invoke-TelephoneLineRelay.ps1'
    $concurrentJob = [Guid]::NewGuid().ToString()
    $concurrentRoot = Join-Path (Join-Path $stateRoot 'jobs') $concurrentJob
    [IO.Directory]::CreateDirectory($concurrentRoot) | Out-Null
    $concurrentPaths = Get-TelephoneJobPaths -JobRoot $concurrentRoot
    $concurrentRequest = Read-TelephoneJson -Path (New-TelephoneTestRequest -JobId $concurrentJob -Role execution -DelayMilliseconds 0)
    $concurrentDispatch = New-TelephoneTestDurableDispatch -RequestRead $concurrentRequest -LeadBindingPath $concurrentPaths.lead_binding
    $null = Write-TelephoneJsonCreateNew -Path $concurrentPaths.dispatch -Value $concurrentDispatch
    $concurrentDispatchRead = Read-TelephoneJson -Path $concurrentPaths.dispatch -SchemaName 'dispatch'
    $null = Write-TelephoneJsonCreateNew -Path $concurrentPaths.receipt -Value (New-TelephoneTestSealedReceipt -DispatchRead $concurrentDispatchRead)
    $concurrentRelay1 = Start-TelephoneHiddenPowerShell -ScriptPath $relayScript -Arguments @('-JobRoot', $concurrentRoot)
    $concurrentRelay2 = Start-TelephoneHiddenPowerShell -ScriptPath $relayScript -Arguments @('-JobRoot', $concurrentRoot)
    Add-TelephoneTestTracked -Owner $concurrentRelay1 -Kind 'relay'
    Add-TelephoneTestTracked -Owner $concurrentRelay2 -Kind 'relay'
    Wait-TelephoneTestPath -Path $concurrentPaths.delivery
    $concurrentRunId = 'telephone-' + $concurrentJob.ToLowerInvariant()
    Assert-TelephoneTest ((Get-TelephoneTestTurnCount -RunId $concurrentRunId) -eq 1) 'Concurrent relays created more than one distinct Lead turn.'
    Assert-TelephoneTest (@(Get-ChildItem -LiteralPath $concurrentRoot -Filter 'delivery.json').Count -eq 1) 'Concurrent relays published more than one delivery object.'
    Assert-TelephoneTest (@(Get-ChildItem -LiteralPath $concurrentRoot -Filter 'wake-attempt.json').Count -eq 1) 'Concurrent relays published more than one wake attempt.'

    $restartJob = [Guid]::NewGuid().ToString()
    $restartRoot = Join-Path (Join-Path $stateRoot 'jobs') $restartJob
    [IO.Directory]::CreateDirectory($restartRoot) | Out-Null
    $restartPaths = Get-TelephoneJobPaths -JobRoot $restartRoot
    $restartRequest = Read-TelephoneJson -Path (New-TelephoneTestRequest -JobId $restartJob -Role review -DelayMilliseconds 0)
    $restartDispatch = New-TelephoneTestDurableDispatch -RequestRead $restartRequest -LeadBindingPath $restartPaths.lead_binding
    $null = Write-TelephoneJsonCreateNew -Path $restartPaths.dispatch -Value $restartDispatch
    $restartDispatchRead = Read-TelephoneJson -Path $restartPaths.dispatch -SchemaName 'dispatch'
    $restartReceipt = New-TelephoneTestSealedReceipt -DispatchRead $restartDispatchRead
    $null = Write-TelephoneJsonCreateNew -Path $restartPaths.receipt -Value $restartReceipt
    $restartReceiptRead = Read-TelephoneJson -Path $restartPaths.receipt -SchemaName 'receipt'
    $restartWake = New-TelephoneWakeIdentity -LineJobId $restartJob -ReceiptIdentity $restartReceiptRead.identity -LeadSessionId $sessionId
    $null = Write-TelephoneJsonCreateNew -Path $restartPaths.delivery_claim -Value ([ordered]@{
        protocol_version = 'telephone-line-delivery-claim-v1'
        line_job_id = $restartJob
        lead_session_id = $sessionId
        lead_worktree = $worktree
        wake_run_id = [string]$restartWake.wake_run_id
        wake_key = [string]$restartWake.wake_key
        claimed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $null = Write-TelephoneJsonCreateNew -Path $restartPaths.wake_intent -Value ([ordered]@{
        protocol_version = 'telephone-line-wake-intent-v1'
        line_job_id = $restartJob
        lead_session_id = $sessionId
        wake_run_id = [string]$restartWake.wake_run_id
        wake_key = [string]$restartWake.wake_key
        receipt = $restartReceiptRead.identity
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $restartRelay = Start-TelephoneHiddenPowerShell -ScriptPath $relayScript -Arguments @('-JobRoot', $restartRoot)
    Add-TelephoneTestTracked -Owner $restartRelay -Kind 'relay'
    Wait-TelephoneTestPath -Path $restartPaths.delivery
    Assert-TelephoneTest ((Get-TelephoneTestTurnCount -RunId ([string]$restartWake.wake_run_id)) -eq 1) 'Restart after claim created more than one distinct Lead turn.'

    $attemptJob = [Guid]::NewGuid().ToString()
    $attemptRoot = Join-Path (Join-Path $stateRoot 'jobs') $attemptJob
    [IO.Directory]::CreateDirectory($attemptRoot) | Out-Null
    $attemptPaths = Get-TelephoneJobPaths -JobRoot $attemptRoot
    $attemptRequest = Read-TelephoneJson -Path (New-TelephoneTestRequest -JobId $attemptJob -Role execution -DelayMilliseconds 0)
    $attemptDispatch = New-TelephoneTestDurableDispatch -RequestRead $attemptRequest -LeadBindingPath $attemptPaths.lead_binding
    $null = Write-TelephoneJsonCreateNew -Path $attemptPaths.dispatch -Value $attemptDispatch
    $attemptDispatchRead = Read-TelephoneJson -Path $attemptPaths.dispatch -SchemaName 'dispatch'
    $null = Write-TelephoneJsonCreateNew -Path $attemptPaths.receipt -Value (New-TelephoneTestSealedReceipt -DispatchRead $attemptDispatchRead)
    $attemptReceiptRead = Read-TelephoneJson -Path $attemptPaths.receipt -SchemaName 'receipt'
    $attemptWake = New-TelephoneWakeIdentity -LineJobId $attemptJob -ReceiptIdentity $attemptReceiptRead.identity -LeadSessionId $sessionId
    $preWakePrompt = Join-Path $testRoot ('pre-wake-' + $attemptJob + '.md')
    [IO.File]::WriteAllText($preWakePrompt, 'pre-wake', [Text.UTF8Encoding]::new($false))
    $null = & $mockLead -WorktreePath $worktree -PromptFile $preWakePrompt -ResumeSessionId $sessionId -RunId ([string]$attemptWake.wake_run_id)
    Assert-TelephoneTest ((Get-TelephoneTestTurnCount -RunId ([string]$attemptWake.wake_run_id)) -eq 1) 'Pre-crash launcher side effect did not create the first Lead turn.'
    $null = Write-TelephoneJsonCreateNew -Path $attemptPaths.delivery_claim -Value ([ordered]@{
        protocol_version = 'telephone-line-delivery-claim-v1'
        line_job_id = $attemptJob
        lead_session_id = $sessionId
        lead_worktree = $worktree
        wake_run_id = [string]$attemptWake.wake_run_id
        wake_key = [string]$attemptWake.wake_key
        claimed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $null = Write-TelephoneJsonCreateNew -Path $attemptPaths.wake_intent -Value ([ordered]@{
        protocol_version = 'telephone-line-wake-intent-v1'
        line_job_id = $attemptJob
        lead_session_id = $sessionId
        wake_run_id = [string]$attemptWake.wake_run_id
        wake_key = [string]$attemptWake.wake_key
        receipt = $attemptReceiptRead.identity
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $null = Write-TelephoneJsonCreateNew -Path $attemptPaths.wake_attempt -Value ([ordered]@{
        protocol_version = 'telephone-line-wake-attempt-v1'
        line_job_id = $attemptJob
        lead_session_id = $sessionId
        wake_run_id = [string]$attemptWake.wake_run_id
        wake_key = [string]$attemptWake.wake_key
        receipt = $attemptReceiptRead.identity
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $attemptRelay = Start-TelephoneHiddenPowerShell -ScriptPath $relayScript -Arguments @('-JobRoot', $attemptRoot)
    Add-TelephoneTestTracked -Owner $attemptRelay -Kind 'relay'
    Wait-TelephoneTestPath -Path $attemptPaths.delivery
    Assert-TelephoneTest ((Get-TelephoneTestTurnCount -RunId ([string]$attemptWake.wake_run_id)) -eq 1) 'Recovery after claim and attempt created a second Lead turn.'

    $ambiguousJob = [Guid]::NewGuid().ToString()
    $ambiguousRequest = New-TelephoneTestRequest -JobId $ambiguousJob -Role execution -DelayMilliseconds 0
    $ambiguousRunId = 'telephone-' + $ambiguousJob.ToLowerInvariant()
    $env:TELEPHONE_TEST_LEAD_THROW_AFTER_WAKE = $ambiguousRunId
    try {
        $ambiguousStart = ((& $starter -RequestFile $ambiguousRequest -StateRoot $stateRoot) -join "`n") | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
        Add-TelephoneTestTracked -Owner $ambiguousStart.command_owner -Kind 'command_owner'
        Add-TelephoneTestTracked -Owner $ambiguousStart.relay_owner -Kind 'relay_owner'
        $ambiguousPaths = Get-TelephoneJobPaths -JobRoot ([string]$ambiguousStart.job_root)
        Wait-TelephoneTestPath -Path $ambiguousPaths.delivery
        Assert-TelephoneTest ((Get-TelephoneTestTurnCount -RunId $ambiguousRunId) -eq 1) 'Ambiguous post-launch failure created a second Lead turn.'
        Assert-TelephoneTest ([IO.File]::Exists($ambiguousPaths.wake_attempt)) 'Ambiguous wake did not persist a create-new attempt.'
        $ambiguousDelivery = (Read-TelephoneJson -Path $ambiguousPaths.delivery).value
        Assert-TelephoneTest ([string]$ambiguousDelivery.lead_session_id -ceq $sessionId) 'Ambiguous-wake recovery did not bind the exact Lead session.'
    } finally {
        Remove-Item Env:TELEPHONE_TEST_LEAD_THROW_AFTER_WAKE -ErrorAction SilentlyContinue
    }
    $ambiguousWakeAtMostOnce = 1

    $namedArgsJob = [Guid]::NewGuid().ToString()
    $namedArgsLauncher = Join-Path $testRoot 'named-args-lead-launcher.ps1'
    $namedArgsState = Join-Path $testRoot 'named-args-state'
    $namedArgsCodex = Join-Path $testRoot 'named-args-codex.cmd'
    $namedArgsProfile = Join-Path $testRoot 'named-args-profile.json'
    $namedArgsTrace = Join-Path $testRoot 'named-args-ok.txt'
    [IO.Directory]::CreateDirectory($namedArgsState) | Out-Null
    [IO.File]::WriteAllText($namedArgsLauncher, @"
param(
    [string]`$WorktreePath, [string]`$PromptFile, [string]`$ResumeSessionId, [string]`$RunId,
    [string]`$StateRoot, [string]`$CodexCommand, [string]`$ProfilePath
)
`$ErrorActionPreference = 'Stop'
if (`$StateRoot -cne '$($namedArgsState.Replace("'", "''"))' -or `$CodexCommand -cne '$($namedArgsCodex.Replace("'", "''"))' -or `$ProfilePath -cne '$($namedArgsProfile.Replace("'", "''"))') { throw 'named launcher arguments were not bound' }
[IO.File]::WriteAllText('$($namedArgsTrace.Replace("'", "''"))', 'ok', [Text.UTF8Encoding]::new(`$false))
`$result = @(& '$($mockLead.Replace("'", "''"))' -WorktreePath `$WorktreePath -PromptFile `$PromptFile -ResumeSessionId `$ResumeSessionId -RunId `$RunId)
[Console]::Out.Write((`$result -join "`n"))
"@, [Text.UTF8Encoding]::new($false))
    $namedArgsRequest = New-TelephoneTestRequest -JobId $namedArgsJob -Role execution -DelayMilliseconds 0 -LauncherPath $namedArgsLauncher -LauncherArguments @('-StateRoot',$namedArgsState,'-CodexCommand',$namedArgsCodex,'-ProfilePath',$namedArgsProfile)
    $namedArgsStart = ((& $starter -RequestFile $namedArgsRequest -StateRoot $stateRoot) -join "`n") | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    Add-TelephoneTestTracked -Owner $namedArgsStart.command_owner -Kind 'command_owner'
    Add-TelephoneTestTracked -Owner $namedArgsStart.relay_owner -Kind 'relay_owner'
    Wait-TelephoneTestPath -Path (Join-Path ([string]$namedArgsStart.job_root) 'delivery.json')
    Assert-TelephoneTest ([IO.File]::Exists($namedArgsTrace)) 'Frozen named launcher arguments were replayed positionally instead of by name.'
    Assert-TelephoneTest (-not [IO.File]::Exists((Join-Path ([string]$namedArgsStart.job_root) 'relay-error.json'))) 'Valid frozen named launcher arguments produced a relay error.'
    $namedLauncherArguments = 1

    $nativeJobDelivery = 0
    $nativeOwnerAliveAtDelivery = 0
    $nativeJobNoDuplicate = 0
    $nativeJobQuiesced = 0
    $env:TELEPHONE_TEST_LEAD_NATIVE_EVENTS = '1'
    try {
        Stop-TelephoneTestMailboxCollectors
        $nativeJobId = [Guid]::NewGuid().ToString()
        $nativeJobRequest = New-TelephoneTestRequest -JobId $nativeJobId -Role execution -DelayMilliseconds 0
        $nativeJobStart = ((& $starter -RequestFile $nativeJobRequest -StateRoot $stateRoot) -join "`n") | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
        Add-TelephoneTestTracked -Owner $nativeJobStart.command_owner -Kind 'command_owner'
        Add-TelephoneTestTracked -Owner $nativeJobStart.relay_owner -Kind 'relay_owner'
        $nativeJobPaths = Get-TelephoneJobPaths -JobRoot ([string]$nativeJobStart.job_root)
        Wait-TelephoneTestPath -Path $nativeJobPaths.delivery
        $nativeWakeRunId = 'telephone-' + $nativeJobId.ToLowerInvariant()
        $nativeJobRunRoot = Join-Path $leadRuns $nativeWakeRunId
        Assert-TelephoneTest ([IO.File]::Exists((Join-Path $nativeJobRunRoot 'lead-run.json'))) 'Native wired job did not publish lead-run.json.'
        Assert-TelephoneTest ([IO.File]::Exists((Join-Path $nativeJobRunRoot 'codex-events.jsonl'))) 'Native wired job did not publish codex-events.jsonl.'
        Assert-TelephoneTest ([IO.File]::Exists((Join-Path $nativeJobRunRoot 'lead-wake-ack.json'))) 'Native wired pair was not persisted as canonical lead-wake-ack.json.'
        Assert-TelephoneTest (-not [IO.File]::Exists((Join-Path $nativeJobRunRoot 'launcher-final.txt'))) 'Native wired launcher waited for Lead final output before acknowledging.'
        $nativeJobOwner = (Read-TelephoneJson -Path (Join-Path $nativeJobRunRoot 'owner.json')).value
        Add-TelephoneTestTracked -Owner $nativeJobOwner -Kind 'lead_owner'
        Assert-TelephoneTest (Test-TelephoneOwnerAlive -Owner $nativeJobOwner) 'Native delivery was published after the owning Lead died.'
        $nativeOwnerAliveAtDelivery = 1
        $nativeJobDeliveryValue = (Read-TelephoneJson -Path $nativeJobPaths.delivery).value
        Assert-TelephoneTest ([string]$nativeJobDeliveryValue.lead_session_id -ceq $sessionId) 'Native wired delivery bound a different Lead session.'
        Assert-TelephoneTest ([string]$nativeJobDeliveryValue.wake_acknowledgment.event -ceq 'turn.started') 'Native wired delivery omitted the exact turn.started acknowledgment.'
        Assert-TelephoneTest ((Get-TelephoneTestTurnCount -RunId $nativeWakeRunId) -eq 1) 'Native wired job did not create exactly one owner turn.'
        Assert-TelephoneTest (-not [IO.File]::Exists($nativeJobPaths.relay_error)) 'Native wired job wrote a relay error after exact acknowledgment.'
        $nativeJobDelivery = 1
        $relayDeadDeadline = [DateTimeOffset]::UtcNow.AddSeconds(20)
        while ([DateTimeOffset]::UtcNow -lt $relayDeadDeadline) {
            $relayAlive = $null
            try { $relayAlive = Get-Process -Id ([int]$nativeJobStart.relay_owner.pid) -ErrorAction SilentlyContinue } catch { $relayAlive = $null }
            if ($null -eq $relayAlive) { break }
            try { $relayAlive.Dispose() } catch { }
            Start-Sleep -Milliseconds 100
        }
        $relayStill = Get-Process -Id ([int]$nativeJobStart.relay_owner.pid) -ErrorAction SilentlyContinue
        Assert-TelephoneTest ($null -eq $relayStill) 'Native wired relay did not quiesce after delivery.'
        if ($null -ne $relayStill) { try { $relayStill.Dispose() } catch { } }
        $releasedLock = $null
        try {
            $releasedLock = [IO.File]::Open($nativeJobPaths.delivery_lock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch {
            throw 'Native wired delivery lock stayed held.'
        } finally {
            if ($null -ne $releasedLock) { $releasedLock.Dispose() }
        }
        Assert-TelephoneTest ($true) 'Native wired delivery lock was released.'
        $nativeJobQuiesced = 1
        $null = & $resume -StateRoot $stateRoot; Scan-TelephoneTestState
        Start-Sleep -Milliseconds 300
        Assert-TelephoneTest ((Get-TelephoneTestTurnCount -RunId $nativeWakeRunId) -eq 1) 'Native wired replay/recovery created a second owner turn.'
        Assert-TelephoneTest (@(Get-ChildItem -LiteralPath ([string]$nativeJobStart.job_root) -Filter 'delivery.json').Count -eq 1) 'Native wired replay/recovery published a second delivery.'
        $nativeJobNoDuplicate = 1
    } finally {
        Remove-Item Env:TELEPHONE_TEST_LEAD_NATIVE_EVENTS -ErrorAction SilentlyContinue
    }

    $counterBeforeChild = if ([IO.File]::Exists($counter)) { @(Get-Content -LiteralPath $counter).Count } else { 0 }
    $jobAfter = [Guid]::NewGuid().ToString()
    $requestAfter = New-TelephoneTestRequest -JobId $jobAfter -Role execution -DelayMilliseconds 400
    $startAfter = ((& $starter -RequestFile $requestAfter -StateRoot $stateRoot) -join "`n") | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    Add-TelephoneTestTracked -Owner $startAfter.command_owner -Kind 'command_owner'
    Add-TelephoneTestTracked -Owner $startAfter.relay_owner -Kind 'relay_owner'
    $afterRoot = [string]$startAfter.job_root
    $afterPaths = Get-TelephoneJobPaths -JobRoot $afterRoot
    Wait-TelephoneTestPath -Path $afterPaths.command_child
    Wait-TelephoneTestPath -Path $afterPaths.stdout
    $stdoutDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while ([DateTimeOffset]::UtcNow -lt $stdoutDeadline -and ([IO.FileInfo]::new($afterPaths.stdout).Length -le 0)) {
        Start-Sleep -Milliseconds 50
    }
    Assert-TelephoneTest (([IO.FileInfo]::new($afterPaths.stdout).Length -gt 0)) 'Child did not publish stdout before owner kill.'
    Stop-Process -Id ([int]$startAfter.command_owner.pid) -Force -ErrorAction Stop
    Wait-TelephoneTestPath -Path $afterPaths.delivery -Seconds 25
    $receiptAfter = (Read-TelephoneJson -Path $afterPaths.receipt -SchemaName 'receipt').value
    Assert-TelephoneTest ($receiptAfter.transport_complete -eq $true) 'Killing the command owner after child publication did not reconcile the same receipt.'
    $childExitAfter = if ([IO.File]::Exists($afterPaths.command_child_exit)) { (Read-TelephoneJson -Path $afterPaths.command_child_exit).value.command_exit_code } else { $null }
    if ($null -eq $childExitAfter) {
        Assert-TelephoneTest ($null -eq $receiptAfter.command_exit_code) 'Owner-death recovery invented success without a known child exit code.'
    } else {
        Assert-TelephoneTest ($childExitAfter -eq 0 -and $receiptAfter.command_exit_code -eq $childExitAfter) 'Owner-death recovery did not preserve the actual child exit code.'
    }
    Assert-TelephoneTest (@(Get-Content -LiteralPath $counter).Count -eq ($counterBeforeChild + 1)) 'Owner-death reconciliation reran the route.'
    $dead_owner_after_child_reconciled = 1

    $jobBefore = [Guid]::NewGuid().ToString()
    $requestBefore = New-TelephoneTestRequest -JobId $jobBefore -Role execution -DelayMilliseconds 1800
    $startBefore = ((& $starter -RequestFile $requestBefore -StateRoot $stateRoot) -join "`n") | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    Add-TelephoneTestTracked -Owner $startBefore.command_owner -Kind 'command_owner'
    Add-TelephoneTestTracked -Owner $startBefore.relay_owner -Kind 'relay_owner'
    $beforePaths = Get-TelephoneJobPaths -JobRoot ([string]$startBefore.job_root)
    Wait-TelephoneTestPath -Path $beforePaths.command_child
    Start-Sleep -Milliseconds 150
    Assert-TelephoneTest (-not [IO.File]::Exists($beforePaths.receipt)) 'Child published a receipt before the before-publication kill.'
    Stop-Process -Id ([int]$startBefore.command_owner.pid) -Force -ErrorAction Stop
    Wait-TelephoneTestPath -Path $beforePaths.delivery -Seconds 25
    $receiptBefore = (Read-TelephoneJson -Path $beforePaths.receipt -SchemaName 'receipt').value
    Assert-TelephoneTest ($receiptBefore.transport_complete -eq $true) 'Killing the command owner before child publication did not wait for the live child.'
    Assert-TelephoneTest (@(Get-Content -LiteralPath $counter).Count -eq ($counterBeforeChild + 2)) 'Before-publication owner death reran the route.'
    $dead_owner_before_child_waited = 1

    $jobMissing = [Guid]::NewGuid().ToString()
    $missingRoot = Join-Path (Join-Path $stateRoot 'jobs') $jobMissing
    [IO.Directory]::CreateDirectory($missingRoot) | Out-Null
    $missingPaths = Get-TelephoneJobPaths -JobRoot $missingRoot
    $missingRequest = Read-TelephoneJson -Path (New-TelephoneTestRequest -JobId $jobMissing -Role execution -DelayMilliseconds 0)
    $missingDispatch = New-TelephoneTestDurableDispatch -RequestRead $missingRequest -LeadBindingPath $missingPaths.lead_binding
    $null = Write-TelephoneJsonCreateNew -Path $missingPaths.dispatch -Value $missingDispatch
    $null = Write-TelephoneJsonCreateNew -Path $missingPaths.command_owner -Value ([ordered]@{ pid = 2147483646; start_time_utc_ticks = 2; started_at_utc = [DateTimeOffset]::UtcNow.ToString('o') })
    $null = Write-TelephoneJsonCreateNew -Path $missingPaths.command_child -Value ([ordered]@{ pid = 2147483645; start_time_utc_ticks = 3; started_at_utc = [DateTimeOffset]::UtcNow.ToString('o'); line_job_id = $jobMissing })
    $null = Sync-TelephoneCommandOwnerCompletion -Paths $missingPaths
    Assert-TelephoneTest ([IO.File]::Exists($missingPaths.receipt)) 'Missing child result did not fail closed.'
    $missingReceipt = (Read-TelephoneJson -Path $missingPaths.receipt -SchemaName 'receipt').value
    Assert-TelephoneTest ($missingReceipt.transport_complete -eq $false -and [string]$missingReceipt.command_error_code -ceq 'COMMAND_HOST_INTERRUPTED') 'Absent child result was converted into success.'
    $dead_owner_missing_result_fail_closed = 1

    $result = [ordered]@{
        success = $true
        asynchronous_lead_exit = 1
        exact_session_wake = 1
        relay_restart = 1
        concurrent_delivery_idempotence = 1
        atomic_receipt_and_wake_ack = 1
        exact_lead_binding = 1
        duplicate_job_suppressed = 1
        command_start_race_closed = 1
        receipt_owner_ordering = $receiptOwnerOrdering
        unknown_exit_preserved = $unknownExitPreserved
        detached_worker_stdio = 1
        durable_wake_error = 1
        interrupted_no_rerun = 1
        dead_owner_after_child_reconciled = $dead_owner_after_child_reconciled
        dead_owner_before_child_waited = $dead_owner_before_child_waited
        dead_owner_missing_result_fail_closed = $dead_owner_missing_result_fail_closed
        stdin_transport = 1
        durable_sensitive_error_absent = $durableSensitiveErrorAbsent
        ambiguous_wake_at_most_once = $ambiguousWakeAtMostOnce
        named_launcher_arguments = $namedLauncherArguments
        native_open_ack = $nativeOpenAck
        native_negatives_closed = $nativeNegativesClosed
        native_job_delivery = $nativeJobDelivery
        native_owner_alive_at_delivery = $nativeOwnerAliveAtDelivery
        native_job_no_duplicate = $nativeJobNoDuplicate
        native_job_quiesced = $nativeJobQuiesced
        absolute_task_timeout = 0
        project_judgment = 0
        automatic_rerun = 0
        residue_live_processes = 1
        residue_live_owners = 1
        residue_held_locks = 1
        test_root_absent = 0
        caller_preserved = 0
        assertions = $assertions
    }
    Complete-TelephoneTestCleanup
    Assert-TelephoneTest (-not [IO.Directory]::Exists($testRoot)) 'Isolated telephone core test root remained after cleanup.'
    Assert-TelephoneTest (@(Get-TelephoneTestRootProcesses).Count -eq 0) 'Exact-root processes remained after cleanup.'
    $caller = $null
    foreach ($ancestor in @($ancestorIdentities)) {
        if ([int]$ancestor.pid -eq $selfProcessId) { continue }
        $caller = $ancestor
        break
    }
    if ($null -ne $caller) {
        Assert-TelephoneTest (Test-TelephoneOwnerAlive -Owner $caller) 'Invocation caller/ancestor was terminated by the test.'
        $result.caller_preserved = 1
        $result['caller_pid'] = [int]$caller.pid
        $result['caller_start_time_utc_ticks'] = [int64]$caller.start_time_utc_ticks
    } else {
        Assert-TelephoneTest (Test-TelephoneOwnerAlive -Owner (Get-TelephoneTestProcessIdentity -ProcessId $selfProcessId)) 'The test process lost its own identity during cleanup.'
        $result.caller_preserved = 1
        $result['caller_pid'] = $selfProcessId
        $result['caller_start_time_utc_ticks'] = [int64](Get-TelephoneTestProcessIdentity -ProcessId $selfProcessId).start_time_utc_ticks
    }
    $result.residue_live_processes = 0
    $result.residue_live_owners = 0
    $result.residue_held_locks = 0
    $result.test_root_absent = 1
    $result.assertions = $assertions
    $result | ConvertTo-Json -Compress
} finally {
    if (-not $cleanupCompleted) {
        try { Scan-TelephoneTestState } catch { }
        try { Stop-TelephoneTestTracked } catch { }
    }
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY', $script:PreviousDashboardProcessEnvOnly, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', $script:PreviousDashboardOptOut, 'Process')
    Remove-Item Env:TELEPHONE_TEST_LEAD_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:TELEPHONE_TEST_LEAD_RUNS -ErrorAction SilentlyContinue
    Remove-Item Env:TELEPHONE_TEST_LEAD_TURNS -ErrorAction SilentlyContinue
    Remove-Item Env:TELEPHONE_TEST_LEAD_THROW_MESSAGE -ErrorAction SilentlyContinue
    Remove-Item Env:TELEPHONE_TEST_LEAD_THROW_AFTER_WAKE -ErrorAction SilentlyContinue
    Remove-Item Env:TELEPHONE_TEST_LEAD_NATIVE_EVENTS -ErrorAction SilentlyContinue
}

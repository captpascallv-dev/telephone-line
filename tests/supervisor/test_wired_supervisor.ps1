# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'src\supervisor\TelephoneSupervisor.Common.ps1')
$pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$assertions = 0
$positiveAtomicPublish = 0
$schedulerTrigger = 0
$oneMutexOwner = 0
$jobMembershipInherited = 0
$durableCompletedOutbox = 0
$sameByteReplayOnce = 0
$negativeFailClosed = 0
$cancelOneIsolated = 0
$emergencyPauseLatch = 0
$pausedNoLaunch = 0
$resumeNoResurrect = 0
$queuedSurvivesRestart = 0
$supervisorDeathFailed = 0
$noOrphanAfterComplete = 0
$earlyLeadExitJobSurvives = 0
$callbackResumedChild = 0
$runHostDeathNegative = 0
$guiCancelOne = 0
$productionChainActivation = 0
$mailboxSixResult = 0
$mailboxFiveOfSix = 0
$mailboxOneWake = 0
$mailboxRetryOnce = 0
$mailboxNoCompletedRerun = 0
$mailboxCollectorInJob = 0
$mailboxCancelPreserves = 0
$mailboxZeroResidue = 0
$recycleForeignOwnerRefused = 0
$recycleNoDirectDelete = 0

function Assert-Sup {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Invoke-SupScript {
    param(
        [Parameter(Mandatory = $true)][string]$Relative,
        [string[]]$Arguments
    )
    $scriptPath = Join-Path $repoRoot $Relative
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $scriptPath
    ) + @($Arguments)) {
        [void]$info.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $json = $null
        try { $json = $stdout | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String } catch { $json = $null }
        return [ordered]@{
            exit_code = [int]$process.ExitCode
            stdout = $stdout
            stderr = $stderr
            json = $json
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-SupRawArguments {
    param([Parameter(Mandatory = $true)][string]$Arguments)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [ordered]@{ exit_code=[int]$process.ExitCode; stdout=$stdout; stderr=$stderr }
    } finally { $process.Dispose() }
}

function Wait-Sup {
    param([scriptblock]$Probe, [int]$Milliseconds = 15000)
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($Milliseconds)
    do {
        if (& $Probe) { return $true }
        Start-Sleep -Milliseconds 50
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    return $false
}

function New-SupRequest {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$MarkerDir,
        [int]$HoldMilliseconds = 8000,
        [string]$Project = 'sup-project',
        [string]$Session = 'sup-session-001',
        [switch]$ExitImmediately,
        [switch]$SpawnSuccessor,
        [switch]$BatchFanIn,
        [string]$BatchSpecFile = '',
        [string]$VersionId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        [string]$VersionInstallRoot = ''
    )
    $lead = Join-Path $repoRoot 'tests\supervisor\fixtures\mock-wired-lead.ps1'
    $leadArgs = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $lead, '-StateRoot', $script:supState, '-RunId', [string]$RunId,
        '-MarkerDirectory', $MarkerDir, '-HoldMilliseconds', ([string]$HoldMilliseconds)
    )
    if ($ExitImmediately) { $leadArgs += '-ExitImmediately' }
    if ($SpawnSuccessor) { $leadArgs += '-SpawnSuccessor' }
    if ($BatchFanIn) {
        $leadArgs += '-BatchFanIn'
        if (-not [string]::IsNullOrWhiteSpace($BatchSpecFile)) {
            $leadArgs += '-BatchSpecFile'
            $leadArgs += [string]$BatchSpecFile
        }
    }
    $request = [ordered]@{
        protocol_version = 'telephone-line-wired-supervisor-request-v1'
        run_id = [string]$RunId
        project = [string]$Project
        stage = 'active'
        lead_session_id = [string]$Session
        lead_run_id = ('run-' + [string]$RunId)
        summary = 'mock wired lead'
        worktree = $testRoot
        command = [ordered]@{
            executable = $pwsh
            working_directory = $testRoot
            arguments = $leadArgs
        }
        installed_version = [ordered]@{
            version_id = [string]$VersionId
            source_sha256 = [string]$VersionId
            install_root = $(if ([string]::IsNullOrWhiteSpace($VersionInstallRoot)) { $repoRoot } else { [string]$VersionInstallRoot })
        }
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $request['request_sha256'] = Get-TelephoneSupervisorRequestHash -Request $request
    return $request
}

function Write-SupJson {
    param([string]$Path, [object]$Value)
    $parent = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path, ((($Value | ConvertTo-Json -Depth 32).Replace("`r`n", "`n")) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Get-SupFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Copy-SupProductSource {
    param([string]$From, [string]$To)
    [IO.Directory]::CreateDirectory($To) | Out-Null
    foreach ($tree in @('src', 'schemas', 'docs')) {
        Copy-Item -LiteralPath (Join-Path $From $tree) -Destination (Join-Path $To $tree) -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $From 'LICENSE') -Destination (Join-Path $To 'LICENSE') -Force
}

function Invoke-SupInstallCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments
    )
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $ScriptPath
    ) + @($Arguments)) {
        [void]$info.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $json = $null
        try { $json = $stdout | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String } catch { $json = $null }
        return [ordered]@{
            exit_code = [int]$process.ExitCode
            stdout = $stdout
            stderr = $stderr
            json = $json
        }
    } finally {
        $process.Dispose()
    }
}

function Get-SupProcessCommandLine {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    $row = Get-CimInstance Win32_Process -Filter ('ProcessId = {0}' -f [int]$ProcessId)
    if ($null -eq $row) { return '' }
    return [string]$row.CommandLine
}

function Get-SupCounterCount {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return 0 }
    return @([IO.File]::ReadAllLines($Path) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
}

function Write-SupHoldRoute {
    param([string]$Path)
    $text = @'
# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CounterPath,
    [Parameter(Mandatory = $true)][string]$HoldPath,
    [ValidateRange(0, 30000)][int]$DelayMilliseconds = 0,
    [string]$FinalText = 'MOCK_ROUTE_DONE',
    [int]$ExitCode = 0
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
while (-not [IO.File]::Exists($HoldPath)) { Start-Sleep -Milliseconds 50 }
if ($DelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $DelayMilliseconds }
$parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($CounterPath))
if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::AppendAllText($CounterPath, "1`n", [Text.UTF8Encoding]::new($false))
[ordered]@{ success = ($ExitCode -eq 0); final_text = $FinalText } | ConvertTo-Json -Compress
exit $ExitCode
'@
    [IO.File]::WriteAllText($Path, $text.TrimStart() + "`n", [Text.UTF8Encoding]::new($false))
}

function Get-SupLeadLogWakeCount {
    param([string]$LogPath, [string]$RunId)
    if (-not [IO.File]::Exists($LogPath)) { return 0 }
    $count = 0
    foreach ($line in @([IO.File]::ReadAllLines($LogPath))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $row = $line | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
            if ([string]$row.run_id -ceq $RunId -and -not [bool]$row.existing) { $count += 1 }
        } catch { }
    }
    return $count
}

try {
    $script:supState = Join-Path $testRoot 'supervisor-state'
    $taskStore = Join-Path $testRoot 'task-store'
    $desktop = Join-Path $testRoot 'desktop'
    $recycle = Join-Path $testRoot 'recycle'
    $marker = Join-Path $testRoot 'markers'
    [IO.Directory]::CreateDirectory($script:supState) | Out-Null
    [IO.Directory]::CreateDirectory($taskStore) | Out-Null
    [IO.Directory]::CreateDirectory($desktop) | Out-Null
    [IO.Directory]::CreateDirectory($recycle) | Out-Null
    [IO.Directory]::CreateDirectory($marker) | Out-Null
    $env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT = $script:supState
    $env:TELEPHONE_LINE_TASK_STORE = $taskStore
    $env:TELEPHONE_LINE_TASK_BACKEND = (Join-Path $repoRoot 'tests\supervisor\fixtures\mock-scheduler.ps1')
    $env:TELEPHONE_LINE_DESKTOP_ROOT = $desktop
    $env:TELEPHONE_LINE_RECYCLE_ROOT = $recycle
    $env:TELEPHONE_LINE_INSTALL_ROOT = $repoRoot
    $env:TELEPHONE_LINE_SUPERVISOR_MARKER_DIR = $marker
    $env:TELEPHONE_LINE_SUPERVISOR_HEADLESS = '1'

    $null = Initialize-TelephoneSupervisorLayout -StateRoot $script:supState
    $null = Register-TelephoneSupervisorInstallSurface -InstallRoot $repoRoot -StateRoot $script:supState
    Assert-Sup ([IO.File]::Exists((Join-Path $taskStore 'task.json'))) 'Mock scheduled task was not registered.'
    $taskRecord = Get-Content -LiteralPath (Join-Path $taskStore 'task.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    Assert-Sup ([string]$taskRecord.task_name -ceq 'TelephoneLineWiredSupervisor') 'Task name is wrong.'
    Assert-Sup ([string]$taskRecord.principal -ceq 'LimitedUser') 'Task principal is not LimitedUser.'
    Assert-Sup ([bool]$taskRecord.hidden) 'Task is not hidden.'
    $taskAction = Join-Path $repoRoot 'src\supervisor\Invoke-TelephoneSupervisor.ps1'
    $taskLogicalArgs = '-InstallRoot "' + $repoRoot + '" -StateRoot "' + $script:supState + '"'
    $encodedTaskArgs = New-TelephoneSupervisorEncodedTaskArguments -ActionScript $taskAction -ActionArguments $taskLogicalArgs
    Assert-Sup ($encodedTaskArgs -match '(?i)-EncodedCommand\s+[A-Za-z0-9+/=]+$') 'Task action is not one encoded command.'
    Assert-Sup ($encodedTaskArgs -match '(?i)-WindowStyle\s+Hidden\s+-EncodedCommand\s+') 'Task action does not hide the interactive PowerShell host.'
    Assert-Sup (-not $encodedTaskArgs.Contains('-File')) 'Encoded task action retained the fragile -File argument surface.'
    $encodedPayload = [regex]::Match($encodedTaskArgs, '(?i)-EncodedCommand\s+([A-Za-z0-9+/=]+)').Groups[1].Value
    $decodedTaskCommand = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedPayload))
    Assert-Sup ($decodedTaskCommand.Contains('$scriptSucceeded=$?')) 'Encoded task action does not capture the script invocation result.'
    Assert-Sup ($decodedTaskCommand.EndsWith('; exit 0', [StringComparison]::Ordinal)) 'Encoded task action does not normalize successful script completion to zero.'
    Assert-Sup ((Get-TelephoneSupervisorTaskActionScript -Arguments $encodedTaskArgs) -ceq $taskAction) 'Encoded task action cannot recover its exact script identity.'
    $taskDefinition = New-TelephoneSupervisorTaskActionDefinition -ActionScript $taskAction -ActionArguments $taskLogicalArgs -InstallRoot $repoRoot
    Assert-Sup ([string]$taskDefinition.execute -like '*\pwsh.exe') 'Scheduled task does not use the configured PowerShell host.'
    Assert-Sup ([string]$taskDefinition.arguments -match '(?i)-WindowStyle\s+Hidden\s+-EncodedCommand\s+') 'Outer scheduled-task host is not hidden.'
    Assert-Sup ([string]$taskDefinition.launcher -like '*Start-TelephoneSupervisorHostVisible.ps1') 'Scheduled task does not use the shipped short launcher.'
    Assert-Sup ((Get-TelephoneSupervisorTaskActionScript -Arguments ([string]$taskDefinition.arguments)) -ceq $taskAction) 'Nested task action cannot recover its exact supervisor script identity.'
    $encodedProbe = Invoke-SupRawArguments -Arguments $encodedTaskArgs
    Assert-Sup ($encodedProbe.exit_code -eq 0) ('Encoded task action failed: ' + $encodedProbe.stderr + $encodedProbe.stdout)
    $staleNativeScript = Join-Path $testRoot 'task-stale-native.ps1'
    [IO.File]::WriteAllText($staleNativeScript, "& cmd.exe /d /c exit 7`nWrite-Output 'ok'`n", [Text.UTF8Encoding]::new($false))
    $staleNativeProbe = Invoke-SupRawArguments -Arguments (New-TelephoneSupervisorEncodedTaskArguments -ActionScript $staleNativeScript -ActionArguments '')
    Assert-Sup ($staleNativeProbe.exit_code -eq 0) 'Encoded task action misreported a successful script with a stale native exit code.'
    $explicitFailureScript = Join-Path $testRoot 'task-explicit-failure.ps1'
    [IO.File]::WriteAllText($explicitFailureScript, "exit 9`n", [Text.UTF8Encoding]::new($false))
    $explicitFailureProbe = Invoke-SupRawArguments -Arguments (New-TelephoneSupervisorEncodedTaskArguments -ActionScript $explicitFailureScript -ActionArguments '')
    Assert-Sup ($explicitFailureProbe.exit_code -eq 9) 'Encoded task action did not propagate an explicit script failure.'

    $runA = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee01'
    $reqA = New-SupRequest -RunId $runA -MarkerDir $marker -HoldMilliseconds 6000
    $reqPath = Join-Path $testRoot 'req-a.json'
    Write-SupJson -Path $reqPath -Value $reqA
    $started = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @(
        '-RequestFile', $reqPath, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
    )
    Assert-Sup ($started.exit_code -eq 0) ('Start-TelephoneWiredRun failed: ' + $started.stderr + $started.stdout)
    Assert-Sup ([bool]$started.json.published) 'Request was not published.'
    Assert-Sup ([bool]$started.json.lead_should_exit_now) 'Starter did not return lead_should_exit_now.'
    Assert-Sup ([bool]$started.json.triggered) 'Scheduler was not triggered.'
    $script:positiveAtomicPublish = 1
    $ops = [IO.File]::ReadAllText((Join-Path $taskStore 'operations.jsonl'))
    Assert-Sup ($ops.Contains('"start"')) 'Scheduler start was not recorded.'
    $script:schedulerTrigger = 1

    $ownerPath = Join-Path (Join-Path $script:supState ('runs\' + $runA)) 'owner.json'
    Assert-Sup (Wait-Sup { [IO.File]::Exists($ownerPath) } -Milliseconds 20000) 'Run owner was not published.'
    $owner = (Read-TelephoneJson -Path $ownerPath -SchemaName 'wired-supervisor-owner').value
    $memberPath = Join-Path (Join-Path $script:supState ('runs\' + $runA)) 'job-members.json'
    Assert-Sup (Wait-Sup { [IO.File]::Exists($memberPath) } -Milliseconds 10000) 'Job membership evidence was not published.'
    $members = (Read-TelephoneJson -Path $memberPath).value
    $jobPids = @($members.job_pids | ForEach-Object { [int]$_ })
    Assert-Sup ($owner.Contains('lead_pid')) 'Run owner did not record the initial Lead identity.'
    Assert-Sup ($jobPids -contains [int]$owner.lead_pid) 'Lead PID is not in the supervisor Job membership list.'
    $job = Open-TelephoneSupervisorRunJob -RunId $runA
    try {
        if ($null -ne $job -and [IntPtr]$job.handle -ne [IntPtr]::Zero) {
            Assert-Sup (Test-TelephoneSupervisorPidInJob -Job $job -ProcessId ([int]$owner.lead_pid)) 'Lead is not a member of the supervisor Job.'
        }
        $leadMarker = Join-Path $marker ('lead-' + $runA + '.json')
        Assert-Sup (Wait-Sup { [IO.File]::Exists($leadMarker) } -Milliseconds 10000) 'Mock lead marker is missing.'
        $leadEv = Get-Content -LiteralPath $leadMarker -Raw | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
        $childMarker = Join-Path $marker ('child-' + $runA + '.json')
        Assert-Sup (Wait-Sup { [IO.File]::Exists($childMarker) } -Milliseconds 10000) 'Inherited child marker is missing.'
        $childEv = Get-Content -LiteralPath $childMarker -Raw | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
        Assert-Sup (Wait-Sup {
            $latest = (Read-TelephoneJson -Path $memberPath).value
            $pids = @($latest.job_pids | ForEach-Object { [int]$_ })
            ($pids -contains [int]$leadEv.lead_pid) -and ($pids -contains [int]$childEv.pid)
        } -Milliseconds 10000) 'Inherited child never appeared in Job membership evidence.'
        $members = (Read-TelephoneJson -Path $memberPath).value
        $jobPids = @($members.job_pids | ForEach-Object { [int]$_ })
        Assert-Sup ($jobPids -contains [int]$leadEv.lead_pid) 'Mock lead PID is not in the Job membership list.'
        Assert-Sup ($jobPids -contains [int]$childEv.pid) 'Inherited child is not in the Job membership list.'
        $script:jobMembershipInherited = 1
    } finally {
        Close-TelephoneSupervisorRunJob -Job $job
    }

    $dupMutex = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisor.ps1' -Arguments @(
        '-InstallRoot', $repoRoot, '-StateRoot', $script:supState
    )
    Assert-Sup ($dupMutex.exit_code -eq 0) 'Duplicate supervisor invoke failed.'
    Assert-Sup ([bool]$dupMutex.json.duplicate -or [int]$dupMutex.json.launched -eq 0) 'Duplicate supervisor became a second owner.'
    $script:oneMutexOwner = 1

    $outboxA = Get-TelephoneSupervisorRecordPath -StateRoot $script:supState -Kind outbox -RunId $runA
    Assert-Sup (Wait-Sup { [IO.File]::Exists($outboxA) } -Milliseconds 20000) 'Completed outbox is missing.'
    $outA = (Read-TelephoneJson -Path $outboxA).value
    Assert-Sup ([string]$outA.terminal -ceq 'completed') 'Outbox terminal is not completed.'
    $script:durableCompletedOutbox = 1
    Assert-Sup (Wait-Sup { -not [IO.File]::Exists((Join-Path $script:supState 'control\supervisor-owner.json')) } -Milliseconds 5000) 'Supervisor owner remained after idle completion.'
    $script:noOrphanAfterComplete = 1

    $replay = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @(
        '-RequestFile', $reqPath, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
    )
    Assert-Sup ($replay.exit_code -eq 0) 'Same-byte replay failed.'
    Assert-Sup ([bool]$replay.json.replayed) 'Same-byte replay was not idempotent.'
    Assert-Sup (-not [bool]$replay.json.triggered) 'Same-byte replay retriggered the scheduler.'
    $script:sameByteReplayOnce = 1

    $conflict = [ordered]@{}
    foreach ($key in @($reqA.Keys)) { $conflict[[string]$key] = $reqA[$key] }
    $conflict.summary = 'different-bytes'
    $conflict['request_sha256'] = Get-TelephoneSupervisorRequestHash -Request $conflict
    $conflictPath = Join-Path $testRoot 'req-conflict.json'
    Write-SupJson -Path $conflictPath -Value $conflict
    $conflictResult = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @(
        '-RequestFile', $conflictPath, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
    )
    Assert-Sup ($conflictResult.exit_code -ne 0) 'Conflicting replay did not fail closed.'

    $unknown = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @(
        '-RequestFile', (Join-Path $repoRoot 'tests\contracts\fixtures\negative\wired-supervisor-request.unknown-field.json'),
        '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
    )
    Assert-Sup ($unknown.exit_code -ne 0) 'Unknown-field request was accepted.'

    $badHash = New-SupRequest -RunId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee99' -MarkerDir $marker -HoldMilliseconds 200
    $badHash.request_sha256 = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
    $badHashPath = Join-Path $testRoot 'req-badhash.json'
    Write-SupJson -Path $badHashPath -Value $badHash
    $badHashResult = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @(
        '-RequestFile', $badHashPath, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
    )
    Assert-Sup ($badHashResult.exit_code -ne 0) 'Wrong request hash was accepted.'

    $partialId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee77'
    $partialReq = New-SupRequest -RunId $partialId -MarkerDir $marker -HoldMilliseconds 200
    $partialInbox = Get-TelephoneSupervisorRecordPath -StateRoot $script:supState -Kind inbox -RunId $partialId
    [IO.File]::WriteAllText((Join-Path ([IO.Path]::GetDirectoryName($partialInbox)) ('.' + [IO.Path]::GetFileName($partialInbox) + '.tmp-deadbeef')), '{}')
    $partialPath = Join-Path $testRoot 'req-partial.json'
    Write-SupJson -Path $partialPath -Value $partialReq
    $partialResult = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @(
        '-RequestFile', $partialPath, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
    )
    Assert-Sup ($partialResult.exit_code -ne 0) 'Partial temp sibling was accepted.'

    $reparseRoot = Join-Path $testRoot 'reparse-target'
    $reparseLink = Join-Path $testRoot 'reparse-state'
    [IO.Directory]::CreateDirectory($reparseRoot) | Out-Null
    $null = New-Item -ItemType Junction -Path $reparseLink -Target $reparseRoot
    $reparseFailed = $false
    try {
        $null = Initialize-TelephoneSupervisorLayout -StateRoot $reparseLink
    } catch { $reparseFailed = $true }
    Assert-Sup $reparseFailed 'Reparse state root was accepted.'
    [IO.Directory]::Delete($reparseLink)

    $self = Get-Process -Id $PID
    try {
        $foreignOwner = [ordered]@{
            protocol_version = 'telephone-line-wired-supervisor-owner-v1'
            kind = 'run'
            run_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee66'
            request_sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            pid = [int]$PID
            start_time_utc_ticks = [int64]$self.StartTime.ToUniversalTime().Ticks
            started_at_utc = $self.StartTime.ToUniversalTime().ToString('o')
            job_name = 'Local\TelephoneLine.WiredRun.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee66'
            project = 'foreign'
            stage = 'active'
            lead_session_id = 'foreign-session'
            installed_version = [ordered]@{
                version_id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                source_sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            }
        }
    } finally { $self.Dispose() }
    $null = Write-TelephoneSupervisorRunOwner -StateRoot $script:supState -Owner $foreignOwner
    $foreignStop = Stop-TelephoneSupervisorExactRun -StateRoot $script:supState -RunId ([string]$foreignOwner.run_id)
    Assert-Sup (-not [bool]$foreignStop.stopped) 'Foreign process was terminated.'
    Assert-Sup ([string]$foreignStop.reason -cin @('foreign-process', 'job-missing')) 'Foreign stop used the wrong reason.'

    $reuseOwner = [ordered]@{}
    foreach ($key in @($foreignOwner.Keys)) { $reuseOwner[[string]$key] = $foreignOwner[$key] }
    $reuseOwner.run_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee55'
    $reuseOwner.job_name = 'Local\TelephoneLine.WiredRun.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee55'
    $reuseOwner.start_time_utc_ticks = [int64]($foreignOwner.start_time_utc_ticks - 1)
    $null = Write-TelephoneSupervisorRunOwner -StateRoot $script:supState -Owner $reuseOwner
    $reuseStop = Stop-TelephoneSupervisorExactRun -StateRoot $script:supState -RunId ([string]$reuseOwner.run_id)
    Assert-Sup (-not [bool]$reuseStop.stopped) 'PID-reuse owner was terminated.'
    Assert-Sup ([string]$reuseStop.reason -cin @('pid-reuse-or-stale', 'job-missing', 'job-missing-and-owner-dead')) 'PID reuse used the wrong reason.'

    $wrongTaskFailed = $false
    try {
        $null = Invoke-TelephoneSupervisorTaskOperation -Operation start -InstallRoot $repoRoot -ActionScript 'C:\Windows\System32\notepad.exe'
    } catch { $wrongTaskFailed = $true }
    Assert-Sup $wrongTaskFailed 'Wrong scheduled-task identity was accepted.'
    $script:negativeFailClosed = 1

    $runEarly = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee07'
    $reqEarly = New-SupRequest -RunId $runEarly -MarkerDir $marker -HoldMilliseconds 15000 -ExitImmediately
    $pathEarly = Join-Path $testRoot 'req-early.json'
    Write-SupJson -Path $pathEarly -Value $reqEarly
    $null = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @('-RequestFile', $pathEarly, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot)
    $ownerEarly = Join-Path (Join-Path $script:supState ('runs\' + $runEarly)) 'owner.json'
    $leadEarly = Join-Path $marker ('lead-' + $runEarly + '.json')
    $childEarly = Join-Path $marker ('child-' + $runEarly + '.json')
    $outEarly = Get-TelephoneSupervisorRecordPath -StateRoot $script:supState -Kind outbox -RunId $runEarly
    Assert-Sup (Wait-Sup { [IO.File]::Exists($ownerEarly) -and [IO.File]::Exists($leadEarly) -and [IO.File]::Exists($childEarly) } -Milliseconds 20000) 'Early-exit Lead or inherited child evidence is missing.'
    $leadEvEarly = Get-Content -LiteralPath $leadEarly -Raw | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
    $childEvEarly = Get-Content -LiteralPath $childEarly -Raw | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
    Assert-Sup (Wait-Sup {
        $aliveLead = Get-Process -Id ([int]$leadEvEarly.lead_pid) -ErrorAction SilentlyContinue
        try { return ($null -eq $aliveLead) } finally { if ($null -ne $aliveLead) { $aliveLead.Dispose() } }
    } -Milliseconds 10000) 'Initial Lead did not exit immediately after dispatch.'
    Assert-Sup (-not [IO.File]::Exists($outEarly)) 'Outbox was published while inherited children were still alive.'
    $childAliveEarly = Get-Process -Id ([int]$childEvEarly.pid) -ErrorAction SilentlyContinue
    try {
        Assert-Sup ($null -ne $childAliveEarly -and -not $childAliveEarly.HasExited) 'Inherited child died when the initial Lead exited.'
    } finally { if ($null -ne $childAliveEarly) { $childAliveEarly.Dispose() } }
    $jobEarly = Open-TelephoneSupervisorRunJob -RunId $runEarly -WaitMilliseconds 0
    try {
        Assert-Sup ($null -ne $jobEarly -and [IntPtr]$jobEarly.handle -ne [IntPtr]::Zero) 'Named Job disappeared after the initial Lead exited.'
        Assert-Sup (Test-TelephoneSupervisorPidInJob -Job $jobEarly -ProcessId ([int]$childEvEarly.pid)) 'Inherited child is not in the exact Job after Lead exit.'
    } finally {
        Close-TelephoneSupervisorRunJob -Job $jobEarly
    }
    $restartLive = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisor.ps1' -Arguments @('-InstallRoot', $repoRoot, '-StateRoot', $script:supState)
    Assert-Sup ($restartLive.exit_code -eq 0) 'Supervisor restart against a live run host failed.'
    Assert-Sup ([bool]$restartLive.json.duplicate -or [int]$restartLive.json.launched -eq 0) 'Supervisor restart launched a second owner for a live run.'
    Assert-Sup (-not [IO.File]::Exists($outEarly)) 'Supervisor restart completed a still-running Job.'
    $childStill = Get-Process -Id ([int]$childEvEarly.pid) -ErrorAction SilentlyContinue
    try {
        Assert-Sup ($null -ne $childStill -and -not $childStill.HasExited) 'Supervisor restart killed the inherited child.'
    } finally { if ($null -ne $childStill) { $childStill.Dispose() } }
    $script:earlyLeadExitJobSurvives = 1
    $guiCancel = Invoke-SupScript -Relative 'src\supervisor\Show-TelephoneSupervisorControl.ps1' -Arguments @(
        '-Action', 'cancel-one', '-RunId', $runEarly, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
    )
    Assert-Sup ($guiCancel.exit_code -eq 0) ('Headless console cancel-one failed: ' + $guiCancel.stderr + $guiCancel.stdout)
    Assert-Sup (Wait-Sup { [IO.File]::Exists($outEarly) } -Milliseconds 15000) 'GUI cancel-one did not publish a terminal.'
    $outEarlyRec = (Read-TelephoneJson -Path $outEarly).value
    Assert-Sup ([string]$outEarlyRec.terminal -ceq 'cancelled') 'GUI cancel-one used the wrong terminal.'
    Assert-Sup (Wait-Sup {
        $left = Get-Process -Id ([int]$childEvEarly.pid) -ErrorAction SilentlyContinue
        try { return ($null -eq $left) } finally { if ($null -ne $left) { $left.Dispose() } }
    } -Milliseconds 10000) 'GUI cancel-one left the inherited child alive.'
    $script:guiCancelOne = 1

    $runCb = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee08'
    $reqCb = New-SupRequest -RunId $runCb -MarkerDir $marker -HoldMilliseconds 2500 -ExitImmediately -SpawnSuccessor
    $pathCb = Join-Path $testRoot 'req-cb.json'
    Write-SupJson -Path $pathCb -Value $reqCb
    $null = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @('-RequestFile', $pathCb, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot)
    $successorMarker = Join-Path $marker ('successor-child-' + $runCb + '.json')
    $outCb = Get-TelephoneSupervisorRecordPath -StateRoot $script:supState -Kind outbox -RunId $runCb
    Assert-Sup (Wait-Sup { [IO.File]::Exists($successorMarker) } -Milliseconds 20000) 'Callback-like successor child was not published.'
    $succEv = Get-Content -LiteralPath $successorMarker -Raw | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
    Assert-Sup (-not [IO.File]::Exists($outCb)) 'Outbox appeared before the resumed successor drained.'
    $jobCb = Open-TelephoneSupervisorRunJob -RunId $runCb -WaitMilliseconds 0
    try {
        Assert-Sup (Test-TelephoneSupervisorPidInJob -Job $jobCb -ProcessId ([int]$succEv.pid)) 'Resumed successor is not in the exact Job.'
    } finally {
        Close-TelephoneSupervisorRunJob -Job $jobCb
    }
    Assert-Sup (Wait-Sup { [IO.File]::Exists($outCb) } -Milliseconds 15000) 'Natural drain did not publish one terminal.'
    $outCbRec = (Read-TelephoneJson -Path $outCb).value
    Assert-Sup ([string]$outCbRec.terminal -ceq 'completed') 'Natural drain used the wrong terminal.'
    $script:callbackResumedChild = 1

    $runHost = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee09'
    $reqHost = New-SupRequest -RunId $runHost -MarkerDir $marker -HoldMilliseconds 15000 -ExitImmediately
    $pathHost = Join-Path $testRoot 'req-host.json'
    Write-SupJson -Path $pathHost -Value $reqHost
    $null = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @('-RequestFile', $pathHost, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot)
    $ownerHostPath = Join-Path (Join-Path $script:supState ('runs\' + $runHost)) 'owner.json'
    $childHost = Join-Path $marker ('child-' + $runHost + '.json')
    Assert-Sup (Wait-Sup { [IO.File]::Exists($ownerHostPath) -and [IO.File]::Exists($childHost) } -Milliseconds 20000) 'Run-host death fixture was not published.'
    $ownerHost = (Read-TelephoneJson -Path $ownerHostPath -SchemaName 'wired-supervisor-owner').value
    $childHostEv = Get-Content -LiteralPath $childHost -Raw | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
    Stop-Process -Id ([int]$ownerHost.pid) -Force -ErrorAction SilentlyContinue
    Assert-Sup (Wait-Sup {
        $hp = Get-Process -Id ([int]$ownerHost.pid) -ErrorAction SilentlyContinue
        try { return ($null -eq $hp) } finally { if ($null -ne $hp) { $hp.Dispose() } }
    } -Milliseconds 10000) 'Run host did not die after forced stop.'
    Assert-Sup (Wait-Sup {
        $cp = Get-Process -Id ([int]$childHostEv.pid) -ErrorAction SilentlyContinue
        try { return ($null -eq $cp) } finally { if ($null -ne $cp) { $cp.Dispose() } }
    } -Milliseconds 10000) 'Job descendants survived run-host death.'
    $null = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisor.ps1' -Arguments @('-InstallRoot', $repoRoot, '-StateRoot', $script:supState)
    $outHost = Get-TelephoneSupervisorRecordPath -StateRoot $script:supState -Kind outbox -RunId $runHost
    Assert-Sup (Wait-Sup { [IO.File]::Exists($outHost) } -Milliseconds 10000) 'Run-host death was not reconciled.'
    $outHostRec = (Read-TelephoneJson -Path $outHost).value
    Assert-Sup ([string]$outHostRec.terminal -ceq 'failed') 'Run-host death invented success.'
    Assert-Sup ([string]$outHostRec.error_code -ceq 'SUPERVISOR_OWNER_DEAD_NO_RERUN') 'Run-host death used the wrong error code.'
    $script:runHostDeathNegative = 1

    $runB = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee02'
    $runC = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee03'
    $reqB = New-SupRequest -RunId $runB -MarkerDir $marker -HoldMilliseconds 20000 -Project 'job-b' -Session 'session-b'
    $reqC = New-SupRequest -RunId $runC -MarkerDir $marker -HoldMilliseconds 20000 -Project 'job-c' -Session 'session-c'
    $pathB = Join-Path $testRoot 'req-b.json'
    $pathC = Join-Path $testRoot 'req-c.json'
    Write-SupJson -Path $pathB -Value $reqB
    Write-SupJson -Path $pathC -Value $reqC
    $null = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @('-RequestFile', $pathB, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot)
    $null = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @('-RequestFile', $pathC, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot)
    $ownerB = Join-Path (Join-Path $script:supState ('runs\' + $runB)) 'owner.json'
    $ownerC = Join-Path (Join-Path $script:supState ('runs\' + $runC)) 'owner.json'
    Assert-Sup (Wait-Sup { [IO.File]::Exists($ownerB) -and [IO.File]::Exists($ownerC) } -Milliseconds 20000) 'Two disjoint owners were not published.'
    $cancelB = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisorControl.ps1' -Arguments @(
        '-Action', 'cancel-one', '-RunId', $runB, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
    )
    Assert-Sup ($cancelB.exit_code -eq 0) ('cancel-one failed: ' + $cancelB.stderr + $cancelB.stdout)
    Assert-Sup ($cancelB.json.Contains('remaining_run_ids')) 'cancel-one omitted remaining_run_ids.'
    Assert-Sup (Wait-Sup { -not (Test-TelephoneSupervisorExactOwner -Owner ((Read-TelephoneJson -Path $ownerB -SchemaName 'wired-supervisor-owner').value)) } -Milliseconds 10000) 'cancel-one did not stop its Job.'
    Assert-Sup (Test-TelephoneSupervisorExactOwner -Owner ((Read-TelephoneJson -Path $ownerC -SchemaName 'wired-supervisor-owner').value)) 'cancel-one harmed the other Job.'
    $script:cancelOneIsolated = 1

    $emerg = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisorControl.ps1' -Arguments @(
        '-Action', 'emergency-stop-all', '-Confirm', '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
    )
    Assert-Sup ($emerg.exit_code -eq 0) ('emergency-stop-all failed: ' + $emerg.stderr)
    Assert-Sup ([bool]$emerg.json.paused_by_pascal) 'Emergency did not latch pause.'
    Assert-Sup ($emerg.json.Contains('refused')) 'Emergency omitted refused runs.'
    Assert-Sup ($emerg.json.Contains('remaining_run_ids')) 'Emergency omitted remaining_run_ids.'
    Assert-Sup (Wait-Sup { -not (Test-TelephoneSupervisorExactOwner -Owner ((Read-TelephoneJson -Path $ownerC -SchemaName 'wired-supervisor-owner').value)) } -Milliseconds 10000) 'Emergency did not stop remaining owned Job.'
    Assert-Sup ([IO.File]::Exists((Join-Path $script:supState ('outbox\' + $runC + '.json')))) 'Emergency deleted run artifacts.'
    $script:emergencyPauseLatch = 1

    $runD = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee04'
    $reqD = New-SupRequest -RunId $runD -MarkerDir $marker -HoldMilliseconds 2000
    $pathD = Join-Path $testRoot 'req-d.json'
    Write-SupJson -Path $pathD -Value $reqD
    $pausedStart = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @(
        '-RequestFile', $pathD, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
    )
    Assert-Sup ($pausedStart.exit_code -eq 0) 'Paused publish failed.'
    Assert-Sup ([bool]$pausedStart.json.published) 'Paused request was not published.'
    Assert-Sup (-not [bool]$pausedStart.json.triggered) 'Paused publish triggered a launch.'
    Assert-Sup (-not [IO.File]::Exists((Join-Path (Join-Path $script:supState ('runs\' + $runD)) 'owner.json'))) 'Paused publish launched a run.'
    $script:pausedNoLaunch = 1

    $resume = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisorControl.ps1' -Arguments @(
        '-Action', 'resume', '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
    )
    Assert-Sup ($resume.exit_code -eq 0) 'Resume failed.'
    Assert-Sup (-not [bool]$resume.json.paused_by_pascal) 'Resume did not clear pause.'
    Assert-Sup ([bool]$resume.json.Contains('resurrected') -and -not [bool]$resume.json.resurrected) 'Resume claimed to resurrect work.'
    $cancelledB = (Read-TelephoneJson -Path (Join-Path $script:supState ('outbox\' + $runB + '.json'))).value
    Assert-Sup ([string]$cancelledB.terminal -ceq 'cancelled') 'Resume resurrected a cancelled request.'
    $null = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisor.ps1' -Arguments @('-InstallRoot', $repoRoot, '-StateRoot', $script:supState)
    Assert-Sup (Wait-Sup { [IO.File]::Exists((Join-Path $script:supState ('outbox\' + $runD + '.json'))) -or [IO.File]::Exists((Join-Path (Join-Path $script:supState ('runs\' + $runD)) 'owner.json')) } -Milliseconds 20000) 'Resume did not accept the queued request.'
    $script:resumeNoResurrect = 1

    $null = Write-TelephoneSupervisorPause -StateRoot $script:supState -Paused $true
    $runE = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee05'
    $reqE = New-SupRequest -RunId $runE -MarkerDir $marker -HoldMilliseconds 1500
    $pathE = Join-Path $testRoot 'req-e.json'
    Write-SupJson -Path $pathE -Value $reqE
    $queued = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @(
        '-RequestFile', $pathE, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
    )
    Assert-Sup ([bool]$queued.json.published -and -not [bool]$queued.json.triggered) 'Queued publish while paused launched.'
    $null = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisor.ps1' -Arguments @('-InstallRoot', $repoRoot, '-StateRoot', $script:supState)
    Assert-Sup ([IO.File]::Exists((Get-TelephoneSupervisorRecordPath -StateRoot $script:supState -Kind inbox -RunId $runE))) 'Queued inbox did not survive supervisor restart while paused.'
    $null = Write-TelephoneSupervisorPause -StateRoot $script:supState -Paused $false
    $null = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisor.ps1' -Arguments @('-InstallRoot', $repoRoot, '-StateRoot', $script:supState)
    Assert-Sup (Wait-Sup { [IO.File]::Exists((Get-TelephoneSupervisorRecordPath -StateRoot $script:supState -Kind outbox -RunId $runE)) } -Milliseconds 20000) 'Queued work did not run after restart and resume.'
    $script:queuedSurvivesRestart = 1

    $runF = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee06'
    $claimedPath = Get-TelephoneSupervisorRecordPath -StateRoot $script:supState -Kind claimed -RunId $runF
    $deadReq = New-SupRequest -RunId $runF -MarkerDir $marker -HoldMilliseconds 200
    Write-SupJson -Path $claimedPath -Value $deadReq
    $deadOwner = [ordered]@{
        protocol_version = 'telephone-line-wired-supervisor-owner-v1'
        kind = 'run'
        run_id = $runF
        request_sha256 = [string]$deadReq.request_sha256
        pid = 999999
        start_time_utc_ticks = [int64]1
        started_at_utc = '2020-01-01T00:00:00.0000000Z'
        job_name = ('Local\TelephoneLine.WiredRun.' + $runF)
        project = 'dead'
        stage = 'active'
        lead_session_id = 'dead-session'
        installed_version = [ordered]@{
            version_id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            source_sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        }
    }
    $null = Write-TelephoneSupervisorRunOwner -StateRoot $script:supState -Owner $deadOwner
    $null = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisor.ps1' -Arguments @('-InstallRoot', $repoRoot, '-StateRoot', $script:supState)
    $deadOut = Get-TelephoneSupervisorRecordPath -StateRoot $script:supState -Kind outbox -RunId $runF
    Assert-Sup (Wait-Sup { [IO.File]::Exists($deadOut) } -Milliseconds 10000) 'Dead owner was not reconciled.'
    $deadRec = (Read-TelephoneJson -Path $deadOut).value
    Assert-Sup ([string]$deadRec.terminal -ceq 'failed') 'Supervisor death invented success.'
    Assert-Sup ([string]$deadRec.error_code -ceq 'SUPERVISOR_OWNER_DEAD_NO_RERUN') 'Supervisor death used the wrong error code.'
    $script:supervisorDeathFailed = 1

    $headless = Invoke-SupScript -Relative 'src\supervisor\Show-TelephoneSupervisorControl.ps1' -Arguments @(
        '-Action', 'status', '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
    )
    Assert-Sup ($headless.exit_code -eq 0) 'Headless desktop control status failed.'

    $savedEnv = [ordered]@{
        TELEPHONE_LINE_SUPERVISOR_STATE_ROOT = [string]$env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT
        TELEPHONE_LINE_TASK_STORE = [string]$env:TELEPHONE_LINE_TASK_STORE
        TELEPHONE_LINE_DESKTOP_ROOT = [string]$env:TELEPHONE_LINE_DESKTOP_ROOT
        TELEPHONE_LINE_RECYCLE_ROOT = [string]$env:TELEPHONE_LINE_RECYCLE_ROOT
        TELEPHONE_LINE_INSTALL_ROOT = [string]$env:TELEPHONE_LINE_INSTALL_ROOT
        TELEPHONE_LINE_SUPERVISOR_MARKER_DIR = [string]$env:TELEPHONE_LINE_SUPERVISOR_MARKER_DIR
        TELEPHONE_LINE_STATE_ROOT = [string]$env:TELEPHONE_LINE_STATE_ROOT
        TELEPHONE_LINE_USER_PATH_FILE = [string]$env:TELEPHONE_LINE_USER_PATH_FILE
    }
    $prodRoot = Join-Path $testRoot 'prod-chain'
    $prodInstall = Join-Path $prodRoot 'install'
    $prodLineState = Join-Path $prodRoot 'line-state'
    $prodSupState = Join-Path $prodRoot 'supervisor-state'
    $prodTask = Join-Path $prodRoot 'task-store'
    $prodDesktop = Join-Path $prodRoot 'desktop'
    $prodRecycle = Join-Path $prodRoot 'recycle'
    $prodMarker = Join-Path $prodRoot 'markers'
    $sourceA = Join-Path $prodRoot 'source-a'
    $sourceB = Join-Path $prodRoot 'source-b'
    $prodPathFile = Join-Path $prodRoot 'user-path.txt'
    foreach ($dir in @($prodRoot, $prodLineState, $prodSupState, $prodTask, $prodDesktop, $prodRecycle, $prodMarker)) {
        [IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    [IO.File]::WriteAllText($prodPathFile, "Z:\prod-path-sentinel`n")
    $pathBefore = [IO.File]::ReadAllText($prodPathFile)
    try {
        $env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT = $prodSupState
        $env:TELEPHONE_LINE_TASK_STORE = $prodTask
        $env:TELEPHONE_LINE_DESKTOP_ROOT = $prodDesktop
        $env:TELEPHONE_LINE_RECYCLE_ROOT = $prodRecycle
        $env:TELEPHONE_LINE_INSTALL_ROOT = $prodInstall
        $env:TELEPHONE_LINE_SUPERVISOR_MARKER_DIR = $prodMarker
        $env:TELEPHONE_LINE_STATE_ROOT = $prodLineState
        $env:TELEPHONE_LINE_USER_PATH_FILE = $prodPathFile
        Copy-SupProductSource -From $repoRoot -To $sourceA
        Copy-SupProductSource -From $repoRoot -To $sourceB
        $privacyRel = 'docs\privacy.md'
        [IO.File]::AppendAllText((Join-Path $sourceB $privacyRel), "`nprod-chain-version-b`n")
        $installed = Invoke-SupInstallCommand -ScriptPath (Join-Path $sourceA 'src\install\Install-TelephoneLine.ps1') -Arguments @(
            '-InstallRoot', $prodInstall, '-SourceRoot', $sourceA
        )
        Assert-Sup ($installed.exit_code -eq 0) ('Fresh install of version A failed: ' + $installed.stderr + $installed.stdout)
        Assert-Sup ([string]$installed.json.code -ceq 'INSTALLED') 'Fresh install did not report INSTALLED.'
        $pointerA = Get-Content -LiteralPath (Join-Path $prodInstall 'current.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
        $versionA = [string]$pointerA.version_id
        Assert-Sup ([string]$versionA -cmatch '^[0-9a-f]{64}$') 'Installed current version identity is invalid.'
        $versionADir = Get-TelephoneSupervisorVersionDirectory -InstallRoot $prodInstall -VersionId $versionA
        Assert-Sup ([IO.Directory]::Exists($versionADir)) 'Version A store is missing.'
        $destPrivacy = Join-Path $prodInstall $privacyRel
        $hashA = Get-SupFileSha256 -Path $destPrivacy
        $hashB = Get-SupFileSha256 -Path (Join-Path $sourceB $privacyRel)
        Assert-Sup ($hashA -cne $hashB) 'Version B source did not differ from version A dest bytes.'
        $manifestA = Get-SupFileSha256 -Path (Join-Path $prodInstall 'install-manifest.json')
        $runSlow = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee11'
        $runFast = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee12'
        $runCancel = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee13'
        $reqSlow = New-SupRequest -RunId $runSlow -MarkerDir $prodMarker -HoldMilliseconds 20000 -Project 'prod-slow' -Session 'prod-slow' -VersionId $versionA -VersionInstallRoot $prodInstall
        $pathSlow = Join-Path $prodRoot 'req-slow.json'
        Write-SupJson -Path $pathSlow -Value $reqSlow
        $startSlow = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @(
            '-RequestFile', $pathSlow, '-StateRoot', $prodSupState, '-InstallRoot', $prodInstall
        )
        Assert-Sup ($startSlow.exit_code -eq 0) ('Pinned run launch failed: ' + $startSlow.stderr + $startSlow.stdout)
        $ownerSlowPath = Join-Path (Join-Path $prodSupState ('runs\' + $runSlow)) 'owner.json'
        Assert-Sup (Wait-Sup { [IO.File]::Exists($ownerSlowPath) } -Milliseconds 20000) 'Pinned version-A run owner was not published.'
        $ownerSlow = (Read-TelephoneJson -Path $ownerSlowPath -SchemaName 'wired-supervisor-owner').value
        $hostCmd = Get-SupProcessCommandLine -ProcessId ([int]$ownerSlow.pid)
        $pinnedHost = Join-Path $versionADir 'src\supervisor\Invoke-TelephoneSupervisorRunHost.ps1'
        Assert-Sup ($hostCmd.IndexOf($pinnedHost, [StringComparison]::OrdinalIgnoreCase) -ge 0) 'Run host was not the version-pinned Invoke-TelephoneSupervisorRunHost.ps1.'
        $installArg = [regex]::Match($hostCmd, '-InstallRoot\s+(?:"([^"]+)"|(\S+))')
        Assert-Sup ([bool]$installArg.Success) 'Version-pinned run host omitted -InstallRoot.'
        $passedInstall = if ($installArg.Groups[1].Success -and -not [string]::IsNullOrWhiteSpace([string]$installArg.Groups[1].Value)) {
            [string]$installArg.Groups[1].Value
        } else {
            [string]$installArg.Groups[2].Value
        }
        $passedInstall = [IO.Path]::GetFullPath($passedInstall).TrimEnd('\')
        Assert-Sup ($passedInstall.Equals($prodInstall, [StringComparison]::OrdinalIgnoreCase)) 'Run host received the version directory as -InstallRoot.'
        Assert-Sup (-not (Test-TelephoneSupervisorVersionStorePath -Path $passedInstall)) 'Run host -InstallRoot was a version store path.'
        $staged = Invoke-SupInstallCommand -ScriptPath (Join-Path $prodInstall 'src\install\Update-TelephoneLine.ps1') -Arguments @(
            '-InstallRoot', $prodInstall, '-SourceRoot', $sourceB
        )
        Assert-Sup ($staged.exit_code -eq 0) ('Pinned update failed: ' + $staged.stderr + $staged.stdout)
        Assert-Sup ([bool]$staged.json.Contains('current_switched') -and -not [bool]$staged.json.current_switched) 'Pinned update switched current while a Job was live.'
        $versionB = [string]$staged.json.staged_version_id
        Assert-Sup ([string]$versionB -cmatch '^[0-9a-f]{64}$') 'Staged version B identity is invalid.'
        Assert-Sup ($versionB -cne $versionA) 'Staged version B reused version A.'
        $pendingPath = Join-Path $prodInstall 'pending.json'
        Assert-Sup ([IO.File]::Exists($pendingPath)) 'Pinned update did not publish base pending.json.'
        $pending = Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
        Assert-Sup ([string]$pending.version_id -ceq $versionB) 'Base pending.json did not point at version B.'
        $pointerStaged = Get-Content -LiteralPath (Join-Path $prodInstall 'current.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
        Assert-Sup ([string]$pointerStaged.version_id -ceq $versionA) 'Pinned update mutated current.json.'
        Assert-Sup ((Get-SupFileSha256 -Path $destPrivacy) -ceq $hashA) 'Pinned update replaced base dest bytes.'
        Assert-Sup ((Get-SupFileSha256 -Path (Join-Path $prodInstall 'install-manifest.json')) -ceq $manifestA) 'Pinned update replaced the base manifest.'
        Assert-Sup ([IO.Directory]::Exists((Join-Path $prodInstall ('versions\' + $versionB)))) 'Version B was not staged under the base store.'
        Assert-Sup (-not [IO.File]::Exists((Join-Path $versionADir 'pending.json'))) 'Pinned update created nested versionDir pending.json.'
        Assert-Sup (-not [IO.Directory]::Exists((Join-Path $versionADir 'versions'))) 'Pinned update created a nested version store.'
        $reqFast = New-SupRequest -RunId $runFast -MarkerDir $prodMarker -HoldMilliseconds 3000 -Project 'prod-fast' -Session 'prod-fast' -VersionId $versionA -VersionInstallRoot $prodInstall
        $reqCancel = New-SupRequest -RunId $runCancel -MarkerDir $prodMarker -HoldMilliseconds 30000 -Project 'prod-cancel' -Session 'prod-cancel' -VersionId $versionA -VersionInstallRoot $prodInstall
        $pathFast = Join-Path $prodRoot 'req-fast.json'
        $pathCancel = Join-Path $prodRoot 'req-cancel.json'
        Write-SupJson -Path $pathFast -Value $reqFast
        Write-SupJson -Path $pathCancel -Value $reqCancel
        $null = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @(
            '-RequestFile', $pathFast, '-StateRoot', $prodSupState, '-InstallRoot', $prodInstall
        )
        $null = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @(
            '-RequestFile', $pathCancel, '-StateRoot', $prodSupState, '-InstallRoot', $prodInstall
        )
        $ownerFastPath = Join-Path (Join-Path $prodSupState ('runs\' + $runFast)) 'owner.json'
        $ownerCancelPath = Join-Path (Join-Path $prodSupState ('runs\' + $runCancel)) 'owner.json'
        Assert-Sup (Wait-Sup { [IO.File]::Exists($ownerFastPath) -and [IO.File]::Exists($ownerCancelPath) } -Milliseconds 20000) 'Concurrent pinned owners were not published.'
        $outFast = Get-TelephoneSupervisorRecordPath -StateRoot $prodSupState -Kind outbox -RunId $runFast
        Assert-Sup (Wait-Sup { [IO.File]::Exists($outFast) } -Milliseconds 20000) 'First concurrent drain did not publish an outbox.'
        $ownerFast = (Read-TelephoneJson -Path $ownerFastPath -SchemaName 'wired-supervisor-owner').value
        Assert-Sup (Wait-Sup {
            $left = Get-Process -Id ([int]$ownerFast.pid) -ErrorAction SilentlyContinue
            try { return ($null -eq $left) } finally { if ($null -ne $left) { $left.Dispose() } }
        } -Milliseconds 15000) 'First concurrent run host remained after drain.'
        Assert-Sup ([IO.File]::Exists($pendingPath)) 'First concurrent drain activated pending while another Job remained.'
        Assert-Sup ([string]((Get-Content -LiteralPath (Join-Path $prodInstall 'current.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String).version_id) -ceq $versionA) 'First concurrent drain switched current.'
        Assert-Sup ((Get-SupFileSha256 -Path $destPrivacy) -ceq $hashA) 'First concurrent drain replaced dest bytes.'
        $cancelOne = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisorControl.ps1' -Arguments @(
            '-Action', 'cancel-one', '-RunId', $runCancel, '-StateRoot', $prodSupState, '-InstallRoot', $prodInstall
        )
        Assert-Sup ($cancelOne.exit_code -eq 0) ('cancel-one of a concurrent pinned run failed: ' + $cancelOne.stderr + $cancelOne.stdout)
        $outCancel = Get-TelephoneSupervisorRecordPath -StateRoot $prodSupState -Kind outbox -RunId $runCancel
        Assert-Sup (Wait-Sup { [IO.File]::Exists($outCancel) } -Milliseconds 15000) 'Cancelled concurrent run did not publish a terminal.'
        Assert-Sup ([string]((Read-TelephoneJson -Path $outCancel).value.terminal) -ceq 'cancelled') 'Cancelled concurrent run used the wrong terminal.'
        $ownerCancel = (Read-TelephoneJson -Path $ownerCancelPath -SchemaName 'wired-supervisor-owner').value
        Assert-Sup (Wait-Sup {
            $left = Get-Process -Id ([int]$ownerCancel.pid) -ErrorAction SilentlyContinue
            try { return ($null -eq $left) } finally { if ($null -ne $left) { $left.Dispose() } }
        } -Milliseconds 15000) 'Cancelled concurrent run host remained.'
        Assert-Sup ([IO.File]::Exists($pendingPath)) 'Cancel of a non-last pinned Job activated pending.'
        Assert-Sup ([string]((Get-Content -LiteralPath (Join-Path $prodInstall 'current.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String).version_id) -ceq $versionA) 'Cancel of a non-last pinned Job switched current.'
        $outSlow = Get-TelephoneSupervisorRecordPath -StateRoot $prodSupState -Kind outbox -RunId $runSlow
        Assert-Sup (Wait-Sup { [IO.File]::Exists($outSlow) } -Milliseconds 25000) 'Last pinned Job did not drain naturally.'
        Assert-Sup ([string]((Read-TelephoneJson -Path $outSlow).value.terminal) -ceq 'completed') 'Last pinned Job used the wrong terminal.'
        Assert-Sup (Wait-Sup {
            $left = Get-Process -Id ([int]$ownerSlow.pid) -ErrorAction SilentlyContinue
            try { return ($null -eq $left) } finally { if ($null -ne $left) { $left.Dispose() } }
        } -Milliseconds 15000) 'Last run host remained after natural drain.'
        Assert-Sup (Wait-Sup { -not [IO.File]::Exists($pendingPath) } -Milliseconds 15000) 'Base pending.json remained after the last pinned Job drained.'
        $pointerB = Get-Content -LiteralPath (Join-Path $prodInstall 'current.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
        Assert-Sup ([string]$pointerB.version_id -ceq $versionB) 'Last drain did not switch current to version B.'
        $pointerAfter = [IO.File]::ReadAllText((Join-Path $prodInstall 'current.json'))
        Start-Sleep -Milliseconds 400
        Assert-Sup ([IO.File]::ReadAllText((Join-Path $prodInstall 'current.json')) -ceq $pointerAfter) 'Current pointer was rewritten more than once after the last drain.'
        Assert-Sup ((Get-SupFileSha256 -Path $destPrivacy) -ceq $hashB) 'Last drain did not copy version B onto dest.'
        Assert-Sup ((Get-SupFileSha256 -Path (Join-Path $prodInstall 'install-manifest.json')) -cne $manifestA) 'Last drain left the version A manifest.'
        Assert-Sup ([IO.Directory]::Exists($versionADir)) 'Version A store was removed after activation.'
        Assert-Sup ([IO.File]::Exists((Join-Path $versionADir 'src\supervisor\Invoke-TelephoneSupervisorRunHost.ps1'))) 'Version A run-host bytes were removed.'
        Assert-Sup ([string]$ownerSlow.installed_version.version_id -ceq $versionA) 'Completed run evidence did not remain pinned to version A.'
        $nestedPending = @(Get-ChildItem -LiteralPath (Join-Path $prodInstall 'versions') -Recurse -Filter 'pending.json' -File -Force -ErrorAction SilentlyContinue)
        Assert-Sup ($nestedPending.Count -eq 0) 'Activation created nested pending.json under a version directory.'
        Assert-Sup (-not [IO.Directory]::Exists((Join-Path $versionADir 'versions'))) 'Activation created a nested version store.'
        Assert-Sup ([IO.File]::ReadAllText($prodPathFile) -ceq $pathBefore) 'Idle activation mutated PATH posture.'
        Assert-Sup ([IO.Directory]::Exists($prodLineState)) 'Idle activation removed durable line state.'
        Assert-Sup ([IO.File]::Exists($outSlow) -and [IO.File]::Exists($outFast) -and [IO.File]::Exists($outCancel)) 'Idle activation removed completed run evidence.'
        foreach ($runId in @($runSlow, $runFast, $runCancel)) {
            $job = Open-TelephoneSupervisorRunJob -RunId $runId -WaitMilliseconds 0
            try {
                Assert-Sup ([IntPtr]$job.handle -eq [IntPtr]::Zero) ('Named Job remained after drain: ' + $runId)
            } finally {
                Close-TelephoneSupervisorRunJob -Job $job
            }
        }
        $probe = Get-TelephoneSupervisorSingleOwnerProbe -StateRoot $prodSupState
        Assert-Sup ([int]$probe.live_owners -eq 0) 'A live supervisor owner remained after production-path drain.'
        Assert-Sup (-not [bool]$probe.mutex_held) 'Supervisor mutex remained held after production-path drain.'
        $actName = Get-TelephoneInstallActivationMutexName -InstallRoot $prodInstall
        $actCreated = $false
        $actMutex = [Threading.Mutex]::new($false, $actName, [ref]$actCreated)
        try {
            $actGot = $false
            try { $actGot = [bool]$actMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $actGot = $true }
            Assert-Sup $actGot 'Install activation mutex remained held.'
            if ($actGot) { try { [void]$actMutex.ReleaseMutex() } catch { } }
        } finally {
            $actMutex.Dispose()
        }
        $script:productionChainActivation = 1
    } finally {
        try {
            $null = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisorControl.ps1' -Arguments @(
                '-Action', 'emergency-stop-all', '-Confirm', '-StateRoot', $prodSupState, '-InstallRoot', $prodInstall
            )
        } catch { }
        try { Unregister-TelephoneSupervisorInstallSurface -InstallRoot $prodInstall } catch { }
        $env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT = [string]$savedEnv.TELEPHONE_LINE_SUPERVISOR_STATE_ROOT
        $env:TELEPHONE_LINE_TASK_STORE = [string]$savedEnv.TELEPHONE_LINE_TASK_STORE
        $env:TELEPHONE_LINE_DESKTOP_ROOT = [string]$savedEnv.TELEPHONE_LINE_DESKTOP_ROOT
        $env:TELEPHONE_LINE_RECYCLE_ROOT = [string]$savedEnv.TELEPHONE_LINE_RECYCLE_ROOT
        $env:TELEPHONE_LINE_INSTALL_ROOT = [string]$savedEnv.TELEPHONE_LINE_INSTALL_ROOT
        $env:TELEPHONE_LINE_SUPERVISOR_MARKER_DIR = [string]$savedEnv.TELEPHONE_LINE_SUPERVISOR_MARKER_DIR
        $env:TELEPHONE_LINE_STATE_ROOT = [string]$savedEnv.TELEPHONE_LINE_STATE_ROOT
        $env:TELEPHONE_LINE_USER_PATH_FILE = [string]$savedEnv.TELEPHONE_LINE_USER_PATH_FILE
    }

    $fanRoot = Join-Path $testRoot 'wired-six'
    $telState = Join-Path $fanRoot 'telephone-state'
    $fanWork = Join-Path $fanRoot 'worktree'
    $leadLog = Join-Path $fanRoot 'lead.log'
    $leadRuns = Join-Path $fanRoot 'lead-runs'
    $holdRoute = Join-Path $fanRoot 'hold-route.ps1'
    $missingHold = Join-Path $fanRoot 'release-pkg-missing'
    $specPath = Join-Path $fanRoot 'batch-spec.json'
    $mockRoute = Join-Path $repoRoot 'tests\core\fixtures\mock-route.ps1'
    $launcher = Join-Path $repoRoot 'tests\core\fixtures\mock-lead-launcher.ps1'
    $starter = Join-Path $repoRoot 'src\core\Start-TelephoneLineJob.ps1'
    $resumeScript = Join-Path $repoRoot 'src\core\Resume-TelephoneLines.ps1'
    foreach ($dir in @($fanRoot, $telState, $fanWork, $leadRuns)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
    Write-SupHoldRoute -Path $holdRoute
    $packageIds = @('pkg-success-1', 'pkg-success-2', 'pkg-exec-fail', 'pkg-start-failed', 'pkg-success-3', 'pkg-missing')
    $counters = @{}
    foreach ($packageId in $packageIds) { $counters[$packageId] = Join-Path $fanRoot ('count-' + $packageId + '.txt') }
    $binding = [ordered]@{
        protocol_version = 'telephone-line-lead-binding-v1'
        session_id = 'wired-mailbox-session-001'
        worktree = $fanWork
        launcher = [ordered]@{
            path = $launcher
            arguments = @()
        }
    }
    $leadKey = [string](Get-TelephoneLeadCanonicalIdentity -Lead $binding).identity_sha256
    $batchId = [guid]::NewGuid().ToString('D').ToLowerInvariant()
    $spec = [ordered]@{
        tel_state = $telState
        starter = $starter
        mock_route = $mockRoute
        hold_route = $holdRoute
        worktree = $fanWork
        project = 'wired-mailbox'
        lead_log = $leadLog
        lead_runs = $leadRuns
        collector_idle_ms = '8000'
        binding = $binding
        batch_id = $batchId
        package_ids = @($packageIds)
        packages = @(
            @{ id = 'pkg-success-1'; exit = 0; fail = $false; counter = [string]$counters['pkg-success-1'] },
            @{ id = 'pkg-success-2'; exit = 0; fail = $false; counter = [string]$counters['pkg-success-2'] },
            @{ id = 'pkg-exec-fail'; exit = 2; fail = $false; counter = [string]$counters['pkg-exec-fail'] },
            @{ id = 'pkg-start-failed'; exit = 0; fail = $true; counter = [string]$counters['pkg-start-failed'] },
            @{ id = 'pkg-success-3'; exit = 0; fail = $false; counter = [string]$counters['pkg-success-3'] },
            @{ id = 'pkg-missing'; exit = 0; fail = $false; counter = [string]$counters['pkg-missing']; hold_path = $missingHold }
        )
    }
    Write-SupJson -Path $specPath -Value $spec
    $previousForce = [Environment]::GetEnvironmentVariable('TELEPHONE_TEST_FORCE_COMMAND_START_FAILED', 'Process')
    $previousState = [string]$env:TELEPHONE_LINE_STATE_ROOT
    $previousLeadLog = [string]$env:TELEPHONE_TEST_LEAD_LOG
    $previousLeadRuns = [string]$env:TELEPHONE_TEST_LEAD_RUNS
    $previousIdle = [string]$env:TELEPHONE_TEST_COLLECTOR_IDLE_MS
    try {
        $env:TELEPHONE_LINE_STATE_ROOT = $telState
        $env:TELEPHONE_TEST_LEAD_LOG = $leadLog
        $env:TELEPHONE_TEST_LEAD_RUNS = $leadRuns
        $env:TELEPHONE_TEST_COLLECTOR_IDLE_MS = '8000'
        [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_FORCE_COMMAND_START_FAILED', $null, 'Process')
        $runSix = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee21'
        $reqSix = New-SupRequest -RunId $runSix -MarkerDir $marker -HoldMilliseconds 1000 -Project 'wired-mailbox' -Session 'wired-mailbox-session-001' -BatchFanIn -BatchSpecFile $specPath
        $pathSix = Join-Path $fanRoot 'req-six.json'
        Write-SupJson -Path $pathSix -Value $reqSix
        $startSix = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @(
            '-RequestFile', $pathSix, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
        )
        Assert-Sup ($startSix.exit_code -eq 0) ('Wired mailbox Lead start failed: ' + $startSix.stderr + $startSix.stdout)
        $leadSix = Join-Path $marker ('lead-' + $runSix + '.json')
        Assert-Sup (Wait-Sup { [IO.File]::Exists($leadSix) } -Milliseconds 30000) 'Wired mailbox Lead marker is missing.'
        Assert-Sup (Wait-Sup {
            if (-not [IO.File]::Exists($leadSix)) { return $false }
            try {
                $ev = (Read-TelephoneJson -Path $leadSix).value
                if ($ev.Contains('error') -and -not [string]::IsNullOrWhiteSpace([string]$ev.error)) { throw ('Wired mailbox Lead failed: ' + [string]$ev.error) }
                return ($ev.Contains('jobs') -and $null -ne $ev.jobs)
            } catch {
                if ([string]$_.Exception.Message -like 'Wired mailbox Lead failed:*') { throw }
                return $false
            }
        } -Milliseconds 90000) 'Wired mailbox six-route launch did not finish.'
        $mailbox = Get-TelephoneLeadMailboxPaths -StateRoot $telState -LeadKey $leadKey
        $batchPaths = Get-TelephoneBatchPaths -MailboxPaths $mailbox -BatchId $batchId
        Assert-Sup (Wait-Sup {
            if (-not [IO.File]::Exists($batchPaths.collection)) { return $false }
            try { return ([int]((Read-TelephoneJson -Path $batchPaths.collection).value.counted) -eq 5) } catch { return $false }
        } -Milliseconds 60000) 'Wired mailbox never reached 5/6.'
        $collectionFive = (Read-TelephoneJson -Path $batchPaths.collection).value
        Assert-Sup ([int]$collectionFive.counted -eq 5 -and [int]$collectionFive.n -eq 6) '5/6 collection denominator drifted.'
        Assert-Sup (-not [bool]$collectionFive.closed) '5/6 closed the batch early.'
        $missingFive = @($collectionFive.missing | ForEach-Object { [string]$_.package_id })
        Assert-Sup ($missingFive.Count -eq 1 -and [string]$missingFive[0] -ceq 'pkg-missing') '5/6 missing identity was not pkg-missing.'
        Assert-Sup (-not [IO.File]::Exists($batchPaths.manifest)) '5/6 published a closed manifest.'
        Assert-Sup (-not [IO.File]::Exists($batchPaths.wake_attempt)) '5/6 published a wake attempt.'
        $wakeRunId = 'telephone-batch-' + $batchId
        Assert-Sup ((Get-SupLeadLogWakeCount -LogPath $leadLog -RunId $wakeRunId) -eq 0) '5/6 woke the Lead.'
        Assert-Sup ((Get-SupCounterCount -Path ([string]$counters['pkg-success-1'])) -eq 1) 'Completed success-1 command count drifted at 5/6.'
        Assert-Sup ((Get-SupCounterCount -Path ([string]$counters['pkg-success-2'])) -eq 1) 'Completed success-2 command count drifted at 5/6.'
        Assert-Sup ((Get-SupCounterCount -Path ([string]$counters['pkg-exec-fail'])) -eq 1) 'Explicit-failure command count drifted at 5/6.'
        Assert-Sup ((Get-SupCounterCount -Path ([string]$counters['pkg-success-3'])) -eq 1) 'Completed success-3 command count drifted at 5/6.'
        Assert-Sup ((Get-SupCounterCount -Path ([string]$counters['pkg-start-failed'])) -eq 0) 'START_FAILED invoked the route.'
        Assert-Sup ((Get-SupCounterCount -Path ([string]$counters['pkg-missing'])) -eq 0) '5/6 missing package invoked the route before recovery.'
        $script:mailboxFiveOfSix = 1
        $leadEv = (Read-TelephoneJson -Path $leadSix).value
        Assert-Sup ([int]$leadEv.launch_span_ms -ge 0 -and [int]$leadEv.launch_span_ms -le 3000) ('Six-route OS launch span exceeded 3000 ms: ' + [string]$leadEv.launch_span_ms)
        $jobs = $leadEv.jobs
        $ownerSixPath = Join-Path (Join-Path $script:supState ('runs\' + $runSix)) 'owner.json'
        Assert-Sup (Wait-Sup { [IO.File]::Exists($ownerSixPath) } -Milliseconds 20000) 'Wired mailbox run owner is missing.'
        Assert-Sup (Wait-Sup {
            $left = Get-Process -Id ([int]$leadEv.lead_pid) -ErrorAction SilentlyContinue
            try { return ($null -eq $left) } finally { if ($null -ne $left) { $left.Dispose() } }
        } -Milliseconds 15000) 'Initial mailbox Lead did not exit.'
        Assert-Sup (Wait-Sup {
            if (-not [IO.File]::Exists([string]$mailbox.owner)) { return $false }
            try { return (Test-TelephoneOwnerAlive -Owner ((Read-TelephoneJson -Path ([string]$mailbox.owner)).value)) } catch { return $false }
        } -Milliseconds 20000) 'Mailbox collector did not stay alive after Lead exit.'
        $collectorOwner = (Read-TelephoneJson -Path ([string]$mailbox.owner)).value
        $jobSix = Open-TelephoneSupervisorRunJob -RunId $runSix -WaitMilliseconds 0
        try {
            Assert-Sup ($null -ne $jobSix -and [IntPtr]$jobSix.handle -ne [IntPtr]::Zero) 'Named Job disappeared after mailbox Lead exit.'
            Assert-Sup (Test-TelephoneSupervisorPidInJob -Job $jobSix -ProcessId ([int]$collectorOwner.pid)) 'Collector is not in the exact Job after Lead exit.'
            foreach ($packageId in @('pkg-success-1', 'pkg-success-2', 'pkg-exec-fail', 'pkg-start-failed', 'pkg-success-3', 'pkg-missing')) {
                $relayPath = Join-Path ([string]$jobs[$packageId].job_root) 'relay-owner.json'
                if (-not [IO.File]::Exists($relayPath)) { continue }
                $relayOwner = (Read-TelephoneJson -Path $relayPath).value
                if (Test-TelephoneOwnerAlive -Owner $relayOwner) {
                    Assert-Sup (Test-TelephoneSupervisorPidInJob -Job $jobSix -ProcessId ([int]$relayOwner.pid)) ('Relay for ' + $packageId + ' is not in the exact Job.')
                }
            }
        } finally {
            Close-TelephoneSupervisorRunJob -Job $jobSix
        }
        $script:mailboxCollectorInJob = 1
        $statusFive = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisorControl.ps1' -Arguments @(
            '-Action', 'status', '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
        )
        Assert-Sup ($statusFive.exit_code -eq 0) ('Status at 5/6 failed: ' + $statusFive.stderr)
        $activeFive = @($statusFive.json.status.active_runs | Where-Object { [string]$_.run_id -ceq $runSix })
        Assert-Sup ($activeFive.Count -eq 1) 'Status omitted the mailbox run at 5/6.'
        Assert-Sup ([string]$activeFive[0].lead_session_id -ceq 'wired-mailbox-session-001') 'Status omitted exact Lead session identity.'
        Assert-Sup ([string]$activeFive[0].lead_identity_sha256 -ceq $leadKey) 'Status omitted exact Lead mailbox identity.'
        Assert-Sup ([string]$activeFive[0].mailbox_batch_id -ceq $batchId) 'Status omitted exact mailbox batch identity.'
        Assert-Sup ([int]$activeFive[0].mailbox_counted -eq 5) 'Status omitted collecting 5/6 truth.'
        Assert-Sup ([bool]$activeFive[0].collector_in_job) 'Status omitted collector Job membership.'
        $restartLive = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisor.ps1' -Arguments @('-InstallRoot', $repoRoot, '-StateRoot', $script:supState)
        Assert-Sup ($restartLive.exit_code -eq 0) 'Supervisor restart against a live mailbox run failed.'
        Assert-Sup ([bool]$restartLive.json.duplicate -or [int]$restartLive.json.launched -eq 0) 'Supervisor restart launched a second owner for a live mailbox run.'
        Assert-Sup ((Get-SupLeadLogWakeCount -LogPath $leadLog -RunId $wakeRunId) -eq 0) 'Supervisor restart woke the Lead at 5/6.'
        Assert-Sup ((Get-SupCounterCount -Path ([string]$counters['pkg-success-1'])) -eq 1) 'Supervisor restart reran a completed package.'
        $oldCollector = (Read-TelephoneJson -Path ([string]$mailbox.owner)).value
        $oldCollectorPid = [int]$oldCollector.pid
        $oldCollectorTicks = [int64]$oldCollector.start_time_utc_ticks
        try { Stop-Process -Id $oldCollectorPid -Force -ErrorAction SilentlyContinue } catch { }
        Assert-Sup (Wait-Sup {
            if (-not [IO.File]::Exists([string]$mailbox.owner)) { return $false }
            try {
                $nowOwner = (Read-TelephoneJson -Path ([string]$mailbox.owner)).value
                return (([int]$nowOwner.pid -ne $oldCollectorPid -or [int64]$nowOwner.start_time_utc_ticks -ne $oldCollectorTicks) -and (Test-TelephoneOwnerAlive -Owner $nowOwner))
            } catch { return $false }
        } -Milliseconds 25000) 'Collector owner death was not recovered.'
        $recoveredOwner = (Read-TelephoneJson -Path ([string]$mailbox.owner)).value
        Assert-Sup (-not (Test-TelephoneOwnerAlive -Owner $oldCollector)) 'Dead collector owner was treated as live after PID reuse window.'
        $jobAfterDeath = Open-TelephoneSupervisorRunJob -RunId $runSix -WaitMilliseconds 0
        try {
            Assert-Sup (Test-TelephoneSupervisorPidInJob -Job $jobAfterDeath -ProcessId ([int]$recoveredOwner.pid)) 'Recovered collector is not in the exact Job.'
        } finally {
            Close-TelephoneSupervisorRunJob -Job $jobAfterDeath
        }
        $collectionAfterDeath = (Read-TelephoneJson -Path $batchPaths.collection).value
        Assert-Sup ([int]$collectionAfterDeath.counted -eq 5) 'Collector recovery mutated 5/6 counted.'
        Assert-Sup ((Get-SupLeadLogWakeCount -LogPath $leadLog -RunId $wakeRunId) -eq 0) 'Collector recovery woke the Lead at 5/6.'
        [IO.File]::WriteAllText($missingHold, "release`n", [Text.UTF8Encoding]::new($false))
        Assert-Sup (Wait-Sup {
            if (-not [IO.File]::Exists($batchPaths.collection)) { return $false }
            try { return ([int]((Read-TelephoneJson -Path $batchPaths.collection).value.counted) -eq 6) } catch { return $false }
        } -Milliseconds 60000) 'Missing-only recovery never reached 6/6.'
        Assert-Sup ((Get-SupCounterCount -Path ([string]$counters['pkg-success-1'])) -eq 1) 'Missing recovery reran a completed success package.'
        Assert-Sup ((Get-SupCounterCount -Path ([string]$counters['pkg-exec-fail'])) -eq 1) 'Missing recovery reran the explicit-failure package.'
        Assert-Sup ((Get-SupCounterCount -Path ([string]$counters['pkg-start-failed'])) -eq 0) 'Missing recovery invoked START_FAILED.'
        Assert-Sup ((Get-SupCounterCount -Path ([string]$counters['pkg-missing'])) -eq 1) 'Missing package command count was not one.'
        Assert-Sup (Wait-Sup { [IO.File]::Exists($batchPaths.manifest) } -Milliseconds 40000) '6/6 did not publish one closed manifest.'
        $manifestOne = Read-TelephoneJson -Path $batchPaths.manifest -SchemaName 'telephone-line-batch'
        $manifestBytes = Get-SupFileSha256 -Path $batchPaths.manifest
        Assert-Sup ([bool]$manifestOne.value.closed -eq $true -and [int]$manifestOne.value.counted -eq 6) 'Closed manifest counted/closed drifted.'
        Assert-Sup ([string]$manifestOne.value.wake_run_id -ceq $wakeRunId) 'Batch wake_run_id drifted.'
        $fifoHashes = @($manifestOne.value.items | ForEach-Object { [string]$_.receipt.sha256 })
        Assert-Sup ($fifoHashes.Count -eq 6) 'Closed manifest did not list six receipt hashes.'
        Assert-Sup ((@($fifoHashes | Select-Object -Unique)).Count -eq 6) 'Closed manifest receipt hashes were not unique.'
        Assert-Sup (Wait-Sup { (Get-SupLeadLogWakeCount -LogPath $leadLog -RunId $wakeRunId) -eq 1 } -Milliseconds 40000) '6/6 did not wake the exact Lead once.'
        $allDelivered = Wait-Sup {
            foreach ($packageId in $packageIds) {
                $delivery = Join-Path ([string]$jobs[$packageId].job_root) 'delivery.json'
                if (-not [IO.File]::Exists($delivery)) { return $false }
            }
            return $true
        } -Milliseconds 60000
        Assert-Sup $allDelivered '6/6 never delivered all six jobs.'
        $deliveredHashes = [Collections.Generic.List[string]]::new()
        foreach ($item in @($manifestOne.value.items)) {
            $delivery = (Read-TelephoneJson -Path (Join-Path ([string]$jobs[[string]$item.package_id].job_root) 'delivery.json')).value
            Assert-Sup ([string]$delivery.wake_run_id -ceq $wakeRunId) ('Delivery wake_run_id drifted for ' + [string]$item.package_id)
            [void]$deliveredHashes.Add([string]$item.receipt.sha256)
        }
        Assert-Sup ((@($deliveredHashes) -join '|') -ceq (@($fifoHashes) -join '|')) 'Delivered receipt hashes were not mailbox FIFO order.'
        Assert-Sup ((Get-SupFileSha256 -Path $batchPaths.manifest) -ceq $manifestBytes) 'Batch-one manifest bytes changed after delivery.'
        Assert-Sup ((Get-SupLeadLogWakeCount -LogPath $leadLog -RunId $wakeRunId) -eq 1) '6/6 woke the Lead more than once.'
        $script:mailboxOneWake = 1
        $resumeAfter = Invoke-SupScript -Relative 'src\core\Resume-TelephoneLines.ps1' -Arguments @('-StateRoot', $telState)
        Assert-Sup ($resumeAfter.exit_code -eq 0) ('Resume after 6/6 failed: ' + $resumeAfter.stderr + $resumeAfter.stdout)
        Assert-Sup ((Get-SupCounterCount -Path ([string]$counters['pkg-success-1'])) -eq 1) 'Resume after 6/6 reran a completed package.'
        Assert-Sup ((Get-SupCounterCount -Path ([string]$counters['pkg-missing'])) -eq 1) 'Resume after 6/6 reran the recovered package.'
        Assert-Sup ((Get-SupLeadLogWakeCount -LogPath $leadLog -RunId $wakeRunId) -eq 1) 'Resume after 6/6 re-woke the closed batch.'
        $script:mailboxNoCompletedRerun = 1
        $outSix = Get-TelephoneSupervisorRecordPath -StateRoot $script:supState -Kind outbox -RunId $runSix
        Assert-Sup (Wait-Sup { [IO.File]::Exists($outSix) } -Milliseconds 30000) 'Natural mailbox drain did not publish a completed outbox.'
        Assert-Sup ([string]((Read-TelephoneJson -Path $outSix).value.terminal) -ceq 'completed') 'Natural mailbox drain used the wrong terminal.'
        Assert-Sup (Wait-Sup {
            if (-not [IO.File]::Exists([string]$mailbox.owner)) { return $true }
            try { return (-not (Test-TelephoneOwnerAlive -Owner ((Read-TelephoneJson -Path ([string]$mailbox.owner)).value))) } catch { return $true }
        } -Milliseconds 20000) 'Collector owner remained live after natural completion.'
        $jobAfterComplete = Open-TelephoneSupervisorRunJob -RunId $runSix -WaitMilliseconds 0
        try {
            Assert-Sup ([IntPtr]$jobAfterComplete.handle -eq [IntPtr]::Zero) 'Named Job remained after mailbox drain.'
        } finally {
            Close-TelephoneSupervisorRunJob -Job $jobAfterComplete
        }
        $gateHeld = $false
        $gate = Open-TelephoneExclusiveGate -Path ([string]$mailbox.gate) -WaitMilliseconds 0
        if ($null -eq $gate) { $gateHeld = $true } else { $gate.Dispose() }
        Assert-Sup (-not $gateHeld) 'Mailbox gate remained held after natural completion.'
        $script:mailboxZeroResidue = 1

        $retryIds = @('pkg-exec-fail', 'pkg-start-failed')
        $batchRetry = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        $retrySpecPath = Join-Path $fanRoot 'retry-spec.json'
        $retryCounters = @{
            'pkg-exec-fail' = Join-Path $fanRoot 'retry-exec.txt'
            'pkg-start-failed' = Join-Path $fanRoot 'retry-start.txt'
        }
        $retrySpec = [ordered]@{
            tel_state = $telState
            starter = $starter
            mock_route = $mockRoute
            hold_route = $holdRoute
            worktree = $fanWork
            project = 'wired-mailbox'
            lead_log = $leadLog
            lead_runs = $leadRuns
            collector_idle_ms = '8000'
            binding = $binding
            batch_id = $batchRetry
            retry_of = $batchId
            package_ids = @($retryIds)
            packages = @(
                @{ id = 'pkg-exec-fail'; exit = 2; fail = $false; counter = [string]$retryCounters['pkg-exec-fail'] },
                @{ id = 'pkg-start-failed'; exit = 0; fail = $true; counter = [string]$retryCounters['pkg-start-failed'] }
            )
        }
        Write-SupJson -Path $retrySpecPath -Value $retrySpec
        $runRetry = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee22'
        $reqRetry = New-SupRequest -RunId $runRetry -MarkerDir $marker -HoldMilliseconds 1000 -Project 'wired-mailbox' -Session 'wired-mailbox-session-001' -BatchFanIn -BatchSpecFile $retrySpecPath
        $pathRetry = Join-Path $fanRoot 'req-retry.json'
        Write-SupJson -Path $pathRetry -Value $reqRetry
        $startRetry = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @(
            '-RequestFile', $pathRetry, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
        )
        Assert-Sup ($startRetry.exit_code -eq 0) ('Retry Lead start failed: ' + $startRetry.stderr + $startRetry.stdout)
        $retryPaths = Get-TelephoneBatchPaths -MailboxPaths $mailbox -BatchId $batchRetry
        Assert-Sup (Wait-Sup { [IO.File]::Exists($retryPaths.manifest) } -Milliseconds 60000) 'Retry batch omitted its closed manifest.'
        $retryWake = 'telephone-batch-' + $batchRetry
        Assert-Sup (Wait-Sup { (Get-SupLeadLogWakeCount -LogPath $leadLog -RunId $retryWake) -eq 1 } -Milliseconds 40000) 'Retry batch did not produce exactly one later wake.'
        Assert-Sup ((Get-SupLeadLogWakeCount -LogPath $leadLog -RunId $wakeRunId) -eq 1) 'Retry wake replaced batch one.'
        Assert-Sup ((Get-SupFileSha256 -Path $batchPaths.manifest) -ceq $manifestBytes) 'Retry batch mutated batch-one manifest bytes.'
        Assert-Sup ((Get-SupCounterCount -Path ([string]$counters['pkg-exec-fail'])) -eq 1) 'Retry reran the completed original executor.'
        $outRetry = Get-TelephoneSupervisorRecordPath -StateRoot $script:supState -Kind outbox -RunId $runRetry
        Assert-Sup (Wait-Sup { [IO.File]::Exists($outRetry) } -Milliseconds 30000) 'Retry run did not drain.'
        $script:mailboxRetryOnce = 1

        $cancelHold = Join-Path $fanRoot 'release-cancel-missing'
        $cancelBatch = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        $cancelSpecPath = Join-Path $fanRoot 'cancel-spec.json'
        $cancelCounters = @{}
        foreach ($packageId in $packageIds) { $cancelCounters[$packageId] = Join-Path $fanRoot ('cancel-count-' + $packageId + '.txt') }
        $cancelSpec = [ordered]@{
            tel_state = $telState
            starter = $starter
            mock_route = $mockRoute
            hold_route = $holdRoute
            worktree = $fanWork
            project = 'wired-mailbox'
            lead_log = $leadLog
            lead_runs = $leadRuns
            collector_idle_ms = '8000'
            binding = $binding
            batch_id = $cancelBatch
            package_ids = @($packageIds)
            packages = @(
                @{ id = 'pkg-success-1'; exit = 0; fail = $false; counter = [string]$cancelCounters['pkg-success-1'] },
                @{ id = 'pkg-success-2'; exit = 0; fail = $false; counter = [string]$cancelCounters['pkg-success-2'] },
                @{ id = 'pkg-exec-fail'; exit = 2; fail = $false; counter = [string]$cancelCounters['pkg-exec-fail'] },
                @{ id = 'pkg-start-failed'; exit = 0; fail = $true; counter = [string]$cancelCounters['pkg-start-failed'] },
                @{ id = 'pkg-success-3'; exit = 0; fail = $false; counter = [string]$cancelCounters['pkg-success-3'] },
                @{ id = 'pkg-missing'; exit = 0; fail = $false; counter = [string]$cancelCounters['pkg-missing']; hold_path = $cancelHold }
            )
        }
        Write-SupJson -Path $cancelSpecPath -Value $cancelSpec
        $runCancelMb = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee23'
        $reqCancelMb = New-SupRequest -RunId $runCancelMb -MarkerDir $marker -HoldMilliseconds 1000 -Project 'wired-mailbox' -Session 'wired-mailbox-session-001' -BatchFanIn -BatchSpecFile $cancelSpecPath
        $pathCancelMb = Join-Path $fanRoot 'req-cancel.json'
        Write-SupJson -Path $pathCancelMb -Value $reqCancelMb
        $null = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @(
            '-RequestFile', $pathCancelMb, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
        )
        $cancelPaths = Get-TelephoneBatchPaths -MailboxPaths $mailbox -BatchId $cancelBatch
        Assert-Sup (Wait-Sup {
            if (-not [IO.File]::Exists($cancelPaths.collection)) { return $false }
            try { return ([int]((Read-TelephoneJson -Path $cancelPaths.collection).value.counted) -eq 5) } catch { return $false }
        } -Milliseconds 60000) 'Cancel fixture never reached 5/6.'
        $cancelOneMb = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisorControl.ps1' -Arguments @(
            '-Action', 'cancel-one', '-RunId', $runCancelMb, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
        )
        Assert-Sup ($cancelOneMb.exit_code -eq 0) ('Mailbox cancel-one failed: ' + $cancelOneMb.stderr + $cancelOneMb.stdout)
        $outCancelMb = Get-TelephoneSupervisorRecordPath -StateRoot $script:supState -Kind outbox -RunId $runCancelMb
        Assert-Sup (Wait-Sup { [IO.File]::Exists($outCancelMb) } -Milliseconds 15000) 'Mailbox cancel-one did not publish a terminal.'
        Assert-Sup ([string]((Read-TelephoneJson -Path $outCancelMb).value.terminal) -ceq 'cancelled') 'Mailbox cancel-one used the wrong terminal.'
        Assert-Sup ([IO.File]::Exists($cancelPaths.collection)) 'Cancel deleted mailbox collection evidence.'
        Assert-Sup ([int]((Read-TelephoneJson -Path $cancelPaths.collection).value.counted) -eq 5) 'Cancel mutated partial mailbox collection.'
        Assert-Sup (-not [IO.File]::Exists($cancelPaths.manifest)) 'Cancel published a closed manifest.'
        Assert-Sup (Wait-Sup {
            if (-not [IO.File]::Exists([string]$mailbox.owner)) { return $true }
            try { return (-not (Test-TelephoneOwnerAlive -Owner ((Read-TelephoneJson -Path ([string]$mailbox.owner)).value))) } catch { return $true }
        } -Milliseconds 15000) 'Cancel left the collector alive.'
        $resumeAfterCancel = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisorControl.ps1' -Arguments @(
            '-Action', 'resume', '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
        )
        Assert-Sup ($resumeAfterCancel.exit_code -eq 0) 'Resume after mailbox cancel failed.'
        Assert-Sup ([bool]$resumeAfterCancel.json.Contains('resurrected') -and -not [bool]$resumeAfterCancel.json.resurrected) 'Resume claimed to resurrect cancelled mailbox work.'
        Assert-Sup ([string]((Read-TelephoneJson -Path $outCancelMb).value.terminal) -ceq 'cancelled') 'Resume resurrected a cancelled mailbox run.'
        Assert-Sup (-not [IO.File]::Exists($cancelPaths.manifest)) 'Resume resurrected a cancelled mailbox batch.'
        $script:mailboxCancelPreserves = 1

        $emergHold = Join-Path $fanRoot 'release-emerg-missing'
        $emergBatch = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        $emergSpecPath = Join-Path $fanRoot 'emerg-spec.json'
        $emergCounters = @{}
        foreach ($packageId in $packageIds) { $emergCounters[$packageId] = Join-Path $fanRoot ('emerg-count-' + $packageId + '.txt') }
        $emergSpec = [ordered]@{
            tel_state = $telState
            starter = $starter
            mock_route = $mockRoute
            hold_route = $holdRoute
            worktree = $fanWork
            project = 'wired-mailbox'
            lead_log = $leadLog
            lead_runs = $leadRuns
            collector_idle_ms = '8000'
            binding = $binding
            batch_id = $emergBatch
            package_ids = @($packageIds)
            packages = @(
                @{ id = 'pkg-success-1'; exit = 0; fail = $false; counter = [string]$emergCounters['pkg-success-1'] },
                @{ id = 'pkg-success-2'; exit = 0; fail = $false; counter = [string]$emergCounters['pkg-success-2'] },
                @{ id = 'pkg-exec-fail'; exit = 2; fail = $false; counter = [string]$emergCounters['pkg-exec-fail'] },
                @{ id = 'pkg-start-failed'; exit = 0; fail = $true; counter = [string]$emergCounters['pkg-start-failed'] },
                @{ id = 'pkg-success-3'; exit = 0; fail = $false; counter = [string]$emergCounters['pkg-success-3'] },
                @{ id = 'pkg-missing'; exit = 0; fail = $false; counter = [string]$emergCounters['pkg-missing']; hold_path = $emergHold }
            )
        }
        Write-SupJson -Path $emergSpecPath -Value $emergSpec
        $runEmerg = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee24'
        $reqEmerg = New-SupRequest -RunId $runEmerg -MarkerDir $marker -HoldMilliseconds 1000 -Project 'wired-mailbox' -Session 'wired-mailbox-session-001' -BatchFanIn -BatchSpecFile $emergSpecPath
        $pathEmerg = Join-Path $fanRoot 'req-emerg.json'
        Write-SupJson -Path $pathEmerg -Value $reqEmerg
        $null = Invoke-SupScript -Relative 'src\supervisor\Start-TelephoneWiredRun.ps1' -Arguments @(
            '-RequestFile', $pathEmerg, '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
        )
        $emergPaths = Get-TelephoneBatchPaths -MailboxPaths $mailbox -BatchId $emergBatch
        Assert-Sup (Wait-Sup {
            if (-not [IO.File]::Exists($emergPaths.collection)) { return $false }
            try { return ([int]((Read-TelephoneJson -Path $emergPaths.collection).value.counted) -ge 1) } catch { return $false }
        } -Milliseconds 60000) 'Emergency fixture never collected a mailbox item.'
        $emerg = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisorControl.ps1' -Arguments @(
            '-Action', 'emergency-stop-all', '-Confirm', '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
        )
        Assert-Sup ($emerg.exit_code -eq 0) ('Mailbox emergency-stop-all failed: ' + $emerg.stderr)
        Assert-Sup ([bool]$emerg.json.paused_by_pascal) 'Mailbox emergency did not latch pause.'
        $outEmerg = Get-TelephoneSupervisorRecordPath -StateRoot $script:supState -Kind outbox -RunId $runEmerg
        Assert-Sup (Wait-Sup { [IO.File]::Exists($outEmerg) } -Milliseconds 15000) 'Mailbox emergency did not publish a terminal.'
        Assert-Sup ([IO.File]::Exists($emergPaths.collection)) 'Emergency deleted mailbox evidence.'
        $null = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisorControl.ps1' -Arguments @(
            '-Action', 'resume', '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
        )
        $script:mailboxSixResult = 1
    } finally {
        [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_FORCE_COMMAND_START_FAILED', $previousForce, 'Process')
        $env:TELEPHONE_LINE_STATE_ROOT = $previousState
        $env:TELEPHONE_TEST_LEAD_LOG = $previousLeadLog
        $env:TELEPHONE_TEST_LEAD_RUNS = $previousLeadRuns
        $env:TELEPHONE_TEST_COLLECTOR_IDLE_MS = $previousIdle
    }

    Unregister-TelephoneSupervisorInstallSurface -InstallRoot $repoRoot
    Assert-Sup (-not [IO.File]::Exists((Join-Path $taskStore 'task.json'))) 'Unregister left the mock task.'
    Assert-Sup (-not [IO.File]::Exists((Join-Path $desktop '有线电话｜紧急停止.lnk'))) 'Emergency shortcut remained.'

    $recycleFn = ${function:Move-TelephonePathToRecycleBin}.ToString()
    Assert-Sup ($recycleFn -notmatch 'Remove-Item') 'Supervisor recycle falls back to Remove-Item.'
    Assert-Sup ($recycleFn -notmatch '\[IO\.Directory\]::Delete') 'Supervisor recycle falls back to Directory.Delete.'
    Assert-Sup ($recycleFn -notmatch '\[IO\.File\]::Delete') 'Supervisor recycle falls back to File.Delete.'
    Assert-Sup ($recycleFn -notmatch 'Stop-Process') 'Supervisor recycle signals processes.'
    $script:recycleNoDirectDelete = 1

    $foreignInfo = [Diagnostics.ProcessStartInfo]::new()
    $foreignInfo.FileName = $pwsh
    $foreignInfo.UseShellExecute = $false
    $foreignInfo.CreateNoWindow = $true
    $foreignInfo.RedirectStandardOutput = $true
    $foreignInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30')) {
        [void]$foreignInfo.ArgumentList.Add([string]$argument)
    }
    $foreignProc = [Diagnostics.Process]::Start($foreignInfo)
    if ($foreignProc.HasExited) { throw 'Supervisor foreign-owner fixture exited immediately.' }
    try {
        $foreignOwner = New-TelephoneSupervisorOwnerSnapshot -Kind supervisor -ProcessId ([int]$foreignProc.Id)
        $foreignRoot = Join-Path $testRoot 'recycle-foreign'
        $null = Initialize-TelephoneSupervisorLayout -StateRoot $foreignRoot
        $null = Write-TelephoneJsonReplace -Path (Get-TelephoneSupervisorPaths -StateRoot $foreignRoot).supervisor_owner -Value $foreignOwner
        [IO.File]::WriteAllText((Join-Path $foreignRoot 'evidence.txt'), 'leave-me')
        $threw = $false
        try { $null = Move-TelephonePathToRecycleBin -Path $foreignRoot } catch { $threw = ([string]$_.Exception.Message -ceq 'RECYCLE_BLOCKED') }
        Assert-Sup $threw 'Supervisor recycle did not refuse a live foreign owner.'
        Assert-Sup ([IO.Directory]::Exists($foreignRoot)) 'Supervisor recycle removed foreign-owned evidence.'
        Assert-Sup (Test-TelephoneOwnerAlive -Owner $foreignOwner) 'Supervisor recycle signaled the foreign owner.'
        $script:recycleForeignOwnerRefused = 1
    } finally {
        if ($null -ne $foreignProc) {
            $identity = [ordered]@{
                pid = [int]$foreignProc.Id
                start_time_utc_ticks = [int64]$foreignProc.StartTime.ToUniversalTime().Ticks
            }
            if (Test-TelephoneOwnerAlive -Owner $identity) {
                try { $foreignProc.Kill() } catch { }
                try { [void]$foreignProc.WaitForExit(3000) } catch { }
            }
            try { $foreignProc.Dispose() } catch { }
        }
    }

    [ordered]@{
        success = $true
        assertions = $assertions
        supervisor_atomic_publish = $positiveAtomicPublish
        supervisor_scheduler_trigger = $schedulerTrigger
        supervisor_one_mutex = $oneMutexOwner
        supervisor_job_membership = $jobMembershipInherited
        supervisor_completed_outbox = $durableCompletedOutbox
        supervisor_replay_once = $sameByteReplayOnce
        supervisor_negative_fail_closed = $negativeFailClosed
        supervisor_cancel_one_isolated = $cancelOneIsolated
        supervisor_emergency_pause = $emergencyPauseLatch
        supervisor_paused_no_launch = $pausedNoLaunch
        supervisor_resume_no_resurrect = $resumeNoResurrect
        supervisor_queued_restart = $queuedSurvivesRestart
        supervisor_death_failed = $supervisorDeathFailed
        supervisor_no_orphan = $noOrphanAfterComplete
        supervisor_early_lead_exit = $earlyLeadExitJobSurvives
        supervisor_callback_continuity = $callbackResumedChild
        supervisor_run_host_death = $runHostDeathNegative
        supervisor_gui_cancel_one = $guiCancelOne
        supervisor_production_idle_activation = $productionChainActivation
        supervisor_mailbox_six_result = $mailboxSixResult
        supervisor_mailbox_five_of_six = $mailboxFiveOfSix
        supervisor_mailbox_one_wake = $mailboxOneWake
        supervisor_mailbox_retry_once = $mailboxRetryOnce
        supervisor_mailbox_no_completed_rerun = $mailboxNoCompletedRerun
        supervisor_mailbox_collector_in_job = $mailboxCollectorInJob
        supervisor_mailbox_cancel_preserves = $mailboxCancelPreserves
        supervisor_mailbox_zero_residue = $mailboxZeroResidue
        supervisor_recycle_foreign_owner_refused = $recycleForeignOwnerRefused
        supervisor_recycle_no_direct_delete = $recycleNoDirectDelete
    } | ConvertTo-Json -Compress
} catch {
    [ordered]@{
        success = $false
        error = [string]$_.Exception.Message
        assertions = $assertions
        supervisor_atomic_publish = $positiveAtomicPublish
        supervisor_scheduler_trigger = $schedulerTrigger
        supervisor_one_mutex = $oneMutexOwner
        supervisor_job_membership = $jobMembershipInherited
        supervisor_completed_outbox = $durableCompletedOutbox
        supervisor_replay_once = $sameByteReplayOnce
        supervisor_negative_fail_closed = $negativeFailClosed
        supervisor_cancel_one_isolated = $cancelOneIsolated
        supervisor_emergency_pause = $emergencyPauseLatch
        supervisor_paused_no_launch = $pausedNoLaunch
        supervisor_resume_no_resurrect = $resumeNoResurrect
        supervisor_queued_restart = $queuedSurvivesRestart
        supervisor_death_failed = $supervisorDeathFailed
        supervisor_no_orphan = $noOrphanAfterComplete
        supervisor_early_lead_exit = $earlyLeadExitJobSurvives
        supervisor_callback_continuity = $callbackResumedChild
        supervisor_run_host_death = $runHostDeathNegative
        supervisor_gui_cancel_one = $guiCancelOne
        supervisor_production_idle_activation = $productionChainActivation
        supervisor_mailbox_six_result = $mailboxSixResult
        supervisor_mailbox_five_of_six = $mailboxFiveOfSix
        supervisor_mailbox_one_wake = $mailboxOneWake
        supervisor_mailbox_retry_once = $mailboxRetryOnce
        supervisor_mailbox_no_completed_rerun = $mailboxNoCompletedRerun
        supervisor_mailbox_collector_in_job = $mailboxCollectorInJob
        supervisor_mailbox_cancel_preserves = $mailboxCancelPreserves
        supervisor_mailbox_zero_residue = $mailboxZeroResidue
        supervisor_recycle_foreign_owner_refused = $recycleForeignOwnerRefused
        supervisor_recycle_no_direct_delete = $recycleNoDirectDelete
    } | ConvertTo-Json -Compress
    exit 1
} finally {
    try {
        $null = Invoke-SupScript -Relative 'src\supervisor\Invoke-TelephoneSupervisorControl.ps1' -Arguments @(
            '-Action', 'emergency-stop-all', '-Confirm', '-StateRoot', $script:supState, '-InstallRoot', $repoRoot
        )
    } catch { }
    try { Unregister-TelephoneSupervisorInstallSurface -InstallRoot $repoRoot } catch { }
}

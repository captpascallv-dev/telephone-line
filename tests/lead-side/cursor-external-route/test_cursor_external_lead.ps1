# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PreviousDashboardProcessEnvOnly = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY', 'Process')
$script:PreviousDashboardOptOut = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', 'Process')
[Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY', '1', 'Process')
[Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', '1', 'Process')
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'src\core\TelephoneLine.Common.ps1')
. (Join-Path $repoRoot 'src\lead-side\cursor-external-route\CursorExternalLead.Common.ps1')
$pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$builder = Join-Path $repoRoot 'src\lead-side\cursor-external-route\New-CursorExternalLeadDispatch.ps1'
$preflight = Join-Path $repoRoot 'src\lead-side\cursor-external-route\Invoke-CursorExternalLeadPreflight.ps1'
$statusScript = Join-Path $repoRoot 'src\lead-side\cursor-external-route\Get-CursorExternalLeadStatus.ps1'
$starter = Join-Path $repoRoot 'src\core\Start-TelephoneLineJob.ps1'
$mockRoute = Join-Path $repoRoot 'tests\core\fixtures\mock-route.ps1'
$mockLead = Join-Path $repoRoot 'tests\core\fixtures\mock-lead-launcher.ps1'
$spyLead = Join-Path $PSScriptRoot 'fixtures\Spy-LeadLauncher.ps1'
$receiver = Join-Path $PSScriptRoot 'fixtures\Receive-CursorExternalLeadArgs.ps1'
$directGrok = Join-Path $repoRoot 'src\adapters\direct-grok-cli\Invoke-DirectGrokRoute.ps1'
$requestedRoot = [string]$TestRoot
$ownedRoot = $null
$junctionPath = $null
$assertions = 0
$cursorExternalBindingDerived = 0
$cursorExternalRequestDirectGrokStart = 0
$cursorExternalStarterExitNow = 0
$cursorExternalExactSessionWake = 0
$cursorExternalBuilderNoStart = 0
$cursorExternalFailClosed = 0
$cursorExternalCreateNew = 0
$cursorExternalCreateNewBinding = 0
$cursorExternalCreateNewRequest = 0
$cursorExternalCreateNewLineJob = 0
$cursorExternalCreateNewDirectGrokJob = 0
$cursorExternalScratchRejected = 0
$cursorExternalArgumentArray = 0
$cursorExternalStatusObservational = 0
$cursorExternalNoProvider = 0
$trackedPids = [Collections.Generic.List[int]]::new()
$script:CxrIntFixturePrefix = 'cxr-lead-'
$script:CxrIntFixtureNamePattern = [regex]'^cxr-lead-[0-9a-fA-F]{32}$'

function Assert-CxrIntTest {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Invoke-CxrIntScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments
    )
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)) {
        [void]$info.ArgumentList.Add([string]$argument)
    }
    foreach ($argument in @($Arguments)) {
        [void]$info.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = [string]$stdoutTask.GetAwaiter().GetResult()
        $stderr = [string]$stderrTask.GetAwaiter().GetResult()
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

function Write-CxrIntText {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $parent = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllBytes($Path, [Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function Write-CxrIntJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
    $json = (($Value | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n")
    Write-CxrIntText -Path $Path -Text $json
}

function New-CxrIntLeadEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][string]$Launcher,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [string]$SecondSessionId = '',
        [switch]$OmitDescriptor,
        [switch]$MalformedDescriptor,
        [switch]$OmitEvents,
        [switch]$EmptyEvents,
        [string]$DescriptorWorktree = ''
    )
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    if (-not $OmitDescriptor) {
        if ($MalformedDescriptor) {
            Write-CxrIntText -Path (Join-Path $Root 'lead-run.json') -Text "{`n"
        } else {
            $wt = if ([string]::IsNullOrWhiteSpace($DescriptorWorktree)) { $Worktree } else { $DescriptorWorktree }
            Write-CxrIntJson -Path (Join-Path $Root 'lead-run.json') -Value ([ordered]@{
                protocol_version = 'lead-run-v1'
                worktree = $wt
                launcher = $Launcher
                session_id = ''
            })
        }
    }
    if (-not $OmitEvents) {
        $nl = [char]10
        if ($EmptyEvents) {
            Write-CxrIntText -Path (Join-Path $Root 'codex-events.jsonl') -Text ("{`"type`":`"turn.started`"}" + $nl)
        } else {
            $lines = '{"type":"thread.started","thread_id":"' + $SessionId + '"}' + $nl + '{"type":"turn.started"}' + $nl
            if (-not [string]::IsNullOrWhiteSpace($SecondSessionId)) {
                $lines += '{"type":"thread.started","thread_id":"' + $SecondSessionId + '"}' + $nl
            } else {
                $lines += '{"type":"thread.started","thread_id":"' + $SessionId + '"}' + $nl
            }
            Write-CxrIntText -Path (Join-Path $Root 'codex-events.jsonl') -Text $lines
        }
    }
}

function Get-CxrIntBuilderArgs {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$InputMap)
    $list = [Collections.Generic.List[string]]::new()
    foreach ($key in @(
            'LeadRunRoot', 'LeadWorktree', 'LeadLauncher', 'SessionId', 'LineJobId', 'ExecutorJobId',
            'TelephoneLineStateRoot', 'DirectGrokStateRoot', 'WorkspacePath', 'PromptFile',
            'BindingOutputPath', 'RequestOutputPath', 'Project', 'Stage', 'Summary', 'Role', 'Route'
        )) {
        if (-not $InputMap.Contains($key)) { continue }
        $value = [string]$InputMap[$key]
        if ([string]::IsNullOrWhiteSpace($value) -and $key -cne 'SessionId') { continue }
        $list.Add('-' + $key)
        $list.Add($value)
    }
    if ($InputMap.Contains('LeadLauncherArguments')) {
        foreach ($item in @($InputMap.LeadLauncherArguments)) {
            $list.Add(('-LeadLauncherArguments:' + [string]$item))
        }
    }
    return $list.ToArray()
}

function Wait-CxrIntPath {
    param([string]$Path, [int]$Seconds = 20)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($Seconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if ([IO.File]::Exists($Path)) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for test path: $Path"
}

function Get-CxrIntJobChildCount {
    param([AllowNull()][string]$StateRoot)
    if ([string]::IsNullOrWhiteSpace($StateRoot)) { return 0 }
    $jobs = Join-Path $StateRoot 'jobs'
    if (-not [IO.Directory]::Exists($jobs)) { return 0 }
    return @([IO.Directory]::GetDirectories($jobs)).Count
}

function Get-CxrIntSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path))).ToLowerInvariant()
}

function Test-CxrIntOwnedFixtureRoot {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $tempAnchor = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.IndexOfAny(@([char]'*', [char]'?', [char]'%')) -ge 0) { return $false }
    if ($full.Contains([string]'$')) { return $false }
    if ($full.Equals($tempAnchor, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $prefix = $tempAnchor + [string][char]92
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $leaf = [IO.Path]::GetFileName($full)
    return $script:CxrIntFixtureNamePattern.IsMatch($leaf)
}

function New-CxrIntOwnedFixtureRoot {
    param([Parameter(Mandatory = $true)][string]$RequestedRoot)
    $tempAnchor = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $requested = [IO.Path]::GetFullPath($RequestedRoot).TrimEnd('\')
    if ($requested.Equals($tempAnchor, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Test root must not be the OS temp path.'
    }
    $prefix = $tempAnchor + [string][char]92
    if (-not $requested.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Test root must be a strict descendant of the OS temp path.'
    }
    if ($requested.IndexOfAny(@([char]'*', [char]'?', [char]'%')) -ge 0 -or $requested.Contains([string]'$')) {
        throw 'Test root must not contain wildcards or unresolved environment tokens.'
    }
    $leaf = $script:CxrIntFixturePrefix + [Guid]::NewGuid().ToString('N')
    $owned = Join-Path $requested $leaf
    [IO.Directory]::CreateDirectory($owned) | Out-Null
    $full = [IO.Path]::GetFullPath($owned).TrimEnd('\')
    if (-not (Test-CxrIntOwnedFixtureRoot -Path $full)) {
        throw 'Owned fixture root failed identity validation.'
    }
    return $full
}

function Remove-CxrIntOwnedFixtureRoot {
    param(
        [AllowNull()][string]$Root,
        [AllowNull()][string]$JunctionPath
    )
    $rootValid = $false
    $rootFull = $null
    if (-not [string]::IsNullOrWhiteSpace($Root) -and (Test-CxrIntOwnedFixtureRoot -Path $Root)) {
        $rootValid = $true
        $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    }
    if ($rootValid -and -not [string]::IsNullOrWhiteSpace($JunctionPath)) {
        $junctionFull = [IO.Path]::GetFullPath($JunctionPath).TrimEnd('\')
        $inside = $junctionFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
            $junctionFull.StartsWith($rootFull + [string][char]92, [StringComparison]::OrdinalIgnoreCase)
        if ($inside -and [IO.Directory]::Exists($junctionFull)) {
            $item = Get-Item -LiteralPath $junctionFull -Force -ErrorAction SilentlyContinue
            if ($null -ne $item -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                [IO.Directory]::Delete($junctionFull)
            }
        }
    }
    if ($rootValid -and [IO.Directory]::Exists($rootFull)) {
        Remove-Item -LiteralPath $rootFull -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-CxrIntPrivacyClean {
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][string]$Label)
    $usersWin = 'C:' + [char]92 + 'Users' + [char]92
    $usersUnix = '/' + 'Users' + '/'
    $dupName = 'hu' + 'hu'
    $projectAlias = 'Con' + 'certo'
    $privateDispatch = $dupName + '-telephone-line-dispatch-v1'
    Assert-CxrIntTest ($Text.Contains($usersWin) -eq $false) "$Label contains a user profile path."
    Assert-CxrIntTest ($Text.Contains($usersUnix) -eq $false) "$Label contains a unix user path."
    Assert-CxrIntTest ([regex]::IsMatch($Text, '(?' + 'i)\b' + $dupName + '\b') -eq $false) "$Label contains a private alias."
    Assert-CxrIntTest ($Text.Contains($projectAlias) -eq $false) "$Label contains a private project name."
    Assert-CxrIntTest ($Text.Contains($privateDispatch) -eq $false) "$Label copies a private dispatch protocol."
}

try {
    $ownedRoot = New-CxrIntOwnedFixtureRoot -RequestedRoot $requestedRoot
    $testRoot = $ownedRoot
    $sessionId = '01c00000-0000-7000-8000-000000000042'
    $lineJobId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0001'
    $executorJobId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0002'
    $leadWorktree = Join-Path $testRoot 'lead-worktree'
    $leadRunRoot = Join-Path $testRoot 'lead-run'
    $scratch = Join-Path $testRoot 'scratch'
    $spaceScratch = Join-Path $testRoot 'scratch dir'
    $promptPath = Join-Path $testRoot 'prompt.txt'
    $spacePrompt = Join-Path $testRoot 'prompt file.txt'
    $telephoneState = Join-Path $testRoot 'telephone-state'
    $grokState = Join-Path $testRoot 'grok-state'
    $outDir = Join-Path $testRoot 'out'
    $bindingPath = Join-Path $outDir 'lead-binding.json'
    $requestPath = Join-Path $outDir 'request.json'
    $spyMarker = Join-Path $testRoot 'spy-marker.txt'
    [IO.Directory]::CreateDirectory($leadWorktree) | Out-Null
    [IO.Directory]::CreateDirectory($scratch) | Out-Null
    [IO.Directory]::CreateDirectory($spaceScratch) | Out-Null
    [IO.Directory]::CreateDirectory($telephoneState) | Out-Null
    [IO.Directory]::CreateDirectory($grokState) | Out-Null
    [IO.Directory]::CreateDirectory($outDir) | Out-Null
    Write-CxrIntText -Path $promptPath -Text "fixture prompt`n"
    Write-CxrIntText -Path $spacePrompt -Text "fixture prompt with spaces`n"
    New-CxrIntLeadEvidence -Root $leadRunRoot -Worktree $leadWorktree -Launcher $spyLead -SessionId $sessionId
    $env:CURSOR_EXTERNAL_SPY_MARKER = $spyMarker

    $baseInput = [ordered]@{
        LeadRunRoot = $leadRunRoot
        LeadWorktree = $leadWorktree
        LeadLauncher = $spyLead
        LineJobId = $lineJobId
        ExecutorJobId = $executorJobId
        TelephoneLineStateRoot = $telephoneState
        DirectGrokStateRoot = $grokState
        WorkspacePath = $scratch
        PromptFile = $promptPath
        BindingOutputPath = $bindingPath
        RequestOutputPath = $requestPath
        Project = 'cursor-external-fixture'
        Stage = 'SIMULATION'
        Summary = 'fixture dispatch'
        Role = 'execution'
        Route = 'direct-grok-cli'
    }

    $preflightOk = Invoke-CxrIntScript -ScriptPath $preflight -Arguments (Get-CxrIntBuilderArgs -InputMap $baseInput)
    Assert-CxrIntTest ($preflightOk.exit_code -eq 0) "Preflight failed on a valid fixture: $($preflightOk.stderr) $($preflightOk.stdout)"
    Assert-CxrIntTest ($preflightOk.json.ready -eq $true -and [bool]$preflightOk.json.started -eq $false) 'Preflight did not stay read-only and ready.'
    Assert-CxrIntTest ([string]$preflightOk.json.session_id -ceq $sessionId) 'Preflight did not derive the original session.'
    Assert-CxrIntTest ((Get-CxrIntJobChildCount -StateRoot $telephoneState) -eq 0) 'Preflight created a Telephone Line job root.'
    Assert-CxrIntTest (-not [IO.File]::Exists($bindingPath) -and -not [IO.File]::Exists($requestPath)) 'Preflight wrote builder outputs.'

    $built = Invoke-CxrIntScript -ScriptPath $builder -Arguments (Get-CxrIntBuilderArgs -InputMap $baseInput)
    Assert-CxrIntTest ($built.exit_code -eq 0) "Builder failed: $($built.stderr) $($built.stdout)"
    Assert-CxrIntTest ($null -ne $built.json) 'Builder did not emit JSON.'
    Assert-CxrIntTest ([bool]$built.json.started -eq $false) 'Builder reported that it started a route.'
    Assert-CxrIntTest ([string]$built.json.session_id -ceq $sessionId) 'Builder did not freeze the derived session.'
    Assert-CxrIntTest ([IO.File]::Exists($bindingPath) -and [IO.File]::Exists($requestPath)) 'Builder did not create binding and request.'
    $bindingRead = Read-TelephoneJson -Path $bindingPath -SchemaName 'lead-binding'
    $requestRead = Read-TelephoneJson -Path $requestPath
    Assert-TelephoneDispatchRequestText -JsonText ([string]$requestRead.text)
    $binding = $bindingRead.value
    $request = $requestRead.value
    Assert-CxrIntTest ([string]$request.protocol_version -ceq 'telephone-line-dispatch-v1') 'Request did not use the public dispatch protocol.'
    Assert-CxrIntTest ([string]$binding.protocol_version -ceq 'telephone-line-lead-binding-v1') 'Binding did not use the public Lead binding protocol.'
    Assert-CxrIntTest ([string]$binding.session_id -ceq $sessionId) 'Frozen binding session differs from the derived id.'
    $resolvedBinding = Read-TelephoneLeadBinding -Lead $request.lead
    Assert-CxrIntTest ([string]$resolvedBinding.session_id -ceq $sessionId) 'Request binding_file did not resolve to the derived session.'
    Assert-CxrIntTest ([IO.Path]::GetFullPath([string]$request.lead.binding_file).Equals([IO.Path]::GetFullPath($bindingPath), [StringComparison]::OrdinalIgnoreCase)) 'Request did not point at the frozen binding file.'
    $script:cursorExternalBindingDerived = 1

    $argumentList = @($request.command.arguments | ForEach-Object { [string]$_ })
    Assert-CursorExternalDirectGrokArguments -Arguments $argumentList -EntryPath $directGrok
    Assert-CxrIntTest ((Get-CursorExternalNamedArgumentValue -Items $argumentList -Name '-Operation') -ceq 'start') 'Request is not Operation start.'
    Assert-CxrIntTest ((Get-CursorExternalNamedArgumentValue -Items $argumentList -Name '-GrokTimeoutSeconds') -ceq '0') 'Grok wait is not zero.'
    Assert-CxrIntTest ((Get-CursorExternalNamedArgumentValue -Items $argumentList -Name '-WaitTimeoutSeconds') -ceq '0') 'Route wait is not zero.'
    Assert-CxrIntTest ((Get-CursorExternalNamedArgumentValue -Items $argumentList -Name '-JobId') -ceq $executorJobId) 'Executor job id was not bound.'
    $wsBound = [IO.Path]::GetFullPath((Get-CursorExternalNamedArgumentValue -Items $argumentList -Name '-WorkspacePath')).TrimEnd('\')
    Assert-CxrIntTest ($wsBound.Equals($scratch, [StringComparison]::OrdinalIgnoreCase)) 'Workspace was not the dedicated scratch.'
    Assert-CxrIntTest ([string]$request.route -ceq 'direct-grok-cli') 'Request route is not the Direct Grok catalog id.'
    $script:cursorExternalRequestDirectGrokStart = 1

    Assert-CxrIntTest (-not [IO.File]::Exists($spyMarker)) 'Builder invoked the Lead launcher.'
    Assert-CxrIntTest ((Get-CxrIntJobChildCount -StateRoot $telephoneState) -eq 0) 'Builder created a Telephone Line job root.'
    Assert-CxrIntTest ((Get-CxrIntJobChildCount -StateRoot $grokState) -eq 0) 'Builder created a Direct Grok job root.'
    $script:cursorExternalBuilderNoStart = 1

    $confirmInput = [ordered]@{}
    foreach ($key in @($baseInput.Keys)) { $confirmInput[$key] = $baseInput[$key] }
    $confirmInput.SessionId = $sessionId
    $confirmInput.BindingOutputPath = Join-Path $outDir 'lead-binding-confirm.json'
    $confirmInput.RequestOutputPath = Join-Path $outDir 'request-confirm.json'
    $confirmInput.LineJobId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0003'
    $confirmInput.ExecutorJobId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0004'
    $confirm = Invoke-CxrIntScript -ScriptPath $builder -Arguments (Get-CxrIntBuilderArgs -InputMap $confirmInput)
    Assert-CxrIntTest ($confirm.exit_code -eq 0 -and [string]$confirm.json.session_id -ceq $sessionId) 'Matching caller session was not accepted as confirmation.'

    $preflightAfter = Invoke-CxrIntScript -ScriptPath $preflight -Arguments (Get-CxrIntBuilderArgs -InputMap $baseInput)
    Assert-CxrIntTest ($preflightAfter.exit_code -ne 0 -and $preflightAfter.json.ready -eq $false) 'Preflight treated existing outputs as ready.'
    Assert-CxrIntTest ([bool]$preflightAfter.json.started -eq $false) 'Preflight started a route.'

    $leadLog = Join-Path $testRoot 'lead-calls.jsonl'
    $leadTurns = Join-Path $testRoot 'lead-turns.jsonl'
    $leadRuns = Join-Path $testRoot 'lead-runs'
    $counter = Join-Path $testRoot 'route-count.txt'
    [IO.Directory]::CreateDirectory($leadRuns) | Out-Null
    $env:TELEPHONE_TEST_LEAD_LOG = $leadLog
    $env:TELEPHONE_TEST_LEAD_RUNS = $leadRuns
    $env:TELEPHONE_TEST_LEAD_TURNS = $leadTurns
    $tripBinding = Join-Path $outDir 'trip-binding.json'
    $tripRequest = Join-Path $outDir 'trip-request.json'
    $tripLine = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0010'
    $tripInput = [ordered]@{}
    foreach ($key in @($baseInput.Keys)) { $tripInput[$key] = $baseInput[$key] }
    $tripInput.LeadLauncher = $mockLead
    $tripInput.BindingOutputPath = $tripBinding
    $tripInput.RequestOutputPath = $tripRequest
    $tripInput.LineJobId = $tripLine
    $tripInput.ExecutorJobId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0011'
    New-CxrIntLeadEvidence -Root (Join-Path $testRoot 'lead-run-trip') -Worktree $leadWorktree -Launcher $mockLead -SessionId $sessionId
    $tripInput.LeadRunRoot = Join-Path $testRoot 'lead-run-trip'
    $tripBuild = Invoke-CxrIntScript -ScriptPath $builder -Arguments (Get-CxrIntBuilderArgs -InputMap $tripInput)
    Assert-CxrIntTest ($tripBuild.exit_code -eq 0) "Trip builder failed: $($tripBuild.stderr)"
    $lifecycleRequestPath = Join-Path $outDir 'lifecycle-request.json'
    $lifecycleRequest = [ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = $tripLine
        project = 'cursor-external-fixture'
        stage = 'SIMULATION'
        role = 'execution'
        route = 'mock-route'
        summary = 'fixture lifecycle'
        lead = [ordered]@{
            binding_file = $tripBinding
        }
        command = [ordered]@{
            executable = $pwsh
            working_directory = $testRoot
            arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $mockRoute, '-CounterPath', $counter, '-DelayMilliseconds', '200', '-FinalText', 'DONE-CXR')
        }
    }
    $null = Write-TelephoneJsonCreateNew -Path $lifecycleRequestPath -Value $lifecycleRequest
    $startText = & $starter -RequestFile $lifecycleRequestPath -StateRoot $telephoneState
    $start = ($startText -join "`n") | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    Assert-CxrIntTest ($start.lead_should_exit_now -eq $true) 'Starter did not tell Lead to exit immediately.'
    Assert-CxrIntTest ($start.absolute_task_timeout -eq $false) 'Starter introduced an absolute task timeout.'
    $trackedPids.Add([int]$start.command_owner.pid)
    $trackedPids.Add([int]$start.relay_owner.pid)
    $script:cursorExternalStarterExitNow = 1
    Wait-CxrIntPath -Path (Join-Path ([string]$start.job_root) 'delivery.json')
    $dispatch = (Read-TelephoneJson -Path (Join-Path ([string]$start.job_root) 'dispatch.json') -SchemaName 'dispatch').value
    $delivery = (Read-TelephoneJson -Path (Join-Path ([string]$start.job_root) 'delivery.json')).value
    Assert-CxrIntTest ([string]$dispatch.lead.session_id -ceq $sessionId) 'Frozen dispatch session is not the derived original session.'
    Assert-CxrIntTest ([string]$delivery.lead_session_id -ceq $sessionId) 'Relay did not wake the derived original session.'
    Assert-CxrIntTest ([string]$delivery.wake_acknowledgment.event -ceq 'turn.started') 'Relay did not acknowledge the exact resumed session.'
    Assert-CxrIntTest ([IO.File]::Exists($leadLog)) 'Mock Lead launcher was not invoked.'
    $script:cursorExternalExactSessionWake = 1

    $failCases = [Collections.Generic.List[object]]::new()
    $missingDescRoot = Join-Path $testRoot 'missing-desc'
    New-CxrIntLeadEvidence -Root $missingDescRoot -Worktree $leadWorktree -Launcher $spyLead -SessionId $sessionId -OmitDescriptor
    $failCases.Add([ordered]@{ name = 'missing-descriptor'; LeadRunRoot = $missingDescRoot })
    $malformedRoot = Join-Path $testRoot 'malformed-desc'
    New-CxrIntLeadEvidence -Root $malformedRoot -Worktree $leadWorktree -Launcher $spyLead -SessionId $sessionId -MalformedDescriptor
    $failCases.Add([ordered]@{ name = 'malformed-descriptor'; LeadRunRoot = $malformedRoot })
    $missingEventsRoot = Join-Path $testRoot 'missing-events'
    New-CxrIntLeadEvidence -Root $missingEventsRoot -Worktree $leadWorktree -Launcher $spyLead -SessionId $sessionId -OmitEvents
    $failCases.Add([ordered]@{ name = 'missing-events'; LeadRunRoot = $missingEventsRoot })
    $noSessionRoot = Join-Path $testRoot 'no-session'
    New-CxrIntLeadEvidence -Root $noSessionRoot -Worktree $leadWorktree -Launcher $spyLead -SessionId $sessionId -EmptyEvents
    $failCases.Add([ordered]@{ name = 'no-session'; LeadRunRoot = $noSessionRoot })
    $twoSessionRoot = Join-Path $testRoot 'two-sessions'
    New-CxrIntLeadEvidence -Root $twoSessionRoot -Worktree $leadWorktree -Launcher $spyLead -SessionId $sessionId -SecondSessionId '01c00000-0000-7000-8000-000000000099'
    $failCases.Add([ordered]@{ name = 'two-sessions'; LeadRunRoot = $twoSessionRoot })
    $mismatchWtRoot = Join-Path $testRoot 'mismatch-wt'
    $otherWt = Join-Path $testRoot 'other-worktree'
    [IO.Directory]::CreateDirectory($otherWt) | Out-Null
    New-CxrIntLeadEvidence -Root $mismatchWtRoot -Worktree $leadWorktree -Launcher $spyLead -SessionId $sessionId -DescriptorWorktree $otherWt
    $failCases.Add([ordered]@{ name = 'worktree-mismatch'; LeadRunRoot = $mismatchWtRoot })
    $failCases.Add([ordered]@{ name = 'caller-session-mismatch'; SessionId = '01c00000-0000-7000-8000-000000000099' })

    $failClosedCount = 0
    foreach ($case in $failCases) {
        $inputMap = [ordered]@{}
        foreach ($key in @($baseInput.Keys)) { $inputMap[$key] = $baseInput[$key] }
        foreach ($key in @($case.Keys)) {
            if ($key -ceq 'name') { continue }
            $inputMap[$key] = $case[$key]
        }
        $inputMap.BindingOutputPath = Join-Path $outDir ("fail-" + [string]$case.name + "-binding.json")
        $inputMap.RequestOutputPath = Join-Path $outDir ("fail-" + [string]$case.name + "-request.json")
        $inputMap.LineJobId = [Guid]::NewGuid().ToString('D')
        $inputMap.ExecutorJobId = [Guid]::NewGuid().ToString('D')
        $failed = Invoke-CxrIntScript -ScriptPath $builder -Arguments (Get-CxrIntBuilderArgs -InputMap $inputMap)
        Assert-CxrIntTest ($failed.exit_code -ne 0) ("Fail-closed case passed: " + [string]$case.name + ' ' + $failed.stdout + ' ' + $failed.stderr)
        Assert-CxrIntTest (-not [IO.File]::Exists([string]$inputMap.BindingOutputPath)) ("Fail-closed case wrote a binding: " + [string]$case.name)
        Assert-CxrIntTest (-not [IO.File]::Exists([string]$inputMap.RequestOutputPath)) ("Fail-closed case wrote a request: " + [string]$case.name)
        $failClosedCount += 1
    }
    Assert-CxrIntTest ($failClosedCount -eq 7) 'Fail-closed matrix did not cover the required cases.'
    $script:cursorExternalFailClosed = $failClosedCount

    $dupInput = [ordered]@{}
    foreach ($key in @($baseInput.Keys)) { $dupInput[$key] = $baseInput[$key] }
    $dupInput.LineJobId = [Guid]::NewGuid().ToString('D')
    $dupInput.ExecutorJobId = [Guid]::NewGuid().ToString('D')
    $dupBinding = Invoke-CxrIntScript -ScriptPath $builder -Arguments (Get-CxrIntBuilderArgs -InputMap $dupInput)
    Assert-CxrIntTest ($dupBinding.exit_code -ne 0) "Existing binding was overwritten: $($dupBinding.stderr)"
    $script:cursorExternalCreateNewBinding = 1

    $requestOnlyBinding = Join-Path $outDir 'create-new-request-binding.json'
    $requestOnlyRequest = Join-Path $outDir 'create-new-request-only.json'
    $requestOnlyBytes = [Text.UTF8Encoding]::new($false).GetBytes("existing-request-bytes-v1`n")
    [IO.File]::WriteAllBytes($requestOnlyRequest, $requestOnlyBytes)
    $requestOnlyHash = Get-CxrIntSha256 -Path $requestOnlyRequest
    $requestOnlyLine = [Guid]::NewGuid().ToString('D')
    $requestOnlyGrok = [Guid]::NewGuid().ToString('D')
    $requestOnlyInput = [ordered]@{}
    foreach ($key in @($baseInput.Keys)) { $requestOnlyInput[$key] = $baseInput[$key] }
    $requestOnlyInput.BindingOutputPath = $requestOnlyBinding
    $requestOnlyInput.RequestOutputPath = $requestOnlyRequest
    $requestOnlyInput.LineJobId = $requestOnlyLine
    $requestOnlyInput.ExecutorJobId = $requestOnlyGrok
    Assert-CxrIntTest (-not [IO.File]::Exists($requestOnlyBinding)) 'Isolated request fixture already had a binding.'
    Assert-CxrIntTest (-not [IO.Directory]::Exists((Join-Path $telephoneState ('jobs\' + $requestOnlyLine)))) 'Isolated request fixture already had a Telephone Line job.'
    Assert-CxrIntTest (-not [IO.Directory]::Exists((Join-Path $grokState ('jobs\' + $requestOnlyGrok)))) 'Isolated request fixture already had a Direct Grok job.'
    $dupRequest = Invoke-CxrIntScript -ScriptPath $builder -Arguments (Get-CxrIntBuilderArgs -InputMap $requestOnlyInput)
    Assert-CxrIntTest ($dupRequest.exit_code -ne 0) "Existing request was overwritten: $($dupRequest.stderr)"
    Assert-CxrIntTest (-not [IO.File]::Exists($requestOnlyBinding)) 'Existing-request case wrote a binding.'
    Assert-CxrIntTest ((Get-CxrIntSha256 -Path $requestOnlyRequest) -ceq $requestOnlyHash) 'Existing request hash changed.'
    $requestOnlyAfter = [IO.File]::ReadAllBytes($requestOnlyRequest)
    $requestBytesMatch = ($requestOnlyAfter.Length -eq $requestOnlyBytes.Length)
    if ($requestBytesMatch) {
        for ($bi = 0; $bi -lt $requestOnlyBytes.Length; $bi++) {
            if ($requestOnlyAfter[$bi] -ne $requestOnlyBytes[$bi]) { $requestBytesMatch = $false; break }
        }
    }
    Assert-CxrIntTest $requestBytesMatch 'Existing request bytes changed.'
    Assert-CxrIntTest (-not [IO.Directory]::Exists((Join-Path $telephoneState ('jobs\' + $requestOnlyLine)))) 'Existing-request case created a Telephone Line job root.'
    Assert-CxrIntTest (-not [IO.Directory]::Exists((Join-Path $grokState ('jobs\' + $requestOnlyGrok)))) 'Existing-request case created a Direct Grok job root.'
    $script:cursorExternalCreateNewRequest = 1

    $newOut = [ordered]@{}
    foreach ($key in @($baseInput.Keys)) { $newOut[$key] = $baseInput[$key] }
    $newOut.BindingOutputPath = Join-Path $outDir 'fresh-binding.json'
    $newOut.RequestOutputPath = Join-Path $outDir 'fresh-request.json'
    $newOut.LineJobId = $tripLine
    $newOut.ExecutorJobId = [Guid]::NewGuid().ToString('D')
    $dupLine = Invoke-CxrIntScript -ScriptPath $builder -Arguments (Get-CxrIntBuilderArgs -InputMap $newOut)
    Assert-CxrIntTest ($dupLine.exit_code -ne 0) 'Existing Telephone Line job was accepted as create-new.'
    $script:cursorExternalCreateNewLineJob = 1
    $grokJobId = [Guid]::NewGuid().ToString('D')
    [IO.Directory]::CreateDirectory((Join-Path $grokState ('jobs\' + $grokJobId))) | Out-Null
    $grokDup = [ordered]@{}
    foreach ($key in @($baseInput.Keys)) { $grokDup[$key] = $baseInput[$key] }
    $grokDup.BindingOutputPath = Join-Path $outDir 'grok-dup-binding.json'
    $grokDup.RequestOutputPath = Join-Path $outDir 'grok-dup-request.json'
    $grokDup.LineJobId = [Guid]::NewGuid().ToString('D')
    $grokDup.ExecutorJobId = $grokJobId
    $dupGrok = Invoke-CxrIntScript -ScriptPath $builder -Arguments (Get-CxrIntBuilderArgs -InputMap $grokDup)
    Assert-CxrIntTest ($dupGrok.exit_code -ne 0) 'Existing Direct Grok job was accepted as create-new.'
    $script:cursorExternalCreateNewDirectGrokJob = 1
    Assert-CxrIntTest ($script:cursorExternalCreateNewBinding -eq 1) 'Existing-binding create-new case was not proven.'
    Assert-CxrIntTest ($script:cursorExternalCreateNewRequest -eq 1) 'Existing-request create-new case was not proven.'
    Assert-CxrIntTest ($script:cursorExternalCreateNewLineJob -eq 1) 'Existing Telephone Line job create-new case was not proven.'
    Assert-CxrIntTest ($script:cursorExternalCreateNewDirectGrokJob -eq 1) 'Existing Direct Grok job create-new case was not proven.'
    $script:cursorExternalCreateNew = 1

    $dirty = Join-Path $testRoot 'dirty-scratch'
    [IO.Directory]::CreateDirectory($dirty) | Out-Null
    Write-CxrIntText -Path (Join-Path $dirty 'stale.txt') -Text 'nope'
    $scratchCases = @(
        @{ name = 'non-empty'; WorkspacePath = $dirty },
        @{ name = 'lead-worktree'; WorkspacePath = $leadWorktree },
        @{ name = 'product-tree'; WorkspacePath = $repoRoot },
        @{ name = 'contains-lead'; WorkspacePath = $testRoot }
    )
    $scratchRejected = 0
    foreach ($case in $scratchCases) {
        $inputMap = [ordered]@{}
        foreach ($key in @($baseInput.Keys)) { $inputMap[$key] = $baseInput[$key] }
        $inputMap.WorkspacePath = [string]$case.WorkspacePath
        $inputMap.BindingOutputPath = Join-Path $outDir ("scratch-" + [string]$case.name + "-binding.json")
        $inputMap.RequestOutputPath = Join-Path $outDir ("scratch-" + [string]$case.name + "-request.json")
        $inputMap.LineJobId = [Guid]::NewGuid().ToString('D')
        $inputMap.ExecutorJobId = [Guid]::NewGuid().ToString('D')
        $failed = Invoke-CxrIntScript -ScriptPath $builder -Arguments (Get-CxrIntBuilderArgs -InputMap $inputMap)
        Assert-CxrIntTest ($failed.exit_code -ne 0) ("Scratch case passed: " + [string]$case.name + ' ' + $failed.stderr)
        $scratchRejected += 1
    }
    $junctionTarget = Join-Path $testRoot 'junction-target'
    $junctionPath = Join-Path $testRoot 'junction-scratch'
    [IO.Directory]::CreateDirectory($junctionTarget) | Out-Null
    $link = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'mklink', '/J', $junctionPath, $junctionTarget) -Wait -PassThru -WindowStyle Hidden
    Assert-CxrIntTest ($link.ExitCode -eq 0 -and [IO.Directory]::Exists($junctionPath)) 'Failed to create a junction fixture.'
    $reparseInput = [ordered]@{}
    foreach ($key in @($baseInput.Keys)) { $reparseInput[$key] = $baseInput[$key] }
    $reparseInput.WorkspacePath = $junctionPath
    $reparseInput.BindingOutputPath = Join-Path $outDir 'reparse-binding.json'
    $reparseInput.RequestOutputPath = Join-Path $outDir 'reparse-request.json'
    $reparseInput.LineJobId = [Guid]::NewGuid().ToString('D')
    $reparseInput.ExecutorJobId = [Guid]::NewGuid().ToString('D')
    $reparseFailed = Invoke-CxrIntScript -ScriptPath $builder -Arguments (Get-CxrIntBuilderArgs -InputMap $reparseInput)
    Assert-CxrIntTest ($reparseFailed.exit_code -ne 0) "Reparse scratch was accepted: $($reparseFailed.stderr)"
    $scratchRejected += 1
    Assert-CxrIntTest ($scratchRejected -ge 5) 'Scratch rejection matrix was incomplete.'
    $script:cursorExternalScratchRejected = $scratchRejected

    $spaceInput = [ordered]@{}
    foreach ($key in @($baseInput.Keys)) { $spaceInput[$key] = $baseInput[$key] }
    $spaceInput.WorkspacePath = $spaceScratch
    $spaceInput.PromptFile = $spacePrompt
    $spaceInput.BindingOutputPath = Join-Path $outDir 'space-binding.json'
    $spaceInput.RequestOutputPath = Join-Path $outDir 'space-request.json'
    $spaceInput.LineJobId = [Guid]::NewGuid().ToString('D')
    $spaceInput.ExecutorJobId = [Guid]::NewGuid().ToString('D')
    $spaceBuild = Invoke-CxrIntScript -ScriptPath $builder -Arguments (Get-CxrIntBuilderArgs -InputMap $spaceInput)
    Assert-CxrIntTest ($spaceBuild.exit_code -eq 0) "Space-path builder failed: $($spaceBuild.stderr)"
    $spaceRequest = (Read-TelephoneJson -Path ([string]$spaceInput.RequestOutputPath)).value
    $spaceArgs = @($spaceRequest.command.arguments | ForEach-Object { [string]$_ })
    for ($i = 0; $i -lt $spaceArgs.Count; $i++) {
        if ($spaceArgs[$i] -ceq '-File' -and ($i + 1) -lt $spaceArgs.Count) {
            $spaceArgs[$i + 1] = $receiver
            break
        }
    }
    $recvInfo = [Diagnostics.ProcessStartInfo]::new()
    $recvInfo.FileName = [string]$spaceRequest.command.executable
    $recvInfo.UseShellExecute = $false
    $recvInfo.RedirectStandardOutput = $true
    $recvInfo.RedirectStandardError = $true
    $recvInfo.CreateNoWindow = $true
    foreach ($argument in $spaceArgs) { [void]$recvInfo.ArgumentList.Add([string]$argument) }
    $recvProcess = [Diagnostics.Process]::Start($recvInfo)
    try {
        $recvOutTask = $recvProcess.StandardOutput.ReadToEndAsync()
        $recvErrTask = $recvProcess.StandardError.ReadToEndAsync()
        $recvProcess.WaitForExit()
        $recvOut = [string]$recvOutTask.GetAwaiter().GetResult()
        $recvErr = [string]$recvErrTask.GetAwaiter().GetResult()
        Assert-CxrIntTest ($recvProcess.ExitCode -eq 0) "Argument receiver failed: $recvErr $recvOut"
        $recvJson = $recvOut | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
        Assert-CxrIntTest ([string]$recvJson.operation -ceq 'start') 'Bound Operation was not start.'
        Assert-CxrIntTest ([IO.Path]::GetFullPath([string]$recvJson.workspace).TrimEnd('\').Equals($spaceScratch, [StringComparison]::OrdinalIgnoreCase)) 'Workspace with spaces did not bind.'
        Assert-CxrIntTest ([IO.Path]::GetFullPath([string]$recvJson.prompt).Equals([IO.Path]::GetFullPath($spacePrompt), [StringComparison]::OrdinalIgnoreCase)) 'Prompt with spaces did not bind.'
        Assert-CxrIntTest ([int]$recvJson.grok_timeout_seconds -eq 0 -and [int]$recvJson.wait_timeout_seconds -eq 0) 'Zero wait values did not bind.'
    } finally {
        $recvProcess.Dispose()
    }
    $fastInput = [ordered]@{}
    foreach ($key in @($baseInput.Keys)) { $fastInput[$key] = $baseInput[$key] }
    $fastInput.BindingOutputPath = Join-Path $outDir 'fast-binding.json'
    $fastInput.RequestOutputPath = Join-Path $outDir 'fast-request.json'
    $fastInput.LineJobId = [Guid]::NewGuid().ToString('D')
    $fastInput.ExecutorJobId = [Guid]::NewGuid().ToString('D')
    $fastInput.LeadLauncherArguments = @('Fast')
    $fastRun = Invoke-CxrIntScript -ScriptPath $builder -Arguments (Get-CxrIntBuilderArgs -InputMap $fastInput)
    Assert-CxrIntTest ($fastRun.exit_code -ne 0) 'Injected Fast token was accepted.'
    Assert-CxrIntTest (-not [IO.File]::Exists([string]$fastInput.BindingOutputPath)) 'Injected Fast token wrote a binding.'
    Assert-CxrIntTest (-not [IO.File]::Exists([string]$fastInput.RequestOutputPath)) 'Injected Fast token wrote a request.'
    Assert-CxrIntTest (Test-CursorExternalForbiddenToken -Text 'service_tier=priority') 'Assignment service_tier=priority was not treated as forbidden.'
    Assert-CxrIntTest (Test-CursorExternalForbiddenToken -Text 'service-tier=priority') 'Assignment service-tier=priority was not treated as forbidden.'
    Assert-CxrIntTest (Test-CursorExternalForbiddenToken -Text '--service-tier=priority') 'Assignment --service-tier=priority was not treated as forbidden.'
    Assert-CxrIntTest (Test-CursorExternalForbiddenToken -Text 'service_tier:priority') 'Colon assignment service_tier:priority was not treated as forbidden.'
    Assert-CxrIntTest (Test-CursorExternalForbiddenToken -Text '--service-tier:priority') 'Colon assignment --service-tier:priority was not treated as forbidden.'
    Assert-CxrIntTest (Test-CursorExternalForbiddenToken -Text 'service_tier=fast') 'Assignment service_tier=fast was not treated as forbidden.'
    Assert-CxrIntTest (Test-CursorExternalForbiddenToken -Text '--service-tier=ultrafast') 'Assignment --service-tier=ultrafast was not treated as forbidden.'
    Assert-CxrIntTest (Test-CursorExternalForbiddenToken -Text '-AllowFast') 'Switch -AllowFast was not treated as forbidden.'
    Assert-CxrIntTest (Test-CursorExternalForbiddenToken -Text '-AllowFast:$true') 'Switch -AllowFast:$true was not treated as forbidden.'
    Assert-CxrIntTest (Test-CursorExternalForbiddenToken -Text 'priority') 'Bare priority was not treated as forbidden.'
    Assert-CxrIntTest (Test-CursorExternalForbiddenToken -Text 'ultrafast') 'Bare ultrafast was not treated as forbidden.'
    Assert-CxrIntTest (-not (Test-CursorExternalForbiddenToken -Text 'fast-label')) 'Innocent fast-label was rejected.'
    Assert-CxrIntTest (-not (Test-CursorExternalForbiddenToken -Text 'priority-queue')) 'Innocent priority-queue was rejected.'
    $innocentPath = Join-Path $testRoot 'ultrafast-notes.txt'
    Assert-CxrIntTest (-not (Test-CursorExternalForbiddenToken -Text $innocentPath)) 'Innocent path containing ordinary words was rejected.'
    $tierCases = @(
        @{ name = 'bare-priority'; args = @('priority') },
        @{ name = 'bare-ultrafast'; args = @('ultrafast') },
        @{ name = 'allow-fast'; args = @('-AllowFast') },
        @{ name = 'allow-fast-colon'; args = @('-AllowFast:$true') },
        @{ name = 'service-tier-eq'; args = @('service_tier=priority') },
        @{ name = 'service-hyphen-eq'; args = @('service-tier=priority') },
        @{ name = 'dashdash-eq'; args = @('--service-tier=priority') },
        @{ name = 'service-colon'; args = @('service_tier:priority') },
        @{ name = 'dashdash-colon'; args = @('--service-tier:priority') },
        @{ name = 'service-eq-fast'; args = @('service_tier=fast') },
        @{ name = 'service-eq-ultrafast'; args = @('--service-tier=ultrafast') }
    )
    foreach ($case in $tierCases) {
        $inputMap = [ordered]@{}
        foreach ($key in @($baseInput.Keys)) { $inputMap[$key] = $baseInput[$key] }
        $inputMap.BindingOutputPath = Join-Path $outDir ('tier-' + [string]$case.name + '-binding.json')
        $inputMap.RequestOutputPath = Join-Path $outDir ('tier-' + [string]$case.name + '-request.json')
        $inputMap.LineJobId = [Guid]::NewGuid().ToString('D')
        $inputMap.ExecutorJobId = [Guid]::NewGuid().ToString('D')
        $inputMap.LeadLauncherArguments = @($case.args)
        $failed = Invoke-CxrIntScript -ScriptPath $builder -Arguments (Get-CxrIntBuilderArgs -InputMap $inputMap)
        Assert-CxrIntTest ($failed.exit_code -ne 0) ("Forbidden launcher token was accepted: " + [string]$case.name + ' ' + $failed.stderr)
        Assert-CxrIntTest (-not [IO.File]::Exists([string]$inputMap.BindingOutputPath)) ("Forbidden token wrote a binding: " + [string]$case.name)
        Assert-CxrIntTest (-not [IO.File]::Exists([string]$inputMap.RequestOutputPath)) ("Forbidden token wrote a request: " + [string]$case.name)
        Assert-CxrIntTest (-not [IO.Directory]::Exists((Join-Path $telephoneState ('jobs\' + [string]$inputMap.LineJobId)))) ("Forbidden token created a Telephone Line job: " + [string]$case.name)
        Assert-CxrIntTest (-not [IO.Directory]::Exists((Join-Path $grokState ('jobs\' + [string]$inputMap.ExecutorJobId)))) ("Forbidden token created a Direct Grok job: " + [string]$case.name)
    }
    $safeInput = [ordered]@{}
    foreach ($key in @($baseInput.Keys)) { $safeInput[$key] = $baseInput[$key] }
    $safeInput.BindingOutputPath = Join-Path $outDir 'safe-args-binding.json'
    $safeInput.RequestOutputPath = Join-Path $outDir 'safe-args-request.json'
    $safeInput.LineJobId = [Guid]::NewGuid().ToString('D')
    $safeInput.ExecutorJobId = [Guid]::NewGuid().ToString('D')
    $safeInput.LeadLauncherArguments = @('fast-label')
    $safeBuild = Invoke-CxrIntScript -ScriptPath $builder -Arguments (Get-CxrIntBuilderArgs -InputMap $safeInput)
    Assert-CxrIntTest ($safeBuild.exit_code -eq 0) "Safe launcher arguments were rejected: $($safeBuild.stderr)"
    $safeBinding = (Read-TelephoneJson -Path ([string]$safeInput.BindingOutputPath) -SchemaName 'lead-binding').value
    $safeArgs = @($safeBinding.launcher.arguments | ForEach-Object { [string]$_ })
    Assert-CxrIntTest ($safeArgs -contains 'fast-label') 'Safe fast-label argument was not preserved.'
    $safeDirect = New-CursorExternalLeadBinding -SessionId $sessionId -Worktree $leadWorktree -LauncherPath $spyLead -LauncherArguments @('fast-label', 'priority-queue', $innocentPath)
    $safeDirectArgs = @($safeDirect.launcher.arguments | ForEach-Object { [string]$_ })
    Assert-CxrIntTest ($safeDirectArgs -contains 'fast-label') 'In-process safe fast-label argument was not preserved.'
    Assert-CxrIntTest ($safeDirectArgs -contains 'priority-queue') 'In-process safe priority-queue argument was not preserved.'
    Assert-CxrIntTest ($safeDirectArgs -contains $innocentPath) 'In-process safe path argument was not preserved.'
    $pairThrew = $false
    try {
        Assert-CursorExternalNoForbiddenTokens -Arguments @('--service-tier', 'priority')
    } catch {
        $pairThrew = $true
    }
    Assert-CxrIntTest $pairThrew 'Adjacent --service-tier priority was accepted.'
    $pairBinding = Join-Path $outDir 'tier-space-priority-binding.json'
    $pairRequest = Join-Path $outDir 'tier-space-priority-request.json'
    $pairLine = [Guid]::NewGuid().ToString('D')
    $pairGrok = [Guid]::NewGuid().ToString('D')
    $pairPreparedThrew = $false
    try {
        $null = Get-CursorExternalPreparedDispatch `
            -LeadRunRoot $leadRunRoot `
            -LeadWorktree $leadWorktree `
            -LeadLauncher $spyLead `
            -LeadLauncherArguments @('--service-tier', 'priority') `
            -LineJobId $pairLine `
            -ExecutorJobId $pairGrok `
            -TelephoneLineStateRoot $telephoneState `
            -DirectGrokStateRoot $grokState `
            -WorkspacePath $scratch `
            -PromptFile $promptPath `
            -BindingOutputPath $pairBinding `
            -RequestOutputPath $pairRequest `
            -Project 'cursor-external-fixture' `
            -Stage 'SIMULATION' `
            -Summary 'fixture dispatch'
    } catch {
        $pairPreparedThrew = $true
    }
    Assert-CxrIntTest $pairPreparedThrew 'Prepared dispatch accepted adjacent --service-tier priority.'
    Assert-CxrIntTest (-not [IO.File]::Exists($pairBinding)) 'Adjacent service-tier pair wrote a binding.'
    Assert-CxrIntTest (-not [IO.File]::Exists($pairRequest)) 'Adjacent service-tier pair wrote a request.'
    Assert-CxrIntTest (-not [IO.Directory]::Exists((Join-Path $telephoneState ('jobs\' + $pairLine)))) 'Adjacent service-tier pair created a Telephone Line job.'
    Assert-CxrIntTest (-not [IO.Directory]::Exists((Join-Path $grokState ('jobs\' + $pairGrok)))) 'Adjacent service-tier pair created a Direct Grok job.'
    $secondRoute = [ordered]@{}
    foreach ($key in @($baseInput.Keys)) { $secondRoute[$key] = $baseInput[$key] }
    $secondRoute.BindingOutputPath = Join-Path $outDir 'second-route-binding.json'
    $secondRoute.RequestOutputPath = Join-Path $outDir 'second-route-request.json'
    $secondRoute.LineJobId = [Guid]::NewGuid().ToString('D')
    $secondRoute.ExecutorJobId = [Guid]::NewGuid().ToString('D')
    $secondRoute.Route = 'direct-cursor'
    $secondRun = Invoke-CxrIntScript -ScriptPath $builder -Arguments (Get-CxrIntBuilderArgs -InputMap $secondRoute)
    Assert-CxrIntTest ($secondRun.exit_code -ne 0) 'A second route id was accepted.'
    $fileInject = [ordered]@{}
    foreach ($key in @($baseInput.Keys)) { $fileInject[$key] = $baseInput[$key] }
    $fileInject.BindingOutputPath = Join-Path $outDir 'file-inject-binding.json'
    $fileInject.RequestOutputPath = Join-Path $outDir 'file-inject-request.json'
    $fileInject.LineJobId = [Guid]::NewGuid().ToString('D')
    $fileInject.ExecutorJobId = [Guid]::NewGuid().ToString('D')
    $fileInject.LeadLauncherArguments = @('-File')
    $fileRun = Invoke-CxrIntScript -ScriptPath $builder -Arguments (Get-CxrIntBuilderArgs -InputMap $fileInject)
    Assert-CxrIntTest ($fileRun.exit_code -ne 0) 'Injected second -File route was accepted.'
    $builderText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\lead-side\cursor-external-route\CursorExternalLead.Common.ps1'))
    Assert-CxrIntTest ($builderText.Contains('ArgumentList') -eq $false -or $builderText.Contains('[Collections.Generic.List[string]]')) 'Builder helpers no longer keep an argument list.'
    Assert-CxrIntTest ($builderText.Contains('cmd.exe /c') -eq $false -and $builderText.Contains('Invoke-Expression') -eq $false) 'Builder interpolates a command string.'
    $suiteText = [IO.File]::ReadAllText($PSCommandPath)
    $rd = 'rm' + 'dir /s'
    Assert-CxrIntTest ($suiteText.Contains($rd) -eq $false) 'Suite still uses recursive rmdir cleanup.'
    $script:cursorExternalArgumentArray = 1

    $statusRoot = Join-Path $testRoot 'status-src'
    $statusJobs = Join-Path $statusRoot 'tl-jobs'
    $sealedId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0201'
    $sealedDir = Join-Path $statusJobs $sealedId
    [IO.Directory]::CreateDirectory($sealedDir) | Out-Null
    Write-CxrIntJson -Path (Join-Path $sealedDir 'dispatch.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = $sealedId
        summary = 'status fixture'
        lead = [ordered]@{ session_id = $sessionId; worktree = $leadWorktree }
    })
    Write-CxrIntJson -Path (Join-Path $sealedDir 'receipt.json') -Value ([ordered]@{ protocol_version = 'telephone-line-receipt-v1'; line_job_id = $sealedId })
    $sourcesPath = Join-Path $testRoot 'status-sources.json'
    Write-CxrIntJson -Path $sourcesPath -Value ([ordered]@{
        protocol_version = 'telephone-line-cursor-external-status-sources-v1'
        sources = @(
            [ordered]@{ id = 'telephone-line'; kind = 'telephone-line-jobs'; root = $statusJobs }
        )
    })
    $beforeHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes((Join-Path $sealedDir 'receipt.json')))).ToLowerInvariant()
    $statusBeforeFiles = @([IO.Directory]::GetFileSystemEntries($statusJobs, '*', [IO.SearchOption]::AllDirectories))
    $statusRun = Invoke-CxrIntScript -ScriptPath $statusScript -Arguments @('-SourcesPath', $sourcesPath)
    Assert-CxrIntTest ($statusRun.exit_code -eq 0) "Status failed: $($statusRun.stderr)"
    Assert-CxrIntTest ([bool]$statusRun.json.started -eq $false -and [bool]$statusRun.json.mutated -eq $false) 'Status claimed to start or mutate a route.'
    Assert-CxrIntTest ([string]$statusRun.json.items[0].stage -ceq 'receipt_sealed') 'Status did not report the durable receipt stage.'
    $afterHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes((Join-Path $sealedDir 'receipt.json')))).ToLowerInvariant()
    $statusAfterFiles = @([IO.Directory]::GetFileSystemEntries($statusJobs, '*', [IO.SearchOption]::AllDirectories))
    Assert-CxrIntTest ($beforeHash -ceq $afterHash) 'Status mutated a durable receipt.'
    Assert-CxrIntTest ($statusBeforeFiles.Count -eq $statusAfterFiles.Count) 'Status created or deleted job files.'
    $emptyRoot = Join-Path $testRoot 'empty-jobs'
    [IO.Directory]::CreateDirectory($emptyRoot) | Out-Null
    $failSources = Join-Path $testRoot 'status-fail-closed.json'
    Write-CxrIntJson -Path $failSources -Value ([ordered]@{
        protocol_version = 'telephone-line-cursor-external-status-sources-v1'
        sources = @(
            [ordered]@{ id = 'declared-running'; kind = 'direct-grok-jobs'; root = $emptyRoot; declared_running = $true; declared_running_ids = @('running-missing') }
        )
    })
    $failStatus = Invoke-CxrIntScript -ScriptPath $statusScript -Arguments @('-SourcesPath', $failSources)
    Assert-CxrIntTest ($failStatus.exit_code -ne 0 -and [string]$failStatus.json.overall_status -ceq 'fail_closed') 'Status did not fail closed on a declared running miss.'

    $missingDeclaredId = 'missing-declared-id'
    $missingSources = Join-Path $testRoot 'status-missing-declared.json'
    Write-CxrIntJson -Path $missingSources -Value ([ordered]@{
        protocol_version = 'telephone-line-cursor-external-status-sources-v1'
        sources = @(
            [ordered]@{
                id = 'telephone-line'
                kind = 'telephone-line-jobs'
                root = $statusJobs
                declared_running_ids = @($missingDeclaredId)
            }
        )
    })
    $missingBeforeHash = Get-CxrIntSha256 -Path (Join-Path $sealedDir 'receipt.json')
    $missingSourcesHash = Get-CxrIntSha256 -Path $missingSources
    $missingBeforeEntries = @([IO.Directory]::GetFileSystemEntries($statusJobs, '*', [IO.SearchOption]::AllDirectories) | Sort-Object)
    $missingStatus = Invoke-CxrIntScript -ScriptPath $statusScript -Arguments @('-SourcesPath', $missingSources)
    Assert-CxrIntTest ($missingStatus.exit_code -ne 0 -and [string]$missingStatus.json.overall_status -ceq 'fail_closed') 'Unrelated sealed job masked a missing declared id.'
    $missingItems = @()
    if ($null -ne $missingStatus.json -and $null -ne $missingStatus.json.items) {
        $missingItems = @($missingStatus.json.items)
    }
    $invented = $false
    foreach ($item in $missingItems) {
        if ([string]$item.item_id -ceq $missingDeclaredId) { $invented = $true }
    }
    Assert-CxrIntTest (-not $invented) 'Status invented a job for a missing declared id.'
    Assert-CxrIntTest ((Get-CxrIntSha256 -Path (Join-Path $sealedDir 'receipt.json')) -ceq $missingBeforeHash) 'Missing-declared status mutated a durable receipt.'
    Assert-CxrIntTest ((Get-CxrIntSha256 -Path $missingSources) -ceq $missingSourcesHash) 'Missing-declared status mutated its sources file.'
    $missingAfterEntries = @([IO.Directory]::GetFileSystemEntries($statusJobs, '*', [IO.SearchOption]::AllDirectories) | Sort-Object)
    Assert-CxrIntTest ($missingBeforeEntries.Count -eq $missingAfterEntries.Count) 'Missing-declared status created or deleted job files.'

    $ownerJobs = Join-Path $testRoot 'status-owners'
    $ownerId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeee0401'
    $ownerDir = Join-Path $ownerJobs $ownerId
    [IO.Directory]::CreateDirectory($ownerDir) | Out-Null
    Write-CxrIntJson -Path (Join-Path $ownerDir 'dispatch.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = $ownerId
        summary = 'owner fixture'
        lead = [ordered]@{ session_id = $sessionId; worktree = $leadWorktree }
    })
    Write-CxrIntJson -Path (Join-Path $ownerDir 'command-owner.json') -Value ([ordered]@{
        pid = 2147483647
        start_time_utc_ticks = 1
        started_at_utc = '2000-01-01T00:00:00.0000000+00:00'
    })
    $current = Get-Process -Id $PID
    try {
        $liveRelayOwner = [ordered]@{
            pid = [int]$PID
            start_time_utc_ticks = [int64]$current.StartTime.ToUniversalTime().Ticks
            started_at_utc = $current.StartTime.ToUniversalTime().ToString('o')
        }
    } finally {
        $current.Dispose()
    }
    Write-CxrIntJson -Path (Join-Path $ownerDir 'relay-owner.json') -Value $liveRelayOwner
    $ownerSources = Join-Path $testRoot 'status-live-relay.json'
    Write-CxrIntJson -Path $ownerSources -Value ([ordered]@{
        protocol_version = 'telephone-line-cursor-external-status-sources-v1'
        sources = @(
            [ordered]@{ id = 'telephone-line-owners'; kind = 'telephone-line-jobs'; root = $ownerJobs }
        )
    })
    $ownerBeforeFiles = @([IO.Directory]::GetFiles($ownerDir) | Sort-Object)
    $ownerBeforeHashes = @($ownerBeforeFiles | ForEach-Object { Get-CxrIntSha256 -Path $_ })
    $ownerSourcesHash = Get-CxrIntSha256 -Path $ownerSources
    $ownerBeforeEntries = @([IO.Directory]::GetFileSystemEntries($ownerJobs, '*', [IO.SearchOption]::AllDirectories) | Sort-Object)
    $ownerStatus = Invoke-CxrIntScript -ScriptPath $statusScript -Arguments @('-SourcesPath', $ownerSources)
    Assert-CxrIntTest ($ownerStatus.exit_code -eq 0) "Live-relay status failed: $($ownerStatus.stderr)"
    Assert-CxrIntTest ([bool]$ownerStatus.json.started -eq $false -and [bool]$ownerStatus.json.mutated -eq $false) 'Live-relay status claimed to start or mutate a route.'
    Assert-CxrIntTest ([string]$ownerStatus.json.items[0].item_id -ceq $ownerId) 'Live-relay status did not project the fixture job.'
    Assert-CxrIntTest ([string]$ownerStatus.json.items[0].stage -ceq 'running') 'Dead command owner masked a live relay owner.'
    $ownerAfterFiles = @([IO.Directory]::GetFiles($ownerDir) | Sort-Object)
    Assert-CxrIntTest ($ownerBeforeFiles.Count -eq $ownerAfterFiles.Count) 'Live-relay status changed the owner entry set.'
    for ($oi = 0; $oi -lt $ownerBeforeFiles.Count; $oi++) {
        Assert-CxrIntTest ([string]$ownerBeforeFiles[$oi] -ceq [string]$ownerAfterFiles[$oi]) 'Live-relay status renamed an owner source file.'
        Assert-CxrIntTest ((Get-CxrIntSha256 -Path $ownerAfterFiles[$oi]) -ceq $ownerBeforeHashes[$oi]) 'Live-relay status mutated an owner source file.'
    }
    Assert-CxrIntTest ((Get-CxrIntSha256 -Path $ownerSources) -ceq $ownerSourcesHash) 'Live-relay status mutated its sources file.'
    $ownerAfterEntries = @([IO.Directory]::GetFileSystemEntries($ownerJobs, '*', [IO.SearchOption]::AllDirectories) | Sort-Object)
    Assert-CxrIntTest ($ownerBeforeEntries.Count -eq $ownerAfterEntries.Count) 'Live-relay status created or deleted job files.'
    Assert-CxrIntTest (-not [IO.File]::Exists($spyMarker)) 'Status invoked the Lead launcher.'
    $script:cursorExternalStatusObservational = 1

    $scanRoots = @(
        (Join-Path $repoRoot 'src\lead-side\cursor-external-route'),
        (Join-Path $repoRoot 'docs\cursor-external-lead.md')
    )
    $exeName = 'grok' + '.exe'
    $agentName = 'cursor' + '-agent'
    $cliName = 'codex' + '.exe'
    $authRel = '.grok' + [char]92 + 'auth.json'
    foreach ($root in $scanRoots) {
        Assert-CxrIntTest ([IO.File]::Exists($root) -or [IO.Directory]::Exists($root)) "Tracked scan root missing: $root"
        $files = if ([IO.File]::Exists($root)) { @($root) } else { @([IO.Directory]::GetFiles($root, '*', [IO.SearchOption]::AllDirectories)) }
        foreach ($file in $files) {
            $text = [IO.File]::ReadAllText($file)
            Test-CxrIntPrivacyClean -Text $text -Label $file
            foreach ($name in @($exeName, $agentName, $cliName, $authRel)) {
                Assert-CxrIntTest ($text.Contains($name) -eq $false) "$file references a real provider path $name"
            }
        }
    }
    Assert-CxrIntTest ((Get-CxrIntJobChildCount -StateRoot $grokState) -eq 1) 'Test created extra Direct Grok jobs outside the duplicate fixture.'
    $script:cursorExternalNoProvider = 1

    [ordered]@{
        success = $true
        cursor_external_binding_derived = $cursorExternalBindingDerived
        cursor_external_request_direct_grok_start = $cursorExternalRequestDirectGrokStart
        cursor_external_starter_exit_now = $cursorExternalStarterExitNow
        cursor_external_exact_session_wake = $cursorExternalExactSessionWake
        cursor_external_builder_no_start = $cursorExternalBuilderNoStart
        cursor_external_fail_closed = $cursorExternalFailClosed
        cursor_external_create_new = $cursorExternalCreateNew
        cursor_external_create_new_binding = $cursorExternalCreateNewBinding
        cursor_external_create_new_request = $cursorExternalCreateNewRequest
        cursor_external_create_new_line_job = $cursorExternalCreateNewLineJob
        cursor_external_create_new_direct_grok_job = $cursorExternalCreateNewDirectGrokJob
        cursor_external_scratch_rejected = $cursorExternalScratchRejected
        cursor_external_argument_array = $cursorExternalArgumentArray
        cursor_external_status_observational = $cursorExternalStatusObservational
        cursor_external_no_provider = $cursorExternalNoProvider
        assertions = $assertions
    } | ConvertTo-Json -Compress
} catch {
    [ordered]@{
        success = $false
        error = [string]$_.Exception.Message
        assertions = $assertions
        cursor_external_binding_derived = $cursorExternalBindingDerived
        cursor_external_request_direct_grok_start = $cursorExternalRequestDirectGrokStart
        cursor_external_starter_exit_now = $cursorExternalStarterExitNow
        cursor_external_exact_session_wake = $cursorExternalExactSessionWake
        cursor_external_builder_no_start = $cursorExternalBuilderNoStart
        cursor_external_fail_closed = $cursorExternalFailClosed
        cursor_external_create_new = $cursorExternalCreateNew
        cursor_external_create_new_binding = $cursorExternalCreateNewBinding
        cursor_external_create_new_request = $cursorExternalCreateNewRequest
        cursor_external_create_new_line_job = $cursorExternalCreateNewLineJob
        cursor_external_create_new_direct_grok_job = $cursorExternalCreateNewDirectGrokJob
        cursor_external_scratch_rejected = $cursorExternalScratchRejected
        cursor_external_argument_array = $cursorExternalArgumentArray
        cursor_external_status_observational = $cursorExternalStatusObservational
        cursor_external_no_provider = $cursorExternalNoProvider
    } | ConvertTo-Json -Compress
    exit 1
} finally {
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY', $script:PreviousDashboardProcessEnvOnly, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', $script:PreviousDashboardOptOut, 'Process')
    [Environment]::SetEnvironmentVariable('CURSOR_EXTERNAL_SPY_MARKER', $null, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_LEAD_LOG', $null, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_LEAD_RUNS', $null, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_LEAD_TURNS', $null, 'Process')
    foreach ($pidValue in @($trackedPids)) {
        try {
            $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
            if ($null -ne $proc) { $proc.Dispose() }
        } catch { }
    }
    Remove-CxrIntOwnedFixtureRoot -Root $ownedRoot -JunctionPath $junctionPath
}

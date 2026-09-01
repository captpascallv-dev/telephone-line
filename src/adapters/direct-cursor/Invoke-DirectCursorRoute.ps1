# SPDX-License-Identifier: MPL-2.0
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)][ValidateSet('start', 'follow_up', 'recover')][string]$Operation,
    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Preflight')]
    [string]$NativeSessionId,
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)]
    [Parameter(ParameterSetName = 'Preflight', Mandatory = $true)]
    [string]$StateRoot,
    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Preflight', Mandatory = $true)]
    [string]$WorkspacePath,
    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Preflight', Mandatory = $true)]
    [string]$PromptFile,
    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Preflight')]
    [ValidateSet('ReadOnly', 'Verify', 'Write')][string]$Mode = 'ReadOnly',
    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Preflight')]
    [string[]]$AllowedWritePath,
    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Preflight', Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$JobId,
    [ValidateRange(0, 2147483647)][int]$CursorTimeoutSeconds = 0,
    [ValidateRange(0, 2147483647)][int]$WaitTimeoutSeconds = 0,
    [ValidateRange(65536, 67108864)][int]$MaxOutputBytes = 16777216,
    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Preflight')]
    [string]$CursorAgentRoot,
    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Preflight')]
    [string]$ExpectedAccount = '',
    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Preflight')]
    [string]$ExpectedSubscription = '',
    [Parameter(ParameterSetName = 'Preflight', Mandatory = $true)]
    [switch]$Preflight
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }
. (Join-Path $PSScriptRoot 'DirectCursor.Common.ps1')

function Get-JobPaths {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Id)
    $jobRoot = Join-Path $Root ('jobs\' + $Id)
    return [ordered]@{
        root = $jobRoot
        request = Join-Path $jobRoot 'request.json'
        config = Join-Path $jobRoot 'host-config.json'
        intent = Join-Path $jobRoot 'launch-intent.json'
        owner = Join-Path $jobRoot 'owner.json'
        stdout = Join-Path $jobRoot 'cursor-result.json'
        stderr = Join-Path $jobRoot 'cursor-stderr.txt'
        receipt = Join-Path $jobRoot 'receipt.json'
    }
}

function Get-SessionPaths {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$SessionId)
    $sessionRoot = Join-Path $Root ('sessions\' + $SessionId)
    return [ordered]@{
        root = $sessionRoot
        binding = Join-Path $sessionRoot 'binding.json'
    }
}

function Get-DirectCursorResultSessionId {
    param($Result)
    if ($null -eq $Result) { return '' }
    if ($Result -is [Collections.IDictionary]) {
        if ($Result.Contains('session_id') -and $null -ne $Result['session_id']) {
            return [string]$Result['session_id']
        }
        return ''
    }
    $prop = $Result.PSObject.Properties['session_id']
    if ($null -eq $prop -or $null -eq $prop.Value) { return '' }
    return [string]$prop.Value
}

function Start-DirectHost {
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$HostScript,
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )

    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $PowerShellPath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $HostScript, '-ConfigPath', $ConfigPath)) {
        [void]$info.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($info)
    if ($null -eq $process) { throw 'Direct Cursor host did not start.' }
    return $process
}

function Find-DirectHostOwner {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    $needle = [IO.Path]::GetFullPath($ConfigPath)
    $matches = @(
        Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            [string]$_.Name -ieq 'pwsh.exe' -and
            -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
            [string]$_.CommandLine -like ('*' + $needle + '*') -and
            [string]$_.CommandLine -like '*process_file_host.ps1*'
        }
    )
    if ($matches.Count -gt 1) { throw 'More than one Direct Cursor host matches this exact job.' }
    if ($matches.Count -eq 0) { return $null }
    $process = Get-Process -Id ([int]$matches[0].ProcessId) -ErrorAction Stop
    try {
        return [ordered]@{
            protocol_version = 'telephone-line-direct-cursor-owner-v1'
            pid = [int]$process.Id
            start_time_utc_ticks = [int64]$process.StartTime.ToUniversalTime().Ticks
            started_at_utc = $process.StartTime.ToUniversalTime().ToString('o')
        }
    } finally {
        $process.Dispose()
    }
}

function New-DirectReceipt {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$RequestRead,
        [Collections.IDictionary]$Owner
    )

    $request = $RequestRead.value
    $stdoutText = if ([IO.File]::Exists($Paths.stdout)) {
        [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($Paths.stdout)).TrimStart([char]0xFEFF)
    } else { '' }
    $cursorResult = $null
    $transportError = $null
    try {
        if ([string]::IsNullOrWhiteSpace($stdoutText)) { throw 'Cursor result is missing.' }
        $cursorResult = $stdoutText | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
        if ($cursorResult -isnot [Collections.IDictionary] -or $cursorResult.success -isnot [bool]) { throw 'Cursor result is not a terminal result object.' }
        if ([string]$cursorResult.prompt_sha256 -cne [string]$request.prompt.sha256) { throw 'Cursor result prompt binding differs.' }
        if (-not [IO.Path]::GetFullPath([string]$cursorResult.workspace).Equals([IO.Path]::GetFullPath([string]$request.workspace), [StringComparison]::OrdinalIgnoreCase)) { throw 'Cursor result workspace differs.' }
        if ([string]$cursorResult.mode -cne [string]$request.mode -or [string]$cursorResult.model_id -cne [string]$request.model) { throw 'Cursor result mode or model differs.' }
        if ($cursorResult.fast_disabled -ne $true) { throw 'Cursor result did not keep Fast disabled.' }
        $actualAllowed = [string[]]@($cursorResult.allowed_write_paths | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        $expectedAllowed = [string[]]@($request.allowed_write_paths | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        if (($actualAllowed -join "`n") -cne ($expectedAllowed -join "`n")) { throw 'Cursor result write scope differs.' }
        if ($cursorResult.Contains('error') -and -not [string]::IsNullOrWhiteSpace([string]$cursorResult.error)) {
            $cursorResult.error = Get-DirectPublicError -Message ([string]$cursorResult.error)
        }
        $isPolicy = $cursorResult.Contains('failure_kind') -and [string]$cursorResult.failure_kind -ceq 'policy'
        if ([bool]$cursorResult.success -ne $true -and -not $isPolicy) {
            $transportError = Get-DirectPublicError -Message ([string]$cursorResult.error)
        }
    } catch {
        $transportError = Get-DirectPublicError -Message $_.Exception.Message
        $cursorResult = $null
    }

    $transportComplete = $null -eq $transportError -and $null -ne $cursorResult
    $receipt = [ordered]@{
        protocol_version = 'telephone-line-direct-cursor-receipt-v1'
        job_id = [string]$request.job_id
        request = $RequestRead.identity
        transport_complete = [bool]$transportComplete
        transport_error = $transportError
        cursor_success = if ($null -ne $cursorResult) { [bool]$cursorResult.success } else { $null }
        native_session_id = Get-DirectCursorResultSessionId -Result $cursorResult
        cursor_result = $cursorResult
        stdout = if ([IO.File]::Exists($Paths.stdout)) { Get-DirectFileIdentity -Path $Paths.stdout } else { $null }
        stderr = if ([IO.File]::Exists($Paths.stderr)) { Get-DirectFileIdentity -Path $Paths.stderr } else { $null }
        owner = $Owner
        automatic_rerun = $false
        replacement_started = $false
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try { return Write-DirectJsonCreateNew -Path $Paths.receipt -Value $receipt }
    catch [IO.IOException] { return Get-DirectFileIdentity -Path $Paths.receipt }
}

function Wait-DirectJob {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][bool]$AllowStart
    )

    $requestRead = Read-DirectJson -Path $Paths.request
    $deadline = if ($TimeoutSeconds -gt 0) { [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds) } else { $null }
    while ($true) {
        if ([IO.File]::Exists($Paths.receipt)) {
            $receiptRead = Read-DirectJson -Path $Paths.receipt
            if ([string]$receiptRead.value.job_id -cne [string]$requestRead.value.job_id) { throw 'Direct Cursor receipt belongs to another job.' }
            Assert-DirectIdentity -Expected $requestRead.identity -Actual $receiptRead.value.request -Label 'Direct Cursor receipt request'
            return $receiptRead
        }

        $owner = $null
        if ([IO.File]::Exists($Paths.owner)) { $owner = (Read-DirectJson -Path $Paths.owner).value }
        elseif ($AllowStart -and [IO.File]::Exists($Paths.config)) {
            $owner = Find-DirectHostOwner -ConfigPath $Paths.config
            if ($null -ne $owner) { try { $null = Write-DirectJsonCreateNew -Path $Paths.owner -Value $owner } catch [IO.IOException] { } }
        }

        if ($null -ne $owner -and (Test-DirectOwnerAlive -Owner $owner)) {
            if ($null -ne $deadline -and [DateTimeOffset]::UtcNow -ge $deadline) {
                return [ordered]@{ value = [ordered]@{ protocol_version = 'telephone-line-direct-cursor-status-v1'; job_id = [string]$requestRead.value.job_id; state = 'running'; owner = $owner; automatic_rerun = $false; replacement_started = $false }; identity = $null }
            }
            Start-Sleep -Milliseconds 500
            continue
        }

        Start-Sleep -Milliseconds 200
        $null = New-DirectReceipt -Paths $Paths -RequestRead $requestRead -Owner $owner
        return Read-DirectJson -Path $Paths.receipt
    }
}

function Write-AdapterResult {
    param(
        [Parameter(Mandatory = $true)][string]$Op,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SessionId,
        [Parameter(Mandatory = $true)][object]$Terminal
    )
    $value = $Terminal.value
    $cursorResult = Get-DirectNoteValue -Object $value -Name 'cursor_result'
    $transportComplete = Get-DirectNoteValue -Object $value -Name 'transport_complete'
    $cursorSuccess = Get-DirectNoteValue -Object $value -Name 'cursor_success'
    $result = [ordered]@{
        protocol_version = 'telephone-line-adapter-result-v1'
        route_id = 'direct-cursor'
        operation = $Op
        native_session_id = $SessionId
        job_id = [string]$value.job_id
        automatic_rerun = $false
        replacement_started = $false
        transport_complete = if ($null -ne $transportComplete) { [bool]$transportComplete } else { $false }
        cursor_success = if ($null -ne $cursorSuccess) { $cursorSuccess } else { $null }
        fast_disabled = $true
        receipt = $Terminal.identity
    }
    $transportError = Get-DirectNoteValue -Object $value -Name 'transport_error'
    if ($null -ne $transportError -and -not [string]::IsNullOrWhiteSpace([string]$transportError)) {
        $result.transport_error = [string]$transportError
    }
    if ($null -ne $cursorResult) {
        $result.mode = [string](Get-DirectNoteValue -Object $cursorResult -Name 'mode')
        $result.allowed_write_paths = @((Get-DirectNoteValue -Object $cursorResult -Name 'allowed_write_paths'))
        $prompt = Get-DirectNoteValue -Object $cursorResult -Name 'prompt'
        if ($null -ne $prompt) { $result.prompt = $prompt }
        $promptSha256 = [string](Get-DirectNoteValue -Object $cursorResult -Name 'prompt_sha256')
        if (-not [string]::IsNullOrWhiteSpace($promptSha256)) { $result.prompt_sha256 = $promptSha256 }
        foreach ($field in @('failure_kind', 'failure_code', 'failure_stage')) {
            $fieldValue = Get-DirectNoteValue -Object $cursorResult -Name $field
            if ($null -ne $fieldValue -and -not [string]::IsNullOrWhiteSpace([string]$fieldValue)) { $result[$field] = [string]$fieldValue }
        }
        if (-not $result.Contains('failure_kind') -and $result.transport_complete -ne $true) { $result.failure_kind = 'transport' }
        if (-not $result.Contains('failure_code') -and $result.transport_complete -ne $true) { $result.failure_code = 'adapter_transport_failure' }
        if (-not $result.Contains('failure_stage') -and $result.transport_complete -ne $true) { $result.failure_stage = 'cursor_execution' }
    }
    $result | ConvertTo-Json -Depth 16
}

$adapterRoot = Get-DirectCanonicalDirectory -Path $PSScriptRoot
$resolvedStateRoot = Get-DirectCanonicalDirectory -Path $StateRoot

if ($PSCmdlet.ParameterSetName -ceq 'Preflight') {
    try {
        $powerShellPath = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $wrapperPath = Join-Path $adapterRoot 'invoke_cursor_agent.ps1'
        $probeTimeout = if ($CursorTimeoutSeconds -gt 0) { $CursorTimeoutSeconds } else { 90 }
        $probeArgs = @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $wrapperPath,
            '-QualifiedProbe',
            '-WorkspacePath', $WorkspacePath,
            '-Mode', $Mode,
            '-Model', 'cursor-grok-4.6-xhigh',
            '-TimeoutSeconds', [string]$probeTimeout
        )
        $sessionStore = Join-Path $resolvedStateRoot 'cursor-sessions'
        $probeArgs += @('-SessionRoot', $sessionStore)
        if (-not [string]::IsNullOrWhiteSpace($CursorAgentRoot)) { $probeArgs += @('-CursorAgentRoot', $CursorAgentRoot) }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedAccount)) { $probeArgs += @('-ExpectedAccount', $ExpectedAccount) }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSubscription)) { $probeArgs += @('-ExpectedSubscription', $ExpectedSubscription) }
        $probeLines = & $powerShellPath @probeArgs
        $probeExit = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
        $probeText = (($probeLines | ForEach-Object { [string]$_ }) -join "`n").Trim()
        if ($probeExit -ne 0) { throw 'Qualified probe did not complete.' }
        $probeEvidence = ConvertFrom-DirectCursorQualifiedProbe -Text $probeText
        $preflightParams = @{
            AdapterRoot = $adapterRoot
            StateRoot = $resolvedStateRoot
            JobId = $JobId
            WorkspacePath = $WorkspacePath
            PromptFile = $PromptFile
            Mode = $Mode
            ResumeSessionId = $NativeSessionId
            ExpectedAccount = $ExpectedAccount
            ExpectedSubscription = $ExpectedSubscription
            ProbeEvidence = $probeEvidence
        }
        if ($null -ne $AllowedWritePath) { $preflightParams.AllowedWritePath = $AllowedWritePath }
        $report = Invoke-DirectCursorLaunchPreflight @preflightParams
    } catch {
        [Console]::Error.WriteLine('Direct Cursor preflight could not produce a trustworthy report.')
        exit 1
    }
    $report | ConvertTo-Json -Depth 16
    if ($report.launchable -eq $true) { exit 0 }
    exit 2
}

if (-not [IO.Directory]::Exists($resolvedStateRoot)) { [IO.Directory]::CreateDirectory($resolvedStateRoot) | Out-Null }

if ($Operation -eq 'start' -and -not [string]::IsNullOrWhiteSpace($NativeSessionId)) {
    throw 'Adapter start must not receive a native session id.'
}
if ($Operation -ne 'start' -and [string]::IsNullOrWhiteSpace($NativeSessionId)) {
    throw 'Adapter native session id is required.'
}
if ($Operation -ne 'start' -and $NativeSessionId -cnotmatch '^[A-Za-z0-9._:-]+$') {
    throw 'Adapter native session id is malformed.'
}

$sessionIndexPath = Join-Path $resolvedStateRoot 'session-index.json'
if ($Operation -eq 'recover') {
    $job = Resolve-DirectCursorRecoverJobId -StateRoot $resolvedStateRoot -NativeSessionId $NativeSessionId
    if ([string]::IsNullOrWhiteSpace([string]$job)) {
        $sessionPaths = Get-SessionPaths -Root $resolvedStateRoot -SessionId $NativeSessionId
        if (-not [IO.File]::Exists($sessionPaths.binding)) { throw 'Adapter native session id is missing or unknown.' }
        $binding = (Read-DirectJson -Path $sessionPaths.binding).value
        if ([string]$binding.native_session_id -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
        $job = [string]$binding.latest_job_id
    }
    if ([string]::IsNullOrWhiteSpace($job)) { throw 'Adapter durable state was not found.' }
    $paths = Get-JobPaths -Root $resolvedStateRoot -Id $job
    if (-not [IO.Directory]::Exists($paths.root)) { throw 'Adapter durable state was not found.' }
    $terminal = Wait-DirectJob -Paths $paths -TimeoutSeconds $WaitTimeoutSeconds -AllowStart $false
    Write-AdapterResult -Op 'recover' -SessionId $NativeSessionId -Terminal $terminal
    if ([string]$terminal.value.protocol_version -ceq 'telephone-line-direct-cursor-status-v1') { exit 3 }
    if ($terminal.value.transport_complete -eq $true) { exit 0 }
    exit 2
}

if ([string]::IsNullOrWhiteSpace($WorkspacePath) -or [string]::IsNullOrWhiteSpace($PromptFile)) {
    throw 'Direct Cursor start and follow-up require workspace and prompt identities.'
}

$effectiveJobId = if ([string]::IsNullOrWhiteSpace($JobId)) { [Guid]::NewGuid().ToString('D') } else { $JobId }
$paths = Get-JobPaths -Root $resolvedStateRoot -Id $effectiveJobId
if ([IO.Directory]::Exists($paths.root)) {
    $existing = Read-DirectJson -Path $paths.request
    if ($Operation -eq 'follow_up') {
        if ([string]$existing.value.resume_session_id -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
    }
    $terminal = Wait-DirectJob -Paths $paths -TimeoutSeconds $WaitTimeoutSeconds -AllowStart $false
    $session = if ($null -ne $terminal.value.native_session_id -and -not [string]::IsNullOrWhiteSpace([string]$terminal.value.native_session_id)) {
        [string]$terminal.value.native_session_id
    } else {
        $fromResult = Get-DirectCursorResultSessionId -Result $(if ($null -ne $terminal.value.cursor_result) { $terminal.value.cursor_result } else { $null })
        if (-not [string]::IsNullOrWhiteSpace($fromResult)) { $fromResult } else { [string]$existing.value.resume_session_id }
    }
    Write-AdapterResult -Op $Operation -SessionId $session -Terminal $terminal
    if ([string]$terminal.value.protocol_version -ceq 'telephone-line-direct-cursor-status-v1') { exit 3 }
    if ($terminal.value.transport_complete -eq $true) { exit 0 }
    exit 2
}

if ($Operation -eq 'follow_up') {
    $sessionPaths = Get-SessionPaths -Root $resolvedStateRoot -SessionId $NativeSessionId
    if (-not [IO.File]::Exists($sessionPaths.binding)) { throw 'Adapter native session id is missing or unknown.' }
    $binding = (Read-DirectJson -Path $sessionPaths.binding).value
    if ([string]$binding.native_session_id -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
    if ([string]$binding.mode -cne $Mode) { throw 'Adapter native session id does not match the frozen session.' }
    $boundScope = [string[]]@($binding.allowed_write_paths | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $requestedScope = [string[]]@(ConvertTo-DirectRelativeWritePaths -WorkspacePath ([IO.Path]::GetFullPath($WorkspacePath).TrimEnd('\')) -Paths $AllowedWritePath)
    if (($boundScope -join "`n") -cne ($requestedScope -join "`n")) { throw 'Adapter native session id does not match the frozen session.' }
}

$workspace = Assert-DirectCursorWorkspaceDispatchable -WorkspacePath $WorkspacePath
if ($resolvedStateRoot.Equals($workspace, [StringComparison]::OrdinalIgnoreCase) -or
    $resolvedStateRoot.StartsWith($workspace + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Direct Cursor state cannot be stored inside the execution workspace.'
}
$promptIdentity = Get-DirectFileIdentity -Path $PromptFile
$promptBytes = [IO.File]::ReadAllBytes([string]$promptIdentity.path)
$promptText = [Text.UTF8Encoding]::new($false, $true).GetString($promptBytes)
if ([string]::IsNullOrWhiteSpace($promptText) -or $promptText.Length -gt 12000) { throw 'Direct Cursor prompt must contain 1 to 12000 characters.' }
$authority = Resolve-DirectCursorModeAuthority -Mode $Mode -AllowWrite ($Mode -ceq 'Write') -AllowedWritePath $AllowedWritePath -WorkspacePath $workspace
$allowed = [string[]]@($authority.allowed_write_paths)
$Mode = [string]$authority.mode
if ($authority.requires_linked_worktree -and -not (Test-Path -LiteralPath (Join-Path $workspace '.git') -PathType Leaf)) {
    throw 'Automated Write mode requires a pre-created linked Git worktree (.git file).'
}
foreach ($rel in $allowed) {
    $declaredFull = [IO.Path]::GetFullPath((Join-Path $workspace $rel)).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $declaredFull)) { throw 'Declared write path does not exist.' }
    $declaredItem = Get-Item -LiteralPath $declaredFull -Force
    if (($declaredItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Declared write path is a reparse point.'
    }
}

$null = Get-DirectFileIdentity -Path (Join-Path $adapterRoot 'cursor_job_host.ps1')
[IO.Directory]::CreateDirectory($paths.root) | Out-Null
$wrapperIdentity = Get-DirectFileIdentity -Path (Join-Path $adapterRoot 'invoke_cursor_agent.ps1')
$bridgeIdentity = Get-DirectFileIdentity -Path (Join-Path $adapterRoot 'invoke_cursor_request.ps1')
$hostIdentity = Get-DirectFileIdentity -Path (Join-Path $adapterRoot 'process_file_host.ps1')
$powerShellPath = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$sessionStore = Join-Path $resolvedStateRoot 'cursor-sessions'
$request = [ordered]@{
    protocol_version = 'telephone-line-direct-cursor-request-v1'
    job_id = $effectiveJobId
    workspace = $workspace
    prompt = $promptIdentity
    mode = $Mode
    model = 'cursor-grok-4.6-xhigh'
    expected_account = $ExpectedAccount
    expected_subscription = $ExpectedSubscription
    resume_session_id = if ($Operation -eq 'follow_up') { $NativeSessionId } else { '' }
    allowed_write_paths = $allowed
    allow_write = [bool]$authority.allow_write
    allow_fast = $false
    timeout_seconds = $CursorTimeoutSeconds
    max_output_bytes = $MaxOutputBytes
    session_root = $sessionStore
    wrapper = $wrapperIdentity
    cursor_agent_root = $CursorAgentRoot
}
$requestIdentity = Write-DirectJsonCreateNew -Path $paths.request -Value $request
$hostConfig = [ordered]@{
    executable = $powerShellPath
    working_directory = $adapterRoot
    arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $bridgeIdentity.path,
        '-RequestPath', $requestIdentity.path,
        '-ExpectedRequestBytes', [string]$requestIdentity.bytes,
        '-ExpectedRequestSha256', [string]$requestIdentity.sha256,
        '-ExpectedBridgeBytes', [string]$bridgeIdentity.bytes,
        '-ExpectedBridgeSha256', [string]$bridgeIdentity.sha256
    )
    stdout_path = $paths.stdout
    stderr_path = $paths.stderr
}
$configIdentity = Write-DirectJsonCreateNew -Path $paths.config -Value $hostConfig
$intent = [ordered]@{
    protocol_version = 'telephone-line-direct-cursor-launch-intent-v1'
    job_id = $effectiveJobId
    request = $requestIdentity
    config = $configIdentity
    bridge = $bridgeIdentity
    host = $hostIdentity
    wrapper = $wrapperIdentity
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    automatic_rerun = $false
}
$null = Write-DirectJsonCreateNew -Path $paths.intent -Value $intent
$hostProcess = Start-DirectHost -PowerShellPath $powerShellPath -HostScript $hostIdentity.path -ConfigPath $configIdentity.path
try {
    $owner = [ordered]@{
        protocol_version = 'telephone-line-direct-cursor-owner-v1'
        pid = [int]$hostProcess.Id
        start_time_utc_ticks = [int64]$hostProcess.StartTime.ToUniversalTime().Ticks
        started_at_utc = $hostProcess.StartTime.ToUniversalTime().ToString('o')
    }
    $null = Write-DirectJsonCreateNew -Path $paths.owner -Value $owner
} finally {
    $hostProcess.Dispose()
}

$terminal = Wait-DirectJob -Paths $paths -TimeoutSeconds $WaitTimeoutSeconds -AllowStart $true
$sessionId = if ($null -ne $terminal.value.native_session_id -and -not [string]::IsNullOrWhiteSpace([string]$terminal.value.native_session_id)) {
    [string]$terminal.value.native_session_id
} else {
    Get-DirectCursorResultSessionId -Result $(if ($null -ne $terminal.value.cursor_result) { $terminal.value.cursor_result } else { $null })
}
if ($Operation -eq 'follow_up' -and $sessionId -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
if ($terminal.value.transport_complete -eq $true -and -not [string]::IsNullOrWhiteSpace($sessionId) -and $null -ne $terminal.identity) {
    Publish-DirectCursorRecoveryBinding -StateRoot $resolvedStateRoot -NativeSessionId $sessionId -JobId $effectiveJobId -ReceiptIdentity $terminal.identity
}
if (-not [string]::IsNullOrWhiteSpace($sessionId) -and $terminal.value.transport_complete -eq $true -and $terminal.value.cursor_success -eq $true) {
    $sessionPaths = Get-SessionPaths -Root $resolvedStateRoot -SessionId $sessionId
    if (-not [IO.File]::Exists($sessionPaths.binding)) {
        $null = Write-DirectJsonCreateNew -Path $sessionPaths.binding -Value ([ordered]@{
            protocol_version = 'telephone-line-direct-cursor-binding-v1'
            native_session_id = $sessionId
            latest_job_id = $effectiveJobId
            workspace = $workspace
            mode = $Mode
            allowed_write_paths = $allowed
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        })
    } else {
        $existingBinding = (Read-DirectJson -Path $sessionPaths.binding).value
        if ([string]$existingBinding.native_session_id -cne $sessionId) { throw 'Adapter native session id does not match the frozen session.' }
        if ([string]$existingBinding.mode -cne $Mode) { throw 'Adapter native session id does not match the frozen session.' }
        $existingBinding.latest_job_id = $effectiveJobId
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes((($existingBinding | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n"))
        [IO.File]::WriteAllBytes($sessionPaths.binding, $bytes)
    }
}
Write-AdapterResult -Op $Operation -SessionId $sessionId -Terminal $terminal
if ([string]$terminal.value.protocol_version -ceq 'telephone-line-direct-cursor-status-v1') { exit 3 }
if ($terminal.value.transport_complete -eq $true) { exit 0 }
exit 2

# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('start', 'follow_up', 'recover')][string]$Operation,
    [string]$NativeSessionId,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [string]$WorkspacePath,
    [string]$PromptFile,
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$JobId,
    [ValidateRange(0, 2147483647)][int]$ClaudeTimeoutSeconds = 0,
    [ValidateRange(0, 2147483647)][int]$WaitTimeoutSeconds = 0,
    [ValidateRange(65536, 67108864)][int]$MaxOutputBytes = 16777216,
    [string]$ClaudeCommand,
    [string]$Model,
    [string]$PermissionMode,
    [string]$SuppliedSessionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }
. (Join-Path $PSScriptRoot 'DirectClaude.Common.ps1')

function Get-DirectClaudeJobPaths {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Id)
    $jobRoot = Join-Path $Root ('jobs\' + $Id)
    return [ordered]@{
        root = $jobRoot
        request = Join-Path $jobRoot 'request.json'
        config = Join-Path $jobRoot 'host-config.json'
        intent = Join-Path $jobRoot 'launch-intent.json'
        owner = Join-Path $jobRoot 'owner.json'
        stdout = Join-Path $jobRoot 'claude-result.json'
        stderr = Join-Path $jobRoot 'wrapper-stderr.txt'
        receipt = Join-Path $jobRoot 'receipt.json'
    }
}

function Get-DirectClaudeSessionPaths {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$SessionId)
    Assert-DirectClaudeNativeSessionIdFormat -SessionId $SessionId -Label 'Direct Claude binding'
    $sessionRoot = Join-Path $Root ('sessions\' + $SessionId)
    return [ordered]@{
        root = $sessionRoot
        binding = Join-Path $sessionRoot 'binding.json'
    }
}

function Start-DirectClaudeHost {
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
    if ($null -eq $process) { throw 'Direct Claude host did not start.' }
    return $process
}

function Find-DirectClaudeHostOwner {
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
    if ($matches.Count -gt 1) { throw 'More than one Direct Claude host matches this exact job.' }
    if ($matches.Count -eq 0) { return $null }
    $process = Get-Process -Id ([int]$matches[0].ProcessId) -ErrorAction Stop
    try {
        return [ordered]@{
            protocol_version = 'telephone-line-direct-claude-owner-v1'
            pid = [int]$process.Id
            start_time_utc_ticks = [int64]$process.StartTime.ToUniversalTime().Ticks
            started_at_utc = $process.StartTime.ToUniversalTime().ToString('o')
        }
    } finally { $process.Dispose() }
}

function New-DirectClaudeReceipt {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$RequestRead,
        [Collections.IDictionary]$Owner
    )
    $request = $RequestRead.value
    $claudeResult = $null
    $transportError = $null
    try {
        if (-not [IO.File]::Exists($Paths.stdout)) { throw 'Direct Claude terminal result is missing.' }
        $resultRead = Read-DirectClaudeJson -Path $Paths.stdout
        $claudeResult = $resultRead.value
        if ($claudeResult -isnot [Collections.IDictionary] -or $claudeResult.success -isnot [bool]) { throw 'Direct Claude terminal result is malformed.' }
        if ([string]$claudeResult.protocol_version -cne 'telephone-line-direct-claude-result-v1') { throw 'Direct Claude terminal protocol differs.' }
        if ([string]$claudeResult.job_id -cne [string]$request.job_id) { throw 'Direct Claude terminal job differs.' }
        if ([string]$claudeResult.prompt.sha256 -cne [string]$request.prompt.sha256) { throw 'Direct Claude terminal prompt differs.' }
        if ([bool]$claudeResult.resumed -ne [bool]$request.resume) { throw 'Direct Claude terminal session differs.' }
        if ($claudeResult.official_cli -ne $true) { throw 'Direct Claude did not stay on the user CLI boundary.' }
        if ([bool]$request.resume -and [string]$claudeResult.session_id -cne [string]$request.session_id) {
            throw 'Adapter native session id does not match the frozen session.'
        }
        if ([bool]$claudeResult.success -eq $true -and (
            -not $claudeResult.Contains('assistant_text') -or
            $claudeResult.assistant_text -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$claudeResult.assistant_text)
        )) {
            throw 'Direct Claude terminal has no assistant text.'
        }
        if ([bool]$claudeResult.success -ne $true) {
            if ($claudeResult.Contains('error')) { $claudeResult.error = Get-DirectClaudePublicError -Text ([string]$claudeResult.error) }
            if ($claudeResult.Contains('diagnostic')) { $claudeResult.diagnostic = Protect-DirectClaudeDiagnostic -Text ([string]$claudeResult.diagnostic) }
            $transportError = Get-DirectClaudePublicError -ErrorCode 'ADAPTER_TRANSPORT_FAILED'
        } elseif ([string]::IsNullOrWhiteSpace([string]$claudeResult.session_id)) {
            throw 'Direct Claude terminal has no native session id.'
        }
    } catch {
        $transportError = Get-DirectClaudePublicError -Text $_.Exception.Message
        $claudeResult = $null
    }
    $transportComplete = $null -eq $transportError -and $null -ne $claudeResult -and [bool]$claudeResult.success
    $receipt = [ordered]@{
        protocol_version = 'telephone-line-direct-claude-receipt-v1'
        job_id = [string]$request.job_id
        request = $RequestRead.identity
        transport_complete = [bool]$transportComplete
        transport_error = $transportError
        official_cli = $true
        native_session_id = if ($null -ne $claudeResult -and -not [string]::IsNullOrWhiteSpace([string]$claudeResult.session_id)) { [string]$claudeResult.session_id } else { [string]$request.session_id }
        assistant_text = if ($null -ne $claudeResult -and [bool]$claudeResult.success) { [string]$claudeResult.assistant_text } else { '' }
        stdout = if ([IO.File]::Exists($Paths.stdout)) { Get-DirectClaudeFileIdentity -Path $Paths.stdout } else { $null }
        stderr = if ([IO.File]::Exists($Paths.stderr)) { Get-DirectClaudeFileIdentity -Path $Paths.stderr } else { $null }
        owner = $Owner
        automatic_rerun = $false
        replacement_started = $false
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try { return Write-DirectClaudeJsonCreateNew -Path $Paths.receipt -Value $receipt }
    catch [IO.IOException] { return Get-DirectClaudeFileIdentity -Path $Paths.receipt }
}

function Wait-DirectClaudeJob {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][bool]$AllowStart
    )
    $requestRead = Read-DirectClaudeJson -Path $Paths.request
    $deadline = if ($TimeoutSeconds -gt 0) { [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds) } else { $null }
    while ($true) {
        if ([IO.File]::Exists($Paths.receipt)) {
            $receiptRead = Read-DirectClaudeJson -Path $Paths.receipt
            if ([string]$receiptRead.value.job_id -cne [string]$requestRead.value.job_id) { throw 'Direct Claude receipt belongs to another job.' }
            Assert-DirectClaudeIdentity -Expected $requestRead.identity -Actual $receiptRead.value.request -Label 'Direct Claude receipt request'
            return $receiptRead
        }
        $owner = $null
        if ([IO.File]::Exists($Paths.owner)) { $owner = (Read-DirectClaudeJson -Path $Paths.owner).value }
        elseif ($AllowStart -and [IO.File]::Exists($Paths.config)) {
            $owner = Find-DirectClaudeHostOwner -ConfigPath $Paths.config
            if ($null -ne $owner) { try { $null = Write-DirectClaudeJsonCreateNew -Path $Paths.owner -Value $owner } catch [IO.IOException] { } }
        }
        if ($null -ne $owner -and (Test-DirectClaudeOwnerAlive -Owner $owner)) {
            if ($null -ne $deadline -and [DateTimeOffset]::UtcNow -ge $deadline) {
                return [ordered]@{ value = [ordered]@{ protocol_version = 'telephone-line-direct-claude-status-v1'; job_id = [string]$requestRead.value.job_id; state = 'running'; owner = $owner; automatic_rerun = $false; replacement_started = $false }; identity = $null }
            }
            Start-Sleep -Milliseconds 500
            continue
        }
        Start-Sleep -Milliseconds 200
        $null = New-DirectClaudeReceipt -Paths $Paths -RequestRead $requestRead -Owner $owner
        return Read-DirectClaudeJson -Path $Paths.receipt
    }
}

function Write-DirectClaudeAdapterResult {
    param([Parameter(Mandatory = $true)][string]$Op, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SessionId, [Parameter(Mandatory = $true)][object]$Terminal)
    $result = [ordered]@{
        protocol_version = 'telephone-line-adapter-result-v1'
        route_id = 'direct-claude-code'
        operation = $Op
        native_session_id = $SessionId
        job_id = [string]$Terminal.value.job_id
        automatic_rerun = $false
        replacement_started = $false
        transport_complete = if ($null -ne $Terminal.value.transport_complete) { [bool]$Terminal.value.transport_complete } else { $false }
        official_cli = $true
        receipt = $Terminal.identity
    }
    $result.assistant_text = if ($Terminal.value -is [Collections.IDictionary] -and $Terminal.value.Contains('assistant_text')) { [string]$Terminal.value.assistant_text } else { '' }
    $result | ConvertTo-Json -Depth 16
}

$adapterRoot = Get-DirectClaudeCanonicalDirectory -Path $PSScriptRoot
$state = Initialize-DirectClaudeStateRoot -Path $StateRoot

if ($Operation -eq 'start' -and -not [string]::IsNullOrWhiteSpace($NativeSessionId)) { throw 'Adapter start must not receive a native session id.' }
if ($Operation -ne 'start' -and [string]::IsNullOrWhiteSpace($NativeSessionId)) { throw 'Adapter native session id is required.' }
if ($Operation -ne 'start') { Assert-DirectClaudeNativeSessionIdFormat -SessionId $NativeSessionId -Label 'Adapter' }
if ($Operation -ne 'start' -and -not [string]::IsNullOrWhiteSpace($SuppliedSessionId)) { throw 'Direct Claude supplied session id is start-only.' }

if ($Operation -eq 'recover') {
    $sessionPaths = Get-DirectClaudeSessionPaths -Root $state -SessionId $NativeSessionId
    if (-not [IO.File]::Exists($sessionPaths.binding)) { throw 'Adapter native session id is missing or unknown.' }
    $bindingPath = Assert-DirectClaudeExistingComponentChain -Path $sessionPaths.binding -Root $state -Label 'Direct Claude binding' -RequireExisting
    $binding = (Read-DirectClaudeJson -Path $bindingPath).value
    if ([string]$binding.native_session_id -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
    $paths = Get-DirectClaudeJobPaths -Root $state -Id ([string]$binding.latest_job_id)
    $null = Assert-DirectClaudeExistingComponentChain -Path $paths.root -Root $state -Label 'Direct Claude job' -RequireExisting
    $waited = Wait-DirectClaudeJob -Paths $paths -TimeoutSeconds $WaitTimeoutSeconds -AllowStart $false
    Write-DirectClaudeAdapterResult -Op 'recover' -SessionId $NativeSessionId -Terminal $waited
    if ([string]$waited.value.protocol_version -ceq 'telephone-line-direct-claude-status-v1') { exit 3 }
    if ($waited.value.transport_complete -eq $true) { exit 0 }
    exit 4
}

if ([string]::IsNullOrWhiteSpace($WorkspacePath) -or [string]::IsNullOrWhiteSpace($PromptFile)) {
    throw 'Direct Claude start and follow-up require workspace and prompt identities.'
}

$job = if ([string]::IsNullOrWhiteSpace($JobId)) { [Guid]::NewGuid().ToString('D') } else { $JobId }
$paths = Get-DirectClaudeJobPaths -Root $state -Id $job
if ([IO.Directory]::Exists($paths.root)) {
    $null = Assert-DirectClaudeExistingComponentChain -Path $paths.root -Root $state -Label 'Direct Claude job' -RequireExisting
    $existing = Read-DirectClaudeJson -Path $paths.request
    if ($Operation -eq 'follow_up' -and [string]$existing.value.session_id -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
    $waited = Wait-DirectClaudeJob -Paths $paths -TimeoutSeconds $WaitTimeoutSeconds -AllowStart $false
    $session = if ($null -ne $waited.value.native_session_id) { [string]$waited.value.native_session_id } else { [string]$existing.value.session_id }
    Write-DirectClaudeAdapterResult -Op $Operation -SessionId $session -Terminal $waited
    if ([string]$waited.value.protocol_version -ceq 'telephone-line-direct-claude-status-v1') { exit 3 }
    if ($waited.value.transport_complete -eq $true) { exit 0 }
    exit 4
}

$workspace = Get-DirectClaudeCanonicalDirectory -Path $WorkspacePath
if (-not [IO.Directory]::Exists($workspace)) { throw 'Direct Claude workspace does not exist.' }
$promptIdentity = Get-DirectClaudeFileIdentity -Path $PromptFile
$sessionId = if ($Operation -eq 'follow_up') { $NativeSessionId } else { '' }
$supplied = if ($Operation -eq 'start' -and -not [string]::IsNullOrWhiteSpace($SuppliedSessionId)) { $SuppliedSessionId } else { '' }
if ($Operation -eq 'follow_up') {
    $sessionPaths = Get-DirectClaudeSessionPaths -Root $state -SessionId $NativeSessionId
    if (-not [IO.File]::Exists($sessionPaths.binding)) { throw 'Adapter native session id is missing or unknown.' }
    $bindingPath = Assert-DirectClaudeExistingComponentChain -Path $sessionPaths.binding -Root $state -Label 'Direct Claude binding' -RequireExisting
    $binding = (Read-DirectClaudeJson -Path $bindingPath).value
    if ([string]$binding.native_session_id -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
}

[IO.Directory]::CreateDirectory($paths.root) | Out-Null
$null = Assert-DirectClaudeExistingComponentChain -Path $paths.root -Root $state -Label 'Direct Claude job' -RequireExisting
$wrapperIdentity = Get-DirectClaudeFileIdentity -Path (Join-Path $adapterRoot 'invoke_claude.ps1')
$cliPath = Resolve-DirectClaudeCommand -ClaudeCommand $ClaudeCommand
$cliIdentity = Get-DirectClaudeFileIdentity -Path $cliPath
$request = [ordered]@{
    protocol_version = 'telephone-line-direct-claude-request-v1'
    job_id = $job
    workspace = $workspace
    prompt = $promptIdentity
    model = if ([string]::IsNullOrWhiteSpace($Model)) { '' } else { $Model }
    permission_mode = if ([string]::IsNullOrWhiteSpace($PermissionMode)) { '' } else { $PermissionMode }
    supplied_session_id = $supplied
    session_id = $sessionId
    resume = ($Operation -eq 'follow_up')
    timeout_seconds = $ClaudeTimeoutSeconds
    max_output_bytes = $MaxOutputBytes
    cli = $cliIdentity
    wrapper = $wrapperIdentity
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}
$requestIdentity = Write-DirectClaudeJsonCreateNew -Path $paths.request -Value $request
$powerShellPath = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$hostScript = Get-DirectClaudeFileIdentity -Path (Join-Path $adapterRoot 'process_file_host.ps1')
$hostConfig = [ordered]@{
    executable = $powerShellPath
    working_directory = $workspace
    arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', [string]$wrapperIdentity.path,
        '-RequestPath', [string]$requestIdentity.path,
        '-ExpectedRequestBytes', [string]$requestIdentity.bytes,
        '-ExpectedRequestSha256', [string]$requestIdentity.sha256,
        '-ExpectedWrapperBytes', [string]$wrapperIdentity.bytes,
        '-ExpectedWrapperSha256', [string]$wrapperIdentity.sha256
    )
    stdout_path = $paths.stdout
    stderr_path = $paths.stderr
}
$configIdentity = Write-DirectClaudeJsonCreateNew -Path $paths.config -Value $hostConfig
$null = Write-DirectClaudeJsonCreateNew -Path $paths.intent -Value ([ordered]@{
    protocol_version = 'telephone-line-direct-claude-launch-v1'
    job_id = $job
    request = $requestIdentity
    config = $configIdentity
    host = $hostScript
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    automatic_rerun = $false
})
$process = Start-DirectClaudeHost -PowerShellPath $powerShellPath -HostScript ([string]$hostScript.path) -ConfigPath ([string]$configIdentity.path)
try {
    $owner = [ordered]@{
        protocol_version = 'telephone-line-direct-claude-owner-v1'
        pid = [int]$process.Id
        start_time_utc_ticks = [int64]$process.StartTime.ToUniversalTime().Ticks
        started_at_utc = $process.StartTime.ToUniversalTime().ToString('o')
    }
    try { $null = Write-DirectClaudeJsonCreateNew -Path $paths.owner -Value $owner } catch [IO.IOException] { }
} finally { $process.Dispose() }

$waited = Wait-DirectClaudeJob -Paths $paths -TimeoutSeconds $WaitTimeoutSeconds -AllowStart $true
$returnedSession = if ($null -ne $waited.value.native_session_id) { [string]$waited.value.native_session_id } else { '' }
if ($Operation -eq 'follow_up' -and $returnedSession -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
if ($waited.value.transport_complete -eq $true -and -not [string]::IsNullOrWhiteSpace($returnedSession)) {
    Assert-DirectClaudeNativeSessionIdFormat -SessionId $returnedSession -Label 'Direct Claude captured'
    $sessionPaths = Get-DirectClaudeSessionPaths -Root $state -SessionId $returnedSession
    if (-not [IO.File]::Exists($sessionPaths.binding)) {
        [IO.Directory]::CreateDirectory($sessionPaths.root) | Out-Null
        $null = Write-DirectClaudeJsonCreateNew -Path $sessionPaths.binding -Value ([ordered]@{
            protocol_version = 'telephone-line-direct-claude-binding-v1'
            native_session_id = $returnedSession
            latest_job_id = $job
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        })
    } else {
        $existingBinding = (Read-DirectClaudeJson -Path $sessionPaths.binding).value
        if ([string]$existingBinding.native_session_id -cne $returnedSession) { throw 'Adapter native session id does not match the frozen session.' }
        $existingBinding.latest_job_id = $job
        [IO.File]::WriteAllBytes($sessionPaths.binding, [Text.UTF8Encoding]::new($false).GetBytes((($existingBinding | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n")))
    }
}
Write-DirectClaudeAdapterResult -Op $Operation -SessionId $returnedSession -Terminal $waited
if ([string]$waited.value.protocol_version -ceq 'telephone-line-direct-claude-status-v1') { exit 3 }
if ($waited.value.transport_complete -eq $true) { exit 0 }
exit 4

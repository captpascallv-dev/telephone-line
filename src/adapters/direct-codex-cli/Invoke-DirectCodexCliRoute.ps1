# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('start', 'follow_up', 'recover')][string]$Operation,
    [string]$NativeSessionId,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [string]$WorkspacePath,
    [string]$PromptFile,
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$JobId,
    [ValidateRange(0, 2147483647)][int]$CodexTimeoutSeconds = 0,
    [ValidateRange(0, 2147483647)][int]$WaitTimeoutSeconds = 0,
    [ValidateRange(65536, 67108864)][int]$MaxOutputBytes = 16777216,
    [string]$CodexCommand,
    [string]$Model,
    [string]$ReasoningEffort,
    [string]$Sandbox,
    [string]$ApprovalPolicy,
    [switch]$SkipGitRepoCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }
. (Join-Path $PSScriptRoot 'DirectCodex.Common.ps1')

function Get-DirectCodexJobPaths {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Id)
    $jobRoot = Join-Path $Root ('jobs\' + $Id)
    return [ordered]@{
        root = $jobRoot
        request = Join-Path $jobRoot 'request.json'
        config = Join-Path $jobRoot 'host-config.json'
        intent = Join-Path $jobRoot 'launch-intent.json'
        owner = Join-Path $jobRoot 'owner.json'
        stdout = Join-Path $jobRoot 'codex-result.json'
        stderr = Join-Path $jobRoot 'wrapper-stderr.txt'
        last_message = Join-Path $jobRoot 'last-message.txt'
        receipt = Join-Path $jobRoot 'receipt.json'
    }
}

function Get-DirectCodexSessionPaths {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$SessionId)
    Assert-DirectCodexNativeSessionIdFormat -SessionId $SessionId -Label 'Direct Codex binding'
    $sessionRoot = Join-Path $Root ('sessions\' + $SessionId)
    return [ordered]@{
        root = $sessionRoot
        binding = Join-Path $sessionRoot 'binding.json'
    }
}

function Start-DirectCodexHost {
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
    if ($null -eq $process) { throw 'Direct Codex host did not start.' }
    return $process
}

function Find-DirectCodexHostOwner {
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
    if ($matches.Count -gt 1) { throw 'More than one Direct Codex host matches this exact job.' }
    if ($matches.Count -eq 0) { return $null }
    $process = Get-Process -Id ([int]$matches[0].ProcessId) -ErrorAction Stop
    try {
        return [ordered]@{
            protocol_version = 'telephone-line-direct-codex-owner-v1'
            pid = [int]$process.Id
            start_time_utc_ticks = [int64]$process.StartTime.ToUniversalTime().Ticks
            started_at_utc = $process.StartTime.ToUniversalTime().ToString('o')
        }
    } finally { $process.Dispose() }
}

function New-DirectCodexReceipt {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$RequestRead,
        [Collections.IDictionary]$Owner
    )
    $request = $RequestRead.value
    $codexResult = $null
    $transportError = $null
    try {
        if (-not [IO.File]::Exists($Paths.stdout)) { throw 'Direct Codex terminal result is missing.' }
        $resultRead = Read-DirectCodexJson -Path $Paths.stdout
        $codexResult = $resultRead.value
        if ($codexResult -isnot [Collections.IDictionary] -or $codexResult.success -isnot [bool]) { throw 'Direct Codex terminal result is malformed.' }
        if ([string]$codexResult.protocol_version -cne 'telephone-line-direct-codex-result-v1') { throw 'Direct Codex terminal protocol differs.' }
        if ([string]$codexResult.job_id -cne [string]$request.job_id) { throw 'Direct Codex terminal job differs.' }
        if ([string]$codexResult.prompt.sha256 -cne [string]$request.prompt.sha256) { throw 'Direct Codex terminal prompt differs.' }
        if ([bool]$codexResult.resumed -ne [bool]$request.resume) { throw 'Direct Codex terminal session differs.' }
        if ($codexResult.official_cli -ne $true) { throw 'Direct Codex did not stay on the user CLI boundary.' }
        if ([bool]$request.resume -and [string]$codexResult.session_id -cne [string]$request.session_id) {
            throw 'Adapter native session id does not match the frozen session.'
        }
        if ([bool]$codexResult.success -ne $true) {
            if ($codexResult.Contains('error')) { $codexResult.error = Get-DirectCodexPublicError -Text ([string]$codexResult.error) }
            if ($codexResult.Contains('diagnostic')) { $codexResult.diagnostic = Protect-DirectCodexDiagnostic -Text ([string]$codexResult.diagnostic) }
            $transportError = Get-DirectCodexPublicError -ErrorCode 'ADAPTER_TRANSPORT_FAILED'
        } elseif ([string]::IsNullOrWhiteSpace([string]$codexResult.session_id)) {
            throw 'Direct Codex terminal has no native session id.'
        }
    } catch {
        $transportError = Get-DirectCodexPublicError -Text $_.Exception.Message
        $codexResult = $null
    }
    $transportComplete = $null -eq $transportError -and $null -ne $codexResult -and [bool]$codexResult.success
    $receipt = [ordered]@{
        protocol_version = 'telephone-line-direct-codex-receipt-v1'
        job_id = [string]$request.job_id
        request = $RequestRead.identity
        transport_complete = [bool]$transportComplete
        transport_error = $transportError
        official_cli = $true
        native_session_id = if ($null -ne $codexResult -and -not [string]::IsNullOrWhiteSpace([string]$codexResult.session_id)) { [string]$codexResult.session_id } else { [string]$request.session_id }
        stdout = if ([IO.File]::Exists($Paths.stdout)) { Get-DirectCodexFileIdentity -Path $Paths.stdout } else { $null }
        stderr = if ([IO.File]::Exists($Paths.stderr)) { Get-DirectCodexFileIdentity -Path $Paths.stderr } else { $null }
        owner = $Owner
        automatic_rerun = $false
        replacement_started = $false
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try { return Write-DirectCodexJsonCreateNew -Path $Paths.receipt -Value $receipt }
    catch [IO.IOException] { return Get-DirectCodexFileIdentity -Path $Paths.receipt }
}

function Wait-DirectCodexJob {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][bool]$AllowStart
    )
    $requestRead = Read-DirectCodexJson -Path $Paths.request
    $deadline = if ($TimeoutSeconds -gt 0) { [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds) } else { $null }
    while ($true) {
        if ([IO.File]::Exists($Paths.receipt)) {
            $receiptRead = Read-DirectCodexJson -Path $Paths.receipt
            if ([string]$receiptRead.value.job_id -cne [string]$requestRead.value.job_id) { throw 'Direct Codex receipt belongs to another job.' }
            Assert-DirectCodexIdentity -Expected $requestRead.identity -Actual $receiptRead.value.request -Label 'Direct Codex receipt request'
            return $receiptRead
        }
        $owner = $null
        if ([IO.File]::Exists($Paths.owner)) { $owner = (Read-DirectCodexJson -Path $Paths.owner).value }
        elseif ($AllowStart -and [IO.File]::Exists($Paths.config)) {
            $owner = Find-DirectCodexHostOwner -ConfigPath $Paths.config
            if ($null -ne $owner) { try { $null = Write-DirectCodexJsonCreateNew -Path $Paths.owner -Value $owner } catch [IO.IOException] { } }
        }
        if ($null -ne $owner -and (Test-DirectCodexOwnerAlive -Owner $owner)) {
            if ($null -ne $deadline -and [DateTimeOffset]::UtcNow -ge $deadline) {
                return [ordered]@{ value = [ordered]@{ protocol_version = 'telephone-line-direct-codex-status-v1'; job_id = [string]$requestRead.value.job_id; state = 'running'; owner = $owner; automatic_rerun = $false; replacement_started = $false }; identity = $null }
            }
            Start-Sleep -Milliseconds 500
            continue
        }
        Start-Sleep -Milliseconds 200
        $null = New-DirectCodexReceipt -Paths $Paths -RequestRead $requestRead -Owner $owner
        return Read-DirectCodexJson -Path $Paths.receipt
    }
}

function Write-DirectCodexAdapterResult {
    param([Parameter(Mandatory = $true)][string]$Op, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SessionId, [Parameter(Mandatory = $true)][object]$Terminal)
    [ordered]@{
        protocol_version = 'telephone-line-adapter-result-v1'
        route_id = 'direct-codex-cli'
        operation = $Op
        native_session_id = $SessionId
        job_id = [string]$Terminal.value.job_id
        automatic_rerun = $false
        replacement_started = $false
        transport_complete = if ($null -ne $Terminal.value.transport_complete) { [bool]$Terminal.value.transport_complete } else { $false }
        official_cli = $true
        receipt = $Terminal.identity
    } | ConvertTo-Json -Depth 16
}

$adapterRoot = Get-DirectCodexCanonicalDirectory -Path $PSScriptRoot
$state = Initialize-DirectCodexStateRoot -Path $StateRoot

if ($Operation -eq 'start' -and -not [string]::IsNullOrWhiteSpace($NativeSessionId)) { throw 'Adapter start must not receive a native session id.' }
if ($Operation -ne 'start' -and [string]::IsNullOrWhiteSpace($NativeSessionId)) { throw 'Adapter native session id is required.' }
if ($Operation -ne 'start') { Assert-DirectCodexNativeSessionIdFormat -SessionId $NativeSessionId -Label 'Adapter' }

if ($Operation -eq 'recover') {
    $sessionPaths = Get-DirectCodexSessionPaths -Root $state -SessionId $NativeSessionId
    if (-not [IO.File]::Exists($sessionPaths.binding)) { throw 'Adapter native session id is missing or unknown.' }
    $bindingPath = Assert-DirectCodexExistingComponentChain -Path $sessionPaths.binding -Root $state -Label 'Direct Codex binding' -RequireExisting
    $binding = (Read-DirectCodexJson -Path $bindingPath).value
    if ([string]$binding.native_session_id -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
    $paths = Get-DirectCodexJobPaths -Root $state -Id ([string]$binding.latest_job_id)
    $null = Assert-DirectCodexExistingComponentChain -Path $paths.root -Root $state -Label 'Direct Codex job' -RequireExisting
    $waited = Wait-DirectCodexJob -Paths $paths -TimeoutSeconds $WaitTimeoutSeconds -AllowStart $false
    Write-DirectCodexAdapterResult -Op 'recover' -SessionId $NativeSessionId -Terminal $waited
    if ([string]$waited.value.protocol_version -ceq 'telephone-line-direct-codex-status-v1') { exit 3 }
    if ($waited.value.transport_complete -eq $true) { exit 0 }
    exit 4
}

if ([string]::IsNullOrWhiteSpace($WorkspacePath) -or [string]::IsNullOrWhiteSpace($PromptFile)) {
    throw 'Direct Codex start and follow-up require workspace and prompt identities.'
}

$job = if ([string]::IsNullOrWhiteSpace($JobId)) { [Guid]::NewGuid().ToString('D') } else { $JobId }
$paths = Get-DirectCodexJobPaths -Root $state -Id $job
if ([IO.Directory]::Exists($paths.root)) {
    $null = Assert-DirectCodexExistingComponentChain -Path $paths.root -Root $state -Label 'Direct Codex job' -RequireExisting
    $existing = Read-DirectCodexJson -Path $paths.request
    if ($Operation -eq 'follow_up' -and [string]$existing.value.session_id -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
    $waited = Wait-DirectCodexJob -Paths $paths -TimeoutSeconds $WaitTimeoutSeconds -AllowStart $false
    $session = if ($null -ne $waited.value.native_session_id) { [string]$waited.value.native_session_id } else { [string]$existing.value.session_id }
    Write-DirectCodexAdapterResult -Op $Operation -SessionId $session -Terminal $waited
    if ([string]$waited.value.protocol_version -ceq 'telephone-line-direct-codex-status-v1') { exit 3 }
    if ($waited.value.transport_complete -eq $true) { exit 0 }
    exit 4
}

$workspace = Get-DirectCodexCanonicalDirectory -Path $WorkspacePath
if (-not [IO.Directory]::Exists($workspace)) { throw 'Direct Codex workspace does not exist.' }
$promptIdentity = Get-DirectCodexFileIdentity -Path $PromptFile
$sessionId = if ($Operation -eq 'follow_up') { $NativeSessionId } else { '' }
if ($Operation -eq 'follow_up') {
    $sessionPaths = Get-DirectCodexSessionPaths -Root $state -SessionId $NativeSessionId
    if (-not [IO.File]::Exists($sessionPaths.binding)) { throw 'Adapter native session id is missing or unknown.' }
    $bindingPath = Assert-DirectCodexExistingComponentChain -Path $sessionPaths.binding -Root $state -Label 'Direct Codex binding' -RequireExisting
    $binding = (Read-DirectCodexJson -Path $bindingPath).value
    if ([string]$binding.native_session_id -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
}

[IO.Directory]::CreateDirectory($paths.root) | Out-Null
$null = Assert-DirectCodexExistingComponentChain -Path $paths.root -Root $state -Label 'Direct Codex job' -RequireExisting
$wrapperIdentity = Get-DirectCodexFileIdentity -Path (Join-Path $adapterRoot 'invoke_codex_exec.ps1')
$cliPath = Resolve-DirectCodexCommand -CodexCommand $CodexCommand
$cliIdentity = Get-DirectCodexFileIdentity -Path $cliPath
$request = [ordered]@{
    protocol_version = 'telephone-line-direct-codex-request-v1'
    job_id = $job
    workspace = $workspace
    prompt = $promptIdentity
    model = if ([string]::IsNullOrWhiteSpace($Model)) { '' } else { $Model }
    reasoning_effort = if ([string]::IsNullOrWhiteSpace($ReasoningEffort)) { '' } else { $ReasoningEffort }
    sandbox = if ([string]::IsNullOrWhiteSpace($Sandbox)) { '' } else { $Sandbox }
    approval_policy = if ([string]::IsNullOrWhiteSpace($ApprovalPolicy)) { '' } else { $ApprovalPolicy }
    skip_git_repo_check = [bool]$SkipGitRepoCheck
    session_id = $sessionId
    resume = ($Operation -eq 'follow_up')
    timeout_seconds = $CodexTimeoutSeconds
    max_output_bytes = $MaxOutputBytes
    last_message_path = $paths.last_message
    cli = $cliIdentity
    wrapper = $wrapperIdentity
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}
$requestIdentity = Write-DirectCodexJsonCreateNew -Path $paths.request -Value $request
$powerShellPath = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$hostScript = Get-DirectCodexFileIdentity -Path (Join-Path $adapterRoot 'process_file_host.ps1')
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
$configIdentity = Write-DirectCodexJsonCreateNew -Path $paths.config -Value $hostConfig
$null = Write-DirectCodexJsonCreateNew -Path $paths.intent -Value ([ordered]@{
    protocol_version = 'telephone-line-direct-codex-launch-v1'
    job_id = $job
    request = $requestIdentity
    config = $configIdentity
    host = $hostScript
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    automatic_rerun = $false
})
$process = Start-DirectCodexHost -PowerShellPath $powerShellPath -HostScript ([string]$hostScript.path) -ConfigPath ([string]$configIdentity.path)
try {
    $owner = [ordered]@{
        protocol_version = 'telephone-line-direct-codex-owner-v1'
        pid = [int]$process.Id
        start_time_utc_ticks = [int64]$process.StartTime.ToUniversalTime().Ticks
        started_at_utc = $process.StartTime.ToUniversalTime().ToString('o')
    }
    try { $null = Write-DirectCodexJsonCreateNew -Path $paths.owner -Value $owner } catch [IO.IOException] { }
} finally { $process.Dispose() }

$waited = Wait-DirectCodexJob -Paths $paths -TimeoutSeconds $WaitTimeoutSeconds -AllowStart $true
$returnedSession = if ($null -ne $waited.value.native_session_id) { [string]$waited.value.native_session_id } else { '' }
if ($Operation -eq 'follow_up' -and $returnedSession -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
if ($waited.value.transport_complete -eq $true -and -not [string]::IsNullOrWhiteSpace($returnedSession)) {
    Assert-DirectCodexNativeSessionIdFormat -SessionId $returnedSession -Label 'Direct Codex captured'
    $sessionPaths = Get-DirectCodexSessionPaths -Root $state -SessionId $returnedSession
    if (-not [IO.File]::Exists($sessionPaths.binding)) {
        [IO.Directory]::CreateDirectory($sessionPaths.root) | Out-Null
        $null = Write-DirectCodexJsonCreateNew -Path $sessionPaths.binding -Value ([ordered]@{
            protocol_version = 'telephone-line-direct-codex-binding-v1'
            native_session_id = $returnedSession
            latest_job_id = $job
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        })
    } else {
        $existingBinding = (Read-DirectCodexJson -Path $sessionPaths.binding).value
        if ([string]$existingBinding.native_session_id -cne $returnedSession) { throw 'Adapter native session id does not match the frozen session.' }
        $existingBinding.latest_job_id = $job
        [IO.File]::WriteAllBytes($sessionPaths.binding, [Text.UTF8Encoding]::new($false).GetBytes((($existingBinding | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n")))
    }
}
Write-DirectCodexAdapterResult -Op $Operation -SessionId $returnedSession -Terminal $waited
if ([string]$waited.value.protocol_version -ceq 'telephone-line-direct-codex-status-v1') { exit 3 }
if ($waited.value.transport_complete -eq $true) { exit 0 }
exit 4

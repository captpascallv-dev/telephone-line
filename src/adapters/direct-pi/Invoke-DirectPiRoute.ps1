# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('start', 'follow_up', 'recover')][string]$Operation,
    [string]$NativeSessionId,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [string]$WorkspacePath,
    [string]$PromptFile,
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$JobId,
    [string]$ResumeSessionPath = '',
    [ValidateRange(0, 2147483647)][int]$PiTimeoutSeconds = 0,
    [ValidateRange(0, 2147483647)][int]$WaitTimeoutSeconds = 0,
    [ValidateRange(65536, 67108864)][int]$MaxOutputBytes = 16777216,
    [string]$NodePath = '',
    [string]$PiCliPath = '',
    [string]$MockCliPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }
. (Join-Path $PSScriptRoot 'DirectPi.Common.ps1')

function Get-DirectPiJobPaths {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Id)
    $jobRoot = Join-Path $Root ('jobs\' + $Id)
    return [ordered]@{
        root = $jobRoot
        request = Join-Path $jobRoot 'request.json'
        config = Join-Path $jobRoot 'host-config.json'
        intent = Join-Path $jobRoot 'launch-intent.json'
        owner = Join-Path $jobRoot 'owner.json'
        stdout = Join-Path $jobRoot 'pi-result.json'
        stderr = Join-Path $jobRoot 'wrapper-stderr.txt'
        receipt = Join-Path $jobRoot 'receipt.json'
    }
}

function Get-DirectPiSessionBindingPaths {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$SessionId)
    $sessionRoot = Join-Path $Root ('bindings\' + $SessionId)
    return [ordered]@{ root = $sessionRoot; binding = Join-Path $sessionRoot 'binding.json' }
}

function Start-DirectPiHost {
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
    if ($null -eq $process) { throw 'Direct PI host did not start.' }
    return $process
}

function Find-DirectPiHostOwner {
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
    if ($matches.Count -gt 1) { throw 'More than one Direct PI host matches this exact job.' }
    if ($matches.Count -eq 0) { return $null }
    $process = Get-Process -Id ([int]$matches[0].ProcessId) -ErrorAction Stop
    try {
        return [ordered]@{
            protocol_version = 'telephone-line-direct-pi-owner-v1'
            pid = [int]$process.Id
            start_time_utc_ticks = [int64]$process.StartTime.ToUniversalTime().Ticks
            started_at_utc = $process.StartTime.ToUniversalTime().ToString('o')
        }
    } finally { $process.Dispose() }
}

function New-DirectPiReceipt {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$RequestRead,
        [Collections.IDictionary]$Owner
    )
    $request = $RequestRead.value
    $piResult = $null
    $schemaError = $null
    try {
        if (-not [IO.File]::Exists($Paths.stdout)) { throw 'Direct PI terminal result is missing; owner is absent and terminal state is unknown.' }
        $resultRead = Read-DirectPiJson -Path $Paths.stdout
        $piResult = $resultRead.value
        Assert-DirectPiKeys -Value $piResult -Keys @(
            'protocol_version', 'job_id', 'success', 'error', 'workspace', 'prompt', 'provider', 'model',
            'thinking', 'session_id', 'session_path', 'resumed', 'pi_exit_code', 'stop_reason', 'assistant_text',
            'assistant_message', 'execution_count', 'event_count', 'agent_end_count', 'stderr_bytes', 'duration_ms'
        ) -Label 'Direct PI terminal result'
        if ($piResult.success -isnot [bool]) { throw 'Direct PI terminal success flag is malformed.' }
        if ([string]$piResult.protocol_version -cne 'telephone-line-direct-pi-result-v1') { throw 'Direct PI terminal protocol differs.' }
        if ([string]$piResult.job_id -cne [string]$request.job_id) { throw 'Direct PI terminal job differs.' }
        if ([string]$piResult.prompt.sha256 -cne [string]$request.prompt.sha256) { throw 'Direct PI terminal prompt differs.' }
        if ([string]$piResult.session_id -cne [string]$request.session_id -or [bool]$piResult.resumed -ne [bool]$request.resume) {
            throw 'Direct PI terminal session differs.'
        }
        if ([int]$piResult.execution_count -ne 1) { throw 'Direct PI terminal execution count differs.' }
        if ([bool]$piResult.success) {
            if ([string]::IsNullOrWhiteSpace([string]$piResult.session_path)) { throw 'Direct PI successful terminal has no exact session path.' }
        } else {
            $piResult.error = Get-DirectPiPublicError -Text ([string]$piResult.error)
        }
    } catch {
        $schemaError = Get-DirectPiPublicError -Text $_.Exception.Message
    }
    $transportComplete = $null -eq $schemaError -and $null -ne $piResult -and [bool]$piResult.success
    $receipt = [ordered]@{
        protocol_version = 'telephone-line-direct-pi-receipt-v1'
        job_id = [string]$request.job_id
        request = $RequestRead.identity
        transport_complete = [bool]$transportComplete
        transport_error = if ($null -ne $schemaError) { $schemaError } elseif ($null -ne $piResult -and -not [bool]$piResult.success) { Get-DirectPiPublicError -Text ([string]$piResult.error) } else { $null }
        pi_success = [bool]$transportComplete
        native_session_id = if ($null -ne $piResult -and -not [string]::IsNullOrWhiteSpace([string]$piResult.session_id)) { [string]$piResult.session_id } else { [string]$request.session_id }
        session_path = if ($null -ne $piResult) { [string]$piResult.session_path } else { '' }
        stop_reason = if ($null -ne $piResult) { [string]$piResult.stop_reason } else { '' }
        execution_count = if ($null -ne $piResult) { [int]$piResult.execution_count } else { 0 }
        terminal_result = if ([IO.File]::Exists($Paths.stdout)) { Get-DirectPiFileIdentity -Path $Paths.stdout } else { $null }
        owner = $Owner
        automatic_rerun = $false
        replacement_started = $false
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try { return Write-DirectPiJsonCreateNew -Path $Paths.receipt -Value $receipt }
    catch [IO.IOException] { return Get-DirectPiFileIdentity -Path $Paths.receipt }
}

function Wait-DirectPiJob {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][bool]$AllowStart
    )
    if (-not [IO.File]::Exists($Paths.request)) { throw 'Direct PI job has no immutable request; refusing to launch or replay.' }
    $requestRead = Read-DirectPiJson -Path $Paths.request
    $deadline = if ($TimeoutSeconds -gt 0) { [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds) } else { $null }
    while ($true) {
        if ([IO.File]::Exists($Paths.receipt)) {
            $receiptRead = Read-DirectPiJson -Path $Paths.receipt
            if ([string]$receiptRead.value.job_id -cne [string]$requestRead.value.job_id) { throw 'Direct PI receipt belongs to another job.' }
            return $receiptRead
        }
        $owner = $null
        if ([IO.File]::Exists($Paths.owner)) { $owner = (Read-DirectPiJson -Path $Paths.owner).value }
        elseif ($AllowStart -and [IO.File]::Exists($Paths.config)) {
            $owner = Find-DirectPiHostOwner -ConfigPath $Paths.config
            if ($null -ne $owner) { try { $null = Write-DirectPiJsonCreateNew -Path $Paths.owner -Value $owner } catch [IO.IOException] { } }
        }
        if ($null -ne $owner -and (Test-DirectPiOwnerAlive -Owner $owner)) {
            if ($null -ne $deadline -and [DateTimeOffset]::UtcNow -ge $deadline) {
                return [ordered]@{ value = [ordered]@{ protocol_version = 'telephone-line-direct-pi-status-v1'; job_id = [string]$requestRead.value.job_id; state = 'running'; owner = $owner; automatic_rerun = $false; replacement_started = $false }; identity = $null }
            }
            Start-Sleep -Milliseconds 500
            continue
        }
        Start-Sleep -Milliseconds 200
        $null = New-DirectPiReceipt -Paths $Paths -RequestRead $requestRead -Owner $owner
        return Read-DirectPiJson -Path $Paths.receipt
    }
}

function Write-DirectPiAdapterResult {
    param([Parameter(Mandatory = $true)][string]$Op, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SessionId, [Parameter(Mandatory = $true)][object]$Terminal)
    [ordered]@{
        protocol_version = 'telephone-line-adapter-result-v1'
        route_id = 'direct-pi'
        operation = $Op
        native_session_id = $SessionId
        job_id = [string]$Terminal.value.job_id
        session_path = if ($null -ne $Terminal.value.session_path) { [string]$Terminal.value.session_path } else { '' }
        automatic_rerun = $false
        replacement_started = $false
        transport_complete = if ($null -ne $Terminal.value.transport_complete) { [bool]$Terminal.value.transport_complete } else { $false }
        receipt = $Terminal.identity
    } | ConvertTo-Json -Depth 16
}

$adapterRoot = Get-DirectPiCanonicalDirectory -Path $PSScriptRoot
$state = Get-DirectPiCanonicalDirectory -Path $StateRoot
[IO.Directory]::CreateDirectory($state) | Out-Null
$sessionDir = Get-DirectPiCanonicalDirectory -Path (Join-Path $state 'sessions')
[IO.Directory]::CreateDirectory($sessionDir) | Out-Null

if ($Operation -eq 'start' -and -not [string]::IsNullOrWhiteSpace($NativeSessionId)) { throw 'Adapter start must not receive a native session id.' }
if ($Operation -ne 'start' -and [string]::IsNullOrWhiteSpace($NativeSessionId)) { throw 'Adapter native session id is required.' }
if ($Operation -ne 'start' -and $NativeSessionId -cnotmatch '^[A-Za-z0-9._:-]+$') { throw 'Adapter native session id is malformed.' }

if ($Operation -eq 'recover') {
    $bindingPaths = Get-DirectPiSessionBindingPaths -Root $state -SessionId $NativeSessionId
    if (-not [IO.File]::Exists($bindingPaths.binding)) { throw 'Adapter native session id is missing or unknown.' }
    $binding = (Read-DirectPiJson -Path $bindingPaths.binding).value
    if ([string]$binding.native_session_id -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
    $paths = Get-DirectPiJobPaths -Root $state -Id ([string]$binding.latest_job_id)
    $waited = Wait-DirectPiJob -Paths $paths -TimeoutSeconds $WaitTimeoutSeconds -AllowStart $false
    Write-DirectPiAdapterResult -Op 'recover' -SessionId $NativeSessionId -Terminal $waited
    if ([string]$waited.value.protocol_version -ceq 'telephone-line-direct-pi-status-v1') { exit 3 }
    if ([bool]$waited.value.transport_complete) { exit 0 }
    exit 4
}

if ([string]::IsNullOrWhiteSpace($WorkspacePath) -or [string]::IsNullOrWhiteSpace($PromptFile)) {
    throw 'Direct PI start and follow-up require workspace and prompt identities.'
}

$job = if ([string]::IsNullOrWhiteSpace($JobId)) { [Guid]::NewGuid().ToString('D') } else { $JobId }
$paths = Get-DirectPiJobPaths -Root $state -Id $job
if ([IO.Directory]::Exists($paths.root)) {
    $existing = Read-DirectPiJson -Path $paths.request
    if ($Operation -eq 'follow_up' -and [string]$existing.value.session_id -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
    $waited = Wait-DirectPiJob -Paths $paths -TimeoutSeconds $WaitTimeoutSeconds -AllowStart $false
    Write-DirectPiAdapterResult -Op $Operation -SessionId ([string]$existing.value.session_id) -Terminal $waited
    if ([string]$waited.value.protocol_version -ceq 'telephone-line-direct-pi-status-v1') { exit 3 }
    if ([bool]$waited.value.transport_complete) { exit 0 }
    exit 4
}

$workspace = Get-DirectPiCanonicalDirectory -Path $WorkspacePath
$sourcePrompt = Get-DirectPiFileIdentity -Path $PromptFile
$mockMode = -not [string]::IsNullOrWhiteSpace($MockCliPath)
$sessionId = if ($Operation -eq 'follow_up') { $NativeSessionId } else { [Guid]::NewGuid().ToString('D') }
$sessionPath = ''
if ($Operation -eq 'follow_up') {
    $bindingPaths = Get-DirectPiSessionBindingPaths -Root $state -SessionId $NativeSessionId
    if (-not [IO.File]::Exists($bindingPaths.binding)) { throw 'Adapter native session id is missing or unknown.' }
    $binding = (Read-DirectPiJson -Path $bindingPaths.binding).value
    if ([string]$binding.native_session_id -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
    $sessionPath = if (-not [string]::IsNullOrWhiteSpace($ResumeSessionPath)) { [IO.Path]::GetFullPath($ResumeSessionPath) } else { [string]$binding.session_path }
    if ([string]::IsNullOrWhiteSpace($sessionPath)) { throw 'Direct PI follow-up requires the exact session file path.' }
}

[IO.Directory]::CreateDirectory($paths.root) | Out-Null
$cliPath = if ($mockMode) { [IO.Path]::GetFullPath($MockCliPath) } else { Resolve-DirectPiCliCommand -PiCliPath $PiCliPath }
$launchKind = Get-DirectPiLaunchKind -CliPath $cliPath -MockMode $mockMode
$nodeResolved = Resolve-DirectPiLaunchHost -CliPath $cliPath -Kind $launchKind -NodePath $NodePath
$cliIdentity = Get-DirectPiFileIdentity -Path $cliPath
$nodeIdentity = Get-DirectPiFileIdentity -Path $nodeResolved
$wrapperIdentity = Get-DirectPiFileIdentity -Path (Join-Path $adapterRoot 'invoke_pi.ps1')
$request = [ordered]@{
    protocol_version = 'telephone-line-direct-pi-request-v1'
    job_id = $job
    workspace = $workspace
    prompt = $sourcePrompt
    provider = 'xai'
    model = 'grok-4.6'
    thinking = 'xhigh'
    session_id = $sessionId
    session_path = $sessionPath
    resume = ($Operation -eq 'follow_up')
    session_dir = $sessionDir
    timeout_seconds = $PiTimeoutSeconds
    max_output_bytes = $MaxOutputBytes
    node = $nodeIdentity
    cli = $cliIdentity
    wrapper = $wrapperIdentity
    mock_mode = [bool]$mockMode
    execution_count = 1
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}
$requestIdentity = Write-DirectPiJsonCreateNew -Path $paths.request -Value $request
$powerShellPath = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$hostScript = Get-DirectPiFileIdentity -Path (Join-Path $adapterRoot 'process_file_host.ps1')
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
$configIdentity = Write-DirectPiJsonCreateNew -Path $paths.config -Value $hostConfig
$null = Write-DirectPiJsonCreateNew -Path $paths.intent -Value ([ordered]@{
    protocol_version = 'telephone-line-direct-pi-launch-v1'
    job_id = $job
    request = $requestIdentity
    config = $configIdentity
    host = $hostScript
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    automatic_rerun = $false
})
$process = Start-DirectPiHost -PowerShellPath $powerShellPath -HostScript ([string]$hostScript.path) -ConfigPath ([string]$configIdentity.path)
try {
    $owner = [ordered]@{
        protocol_version = 'telephone-line-direct-pi-owner-v1'
        pid = [int]$process.Id
        start_time_utc_ticks = [int64]$process.StartTime.ToUniversalTime().Ticks
        started_at_utc = $process.StartTime.ToUniversalTime().ToString('o')
    }
    try { $null = Write-DirectPiJsonCreateNew -Path $paths.owner -Value $owner } catch [IO.IOException] { }
} finally { $process.Dispose() }

$waited = Wait-DirectPiJob -Paths $paths -TimeoutSeconds $WaitTimeoutSeconds -AllowStart $true
$returnedSession = if ($null -ne $waited.value.native_session_id) { [string]$waited.value.native_session_id } else { $sessionId }
if ($Operation -eq 'follow_up' -and $returnedSession -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
if ([bool]$waited.value.transport_complete) {
    $bindingPaths = Get-DirectPiSessionBindingPaths -Root $state -SessionId $returnedSession
    $bindingValue = [ordered]@{
        protocol_version = 'telephone-line-direct-pi-binding-v1'
        native_session_id = $returnedSession
        latest_job_id = $job
        session_path = [string]$waited.value.session_path
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if (-not [IO.File]::Exists($bindingPaths.binding)) {
        $null = Write-DirectPiJsonCreateNew -Path $bindingPaths.binding -Value $bindingValue
    } else {
        [IO.File]::WriteAllBytes($bindingPaths.binding, [Text.UTF8Encoding]::new($false).GetBytes((($bindingValue | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n")))
    }
}
Write-DirectPiAdapterResult -Op $Operation -SessionId $returnedSession -Terminal $waited
if ([string]$waited.value.protocol_version -ceq 'telephone-line-direct-pi-status-v1') { exit 3 }
if ([bool]$waited.value.transport_complete) { exit 0 }
exit 4

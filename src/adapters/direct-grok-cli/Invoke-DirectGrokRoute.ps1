# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('start', 'follow_up', 'recover')][string]$Operation,
    [string]$NativeSessionId,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [string]$WorkspacePath,
    [string]$PromptFile,
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$JobId,
    [ValidateRange(0, 2147483647)][int]$GrokTimeoutSeconds = 0,
    [ValidateRange(0, 2147483647)][int]$WaitTimeoutSeconds = 0,
    [ValidateRange(65536, 67108864)][int]$MaxOutputBytes = 16777216,
    [string]$GrokCommand
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }
. (Join-Path $PSScriptRoot 'DirectGrok.Common.ps1')

function Get-DirectGrokJobPaths {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Id)
    $jobRoot = Join-Path $Root ('jobs\' + $Id)
    return [ordered]@{
        root = $jobRoot
        request = Join-Path $jobRoot 'request.json'
        config = Join-Path $jobRoot 'host-config.json'
        intent = Join-Path $jobRoot 'launch-intent.json'
        owner = Join-Path $jobRoot 'owner.json'
        stdout = Join-Path $jobRoot 'grok-result.json'
        stderr = Join-Path $jobRoot 'wrapper-stderr.txt'
        receipt = Join-Path $jobRoot 'receipt.json'
        cli_stdout = Join-Path $jobRoot 'cli-stdout.json'
        checkpoint = Join-Path $jobRoot 'completion-checkpoint.json'
        session_proof = Join-Path $jobRoot 'session-proof.json'
    }
}

function Get-DirectGrokSessionPaths {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$SessionId)
    $sessionRoot = Join-Path $Root ('sessions\' + $SessionId)
    return [ordered]@{
        root = $sessionRoot
        binding = Join-Path $sessionRoot 'binding.json'
        occupancy = Join-Path $sessionRoot 'write-occupancy.json'
    }
}

function Start-DirectGrokHost {
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$HostScript,
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )
    Disable-DirectGrokStandardHandleInheritance
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $PowerShellPath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $HostScript, '-ConfigPath', $ConfigPath)) {
        [void]$info.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($info)
    if ($null -eq $process) { throw 'Direct Grok host did not start.' }
    return $process
}

function Find-DirectGrokHostOwner {
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
    if ($matches.Count -gt 1) { throw 'More than one Direct Grok host matches this exact job.' }
    if ($matches.Count -eq 0) { return $null }
    $process = Get-Process -Id ([int]$matches[0].ProcessId) -ErrorAction Stop
    try {
        return [ordered]@{
            protocol_version = 'telephone-line-direct-grok-owner-v1'
            pid = [int]$process.Id
            start_time_utc_ticks = [int64]$process.StartTime.ToUniversalTime().Ticks
            started_at_utc = $process.StartTime.ToUniversalTime().ToString('o')
        }
    } finally { $process.Dispose() }
}

function Get-DirectGrokStateRootFromJobPaths {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Paths)
    $jobRoot = [IO.Path]::GetFullPath([string]$Paths.root).TrimEnd('\')
    $jobsDir = [IO.Path]::GetDirectoryName($jobRoot)
    return [IO.Path]::GetDirectoryName($jobsDir)
}

function Test-DirectGrokExactOwnerFileAlive {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $false }
    try {
        $owner = (Read-DirectGrokJson -Path $Path).value
        return Test-DirectGrokOwnerAlive -Owner $owner
    } catch {
        return $false
    }
}

function Test-DirectGrokJobWriteLive {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Paths)
    $artifacts = Get-DirectGrokJobArtifactPaths -JobRoot ([string]$Paths.root)
    if (Test-DirectGrokExactOwnerFileAlive -Path ([string]$artifacts.grok_child_owner)) { return $true }
    if (Test-DirectGrokExactOwnerFileAlive -Path ([string]$Paths.owner)) { return $true }
    if ([IO.File]::Exists([string]$Paths.receipt)) { return $false }
    if ([IO.File]::Exists([string]$Paths.config)) {
        try {
            $found = Find-DirectGrokHostOwner -ConfigPath ([string]$Paths.config)
            if ($null -ne $found) { return $true }
        } catch { }
    }
    return $false
}

function Get-DirectGrokSessionLiveWriteJobId {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$SessionPaths
    )
    $occupancyPath = [string]$SessionPaths.occupancy
    $occJob = ''
    $occYoung = $false
    if ([IO.File]::Exists($occupancyPath)) {
        try {
            $occ = (Read-DirectGrokJson -Path $occupancyPath).value
            $occJob = [string]$occ.job_id
            if ($occ.Contains('created_at_utc') -and (Test-DirectGrokRoundTripTimestamp -Value ([string]$occ.created_at_utc))) {
                $created = [DateTimeOffset]::ParseExact(
                    [string]$occ.created_at_utc,
                    'o',
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                )
                $occYoung = ([DateTimeOffset]::UtcNow - $created).TotalSeconds -lt 5
            }
        } catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($occJob)) {
        $paths = Get-DirectGrokJobPaths -Root $State -Id $occJob
        if (-not [IO.Directory]::Exists([string]$paths.root)) {
            if ($occYoung) { return $occJob }
            try { [IO.File]::Delete($occupancyPath) } catch { }
        } elseif ((Test-DirectGrokJobWriteLive -Paths $paths) -or $occYoung) {
            return $occJob
        } else {
            try { [IO.File]::Delete($occupancyPath) } catch { }
        }
    }
    if ([IO.File]::Exists([string]$SessionPaths.binding)) {
        try {
            $binding = (Read-DirectGrokJson -Path ([string]$SessionPaths.binding)).value
            $latest = [string]$binding.latest_job_id
            if (-not [string]::IsNullOrWhiteSpace($latest)) {
                $latestPaths = Get-DirectGrokJobPaths -Root $State -Id $latest
                if ([IO.Directory]::Exists([string]$latestPaths.root) -and (Test-DirectGrokJobWriteLive -Paths $latestPaths)) {
                    return $latest
                }
            }
        } catch { }
    }
    return ''
}

function New-DirectGrokSessionWriteOccupancy {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$SessionPaths,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$JobId
    )
    [IO.Directory]::CreateDirectory([string]$SessionPaths.root) | Out-Null
    try {
        $null = Write-DirectGrokJsonCreateNew -Path ([string]$SessionPaths.occupancy) -Value ([ordered]@{
            protocol_version = 'telephone-line-direct-grok-write-occupancy-v1'
            native_session_id = [string]$SessionId
            job_id = [string]$JobId
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            automatic_rerun = $false
            replacement_started = $false
        })
        return $true
    } catch [IO.IOException] {
        return $false
    }
}

function Release-DirectGrokSessionWriteOccupancy {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$SessionPaths,
        [Parameter(Mandatory = $true)][string]$JobId
    )
    $path = [string]$SessionPaths.occupancy
    if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.File]::Exists($path)) { return }
    try {
        $occ = (Read-DirectGrokJson -Path $path).value
        if ([string]$occ.job_id -cne [string]$JobId) { return }
        [IO.File]::Delete($path)
    } catch { }
}

function Complete-DirectGrokJobWriteTurn {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Request
    )
    if (Test-DirectGrokJobWriteLive -Paths $Paths) { return }
    $state = Get-DirectGrokStateRootFromJobPaths -Paths $Paths
    $sessionId = [string]$Request.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { return }
    $sessionPaths = Get-DirectGrokSessionPaths -Root $state -SessionId $sessionId
    Release-DirectGrokSessionWriteOccupancy -SessionPaths $sessionPaths -JobId ([string]$Request.job_id)
}

function Assert-DirectGrokBindingComplete {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Binding,
        [Parameter(Mandatory = $true)][string]$SessionId
    )
    if ($Binding -isnot [Collections.IDictionary]) { throw 'Adapter native session id is missing or unknown.' }
    Assert-DirectGrokKeys -Value $Binding -Keys @('protocol_version', 'native_session_id', 'latest_job_id', 'created_at_utc') -Label 'Direct Grok binding'
    if ([string]$Binding.protocol_version -cne 'telephone-line-direct-grok-binding-v1') { throw 'Adapter native session id is missing or unknown.' }
    if ([string]$Binding.native_session_id -cne [string]$SessionId) { throw 'Adapter native session id does not match the frozen session.' }
    if ([string]$Binding.latest_job_id -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'Adapter durable state was not found.' }
}

function Set-DirectGrokBindingLatestJob {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$SessionPaths,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$JobId
    )
    if (-not [IO.File]::Exists([string]$SessionPaths.occupancy)) { return $null }
    try {
        $occ = (Read-DirectGrokJson -Path ([string]$SessionPaths.occupancy)).value
        if ([string]$occ.job_id -cne [string]$JobId) { return $null }
        if ([string]$occ.native_session_id -cne [string]$SessionId) { return $null }
    } catch {
        return $null
    }
    if (-not [IO.File]::Exists([string]$SessionPaths.binding)) { throw 'Adapter native session id is missing or unknown.' }
    $read = Read-DirectGrokJson -Path ([string]$SessionPaths.binding)
    Assert-DirectGrokBindingComplete -Binding $read.value -SessionId $SessionId
    if ([string]$read.value.latest_job_id -ceq [string]$JobId) { return $read.identity }
    $next = [ordered]@{
        protocol_version = 'telephone-line-direct-grok-binding-v1'
        native_session_id = [string]$SessionId
        latest_job_id = [string]$JobId
        created_at_utc = [string]$read.value.created_at_utc
    }
    return Write-DirectGrokJsonReplace -Path ([string]$SessionPaths.binding) -Value $next
}

function New-DirectGrokRunningStatus {
    param(
        [Parameter(Mandatory = $true)][string]$JobId,
        [Collections.IDictionary]$Owner
    )
    return [ordered]@{
        value = [ordered]@{
            protocol_version = 'telephone-line-direct-grok-status-v1'
            job_id = [string]$JobId
            state = 'running'
            owner = $Owner
            automatic_rerun = $false
            replacement_started = $false
        }
        identity = $null
    }
}

function Enter-DirectGrokSessionWriteTurn {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$SessionPaths,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][int]$WaitTimeoutSeconds
    )
    $deadline = if ($WaitTimeoutSeconds -gt 0) { [DateTimeOffset]::UtcNow.AddSeconds($WaitTimeoutSeconds) } else { $null }
    while ($true) {
        $liveJobId = Get-DirectGrokSessionLiveWriteJobId -State $State -SessionPaths $SessionPaths
        if ([string]::IsNullOrWhiteSpace($liveJobId) -or $liveJobId -ceq $JobId) {
            if (New-DirectGrokSessionWriteOccupancy -SessionPaths $SessionPaths -SessionId $SessionId -JobId $JobId) {
                return [ordered]@{ acquired = $true; terminal = $null }
            }
            Start-Sleep -Milliseconds 200
            continue
        }
        $livePaths = Get-DirectGrokJobPaths -Root $State -Id $liveJobId
        if (-not [IO.Directory]::Exists([string]$livePaths.root)) {
            if ($null -ne $deadline -and [DateTimeOffset]::UtcNow -ge $deadline) {
                return [ordered]@{ acquired = $false; terminal = (New-DirectGrokRunningStatus -JobId $liveJobId -Owner $null) }
            }
            Start-Sleep -Milliseconds 200
            continue
        }
        $remaining = 0
        if ($null -ne $deadline) {
            $remaining = [int][Math]::Max(0, [Math]::Ceiling(($deadline - [DateTimeOffset]::UtcNow).TotalSeconds))
            if ($remaining -le 0) {
                $owner = $null
                if ([IO.File]::Exists([string]$livePaths.owner)) {
                    try { $owner = (Read-DirectGrokJson -Path ([string]$livePaths.owner)).value } catch { }
                }
                return [ordered]@{ acquired = $false; terminal = (New-DirectGrokRunningStatus -JobId $liveJobId -Owner $owner) }
            }
        }
        $waited = Wait-DirectGrokJob -Paths $livePaths -TimeoutSeconds $remaining -AllowStart $false
        if ([string]$waited.value.protocol_version -ceq 'telephone-line-direct-grok-status-v1') {
            return [ordered]@{ acquired = $false; terminal = $waited }
        }
        while (Test-DirectGrokJobWriteLive -Paths $livePaths) {
            if ($null -ne $deadline -and [DateTimeOffset]::UtcNow -ge $deadline) {
                $stillOwner = $null
                if ([IO.File]::Exists([string]$livePaths.owner)) {
                    try { $stillOwner = (Read-DirectGrokJson -Path ([string]$livePaths.owner)).value } catch { }
                }
                return [ordered]@{ acquired = $false; terminal = (New-DirectGrokRunningStatus -JobId $liveJobId -Owner $stillOwner) }
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

function New-DirectGrokReceipt {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$RequestRead,
        [Collections.IDictionary]$Owner
    )
    $request = $RequestRead.value
    $grokResult = Resolve-DirectGrokDurableTerminal -Paths $Paths -Request $request
    $transportError = $null
    try {
        if ($null -eq $grokResult) { throw 'Direct Grok terminal result is missing.' }
        if (-not (Test-DirectGrokTerminalMatchesRequest -Request $request -Terminal $grokResult -CliStdoutPath ([string]$Paths.cli_stdout))) { throw 'Direct Grok terminal identity differs.' }
        if ([bool]$grokResult.success -ne $true) {
            if ($grokResult.Contains('error')) { $grokResult.error = Get-DirectGrokPublicError -Text ([string]$grokResult.error) }
            if ($grokResult.Contains('diagnostic')) { $grokResult.diagnostic = Get-DirectGrokPublicError -Text ([string]$grokResult.diagnostic) }
            $transportError = Get-DirectGrokPublicError -ErrorCode 'ADAPTER_TRANSPORT_FAILED'
        } else {
            $stdoutCandidate = Read-DirectGrokTerminalCandidate -Path $Paths.stdout
            $stdoutValid = $null -ne $stdoutCandidate -and (Test-DirectGrokTerminalMatchesRequest -Request $request -Terminal $stdoutCandidate -CliStdoutPath ([string]$Paths.cli_stdout)) -and [bool]$stdoutCandidate.success
            if (-not $stdoutValid) {
                try { $null = Write-DirectGrokJsonReplace -Path $Paths.stdout -Value $grokResult } catch [IO.IOException] { }
            }
        }
    } catch {
        $transportError = Get-DirectGrokPublicError -Text $_.Exception.Message
        $grokResult = $null
    }
    $transportComplete = $null -eq $transportError -and $null -ne $grokResult -and [bool]$grokResult.success
    $receipt = [ordered]@{
        protocol_version = 'telephone-line-direct-grok-receipt-v1'
        job_id = [string]$request.job_id
        request = $RequestRead.identity
        transport_complete = [bool]$transportComplete
        transport_error = $transportError
        grok_success = if ($null -ne $grokResult) { [bool]$grokResult.success } else { $null }
        native_session_id = if ($null -ne $grokResult) { [string]$grokResult.session_id } else { [string]$request.session_id }
        grok_result = $grokResult
        stdout = if ([IO.File]::Exists($Paths.stdout)) { try { Get-DirectGrokFileIdentity -Path $Paths.stdout } catch { $null } } else { $null }
        stderr = if ([IO.File]::Exists($Paths.stderr)) { try { Get-DirectGrokFileIdentity -Path $Paths.stderr } catch { $null } } else { $null }
        owner = $Owner
        automatic_rerun = $false
        replacement_started = $false
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try { return Write-DirectGrokJsonCreateNew -Path $Paths.receipt -Value $receipt }
    catch [IO.IOException] { return Get-DirectGrokFileIdentity -Path $Paths.receipt }
}

function Wait-DirectGrokJob {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][bool]$AllowStart
    )
    $requestRead = Read-DirectGrokJson -Path $Paths.request
    $deadline = if ($TimeoutSeconds -gt 0) { [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds) } else { $null }
    while ($true) {
        if ([IO.File]::Exists($Paths.receipt)) {
            $receiptRead = Read-DirectGrokJson -Path $Paths.receipt
            if ([string]$receiptRead.value.job_id -cne [string]$requestRead.value.job_id) { throw 'Direct Grok receipt belongs to another job.' }
            Assert-DirectGrokIdentity -Expected $requestRead.identity -Actual $receiptRead.value.request -Label 'Direct Grok receipt request'
            Complete-DirectGrokJobWriteTurn -Paths $Paths -Request $requestRead.value
            return $receiptRead
        }
        if (Test-DirectGrokBoundedStopFailureReady -Paths $Paths -Request $requestRead.value) {
            $ownerReady = $null
            if ([IO.File]::Exists($Paths.owner)) {
                try { $ownerReady = (Read-DirectGrokJson -Path $Paths.owner).value } catch { }
            }
            $null = New-DirectGrokReceipt -Paths $Paths -RequestRead $requestRead -Owner $ownerReady
            Complete-DirectGrokJobWriteTurn -Paths $Paths -Request $requestRead.value
            return Read-DirectGrokJson -Path $Paths.receipt
        }
        $owner = $null
        if ([IO.File]::Exists($Paths.owner)) { $owner = (Read-DirectGrokJson -Path $Paths.owner).value }
        elseif ($AllowStart -and [IO.File]::Exists($Paths.config)) {
            $owner = Find-DirectGrokHostOwner -ConfigPath $Paths.config
            if ($null -ne $owner) { try { $null = Write-DirectGrokJsonCreateNew -Path $Paths.owner -Value $owner } catch [IO.IOException] { } }
        }
        if ($null -ne $owner -and (Test-DirectGrokOwnerAlive -Owner $owner)) {
            if ($null -ne $deadline -and [DateTimeOffset]::UtcNow -ge $deadline) {
                return [ordered]@{ value = [ordered]@{ protocol_version = 'telephone-line-direct-grok-status-v1'; job_id = [string]$requestRead.value.job_id; state = 'running'; owner = $owner; automatic_rerun = $false; replacement_started = $false }; identity = $null }
            }
            Start-Sleep -Milliseconds 500
            continue
        }
        Start-Sleep -Milliseconds 200
        $null = New-DirectGrokReceipt -Paths $Paths -RequestRead $requestRead -Owner $owner
        Complete-DirectGrokJobWriteTurn -Paths $Paths -Request $requestRead.value
        return Read-DirectGrokJson -Path $Paths.receipt
    }
}

function Get-DirectGrokTerminalSessionId {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$TerminalValue,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Fallback
    )
    if (
        $TerminalValue -is [Collections.IDictionary] -and
        $TerminalValue.Contains('native_session_id') -and
        $null -ne $TerminalValue.native_session_id -and
        -not [string]::IsNullOrWhiteSpace([string]$TerminalValue.native_session_id)
    ) {
        return [string]$TerminalValue.native_session_id
    }
    return $Fallback
}

function Test-DirectGrokTerminalTransportComplete {
    param([Parameter(Mandatory = $true)][AllowNull()][object]$TerminalValue)
    return (
        $TerminalValue -is [Collections.IDictionary] -and
        $TerminalValue.Contains('transport_complete') -and
        $null -ne $TerminalValue.transport_complete -and
        [bool]$TerminalValue.transport_complete
    )
}

function Write-DirectGrokAdapterResult {
    param([Parameter(Mandatory = $true)][string]$Op, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SessionId, [Parameter(Mandatory = $true)][object]$Terminal)
    $terminalValue = $Terminal.value
    $transportComplete = Test-DirectGrokTerminalTransportComplete -TerminalValue $terminalValue
    [ordered]@{
        protocol_version = 'telephone-line-adapter-result-v1'
        route_id = 'direct-grok-cli'
        operation = $Op
        native_session_id = $SessionId
        job_id = [string]$terminalValue.job_id
        automatic_rerun = $false
        replacement_started = $false
        transport_complete = $transportComplete
        official_cli = $true
        receipt = $Terminal.identity
    } | ConvertTo-Json -Depth 16
}

$adapterRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$state = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
if (-not [IO.Directory]::Exists($state)) { [IO.Directory]::CreateDirectory($state) | Out-Null }

if ($Operation -eq 'start' -and -not [string]::IsNullOrWhiteSpace($NativeSessionId)) { throw 'Adapter start must not receive a native session id.' }
if ($Operation -eq 'follow_up' -and [string]::IsNullOrWhiteSpace($NativeSessionId)) { throw 'Adapter native session id is required.' }
if ($Operation -eq 'recover' -and [string]::IsNullOrWhiteSpace($NativeSessionId) -and [string]::IsNullOrWhiteSpace($JobId)) { throw 'Adapter native session id is required.' }
if (-not [string]::IsNullOrWhiteSpace($NativeSessionId) -and $NativeSessionId -cnotmatch '^[A-Za-z0-9._:-]+$') { throw 'Adapter native session id is malformed.' }

if ($Operation -eq 'recover') {
    $paths = $null
    $recoverSession = [string]$NativeSessionId
    if (-not [string]::IsNullOrWhiteSpace($JobId)) {
        $paths = Get-DirectGrokJobPaths -Root $state -Id $JobId
        if (-not [IO.Directory]::Exists($paths.root) -or -not [IO.File]::Exists($paths.request)) { throw 'Adapter durable state was not found.' }
        $recoverRequest = (Read-DirectGrokJson -Path $paths.request).value
        $recoverSession = [string]$recoverRequest.session_id
        if (-not [string]::IsNullOrWhiteSpace($NativeSessionId) -and $NativeSessionId -cne $recoverSession) {
            throw 'Adapter native session id does not match the frozen session.'
        }
    } else {
        $sessionPaths = Get-DirectGrokSessionPaths -Root $state -SessionId $NativeSessionId
        if (-not [IO.File]::Exists($sessionPaths.binding)) { throw 'Adapter native session id is missing or unknown.' }
        $binding = (Read-DirectGrokJson -Path $sessionPaths.binding).value
        Assert-DirectGrokBindingComplete -Binding $binding -SessionId $NativeSessionId
        $paths = Get-DirectGrokJobPaths -Root $state -Id ([string]$binding.latest_job_id)
    }
    if (-not [IO.Directory]::Exists($paths.root)) { throw 'Adapter durable state was not found.' }
    $waited = Wait-DirectGrokJob -Paths $paths -TimeoutSeconds $WaitTimeoutSeconds -AllowStart $false
    Write-DirectGrokAdapterResult -Op 'recover' -SessionId $recoverSession -Terminal $waited
    if ([string]$waited.value.protocol_version -ceq 'telephone-line-direct-grok-status-v1') { exit 3 }
    if (Test-DirectGrokTerminalTransportComplete -TerminalValue $waited.value) { exit 0 }
    exit 4
}

if ([string]::IsNullOrWhiteSpace($WorkspacePath) -or [string]::IsNullOrWhiteSpace($PromptFile)) {
    throw 'Direct Grok start and follow-up require workspace and prompt identities.'
}

$job = if ([string]::IsNullOrWhiteSpace($JobId)) { [Guid]::NewGuid().ToString('D') } else { $JobId }
$paths = Get-DirectGrokJobPaths -Root $state -Id $job
if ([IO.Directory]::Exists($paths.root)) {
    $existing = Read-DirectGrokJson -Path $paths.request
    if ($Operation -eq 'follow_up' -and [string]$existing.value.session_id -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
    $waited = Wait-DirectGrokJob -Paths $paths -TimeoutSeconds $WaitTimeoutSeconds -AllowStart $false
    $session = Get-DirectGrokTerminalSessionId -TerminalValue $waited.value -Fallback ([string]$existing.value.session_id)
    Write-DirectGrokAdapterResult -Op $Operation -SessionId $session -Terminal $waited
    if ([string]$waited.value.protocol_version -ceq 'telephone-line-direct-grok-status-v1') { exit 3 }
    if (Test-DirectGrokTerminalTransportComplete -TerminalValue $waited.value) { exit 0 }
    exit 4
}

$workspace = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd('\')
if (-not [IO.Directory]::Exists($workspace)) { throw 'Direct Grok workspace does not exist.' }
$promptIdentity = Get-DirectGrokFileIdentity -Path $PromptFile
$sessionId = if ($Operation -eq 'follow_up') { $NativeSessionId } else { [Guid]::NewGuid().ToString('D') }
if ($Operation -eq 'follow_up') {
    $sessionPaths = Get-DirectGrokSessionPaths -Root $state -SessionId $NativeSessionId
    if (-not [IO.File]::Exists($sessionPaths.binding)) { throw 'Adapter native session id is missing or unknown.' }
    $binding = (Read-DirectGrokJson -Path $sessionPaths.binding).value
    Assert-DirectGrokBindingComplete -Binding $binding -SessionId $NativeSessionId
    $entered = Enter-DirectGrokSessionWriteTurn -State $state -SessionPaths $sessionPaths -SessionId $NativeSessionId -JobId $job -WaitTimeoutSeconds $WaitTimeoutSeconds
    if (-not [bool]$entered.acquired) {
        $waited = $entered.terminal
        $busySession = $NativeSessionId
        Write-DirectGrokAdapterResult -Op $Operation -SessionId $busySession -Terminal $waited
        if ([string]$waited.value.protocol_version -ceq 'telephone-line-direct-grok-status-v1') { exit 3 }
        if (Test-DirectGrokTerminalTransportComplete -TerminalValue $waited.value) { exit 0 }
        exit 4
    }
}

$sessionWriteHeld = ($Operation -eq 'follow_up')
$hostStarted = $false
try {
[IO.Directory]::CreateDirectory($paths.root) | Out-Null
$wrapperIdentity = Get-DirectGrokFileIdentity -Path (Join-Path $adapterRoot 'invoke_grok_build.ps1')
$grokPath = Resolve-DirectGrokOfficialCommand -GrokCommand $GrokCommand
$grokIdentity = Get-DirectGrokFileIdentity -Path $grokPath
$request = [ordered]@{
    protocol_version = 'telephone-line-direct-grok-request-v1'
    job_id = $job
    workspace = $workspace
    prompt = $promptIdentity
    model = 'grok-4.6'
    reasoning_effort = 'xhigh'
    session_id = $sessionId
    resume = ($Operation -eq 'follow_up')
    timeout_seconds = $GrokTimeoutSeconds
    max_output_bytes = $MaxOutputBytes
    grok = $grokIdentity
    wrapper = $wrapperIdentity
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}
$requestIdentity = Write-DirectGrokJsonCreateNew -Path $paths.request -Value $request
if ($Operation -eq 'follow_up') {
    $null = Set-DirectGrokBindingLatestJob -SessionPaths $sessionPaths -SessionId $NativeSessionId -JobId $job
}
$powerShellPath = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$hostScript = Get-DirectGrokFileIdentity -Path (Join-Path $adapterRoot 'process_file_host.ps1')
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
$configIdentity = Write-DirectGrokJsonCreateNew -Path $paths.config -Value $hostConfig
$null = Write-DirectGrokJsonCreateNew -Path $paths.intent -Value ([ordered]@{
    protocol_version = 'telephone-line-direct-grok-launch-v1'
    job_id = $job
    request = $requestIdentity
    config = $configIdentity
    host = $hostScript
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    automatic_rerun = $false
})
$process = Start-DirectGrokHost -PowerShellPath $powerShellPath -HostScript ([string]$hostScript.path) -ConfigPath ([string]$configIdentity.path)
$hostStarted = $true
try {
    $owner = [ordered]@{
        protocol_version = 'telephone-line-direct-grok-owner-v1'
        pid = [int]$process.Id
        start_time_utc_ticks = [int64]$process.StartTime.ToUniversalTime().Ticks
        started_at_utc = $process.StartTime.ToUniversalTime().ToString('o')
    }
    try { $null = Write-DirectGrokJsonCreateNew -Path $paths.owner -Value $owner } catch [IO.IOException] { }
} finally { $process.Dispose() }
} finally {
    if ($sessionWriteHeld -and -not $hostStarted) {
        Release-DirectGrokSessionWriteOccupancy -SessionPaths $sessionPaths -JobId $job
    }
}

$waited = Wait-DirectGrokJob -Paths $paths -TimeoutSeconds $WaitTimeoutSeconds -AllowStart $true
$returnedSession = Get-DirectGrokTerminalSessionId -TerminalValue $waited.value -Fallback $sessionId
if ($Operation -eq 'follow_up' -and $returnedSession -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
$delayBindingMs = 0
if (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_TEST_DIRECT_GROK_DELAY_BINDING_MS)) {
    try { $delayBindingMs = [int]$env:TELEPHONE_TEST_DIRECT_GROK_DELAY_BINDING_MS } catch { $delayBindingMs = 0 }
}
if ($delayBindingMs -gt 0) { Start-Sleep -Milliseconds $delayBindingMs }
if ((Test-DirectGrokTerminalTransportComplete -TerminalValue $waited.value) -and -not [string]::IsNullOrWhiteSpace($returnedSession)) {
    $sessionPaths = Get-DirectGrokSessionPaths -Root $state -SessionId $returnedSession
    if (-not [IO.File]::Exists($sessionPaths.binding)) {
        $null = Write-DirectGrokJsonCreateNew -Path $sessionPaths.binding -Value ([ordered]@{
            protocol_version = 'telephone-line-direct-grok-binding-v1'
            native_session_id = $returnedSession
            latest_job_id = $job
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        })
    } else {
        $null = Set-DirectGrokBindingLatestJob -SessionPaths $sessionPaths -SessionId $returnedSession -JobId $job
    }
}
Write-DirectGrokAdapterResult -Op $Operation -SessionId $returnedSession -Terminal $waited
if ([string]$waited.value.protocol_version -ceq 'telephone-line-direct-grok-status-v1') { exit 3 }
if (Test-DirectGrokTerminalTransportComplete -TerminalValue $waited.value) { exit 0 }
exit 4

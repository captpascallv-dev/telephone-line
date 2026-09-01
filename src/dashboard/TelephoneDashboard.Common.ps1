# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest

$script:TelephoneDashboardDir = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$script:TelephoneDashboardProductRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$script:TelephoneDashboardEnsureOverrideName = 'TELEPHONE_LINE_DASHBOARD_ENSURE_SCRIPT'
$script:TelephoneDashboardOptOutName = 'TELEPHONE_LINE_DASHBOARD_OPT_OUT'
$script:TelephoneDashboardProcessEnvOnlyName = 'TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY'
$script:TelephoneDashboardStateName = 'TELEPHONE_LINE_DASHBOARD_STATE'
$script:TelephoneDashboardConfigName = 'TELEPHONE_LINE_DASHBOARD_CONFIG'
$script:TelephoneDashboardHeadlessName = 'TELEPHONE_LINE_DASHBOARD_HEADLESS'

if (-not (Get-Command -Name 'Get-TelephonePublicErrorMessage' -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '..\core\TelephoneLine.Common.ps1')
}
. (Join-Path $PSScriptRoot 'TelephoneDashboard.Reducer.ps1')

function Get-TelephoneDashboardEnvironmentValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$ProcessOnly
    )
    $targets = if ($ProcessOnly) {
        @([EnvironmentVariableTarget]::Process)
    } else {
        @([EnvironmentVariableTarget]::Process, [EnvironmentVariableTarget]::User, [EnvironmentVariableTarget]::Machine)
    }
    foreach ($target in $targets) {
        try { $candidate = [Environment]::GetEnvironmentVariable($Name, $target) } catch { $candidate = '' }
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            return [string]$candidate
        }
    }
    return ''
}

function Test-TelephoneDashboardProcessEnvOnly {
    [CmdletBinding()]
    param()
    $value = Get-TelephoneDashboardEnvironmentValue -Name $script:TelephoneDashboardProcessEnvOnlyName -ProcessOnly
    return (Test-TelephoneDashboardTruthy -Value $value)
}

function Test-TelephoneDashboardTruthy {
    [CmdletBinding()]
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $false }
    return ([string]$Value -match '^(?i:1|true|yes|on)$')
}

function Test-TelephoneDashboardOptOut {
    [CmdletBinding()]
    param()
    $processOnly = Test-TelephoneDashboardProcessEnvOnly
    $value = Get-TelephoneDashboardEnvironmentValue -Name $script:TelephoneDashboardOptOutName -ProcessOnly:$processOnly
    return (Test-TelephoneDashboardTruthy -Value $value)
}

function Get-TelephoneDashboardEnsureOverride {
    [CmdletBinding()]
    param()
    $processOnly = Test-TelephoneDashboardProcessEnvOnly
    return (Get-TelephoneDashboardEnvironmentValue -Name $script:TelephoneDashboardEnsureOverrideName -ProcessOnly:$processOnly)
}

function Get-TelephoneDashboardProductRoot {
    [CmdletBinding()]
    param()
    return $script:TelephoneDashboardProductRoot
}

function Get-TelephoneDashboardEnsureScriptPath {
    [CmdletBinding()]
    param()
    $path = Join-Path $script:TelephoneDashboardDir 'Ensure-TelephoneDashboard.ps1'
    return (Assert-TelephoneRegularFilePath -Path $path -Label 'Bundled dashboard ensure script')
}

function Get-TelephoneDashboardWatchScriptPath {
    [CmdletBinding()]
    param()
    $path = Join-Path $script:TelephoneDashboardDir 'Watch-TelephoneDashboard.ps1'
    return (Assert-TelephoneRegularFilePath -Path $path -Label 'Bundled dashboard watcher script')
}

function Get-TelephoneDashboardStateRoot {
    [CmdletBinding()]
    param()
    $configured = Get-TelephoneDashboardEnvironmentValue -Name $script:TelephoneDashboardStateName
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        $full = [IO.Path]::GetFullPath($configured).TrimEnd('\')
        if ($full.IndexOf('http:', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $full.IndexOf('https:', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw 'Dashboard state root must be a local directory.'
        }
        return $full
    }
    $local = [string]$env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($local)) {
        throw 'Dashboard state root is required. Set TELEPHONE_LINE_DASHBOARD_STATE.'
    }
    return [IO.Path]::GetFullPath((Join-Path $local 'TelephoneLine\dashboard-runtime')).TrimEnd('\')
}

function Get-TelephoneDashboardConfigPath {
    [CmdletBinding()]
    param()
    $configured = Get-TelephoneDashboardEnvironmentValue -Name $script:TelephoneDashboardConfigName
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        return [IO.Path]::GetFullPath($configured)
    }
    return (Join-Path (Get-TelephoneDashboardStateRoot) 'config.json')
}

function Get-TelephoneDashboardPaths {
    [CmdletBinding()]
    param([string]$StateRoot)
    $root = if ([string]::IsNullOrWhiteSpace($StateRoot)) {
        Get-TelephoneDashboardStateRoot
    } else {
        [IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
    }
    return [ordered]@{
        root = $root
        ensure_lock = Join-Path $root 'ensure.lock'
        watcher = Join-Path $root 'watcher.json'
        projection = Join-Path $root 'projection.json'
        summary = Join-Path $root 'summary.txt'
        config = Get-TelephoneDashboardConfigPath
    }
}

function Get-TelephoneDashboardProcessCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    try {
        $cim = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = " + [int]$ProcessId) -ErrorAction Stop
        return [string]$cim.CommandLine
    } catch {
        return ''
    }
}

function Get-TelephoneDashboardBuildIdentity {
    [CmdletBinding()]
    param([string]$InstallRoot)
    $root = if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        $script:TelephoneDashboardProductRoot
    } else {
        [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    }
    $files = @(
        'src\dashboard\Watch-TelephoneDashboard.ps1',
        'src\dashboard\Ensure-TelephoneDashboard.ps1',
        'src\dashboard\TelephoneDashboard.Common.ps1',
        'src\dashboard\TelephoneDashboard.Projection.ps1',
        'src\dashboard\TelephoneDashboard.Reducer.ps1'
    )
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($rel in $files) {
        $full = Join-Path $root $rel
        if (-not [IO.File]::Exists($full)) { continue }
        $bytes = [IO.File]::ReadAllBytes($full)
        $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        [void]$lines.Add(('{0}|{1}|{2}' -f $rel.Replace('\', '/'), [int64]$bytes.Length, $sha))
    }
    $text = [string]::Join("`n", $lines)
    return [ordered]@{
        install_root = $root
        package_version = '0.1.0'
        build_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($text))).ToLowerInvariant()
    }
}

function Test-TelephoneDashboardWatcherIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Identity,
        [Parameter(Mandatory = $true)][string]$WatchScript,
        [string]$InstallRoot,
        [switch]$RequireCommandLine
    )
    if ($Identity.Contains('retired') -and [bool]$Identity.retired) { return $false }
    if ($Identity.Contains('healthy') -and $null -ne $Identity.healthy -and [bool]$Identity.healthy -eq $false) { return $false }
    $pidValue = 0
    try { $pidValue = [int]$Identity.pid } catch { return $false }
    if ($pidValue -le 0) { return $false }
    if (-not (Test-TelephoneOwnerAlive -Owner $Identity)) { return $false }
    $watch = [IO.Path]::GetFullPath($WatchScript)
    $storedScript = ''
    if ($Identity.Contains('script_path')) { $storedScript = [string]$Identity.script_path }
    if (-not [string]::IsNullOrWhiteSpace($storedScript)) {
        try {
            if (-not [IO.Path]::GetFullPath($storedScript).Equals($watch, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        } catch {
            return $false
        }
    }
    $build = Get-TelephoneDashboardBuildIdentity -InstallRoot $InstallRoot
    $storedBuild = ''
    if ($Identity.Contains('build_sha256')) { $storedBuild = [string]$Identity.build_sha256 }
    if ([string]::IsNullOrWhiteSpace($storedBuild) -or $storedBuild -cne [string]$build.build_sha256) { return $false }
    $storedRoot = ''
    if ($Identity.Contains('install_root')) { $storedRoot = [string]$Identity.install_root }
    if (-not [string]::IsNullOrWhiteSpace($storedRoot)) {
        try {
            if (-not [IO.Path]::GetFullPath($storedRoot).TrimEnd('\').Equals([string]$build.install_root, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        } catch {
            return $false
        }
    }
    $command = Get-TelephoneDashboardProcessCommand -ProcessId $pidValue
    if (-not [string]::IsNullOrWhiteSpace($command)) {
        if ($command.IndexOf($watch, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
        return $true
    }
    if ($RequireCommandLine) { return $false }
    # Command line can be unavailable; PID+start plus durable script/package/install identity is the owner proof.
    return (-not [string]::IsNullOrWhiteSpace($storedScript) -and -not [string]::IsNullOrWhiteSpace($storedBuild))
}

function Read-TelephoneDashboardWatcherIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    try {
        return (Read-TelephoneJson -Path $Path).value
    } catch {
        return $null
    }
}

function Write-TelephoneDashboardWatcherIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Owner,
        [Parameter(Mandatory = $true)][string]$WatchScript
    )
    $build = Get-TelephoneDashboardBuildIdentity
    $value = [ordered]@{
        protocol_version = 'telephone-line-dashboard-watcher-v1'
        pid = [int]$Owner.pid
        start_time_utc_ticks = [int64]$Owner.start_time_utc_ticks
        started_at_utc = [string]$Owner.started_at_utc
        script_path = [IO.Path]::GetFullPath($WatchScript)
        install_root = [string]$build.install_root
        package_version = [string]$build.package_version
        build_sha256 = [string]$build.build_sha256
        observational = $true
    }
    return (Write-TelephoneJsonReplace -Path $Path -Value $value)
}

function Invalidate-TelephoneDashboardWatcherIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return }
    $existing = Read-TelephoneDashboardWatcherIdentity -Path $Path
    if ($null -eq $existing) {
        try { [IO.File]::Delete($Path) } catch { }
        return
    }
    $existing.retired = $true
    $existing.healthy = $false
    $existing.invalidated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    try {
        $null = Write-TelephoneJsonReplace -Path $Path -Value $existing
    } catch {
        try { [IO.File]::Delete($Path) } catch { }
    }
}

function New-TelephoneDashboardEnsureResult {
    [CmdletBinding()]
    param(
        [bool]$Configured = $false,
        [bool]$Attempted = $false,
        [bool]$Healthy = $true,
        [bool]$Started = $false,
        [bool]$AlreadyRunning = $false,
        [int]$WatcherPid = 0,
        [string]$ErrorCode = '',
        [string]$Source = ''
    )
    return [pscustomobject][ordered]@{
        configured = [bool]$Configured
        attempted = [bool]$Attempted
        healthy = [bool]$Healthy
        started = [bool]$Started
        already_running = [bool]$AlreadyRunning
        watcher_pid = [int]$WatcherPid
        error_code = [string]$ErrorCode
        source = [string]$Source
        observational = $true
    }
}

function Start-TelephoneDashboardWatcherProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WatchScript,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [string]$ConfigPath,
        [switch]$Headless
    )

    $pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.UseShellExecute = -not $Headless
    $info.CreateNoWindow = [bool]$Headless
    if ($Headless) {
        $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    } else {
        $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
    }
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $WatchScript, '-StateRoot', $StateRoot)) {
        [void]$arguments.Add([string]$argument)
    }
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        [void]$arguments.Add('-ConfigPath')
        [void]$arguments.Add([string]$ConfigPath)
    }
    if ($Headless) { [void]$arguments.Add('-Headless') }
    foreach ($argument in $arguments) {
        [void]$info.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::Start($info)
    if ($null -eq $process) { throw 'DASHBOARD_ENSURE_FAILED' }
    try {
        return [ordered]@{
            pid = [int]$process.Id
            start_time_utc_ticks = [int64]$process.StartTime.ToUniversalTime().Ticks
            started_at_utc = $process.StartTime.ToUniversalTime().ToString('o')
        }
    } finally {
        $process.Dispose()
    }
}

function Stop-TelephoneDashboardExactWatcher {
    [CmdletBinding()]
    param(
        [string]$InstallRoot,
        [string]$WatchScript,
        [string]$StateRoot,
        [switch]$AllowIncompatibleBuild
    )

    $stopped = [Collections.Generic.List[object]]::new()
    $refused = [Collections.Generic.List[object]]::new()
    $watch = $WatchScript
    if ([string]::IsNullOrWhiteSpace($watch) -and -not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        $fromInstall = Join-Path $InstallRoot 'src\dashboard\Watch-TelephoneDashboard.ps1'
        if ([IO.File]::Exists($fromInstall)) { $watch = [IO.Path]::GetFullPath($fromInstall) }
    }
    if ([string]::IsNullOrWhiteSpace($watch)) {
        try { $watch = Get-TelephoneDashboardWatchScriptPath } catch { $watch = '' }
    }
    $paths = $null
    try {
        $paths = Get-TelephoneDashboardPaths -StateRoot $StateRoot
    } catch {
        $paths = $null
    }
    $identity = $null
    if ($null -ne $paths) {
        $identity = Read-TelephoneDashboardWatcherIdentity -Path ([string]$paths.watcher)
    }
    if ($null -ne $identity) {
        $pidValue = 0
        try { $pidValue = [int]$identity.pid } catch { $pidValue = 0 }
        $alive = Test-TelephoneOwnerAlive -Owner $identity
        $matches = $false
        if ($alive -and $pidValue -gt 0 -and -not [string]::IsNullOrWhiteSpace($watch)) {
            $matches = Test-TelephoneDashboardWatcherIdentity -Identity $identity -WatchScript $watch -InstallRoot $InstallRoot
            if (-not $matches) {
                # Command line may be hidden; PID+start plus durable identity still owns the process.
                $matches = (Test-TelephoneOwnerAlive -Owner $identity)
                $storedScript = if ($identity.Contains('script_path')) { [string]$identity.script_path } else { '' }
                if ($matches -and -not [string]::IsNullOrWhiteSpace($storedScript)) {
                    try {
                        $matches = [IO.Path]::GetFullPath($storedScript).Equals([IO.Path]::GetFullPath($watch), [StringComparison]::OrdinalIgnoreCase)
                    } catch { $matches = $false }
                }
                $liveCommand = Get-TelephoneDashboardProcessCommand -ProcessId $pidValue
                if ($matches -and -not [string]::IsNullOrWhiteSpace($liveCommand) -and $liveCommand.IndexOf($watch, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    $matches = $false
                }
                $storedBuild = if ($identity.Contains('build_sha256')) { [string]$identity.build_sha256 } else { '' }
                if ($matches -and -not [string]::IsNullOrWhiteSpace($storedBuild) -and -not $AllowIncompatibleBuild) {
                    $build = Get-TelephoneDashboardBuildIdentity -InstallRoot $InstallRoot
                    if ($storedBuild -cne [string]$build.build_sha256) { $matches = $false }
                }
            }
        }
        if ($pidValue -gt 0 -and $alive -and $matches) {
            try {
                Stop-Process -Id $pidValue -Force -ErrorAction Stop
                $stopped.Add([ordered]@{ pid = $pidValue; start_time_utc_ticks = [int64]$identity.start_time_utc_ticks })
            } catch {
                $refused.Add([ordered]@{ pid = $pidValue; reason = 'stop-failed' })
            }
        } elseif ($pidValue -gt 0 -and $alive -and -not $matches) {
            $refused.Add([ordered]@{ pid = $pidValue; reason = 'identity-mismatch' })
        }
        if ($null -ne $paths -and [IO.File]::Exists([string]$paths.watcher)) {
            try { [IO.File]::Delete([string]$paths.watcher) } catch { }
        }
        return [ordered]@{ stopped = @($stopped); refused = @($refused) }
    }

    $refused.Add([ordered]@{ pid = 0; reason = 'durable-identity-missing' })
    return [ordered]@{ stopped = @($stopped); refused = @($refused) }
}

function Invoke-TelephoneBundledDashboardEnsure {
    [CmdletBinding()]
    param()

    $watchScript = Get-TelephoneDashboardWatchScriptPath
    $stateRoot = Get-TelephoneDashboardStateRoot
    $stateSafety = Test-TelephoneCompletePathChain -Path $stateRoot -AllowMissing -Label 'Dashboard state root'
    if (-not [bool]$stateSafety.ok) {
        return (New-TelephoneDashboardEnsureResult -Configured $true -Attempted $true -Healthy $false -ErrorCode 'DASHBOARD_ENSURE_FAILED' -Source 'bundled')
    }
    [IO.Directory]::CreateDirectory([string]$stateSafety.path) | Out-Null
    $paths = Get-TelephoneDashboardPaths -StateRoot ([string]$stateSafety.path)
    foreach ($writePath in @([string]$paths.ensure_lock, [string]$paths.watcher, [string]$paths.projection, [string]$paths.summary)) {
        $writeSafety = Test-TelephoneCompletePathChain -Path $writePath -Root ([string]$stateSafety.path) -AllowMissing -Label 'Dashboard runtime file'
        if (-not [bool]$writeSafety.ok) {
            return (New-TelephoneDashboardEnsureResult -Configured $true -Attempted $true -Healthy $false -ErrorCode 'DASHBOARD_ENSURE_FAILED' -Source 'bundled')
        }
    }
    $headless = Test-TelephoneDashboardTruthy -Value (Get-TelephoneDashboardEnvironmentValue -Name $script:TelephoneDashboardHeadlessName -ProcessOnly)
    $gate = Open-TelephoneExclusiveGate -Path $paths.ensure_lock -WaitMilliseconds 5000
    if ($null -eq $gate) {
        return (New-TelephoneDashboardEnsureResult -Configured $true -Attempted $true -Healthy $false -ErrorCode 'DASHBOARD_ENSURE_FAILED' -Source 'bundled')
    }
    try {
        $existing = Read-TelephoneDashboardWatcherIdentity -Path $paths.watcher
        if ($null -ne $existing -and (Test-TelephoneDashboardWatcherIdentity -Identity $existing -WatchScript $watchScript)) {
            return (New-TelephoneDashboardEnsureResult -Configured $true -Attempted $true -Healthy $true -AlreadyRunning $true -WatcherPid ([int]$existing.pid) -Source 'bundled')
        }
        if ($null -ne $existing -and (Test-TelephoneOwnerAlive -Owner $existing)) {
            $cmd = Get-TelephoneDashboardProcessCommand -ProcessId ([int]$existing.pid)
            $ours = $false
            if ([string]::IsNullOrWhiteSpace($cmd)) {
                $stored = if ($existing.Contains('script_path')) { [string]$existing.script_path } else { '' }
                if (-not [string]::IsNullOrWhiteSpace($stored)) {
                    try { $ours = [IO.Path]::GetFullPath($stored).Equals($watchScript, [StringComparison]::OrdinalIgnoreCase) } catch { $ours = $false }
                }
            } else {
                $ours = ($cmd.IndexOf($watchScript, [StringComparison]::OrdinalIgnoreCase) -ge 0)
            }
            if ($ours) {
                $null = Stop-TelephoneDashboardExactWatcher -WatchScript $watchScript -StateRoot $stateRoot -AllowIncompatibleBuild
            }
        }
        $owner = Start-TelephoneDashboardWatcherProcess -WatchScript $watchScript -StateRoot $stateRoot -ConfigPath $paths.config -Headless:$headless
        $null = Write-TelephoneDashboardWatcherIdentity -Path $paths.watcher -Owner $owner -WatchScript $watchScript
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
        $ready = $false
        while ([DateTimeOffset]::UtcNow -lt $deadline) {
            $written = Read-TelephoneDashboardWatcherIdentity -Path $paths.watcher
            if ($null -ne $written -and (Test-TelephoneDashboardWatcherIdentity -Identity $written -WatchScript $watchScript)) {
                $owner = $written
                $ready = $true
                break
            }
            Start-Sleep -Milliseconds 50
        }
        if (-not $ready -or -not (Test-TelephoneDashboardWatcherIdentity -Identity $owner -WatchScript $watchScript)) {
            return (New-TelephoneDashboardEnsureResult -Configured $true -Attempted $true -Healthy $false -ErrorCode 'DASHBOARD_ENSURE_FAILED' -Source 'bundled')
        }
        return (New-TelephoneDashboardEnsureResult -Configured $true -Attempted $true -Healthy $true -Started $true -WatcherPid ([int]$owner.pid) -Source 'bundled')
    } catch {
        return (New-TelephoneDashboardEnsureResult -Configured $true -Attempted $true -Healthy $false -ErrorCode 'DASHBOARD_ENSURE_FAILED' -Source 'bundled')
    } finally {
        $gate.Dispose()
    }
}

function Get-TelephoneDashboardDoctorReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string]$StateRoot
    )

    $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $ensure = Join-Path $root 'src\dashboard\Ensure-TelephoneDashboard.ps1'
    $watch = Join-Path $root 'src\dashboard\Watch-TelephoneDashboard.ps1'
    $reducer = Join-Path $root 'src\dashboard\TelephoneDashboard.Reducer.ps1'
    $bundledPresent = ([IO.File]::Exists($ensure) -and [IO.File]::Exists($watch) -and [IO.File]::Exists($reducer))
    $schemaNames = @(
        'dashboard-config',
        'dashboard-project-descriptor',
        'dashboard-lifecycle-event',
        'dashboard-projection',
        'dashboard-closure',
        'lifecycle-status',
        'control-plane-current-state',
        'control-plane-continuation-capsule',
        'control-plane-wave-manifest',
        'control-plane-wave-spec',
        'control-plane-current-pointer',
        'control-plane-action-intent',
        'control-plane-action-result',
        'control-plane-event',
        'control-plane-transition',
        'control-plane-history-index',
        'control-plane-lane-attempt',
        'control-plane-performance-evidence',
        'control-plane-failure-matrix-evidence',
        'control-plane-release-gates-evidence'
    )
    $schemasValid = $true
    foreach ($name in $schemaNames) {
        $schemaPath = Join-Path $root ('schemas\' + $name + '.schema.json')
        if (-not [IO.File]::Exists($schemaPath)) { $schemasValid = $false; break }
        try {
            $null = [IO.File]::ReadAllText($schemaPath) | ConvertFrom-Json -Depth 32
        } catch {
            $schemasValid = $false
            break
        }
    }
    $configPath = $null
    try { $configPath = Get-TelephoneDashboardConfigPath } catch { $configPath = $null }
    $configPresent = (-not [string]::IsNullOrWhiteSpace([string]$configPath) -and [IO.File]::Exists($configPath))
    $configValid = $false
    if ($configPresent) {
        try {
            $text = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($configPath))
            Assert-TelephoneJsonSchema -JsonText $text -SchemaName 'dashboard-config' -Label 'dashboard config'
            $configValid = $true
        } catch {
            $configValid = $false
        }
    }
    $overrideConfigured = -not [string]::IsNullOrWhiteSpace((Get-TelephoneDashboardEnsureOverride))
    $optOut = Test-TelephoneDashboardOptOut
    $watcherRunning = $false
    $watcherPid = 0
    $identityOk = $false
    try {
        $dashState = Get-TelephoneDashboardStateRoot
        $identity = Read-TelephoneDashboardWatcherIdentity -Path (Join-Path $dashState 'watcher.json')
        if ($null -ne $identity -and [IO.File]::Exists($watch) -and (Test-TelephoneDashboardWatcherIdentity -Identity $identity -WatchScript $watch)) {
            $watcherRunning = $true
            $watcherPid = [int]$identity.pid
            $identityOk = $true
        }
    } catch { }
    return [ordered]@{
        bundled_present = [bool]$bundledPresent
        schemas_valid = [bool]$schemasValid
        config_present = [bool]$configPresent
        config_valid = [bool]$configValid
        override_configured = [bool]$overrideConfigured
        opt_out = [bool]$optOut
        watcher_running = [bool]$watcherRunning
        watcher_pid = [int]$watcherPid
        watcher_identity_ok = [bool]$identityOk
        observational = $true
        read_only = $true
    }
}

# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'src\install\TelephoneLineInstall.Common.ps1')
$pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$assertions = 0
$installLifecycle = 0
$installIdempotent = 0
$uninstallNoResidue = 0
$doctorReadOnly = 0
$doctorDriftDetected = 0
$updatePreservesState = 0
$updateReplacesIncompatibleWatcher = 0
$installShipsLicense = 0
$childHarnessLaunch = 0
$installPendingIdleActivation = 0
$doctorTaskIdentity = 0
$recycleTransientRetry = 0
$recycleRealWindowsProbe = 0
$recycleForeignOwnerRefused = 0
$uninstallConvergentLifecycle = 0
$uninstallRemoveState = 0
$localAppDataSafeOracle = 0
$emptyFileFingerprint = 0

function Assert-InstallTest {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Get-InstallTreeBytes {
    param([string]$Root)
    if (-not [IO.Directory]::Exists($Root)) { return [ordered]@{ present = $false; map = [ordered]@{} } }
    $map = [ordered]@{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName)) {
        Assert-InstallTest (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'A reparse point exists under a test tree.'
        $rel = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $map[$rel] = [ordered]@{
            bytes = [int64]$bytes.Length
            sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            ticks = [int64]$file.LastWriteTimeUtc.Ticks
        }
    }
    return [ordered]@{ present = $true; map = $map }
}

function Test-InstallMapsEqual {
    param($Left, $Right, [switch]$IgnoreTicks)
    if ([bool]$Left.present -ne [bool]$Right.present) { return $false }
    if ($Left.map.Count -ne $Right.map.Count) { return $false }
    foreach ($key in @($Left.map.Keys)) {
        if (-not $Right.map.Contains($key)) { return $false }
        if ([int64]$Left.map[$key].bytes -ne [int64]$Right.map[$key].bytes) { return $false }
        if ([string]$Left.map[$key].sha256 -cne [string]$Right.map[$key].sha256) { return $false }
        if (-not $IgnoreTicks -and [int64]$Left.map[$key].ticks -ne [int64]$Right.map[$key].ticks) { return $false }
    }
    return $true
}

function Invoke-InstallCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [string[]]$Arguments
    )
    $scriptPath = Join-Path $repoRoot ('src\install\' + $ScriptName)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = $testRoot
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $scriptPath
    ) + @($Arguments)) {
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
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $json = $stdout | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
        }
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

function Copy-InstallSourceTrees {
    param([string]$From, [string]$To)
    [IO.Directory]::CreateDirectory($To) | Out-Null
    foreach ($tree in @('src', 'schemas', 'docs')) {
        $src = Join-Path $From $tree
        $dst = Join-Path $To $tree
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $From 'LICENSE') -Destination (Join-Path $To 'LICENSE') -Force
}

function Get-WatchedHarnessPids {
    $names = @('codex', 'claude', 'grok', 'dsh', 'cursor-agent')
    $pids = [Collections.Generic.List[int]]::new()
    Get-CimInstance Win32_Process | ForEach-Object {
        $procName = ([string]$_.Name).ToLowerInvariant()
        $cmd = [string]$_.CommandLine
        foreach ($name in $names) {
            if ($procName.StartsWith($name, [StringComparison]::Ordinal) -or $cmd -match [regex]::Escape($name + '.exe')) {
                [void]$pids.Add([int]$_.ProcessId)
                break
            }
        }
    }
    return @($pids)
}

function Get-InstallUnrelatedIdentities {
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($name in @('explorer')) {
        foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            try {
                [void]$rows.Add([ordered]@{
                    name = [string]$proc.ProcessName
                    pid = [int]$proc.Id
                    start_time_utc_ticks = [int64]$proc.StartTime.ToUniversalTime().Ticks
                })
            } finally {
                $proc.Dispose()
            }
        }
    }
    $self = Get-Process -Id $PID
    try {
        [void]$rows.Add([ordered]@{
            name = [string]$self.ProcessName
            pid = [int]$self.Id
            start_time_utc_ticks = [int64]$self.StartTime.ToUniversalTime().Ticks
        })
    } finally {
        $self.Dispose()
    }
    return @($rows)
}

function Assert-InstallUnrelatedIdentitiesUntouched {
    param([object[]]$Before)
    foreach ($row in @($Before)) {
        Assert-InstallTest (Test-TelephoneOwnerAlive -Owner $row) ('Unrelated process was signaled: ' + [string]$row.name + '/' + [string]$row.pid)
    }
}

function Get-InstallRecycleFunctionText {
    return ${function:Move-TelephonePathToRecycleBin}.ToString()
}

function Start-InstallForeignOwnerProcess {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 45')) {
        [void]$info.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::Start($info)
    if ($process.HasExited) {
        throw 'Foreign-owner fixture exited immediately.'
    }
    return $process
}

function Stop-InstallExactProcess {
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)
    if ($null -eq $Process) { return }
    $identity = [ordered]@{
        pid = [int]$Process.Id
        start_time_utc_ticks = [int64]$Process.StartTime.ToUniversalTime().Ticks
    }
    if (Test-TelephoneOwnerAlive -Owner $identity) {
        try { $Process.Kill() } catch { }
        try { [void]$Process.WaitForExit(3000) } catch { }
    }
    try { $Process.Dispose() } catch { }
}

try {
    $emptyFingerprintRoot = Join-Path $testRoot 'empty-fingerprint'
    [IO.Directory]::CreateDirectory($emptyFingerprintRoot) | Out-Null
    $emptyFingerprintFile = Join-Path $emptyFingerprintRoot 'empty.lock'
    [IO.File]::WriteAllBytes($emptyFingerprintFile, [byte[]]@())
    $emptyIdentity = Get-TelephoneInstallFileIdentity -Path $emptyFingerprintFile
    $emptyTreeIdentity = Get-TelephoneInstallTreeFingerprint -Root $emptyFingerprintRoot
    Assert-InstallTest ([int64]$emptyIdentity.bytes -eq 0 -and [string]$emptyIdentity.sha256 -ceq 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') 'Zero-byte file identity is incorrect.'
    Assert-InstallTest ([int]$emptyTreeIdentity.file_count -eq 1) 'Tree fingerprint rejected a zero-byte runtime file.'
    $script:emptyFileFingerprint = 1
    $userPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
    $defaultInstall = Join-Path ([string]$env:LOCALAPPDATA) 'TelephoneLine'
    $defaultExisted = [IO.Directory]::Exists($defaultInstall)

    $pathFile = Join-Path $testRoot 'user-path.txt'
    $originalPathValue = 'X:\tl-bin;Y:\other-bin'
    [IO.File]::WriteAllText($pathFile, $originalPathValue)
    $env:TELEPHONE_LINE_USER_PATH_FILE = $pathFile
    $env:TELEPHONE_LINE_INSTALL_ROOT = (Join-Path $testRoot 'unused-default-install')
    $lifeRoot = Join-Path $testRoot 'lifecycle'
    $installRoot = Join-Path $lifeRoot 'install'
    $stateRoot = Join-Path $lifeRoot 'state'
    [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    $env:TELEPHONE_LINE_STATE_ROOT = $stateRoot
    $taskStore = Join-Path $testRoot 'task-store'
    $desktopRoot = Join-Path $testRoot 'desktop'
    $recycleRoot = Join-Path $testRoot 'recycle'
    $supervisorState = Join-Path $testRoot 'supervisor-state'
    [IO.Directory]::CreateDirectory($taskStore) | Out-Null
    [IO.Directory]::CreateDirectory($desktopRoot) | Out-Null
    [IO.Directory]::CreateDirectory($recycleRoot) | Out-Null
    [IO.Directory]::CreateDirectory($supervisorState) | Out-Null
    $env:TELEPHONE_LINE_TASK_STORE = $taskStore
    $env:TELEPHONE_LINE_TASK_BACKEND = (Join-Path $repoRoot 'tests\supervisor\fixtures\mock-scheduler.ps1')
    $env:TELEPHONE_LINE_DESKTOP_ROOT = $desktopRoot
    $env:TELEPHONE_LINE_RECYCLE_ROOT = $recycleRoot
    $env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT = $supervisorState
    $sourceRoot = $repoRoot

    $install = Invoke-InstallCommand -ScriptName 'Install-TelephoneLine.ps1' -Arguments @(
        '-InstallRoot', $installRoot, '-SourceRoot', $sourceRoot
    )
    Assert-InstallTest ($install.exit_code -eq 0) 'Fresh install exited non-zero.'
    Assert-InstallTest ($install.json.ok -eq $true) 'Fresh install was not ok.'
    Assert-InstallTest ([string]$install.json.code -ceq 'INSTALLED') 'Fresh install did not report INSTALLED.'
    $manifestPath = Join-Path $installRoot 'install-manifest.json'
    Assert-InstallTest ([IO.File]::Exists($manifestPath)) 'Install manifest was not published.'
    $manifest = Read-TelephoneInstallManifest -InstallRoot $installRoot
    Assert-InstallTest (Test-TelephoneInstallManifestProduct -Manifest $manifest) 'Install manifest is not this product.'
    Assert-InstallTest ([string]$manifest.install_root -ceq '.') 'Install manifest recorded an install root other than the manifest directory.'
    $manifestText = [IO.File]::ReadAllText($manifestPath)
    $usersPrefix = 'C:' + [char]0x5C + 'Users' + [char]0x5C
    Assert-InstallTest ($manifestText.IndexOf($usersPrefix, [StringComparison]::OrdinalIgnoreCase) -lt 0) 'Install manifest contains an absolute user path.'
    foreach ($secret in @([string]$env:USERPROFILE, [string]$env:USERNAME, [string]$env:COMPUTERNAME)) {
        if ([string]::IsNullOrWhiteSpace($secret) -or $secret.Length -lt 3) { continue }
        Assert-InstallTest ($manifestText.IndexOf($secret, [StringComparison]::OrdinalIgnoreCase) -lt 0) 'Install manifest contains a machine or user identity.'
    }
    $matchedRows = 0
    foreach ($row in @($manifest.files)) {
        $full = Join-Path $installRoot ([string]$row.path).Replace('/', '\')
        Assert-InstallTest ([IO.File]::Exists($full)) ('Installed file missing: ' + [string]$row.path)
        $identity = Get-TelephoneInstallFileIdentity -Path $full
        Assert-InstallTest ([int64]$identity.bytes -eq [int64]$row.bytes) ('Installed bytes differ: ' + [string]$row.path)
        Assert-InstallTest ([string]$identity.sha256 -ceq [string]$row.sha256) ('Installed hash differs: ' + [string]$row.path)
        $matchedRows += 1
    }
    Assert-InstallTest ($matchedRows -eq @($manifest.files).Count) 'Manifest row count disagreed with matched files.'
    $sourceLicense = Join-Path $sourceRoot 'LICENSE'
    $installedLicense = Join-Path $installRoot 'LICENSE'
    Assert-InstallTest ([IO.File]::Exists($installedLicense)) 'Install did not copy LICENSE to the install root.'
    $sourceLicenseId = Get-TelephoneInstallFileIdentity -Path $sourceLicense
    $installedLicenseId = Get-TelephoneInstallFileIdentity -Path $installedLicense
    Assert-InstallTest ([int64]$sourceLicenseId.bytes -eq [int64]$installedLicenseId.bytes -and [string]$sourceLicenseId.sha256 -ceq [string]$installedLicenseId.sha256) 'Installed LICENSE is not byte-identical to source LICENSE.'
    $licenseInManifest = $false
    foreach ($row in @($manifest.files)) {
        if ([string]$row.path -ceq 'LICENSE') { $licenseInManifest = $true; break }
    }
    Assert-InstallTest $licenseInManifest 'LICENSE is missing from the install manifest.'
    $manifestPaths = @($manifest.files | ForEach-Object { [string]$_.path })
    Assert-InstallTest ($manifestPaths -contains 'schemas/telephone-line-batch.schema.json') 'Install inventory omitted the shared mailbox batch schema.'
    Assert-InstallTest ($manifestPaths -contains 'schemas/wired-supervisor-status.schema.json') 'Install inventory omitted the wired supervisor status schema.'
    Assert-InstallTest ($manifestPaths -contains 'src/core/Invoke-TelephoneLineRelay.ps1') 'Install inventory omitted the shared mailbox relay.'
    Assert-InstallTest ($manifestPaths -contains 'src/supervisor/Invoke-TelephoneSupervisor.ps1') 'Install inventory omitted the wired supervisor.'
    Assert-InstallTest ([IO.File]::Exists((Join-Path $installRoot 'current.json'))) 'Install did not publish the current version pointer.'
    $currentPointer = Get-Content -LiteralPath (Join-Path $installRoot 'current.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
    Assert-InstallTest ([string]$currentPointer.protocol_version -ceq 'telephone-line-install-current-v1') 'Current pointer protocol is wrong.'
    Assert-InstallTest ([IO.Directory]::Exists((Join-Path $installRoot ('versions\' + [string]$currentPointer.version_id)))) 'Versioned install directory is missing.'
    Assert-InstallTest ([IO.File]::Exists((Join-Path $taskStore 'task.json'))) 'Install did not register the supervisor task.'
    $taskRow = Get-Content -LiteralPath (Join-Path $taskStore 'task.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
    Assert-InstallTest ([string]$taskRow.task_name -ceq 'TelephoneLineWiredSupervisor') 'Installed task name is wrong.'
    Assert-InstallTest ([string]$taskRow.principal -ceq 'LimitedUser') 'Installed task principal is wrong.'
    Assert-InstallTest ([IO.File]::Exists((Join-Path $desktopRoot '有线电话｜紧急停止.lnk'))) 'Emergency desktop shortcut is missing.'
    Assert-InstallTest ([IO.File]::Exists((Join-Path $desktopRoot '有线电话｜控制台.lnk'))) 'Console desktop shortcut is missing.'
    Assert-InstallTest (-not [IO.Directory]::Exists((Join-Path $installRoot '.git'))) 'Install copied .git.'
    Assert-InstallTest (-not [IO.Directory]::Exists((Join-Path $installRoot '.control'))) 'Install copied .control.'
    Assert-InstallTest (-not [IO.Directory]::Exists((Join-Path $installRoot 'tests'))) 'Install copied tests.'
    $script:installLifecycle += 1

    $beforeSecond = Get-InstallTreeBytes -Root $installRoot
    $second = Invoke-InstallCommand -ScriptName 'Install-TelephoneLine.ps1' -Arguments @(
        '-InstallRoot', $installRoot, '-SourceRoot', $sourceRoot
    )
    Assert-InstallTest ($second.exit_code -eq 0) 'Idempotent install exited non-zero.'
    Assert-InstallTest ([string]$second.json.code -ceq 'ALREADY_CURRENT') 'Second install did not report already-current.'
    Assert-InstallTest ($second.json.changed -eq $false) 'Second install reported a change.'
    $afterSecond = Get-InstallTreeBytes -Root $installRoot
    Assert-InstallTest (Test-InstallMapsEqual -Left $beforeSecond -Right $afterSecond) 'Second install copied files again.'
    $script:installIdempotent += 1

    $stateMarker = Join-Path $stateRoot 'durable-marker.txt'
    $markerBytes = [Text.UTF8Encoding]::new($false).GetBytes('durable-state-v1')
    [IO.File]::WriteAllBytes($stateMarker, $markerBytes)
    $stateBeforeDoctor = Get-InstallTreeBytes -Root $stateRoot
    $installBeforeDoctor = Get-InstallTreeBytes -Root $installRoot
    $watchedBefore = @(Get-WatchedHarnessPids)
    $doctor = Invoke-InstallCommand -ScriptName 'Invoke-TelephoneLineDoctor.ps1' -Arguments @(
        '-InstallRoot', $installRoot, '-StateRoot', $stateRoot
    )
    $watchedAfter = @(Get-WatchedHarnessPids)
    Assert-InstallTest ($doctor.exit_code -eq 0) 'Healthy doctor exited non-zero.'
    Assert-InstallTest ($doctor.json.healthy -eq $true) 'Doctor did not report healthy.'
    Assert-InstallTest ($doctor.json.read_only -eq $true) 'Doctor did not declare read-only.'
    Assert-InstallTest ($doctor.json.harness_probed -eq $false) 'Doctor probed a harness CLI.'
    Assert-InstallTest ($doctor.json.harness_launched -eq $false) 'Doctor launched a harness CLI.'
    Assert-InstallTest ([int]$doctor.json.adapters.validated -eq 8) 'Doctor did not validate eight descriptors.'
    Assert-InstallTest ($doctor.json.dashboard.bundled_present -eq $true) 'Doctor did not see the bundled dashboard.'
    Assert-InstallTest ($doctor.json.dashboard.schemas_valid -eq $true) 'Doctor did not validate dashboard schemas.'
    Assert-InstallTest ($doctor.json.dashboard.observational -eq $true) 'Doctor did not report dashboard observational.'
    Assert-InstallTest ($doctor.json.dashboard.read_only -eq $true) 'Doctor dashboard report was not read-only.'
    Assert-InstallTest ($doctor.json.supervisor.task.registered -eq $true) 'Doctor did not see the registered supervisor task.'
    Assert-InstallTest ($doctor.json.supervisor.task.action_ok -eq $true) 'Doctor did not accept the supervisor task action.'
    Assert-InstallTest ($doctor.json.supervisor.task.principal_ok -eq $true) 'Doctor did not accept the supervisor task principal.'
    $taskBackup = [IO.File]::ReadAllText((Join-Path $taskStore 'task.json'))
    $wrongTask = Get-Content -LiteralPath (Join-Path $taskStore 'task.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
    $wrongTask.action_script = 'C:\Windows\System32\notepad.exe'
    $wrongTask.principal = 'Highest'
    [IO.File]::WriteAllText((Join-Path $taskStore 'task.json'), (($wrongTask | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $wrongTaskDoctor = Invoke-InstallCommand -ScriptName 'Invoke-TelephoneLineDoctor.ps1' -Arguments @(
        '-InstallRoot', $installRoot, '-StateRoot', $stateRoot
    )
    Assert-InstallTest ($wrongTaskDoctor.exit_code -eq 0) 'Wrong-task doctor exited non-zero.'
    Assert-InstallTest ($wrongTaskDoctor.json.healthy -eq $false) 'Wrong-task doctor reported healthy.'
    Assert-InstallTest ($wrongTaskDoctor.json.supervisor.task.action_ok -eq $false) 'Doctor echoed a healthy action for the wrong executable.'
    Assert-InstallTest ($wrongTaskDoctor.json.supervisor.task.principal_ok -eq $false) 'Doctor echoed a healthy principal for Highest.'
    [IO.File]::WriteAllText((Join-Path $taskStore 'task.json'), $taskBackup, [Text.UTF8Encoding]::new($false))
    $script:doctorTaskIdentity = 1
    Assert-InstallTest ($doctor.json.supervisor.inbox -eq $true) 'Doctor did not see the supervisor inbox.'
    Assert-InstallTest ($doctor.json.supervisor.desktop.emergency -eq $true) 'Doctor did not see the emergency shortcut.'
    Assert-InstallTest (Test-InstallMapsEqual -Left $installBeforeDoctor -Right (Get-InstallTreeBytes -Root $installRoot)) 'Doctor mutated the install root.'
    Assert-InstallTest (Test-InstallMapsEqual -Left $stateBeforeDoctor -Right (Get-InstallTreeBytes -Root $stateRoot)) 'Doctor mutated the state root.'
    $newHarness = @($watchedAfter | Where-Object { $watchedBefore -notcontains $_ })
    Assert-InstallTest ($newHarness.Count -eq 0) 'Doctor started a harness process.'
    $script:doctorReadOnly += 1

    $driftRel = 'docs/privacy.md'
    $driftPath = Join-Path $installRoot ($driftRel.Replace('/', '\'))
    $originalDrift = [IO.File]::ReadAllBytes($driftPath)
    [IO.File]::AppendAllText($driftPath, 'drift')
    $driftDoctor = Invoke-InstallCommand -ScriptName 'Invoke-TelephoneLineDoctor.ps1' -Arguments @(
        '-InstallRoot', $installRoot, '-StateRoot', $stateRoot
    )
    Assert-InstallTest ($driftDoctor.exit_code -eq 0) 'Drift doctor exited non-zero.'
    Assert-InstallTest ($driftDoctor.json.healthy -eq $false) 'Drift doctor reported healthy.'
    Assert-InstallTest ([string]$driftDoctor.json.code -ceq 'DRIFT_DETECTED') 'Drift doctor did not use DRIFT_DETECTED.'
    $driftList = @($driftDoctor.json.manifest.drift)
    Assert-InstallTest ($driftList -contains $driftRel) 'Doctor did not report the drifted relative path.'
    Assert-InstallTest ($driftDoctor.json.read_only -eq $true) 'Drift doctor was not read-only.'
    [IO.File]::WriteAllBytes($driftPath, $originalDrift)
    $script:doctorDriftDetected += 1

    $licenseOriginal = [IO.File]::ReadAllBytes($installedLicense)
    [IO.File]::AppendAllText($installedLicense, 'license-drift')
    $licenseDoctor = Invoke-InstallCommand -ScriptName 'Invoke-TelephoneLineDoctor.ps1' -Arguments @(
        '-InstallRoot', $installRoot, '-StateRoot', $stateRoot
    )
    Assert-InstallTest ($licenseDoctor.exit_code -eq 0) 'LICENSE drift doctor exited non-zero.'
    Assert-InstallTest ($licenseDoctor.json.healthy -eq $false) 'LICENSE drift doctor reported healthy.'
    Assert-InstallTest ([string]$licenseDoctor.json.code -ceq 'DRIFT_DETECTED') 'LICENSE drift doctor did not use DRIFT_DETECTED.'
    $licenseDriftList = @($licenseDoctor.json.manifest.drift)
    Assert-InstallTest ($licenseDriftList -contains 'LICENSE') 'Doctor did not report LICENSE drift.'
    Assert-InstallTest ($licenseDoctor.json.read_only -eq $true) 'LICENSE drift doctor was not read-only.'
    [IO.File]::WriteAllBytes($installedLicense, $licenseOriginal)

    $eightDoctor = Invoke-InstallCommand -ScriptName 'Invoke-TelephoneLineDoctor.ps1' -Arguments @(
        '-InstallRoot', $installRoot, '-StateRoot', $stateRoot
    )
    Assert-InstallTest ([int]$eightDoctor.json.adapters.validated -eq 8) 'Doctor did not validate eight adapter descriptors.'
    Assert-InstallTest ($eightDoctor.json.harness_probed -eq $false) 'Eight-descriptor doctor probed a harness.'
    $declared = 0
    foreach ($route in @($eightDoctor.json.adapters.routes)) {
        Assert-InstallTest (-not [string]::IsNullOrWhiteSpace([string]$route.dependency_boundary)) 'Doctor omitted a declared dependency_boundary.'
        Assert-InstallTest ($route.boundary_declared_not_probed -eq $true) 'Doctor did not state that the boundary is declared rather than probed.'
        $declared += 1
    }
    Assert-InstallTest ($declared -eq 8) 'Doctor did not report eight route boundaries.'

    [IO.File]::Delete((Join-Path $taskStore 'task.json'))
    $missingTaskDoctor = Invoke-InstallCommand -ScriptName 'Invoke-TelephoneLineDoctor.ps1' -Arguments @(
        '-InstallRoot', $installRoot, '-StateRoot', $stateRoot
    )
    Assert-InstallTest ($missingTaskDoctor.exit_code -eq 0) 'Missing-task doctor exited non-zero.'
    Assert-InstallTest ($missingTaskDoctor.json.ok -eq $true) 'Missing-task doctor did not keep command ok.'
    Assert-InstallTest ($missingTaskDoctor.json.healthy -eq $false) 'Missing-task doctor reported healthy.'
    Assert-InstallTest ([string]$missingTaskDoctor.json.code -ceq 'DRIFT_DETECTED') 'Missing-task doctor did not use DRIFT_DETECTED.'
    Import-TelephoneSupervisorCommon
    $null = Complete-TelephoneSupervisorInstallSurface -InstallRoot $installRoot

    $updateSource = Join-Path $testRoot 'update-source'
    Copy-InstallSourceTrees -From $sourceRoot -To $updateSource
    $changedRel = 'docs/privacy.md'
    $droppedRel = 'docs/adapters/direct-pi.md'
    $addedRel = 'docs/update-marker.md'
    $changedPath = Join-Path $updateSource ($changedRel.Replace('/', '\'))
    [IO.File]::AppendAllText($changedPath, "`nupdate-marker`n")
    $droppedPath = Join-Path $updateSource ($droppedRel.Replace('/', '\'))
    Assert-InstallTest ([IO.File]::Exists($droppedPath)) 'Update fixture is missing the file to drop.'
    [IO.File]::Delete($droppedPath)
    $addedPath = Join-Path $updateSource ($addedRel.Replace('/', '\'))
    [IO.File]::WriteAllText($addedPath, "update added`n")
    $stateBeforeUpdate = Get-InstallTreeBytes -Root $stateRoot
    Import-TelephoneSupervisorCommon
    $pinProc = Get-Process -Id $PID
    try {
        $pinOwner = [ordered]@{
            protocol_version = 'telephone-line-wired-supervisor-owner-v1'
            kind = 'run'
            run_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee90'
            request_sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            pid = [int]$PID
            start_time_utc_ticks = [int64]$pinProc.StartTime.ToUniversalTime().Ticks
            started_at_utc = $pinProc.StartTime.ToUniversalTime().ToString('o')
            job_name = 'Local\TelephoneLine.WiredRun.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee90'
            project = 'pin-project'
            stage = 'active'
            lead_session_id = 'pin-session'
            installed_version = [ordered]@{
                version_id = [string]$currentPointer.version_id
                source_sha256 = [string]$currentPointer.source_sha256
            }
        }
    } finally { $pinProc.Dispose() }
    $null = Write-TelephoneSupervisorRunOwner -StateRoot $supervisorState -Owner $pinOwner
    $destPrivacyBefore = Get-TelephoneInstallFileIdentity -Path (Join-Path $installRoot ($changedRel.Replace('/', '\')))
    $pointerBefore = Get-Content -LiteralPath (Join-Path $installRoot 'current.json') -Raw
    $staged = Invoke-InstallCommand -ScriptName 'Update-TelephoneLine.ps1' -Arguments @(
        '-InstallRoot', $installRoot, '-SourceRoot', $updateSource
    )
    Assert-InstallTest ($staged.exit_code -eq 0) 'Pinned update exited non-zero.'
    Assert-InstallTest ($staged.json.current_switched -eq $false) 'Pinned update switched the current pointer.'
    Assert-InstallTest ([IO.File]::ReadAllText((Join-Path $installRoot 'current.json')) -ceq $pointerBefore) 'Pinned update mutated current.json.'
    $destPrivacyAfterPin = Get-TelephoneInstallFileIdentity -Path (Join-Path $installRoot ($changedRel.Replace('/', '\')))
    Assert-InstallTest ([string]$destPrivacyAfterPin.sha256 -ceq [string]$destPrivacyBefore.sha256) 'Pinned update replaced dest files while a run was pinned.'
    Assert-InstallTest ([IO.Directory]::Exists((Join-Path $installRoot ('versions\' + [string]$staged.json.staged_version_id)))) 'Pinned update did not stage the new version directory.'
    Assert-InstallTest ([IO.File]::Exists((Join-Path $installRoot 'pending.json'))) 'Pinned update did not publish pending.json.'
    [IO.File]::Delete((Join-Path (Join-Path $supervisorState ('runs\' + [string]$pinOwner.run_id)) 'owner.json'))
    $idleAct = Complete-TelephoneInstallPendingActivationIfIdle -InstallRoot $installRoot -StateRoot $supervisorState
    Assert-InstallTest ([bool]$idleAct.switched) 'Pending version did not activate automatically after the pinned Job became idle.'
    Assert-InstallTest ([IO.File]::ReadAllText((Join-Path $installRoot 'current.json')) -cne $pointerBefore) 'Idle activation left the current pointer unchanged.'
    $destAfterIdle = Get-TelephoneInstallFileIdentity -Path (Join-Path $installRoot ($changedRel.Replace('/', '\')))
    $sourceChanged = Get-TelephoneInstallFileIdentity -Path $changedPath
    Assert-InstallTest ([string]$destAfterIdle.sha256 -ceq [string]$sourceChanged.sha256) 'Idle activation did not copy pending bytes onto dest.'
    Assert-InstallTest (-not [IO.File]::Exists((Join-Path $installRoot 'pending.json'))) 'Idle activation left pending.json.'
    $script:installPendingIdleActivation = 1
    $update = Invoke-InstallCommand -ScriptName 'Update-TelephoneLine.ps1' -Arguments @(
        '-InstallRoot', $installRoot, '-SourceRoot', $updateSource
    )
    Assert-InstallTest ($update.exit_code -eq 0) 'Update exited non-zero.'
    Assert-InstallTest ([string]$update.json.code -cin @('UPDATED', 'ALREADY_CURRENT')) 'Update after idle activation used the wrong public code.'
    $updatedManifest = Read-TelephoneInstallManifest -InstallRoot $installRoot
    $updatedChanged = Get-TelephoneInstallFileIdentity -Path (Join-Path $installRoot ($changedRel.Replace('/', '\')))
    Assert-InstallTest ([string]$updatedChanged.sha256 -ceq [string]$sourceChanged.sha256) 'Update did not keep the changed file.'
    Assert-InstallTest (-not [IO.File]::Exists((Join-Path $installRoot ($droppedRel.Replace('/', '\'))))) 'Update did not remove the dropped file.'
    Assert-InstallTest ([IO.File]::Exists((Join-Path $installRoot ($addedRel.Replace('/', '\'))))) 'Update did not add the new source file.'
    Assert-InstallTest (Test-InstallMapsEqual -Left $stateBeforeUpdate -Right (Get-InstallTreeBytes -Root $stateRoot)) 'Update mutated durable state.'
    $script:updatePreservesState += 1

    $dashState = Join-Path $lifeRoot 'dash-runtime'
    [IO.Directory]::CreateDirectory($dashState) | Out-Null
    $env:TELEPHONE_LINE_DASHBOARD_STATE = $dashState
    $env:TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY = '1'
    $env:TELEPHONE_LINE_DASHBOARD_HEADLESS = '1'
    $env:TELEPHONE_LINE_DASHBOARD_OPT_OUT = ''
    $env:TELEPHONE_LINE_DASHBOARD_ENSURE_SCRIPT = ''
    . (Join-Path $installRoot 'src\dashboard\TelephoneDashboard.Common.ps1')
    $ens = Invoke-TelephoneBundledDashboardEnsure
    Assert-InstallTest ([bool]$ens.healthy -and [int]$ens.watcher_pid -gt 0) 'Bundled dashboard ensure did not start a watcher.'
    $watchPid = [int]$ens.watcher_pid
    $watchOwner = Read-TelephoneDashboardWatcherIdentity -Path (Join-Path $dashState 'watcher.json')
    $updateWatch = Join-Path $updateSource 'src\dashboard\Watch-TelephoneDashboard.ps1'
    [IO.File]::AppendAllText($updateWatch, "`n# incompatible-update`n")
    $updateIncompat = Invoke-InstallCommand -ScriptName 'Update-TelephoneLine.ps1' -Arguments @(
        '-InstallRoot', $installRoot, '-SourceRoot', $updateSource
    )
    Assert-InstallTest ($updateIncompat.exit_code -eq 0) 'Incompatible-update exited non-zero.'
    Start-Sleep -Milliseconds 300
    $oldAlive = $false
    try { $oldAlive = Test-TelephoneOwnerAlive -Owner $watchOwner } catch { $oldAlive = $false }
    Assert-InstallTest (-not $oldAlive) 'Update reused an incompatible pre-update watcher.'
    Assert-InstallTest ([IO.Directory]::Exists($dashState)) 'Update removed dashboard state.'
    $script:updateReplacesIncompatibleWatcher = 1
    $null = Stop-TelephoneDashboardExactWatcher -InstallRoot $installRoot -AllowIncompatibleBuild

    $inFlightJob = Join-Path $stateRoot 'jobs\aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1'
    [IO.Directory]::CreateDirectory($inFlightJob) | Out-Null
    [IO.File]::WriteAllText((Join-Path $inFlightJob 'dispatch.json'), "{`n}`n")
    $installBeforeRefuse = Get-InstallTreeBytes -Root $installRoot
    $stateBeforeRefuse = Get-InstallTreeBytes -Root $stateRoot
    $refused = Invoke-InstallCommand -ScriptName 'Update-TelephoneLine.ps1' -Arguments @(
        '-InstallRoot', $installRoot, '-SourceRoot', $updateSource
    )
    Assert-InstallTest ($refused.exit_code -eq 0) 'In-flight update refusal exited non-zero.'
    Assert-InstallTest ($refused.json.ok -eq $true) 'In-flight update refusal was not ok.'
    Assert-InstallTest ([string]$refused.json.code -ceq 'IN_FLIGHT_JOBS_PRESENT') 'In-flight update used the wrong public code.'
    Assert-InstallTest ($refused.json.changed -eq $false) 'In-flight update reported a change.'
    Assert-InstallTest (Test-InstallMapsEqual -Left $installBeforeRefuse -Right (Get-InstallTreeBytes -Root $installRoot)) 'In-flight update mutated the install root.'
    Assert-InstallTest (Test-InstallMapsEqual -Left $stateBeforeRefuse -Right (Get-InstallTreeBytes -Root $stateRoot)) 'In-flight update mutated the state root.'

    $uninstalled = Invoke-InstallCommand -ScriptName 'Uninstall-TelephoneLine.ps1' -Arguments @(
        '-InstallRoot', $installRoot
    )
    Assert-InstallTest ($uninstalled.exit_code -eq 0) 'Uninstall exited non-zero.'
    Assert-InstallTest ([string]$uninstalled.json.code -ceq 'UNINSTALLED') 'Uninstall did not report UNINSTALLED.'
    Assert-InstallTest ($uninstalled.json.residue -eq $false) 'Uninstall reported residue.'
    Assert-InstallTest (-not [IO.Directory]::Exists($installRoot)) 'Uninstall left the install root.'
    Assert-InstallTest (-not [IO.File]::Exists($installedLicense)) 'Uninstall left LICENSE.'
    Assert-InstallTest ([IO.File]::Exists($stateMarker)) 'Default uninstall removed durable state.'
    Assert-InstallTest ([IO.Directory]::Exists($inFlightJob)) 'Default uninstall removed in-flight state.'
    Assert-InstallTest (-not [IO.File]::Exists((Join-Path $desktopRoot '有线电话｜紧急停止.lnk'))) 'Uninstall left the emergency shortcut.'
    Assert-InstallTest (-not [IO.File]::Exists((Join-Path $taskStore 'task.json'))) 'Uninstall left the supervisor task.'
    $recycleHits = @(Get-ChildItem -LiteralPath $recycleRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
    Assert-InstallTest ($recycleHits.Count -gt 0) 'Uninstall did not send install material through the recycle path.'
    $script:uninstallNoResidue += 1

    $sentinelRoot = Join-Path $testRoot 'sentinel'
    $sentinelInstall = Join-Path $sentinelRoot 'install'
    $sibling = Join-Path $sentinelRoot 'sibling'
    [IO.Directory]::CreateDirectory($sibling) | Out-Null
    $siblingFile = Join-Path $sibling 'keep.txt'
    [IO.File]::WriteAllText($siblingFile, 'outside')
    $sentinelInstallResult = Invoke-InstallCommand -ScriptName 'Install-TelephoneLine.ps1' -Arguments @(
        '-InstallRoot', $sentinelInstall, '-SourceRoot', $sourceRoot
    )
    Assert-InstallTest ($sentinelInstallResult.exit_code -eq 0) 'Sentinel install exited non-zero.'
    $sentinelFile = Join-Path $sentinelInstall 'unmanaged-sentinel.txt'
    [IO.File]::WriteAllText($sentinelFile, 'unmanaged')
    $sentinelUninstall = Invoke-InstallCommand -ScriptName 'Uninstall-TelephoneLine.ps1' -Arguments @(
        '-InstallRoot', $sentinelInstall
    )
    Assert-InstallTest ($sentinelUninstall.exit_code -eq 0) 'Sentinel uninstall exited non-zero.'
    Assert-InstallTest ([IO.File]::Exists($sentinelFile)) 'Uninstall deleted an unmanaged sentinel.'
    Assert-InstallTest ([IO.Directory]::Exists($sentinelInstall)) 'Uninstall removed an install root that still had unmanaged content.'
    Assert-InstallTest (-not [IO.File]::Exists((Join-Path $sentinelInstall 'install-manifest.json'))) 'Sentinel uninstall left the install manifest.'
    Assert-InstallTest (-not [IO.File]::Exists((Join-Path $sentinelInstall 'LICENSE'))) 'Sentinel uninstall left LICENSE.'
    Assert-InstallTest (-not [IO.Directory]::Exists((Join-Path $sentinelInstall 'src'))) 'Sentinel uninstall left product src.'
    Assert-InstallTest ([IO.File]::Exists($siblingFile)) 'Uninstall touched a sibling directory.'
    Assert-InstallTest ([IO.File]::ReadAllText($siblingFile) -ceq 'outside') 'Uninstall mutated a sibling file.'

    $pathInstall = Join-Path $testRoot 'path-install'
    $pathBefore = [IO.File]::ReadAllText($pathFile)
    Assert-InstallTest ($pathBefore -ceq $originalPathValue) 'PATH store was mutated before the PATH proof.'
    $pathInstallResult = Invoke-InstallCommand -ScriptName 'Install-TelephoneLine.ps1' -Arguments @(
        '-InstallRoot', $pathInstall, '-SourceRoot', $sourceRoot, '-AddToPath'
    )
    Assert-InstallTest ($pathInstallResult.exit_code -eq 0) 'PATH install exited non-zero.'
    Assert-InstallTest ($pathInstallResult.json.path_appended -eq $true) 'PATH install did not record a PATH entry.'
    $pathAfterInstall = [IO.File]::ReadAllText($pathFile)
    $expectedPath = $originalPathValue + ';' + ([IO.Path]::GetFullPath($pathInstall).TrimEnd('\'))
    Assert-InstallTest ($pathAfterInstall -ceq $expectedPath) 'AddToPath did not append the install root exactly once.'
    $pathUninstall = Invoke-InstallCommand -ScriptName 'Uninstall-TelephoneLine.ps1' -Arguments @(
        '-InstallRoot', $pathInstall
    )
    Assert-InstallTest ($pathUninstall.exit_code -eq 0) 'PATH uninstall exited non-zero.'
    Assert-InstallTest ([IO.File]::ReadAllText($pathFile) -ceq $originalPathValue) 'Uninstall did not restore the original per-user PATH value.'

    $recycleFn = Get-InstallRecycleFunctionText
    Assert-InstallTest ($recycleFn -notmatch 'Remove-Item') 'Recycle function falls back to Remove-Item.'
    Assert-InstallTest ($recycleFn -notmatch '\[IO\.Directory\]::Delete') 'Recycle function falls back to Directory.Delete.'
    Assert-InstallTest ($recycleFn -notmatch '\[IO\.File\]::Delete') 'Recycle function falls back to File.Delete.'
    Assert-InstallTest ($recycleFn -notmatch 'Stop-Process') 'Recycle function signals processes.'
    Assert-InstallTest ($recycleFn -notmatch 'Kill\(') 'Recycle function kills processes.'
    Assert-InstallTest ($recycleFn -notmatch 'TerminateProcess') 'Recycle function terminates processes.'

    $foreignProc = $null
    try {
        $foreignProc = Start-InstallForeignOwnerProcess
        $foreignOwner = New-TelephoneSupervisorOwnerSnapshot -Kind supervisor -ProcessId ([int]$foreignProc.Id)
        $foreignRoot = Join-Path $testRoot 'recycle-foreign-live'
        $null = Initialize-TelephoneSupervisorLayout -StateRoot $foreignRoot
        $null = Write-TelephoneJsonReplace -Path (Get-TelephoneSupervisorPaths -StateRoot $foreignRoot).supervisor_owner -Value $foreignOwner
        $nestedForeign = Join-Path $foreignRoot 'nested\keep.txt'
        [IO.Directory]::CreateDirectory((Join-Path $foreignRoot 'nested')) | Out-Null
        [IO.File]::WriteAllText($nestedForeign, 'keep-evidence')
        $beforeForeign = Get-InstallUnrelatedIdentities
        $foreignThrew = $false
        try {
            $null = Move-TelephonePathToRecycleBin -Path $foreignRoot
        } catch {
            $foreignThrew = ([string]$_.Exception.Message -ceq 'RECYCLE_BLOCKED')
        }
        Assert-InstallTest $foreignThrew 'Live foreign owner recycle did not return RECYCLE_BLOCKED.'
        Assert-InstallTest ([IO.Directory]::Exists($foreignRoot)) 'Live foreign owner recycle removed evidence.'
        Assert-InstallTest ([IO.File]::Exists($nestedForeign)) 'Live foreign owner recycle deleted nested evidence.'
        Assert-InstallTest (Test-TelephoneOwnerAlive -Owner $foreignOwner) 'Live foreign owner process was signaled.'
        Assert-InstallUnrelatedIdentitiesUntouched -Before $beforeForeign
        $script:recycleForeignOwnerRefused = 1

        $reuseRoot = Join-Path $testRoot 'recycle-pid-reuse'
        $null = Initialize-TelephoneSupervisorLayout -StateRoot $reuseRoot
        $reuseOwner = [ordered]@{}
        foreach ($key in @($foreignOwner.Keys)) { $reuseOwner[$key] = $foreignOwner[$key] }
        $reuseOwner.start_time_utc_ticks = 1
        $reuseOwner.started_at_utc = '2020-01-01T00:00:00Z'
        $null = Write-TelephoneJsonReplace -Path (Get-TelephoneSupervisorPaths -StateRoot $reuseRoot).supervisor_owner -Value $reuseOwner
        [IO.File]::WriteAllText((Join-Path $reuseRoot 'marker.txt'), 'reuse')
        $reuseMoved = Move-TelephonePathToRecycleBin -Path $reuseRoot
        Assert-InstallTest ([bool]$reuseMoved.recycled) 'PID-reuse owner recycle did not recycle the target.'
        Assert-InstallTest (-not [IO.Directory]::Exists($reuseRoot)) 'PID-reuse owner recycle left the target.'
        Assert-InstallTest (Test-TelephoneOwnerAlive -Owner $foreignOwner) 'PID-reuse recycle signaled the reused PID.'
    } finally {
        Stop-InstallExactProcess -Process $foreignProc
    }

    $savedRecycleRoot = [string]$env:TELEPHONE_LINE_RECYCLE_ROOT
    $prodInstall = Join-Path ([string]$env:LOCALAPPDATA) 'TelephoneLine'
    $nativeProbe = Join-Path ([string]$env:LOCALAPPDATA) ('TelephoneLine.RecycleProbe.' + [Guid]::NewGuid().ToString('N'))
    Assert-InstallTest (-not $nativeProbe.Equals($prodInstall, [StringComparison]::OrdinalIgnoreCase)) 'Native recycle probe used the production install root.'
    Assert-InstallTest (-not (Test-TelephoneInstallPathInsideRoot -Path $nativeProbe -Root $prodInstall)) 'Native recycle probe was nested under the production install root.'
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    Assert-InstallTest (-not (Test-TelephoneInstallPathInsideRoot -Path $nativeProbe -Root $tempRoot)) 'Native recycle probe used TEMP.'
    try {
        $nestedProbe = Join-Path $nativeProbe 'nested\state'
        [IO.Directory]::CreateDirectory($nestedProbe) | Out-Null
        [IO.File]::WriteAllText((Join-Path $nestedProbe 'durable.json'), "{`n  `"keep`": true`n}`n")
        [IO.File]::WriteAllText((Join-Path $nestedProbe 'child.txt'), 'nested-state')
        Reset-TelephoneRecycleAttemptLog
        $script:TelephoneRecycleInjectNextNativeFailures = 1
        $env:TELEPHONE_LINE_RECYCLE_INJECT_TRANSIENT = '1'
        $env:TELEPHONE_LINE_RECYCLE_ROOT = ''
        $beforeNative = Get-InstallUnrelatedIdentities
        $nativeMoved = Move-TelephonePathToRecycleBin -Path $nativeProbe
        Assert-InstallUnrelatedIdentitiesUntouched -Before $beforeNative
        Assert-InstallTest ([bool]$nativeMoved.recycled) 'Native recycle probe did not recycle.'
        Assert-InstallTest ([int]$nativeMoved.attempts -eq 2) 'Native transient recycle did not use one retry.'
        Assert-InstallTest ([int]$nativeMoved.attempts -le 8) 'Native recycle exceeded the bounded attempt count.'
        Assert-InstallTest ([bool]$nativeMoved.revalidated) 'Native recycle retry did not revalidate the target.'
        Assert-InstallTest ([string]$nativeMoved.backend -ceq 'native') 'Native recycle used the fake backend.'
        Assert-InstallTest (-not [IO.Directory]::Exists($nativeProbe)) 'Native recycle left the source directory.'
        $log = @($nativeMoved.attempt_records)
        Assert-InstallTest ($log.Count -ge 2) 'Native recycle attempt log is short.'
        Assert-InstallTest ([bool]$log[0].injected) 'First native attempt was not the injected failure.'
        Assert-InstallTest ([int]$log[0].code -eq 32) 'Injected native failure did not return sharing violation.'
        Assert-InstallTest ([bool]$log[0].existed_after) 'Injected native failure deleted the target.'
        Assert-InstallTest ($log[0].path.Equals([string]$nativeProbe, [StringComparison]::OrdinalIgnoreCase)) 'Retry log did not keep the exact target path.'
        Assert-InstallTest (-not [bool]$log[1].injected) 'Second native attempt was still injected.'
        Assert-InstallTest (-not [bool]$log[1].existed_after) 'Successful native retry left the source.'
        Assert-InstallTest ([bool]$nativeMoved.recoverable) 'Native recycle was not recoverable.'
        $script:recycleTransientRetry = 1
        $script:recycleRealWindowsProbe = 1
    } finally {
        $script:TelephoneRecycleInjectNextNativeFailures = 0
        $env:TELEPHONE_LINE_RECYCLE_INJECT_TRANSIENT = ''
        if ([IO.Directory]::Exists($nativeProbe)) {
            try { $null = Move-TelephonePathToRecycleBin -Path $nativeProbe } catch { }
        }
        $env:TELEPHONE_LINE_RECYCLE_ROOT = $savedRecycleRoot
    }

    $convRoot = Join-Path $testRoot 'convergent'
    $convInstall = Join-Path $convRoot 'install'
    $convState = Join-Path $convRoot 'state'
    $convSup = Join-Path $convRoot 'supervisor-state'
    [IO.Directory]::CreateDirectory($convState) | Out-Null
    $savedStateRoot = [string]$env:TELEPHONE_LINE_STATE_ROOT
    $savedSupRoot = [string]$env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT
    $env:TELEPHONE_LINE_STATE_ROOT = $convState
    $env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT = $convSup
    [IO.File]::WriteAllText((Join-Path $convState 'durable-marker.txt'), 'preserve-me')
    $convInstallResult = Invoke-InstallCommand -ScriptName 'Install-TelephoneLine.ps1' -Arguments @(
        '-InstallRoot', $convInstall, '-SourceRoot', $sourceRoot
    )
    Assert-InstallTest ($convInstallResult.exit_code -eq 0) 'Convergent install exited non-zero.'
    Import-TelephoneSupervisorCommon
    Unregister-TelephoneSupervisorInstallSurface -InstallRoot $convInstall
    Assert-InstallTest (-not [IO.File]::Exists((Join-Path $taskStore 'task.json'))) 'Real-surface unregister left the task.'
    Assert-InstallTest (-not [IO.File]::Exists((Join-Path $desktopRoot '有线电话｜紧急停止.lnk'))) 'Real-surface unregister left the emergency shortcut.'
    $convDefault = Invoke-InstallCommand -ScriptName 'Uninstall-TelephoneLine.ps1' -Arguments @(
        '-InstallRoot', $convInstall
    )
    Assert-InstallTest ($convDefault.exit_code -eq 0) 'Convergent default uninstall exited non-zero.'
    Assert-InstallTest ([string]$convDefault.json.code -cin @('UNINSTALLED', 'UNMANAGED_CONTENT_REMAINS')) 'Convergent default uninstall used the wrong code.'
    Assert-InstallTest ([IO.File]::Exists((Join-Path $convState 'durable-marker.txt'))) 'Default uninstall removed preserved state.'
    Assert-InstallTest ($convDefault.json.state_preserved -eq $true) 'Default uninstall did not preserve state.'
    Assert-InstallTest (-not [IO.File]::Exists((Join-Path $taskStore 'task.json'))) 'Default uninstall left the task.'
    $convReinstall = Invoke-InstallCommand -ScriptName 'Install-TelephoneLine.ps1' -Arguments @(
        '-InstallRoot', $convInstall, '-SourceRoot', $sourceRoot
    )
    Assert-InstallTest ($convReinstall.exit_code -eq 0) 'Convergent reinstall exited non-zero.'
    Assert-InstallTest ([string]$convReinstall.json.code -cin @('INSTALLED', 'ALREADY_CURRENT')) 'Convergent reinstall used the wrong code.'
    $convRemove = Invoke-InstallCommand -ScriptName 'Uninstall-TelephoneLine.ps1' -Arguments @(
        '-InstallRoot', $convInstall, '-RemoveState'
    )
    Assert-InstallTest ($convRemove.exit_code -eq 0) 'Convergent -RemoveState exited non-zero.'
    Assert-InstallTest ($convRemove.json.ok -eq $true) 'Convergent -RemoveState was not ok.'
    Assert-InstallTest ([string]$convRemove.json.code -ceq 'UNINSTALLED') 'Convergent -RemoveState did not report UNINSTALLED.'
    Assert-InstallTest ($convRemove.json.residue -eq $false) 'Convergent -RemoveState reported residue.'
    Assert-InstallTest ($convRemove.json.state_removed -eq $true) 'Convergent -RemoveState did not remove state.'
    Assert-InstallTest (-not [IO.Directory]::Exists($convInstall)) 'Convergent -RemoveState left the install root.'
    Assert-InstallTest (-not [IO.Directory]::Exists($convState)) 'Convergent -RemoveState left line state.'
    Assert-InstallTest (-not [IO.Directory]::Exists($convSup)) 'Convergent -RemoveState left supervisor state.'
    Assert-InstallTest (-not [IO.File]::Exists((Join-Path $taskStore 'task.json'))) 'Convergent -RemoveState left the task.'
    Assert-InstallTest (-not [IO.File]::Exists((Join-Path $desktopRoot '有线电话｜紧急停止.lnk'))) 'Convergent -RemoveState left a shortcut.'
    $script:uninstallRemoveState = 1
    $convFinal = Invoke-InstallCommand -ScriptName 'Install-TelephoneLine.ps1' -Arguments @(
        '-InstallRoot', $convInstall, '-SourceRoot', $sourceRoot
    )
    Assert-InstallTest ($convFinal.exit_code -eq 0) 'Post-remove reinstall exited non-zero.'
    $convDoctor = Invoke-InstallCommand -ScriptName 'Invoke-TelephoneLineDoctor.ps1' -Arguments @(
        '-InstallRoot', $convInstall, '-StateRoot', $convState
    )
    Assert-InstallTest ($convDoctor.exit_code -eq 0) 'Post-remove doctor exited non-zero.'
    Assert-InstallTest ($convDoctor.json.healthy -eq $true) 'Post-remove doctor was not healthy.'
    Assert-InstallTest ($convDoctor.json.manifest.identity_match -eq $true) 'Post-remove doctor identity did not match.'
    Assert-InstallTest ([int]$convDoctor.json.adapters.validated -eq 8) 'Post-remove doctor did not validate eight adapters.'
    $script:uninstallConvergentLifecycle = 1
    $env:TELEPHONE_LINE_STATE_ROOT = $savedStateRoot
    $env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT = $savedSupRoot

    $safeInstall = Join-Path ([string]$env:LOCALAPPDATA) ('TelephoneLine.SafeOracle.' + [Guid]::NewGuid().ToString('N'))
    Assert-InstallTest (-not $safeInstall.Equals($prodInstall, [StringComparison]::OrdinalIgnoreCase)) 'Safe oracle used the production install root.'
    Assert-InstallTest (-not (Test-TelephoneInstallPathInsideRoot -Path $safeInstall -Root $prodInstall)) 'Safe oracle was nested under the production install root.'
    $safeState = Join-Path $safeInstall 'line-state'
    $safeSup = Join-Path $safeInstall 'supervisor-state'
    [IO.Directory]::CreateDirectory($safeState) | Out-Null
    [IO.File]::WriteAllText((Join-Path $safeState 'safe-marker.txt'), 'safe-state')
    $env:TELEPHONE_LINE_STATE_ROOT = $safeState
    $env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT = $safeSup
    try {
        $safeInstallResult = Invoke-InstallCommand -ScriptName 'Install-TelephoneLine.ps1' -Arguments @(
            '-InstallRoot', $safeInstall, '-SourceRoot', $sourceRoot
        )
        Assert-InstallTest ($safeInstallResult.exit_code -eq 0) 'LocalAppData safe install exited non-zero.'
        Unregister-TelephoneSupervisorInstallSurface -InstallRoot $safeInstall
        $safeDefault = Invoke-InstallCommand -ScriptName 'Uninstall-TelephoneLine.ps1' -Arguments @(
            '-InstallRoot', $safeInstall
        )
        Assert-InstallTest ($safeDefault.exit_code -eq 0) 'LocalAppData default uninstall exited non-zero.'
        Assert-InstallTest ([IO.File]::Exists((Join-Path $safeState 'safe-marker.txt'))) 'LocalAppData default uninstall removed state.'
        $safeReinstall = Invoke-InstallCommand -ScriptName 'Install-TelephoneLine.ps1' -Arguments @(
            '-InstallRoot', $safeInstall, '-SourceRoot', $sourceRoot
        )
        Assert-InstallTest ($safeReinstall.exit_code -eq 0) 'LocalAppData reinstall exited non-zero.'
        $safeRemove = Invoke-InstallCommand -ScriptName 'Uninstall-TelephoneLine.ps1' -Arguments @(
            '-InstallRoot', $safeInstall, '-RemoveState'
        )
        Assert-InstallTest ($safeRemove.exit_code -eq 0) 'LocalAppData -RemoveState exited non-zero.'
        Assert-InstallTest ($safeRemove.json.ok -eq $true) 'LocalAppData -RemoveState was not ok.'
        Assert-InstallTest ([string]$safeRemove.json.code -ceq 'UNINSTALLED') 'LocalAppData -RemoveState did not report UNINSTALLED.'
        Assert-InstallTest ($safeRemove.json.residue -eq $false) 'LocalAppData -RemoveState reported residue.'
        Assert-InstallTest (-not [IO.Directory]::Exists($safeInstall)) 'LocalAppData -RemoveState left the install root.'
        Assert-InstallTest (-not [IO.Directory]::Exists($safeState)) 'LocalAppData -RemoveState left line state.'
        Assert-InstallTest (-not [IO.Directory]::Exists($safeSup)) 'LocalAppData -RemoveState left supervisor state.'
        Assert-InstallTest (-not [IO.Directory]::Exists($prodInstall) -or $defaultExisted) 'Safe oracle created or restored the production install root.'
        $safeFinal = Invoke-InstallCommand -ScriptName 'Install-TelephoneLine.ps1' -Arguments @(
            '-InstallRoot', $safeInstall, '-SourceRoot', $sourceRoot
        )
        Assert-InstallTest ($safeFinal.exit_code -eq 0) 'LocalAppData final reinstall exited non-zero.'
        $safeDoctor = Invoke-InstallCommand -ScriptName 'Invoke-TelephoneLineDoctor.ps1' -Arguments @(
            '-InstallRoot', $safeInstall, '-StateRoot', $safeState
        )
        Assert-InstallTest ($safeDoctor.exit_code -eq 0) 'LocalAppData doctor exited non-zero.'
        Assert-InstallTest ($safeDoctor.json.healthy -eq $true) 'LocalAppData doctor was not healthy.'
        Assert-InstallTest ($safeDoctor.json.manifest.identity_match -eq $true) 'LocalAppData doctor identity did not match.'
        $null = Invoke-InstallCommand -ScriptName 'Uninstall-TelephoneLine.ps1' -Arguments @(
            '-InstallRoot', $safeInstall, '-RemoveState'
        )
        Assert-InstallTest (-not [IO.Directory]::Exists($safeInstall)) 'LocalAppData cleanup left the safe install root.'
        $script:localAppDataSafeOracle = 1
    } finally {
        $env:TELEPHONE_LINE_STATE_ROOT = $savedStateRoot
        $env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT = $savedSupRoot
        if ([IO.Directory]::Exists($safeInstall)) {
            try { $null = Move-TelephonePathToRecycleBin -Path $safeInstall } catch { }
        }
    }

    $userPathAfter = [Environment]::GetEnvironmentVariable('Path', 'User')
    Assert-InstallTest ([string]$userPathBefore -ceq [string]$userPathAfter) 'A command mutated the real per-user PATH.'
    if (-not $defaultExisted) {
        Assert-InstallTest (-not [IO.Directory]::Exists($defaultInstall)) 'A command wrote the default per-user install location.'
    }
    $outsideHits = @(Get-ChildItem -LiteralPath $testRoot -Recurse -Force | Where-Object {
        ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    })
    Assert-InstallTest ($outsideHits.Count -eq 0) 'A reparse point was created under the test root.'

    $installSource = Join-Path $repoRoot 'src\install'
    foreach ($file in @(Get-ChildItem -LiteralPath $installSource -File -Filter '*.ps1')) {
        $text = [IO.File]::ReadAllText($file.FullName)
        Assert-InstallTest ($text -notmatch 'HKLM') 'Install source references HKLM.'
        Assert-InstallTest ($text -notmatch 'LocalMachine') 'Install source references HKLM LocalMachine.'
        Assert-InstallTest ($text -notmatch 'Invoke-WebRequest') 'Install source contacts the network.'
        Assert-InstallTest ($text -notmatch 'Invoke-RestMethod') 'Install source contacts the network.'
        Assert-InstallTest ($text -notmatch 'HttpClient') 'Install source contacts the network.'
        Assert-InstallTest ($text -notmatch 'Start-Process') 'Install source launches a process via Start-Process.'
        Assert-InstallTest ($text -notmatch 'RunAs') 'Install source requests elevation.'
        Assert-InstallTest ($text.IndexOf($usersPrefix, [StringComparison]::OrdinalIgnoreCase) -lt 0) 'Install source contains an absolute user path.'
        Assert-InstallTest ($text -notmatch 'Program Files') 'Install source writes toward Program Files.'
    }

    $script:installShipsLicense = 1

    [ordered]@{
        success = $true
        assertions = $assertions
        install_lifecycle = $installLifecycle
        install_idempotent = $installIdempotent
        uninstall_no_residue = $uninstallNoResidue
        doctor_read_only = $doctorReadOnly
        doctor_drift_detected = $doctorDriftDetected
        update_preserves_state = $updatePreservesState
        update_replaces_incompatible_watcher = $updateReplacesIncompatibleWatcher
        install_ships_license = $installShipsLicense
        child_harness_launch = $childHarnessLaunch
        install_pending_idle_activation = $installPendingIdleActivation
        doctor_task_identity = $doctorTaskIdentity
        recycle_transient_retry = $recycleTransientRetry
        recycle_real_windows_probe = $recycleRealWindowsProbe
        recycle_foreign_owner_refused = $recycleForeignOwnerRefused
        uninstall_convergent_lifecycle = $uninstallConvergentLifecycle
        uninstall_remove_state = $uninstallRemoveState
        local_appdata_safe_oracle = $localAppDataSafeOracle
        empty_file_fingerprint = $emptyFileFingerprint
        residue = $false
    } | ConvertTo-Json -Compress
} catch {
    [ordered]@{
        success = $false
        error = [string]$_.Exception.Message
        assertions = $assertions
        install_lifecycle = $installLifecycle
        install_idempotent = $installIdempotent
        uninstall_no_residue = $uninstallNoResidue
        doctor_read_only = $doctorReadOnly
        doctor_drift_detected = $doctorDriftDetected
        update_preserves_state = $updatePreservesState
        update_replaces_incompatible_watcher = $updateReplacesIncompatibleWatcher
        install_ships_license = $installShipsLicense
        child_harness_launch = $childHarnessLaunch
        install_pending_idle_activation = $installPendingIdleActivation
        doctor_task_identity = $doctorTaskIdentity
        recycle_transient_retry = $recycleTransientRetry
        recycle_real_windows_probe = $recycleRealWindowsProbe
        recycle_foreign_owner_refused = $recycleForeignOwnerRefused
        uninstall_convergent_lifecycle = $uninstallConvergentLifecycle
        uninstall_remove_state = $uninstallRemoveState
        local_appdata_safe_oracle = $localAppDataSafeOracle
        empty_file_fingerprint = $emptyFileFingerprint
    } | ConvertTo-Json -Compress
    exit 1
}

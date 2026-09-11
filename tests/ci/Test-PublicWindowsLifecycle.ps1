# SPDX-License-Identifier: MPL-2.0
# GitHub-hosted Windows public ZIP install/background/ownership lifecycle.
# Local shared-host Install/Start/Update/Uninstall is refused.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExtractedWindowsRoot,
    [Parameter(Mandatory = $true)][string]$WindowsZip,
    [Parameter(Mandatory = $true)][string]$SourceZip,
    [Parameter(Mandatory = $true)][string]$AssetRoot,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]$env:GITHUB_ACTIONS -cne 'true') {
    throw 'Test-PublicWindowsLifecycle.ps1 installs only on a GitHub-hosted Windows runner. Local shared-host Install/Start/Update/Uninstall is not authorized.'
}

$pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$extract = [IO.Path]::GetFullPath($ExtractedWindowsRoot).TrimEnd('\')
$evidence = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\')
$assetRoot = [IO.Path]::GetFullPath($AssetRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($evidence) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $evidence 'command-results')) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $evidence 'snapshots')) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $evidence 'task')) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $evidence 'wired-run')) | Out-Null

$runId = if (-not [string]::IsNullOrWhiteSpace([string]$env:GITHUB_RUN_ID)) { [string]$env:GITHUB_RUN_ID } else { [guid]::NewGuid().ToString('N') }
$jobHome = [IO.Path]::GetFullPath((Join-Path ([string]$env:LOCALAPPDATA) ('telephone-line-windows-lifecycle-' + $runId))).TrimEnd('\')
$installRoot = Join-Path $jobHome 'install'
$secondRoot = Join-Path $jobHome 'second-install'
$lineState = Join-Path $jobHome 'line-state'
$supervisorState = Join-Path $installRoot 'supervisor-state'
$foreignState = Join-Path $jobHome 'foreign-supervisor-state'
$workRoot = Join-Path $jobHome 'work'
$desktopRoot = Join-Path $jobHome 'desktop'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')

function Get-Sha256Bytes {
    param([byte[]]$Bytes)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant()
}

function Get-Sha256File {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return $null }
    return (Get-Sha256Bytes -Bytes ([IO.File]::ReadAllBytes($Path)))
}

function Get-Sha256Text {
    param([string]$Text)
    return (Get-Sha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes([string]$Text)))
}

function Write-Utf8Json {
    param([string]$Path, [object]$Value)
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllBytes($Path, [Text.UTF8Encoding]::new($false).GetBytes((($Value | ConvertTo-Json -Depth 32) + "`n")))
}

function Read-JsonOrNull {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 32) } catch { return $null }
}

function Get-TreeFingerprint {
    param([string]$Root)
    $full = if ([string]::IsNullOrWhiteSpace($Root)) { $null } else { [IO.Path]::GetFullPath($Root).TrimEnd('\') }
    if ($null -eq $full -or -not [IO.Directory]::Exists($full)) {
        return [ordered]@{ present = $false; root = $full; file_count = 0; sha256 = $null; files = @() }
    }
    $rows = [Collections.Generic.List[string]]::new()
    $files = [Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $rel = $file.FullName.Substring($full.Length).TrimStart('\').Replace('\', '/')
        [void]$files.Add($rel)
        [void]$rows.Add($rel + '|' + [string]$file.Length + '|' + (Get-Sha256File -Path $file.FullName))
    }
    $material = ($rows -join "`n")
    return [ordered]@{ present = $true; root = $full; file_count = $rows.Count; sha256 = (Get-Sha256Text -Text $material); files = @($files) }
}

function Get-DesktopInventory {
    $names = @()
    $owned = [ordered]@{
        emergency = $false
        console = $false
        emergency_bytes = 0
        console_bytes = 0
    }
    if ([IO.Directory]::Exists($desktopRoot)) {
        $names = @(Get-ChildItem -LiteralPath $desktopRoot -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
        $emerg = Join-Path $desktopRoot '有线电话｜紧急停止.lnk'
        $console = Join-Path $desktopRoot '有线电话｜控制台.lnk'
        $owned.emergency = [IO.File]::Exists($emerg)
        $owned.console = [IO.File]::Exists($console)
        if ([bool]$owned.emergency) { $owned.emergency_bytes = [int64](Get-Item -LiteralPath $emerg).Length }
        if ([bool]$owned.console) { $owned.console_bytes = [int64](Get-Item -LiteralPath $console).Length }
    }
    return [ordered]@{ names = @($names); owned = $owned }
}

function Get-ScheduledTaskEvidence {
    $xml = $null
    $xmlSha = $null
    $info = $null
    $lastRun = $null
    try {
        $task = Get-ScheduledTask -TaskName 'TelephoneLineWiredSupervisor' -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            $xml = [string](Export-ScheduledTask -TaskName 'TelephoneLineWiredSupervisor')
            $xmlSha = Get-Sha256Text -Text $xml
            $action = @($task.Actions)[0]
            $info = [ordered]@{
                task_name = [string]$task.TaskName
                execute = $(if ($null -ne $action) { [string]$action.Execute } else { '' })
                arguments = $(if ($null -ne $action) { [string]$action.Arguments } else { '' })
                working_directory = $(if ($null -ne $action) { [string]$action.WorkingDirectory } else { '' })
                logon_type = $(if ($null -ne $task.Principal) { [string]$task.Principal.LogonType } else { '' })
                run_level = $(if ($null -ne $task.Principal) { [string]$task.Principal.RunLevel } else { '' })
                hidden = [bool]$task.Settings.Hidden
            }
            try {
                $ti = Get-ScheduledTaskInfo -TaskName 'TelephoneLineWiredSupervisor' -ErrorAction SilentlyContinue
                if ($null -ne $ti) {
                    $lastRun = [ordered]@{
                        last_run_time = [string]$ti.LastRunTime
                        last_task_result = [int]$ti.LastTaskResult
                        number_of_missed_runs = [int]$ti.NumberOfMissedRuns
                    }
                }
            } catch { }
        }
    } catch { }
    return [ordered]@{ registered = (-not [string]::IsNullOrWhiteSpace($xml)); xml = $xml; xml_sha256 = $xmlSha; info = $info; last_run = $lastRun }
}

function Get-WrapperForm {
    param([object]$TaskInfo)
    $execute = if ($null -ne $TaskInfo) { [string]$TaskInfo.execute } else { '' }
    $arguments = if ($null -ne $TaskInfo) { [string]$TaskInfo.arguments } else { '' }
    $leaf = if ([string]::IsNullOrWhiteSpace($execute)) { '' } else { [IO.Path]::GetFileName($execute) }
    $sidecar = Join-Path $installRoot 'src\supervisor\SupervisorNoConsoleHost.exe.identity.json'
    $identity = Read-JsonOrNull -Path $sidecar
    if ($leaf -match '(?i)^wscript\.exe$' -and $arguments -match '(?i)Invoke-TelephoneSupervisorHidden\.vbs') { return 'wscript_hidden_vbs' }
    if ($leaf -match '(?i)^SupervisorNoConsoleHost\.exe$' -and $null -ne $identity -and [string]$identity.protocol_version -ceq 'telephone-line-supervisor-wrapper-identity-v1') {
        return 'verified_wrapper_identity_sidecar'
    }
    if ($leaf -match '(?i)\.exe$') { return 'filename_only_exe_not_enough' }
    return 'unknown'
}

function Open-ExactProcess {
    param([int]$ProcessId, [int64]$StartTicks)
    if ($ProcessId -le 0 -or $StartTicks -le 0) { return $null }
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        if ([int64]$proc.StartTime.ToUniversalTime().Ticks -ne [int64]$StartTicks) {
            $proc.Dispose()
            return [ordered]@{ mismatch = $true; process = $null; disappeared = $false }
        }
        return [ordered]@{ mismatch = $false; process = $proc; disappeared = $false }
    } catch {
        return [ordered]@{ mismatch = $false; process = $null; disappeared = $true }
    }
}

function Copy-TreeIfPresent {
    param([string]$From, [string]$To)
    if (-not [IO.Directory]::Exists($From)) { return }
    [IO.Directory]::CreateDirectory($To) | Out-Null
    foreach ($file in @(Get-ChildItem -LiteralPath $From -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $file.FullName.Substring($From.Length).TrimStart('\')
        $dest = Join-Path $To $rel
        $parent = [IO.Path]::GetDirectoryName($dest)
        if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
    }
}

function Invoke-Product {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [hashtable]$ExtraEnvironment
    )
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory) -and [IO.Directory]::Exists($WorkingDirectory)) {
        $info.WorkingDirectory = $WorkingDirectory
    }
    $info.Environment['TELEPHONE_LINE_INSTALL_ROOT'] = $installRoot
    $info.Environment['TELEPHONE_LINE_STATE_ROOT'] = $lineState
    $info.Environment['TELEPHONE_LINE_SUPERVISOR_STATE_ROOT'] = $supervisorState
    $info.Environment['TELEPHONE_LINE_SOURCE_ROOT'] = $extract
    $info.Environment['TELEPHONE_LINE_DESKTOP_ROOT'] = $desktopRoot
    if ($null -ne $ExtraEnvironment) {
        foreach ($k in $ExtraEnvironment.Keys) { $info.Environment[[string]$k] = [string]$ExtraEnvironment[$k] }
    }
    foreach ($a in @('-Sta', '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $File)) {
        [void]$info.ArgumentList.Add($a)
    }
    foreach ($a in @($ArgumentList)) { [void]$info.ArgumentList.Add([string]$a) }
    $p = [Diagnostics.Process]::Start($info)
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $parsed = $null
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        try { $parsed = $stdout | ConvertFrom-Json -AsHashtable -Depth 32 } catch { $parsed = $null }
    }
    $code = ''
    if ($parsed -is [Collections.IDictionary] -and $parsed.Contains('code')) { $code = [string]$parsed.code }
    return [ordered]@{
        file = $File
        exit_code = [int]$p.ExitCode
        stdout = $stdout
        stderr = $stderr
        parsed = $parsed
        code = $code
        ok = $(if ($parsed -is [Collections.IDictionary] -and $parsed.Contains('ok')) { [bool]$parsed.ok } else { ([int]$p.ExitCode -eq 0) })
    }
}

function Assert-IndependentRoots {
    $named = @(
        @{ name = 'install'; path = $installRoot },
        @{ name = 'second'; path = $secondRoot },
        @{ name = 'line'; path = $lineState },
        @{ name = 'foreign'; path = $foreignState },
        @{ name = 'work'; path = $workRoot },
        @{ name = 'desktop'; path = $desktopRoot },
        @{ name = 'extract'; path = $extract }
    )
    for ($i = 0; $i -lt $named.Count; $i++) {
        $a = [IO.Path]::GetFullPath($named[$i].path).TrimEnd('\')
        for ($j = $i + 1; $j -lt $named.Count; $j++) {
            $b = [IO.Path]::GetFullPath($named[$j].path).TrimEnd('\')
            if ($a.Equals($b, [StringComparison]::OrdinalIgnoreCase)) { throw ('Overlapping lifecycle roots: ' + [string]$named[$i].name) }
        }
    }
    foreach ($root in @($installRoot, $secondRoot, $lineState, $foreignState, $jobHome)) {
        $full = [IO.Path]::GetFullPath($root).TrimEnd('\')
        if ($full.Equals($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or ($full + '\').StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw ('Install/state root is under TEMP and would take the mock scheduler path: ' + $full)
        }
    }
    if (-not $supervisorState.StartsWith($installRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Supervisor state must be the install-owned supervisor-state directory.'
    }
}

$stages = [ordered]@{}
$pass = $false
$blocked = $false
$failure = $null
$localWorkOk = $false
$installOk = $false
$doctorHealthy = $false
$wiredShared = $false
$secondOk = $false
$removeOk = $false
$updateOk = $false
$wrapperOk = $false
$uninstallOk = $false
$foreignKept = $false
$safetyCleanup = [ordered]@{ used = $false; product_uninstall_pass = $false }

try {
    Assert-IndependentRoots
    foreach ($dir in @($jobHome, $secondRoot, $lineState, $foreignState, $workRoot, $desktopRoot)) {
        [IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    $foreignMarker = Join-Path $foreignState 'foreign-marker.txt'
    [IO.File]::WriteAllText($foreignMarker, "foreign-supervisor-state`n", [Text.UTF8Encoding]::new($false))
    $foreignBefore = Get-TreeFingerprint -Root $foreignState

    if (-not [IO.File]::Exists((Join-Path $extract 'src\install\Install-TelephoneLine.ps1'))) {
        throw 'Extracted Windows tree is missing the public Install entry.'
    }
    if ([IO.Directory]::Exists((Join-Path $extract 'tests'))) {
        throw 'Windows ZIP extract unexpectedly contains tests/.'
    }

    $hostFacts = [ordered]@{
        apartment = [string][Threading.Thread]::CurrentThread.GetApartmentState()
        ansi_codepage = [int][Text.Encoding]::Default.CodePage
        culture = [string][Globalization.CultureInfo]::CurrentCulture.Name
        ui_culture = [string][Globalization.CultureInfo]::CurrentUICulture.Name
    }
    Write-Utf8Json -Path (Join-Path $evidence 'command-results\host-com-facts.json') -Value $hostFacts

    $desktopProbe = [ordered]@{ ascii = [ordered]@{ ok = $false }; product_names = [ordered]@{ ok = $false }; diagnostic_only = $true }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $asciiPath = Join-Path $desktopRoot 'lifecycle-desktop-probe.lnk'
        $shortcut = $shell.CreateShortcut($asciiPath)
        $shortcut.TargetPath = $pwsh
        $shortcut.WorkingDirectory = $workRoot
        $shortcut.Save()
        $desktopProbe.ascii.ok = [IO.File]::Exists($asciiPath)
        $desktopProbe.ascii.path = $asciiPath
    } catch {
        $desktopProbe.ascii.ok = $false
        $desktopProbe.ascii.exception = [string]$_.Exception.ToString()
    }
    $staProbe = Join-Path $workRoot 'Invoke-StaDesktopProbe.ps1'
    $staProbeOut = Join-Path $evidence 'command-results\desktop-sta-probe.json'
    $staProbeText = @'
# SPDX-License-Identifier: MPL-2.0
param([string]$DesktopRoot, [string]$WorkingDirectory, [string]$Pwsh, [string]$OutFile)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$result = [ordered]@{
    apartment = [string][Threading.Thread]::CurrentThread.GetApartmentState()
    ascii = [ordered]@{ ok = $false }
    product_names = [ordered]@{ ok = $false }
    note = 'WScript.Shell ANSI probe only; product install uses IShellLinkW.'
}
try {
    $shell = New-Object -ComObject WScript.Shell
    $asciiPath = Join-Path $DesktopRoot 'lifecycle-sta-ascii.lnk'
    $sc = $shell.CreateShortcut($asciiPath)
    $sc.TargetPath = $Pwsh
    $sc.WorkingDirectory = $WorkingDirectory
    $sc.Save()
    $result.ascii.ok = [IO.File]::Exists($asciiPath)
    $result.ascii.path = $asciiPath
    foreach ($name in @('有线电话｜紧急停止.lnk', '有线电话｜控制台.lnk')) {
        $path = Join-Path $DesktopRoot $name
        $sc = $shell.CreateShortcut($path)
        $sc.TargetPath = $Pwsh
        $sc.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $WorkingDirectory 'missing-control.ps1') + '" -Mode Emergency'
        $sc.WorkingDirectory = $WorkingDirectory
        $sc.WindowStyle = 1
        $sc.Save()
        if (-not [IO.File]::Exists($path)) { throw ('STA shortcut missing: ' + $name) }
    }
    $result.product_names.ok = $true
} catch {
    $result.exception = [string]$_.Exception.ToString()
    $result.message = [string]$_.Exception.Message
}
[IO.File]::WriteAllBytes($OutFile, [Text.UTF8Encoding]::new($false).GetBytes((($result | ConvertTo-Json -Depth 8) + [char]10)))
'@
    [IO.File]::WriteAllText($staProbe, $staProbeText.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))
    $staInfo = [Diagnostics.ProcessStartInfo]::new()
    $staInfo.FileName = $pwsh
    $staInfo.UseShellExecute = $false
    $staInfo.RedirectStandardOutput = $true
    $staInfo.RedirectStandardError = $true
    $staInfo.CreateNoWindow = $true
    foreach ($a in @('-Sta', '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $staProbe, '-DesktopRoot', $desktopRoot, '-WorkingDirectory', $workRoot, '-Pwsh', $pwsh, '-OutFile', $staProbeOut)) {
        [void]$staInfo.ArgumentList.Add($a)
    }
    $staProc = [Diagnostics.Process]::Start($staInfo)
    $null = $staProc.StandardOutput.ReadToEnd()
    $staErr = $staProc.StandardError.ReadToEnd()
    $staProc.WaitForExit()
    $desktopProbe.sta_probe_exit = [int]$staProc.ExitCode
    $desktopProbe.sta_probe_stderr = $staErr
    $desktopProbe.sta_probe = Read-JsonOrNull -Path $staProbeOut
    Write-Utf8Json -Path (Join-Path $evidence 'command-results\desktop-com-probe.json') -Value $desktopProbe

    $env:TELEPHONE_LINE_INSTALL_ROOT = $installRoot
    $env:TELEPHONE_LINE_STATE_ROOT = $lineState
    $env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT = $supervisorState
    $env:TELEPHONE_LINE_SOURCE_ROOT = $extract
    $env:TELEPHONE_LINE_DESKTOP_ROOT = $desktopRoot
    Remove-Item Env:TELEPHONE_LINE_TASK_BACKEND -ErrorAction SilentlyContinue
    Remove-Item Env:TELEPHONE_LINE_TASK_STORE -ErrorAction SilentlyContinue
    $install = Invoke-Product -File (Join-Path $extract 'src\install\Install-TelephoneLine.ps1') -WorkingDirectory $extract -ArgumentList @(
        '-InstallRoot', $installRoot, '-SourceRoot', $extract
    )
    Write-Utf8Json -Path (Join-Path $evidence 'command-results\install.json') -Value $install
    $leftover = [ordered]@{
        install_present = [IO.Directory]::Exists($installRoot)
        has_manifest = [IO.File]::Exists((Join-Path $installRoot 'install-manifest.json'))
        has_current = [IO.File]::Exists((Join-Path $installRoot 'current.json'))
        has_control = [IO.File]::Exists((Join-Path $installRoot 'src\supervisor\Show-TelephoneSupervisorControl.ps1'))
        files = @()
        desktop = (Get-DesktopInventory)
    }
    if ([IO.Directory]::Exists($installRoot)) {
        $leftover.files = @(Get-ChildItem -LiteralPath $installRoot -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($installRoot.Length).TrimStart('\').Replace('\', '/') } | Sort-Object)
    }
    Write-Utf8Json -Path (Join-Path $evidence 'command-results\leftover-install.json') -Value $leftover
    if ([bool]$leftover.has_manifest) {
        Copy-Item -LiteralPath (Join-Path $installRoot 'install-manifest.json') -Destination (Join-Path $evidence 'command-results\install-manifest.json') -Force
    }
    if ([bool]$leftover.has_current) {
        Copy-Item -LiteralPath (Join-Path $installRoot 'current.json') -Destination (Join-Path $evidence 'command-results\current.json') -Force
    }
    if (-not [bool]$install.ok) {
        $diagOut = Join-Path $evidence 'command-results\desktop-register-diag.json'
        $diagScript = Join-Path $workRoot 'Invoke-DesktopRegisterDiag.ps1'
        $diagText = @'
# SPDX-License-Identifier: MPL-2.0
param([string]$ExtractRoot, [string]$InstallRoot, [string]$DesktopRoot, [string]$OutFile)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:TELEPHONE_LINE_DESKTOP_ROOT = $DesktopRoot
. (Join-Path $ExtractRoot 'src\install\TelephoneLineInstall.Common.ps1')
$result = [ordered]@{ apartment = [string][Threading.Thread]::CurrentThread.GetApartmentState(); ok = $false }
try {
    Import-TelephoneSupervisorCommon
    $control = Join-Path $InstallRoot 'src\supervisor\Show-TelephoneSupervisorControl.ps1'
    $null = Register-TelephoneSupervisorDesktopShortcuts -InstallRoot $InstallRoot -ControlScript $control
    $result.ok = $true
    $emerg = Join-Path $DesktopRoot '有线电话｜紧急停止.lnk'
    $console = Join-Path $DesktopRoot '有线电话｜控制台.lnk'
    $result.emergency_exists = [IO.File]::Exists($emerg)
    $result.console_exists = [IO.File]::Exists($console)
    if ([bool]$result.emergency_exists) { $result.emergency_bytes = [int64](Get-Item -LiteralPath $emerg).Length }
    if ([bool]$result.console_exists) { $result.console_bytes = [int64](Get-Item -LiteralPath $console).Length }
} catch {
    $result.ok = $false
    $result.message = [string]$_.Exception.Message
    $result.exception = [string]$_.Exception.ToString()
    if ($Error.Count -gt 0) { $result.script_stack = [string]$Error[0].ScriptStackTrace }
}
[IO.File]::WriteAllBytes($OutFile, [Text.UTF8Encoding]::new($false).GetBytes((($result | ConvertTo-Json -Depth 8) + [char]10)))
'@
        [IO.File]::WriteAllText($diagScript, $diagText.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))
        $null = Invoke-Product -File $diagScript -WorkingDirectory $workRoot -ArgumentList @(
            '-ExtractRoot', $extract, '-InstallRoot', $installRoot, '-DesktopRoot', $desktopRoot, '-OutFile', $diagOut
        )
    }
    $desktopAfterInstall = Get-DesktopInventory
    Write-Utf8Json -Path (Join-Path $evidence 'command-results\desktop-after-install.json') -Value $desktopAfterInstall
    $stages.install = [ordered]@{
        ok = [bool]$install.ok
        code = [string]$install.code
        exit_code = [int]$install.exit_code
        owned_shortcuts = $desktopAfterInstall.owned
    }
    if (-not [bool]$install.ok -or [string]$install.code -cnotin @('INSTALLED', 'ALREADY_CURRENT')) {
        $blocked = $true
        $failure = 'Install did not succeed; later mutating stages were not started.'
    } elseif (-not [bool]$desktopAfterInstall.owned.emergency -or -not [bool]$desktopAfterInstall.owned.console -or [int64]$desktopAfterInstall.owned.emergency_bytes -lt 1 -or [int64]$desktopAfterInstall.owned.console_bytes -lt 1) {
        $blocked = $true
        $failure = 'Install reported success but owned Unicode desktop shortcuts were missing or empty.'
    } else {
        $installOk = $true
    }

    $taskAfterInstall = Get-ScheduledTaskEvidence
    if ($null -ne $taskAfterInstall.xml) {
        [IO.File]::WriteAllText((Join-Path $evidence 'task\after-install.xml'), $taskAfterInstall.xml, [Text.UTF8Encoding]::new($false))
    }
    Write-Utf8Json -Path (Join-Path $evidence 'task\after-install.json') -Value $taskAfterInstall

    if (-not $blocked) {
        $doctor = Invoke-Product -File (Join-Path $installRoot 'src\install\Invoke-TelephoneLineDoctor.ps1') -WorkingDirectory $installRoot -ArgumentList @(
            '-InstallRoot', $installRoot, '-StateRoot', $lineState, '-SupervisorStateRoot', $supervisorState
        )
        Write-Utf8Json -Path (Join-Path $evidence 'command-results\doctor.json') -Value $doctor
        $healthy = $false
        if ($doctor.parsed -is [Collections.IDictionary] -and [bool]$doctor.parsed.healthy -eq $true -and [string]$doctor.parsed.code -ceq 'HEALTHY') { $healthy = $true }
        $stages.doctor = [ordered]@{ ok = [bool]$doctor.ok; code = [string]$doctor.code; healthy = $healthy; exit_code = [int]$doctor.exit_code }
        if (-not $healthy) {
            $blocked = $true
            $failure = 'Doctor was not HEALTHY; later mutating stages were not started.'
        } else {
            $doctorHealthy = $true
        }
    }

    $current = Read-JsonOrNull -Path (Join-Path $installRoot 'current.json')
    $versionId = if ($null -ne $current -and $current.Contains('version_id')) { [string]$current.version_id } else { '' }
    $sourceSha = if ($null -ne $current -and $current.Contains('source_sha256')) { [string]$current.source_sha256 } else { $versionId }

    if (-not $blocked) {
        . (Join-Path $installRoot 'src\supervisor\TelephoneSupervisor.Common.ps1')
        $nonce = [guid]::NewGuid().ToString('N')
        $phrase = 'telephone-line-public-install-lifecycle-work'
        $inputPath = Join-Path $workRoot 'input.json'
        $outputPath = Join-Path $workRoot 'output.json'
        $stdoutPath = Join-Path $workRoot 'stdout.txt'
        $stderrPath = Join-Path $workRoot 'stderr.txt'
        $terminalPath = Join-Path $workRoot 'terminal.json'
        $workerPath = Join-Path $workRoot 'Invoke-PublicInstallLifecycleWork.ps1'
        $wiredPath = Join-Path $workRoot 'wired-request.json'
        $inputDoc = [ordered]@{
            protocol_version = 'telephone-line-public-install-lifecycle-input-v1'
            purpose = 'public_install_background_verification'
            not_ai = $true
            not_original_lead_callback = $true
            nonce = $nonce
            phrase = $phrase
        }
        Write-Utf8Json -Path $inputPath -Value $inputDoc
        $inputSha = Get-Sha256File -Path $inputPath
        $worker = @'
# SPDX-License-Identifier: MPL-2.0
# Public install/background verification worker. Not an AI task and not an original Lead callback.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputFile,
    [Parameter(Mandatory = $true)][string]$OutputFile,
    [Parameter(Mandatory = $true)][string]$StdoutFile,
    [Parameter(Mandatory = $true)][string]$StderrFile,
    [Parameter(Mandatory = $true)][string]$TerminalFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$raw = [IO.File]::ReadAllBytes($InputFile)
$inputSha = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw))).ToLowerInvariant()
$doc = (Get-Content -LiteralPath $InputFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 8)
$proc = Get-Process -Id $PID
try {
    $out = [ordered]@{
        protocol_version = 'telephone-line-public-install-lifecycle-work-v1'
        purpose = 'public_install_background_verification'
        not_ai = $true
        not_original_lead_callback = $true
        nonce = [string]$doc.nonce
        phrase = [string]$doc.phrase
        input_sha256 = $inputSha
        pid = [int]$proc.Id
        start_time_utc_ticks = [int64]$proc.StartTime.ToUniversalTime().Ticks
        started_at_utc = $proc.StartTime.ToUniversalTime().ToString('o')
        exit_code_intent = 0
    }
    $text = (($out | ConvertTo-Json -Depth 8) + "`n")
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    [IO.File]::WriteAllBytes($OutputFile, $bytes)
    [IO.File]::WriteAllBytes($StdoutFile, $bytes)
    [IO.File]::WriteAllBytes($StderrFile, [byte[]]@())
    $term = [ordered]@{
        protocol_version = 'telephone-line-public-install-lifecycle-terminal-v1'
        eof = $true
        exit_code_intent = 0
        stdout_sha256 = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
        stderr_bytes = 0
        written_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllBytes($TerminalFile, [Text.UTF8Encoding]::new($false).GetBytes((($term | ConvertTo-Json -Depth 8) + "`n")))
} finally { $proc.Dispose() }
Start-Sleep -Seconds 8
exit 0
'@
        [IO.File]::WriteAllText($workerPath, $worker.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))
        $sessionId = 'ci-windows-lifecycle-not-ai'
        $wiredRunId = [guid]::NewGuid().ToString()
        $wired = [ordered]@{
            protocol_version = 'telephone-line-wired-supervisor-request-v1'
            run_id = $wiredRunId
            project = 'telephone-windows-lifecycle'
            stage = 'public-install-background-verification'
            lead_session_id = $sessionId
            lead_run_id = ('ci-' + [guid]::NewGuid().ToString())
            summary = 'GitHub Windows VM public install/background verification via Start-TelephoneWiredRun generic command; not AI and not original Lead callback'
            worktree = $workRoot
            command = [ordered]@{
                executable = $pwsh
                working_directory = $workRoot
                arguments = @(
                    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                    '-File', $workerPath,
                    '-InputFile', $inputPath,
                    '-OutputFile', $outputPath,
                    '-StdoutFile', $stdoutPath,
                    '-StderrFile', $stderrPath,
                    '-TerminalFile', $terminalPath
                )
            }
            installed_version = [ordered]@{
                version_id = $versionId
                source_sha256 = $sourceSha
                install_root = $installRoot
            }
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $wired['request_sha256'] = Get-TelephoneSupervisorRequestHash -Request $wired
        Write-Utf8Json -Path $wiredPath -Value $wired
        Copy-Item -LiteralPath $wiredPath -Destination (Join-Path $evidence 'wired-run\wired-request.json') -Force

        $taskBeforeStart = Get-ScheduledTaskEvidence
        $wiredRun = Invoke-Product -File (Join-Path $installRoot 'src\supervisor\Start-TelephoneWiredRun.ps1') -WorkingDirectory $installRoot -ArgumentList @(
            '-RequestFile', $wiredPath, '-StateRoot', $supervisorState, '-InstallRoot', $installRoot
        )
        Write-Utf8Json -Path (Join-Path $evidence 'command-results\wired-run.json') -Value $wiredRun
        $taskAfterStart = Get-ScheduledTaskEvidence
        if ($null -ne $taskAfterStart.xml) {
            [IO.File]::WriteAllText((Join-Path $evidence 'task\after-wired-start.xml'), $taskAfterStart.xml, [Text.UTF8Encoding]::new($false))
        }
        Write-Utf8Json -Path (Join-Path $evidence 'task\after-wired-start.json') -Value $taskAfterStart
        $consumer = ''
        $sharedStarted = $false
        $publishedRunId = ''
        if ($wiredRun.parsed -is [Collections.IDictionary]) {
            if ($wiredRun.parsed.Contains('start_consumer')) { $consumer = [string]$wiredRun.parsed.start_consumer }
            if ($wiredRun.parsed.Contains('shared_task_started')) { $sharedStarted = [bool]$wiredRun.parsed.shared_task_started }
            if ($wiredRun.parsed.Contains('run_id')) { $publishedRunId = [string]$wiredRun.parsed.run_id }
        }
        $stages.wired_run_id = $publishedRunId
        if ($consumer -match '(?i)HostVisible' -or $consumer -eq 'Start-TelephoneSupervisorHostVisible.ps1') {
            $blocked = $true
            $failure = 'Start used the internal HostVisible consumer instead of the registered scheduled task.'
        } elseif (-not $sharedStarted) {
            $blocked = $true
            $failure = 'Start-TelephoneWiredRun did not start the registered shared scheduled task. Failure kept; principal/trigger were not rewritten.'
        } elseif ($publishedRunId -cne $wiredRunId) {
            $blocked = $true
            $failure = 'Start-TelephoneWiredRun run_id did not match the published request.'
        } else {
            $wiredShared = $true
        }
        $stages.wired = [ordered]@{
            ok = [bool]$wiredRun.ok
            shared_task_started = $sharedStarted
            start_consumer = $consumer
            published = $(if ($wiredRun.parsed -is [Collections.IDictionary] -and $wiredRun.parsed.Contains('published')) { [bool]$wiredRun.parsed.published } else { $null })
            triggered = $(if ($wiredRun.parsed -is [Collections.IDictionary] -and $wiredRun.parsed.Contains('triggered')) { [bool]$wiredRun.parsed.triggered } else { $null })
            task_xml_sha256 = [string]$taskAfterStart.xml_sha256
            last_run = $taskAfterStart.last_run
        }

        if (-not $blocked) {
            $runDir = Join-Path $supervisorState ('runs\' + $wiredRunId)
            $ownerPath = Join-Path $runDir 'owner.json'
            $launchPath = Join-Path $runDir 'launch-intent.json'
            $membersPath = Join-Path $runDir 'job-members.json'
            $outboxPath = Get-TelephoneSupervisorRecordPath -StateRoot $supervisorState -Kind outbox -RunId $wiredRunId
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(180)
            $collect = [ordered]@{ status = 'IN_PROGRESS'; pass = $false }
            $workerProc = $null
            $wrapperProc = $null
            $workerExit = $null
            $wrapperExit = $null
            $workerDisappeared = $false
            $wrapperDisappeared = $false
            $workerMismatch = $false
            $wrapperMismatch = $false
            try {
                while ([DateTimeOffset]::UtcNow -lt $deadline) {
                    $owner = Read-JsonOrNull -Path $ownerPath
                    $launch = Read-JsonOrNull -Path $launchPath
                    $outDoc = Read-JsonOrNull -Path $outputPath
                    $termDoc = Read-JsonOrNull -Path $terminalPath
                    $outbox = Read-JsonOrNull -Path $outboxPath
                    if ($null -eq $wrapperProc -and -not $wrapperDisappeared -and $null -ne $owner -and $owner.Contains('pid') -and $owner.Contains('start_time_utc_ticks')) {
                        $opened = Open-ExactProcess -ProcessId ([int]$owner.pid) -StartTicks ([int64]$owner.start_time_utc_ticks)
                        if ($null -ne $opened -and [bool]$opened.mismatch) { $wrapperMismatch = $true; break }
                        if ($null -ne $opened -and $null -ne $opened.process) { $wrapperProc = $opened.process }
                        elseif ($null -ne $opened -and [bool]$opened.disappeared) { $wrapperDisappeared = $true }
                    }
                    if ($null -eq $workerProc -and -not $workerDisappeared -and $null -ne $outDoc -and $outDoc.Contains('pid') -and $outDoc.Contains('start_time_utc_ticks')) {
                        $opened = Open-ExactProcess -ProcessId ([int]$outDoc.pid) -StartTicks ([int64]$outDoc.start_time_utc_ticks)
                        if ($null -ne $opened -and [bool]$opened.mismatch) { $workerMismatch = $true; break }
                        if ($null -ne $opened -and $null -ne $opened.process) { $workerProc = $opened.process }
                        elseif ($null -ne $opened -and [bool]$opened.disappeared) { $workerDisappeared = $true }
                    }
                    if ($null -ne $workerProc -and $null -eq $workerExit) {
                        if ($workerProc.HasExited -or $workerProc.WaitForExit(400)) {
                            if ($workerProc.HasExited) { $workerExit = [int]$workerProc.ExitCode }
                        }
                    }
                    if ($null -ne $wrapperProc -and $null -eq $wrapperExit) {
                        if ($wrapperProc.HasExited -or $wrapperProc.WaitForExit(400)) {
                            if ($wrapperProc.HasExited) { $wrapperExit = [int]$wrapperProc.ExitCode }
                        }
                    }
                    $contentOk = $false
                    if ($null -ne $outDoc) {
                        $contentOk = (
                            [string]$outDoc.protocol_version -ceq 'telephone-line-public-install-lifecycle-work-v1' -and
                            [bool]$outDoc.not_ai -eq $true -and
                            [bool]$outDoc.not_original_lead_callback -eq $true -and
                            [string]$outDoc.nonce -ceq $nonce -and
                            [string]$outDoc.phrase -ceq $phrase -and
                            [string]$outDoc.input_sha256 -ceq $inputSha
                        )
                    }
                    $eofOk = $false
                    if ($null -ne $termDoc -and [bool]$termDoc.eof -eq $true -and [int]$termDoc.exit_code_intent -eq 0) {
                        $stdoutSha = Get-Sha256File -Path $stdoutPath
                        $outputSha = Get-Sha256File -Path $outputPath
                        $stderrBytes = if ([IO.File]::Exists($stderrPath)) { [int64](Get-Item -LiteralPath $stderrPath).Length } else { -1 }
                        $eofOk = (
                            -not [string]::IsNullOrWhiteSpace($stdoutSha) -and
                            $stdoutSha -ceq $outputSha -and
                            $stdoutSha -ceq [string]$termDoc.stdout_sha256 -and
                            $stderrBytes -eq 0 -and
                            [int64]$termDoc.stderr_bytes -eq 0
                        )
                    }
                    $outboxOk = ($null -ne $outbox -and [string]$outbox.terminal -ceq 'completed' -and [string]$outbox.run_id -ceq $wiredRunId)
                    $ownerOk = $false
                    if ($null -ne $owner -and $null -ne $outDoc -and $null -ne $launch) {
                        $ownerOk = (
                            [string]$owner.run_id -ceq $wiredRunId -and
                            [int]$owner.lead_pid -eq [int]$outDoc.pid -and
                            [int64]$owner.lead_start_time_utc_ticks -eq [int64]$outDoc.start_time_utc_ticks -and
                            [int]$owner.pid -eq [int]$launch.pid -and
                            [int64]$owner.start_time_utc_ticks -eq [int64]$launch.start_time_utc_ticks
                        )
                    }
                    if ($contentOk -and $eofOk -and $outboxOk -and $ownerOk -and $null -ne $workerExit -and $null -ne $wrapperExit) {
                        if ([int]$workerExit -eq 0 -and [int]$wrapperExit -eq 0 -and [int]$outDoc.exit_code_intent -eq 0) {
                            $collect.status = 'PASS'
                            $collect.pass = $true
                            $collect.output = $outDoc
                            $collect.terminal = $termDoc
                            $collect.owner = $owner
                            $collect.launch_intent = $launch
                            $collect.outbox = $outbox
                            $collect.worker_pid = [int]$outDoc.pid
                            $collect.worker_start_time_utc_ticks = [int64]$outDoc.start_time_utc_ticks
                            $collect.worker_exit_code = [int]$workerExit
                            $collect.wrapper_pid = [int]$owner.pid
                            $collect.wrapper_start_time_utc_ticks = [int64]$owner.start_time_utc_ticks
                            $collect.wrapper_exit_code = [int]$wrapperExit
                            $collect.output_sha256 = Get-Sha256File -Path $outputPath
                            $collect.stdout_sha256 = Get-Sha256File -Path $stdoutPath
                            $collect.stderr_bytes = [int64](Get-Item -LiteralPath $stderrPath).Length
                            $collect.input_sha256 = $inputSha
                            $collect.independently_expected = [ordered]@{ nonce = $nonce; phrase = $phrase; input_sha256 = $inputSha }
                            break
                        } else {
                            $collect.detail = 'Measured exit codes were not both 0.'
                            break
                        }
                    }
                    if ($workerMismatch -or $wrapperMismatch) { break }
                    Start-Sleep -Milliseconds 200
                }
            } finally {
                if ($null -ne $workerProc) { try { $workerProc.Dispose() } catch { } }
                if ($null -ne $wrapperProc) { try { $wrapperProc.Dispose() } catch { } }
            }
            Copy-TreeIfPresent -From $runDir -To (Join-Path $evidence 'wired-run\run')
            if ([IO.File]::Exists($outboxPath)) { Copy-Item -LiteralPath $outboxPath -Destination (Join-Path $evidence 'wired-run\outbox.json') -Force }
            if ([IO.File]::Exists($outputPath)) { Copy-Item -LiteralPath $outputPath -Destination (Join-Path $evidence 'wired-run\output.json') -Force }
            if ([IO.File]::Exists($stdoutPath)) { Copy-Item -LiteralPath $stdoutPath -Destination (Join-Path $evidence 'wired-run\stdout.txt') -Force }
            if ([IO.File]::Exists($stderrPath)) { Copy-Item -LiteralPath $stderrPath -Destination (Join-Path $evidence 'wired-run\stderr.txt') -Force }
            if ([IO.File]::Exists($terminalPath)) { Copy-Item -LiteralPath $terminalPath -Destination (Join-Path $evidence 'wired-run\terminal.json') -Force }
            $collect.worker_exit_code = $workerExit
            $collect.wrapper_exit_code = $wrapperExit
            $collect.worker_disappeared_before_wait = $workerDisappeared
            $collect.wrapper_disappeared_before_wait = $wrapperDisappeared
            $collect.pid_start_mismatch = ($workerMismatch -or $wrapperMismatch)
            $collect.members = Read-JsonOrNull -Path $membersPath
            $collect.task_after_start = $taskAfterStart.info
            $collect.task_last_run = $taskAfterStart.last_run
            if ([string]$collect.status -cne 'PASS') {
                $collect.status = 'FAIL'
                if ([string]::IsNullOrWhiteSpace([string]$collect.detail)) {
                    if ($workerDisappeared -or $wrapperDisappeared) {
                        $collect.detail = 'A required process disappeared before WaitForExit; disappearance is not success.'
                    } elseif ($null -eq $workerExit -or $null -eq $wrapperExit) {
                        $collect.detail = 'Bounded collection did not obtain measured worker and per-run wrapper exit codes. Timeout, missing exit, or unknown exit is not success.'
                    } else {
                        $collect.detail = 'Fixed output, EOF files, task/run records, and measured exits did not all agree.'
                    }
                }
                $blocked = $true
                $failure = [string]$collect.detail
            } else {
                $localWorkOk = $true
            }
            Write-Utf8Json -Path (Join-Path $evidence 'command-results\local-work-collect.json') -Value $collect
            $stages.local_work = $collect
        }
    }

    if (-not $blocked) {
        $beforeConflictInstall = Get-TreeFingerprint -Root $installRoot
        $beforeConflictTask = Get-ScheduledTaskEvidence
        $second = Invoke-Product -File (Join-Path $extract 'src\install\Install-TelephoneLine.ps1') -WorkingDirectory $extract -ArgumentList @(
            '-InstallRoot', $secondRoot, '-SourceRoot', $extract
        )
        Write-Utf8Json -Path (Join-Path $evidence 'command-results\second-install.json') -Value $second
        $afterConflictInstall = Get-TreeFingerprint -Root $installRoot
        $afterConflictTask = Get-ScheduledTaskEvidence
        $secondOk = (
            -not [bool]$second.ok -and
            [string]$second.code -ceq 'SUPERVISOR_TASK_OWNED_BY_OTHER_INSTALL' -and
            [string]$beforeConflictInstall.sha256 -ceq [string]$afterConflictInstall.sha256 -and
            [string]$beforeConflictTask.xml_sha256 -ceq [string]$afterConflictTask.xml_sha256
        )
        $stages.second_install = [ordered]@{
            ok_field = [bool]$second.ok
            code = [string]$second.code
            owner_install_unchanged = ([string]$beforeConflictInstall.sha256 -ceq [string]$afterConflictInstall.sha256)
            task_xml_unchanged = ([string]$beforeConflictTask.xml_sha256 -ceq [string]$afterConflictTask.xml_sha256)
            accepted = $secondOk
        }
        if (-not $secondOk) {
            $blocked = $true
            $failure = 'Second-root conflict did not refuse with unchanged owner resources.'
        }
    }

    if (-not $blocked) {
        $foreignBeforeRemove = Get-TreeFingerprint -Root $foreignState
        $ownerBeforeRemove = Get-TreeFingerprint -Root $installRoot
        $taskBeforeRemove = Get-ScheduledTaskEvidence
        $remove = Invoke-Product -File (Join-Path $installRoot 'src\install\Uninstall-TelephoneLine.ps1') -WorkingDirectory $installRoot -ArgumentList @(
            '-InstallRoot', $installRoot, '-RemoveState'
        ) -ExtraEnvironment @{ TELEPHONE_LINE_SUPERVISOR_STATE_ROOT = $foreignState }
        Write-Utf8Json -Path (Join-Path $evidence 'command-results\nonowner-removestate.json') -Value $remove
        $foreignAfterRemove = Get-TreeFingerprint -Root $foreignState
        $ownerAfterRemove = Get-TreeFingerprint -Root $installRoot
        $taskAfterRemove = Get-ScheduledTaskEvidence
        $removeOk = (
            -not [bool]$remove.ok -and
            [string]$remove.code -ceq 'SUPERVISOR_STATE_FOREIGN' -and
            [string]$foreignBeforeRemove.sha256 -ceq [string]$foreignAfterRemove.sha256 -and
            [string]$ownerBeforeRemove.sha256 -ceq [string]$ownerAfterRemove.sha256 -and
            [string]$taskBeforeRemove.xml_sha256 -ceq [string]$taskAfterRemove.xml_sha256
        )
        $stages.nonowner_removestate = [ordered]@{
            ok_field = [bool]$remove.ok
            code = [string]$remove.code
            foreign_unchanged = ([string]$foreignBeforeRemove.sha256 -ceq [string]$foreignAfterRemove.sha256)
            owner_unchanged = ([string]$ownerBeforeRemove.sha256 -ceq [string]$ownerAfterRemove.sha256)
            task_xml_unchanged = ([string]$taskBeforeRemove.xml_sha256 -ceq [string]$taskAfterRemove.xml_sha256)
            accepted = $removeOk
        }
        if (-not $removeOk) {
            $blocked = $true
            $failure = 'Non-owner RemoveState did not refuse with unchanged foreign/owner/task hashes.'
        }
    }

    if (-not $blocked) {
        $update = Invoke-Product -File (Join-Path $installRoot 'src\install\Update-TelephoneLine.ps1') -WorkingDirectory $installRoot -ArgumentList @(
            '-InstallRoot', $installRoot, '-SourceRoot', $extract
        )
        Write-Utf8Json -Path (Join-Path $evidence 'command-results\update.json') -Value $update
        $doctor2 = Invoke-Product -File (Join-Path $installRoot 'src\install\Invoke-TelephoneLineDoctor.ps1') -WorkingDirectory $installRoot -ArgumentList @(
            '-InstallRoot', $installRoot, '-StateRoot', $lineState, '-SupervisorStateRoot', $supervisorState
        )
        Write-Utf8Json -Path (Join-Path $evidence 'command-results\doctor-after-update.json') -Value $doctor2
        $taskAfterUpdate = Get-ScheduledTaskEvidence
        if ($null -ne $taskAfterUpdate.xml) {
            [IO.File]::WriteAllText((Join-Path $evidence 'task\after-update.xml'), $taskAfterUpdate.xml, [Text.UTF8Encoding]::new($false))
        }
        Write-Utf8Json -Path (Join-Path $evidence 'task\after-update.json') -Value $taskAfterUpdate
        $wrapperForm = Get-WrapperForm -TaskInfo $taskAfterUpdate.info
        $wrapperOk = ([string]$wrapperForm -cin @('wscript_hidden_vbs', 'verified_wrapper_identity_sidecar'))
        $desktopAfterUpdate = Get-DesktopInventory
        $updateOk = (
            [bool]$update.ok -eq $true -and
            [string]$update.code -cin @('UPDATED', 'ALREADY_CURRENT') -and
            $doctor2.parsed -is [Collections.IDictionary] -and
            [bool]$doctor2.parsed.healthy -eq $true -and
            [string]$doctor2.parsed.code -ceq 'HEALTHY' -and
            $wrapperOk -and
            [bool]$desktopAfterUpdate.owned.emergency -and
            [bool]$desktopAfterUpdate.owned.console
        )
        $stages.update = [ordered]@{
            ok_field = [bool]$update.ok
            code = [string]$update.code
            doctor_healthy = $(if ($doctor2.parsed -is [Collections.IDictionary]) { [bool]$doctor2.parsed.healthy } else { $false })
            wrapper_form = $wrapperForm
            owned_shortcuts = $desktopAfterUpdate.owned
            accepted = $updateOk
        }
        if (-not $updateOk) {
            $blocked = $true
            $failure = 'Same-owner Update/Doctor/wrapper identity did not pass.'
        }
    }

    if (-not $blocked) {
        $uninstall = Invoke-Product -File (Join-Path $installRoot 'src\install\Uninstall-TelephoneLine.ps1') -WorkingDirectory $installRoot -ArgumentList @(
            '-InstallRoot', $installRoot, '-RemoveState'
        )
        Write-Utf8Json -Path (Join-Path $evidence 'command-results\uninstall.json') -Value $uninstall
        $foreignAfterUninstall = Get-TreeFingerprint -Root $foreignState
        $taskAfterUninstall = Get-ScheduledTaskEvidence
        $desktopAfterUninstall = Get-DesktopInventory
        $installAfterUninstall = Get-TreeFingerprint -Root $installRoot
        $lineAfterUninstall = Get-TreeFingerprint -Root $lineState
        $supervisorAfterUninstall = Get-TreeFingerprint -Root $supervisorState
        $foreignKept = (
            [IO.File]::Exists($foreignMarker) -and
            [string]$foreignAfterUninstall.sha256 -ceq [string]$foreignBefore.sha256
        )
        $ownedGone = (
            -not [bool]$desktopAfterUninstall.owned.emergency -and
            -not [bool]$desktopAfterUninstall.owned.console -and
            -not [bool]$taskAfterUninstall.registered -and
            -not [bool]$installAfterUninstall.present -and
            -not [bool]$lineAfterUninstall.present -and
            -not [bool]$supervisorAfterUninstall.present
        )
        $uninstallFreeze = [ordered]@{
            recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            before_job_temp_cleanup = $true
            uninstall_ok_field = [bool]$uninstall.ok
            uninstall_code = [string]$uninstall.code
            residue = $(if ($uninstall.parsed -is [Collections.IDictionary] -and $uninstall.parsed.Contains('residue')) { [bool]$uninstall.parsed.residue } else { $null })
            task = $taskAfterUninstall
            desktop = $desktopAfterUninstall
            install = $installAfterUninstall
            line_state = $lineAfterUninstall
            supervisor_state = $supervisorAfterUninstall
            foreign = $foreignAfterUninstall
            owned_removed = $ownedGone
            foreign_kept = $foreignKept
        }
        Write-Utf8Json -Path (Join-Path $evidence 'command-results\uninstall-freeze.json') -Value $uninstallFreeze
        $uninstallOk = (
            [bool]$uninstall.ok -eq $true -and
            [string]$uninstall.code -ceq 'UNINSTALLED' -and
            $ownedGone -and
            $foreignKept
        )
        $stages.uninstall = [ordered]@{
            ok_field = [bool]$uninstall.ok
            code = [string]$uninstall.code
            foreign_kept = $foreignKept
            task_registered_after = [bool]$taskAfterUninstall.registered
            owned_removed = $ownedGone
            accepted = $uninstallOk
            freeze_before_cleanup = $true
        }
        if (-not $uninstallOk) {
            $blocked = $true
            if ([string]::IsNullOrWhiteSpace($failure)) { $failure = 'Owned uninstall did not remove owned task/shortcuts/resources while keeping foreign state.' }
        }
    }

    $pass = (
        $installOk -and $doctorHealthy -and $wiredShared -and $localWorkOk -and
        $secondOk -and $removeOk -and $updateOk -and $wrapperOk -and $uninstallOk -and $foreignKept
    )
} catch {
    $failure = [string]$_.Exception.Message
    $blocked = $true
    $pass = $false
} finally {
    $safetyCleanup.used = $false
    $safetyCleanup.product_uninstall_pass = [bool]$uninstallOk
    try {
        $stillInstalled = [IO.Directory]::Exists($installRoot) -and [IO.File]::Exists((Join-Path $installRoot 'src\install\Uninstall-TelephoneLine.ps1'))
        if ($stillInstalled) {
            $safetyCleanup.used = $true
            $safety = Invoke-Product -File (Join-Path $installRoot 'src\install\Uninstall-TelephoneLine.ps1') -WorkingDirectory $installRoot -ArgumentList @(
                '-InstallRoot', $installRoot, '-RemoveState'
            )
            $safetyCleanup.command = [ordered]@{ ok = [bool]$safety.ok; code = [string]$safety.code; exit_code = [int]$safety.exit_code }
            Write-Utf8Json -Path (Join-Path $evidence 'command-results\safety-cleanup-uninstall.json') -Value $safety
        }
    } catch {
        $safetyCleanup.error = [string]$_.Exception.Message
    }
    Write-Utf8Json -Path (Join-Path $evidence 'command-results\safety-cleanup.json') -Value $safetyCleanup
    try {
        if ([IO.Directory]::Exists($jobHome)) {
            foreach ($leaf in @('install', 'second-install', 'line-state', 'work', 'desktop')) {
                $p = Join-Path $jobHome $leaf
                if ([IO.Directory]::Exists($p)) {
                    try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } catch { }
                }
            }
        }
    } catch { }
}

$identity = [ordered]@{
    user_name = [string]([Security.Principal.WindowsIdentity]::GetCurrent().Name)
    user_sid = [string]([Security.Principal.WindowsIdentity]::GetCurrent().User)
    interactive = [bool][Environment]::UserInteractive
    admin = [bool]([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    image_os = [string]$env:ImageOS
    image_version = [string]$env:ImageVersion
    github_sha = [string]$env:GITHUB_SHA
    github_ref = [string]$env:GITHUB_REF
    github_run_id = [string]$env:GITHUB_RUN_ID
    github_run_url = ('https://github.com/' + [string]$env:GITHUB_REPOSITORY + '/actions/runs/' + [string]$env:GITHUB_RUN_ID)
}

$result = [ordered]@{
    protocol_version = 'telephone-line-windows-lifecycle-result-v1'
    purpose = 'github_hosted_windows_public_zip_install_background_ownership'
    not_ai = $true
    not_original_lead_callback = $true
    pass = $pass
    blocked_after_prerequisite_failure = $blocked
    failure = $failure
    job_home = $jobHome
    install_root = $installRoot
    extracted_windows_root = $extract
    windows_zip_sha256 = Get-Sha256File -Path $WindowsZip
    source_zip_sha256 = Get-Sha256File -Path $SourceZip
    runner = $identity
    stages = $stages
    safety_cleanup = $safetyCleanup
    historical_private_F = 'UNRUN_SUPERSEDED_BY_CURRENT_COMBINATION'
    cannot_prove = @(
        'Pascal-host AI original-session callback and measured process/EOF drain',
        'arbitrary interactive desktop users outside this runner login',
        'paid model execution'
    )
}
Write-Utf8Json -Path (Join-Path $evidence 'lifecycle-result.json') -Value $result
Write-Output (($result | ConvertTo-Json -Depth 32).TrimEnd())
if ($pass) { exit 0 }
exit 1

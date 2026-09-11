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
[IO.Directory]::CreateDirectory((Join-Path $evidence 'job')) | Out-Null

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
        return [ordered]@{ present = $false; root = $full; file_count = 0; sha256 = $null }
    }
    $rows = [Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $rel = $file.FullName.Substring($full.Length).TrimStart('\').Replace('\', '/')
        [void]$rows.Add($rel + '|' + [string]$file.Length + '|' + (Get-Sha256File -Path $file.FullName))
    }
    $material = ($rows -join "`n")
    return [ordered]@{ present = $true; root = $full; file_count = $rows.Count; sha256 = (Get-Sha256Text -Text $material) }
}

function Get-ScheduledTaskEvidence {
    $xml = $null
    $xmlSha = $null
    $info = $null
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
        }
    } catch { }
    return [ordered]@{ registered = (-not [string]::IsNullOrWhiteSpace($xml)); xml = $xml; xml_sha256 = $xmlSha; info = $info }
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

function Test-OwnerAlive {
    param([int]$ProcessId, [int64]$StartTicks)
    if ($ProcessId -le 0) { return $false }
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        try {
            return ([int64]$proc.StartTime.ToUniversalTime().Ticks -eq [int64]$StartTicks)
        } finally { $proc.Dispose() }
    } catch { return $false }
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
    $info.Environment['TELEPHONE_LINE_TASK_BACKEND'] = ''
    $info.Environment['TELEPHONE_LINE_TASK_STORE'] = ''
    if ($null -ne $ExtraEnvironment) {
        foreach ($k in $ExtraEnvironment.Keys) { $info.Environment[[string]$k] = [string]$ExtraEnvironment[$k] }
    }
    foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $File)) {
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

try {
    Assert-IndependentRoots
    foreach ($dir in @($jobHome, $installRoot, $secondRoot, $lineState, $supervisorState, $foreignState, $workRoot, $desktopRoot)) {
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

    $install = Invoke-Product -File (Join-Path $extract 'src\install\Install-TelephoneLine.ps1') -WorkingDirectory $extract -ArgumentList @(
        '-InstallRoot', $installRoot, '-SourceRoot', $extract
    )
    Write-Utf8Json -Path (Join-Path $evidence 'command-results\install.json') -Value $install
    $stages.install = [ordered]@{ ok = [bool]$install.ok; code = [string]$install.code; exit_code = [int]$install.exit_code }
    if (-not [bool]$install.ok -or [string]$install.code -cnotin @('INSTALLED', 'ALREADY_CURRENT')) {
        $blocked = $true
        $failure = 'Install did not succeed; later mutating stages were not started.'
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
        $workerPath = Join-Path $workRoot 'Invoke-PublicInstallLifecycleWork.ps1'
        $dispatchPath = Join-Path $workRoot 'dispatch-request.json'
        $wiredPath = Join-Path $workRoot 'wired-request.json'
        $bindingPath = Join-Path $workRoot 'ci-lead-binding.json'
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
    [Parameter(Mandatory = $true)][string]$OutputFile
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
    [IO.File]::WriteAllBytes($OutputFile, [Text.UTF8Encoding]::new($false).GetBytes($text))
} finally { $proc.Dispose() }
exit 0
'@
        [IO.File]::WriteAllText($workerPath, $worker.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))
        $lineJobId = [guid]::NewGuid().ToString()
        $sessionId = 'ci-windows-lifecycle-not-ai'
        $binding = [ordered]@{
            protocol_version = 'telephone-line-lead-binding-v1'
            session_id = $sessionId
            worktree = $workRoot
            launcher = [ordered]@{
                path = $workerPath
                arguments = @()
            }
        }
        Write-Utf8Json -Path $bindingPath -Value $binding
        $dispatch = [ordered]@{
            protocol_version = 'telephone-line-dispatch-v1'
            line_job_id = $lineJobId
            project = 'telephone-windows-lifecycle'
            stage = 'public-install-background-verification'
            role = 'execution'
            route = 'direct-cursor'
            summary = 'GitHub Windows VM public install/background verification; not AI and not original Lead callback'
            lead = $binding
            command = [ordered]@{
                executable = $pwsh
                working_directory = $workRoot
                arguments = @(
                    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                    '-File', $workerPath, '-InputFile', $inputPath, '-OutputFile', $outputPath
                )
            }
        }
        Write-Utf8Json -Path $dispatchPath -Value $dispatch
        $jobScript = Join-Path $installRoot 'src\core\Start-TelephoneLineJob.ps1'
        if (-not [IO.File]::Exists($jobScript)) { throw 'Installed Start-TelephoneLineJob.ps1 is missing.' }
        $wired = [ordered]@{
            protocol_version = 'telephone-line-wired-supervisor-request-v1'
            run_id = [guid]::NewGuid().ToString()
            project = 'telephone-windows-lifecycle'
            stage = 'public-install-background-verification'
            lead_session_id = $sessionId
            lead_run_id = ('ci-' + $lineJobId)
            summary = 'GitHub Windows VM public install/background verification; not AI and not original Lead callback'
            worktree = $workRoot
            command = [ordered]@{
                executable = $pwsh
                working_directory = $installRoot
                arguments = @(
                    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                    '-File', $jobScript, '-RequestFile', $dispatchPath, '-StateRoot', $lineState
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

        $wiredRun = Invoke-Product -File (Join-Path $installRoot 'src\supervisor\Start-TelephoneWiredRun.ps1') -WorkingDirectory $installRoot -ArgumentList @(
            '-RequestFile', $wiredPath, '-StateRoot', $supervisorState, '-InstallRoot', $installRoot
        )
        Write-Utf8Json -Path (Join-Path $evidence 'command-results\wired-run.json') -Value $wiredRun
        $consumer = ''
        $sharedStarted = $false
        if ($wiredRun.parsed -is [Collections.IDictionary]) {
            if ($wiredRun.parsed.Contains('start_consumer')) { $consumer = [string]$wiredRun.parsed.start_consumer }
            if ($wiredRun.parsed.Contains('shared_task_started')) { $sharedStarted = [bool]$wiredRun.parsed.shared_task_started }
            if ($wiredRun.parsed.Contains('run_id')) { $stages.wired_run_id = [string]$wiredRun.parsed.run_id }
        }
        if ($consumer -match '(?i)HostVisible' -or $consumer -eq 'Start-TelephoneSupervisorHostVisible.ps1') {
            $blocked = $true
            $failure = 'Start used the internal HostVisible consumer instead of the registered scheduled task.'
        } elseif (-not $sharedStarted) {
            $blocked = $true
            $failure = 'Start-TelephoneWiredRun did not start the registered shared scheduled task. Failure kept; principal/trigger were not rewritten.'
        } else {
            $wiredShared = $true
        }
        $stages.wired = [ordered]@{
            ok = [bool]$wiredRun.ok
            shared_task_started = $sharedStarted
            start_consumer = $consumer
            published = $(if ($wiredRun.parsed -is [Collections.IDictionary] -and $wiredRun.parsed.Contains('published')) { [bool]$wiredRun.parsed.published } else { $null })
            triggered = $(if ($wiredRun.parsed -is [Collections.IDictionary] -and $wiredRun.parsed.Contains('triggered')) { [bool]$wiredRun.parsed.triggered } else { $null })
        }

        if (-not $blocked) {
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(120)
            $collect = [ordered]@{ status = 'IN_PROGRESS'; pass = $false }
            while ([DateTimeOffset]::UtcNow -lt $deadline) {
                $outDoc = Read-JsonOrNull -Path $outputPath
                $contentOk = $false
                $alive = $false
                $exitObserved = $null
                if ($null -ne $outDoc) {
                    $contentOk = (
                        [string]$outDoc.protocol_version -ceq 'telephone-line-public-install-lifecycle-work-v1' -and
                        [bool]$outDoc.not_ai -eq $true -and
                        [bool]$outDoc.not_original_lead_callback -eq $true -and
                        [string]$outDoc.nonce -ceq $nonce -and
                        [string]$outDoc.phrase -ceq $phrase -and
                        [string]$outDoc.input_sha256 -ceq $inputSha
                    )
                    $workPid = 0
                    $workTicks = [int64]0
                    if ($outDoc.Contains('pid')) { $workPid = [int]$outDoc.pid }
                    if ($outDoc.Contains('start_time_utc_ticks')) { $workTicks = [int64]$outDoc.start_time_utc_ticks }
                    $alive = Test-OwnerAlive -ProcessId $workPid -StartTicks $workTicks
                    if ($alive) {
                        try {
                            $wp = Get-Process -Id $workPid -ErrorAction Stop
                            try {
                                if (-not $wp.WaitForExit(15000)) { }
                                if ($wp.HasExited) { $exitObserved = [int]$wp.ExitCode; $alive = $false }
                            } finally { $wp.Dispose() }
                        } catch { $alive = $false }
                    }
                    if ($contentOk -and -not $alive) {
                        $collect.status = 'PASS'
                        $collect.pass = $true
                        $collect.output = $outDoc
                        $collect.worker_pid = $workPid
                        $collect.worker_start_time_utc_ticks = $workTicks
                        $collect.worker_exit_code = $exitObserved
                        $collect.output_sha256 = Get-Sha256File -Path $outputPath
                        $collect.input_sha256 = $inputSha
                        break
                    }
                }
                Start-Sleep -Milliseconds 500
            }
            $jobDir = Join-Path $lineState ('jobs\' + $lineJobId)
            foreach ($name in @('dispatch.json', 'command-owner.json', 'command-launch.json', 'lifecycle-status.json', 'supervisor-lineage.json', 'receipt.json')) {
                $src = Join-Path $jobDir $name
                if ([IO.File]::Exists($src)) { Copy-Item -LiteralPath $src -Destination (Join-Path $evidence ('job\' + $name)) -Force }
            }
            $owner = Read-JsonOrNull -Path (Join-Path $jobDir 'command-owner.json')
            $launch = Read-JsonOrNull -Path (Join-Path $jobDir 'command-launch.json')
            $lineage = Read-JsonOrNull -Path (Join-Path $jobDir 'supervisor-lineage.json')
            $collect.command_owner = $owner
            $collect.command_launch = $launch
            $collect.supervisor_lineage = $lineage
            if ([string]$collect.status -cne 'PASS') {
                $collect.status = 'FAIL'
                $collect.detail = 'Bounded collection did not obtain matching output plus an independently dead worker identity. File existence alone is not success.'
                $blocked = $true
                $failure = [string]$collect.detail
            } else {
                $localWorkOk = $true
            }
            Write-Utf8Json -Path (Join-Path $evidence 'command-results\local-work-collect.json') -Value $collect
            $stages.local_work = $collect
            $receiptPath = Join-Path $jobDir 'receipt.json'
            $receiptDeadline = [DateTimeOffset]::UtcNow.AddSeconds(60)
            while ((-not [IO.File]::Exists($receiptPath)) -and [DateTimeOffset]::UtcNow -lt $receiptDeadline) {
                Start-Sleep -Milliseconds 500
            }
            if ([IO.File]::Exists($receiptPath)) {
                Copy-Item -LiteralPath $receiptPath -Destination (Join-Path $evidence 'job\receipt.json') -Force
            }
            $stages.line_job_receipt_present = [IO.File]::Exists($receiptPath)
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
        $wrapperForm = Get-WrapperForm -TaskInfo $taskAfterUpdate.info
        $wrapperOk = ([string]$wrapperForm -cin @('wscript_hidden_vbs', 'verified_wrapper_identity_sidecar'))
        $updateOk = (
            [bool]$update.ok -eq $true -and
            [string]$update.code -cin @('UPDATED', 'ALREADY_CURRENT') -and
            $doctor2.parsed -is [Collections.IDictionary] -and
            [bool]$doctor2.parsed.healthy -eq $true -and
            [string]$doctor2.parsed.code -ceq 'HEALTHY' -and
            $wrapperOk
        )
        $stages.update = [ordered]@{
            ok_field = [bool]$update.ok
            code = [string]$update.code
            doctor_healthy = $(if ($doctor2.parsed -is [Collections.IDictionary]) { [bool]$doctor2.parsed.healthy } else { $false })
            wrapper_form = $wrapperForm
            accepted = $updateOk
        }
        if (-not $updateOk) {
            $blocked = $true
            $failure = 'Same-owner Update/Doctor/wrapper identity did not pass.'
        }

        $uninstall = Invoke-Product -File (Join-Path $installRoot 'src\install\Uninstall-TelephoneLine.ps1') -WorkingDirectory $installRoot -ArgumentList @(
            '-InstallRoot', $installRoot, '-RemoveState'
        )
        Write-Utf8Json -Path (Join-Path $evidence 'command-results\uninstall.json') -Value $uninstall
        $foreignAfterUninstall = Get-TreeFingerprint -Root $foreignState
        $taskAfterUninstall = Get-ScheduledTaskEvidence
        $foreignKept = (
            [IO.File]::Exists($foreignMarker) -and
            [string]$foreignAfterUninstall.sha256 -ceq [string]$foreignBefore.sha256
        )
        $uninstallOk = (
            [bool]$uninstall.ok -eq $true -and
            [string]$uninstall.code -cin @('UNINSTALLED', 'UNMANAGED_CONTENT_REMAINS') -and
            $foreignKept
        )
        $stages.uninstall = [ordered]@{
            ok_field = [bool]$uninstall.ok
            code = [string]$uninstall.code
            foreign_kept = $foreignKept
            task_registered_after = [bool]$taskAfterUninstall.registered
            accepted = $uninstallOk
        }
        if (-not $uninstallOk) {
            $blocked = $true
            if ([string]::IsNullOrWhiteSpace($failure)) { $failure = 'Owned uninstall did not preserve foreign state.' }
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
    try {
        if ([IO.Directory]::Exists($installRoot) -and [IO.File]::Exists((Join-Path $installRoot 'src\install\Uninstall-TelephoneLine.ps1'))) {
            $null = Invoke-Product -File (Join-Path $installRoot 'src\install\Uninstall-TelephoneLine.ps1') -WorkingDirectory $installRoot -ArgumentList @(
                '-InstallRoot', $installRoot, '-RemoveState'
            )
        }
    } catch { }
    try {
        if ([IO.Directory]::Exists($jobHome)) {
            # Keep evidence copies; remove only this job's owned runtime trees except evidence/assets.
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

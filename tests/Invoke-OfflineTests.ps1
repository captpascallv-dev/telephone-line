# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [switch]$ResidueOracleOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$selfPid = [int]$PID

function Get-TelephoneOfflineCommandSha256 {
    param([AllowNull()][string]$Command)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$Command)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-TelephoneOfflineProcessCommand {
    param([int]$ProcessId)
    try {
        $cim = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = " + [int]$ProcessId) -ErrorAction Stop
        return [string]$cim.CommandLine
    } catch {
        return ''
    }
}

function Get-TelephoneOfflineFixtureProcesses {
    param([Parameter(Mandatory = $true)][string]$Root)
    $rootNorm = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $rows = [Collections.Generic.List[object]]::new()
    $filter = "Name = 'pwsh.exe' OR Name = 'powershell.exe'"
    foreach ($cim in @(Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction SilentlyContinue)) {
        $pidValue = [int]$cim.ProcessId
        if ($pidValue -eq $selfPid) { continue }
        $command = [string]$cim.CommandLine
        if ([string]::IsNullOrWhiteSpace($command)) { continue }
        if ($command.IndexOf($rootNorm, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
        if ($null -eq $proc) { continue }
        try {
            $ticks = [int64]$proc.StartTime.ToUniversalTime().Ticks
        } catch {
            continue
        } finally {
            if ($null -ne $proc) { $proc.Dispose() }
        }
        $rows.Add([ordered]@{
            pid = $pidValue
            start_time_utc_ticks = $ticks
            command_sha256 = Get-TelephoneOfflineCommandSha256 -Command $command
        })
    }
    return @($rows)
}

function Stop-TelephoneOfflineExactFixtureProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [AllowNull()][object[]]$ClaimedIdentities = @()
    )
    $rootNorm = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $stopped = [Collections.Generic.List[object]]::new()
    $refused = [Collections.Generic.List[object]]::new()
    foreach ($row in @(Get-TelephoneOfflineFixtureProcesses -Root $rootNorm)) {
        $pidValue = [int]$row.pid
        $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
        if ($null -eq $proc) { continue }
        try {
            $ticks = [int64]$proc.StartTime.ToUniversalTime().Ticks
        } catch {
            $refused.Add([ordered]@{ pid = $pidValue; reason = 'start-time-unreadable' })
            continue
        } finally {
            if ($null -ne $proc) { $proc.Dispose() }
        }
        if ($ticks -ne [int64]$row.start_time_utc_ticks) {
            $refused.Add([ordered]@{ pid = $pidValue; start_time_utc_ticks = $ticks; reason = 'pid-reuse' })
            continue
        }
        $command = Get-TelephoneOfflineProcessCommand -ProcessId $pidValue
        if ([string]::IsNullOrWhiteSpace($command) -or $command.IndexOf($rootNorm, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            $refused.Add([ordered]@{ pid = $pidValue; start_time_utc_ticks = $ticks; reason = 'command-root-mismatch'; command_sha256 = (Get-TelephoneOfflineCommandSha256 -Command $command) })
            continue
        }
        try {
            Stop-Process -Id $pidValue -Force -ErrorAction Stop
            $stopped.Add([ordered]@{ pid = $pidValue; start_time_utc_ticks = $ticks; command_sha256 = [string]$row.command_sha256 })
        } catch {
            $refused.Add([ordered]@{ pid = $pidValue; start_time_utc_ticks = $ticks; reason = 'stop-failed' })
        }
    }
    foreach ($claimed in @($ClaimedIdentities)) {
        if ($null -eq $claimed) { continue }
        $claimedPid = 0
        try { $claimedPid = [int]$claimed.pid } catch { continue }
        if ($claimedPid -le 0 -or $claimedPid -eq $selfPid) { continue }
        $proc = Get-Process -Id $claimedPid -ErrorAction SilentlyContinue
        if ($null -eq $proc) { continue }
        try {
            $ticks = [int64]$proc.StartTime.ToUniversalTime().Ticks
        } catch {
            $refused.Add([ordered]@{ pid = $claimedPid; reason = 'claimed-start-time-unreadable' })
            continue
        } finally {
            if ($null -ne $proc) { $proc.Dispose() }
        }
        $command = Get-TelephoneOfflineProcessCommand -ProcessId $claimedPid
        $ticksMatch = ($ticks -eq [int64]$claimed.start_time_utc_ticks)
        $rootMatch = (-not [string]::IsNullOrWhiteSpace($command) -and $command.IndexOf($rootNorm, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        if ($ticksMatch -and $rootMatch) { continue }
        $refused.Add([ordered]@{
            pid = $claimedPid
            start_time_utc_ticks = $ticks
            reason = 'identity-mismatch'
            command_sha256 = (Get-TelephoneOfflineCommandSha256 -Command $command)
        })
    }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    while ([DateTimeOffset]::UtcNow -lt $deadline -and @(Get-TelephoneOfflineFixtureProcesses -Root $rootNorm).Count -gt 0) {
        Start-Sleep -Milliseconds 50
    }
    return [ordered]@{
        stopped = @($stopped)
        refused = @($refused)
        remaining = @(Get-TelephoneOfflineFixtureProcesses -Root $rootNorm)
    }
}

function Complete-TelephoneOfflineTempRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [AllowNull()][object[]]$ClaimedIdentities = @()
    )
    $rootNorm = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $processResult = Stop-TelephoneOfflineExactFixtureProcesses -Root $rootNorm -ClaimedIdentities $ClaimedIdentities
    $removed = $false
    if ([IO.Directory]::Exists($rootNorm)) {
        for ($attempt = 0; $attempt -lt 8; $attempt++) {
            try {
                Remove-Item -LiteralPath $rootNorm -Recurse -Force -ErrorAction Stop
                $removed = -not [IO.Directory]::Exists($rootNorm)
                if ($removed) { break }
            } catch {
                Start-Sleep -Milliseconds 50
            }
        }
    } else {
        $removed = $true
    }
    $remaining = @(Get-TelephoneOfflineFixtureProcesses -Root $rootNorm)
    $directoryExists = [IO.Directory]::Exists($rootNorm)
    $refusedCount = @($processResult.refused).Count
    $residue = ($directoryExists -or $remaining.Count -gt 0 -or $refusedCount -gt 0)
    return [ordered]@{
        residue = [bool]$residue
        directory_exists = [bool]$directoryExists
        remaining_processes = [int]$remaining.Count
        refused = [int]$refusedCount
        stopped = [int]@($processResult.stopped).Count
        identities = @($remaining + @($processResult.refused))
    }
}

if ($ResidueOracleOnly) {
    $residueAssertions = 0
    function Assert-ResidueOracle {
        param([bool]$Condition, [string]$Message)
        $script:residueAssertions += 1
        if (-not $Condition) { throw $Message }
    }
    $positiveRoot = Join-Path ([IO.Path]::GetTempPath()) ('tl-residue-oracle-' + [Guid]::NewGuid().ToString('N'))
    $negativeRoot = Join-Path ([IO.Path]::GetTempPath()) ('tl-residue-neg-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($positiveRoot) | Out-Null
    [IO.Directory]::CreateDirectory($negativeRoot) | Out-Null
    $foreign = $null
    $held = $null
    try {
        $heldInfo = [Diagnostics.ProcessStartInfo]::new()
        $heldInfo.FileName = $pwsh
        $heldInfo.UseShellExecute = $false
        $heldInfo.CreateNoWindow = $true
        $heldInfo.RedirectStandardOutput = $true
        $heldInfo.RedirectStandardError = $true
        $heldCommand = ("Start-Sleep -Seconds 120; '" + $positiveRoot.Replace("'", "''") + "'")
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $heldCommand)) {
            [void]$heldInfo.ArgumentList.Add([string]$argument)
        }
        $held = [Diagnostics.Process]::Start($heldInfo)
        $heldSeen = $false
        $seenBy = [DateTimeOffset]::UtcNow.AddSeconds(5)
        while ([DateTimeOffset]::UtcNow -lt $seenBy) {
            if (@(Get-TelephoneOfflineFixtureProcesses -Root $positiveRoot).Count -ge 1) { $heldSeen = $true; break }
            Start-Sleep -Milliseconds 50
        }
        Assert-ResidueOracle $heldSeen 'Exact held orphan was not identified by root+command.'
        $positive = Complete-TelephoneOfflineTempRoot -Root $positiveRoot
        Assert-ResidueOracle (-not [bool]$positive.residue) 'Exact orphan cleanup left residue.'
        Assert-ResidueOracle (-not [IO.Directory]::Exists($positiveRoot)) 'Exact oracle root remained after cleanup.'
        Assert-ResidueOracle ([int]$positive.remaining_processes -eq 0) 'Exact orphan process remained after cleanup.'
        $exactOrphanCleanup = 1

        $foreignInfo = [Diagnostics.ProcessStartInfo]::new()
        $foreignInfo.FileName = $pwsh
        $foreignInfo.UseShellExecute = $false
        $foreignInfo.CreateNoWindow = $true
        $foreignInfo.RedirectStandardOutput = $true
        $foreignInfo.RedirectStandardError = $true
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', 'Start-Sleep -Seconds 120')) {
            [void]$foreignInfo.ArgumentList.Add([string]$argument)
        }
        $foreign = [Diagnostics.Process]::Start($foreignInfo)
        Start-Sleep -Milliseconds 200
        $foreignProc = Get-Process -Id ([int]$foreign.Id) -ErrorAction Stop
        try { $foreignTicks = [int64]$foreignProc.StartTime.ToUniversalTime().Ticks } finally { $foreignProc.Dispose() }
        [IO.File]::WriteAllText((Join-Path $negativeRoot 'marker.txt'), "held`n", [Text.UTF8Encoding]::new($false))
        $claimed = @([ordered]@{ pid = [int]$foreign.Id; start_time_utc_ticks = $foreignTicks })
        $negative = Complete-TelephoneOfflineTempRoot -Root $negativeRoot -ClaimedIdentities $claimed
        $foreignAlive = $false
        try { $foreignAlive = -not $foreign.HasExited } catch { $foreignAlive = $false }
        Assert-ResidueOracle $foreignAlive 'Identity-mismatched process was killed.'
        Assert-ResidueOracle ([bool]$negative.residue) 'Identity-mismatched cleanup did not fail closed with residue.'
        Assert-ResidueOracle ([int]$negative.refused -ge 1) 'Identity-mismatched cleanup did not record a refused kill.'
        $failClosedCapture = [ordered]@{
            success = $false
            exit_code = 1
            residue = [bool]$negative.residue
            remaining_processes = [int]$negative.remaining_processes
            refused = [int]$negative.refused
        }
        $orphanCleanupFailClosed = 1
        $postFinallyResidueTruthful = 1
        [ordered]@{
            protocol_version = 'telephone-line-offline-residue-oracle-v1'
            success = $true
            assertions = $residueAssertions
            post_finally_residue_truthful = $postFinallyResidueTruthful
            exact_orphan_cleanup = $exactOrphanCleanup
            orphan_cleanup_fail_closed = $orphanCleanupFailClosed
            positive = [ordered]@{ residue = [bool]$positive.residue; remaining_processes = [int]$positive.remaining_processes; directory_exists = [bool]$positive.directory_exists }
            negative = $failClosedCapture
        } | ConvertTo-Json -Depth 8 -Compress
    } finally {
        if ($null -ne $held -and -not $held.HasExited) { try { Stop-Process -Id ([int]$held.Id) -Force -ErrorAction SilentlyContinue } catch { } }
        if ($null -ne $foreign -and -not $foreign.HasExited) { try { Stop-Process -Id ([int]$foreign.Id) -Force -ErrorAction SilentlyContinue } catch { } }
        if ($null -ne $held) { try { $held.Dispose() } catch { } }
        if ($null -ne $foreign) { try { $foreign.Dispose() } catch { } }
        foreach ($root in @($positiveRoot, $negativeRoot)) {
            if ([IO.Directory]::Exists($root)) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $left = @(Get-TelephoneOfflineFixtureProcesses -Root $positiveRoot) + @(Get-TelephoneOfflineFixtureProcesses -Root $negativeRoot)
        if ($left.Count -gt 0) { throw 'Residue oracle teardown left a matching fixture process.' }
        if ([IO.Directory]::Exists($positiveRoot) -or [IO.Directory]::Exists($negativeRoot)) { throw 'Residue oracle teardown left a temp root.' }
    }
    exit 0
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tl-offline-' + [Guid]::NewGuid().ToString('N'))
$coreRoot = Join-Path $tempRoot 'core'
$contractRoot = Join-Path $tempRoot 'contracts'
$adapterRoot = Join-Path $tempRoot 'adapters'
$installRoot = Join-Path $tempRoot 'install'
$catalogRoot = Join-Path $tempRoot 'catalog'
$docsRoot = Join-Path $tempRoot 'docs'
$compatRoot = Join-Path $tempRoot 'compatibility'
$packagingRoot = Join-Path $tempRoot 'packaging'
$leadSideRoot = Join-Path $tempRoot 'lead-side'
$appServerLeadRoot = Join-Path $tempRoot 'app-server-lead'
$dashboardRoot = Join-Path $tempRoot 'dashboard'
$supervisorRoot = Join-Path $tempRoot 'supervisor'
$controlPlaneRoot = Join-Path $tempRoot 'control-plane'
$results = [ordered]@{
    protocol_version = 'telephone-line-offline-test-result-v1'
    success = $false
    temp_root = $tempRoot
    residue = $false
}
try {
    [IO.Directory]::CreateDirectory($coreRoot) | Out-Null
    [IO.Directory]::CreateDirectory($contractRoot) | Out-Null
    [IO.Directory]::CreateDirectory($adapterRoot) | Out-Null
    [IO.Directory]::CreateDirectory($installRoot) | Out-Null
    [IO.Directory]::CreateDirectory($catalogRoot) | Out-Null
    [IO.Directory]::CreateDirectory($docsRoot) | Out-Null
    [IO.Directory]::CreateDirectory($compatRoot) | Out-Null
    [IO.Directory]::CreateDirectory($packagingRoot) | Out-Null
    [IO.Directory]::CreateDirectory($leadSideRoot) | Out-Null
    [IO.Directory]::CreateDirectory($appServerLeadRoot) | Out-Null
    [IO.Directory]::CreateDirectory($dashboardRoot) | Out-Null
    [IO.Directory]::CreateDirectory($supervisorRoot) | Out-Null
    [IO.Directory]::CreateDirectory($controlPlaneRoot) | Out-Null

    function Invoke-TelephoneOfflineChild {
        param([Parameter(Mandatory = $true)][string]$ScriptPath, [Parameter(Mandatory = $true)][string]$ChildRoot)
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $pwsh
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.CreateNoWindow = $true
        foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $ScriptPath, '-TestRoot', $ChildRoot
        )) {
            [void]$info.ArgumentList.Add([string]$argument)
        }
        $process = [Diagnostics.Process]::Start($info)
        try {
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            return [ordered]@{
                exit_code = [int]$process.ExitCode
                stdout = [string]$stdoutTask.GetAwaiter().GetResult()
                stderr = [string]$stderrTask.GetAwaiter().GetResult()
            }
        } finally {
            $process.Dispose()
        }
    }

    function Get-TelephoneOfflineCounterNames {
        param($Node)
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        function Add-TelephoneOfflineCounterWalk {
            param($Item)
            if ($Item -is [Collections.IDictionary]) {
                foreach ($key in @($Item.Keys)) {
                    $value = $Item[$key]
                    if ($value -is [byte] -or $value -is [int16] -or $value -is [uint16] -or $value -is [int] -or $value -is [uint32] -or $value -is [int64] -or $value -is [uint64] -or $value -is [decimal] -or $value -is [double]) {
                        [void]$names.Add([string]$key)
                    } elseif ($value -is [Collections.IDictionary]) {
                        Add-TelephoneOfflineCounterWalk -Item $value
                    } elseif ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
                        foreach ($child in @($value)) { Add-TelephoneOfflineCounterWalk -Item $child }
                    }
                }
                return
            }
            if ($Item -is [string] -or $Item -is [ValueType]) { return }
            if ($Item -is [System.Collections.IEnumerable]) {
                foreach ($child in @($Item)) { Add-TelephoneOfflineCounterWalk -Item $child }
            }
        }
        Add-TelephoneOfflineCounterWalk -Item $Node
        $arr = @($names)
        [Array]::Sort($arr, [StringComparer]::Ordinal)
        return @($arr)
    }

    $contract = Invoke-TelephoneOfflineChild -ScriptPath (Join-Path $repoRoot 'tests\contracts\test_contracts.ps1') -ChildRoot $contractRoot
    if ([int]$contract.exit_code -ne 0) {
        throw "Contract tests failed: $($contract.stderr) $($contract.stdout)"
    }
    $core = Invoke-TelephoneOfflineChild -ScriptPath (Join-Path $repoRoot 'tests\core\test_telephone_line.ps1') -ChildRoot $coreRoot
    if ([int]$core.exit_code -ne 0) {
        throw "Core tests failed: $($core.stderr) $($core.stdout)"
    }
    $adapters = Invoke-TelephoneOfflineChild -ScriptPath (Join-Path $repoRoot 'tests\adapters\Invoke-ExistingAdapterTests.ps1') -ChildRoot $adapterRoot
    if ([int]$adapters.exit_code -ne 0) {
        throw "Adapter tests failed: $($adapters.stderr) $($adapters.stdout)"
    }
    $install = Invoke-TelephoneOfflineChild -ScriptPath (Join-Path $repoRoot 'tests\install\test_install_lifecycle.ps1') -ChildRoot $installRoot
    if ([int]$install.exit_code -ne 0) {
        throw "Install tests failed: $($install.stderr) $($install.stdout)"
    }
    $catalog = Invoke-TelephoneOfflineChild -ScriptPath (Join-Path $repoRoot 'tests\catalog\test_catalog.ps1') -ChildRoot $catalogRoot
    if ([int]$catalog.exit_code -ne 0) {
        throw "Catalog tests failed: $($catalog.stderr) $($catalog.stdout)"
    }
    $docs = Invoke-TelephoneOfflineChild -ScriptPath (Join-Path $repoRoot 'tests\docs\test_public_docs.ps1') -ChildRoot $docsRoot
    if ([int]$docs.exit_code -ne 0) {
        throw "Public docs tests failed: $($docs.stderr) $($docs.stdout)"
    }
    $packaging = Invoke-TelephoneOfflineChild -ScriptPath (Join-Path $repoRoot 'tests\packaging\test_packaging.ps1') -ChildRoot $packagingRoot
    if ([int]$packaging.exit_code -ne 0) {
        throw "Packaging tests failed: $($packaging.stderr) $($packaging.stdout)"
    }
    $leadSide = Invoke-TelephoneOfflineChild -ScriptPath (Join-Path $repoRoot 'tests\lead-side\cursor-external-route\test_cursor_external_lead.ps1') -ChildRoot $leadSideRoot
    if ([int]$leadSide.exit_code -ne 0) {
        throw "Cursor external Lead tests failed: $($leadSide.stderr) $($leadSide.stdout)"
    }
    $appServerLead = Invoke-TelephoneOfflineChild -ScriptPath (Join-Path $repoRoot 'tests\lead-side\codex-app-server\test_codex_app_server_lead.ps1') -ChildRoot $appServerLeadRoot
    if ([int]$appServerLead.exit_code -ne 0) {
        throw "Codex app-server Lead tests failed: $($appServerLead.stderr) $($appServerLead.stdout)"
    }
    $dashboard = Invoke-TelephoneOfflineChild -ScriptPath (Join-Path $repoRoot 'tests\dashboard\test_dashboard.ps1') -ChildRoot $dashboardRoot
    if ([int]$dashboard.exit_code -ne 0) {
        throw "Dashboard tests failed: $($dashboard.stderr) $($dashboard.stdout)"
    }
    $controlPlane = Invoke-TelephoneOfflineChild -ScriptPath (Join-Path $repoRoot 'tests\control-plane\test_control_plane.ps1') -ChildRoot $controlPlaneRoot
    if ([int]$controlPlane.exit_code -ne 0) {
        throw "Control-plane tests failed: $($controlPlane.stderr) $($controlPlane.stdout)"
    }
    $supervisor = Invoke-TelephoneOfflineChild -ScriptPath (Join-Path $repoRoot 'tests\supervisor\test_wired_supervisor.ps1') -ChildRoot $supervisorRoot
    if ([int]$supervisor.exit_code -ne 0) {
        throw "Supervisor tests failed: $($supervisor.stderr) $($supervisor.stdout)"
    }

    $contractJson = ($contract.stdout | Select-Object -Last 1)
    $coreJson = ($core.stdout | Select-Object -Last 1)
    $adapterJson = ($adapters.stdout | Select-Object -Last 1)
    $installJson = ($install.stdout | Select-Object -Last 1)
    $catalogJson = ($catalog.stdout | Select-Object -Last 1)
    $docsJson = ($docs.stdout | Select-Object -Last 1)
    $packagingJson = ($packaging.stdout | Select-Object -Last 1)
    $leadSideJson = ($leadSide.stdout | Select-Object -Last 1)
    $appServerLeadJson = ($appServerLead.stdout | Select-Object -Last 1)
    $dashboardJson = ($dashboard.stdout | Select-Object -Last 1)
    $controlPlaneJson = ($controlPlane.stdout | Select-Object -Last 1)
    $supervisorJson = ($supervisor.stdout | Select-Object -Last 1)
    $contractResult = $contractJson | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    $coreResult = $coreJson | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    $adapterResult = $adapterJson | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    $installResult = $installJson | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    $catalogResult = $catalogJson | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    $docsResult = $docsJson | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    $packagingResult = $packagingJson | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    $leadSideResult = $leadSideJson | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    $appServerLeadResult = $appServerLeadJson | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    $dashboardResult = $dashboardJson | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    $controlPlaneResult = $controlPlaneJson | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    $supervisorResult = $supervisorJson | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    if ($contractResult.success -ne $true -or $coreResult.success -ne $true -or $adapterResult.success -ne $true -or $installResult.success -ne $true -or $catalogResult.success -ne $true -or $docsResult.success -ne $true -or $packagingResult.success -ne $true -or $leadSideResult.success -ne $true -or $appServerLeadResult.success -ne $true -or $dashboardResult.success -ne $true -or $controlPlaneResult.success -ne $true -or $supervisorResult.success -ne $true) {
        throw 'Offline tests did not report success.'
    }

    $aggregateNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in @(
        (Get-TelephoneOfflineCounterNames -Node $contractResult) +
        (Get-TelephoneOfflineCounterNames -Node $coreResult) +
        (Get-TelephoneOfflineCounterNames -Node $adapterResult) +
        (Get-TelephoneOfflineCounterNames -Node $installResult) +
        (Get-TelephoneOfflineCounterNames -Node $catalogResult) +
        (Get-TelephoneOfflineCounterNames -Node $docsResult) +
        (Get-TelephoneOfflineCounterNames -Node $packagingResult) +
        (Get-TelephoneOfflineCounterNames -Node $leadSideResult) +
        (Get-TelephoneOfflineCounterNames -Node $appServerLeadResult) +
        (Get-TelephoneOfflineCounterNames -Node $dashboardResult) +
        (Get-TelephoneOfflineCounterNames -Node $controlPlaneResult) +
        (Get-TelephoneOfflineCounterNames -Node $supervisorResult)
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$name)) { [void]$aggregateNames.Add([string]$name) }
    }
    $aggregateArr = @($aggregateNames)
    [Array]::Sort($aggregateArr, [StringComparer]::Ordinal)
    $aggregateJson = (([ordered]@{ protocol = 'telephone-line-offline-counter-snapshot-v1'; names = @($aggregateArr) } | ConvertTo-Json -Depth 8 -Compress) + "`n")
    [IO.File]::WriteAllText((Join-Path $compatRoot 'suite-aggregate.json'), $aggregateJson, [Text.UTF8Encoding]::new($false))

    $compat = Invoke-TelephoneOfflineChild -ScriptPath (Join-Path $repoRoot 'tests\compatibility\test_compatibility_contract.ps1') -ChildRoot $compatRoot
    if ([int]$compat.exit_code -ne 0) {
        throw "Compatibility tests failed: $($compat.stderr) $($compat.stdout)"
    }
    $compatJson = ($compat.stdout | Select-Object -Last 1)
    $compatResult = $compatJson | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    if ($compatResult.success -ne $true) {
        throw 'Offline tests did not report success.'
    }

    $results.success = $true
    $results.contract = $contractResult
    $results.core = $coreResult
    $results.adapters = $adapterResult
    $results.install = $installResult
    $results.catalog = $catalogResult
    $results.docs = $docsResult
    $results.packaging = $packagingResult
    $results.lead_side = $leadSideResult
    $results.app_server_lead = $appServerLeadResult
    $results.dashboard = $dashboardResult
    $results.control_plane = $controlPlaneResult
    $results.supervisor = $supervisorResult
    $results.compatibility = $compatResult
    $results.assertions = [int]$contractResult.assertions + [int]$coreResult.assertions + [int]$adapterResult.assertions + [int]$installResult.assertions + [int]$catalogResult.assertions + [int]$docsResult.assertions + [int]$packagingResult.assertions + [int]$leadSideResult.assertions + [int]$appServerLeadResult.assertions + [int]$dashboardResult.assertions + [int]$controlPlaneResult.assertions + [int]$supervisorResult.assertions + [int]$compatResult.assertions
    $results.control_plane_wave_manifest_replay = [int]$controlPlaneResult.wave_manifest_replay
    $results.control_plane_transition_only_ledger = [int]$controlPlaneResult.transition_only_ledger
    $results.control_plane_continuation_capsule = [int]$controlPlaneResult.continuation_capsule
    $results.control_plane_lane_local_recovery = [int]$controlPlaneResult.lane_local_recovery
    $results.control_plane_admission_second_turn_chain = [int]$controlPlaneResult.admission_second_turn_chain
    $results.control_plane_controller_exactly_once = [int]$controlPlaneResult.controller_exactly_once
    $results.control_plane_dashboard_current_state_only = [int]$controlPlaneResult.dashboard_current_state_only
    $results.control_plane_dashboard_projection_equal = [int]$controlPlaneResult.dashboard_projection_equal
    $results.control_plane_zero_one_many_action_arrays = [int]$controlPlaneResult.zero_one_many_action_arrays
    $results.control_plane_stalled_failure_matrix = [int]$controlPlaneResult.stalled_dead_start_callback_shared_host_matrix
    $results.control_plane_two_consecutive_waves = [int]$controlPlaneResult.two_consecutive_waves
    $results.control_plane_restart_write_cut_reconstruction = [int]$controlPlaneResult.restart_write_cut_reconstruction
    $results.control_plane_exact_session_second_turn = [int]$controlPlaneResult.exact_session_second_turn
    $results.control_plane_successor_capsule_recovery = [int]$controlPlaneResult.successor_capsule_recovery
    $results.control_plane_three_lane_failure_positions = [int]$controlPlaneResult.three_lane_failure_positions
    $results.control_plane_successful_lane_identity_preservation = [int]$controlPlaneResult.successful_lane_identity_preservation
    $results.control_plane_automatic_supervisor_wake = [int]$controlPlaneResult.automatic_supervisor_wake
    $results.control_plane_automatic_next_wave = [int]$controlPlaneResult.automatic_next_wave
    $results.control_plane_dashboard_stale_unknown_yellow = [int]$controlPlaneResult.dashboard_stale_unknown_yellow
    $results.control_plane_public_extra_privacy_negatives = [int]$controlPlaneResult.public_extra_privacy_negatives
    $results.dashboard_reducer_cases = [int]$dashboardResult.reducer_cases
    $results.dashboard_happy_path_disappears_only_after_closure_receipt = [int]$dashboardResult.happy_path_disappears_only_after_closure_receipt
    $results.dashboard_single_instance_reuse = [int]$dashboardResult.single_instance_reuse
    $results.dashboard_override_hook_preserved = [int]$dashboardResult.override_hook_preserved
    $results.dashboard_explicit_opt_out = [int]$dashboardResult.explicit_opt_out
    $results.dashboard_concurrent_projects_visible = [int]$dashboardResult.concurrent_projects_visible
    $results.dashboard_exact_terminal_disappearance = [int]$dashboardResult.exact_terminal_disappearance
    $results.dashboard_duplicate_provenance_no_second_ordinal = [int]$dashboardResult.duplicate_provenance_no_second_ordinal
    $results.dashboard_privacy_no_user_path = [int]$dashboardResult.privacy_no_user_path
    $results.supervisor_atomic_publish = [int]$supervisorResult.supervisor_atomic_publish
    $results.supervisor_scheduler_trigger = [int]$supervisorResult.supervisor_scheduler_trigger
    $results.supervisor_one_mutex = [int]$supervisorResult.supervisor_one_mutex
    $results.supervisor_job_membership = [int]$supervisorResult.supervisor_job_membership
    $results.supervisor_completed_outbox = [int]$supervisorResult.supervisor_completed_outbox
    $results.supervisor_replay_once = [int]$supervisorResult.supervisor_replay_once
    $results.supervisor_negative_fail_closed = [int]$supervisorResult.supervisor_negative_fail_closed
    $results.supervisor_cancel_one_isolated = [int]$supervisorResult.supervisor_cancel_one_isolated
    $results.supervisor_emergency_pause = [int]$supervisorResult.supervisor_emergency_pause
    $results.supervisor_paused_no_launch = [int]$supervisorResult.supervisor_paused_no_launch
    $results.supervisor_resume_no_resurrect = [int]$supervisorResult.supervisor_resume_no_resurrect
    $results.supervisor_queued_restart = [int]$supervisorResult.supervisor_queued_restart
    $results.supervisor_death_failed = [int]$supervisorResult.supervisor_death_failed
    $results.supervisor_no_orphan = [int]$supervisorResult.supervisor_no_orphan
    $results.supervisor_early_lead_exit = [int]$supervisorResult.supervisor_early_lead_exit
    $results.supervisor_callback_continuity = [int]$supervisorResult.supervisor_callback_continuity
    $results.supervisor_run_host_death = [int]$supervisorResult.supervisor_run_host_death
    $results.supervisor_gui_cancel_one = [int]$supervisorResult.supervisor_gui_cancel_one
    $results.dashboard_supervisor_projection_truth = [int]$dashboardResult.supervisor_projection_truth
    $results.dashboard_supervisor_read_only = [int]$dashboardResult.supervisor_dashboard_read_only
    $results.dashboard_supervisor_incomplete_identity = [int]$dashboardResult.supervisor_incomplete_identity
    $results.intermediate_reparse_rejected = [int]$contractResult.intermediate_reparse_rejected
    $results.durable_sensitive_error_absent = [int]$coreResult.durable_sensitive_error_absent
    $results.ambiguous_wake_at_most_once = [int]$coreResult.ambiguous_wake_at_most_once
    $results.deepsea_prompt_transport = [int]$adapterResult.deepsea_prompt_transport
    $results.deepsea_result_referenced = [int]$adapterResult.deepsea_result_referenced
    $results.deepsea_native_binding = [int]$adapterResult.deepsea_native_binding
    $results.production_shaped_dsh_invocation = [int]$adapterResult.production_shaped_dsh_invocation
    $results.pi_path_discovery = [int]$adapterResult.pi_path_discovery
    $results.durable_generic_error_privacy = [int]$adapterResult.durable_generic_error_privacy
    $results.follow_up_rejected = [int]$adapterResult.follow_up_rejected
    $results.recover_no_provider = [int]$adapterResult.recover_no_provider
    $results.cursor_unavailable = [int]$adapterResult.cursor_unavailable
    $results.cursor_process_launch = [int]$adapterResult.cursor_process_launch
    $results.v4_exact_native_session = [int]$adapterResult.v4_exact_native_session
    $results.provider_model_bound = [int]$adapterResult.provider_model_bound
    $results.reasoning_effort_bound = [int]$adapterResult.reasoning_effort_bound
    $results.deepsea_model_effort_override = [int]$adapterResult.deepsea_model_effort_override
    $results.deepsea_model_effort_rejected = [int]$adapterResult.deepsea_model_effort_rejected
    $results.profile_contained = [int]$adapterResult.profile_contained
    $results.child_harness_launch = [int]$adapterResult.child_harness_launch
    $results.exact_native_session_truthful = [int]$adapterResult.exact_native_session_truthful
    $results.descriptors_validated = [int]$adapterResult.descriptors_validated
    $results.codex_exact_session = [int]$adapterResult.codex_exact_session
    $results.codex_recover_no_rerun = [int]$adapterResult.codex_recover_no_rerun
    $results.claude_exact_session = [int]$adapterResult.claude_exact_session
    $results.claude_recover_no_rerun = [int]$adapterResult.claude_recover_no_rerun
    $results.install_lifecycle = [int]$installResult.install_lifecycle
    $results.install_idempotent = [int]$installResult.install_idempotent
    $results.uninstall_no_residue = [int]$installResult.uninstall_no_residue
    $results.doctor_read_only = [int]$installResult.doctor_read_only
    $results.doctor_drift_detected = [int]$installResult.doctor_drift_detected
    $results.update_preserves_state = [int]$installResult.update_preserves_state
    $results.install_ships_license = [int]$installResult.install_ships_license
    $results.install_pending_idle_activation = [int]$installResult.install_pending_idle_activation
    $results.doctor_task_identity = [int]$installResult.doctor_task_identity
    $results.catalog_schema_valid = [int]$catalogResult.catalog_schema_valid
    $results.catalog_ninth_route_rejected = [int]$catalogResult.catalog_ninth_route_rejected
    $results.catalog_denominator_eight = [int]$catalogResult.catalog_denominator_eight
    $results.catalog_matches_descriptors = [int]$catalogResult.catalog_matches_descriptors
    $results.catalog_paths_real = [int]$catalogResult.catalog_paths_real
    $results.catalog_no_invented_lead = [int]$catalogResult.catalog_no_invented_lead
    $results.catalog_sorted_stable = [int]$catalogResult.catalog_sorted_stable
    $results.docs_routes_agree = [int]$catalogResult.docs_routes_agree
    $results.docs_no_duplicate_positioning = [int]$catalogResult.docs_no_duplicate_positioning
    $results.docs_positioning_present = [int]$catalogResult.docs_positioning_present
    $results.docs_no_ninth_route_claim = [int]$catalogResult.docs_no_ninth_route_claim
    $results.catalog_privacy_clean = [int]$catalogResult.catalog_privacy_clean
    $results.readme_first_screen_codex_first = [int]$docsResult.readme_first_screen_codex_first
    $results.readme_lead_sequence_present = [int]$docsResult.readme_lead_sequence_present
    $results.readme_no_forbidden_claims = [int]$docsResult.readme_no_forbidden_claims
    $results.readme_community_lead_gated = [int]$docsResult.readme_community_lead_gated
    $results.docs_links_resolve = [int]$docsResult.docs_links_resolve
    $results.license_is_mpl2_complete = [int]$docsResult.license_is_mpl2_complete
    $results.licensing_notes_consistent = [int]$docsResult.licensing_notes_consistent
    $results.quick_start_commands_real = [int]$docsResult.quick_start_commands_real
    $results.templates_valid = [int]$docsResult.templates_valid
    $results.eight_routes_consistent = [int]$docsResult.eight_routes_consistent
    $results.public_docs_privacy_clean = [int]$docsResult.public_docs_privacy_clean
    $results.contract_stages_five = [int]$compatResult.contract_stages_five
    $results.contract_files_exist = [int]$compatResult.contract_files_exist
    $results.contract_counters_emitted = [int]$compatResult.contract_counters_emitted
    $results.contract_doc_agrees = [int]$compatResult.contract_doc_agrees
    $results.contract_no_paid_model = [int]$compatResult.contract_no_paid_model
    $results.ci_workflow_offline_shape = [int]$compatResult.ci_workflow_offline_shape
    $results.schema_name_surface_consistent = [int]$contractResult.schema_name_surface_consistent
    $results.package_set_excludes_private = [int]$packagingResult.package_set_excludes_private
    $results.source_archive_deterministic = [int]$packagingResult.source_archive_deterministic
    $results.release_zip_deterministic = [int]$packagingResult.release_zip_deterministic
    $results.release_zip_excludes_tests = [int]$packagingResult.release_zip_excludes_tests
    $results.archives_contain_license = [int]$packagingResult.archives_contain_license
    $results.manifest_matches_tree = [int]$packagingResult.manifest_matches_tree
    $results.manifest_deterministic = [int]$packagingResult.manifest_deterministic
    $results.manifest_routes_eight = [int]$packagingResult.manifest_routes_eight
    $results.manifest_schema_valid = [int]$packagingResult.manifest_schema_valid
    $results.redistribution_privacy_clean = [int]$packagingResult.redistribution_privacy_clean
    $results.third_party_inventory_accurate = [int]$packagingResult.third_party_inventory_accurate
    $results.archives_markdown_links_resolved = [int]$packagingResult.archives_markdown_links_resolved
    $results.cursor_external_binding_derived = [int]$leadSideResult.cursor_external_binding_derived
    $results.cursor_external_request_direct_grok_start = [int]$leadSideResult.cursor_external_request_direct_grok_start
    $results.cursor_external_starter_exit_now = [int]$leadSideResult.cursor_external_starter_exit_now
    $results.cursor_external_exact_session_wake = [int]$leadSideResult.cursor_external_exact_session_wake
    $results.cursor_external_builder_no_start = [int]$leadSideResult.cursor_external_builder_no_start
    $results.cursor_external_fail_closed = [int]$leadSideResult.cursor_external_fail_closed
    $results.cursor_external_create_new = [int]$leadSideResult.cursor_external_create_new
    $results.cursor_external_scratch_rejected = [int]$leadSideResult.cursor_external_scratch_rejected
    $results.cursor_external_argument_array = [int]$leadSideResult.cursor_external_argument_array
    $results.cursor_external_status_observational = [int]$leadSideResult.cursor_external_status_observational
    $results.cursor_external_no_provider = [int]$leadSideResult.cursor_external_no_provider
    $results.app_server_thread_id_direct = [int]$appServerLeadResult.thread_id_direct
    $results.app_server_restart_resume = [int]$appServerLeadResult.restart_resume
    $results.app_server_callback_once = [int]$appServerLeadResult.callback_once
    $results.app_server_crash_before_write = [int]$appServerLeadResult.crash_before_write
    $results.app_server_crash_after_ambiguous_write = [int]$appServerLeadResult.crash_after_ambiguous_write
    $results.app_server_crash_after_turn_bind = [int]$appServerLeadResult.crash_after_turn_bind
    $results.app_server_crash_before_ack = [int]$appServerLeadResult.crash_before_ack
    $results.app_server_concurrency_once = [int]$appServerLeadResult.concurrency_once
    $results.app_server_fail_closed_zero = [int]$appServerLeadResult.fail_closed_zero
    $results.app_server_fail_closed_multiple = [int]$appServerLeadResult.fail_closed_multiple
    $results.app_server_fail_closed_unexplained = [int]$appServerLeadResult.fail_closed_unexplained
    $results.app_server_status_not_loaded = [int]$appServerLeadResult.status_not_loaded
    $results.app_server_status_idle = [int]$appServerLeadResult.status_idle
    $results.app_server_status_system_error = [int]$appServerLeadResult.status_system_error
    $results.app_server_status_active = [int]$appServerLeadResult.status_active
    $results.app_server_flag_waiting_on_approval = [int]$appServerLeadResult.flag_waiting_on_approval
    $results.app_server_flag_waiting_on_user_input = [int]$appServerLeadResult.flag_waiting_on_user_input
    $results.app_server_pending_projected = [int]$appServerLeadResult.pending_projected
    $results.app_server_status_observational = [int]$appServerLeadResult.status_observational
    $results.app_server_schema_mismatch = [int]$appServerLeadResult.schema_mismatch
    $results.app_server_explicit_fallback = [int]$appServerLeadResult.explicit_fallback
    $results.app_server_automatic_fallback_absent = [int]$appServerLeadResult.automatic_fallback_absent
    $results.app_server_stdio_only = [int]$appServerLeadResult.stdio_only
    $results.app_server_experimental_excluded = [int]$appServerLeadResult.experimental_excluded
    $results.app_server_privacy_clean = [int]$appServerLeadResult.privacy_clean
    $results.app_server_no_provider = [int]$appServerLeadResult.no_provider
    $results.app_server_denominator_eight = [int]$appServerLeadResult.denominator_eight
    $results.app_server_durable_ack_before_terminal = [int]$appServerLeadResult.durable_ack_before_terminal
    $results.app_server_launcher_exit_same_turn = [int]$appServerLeadResult.launcher_exit_same_turn
    $results.app_server_appserver_death_same_turn = [int]$appServerLeadResult.appserver_death_same_turn
    $results.app_server_worker_death_same_turn = [int]$appServerLeadResult.worker_death_same_turn
    $results.app_server_intent_mismatch_closed = [int]$appServerLeadResult.intent_mismatch_closed
    $results.app_server_marker_user_exact = [int]$appServerLeadResult.marker_user_exact
    $results.app_server_marker_echo_rejected = [int]$appServerLeadResult.marker_echo_rejected
    $results.app_server_pending_four_methods = [int]$appServerLeadResult.pending_four_methods
    $results.app_server_pending_unknown_ignored = [int]$appServerLeadResult.pending_unknown_ignored
    $results.app_server_pending_resolved_cleared = [int]$appServerLeadResult.pending_resolved_cleared
    $results.app_server_stderr_drained = [int]$appServerLeadResult.stderr_drained
    $results.app_server_fail_closed_empty = [int]$appServerLeadResult.fail_closed_empty
    $results.app_server_official_completed = [int]$appServerLeadResult.official_completed
    $results.app_server_official_failed = [int]$appServerLeadResult.official_failed
    $results.app_server_official_interrupted = [int]$appServerLeadResult.official_interrupted
    $results.app_server_recovery_required = [int]$appServerLeadResult.recovery_required
    $results.app_server_quiet_read_survived = [int]$appServerLeadResult.quiet_read_survived
    $results.app_server_no_concurrent_stdout_read = [int]$appServerLeadResult.no_concurrent_stdout_read
    $results.app_server_no_absolute_turn_timeout = [int]$appServerLeadResult.no_absolute_turn_timeout
    $results.app_server_cross_identity_ignored = [int]$appServerLeadResult.cross_identity_ignored
    $results.app_server_malformed_terminal_not_completed = [int]$appServerLeadResult.malformed_terminal_not_completed
    $results.app_server_chain_valid_recovered = [int]$appServerLeadResult.chain_valid_recovered
    $results.app_server_chain_orphan_ack_closed = [int]$appServerLeadResult.chain_orphan_ack_closed
    $results.app_server_chain_orphan_bound_closed = [int]$appServerLeadResult.chain_orphan_bound_closed
    $results.app_server_chain_conflict_closed = [int]$appServerLeadResult.chain_conflict_closed
    $results.app_server_chain_terminal_without_chain_closed = [int]$appServerLeadResult.chain_terminal_without_chain_closed
    $results.app_server_chain_live_owner_bypass_closed = [int]$appServerLeadResult.chain_live_owner_bypass_closed
    $results.app_server_f01_stable_protocol = [int]$appServerLeadResult.f01_stable_protocol
    $results.app_server_f02_durable_chain = [int]$appServerLeadResult.f02_durable_chain
    $results.app_server_f02_illegal_recovery_history = [int]$appServerLeadResult.f02_illegal_recovery_history
    $results.app_server_f02_illegal_failure_history = [int]$appServerLeadResult.f02_illegal_failure_history
    $results.app_server_f02_legal_recovery_history = [int]$appServerLeadResult.f02_legal_recovery_history
    $results.app_server_f02_legal_failure_history = [int]$appServerLeadResult.f02_legal_failure_history
    $results.app_server_f02_writer_observed_count = [int]$appServerLeadResult.f02_writer_observed_count
    $results.app_server_f02_table_count = [int]$appServerLeadResult.f02_table_count
    $results.app_server_f02_expected_count = [int]$appServerLeadResult.f02_expected_count
    $results.app_server_f02_missing_rows = [int]$appServerLeadResult.f02_missing_rows
    $results.app_server_f02_extra_rows = [int]$appServerLeadResult.f02_extra_rows
    $results.app_server_f02_duplicate_rows = [int]$appServerLeadResult.f02_duplicate_rows
    $results.app_server_f02_r5_prebind_recovery_preserved = [int]$appServerLeadResult.f02_r5_prebind_recovery_preserved
    $results.app_server_f02_r5_terminal_publishing_preserved = [int]$appServerLeadResult.f02_r5_terminal_publishing_preserved
    $results.app_server_f02_raw_observation_count = [int]$appServerLeadResult.f02_raw_observation_count
    $results.app_server_f02_submitted_count = [int]$appServerLeadResult.f02_submitted_count
    $results.app_server_f02_writer_unique_count = [int]$appServerLeadResult.f02_writer_unique_count
    $results.app_server_f02_production_duplicate_count = [int]$appServerLeadResult.f02_production_duplicate_count
    $results.app_server_f02_closed_accounting = [int]$appServerLeadResult.f02_closed_accounting
    $results.app_server_f02_capture_filter_absent = [int]$appServerLeadResult.f02_capture_filter_absent
    $results.app_server_f02_owner_local_dedupe_absent = [int]$appServerLeadResult.f02_owner_local_dedupe_absent
    $results.app_server_f02_same_key_byte_observation = [int]$appServerLeadResult.f02_same_key_byte_observation
    $results.app_server_f02_changed_key_recovery_observation = [int]$appServerLeadResult.f02_changed_key_recovery_observation
    $results.app_server_f02_duplicate_probe = [int]$appServerLeadResult.f02_duplicate_probe
    $results.app_server_f02_independent_expected_count = [int]$appServerLeadResult.f02_independent_expected_count
    $results.app_server_f02_r6_recover_forward_turn_bound_crash = [int]$appServerLeadResult.f02_r6_recover_forward_turn_bound_crash
    $results.app_server_f02_r6_recover_forward_in_progress_crash = [int]$appServerLeadResult.f02_r6_recover_forward_in_progress_crash
    $results.app_server_f02_r6_recover_forward_repeat_terminal = [int]$appServerLeadResult.f02_r6_recover_forward_repeat_terminal
    $results.app_server_f02_r6_recover_forward_publishing_crash = [int]$appServerLeadResult.f02_r6_recover_forward_publishing_crash
    $results.app_server_f02_r7_recovery_commit_lifecycle = [int]$appServerLeadResult.f02_r7_recovery_commit_lifecycle
    $results.app_server_f02_r7_marker_prebind_recovery = [int]$appServerLeadResult.f02_r7_marker_prebind_recovery
    $results.app_server_f02_r7_successive_recovery_crashes = [int]$appServerLeadResult.f02_r7_successive_recovery_crashes
    $results.app_server_f02_r7_recovered_failed = [int]$appServerLeadResult.f02_r7_recovered_failed
    $results.app_server_f02_r7_recovered_interrupted = [int]$appServerLeadResult.f02_r7_recovered_interrupted
    $results.app_server_f02_r7_unfiltered_writer_equality = [int]$appServerLeadResult.f02_r7_unfiltered_writer_equality
    $results.app_server_f02_r8_independent_oracle = [int]$appServerLeadResult.f02_r8_independent_oracle
    $results.app_server_f02_r8_writer_scoped_cuts = [int]$appServerLeadResult.f02_r8_writer_scoped_cuts
    $results.app_server_f02_r8_process_death_cuts = [int]$appServerLeadResult.f02_r8_process_death_cuts
    $results.app_server_f03_atomic_publish = [int]$appServerLeadResult.f03_atomic_publish
    $results.app_server_f04_service_tier_default = [int]$appServerLeadResult.f04_service_tier_default
    $results.app_server_f05_compatibility_identity = [int]$appServerLeadResult.f05_compatibility_identity
    $results.app_server_f06_status_containment = [int]$appServerLeadResult.f06_status_containment
    $results.app_server_f07_public_error_privacy = [int]$appServerLeadResult.f07_public_error_privacy
    $results.app_server_nondefault_turn_starts = [int]$appServerLeadResult.nondefault_turn_starts
    $results.app_server_privacy_needle_hits = [int]$appServerLeadResult.privacy_needle_hits
    if ($results.intermediate_reparse_rejected -lt 1 -or $results.durable_sensitive_error_absent -lt 1 -or $results.ambiguous_wake_at_most_once -lt 1) {
        throw 'Offline tests did not prove the required containment, privacy, or wake-idempotence counters.'
    }
    if (
        $results.deepsea_prompt_transport -lt 1 -or
        $results.deepsea_result_referenced -lt 1 -or
        $results.deepsea_native_binding -lt 1 -or
        $results.production_shaped_dsh_invocation -lt 1 -or
        $results.pi_path_discovery -lt 1 -or
        $results.durable_generic_error_privacy -lt 1 -or
        $results.follow_up_rejected -lt 1 -or
        $results.recover_no_provider -lt 1 -or
        $results.v4_exact_native_session -lt 1 -or
        $results.provider_model_bound -lt 1 -or
        $results.reasoning_effort_bound -lt 1 -or
        $results.deepsea_model_effort_override -lt 1 -or
        $results.deepsea_model_effort_rejected -lt 1 -or
        $results.profile_contained -lt 1 -or
        $results.exact_native_session_truthful -lt 1 -or
        $results.codex_exact_session -lt 1 -or
        $results.codex_recover_no_rerun -lt 1 -or
        $results.claude_exact_session -lt 1 -or
        $results.claude_recover_no_rerun -lt 1 -or
        $results.descriptors_validated -ne 8 -or
        $results.cursor_process_launch -ne 0 -or
        $results.child_harness_launch -ne 0
    ) {
        throw 'Offline tests did not prove the required adapter transport, discovery, or generic-error counters.'
    }
    if (
        $results.install_lifecycle -lt 1 -or
        $results.install_idempotent -lt 1 -or
        $results.uninstall_no_residue -lt 1 -or
        $results.doctor_read_only -lt 1 -or
        $results.doctor_drift_detected -lt 1 -or
        $results.update_preserves_state -lt 1 -or
        $results.install_ships_license -lt 1 -or
        $results.install_pending_idle_activation -lt 1 -or
        $results.doctor_task_identity -lt 1
    ) {
        throw 'Offline tests did not prove the required install lifecycle counters.'
    }
    if (
        $results.catalog_schema_valid -lt 1 -or
        $results.catalog_ninth_route_rejected -lt 1 -or
        $results.catalog_denominator_eight -ne 8 -or
        $results.catalog_matches_descriptors -ne 64 -or
        $results.catalog_paths_real -lt 1 -or
        $results.catalog_no_invented_lead -lt 1 -or
        $results.catalog_sorted_stable -lt 1 -or
        $results.docs_routes_agree -ne 8 -or
        $results.docs_no_duplicate_positioning -lt 1 -or
        $results.docs_positioning_present -ne 4 -or
        $results.docs_no_ninth_route_claim -lt 1 -or
        $results.catalog_privacy_clean -lt 1
    ) {
        throw 'Offline tests did not prove the required catalog counters.'
    }
    if (
        $results.readme_first_screen_codex_first -lt 1 -or
        $results.readme_lead_sequence_present -lt 1 -or
        $results.readme_no_forbidden_claims -lt 1 -or
        $results.readme_community_lead_gated -lt 1 -or
        $results.docs_links_resolve -lt 1 -or
        $results.license_is_mpl2_complete -lt 1 -or
        $results.licensing_notes_consistent -lt 1 -or
        $results.quick_start_commands_real -lt 1 -or
        $results.templates_valid -lt 1 -or
        $results.eight_routes_consistent -lt 1 -or
        $results.public_docs_privacy_clean -lt 1
    ) {
        throw 'Offline tests did not prove the required public docs counters.'
    }
    if (
        $results.contract_stages_five -lt 1 -or
        $results.contract_files_exist -lt 1 -or
        $results.contract_counters_emitted -lt 1 -or
        $results.contract_doc_agrees -lt 1 -or
        $results.contract_no_paid_model -lt 1 -or
        $results.ci_workflow_offline_shape -lt 1
    ) {
        throw 'Offline tests did not prove the required compatibility or CI counters.'
    }
    if ($results.schema_name_surface_consistent -lt 1) {
        throw 'Offline tests did not prove schema-name surface consistency.'
    }
    if (
        $results.package_set_excludes_private -lt 1 -or
        $results.source_archive_deterministic -lt 1 -or
        $results.release_zip_deterministic -lt 1 -or
        $results.release_zip_excludes_tests -lt 1 -or
        $results.archives_contain_license -lt 1 -or
        $results.manifest_matches_tree -lt 1 -or
        $results.manifest_deterministic -lt 1 -or
        $results.manifest_routes_eight -lt 1 -or
        $results.manifest_schema_valid -lt 1 -or
        $results.redistribution_privacy_clean -lt 1 -or
        $results.third_party_inventory_accurate -lt 1 -or
        $results.archives_markdown_links_resolved -lt 1
    ) {
        throw 'Offline tests did not prove the required packaging counters.'
    }
    if (
        $results.cursor_external_binding_derived -lt 1 -or
        $results.cursor_external_request_direct_grok_start -lt 1 -or
        $results.cursor_external_starter_exit_now -lt 1 -or
        $results.cursor_external_exact_session_wake -lt 1 -or
        $results.cursor_external_builder_no_start -lt 1 -or
        $results.cursor_external_fail_closed -lt 1 -or
        $results.cursor_external_create_new -lt 1 -or
        $results.cursor_external_scratch_rejected -lt 1 -or
        $results.cursor_external_argument_array -lt 1 -or
        $results.cursor_external_status_observational -lt 1 -or
        $results.cursor_external_no_provider -lt 1
    ) {
        throw 'Offline tests did not prove the required Cursor external Lead counters.'
    }
    if (
        $results.app_server_thread_id_direct -lt 1 -or
        $results.app_server_restart_resume -lt 1 -or
        $results.app_server_callback_once -lt 1 -or
        $results.app_server_crash_before_write -lt 1 -or
        $results.app_server_crash_after_ambiguous_write -lt 1 -or
        $results.app_server_crash_after_turn_bind -lt 1 -or
        $results.app_server_crash_before_ack -lt 1 -or
        $results.app_server_concurrency_once -lt 1 -or
        $results.app_server_fail_closed_zero -lt 1 -or
        $results.app_server_fail_closed_multiple -lt 1 -or
        $results.app_server_fail_closed_unexplained -lt 1 -or
        $results.app_server_status_not_loaded -lt 1 -or
        $results.app_server_status_idle -lt 1 -or
        $results.app_server_status_system_error -lt 1 -or
        $results.app_server_status_active -lt 1 -or
        $results.app_server_flag_waiting_on_approval -lt 1 -or
        $results.app_server_flag_waiting_on_user_input -lt 1 -or
        $results.app_server_pending_projected -lt 1 -or
        $results.app_server_status_observational -lt 1 -or
        $results.app_server_schema_mismatch -lt 1 -or
        $results.app_server_explicit_fallback -lt 1 -or
        $results.app_server_automatic_fallback_absent -lt 1 -or
        $results.app_server_stdio_only -lt 1 -or
        $results.app_server_experimental_excluded -lt 1 -or
        $results.app_server_privacy_clean -lt 1 -or
        $results.app_server_no_provider -lt 1 -or
        $results.app_server_denominator_eight -ne 8 -or
        $results.app_server_durable_ack_before_terminal -lt 1 -or
        $results.app_server_launcher_exit_same_turn -lt 1 -or
        $results.app_server_appserver_death_same_turn -lt 1 -or
        $results.app_server_worker_death_same_turn -lt 1 -or
        $results.app_server_intent_mismatch_closed -lt 1 -or
        $results.app_server_marker_user_exact -lt 1 -or
        $results.app_server_marker_echo_rejected -lt 1 -or
        $results.app_server_pending_four_methods -lt 1 -or
        $results.app_server_pending_unknown_ignored -lt 1 -or
        $results.app_server_pending_resolved_cleared -lt 1 -or
        $results.app_server_stderr_drained -lt 1 -or
        $results.app_server_fail_closed_empty -lt 1 -or
        $results.app_server_official_completed -lt 1 -or
        $results.app_server_official_failed -lt 1 -or
        $results.app_server_official_interrupted -lt 1 -or
        $results.app_server_recovery_required -lt 1 -or
        $results.app_server_quiet_read_survived -lt 1 -or
        $results.app_server_no_concurrent_stdout_read -lt 1 -or
        $results.app_server_no_absolute_turn_timeout -lt 1 -or
        $results.app_server_cross_identity_ignored -lt 1 -or
        $results.app_server_malformed_terminal_not_completed -lt 1 -or
        $results.app_server_chain_valid_recovered -lt 1 -or
        $results.app_server_chain_orphan_ack_closed -lt 1 -or
        $results.app_server_chain_orphan_bound_closed -lt 1 -or
        $results.app_server_chain_conflict_closed -lt 1 -or
        $results.app_server_chain_terminal_without_chain_closed -lt 1 -or
        $results.app_server_chain_live_owner_bypass_closed -lt 1 -or
        $results.app_server_f01_stable_protocol -lt 1 -or
        $results.app_server_f02_durable_chain -lt 1 -or
        $results.app_server_f02_illegal_recovery_history -lt 4 -or
        $results.app_server_f02_illegal_failure_history -lt 5 -or
        $results.app_server_f02_legal_recovery_history -ne 12 -or
        $results.app_server_f02_legal_failure_history -ne 32 -or
        $results.app_server_f02_missing_rows -ne 0 -or
        $results.app_server_f02_extra_rows -ne 0 -or
        $results.app_server_f02_duplicate_rows -ne 4 -or
        $results.app_server_f02_writer_observed_count -ne 44 -or
        $results.app_server_f02_table_count -ne $results.app_server_f02_writer_observed_count -or
        $results.app_server_f02_writer_unique_count -ne $results.app_server_f02_table_count -or
        $results.app_server_f02_raw_observation_count -ne 48 -or
        $results.app_server_f02_submitted_count -ne 48 -or
        $results.app_server_f02_raw_observation_count -ne $results.app_server_f02_submitted_count -or
        $results.app_server_f02_submitted_count -ne ($results.app_server_f02_writer_unique_count + $results.app_server_f02_duplicate_rows) -or
        $results.app_server_f02_independent_expected_count -ne 44 -or
        $results.app_server_f02_closed_accounting -lt 1 -or
        $results.app_server_f02_capture_filter_absent -lt 1 -or
        $results.app_server_f02_owner_local_dedupe_absent -lt 1 -or
        $results.app_server_f02_same_key_byte_observation -lt 1 -or
        $results.app_server_f02_changed_key_recovery_observation -lt 1 -or
        $results.app_server_f02_duplicate_probe -lt 1 -or
        $results.app_server_f02_r5_prebind_recovery_preserved -lt 1 -or
        $results.app_server_f02_r5_terminal_publishing_preserved -lt 1 -or
        $results.app_server_f02_production_duplicate_count -ne 0 -or
        $results.app_server_f02_r6_recover_forward_turn_bound_crash -lt 1 -or
        $results.app_server_f02_r6_recover_forward_in_progress_crash -lt 1 -or
        $results.app_server_f02_r6_recover_forward_repeat_terminal -lt 1 -or
        $results.app_server_f02_r6_recover_forward_publishing_crash -lt 1 -or
        $results.app_server_f02_r7_recovery_commit_lifecycle -lt 1 -or
        $results.app_server_f02_r7_marker_prebind_recovery -lt 1 -or
        $results.app_server_f02_r7_successive_recovery_crashes -lt 1 -or
        $results.app_server_f02_r7_recovered_failed -lt 1 -or
        $results.app_server_f02_r7_recovered_interrupted -lt 1 -or
        $results.app_server_f02_r7_unfiltered_writer_equality -lt 1 -or
        $results.app_server_f02_r8_independent_oracle -lt 1 -or
        $results.app_server_f02_r8_writer_scoped_cuts -lt 1 -or
        $results.app_server_f02_r8_process_death_cuts -lt 72 -or
        $results.app_server_f03_atomic_publish -lt 1 -or
        $results.app_server_f04_service_tier_default -lt 1 -or
        $results.app_server_f05_compatibility_identity -lt 1 -or
        $results.app_server_f06_status_containment -lt 1 -or
        $results.app_server_f07_public_error_privacy -lt 1 -or
        $results.app_server_nondefault_turn_starts -ne 0 -or
        $results.app_server_privacy_needle_hits -ne 0
    ) {
        throw 'Offline tests did not prove the required Codex app-server Lead counters.'
    }
    if (
        $results.control_plane_wave_manifest_replay -lt 1 -or
        $results.control_plane_transition_only_ledger -lt 1 -or
        $results.control_plane_continuation_capsule -lt 1 -or
        $results.control_plane_lane_local_recovery -lt 1 -or
        $results.control_plane_admission_second_turn_chain -lt 1 -or
        $results.control_plane_controller_exactly_once -lt 1 -or
        $results.control_plane_dashboard_current_state_only -lt 1 -or
        $results.control_plane_dashboard_projection_equal -lt 1 -or
        $results.control_plane_zero_one_many_action_arrays -lt 3 -or
        $results.control_plane_stalled_failure_matrix -lt 6 -or
        $results.control_plane_two_consecutive_waves -lt 2 -or
        $results.control_plane_restart_write_cut_reconstruction -lt 4 -or
        $results.control_plane_exact_session_second_turn -lt 1 -or
        $results.control_plane_successor_capsule_recovery -lt 1 -or
        $results.control_plane_three_lane_failure_positions -lt 3 -or
        $results.control_plane_successful_lane_identity_preservation -lt 15 -or
        $results.control_plane_automatic_supervisor_wake -lt 1 -or
        $results.control_plane_automatic_next_wave -lt 1 -or
        $results.control_plane_dashboard_stale_unknown_yellow -lt 1 -or
        $results.control_plane_public_extra_privacy_negatives -lt 2
    ) {
        throw 'Offline tests did not prove the required control-plane counters.'
    }
    if (
        $results.dashboard_reducer_cases -lt 15 -or
        $results.dashboard_happy_path_disappears_only_after_closure_receipt -lt 1 -or
        $results.dashboard_single_instance_reuse -lt 1 -or
        $results.dashboard_override_hook_preserved -lt 1 -or
        $results.dashboard_explicit_opt_out -lt 1 -or
        $results.dashboard_concurrent_projects_visible -lt 1 -or
        $results.dashboard_exact_terminal_disappearance -lt 1 -or
        $results.dashboard_duplicate_provenance_no_second_ordinal -lt 1 -or
        $results.dashboard_privacy_no_user_path -lt 1
    ) {
        throw 'Offline tests did not prove the required dashboard counters.'
    }
    if (
        $results.supervisor_atomic_publish -lt 1 -or
        $results.supervisor_scheduler_trigger -lt 1 -or
        $results.supervisor_one_mutex -lt 1 -or
        $results.supervisor_job_membership -lt 1 -or
        $results.supervisor_completed_outbox -lt 1 -or
        $results.supervisor_replay_once -lt 1 -or
        $results.supervisor_negative_fail_closed -lt 1 -or
        $results.supervisor_cancel_one_isolated -lt 1 -or
        $results.supervisor_emergency_pause -lt 1 -or
        $results.supervisor_paused_no_launch -lt 1 -or
        $results.supervisor_resume_no_resurrect -lt 1 -or
        $results.supervisor_queued_restart -lt 1 -or
        $results.supervisor_death_failed -lt 1 -or
        $results.supervisor_no_orphan -lt 1 -or
        $results.supervisor_early_lead_exit -lt 1 -or
        $results.supervisor_callback_continuity -lt 1 -or
        $results.supervisor_run_host_death -lt 1 -or
        $results.supervisor_gui_cancel_one -lt 1 -or
        $results.dashboard_supervisor_projection_truth -lt 1 -or
        $results.dashboard_supervisor_read_only -lt 1 -or
        $results.dashboard_supervisor_incomplete_identity -lt 1
    ) {
        throw 'Offline tests did not prove the required supervisor counters.'
    }
    $results.exit_code = 0
    $results.success = $true
} catch {
    $results.success = $false
    $results.error = [string]$_.Exception.Message
    $results.exit_code = 1
} finally {
    $finalized = Complete-TelephoneOfflineTempRoot -Root $tempRoot
    $results.residue = [bool]$finalized.residue
    if ($finalized.identities.Count -gt 0) {
        $results.orphan_identities = @($finalized.identities)
    }
    if ([bool]$finalized.residue) {
        $results.success = $false
        $results.exit_code = 1
        if ([string]::IsNullOrWhiteSpace([string]$results.error)) {
            $results.error = 'Offline temp residue remained after exact fixture cleanup.'
        }
    }
}

$results | ConvertTo-Json -Depth 16
exit [int]$results.exit_code

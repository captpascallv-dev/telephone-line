# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest

if (-not $IsWindows) {
    throw 'Telephone Line v0.1 supports Windows only.'
}

$script:TelephoneInstallProductId = 'telephone-line'
$script:TelephoneInstallManifestName = 'install-manifest.json'
$script:TelephoneInstallManifestProtocol = 'telephone-line-install-manifest-v1'
$script:TelephoneInstallResultProtocol = 'telephone-line-install-result-v1'
$script:TelephoneInstallTrees = @('src', 'schemas', 'docs')
$script:TelephoneInstallSessionState = $ExecutionContext.SessionState
if (-not (Get-Variable -Name TelephoneSupervisorCommonImported -Scope Script -ErrorAction SilentlyContinue)) {
    $script:TelephoneSupervisorCommonImported = $false
}

$script:TelephoneInstallPublicMessage = [ordered]@{
    INSTALL_FAILED = 'The telephone-line install command failed.'
    UNINSTALL_FAILED = 'The telephone-line uninstall command failed.'
    UPDATE_FAILED = 'The telephone-line update command failed.'
    DOCTOR_FAILED = 'The telephone-line doctor command failed.'
    INSTALL_ROOT_REQUIRED = 'Install root is required. Pass -InstallRoot or set TELEPHONE_LINE_INSTALL_ROOT.'
    SOURCE_ROOT_REQUIRED = 'Source root is required. Pass -SourceRoot or run the command from a product tree.'
    SOURCE_EQUALS_INSTALL = 'Source root and install root must be different directories.'
    INSTALL_LOCATION_FORBIDDEN = 'Install root is not an allowed per-user location.'
    MANIFEST_MISSING = 'Install manifest is missing.'
    MANIFEST_NOT_THIS_PRODUCT = 'Install manifest does not belong to this product.'
    INSTALL_EXISTS = 'An install already exists. Pass -Force to replace it, or use update.'
    IN_FLIGHT_JOBS_PRESENT = 'In-flight line jobs lack a terminal receipt. No files were changed.'
    STATE_ROOT_REQUIRED = 'A state root is required for -RemoveState. Set TELEPHONE_LINE_STATE_ROOT.'
    UNMANAGED_CONTENT_REMAINS = 'Unmanaged content remains in the install root.'
    RECYCLE_BLOCKED = 'A recycle-bin removal remained blocked after a bounded quiet retry. Evidence was left intact.'
    ALREADY_CURRENT = 'The install is already current for this source identity.'
    INSTALLED = 'The product tree was installed.'
    UPDATED = 'The product tree was updated from a local source.'
    UNINSTALLED = 'The manifested product files were removed.'
    HEALTHY = 'The install is healthy.'
    DRIFT_DETECTED = 'Installed files do not match the install manifest.'
    ADAPTER_DESCRIPTOR_INVALID = 'One or more adapter descriptors did not validate.'
}

function Get-TelephoneInstallPublicMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Code)
    if ($script:TelephoneInstallPublicMessage.Contains($Code)) {
        return [string]$script:TelephoneInstallPublicMessage[$Code]
    }
    return [string]$script:TelephoneInstallPublicMessage['INSTALL_FAILED']
}

function New-TelephoneInstallResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$Ok,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$Code,
        [string]$Status,
        [object]$Extra
    )

    $result = [ordered]@{
        protocol_version = $script:TelephoneInstallResultProtocol
        ok = $Ok
        action = $Action
        status = if ([string]::IsNullOrWhiteSpace($Status)) { $Code.ToLowerInvariant() } else { $Status }
        code = $Code
        message = Get-TelephoneInstallPublicMessage -Code $Code
        changed = $false
    }
    if ($null -ne $Extra -and $Extra -is [Collections.IDictionary]) {
        foreach ($key in @($Extra.Keys)) {
            $result[$key] = $Extra[$key]
        }
    }
    return $result
}

function Get-TelephoneInstallSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-TelephoneInstallFileIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Expected a regular file.'
    }
    $bytes = [IO.File]::ReadAllBytes($full)
    return [ordered]@{
        bytes = [int64]$bytes.Length
        sha256 = Get-TelephoneInstallSha256 -Bytes $bytes
    }
}

function ConvertTo-TelephoneInstallJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Value)
    return (($Value | ConvertTo-Json -Depth 32).Replace("`r`n", "`n") + "`n")
}

function Test-TelephoneInstallReparse {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path) -and -not [IO.Directory]::Exists($Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-TelephoneInstallNoReparse {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Label)
    if (Test-TelephoneInstallReparse -Path $Path) {
        throw "$Label path is a reparse point."
    }
}

function Test-TelephoneInstallPathInsideRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return ($pathFull + '\').StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-TelephoneInstallCallerPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Resolve-TelephoneInstallRootValue {
    [CmdletBinding()]
    param([string]$InstallRoot)

    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        return Resolve-TelephoneInstallCallerPath -Path $InstallRoot
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_INSTALL_ROOT)) {
        return Resolve-TelephoneInstallCallerPath -Path ([string]$env:TELEPHONE_LINE_INSTALL_ROOT)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:LOCALAPPDATA)) {
        return Resolve-TelephoneInstallCallerPath -Path (Join-Path ([string]$env:LOCALAPPDATA) 'TelephoneLine')
    }
    throw 'INSTALL_ROOT_REQUIRED'
}

function Resolve-TelephoneSourceRootValue {
    [CmdletBinding()]
    param([string]$SourceRoot)

    if (-not [string]::IsNullOrWhiteSpace($SourceRoot)) {
        return Resolve-TelephoneInstallCallerPath -Path $SourceRoot
    }
    $fromEnv = [string]$env:TELEPHONE_LINE_SOURCE_ROOT
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        return Resolve-TelephoneInstallCallerPath -Path $fromEnv
    }
    $defaultRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
    foreach ($tree in $script:TelephoneInstallTrees) {
        if (-not [IO.Directory]::Exists((Join-Path $defaultRoot $tree))) {
            throw 'SOURCE_ROOT_REQUIRED'
        }
    }
    return $defaultRoot
}

function Resolve-TelephoneStateRootValue {
    [CmdletBinding()]
    param([string]$StateRoot)

    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        return Resolve-TelephoneInstallCallerPath -Path $StateRoot
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_STATE_ROOT)) {
        return Resolve-TelephoneInstallCallerPath -Path ([string]$env:TELEPHONE_LINE_STATE_ROOT)
    }
    return $null
}

function Assert-TelephoneAllowedInstallRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $full = Resolve-TelephoneInstallCallerPath -Path $InstallRoot
    $driveRoot = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($driveRoot)) { throw 'INSTALL_LOCATION_FORBIDDEN' }
    $driveFull = $driveRoot.TrimEnd('\')
    if ($full.Equals($driveFull, [StringComparison]::OrdinalIgnoreCase) -or $full.Equals($driveRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'INSTALL_LOCATION_FORBIDDEN'
    }

    $forbidden = [Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
        [string]$env:ProgramFiles,
        [string]${env:ProgramFiles(x86)},
        [string]$env:WINDIR,
        [string]$env:SystemRoot
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            [void]$forbidden.Add((Resolve-TelephoneInstallCallerPath -Path $candidate))
        }
    }
    foreach ($base in $forbidden) {
        if (Test-TelephoneInstallPathInsideRoot -Path $full -Root $base) {
            throw 'INSTALL_LOCATION_FORBIDDEN'
        }
    }
    return $full
}

function Get-TelephoneInstallManifestPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    return (Join-Path $InstallRoot $script:TelephoneInstallManifestName)
}

function Write-TelephoneInstallBytesAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrWhiteSpace($parent)) { throw 'INSTALL_FAILED' }
    if (-not [IO.Directory]::Exists($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    Assert-TelephoneInstallNoReparse -Path $parent -Label 'Install destination'
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) + '.tmp-' + [Guid]::NewGuid().ToString('N'))
    $backup = $null
    try {
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        if ([IO.File]::Exists($full)) {
            Assert-TelephoneInstallNoReparse -Path $full -Label 'Install destination'
            $backup = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) + '.bak-' + [Guid]::NewGuid().ToString('N'))
            [IO.File]::Replace($temporary, $full, $backup)
        } else {
            [IO.File]::Move($temporary, $full)
        }
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($backup) -and [IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Get-TelephoneInstallRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$FullPath
    )

    $rootFull = Resolve-TelephoneInstallCallerPath -Path $Root
    $pathFull = [IO.Path]::GetFullPath($FullPath)
    if (-not (Test-TelephoneInstallPathInsideRoot -Path $pathFull -Root $rootFull)) {
        throw 'INSTALL_FAILED'
    }
    $relative = [IO.Path]::GetRelativePath($rootFull, $pathFull)
    if ($relative.StartsWith('..', [StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($relative)) {
        throw 'INSTALL_FAILED'
    }
    return $relative.Replace('\', '/')
}

function Get-TelephoneInstallInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SourceRoot)

    $root = Resolve-TelephoneInstallCallerPath -Path $SourceRoot
    if (-not [IO.Directory]::Exists($root)) { throw 'SOURCE_ROOT_REQUIRED' }
    Assert-TelephoneInstallNoReparse -Path $root -Label 'Source root'
    $rows = [Collections.Generic.List[object]]::new()

    function Add-TelephoneInstallWalk {
        param([string]$Directory)
        Assert-TelephoneInstallNoReparse -Path $Directory -Label 'Source tree'
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Directory)) {
            $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Source tree contains a reparse point.'
            }
            if ($item.PSIsContainer) {
                Add-TelephoneInstallWalk -Directory $item.FullName
            } else {
                $identity = Get-TelephoneInstallFileIdentity -Path $item.FullName
                $rel = Get-TelephoneInstallRelativePath -Root $root -FullPath $item.FullName
                [void]$rows.Add([ordered]@{
                    path = $rel
                    bytes = [int64]$identity.bytes
                    sha256 = [string]$identity.sha256
                })
            }
        }
    }

    foreach ($tree in $script:TelephoneInstallTrees) {
        $dir = Join-Path $root $tree
        if (-not [IO.Directory]::Exists($dir)) { throw 'SOURCE_ROOT_REQUIRED' }
        Add-TelephoneInstallWalk -Directory $dir
    }

    $licensePath = Join-Path $root 'LICENSE'
    if (-not [IO.File]::Exists($licensePath)) { throw 'SOURCE_ROOT_REQUIRED' }
    Assert-TelephoneInstallNoReparse -Path $licensePath -Label 'Source license'
    $licenseIdentity = Get-TelephoneInstallFileIdentity -Path $licensePath
    [void]$rows.Add([ordered]@{
        path = 'LICENSE'
        bytes = [int64]$licenseIdentity.bytes
        sha256 = [string]$licenseIdentity.sha256
    })

    $arr = @($rows)
    [Array]::Sort($arr, [Comparison[object]]{ param($a, $b) [string]::CompareOrdinal([string]$a.path, [string]$b.path) })
    if ($arr.Count -lt 1) { throw 'SOURCE_ROOT_REQUIRED' }
    return @($arr)
}

function Get-TelephoneInstallSourceIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Inventory)

    $lines = [Collections.Generic.List[string]]::new()
    foreach ($row in @($Inventory)) {
        [void]$lines.Add(('{0}{1}{2}{1}{3}' -f [string]$row.path, "`t", [int64]$row.bytes, [string]$row.sha256))
    }
    $text = [string]::Join("`n", $lines) + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    return [ordered]@{
        protocol_version = 'telephone-line-source-identity-v1'
        file_count = @($Inventory).Count
        sha256 = Get-TelephoneInstallSha256 -Bytes $bytes
    }
}

function Get-TelephoneInstallTreeFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not [IO.Directory]::Exists($Root)) {
        return [ordered]@{ present = $false; file_count = 0; sha256 = [string]::Empty }
    }
    Assert-TelephoneInstallNoReparse -Path $Root -Label 'Tree'
    $rows = [Collections.Generic.List[string]]::new()

    function Add-TelephoneFingerprintWalk {
        param([string]$Directory)
        Assert-TelephoneInstallNoReparse -Path $Directory -Label 'Tree'
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Directory)) {
            $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Tree contains a reparse point.'
            }
            if ($item.PSIsContainer) {
                Add-TelephoneFingerprintWalk -Directory $item.FullName
            } else {
                $identity = Get-TelephoneInstallFileIdentity -Path $item.FullName
                $rel = Get-TelephoneInstallRelativePath -Root $Root -FullPath $item.FullName
                $ticks = [int64]$item.LastWriteTimeUtc.Ticks
                [void]$rows.Add(('{0}{1}{2}{1}{3}{1}{4}' -f $rel, "`t", [int64]$identity.bytes, [string]$identity.sha256, $ticks))
            }
        }
    }

    Add-TelephoneFingerprintWalk -Directory $Root
    $arr = @($rows)
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    $text = [string]::Join("`n", $arr) + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    return [ordered]@{
        present = $true
        file_count = $arr.Count
        sha256 = Get-TelephoneInstallSha256 -Bytes $bytes
    }
}

function Read-TelephoneInstallManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $path = Get-TelephoneInstallManifestPath -InstallRoot $InstallRoot
    if (-not [IO.File]::Exists($path)) { return $null }
    Assert-TelephoneInstallNoReparse -Path $path -Label 'Install manifest'
    $text = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($path))
    $value = $text | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
    return $value
}

function Test-TelephoneInstallManifestProduct {
    [CmdletBinding()]
    param([AllowNull()][object]$Manifest)
    if ($null -eq $Manifest -or $Manifest -isnot [Collections.IDictionary]) { return $false }
    if ([string]$Manifest.protocol_version -cne $script:TelephoneInstallManifestProtocol) { return $false }
    if ([string]$Manifest.product_id -cne $script:TelephoneInstallProductId) { return $false }
    if (-not $Manifest.Contains('files') -or -not $Manifest.Contains('source_identity')) { return $false }
    return $true
}

function Publish-TelephoneInstallManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][object]$SourceIdentity,
        [Parameter(Mandatory = $true)][object[]]$Files,
        [bool]$PathAppended
    )

    $manifest = [ordered]@{
        protocol_version = $script:TelephoneInstallManifestProtocol
        product_id = $script:TelephoneInstallProductId
        install_root = '.'
        source_identity = $SourceIdentity
        path_appended = [bool]$PathAppended
        files = @($Files)
    }
    $json = ConvertTo-TelephoneInstallJson -Value $manifest
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    Write-TelephoneInstallBytesAtomic -Path (Get-TelephoneInstallManifestPath -InstallRoot $InstallRoot) -Bytes $bytes
}

function Copy-TelephoneInstallInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][object[]]$Inventory
    )

    $source = Resolve-TelephoneInstallCallerPath -Path $SourceRoot
    $destRoot = Resolve-TelephoneInstallCallerPath -Path $InstallRoot
    foreach ($row in @($Inventory)) {
        $rel = [string]$row.path
        if ($rel.Contains('..')) { throw 'INSTALL_FAILED' }
        $src = [IO.Path]::GetFullPath((Join-Path $source ($rel.Replace('/', '\'))))
        $dest = [IO.Path]::GetFullPath((Join-Path $destRoot ($rel.Replace('/', '\'))))
        if (-not (Test-TelephoneInstallPathInsideRoot -Path $src -Root $source)) { throw 'INSTALL_FAILED' }
        if (-not (Test-TelephoneInstallPathInsideRoot -Path $dest -Root $destRoot)) { throw 'INSTALL_FAILED' }
        $bytes = [IO.File]::ReadAllBytes($src)
        $sha = Get-TelephoneInstallSha256 -Bytes $bytes
        if ([int64]$bytes.Length -ne [int64]$row.bytes -or $sha -cne [string]$row.sha256) {
            throw 'INSTALL_FAILED'
        }
        Write-TelephoneInstallBytesAtomic -Path $dest -Bytes $bytes
    }
}

function Get-TelephoneInstallRootResidue {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $root = Resolve-TelephoneInstallCallerPath -Path $InstallRoot
    if (-not [IO.Directory]::Exists($root)) {
        return [ordered]@{ root_remains = $false; residue = $false }
    }
    $hasEntries = $false
    foreach ($ignored in [IO.Directory]::EnumerateFileSystemEntries($root)) {
        $hasEntries = $true
        break
    }
    return [ordered]@{ root_remains = $true; residue = [bool]$hasEntries }
}

function Clear-TelephoneInstallEmptyDirectories {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $root = Resolve-TelephoneInstallCallerPath -Path $InstallRoot
    if (-not [IO.Directory]::Exists($root)) {
        return (Get-TelephoneInstallRootResidue -InstallRoot $root)
    }
    $directories = [Collections.Generic.List[string]]::new()
    function Add-TelephoneInstallDirectories {
        param([string]$Directory)
        if (-not [IO.Directory]::Exists($Directory)) { return }
        Assert-TelephoneInstallNoReparse -Path $Directory -Label 'Install directory'
        foreach ($entry in [IO.Directory]::EnumerateDirectories($Directory)) {
            $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if (-not (Test-TelephoneInstallPathInsideRoot -Path $item.FullName -Root $root)) { throw 'UNINSTALL_FAILED' }
            Add-TelephoneInstallDirectories -Directory $item.FullName
        }
        [void]$directories.Add((Resolve-TelephoneInstallCallerPath -Path $Directory))
    }
    Add-TelephoneInstallDirectories -Directory $root
    foreach ($dir in $directories) {
        if (-not [IO.Directory]::Exists($dir)) { continue }
        if (Test-TelephoneInstallReparse -Path $dir) { continue }
        if (-not (Test-TelephoneInstallPathInsideRoot -Path $dir -Root $root)) { throw 'UNINSTALL_FAILED' }
        $empty = $true
        foreach ($ignored in [IO.Directory]::EnumerateFileSystemEntries($dir)) {
            $empty = $false
            break
        }
        if ($empty) {
            [IO.Directory]::Delete($dir)
        }
    }
    return (Get-TelephoneInstallRootResidue -InstallRoot $root)
}

function Invoke-TelephoneInstallRecycleStateRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($StateRoot) -or -not (Test-TelephoneRecyclePathPresent -Path $StateRoot)) {
        return [ordered]@{ removed = $false; missing = $true }
    }
    $full = Resolve-TelephoneInstallCallerPath -Path $StateRoot
    Assert-TelephoneInstallNoReparse -Path $full -Label $Label
    $null = Wait-TelephoneRecycleOwnershipQuiescence -StateRoot $full
    $null = Move-TelephonePathToRecycleBin -Path $full
    $gone = -not (Test-TelephoneRecyclePathPresent -Path $full)
    if (-not $gone) { throw 'RECYCLE_BLOCKED' }
    return [ordered]@{ removed = $true; missing = $false }
}

function Remove-TelephoneInstallManifestedFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $root = Resolve-TelephoneInstallCallerPath -Path $InstallRoot
    foreach ($row in @($Manifest.files)) {
        $rel = [string]$row.path
        if ([string]::IsNullOrWhiteSpace($rel) -or $rel.Contains('..')) { throw 'UNINSTALL_FAILED' }
        $full = [IO.Path]::GetFullPath((Join-Path $root ($rel.Replace('/', '\'))))
        if (-not (Test-TelephoneInstallPathInsideRoot -Path $full -Root $root)) { throw 'UNINSTALL_FAILED' }
        if (-not [IO.File]::Exists($full)) { continue }
        Assert-TelephoneInstallNoReparse -Path $full -Label 'Installed file'
        $null = Move-TelephonePathToRecycleBin -Path $full
    }

    $manifestPath = Get-TelephoneInstallManifestPath -InstallRoot $root
    if ([IO.File]::Exists($manifestPath)) {
        Assert-TelephoneInstallNoReparse -Path $manifestPath -Label 'Install manifest'
        $null = Move-TelephonePathToRecycleBin -Path $manifestPath
    }

    return (Clear-TelephoneInstallEmptyDirectories -InstallRoot $root)
}

function Get-TelephoneInFlightJobCount {
    [CmdletBinding()]
    param([string]$StateRoot)

    if ([string]::IsNullOrWhiteSpace($StateRoot) -or -not [IO.Directory]::Exists($StateRoot)) {
        return 0
    }
    Assert-TelephoneInstallNoReparse -Path $StateRoot -Label 'State root'
    $jobs = Join-Path $StateRoot 'jobs'
    if (-not [IO.Directory]::Exists($jobs)) { return 0 }
    Assert-TelephoneInstallNoReparse -Path $jobs -Label 'State jobs'
    $count = 0
    foreach ($entry in [IO.Directory]::EnumerateDirectories($jobs)) {
        $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $receipt = Join-Path $item.FullName 'receipt.json'
        if (-not [IO.File]::Exists($receipt)) { $count += 1 }
    }
    return $count
}

function Get-TelephoneUserPathValue {
    [CmdletBinding()]
    param()

    $override = [string]$env:TELEPHONE_LINE_USER_PATH_FILE
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $path = Resolve-TelephoneInstallCallerPath -Path $override
        if (-not [IO.File]::Exists($path)) { return [string]::Empty }
        Assert-TelephoneInstallNoReparse -Path $path -Label 'PATH store'
        return [string][IO.File]::ReadAllText($path)
    }
    $value = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $value) { return [string]::Empty }
    return [string]$value
}

function Set-TelephoneUserPathValue {
    [CmdletBinding()]
    param([AllowNull()][string]$Value)

    $text = if ($null -eq $Value) { [string]::Empty } else { [string]$Value }
    $override = [string]$env:TELEPHONE_LINE_USER_PATH_FILE
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $path = [IO.Path]::GetFullPath($override)
        $parent = [IO.Path]::GetDirectoryName($path)
        if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
        Write-TelephoneInstallBytesAtomic -Path $path -Bytes $bytes
        return
    }
    [Environment]::SetEnvironmentVariable('Path', $text, 'User')
}

function Add-TelephoneInstallPathEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $root = Resolve-TelephoneInstallCallerPath -Path $InstallRoot
    $current = Get-TelephoneUserPathValue
    $parts = @()
    if (-not [string]::IsNullOrEmpty($current)) {
        $parts = @($current.Split([char]';'))
    }
    foreach ($part in $parts) {
        if ($part.TrimEnd('\').Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    $newValue = if ([string]::IsNullOrEmpty($current)) {
        $root
    } elseif ($current.EndsWith(';', [StringComparison]::Ordinal)) {
        $current + $root
    } else {
        $current + ';' + $root
    }
    Set-TelephoneUserPathValue -Value $newValue
    return $true
}

function Remove-TelephoneInstallPathEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $root = Resolve-TelephoneInstallCallerPath -Path $InstallRoot
    $current = Get-TelephoneUserPathValue
    if ([string]::IsNullOrEmpty($current)) { return }
    $kept = [Collections.Generic.List[string]]::new()
    foreach ($part in @($current.Split([char]';'))) {
        if ($part.TrimEnd('\').Equals($root, [StringComparison]::OrdinalIgnoreCase)) { continue }
        [void]$kept.Add($part)
    }
    Set-TelephoneUserPathValue -Value ([string]::Join(';', $kept))
}

function Confirm-TelephoneInstallFileIdentities {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $root = Resolve-TelephoneInstallCallerPath -Path $InstallRoot
    $drift = [Collections.Generic.List[string]]::new()
    foreach ($row in @($Manifest.files)) {
        $rel = [string]$row.path
        $full = [IO.Path]::GetFullPath((Join-Path $root ($rel.Replace('/', '\'))))
        if (-not [IO.File]::Exists($full)) {
            [void]$drift.Add($rel)
            continue
        }
        if (Test-TelephoneInstallReparse -Path $full) {
            [void]$drift.Add($rel)
            continue
        }
        $identity = Get-TelephoneInstallFileIdentity -Path $full
        if ([int64]$identity.bytes -ne [int64]$row.bytes -or [string]$identity.sha256 -cne [string]$row.sha256) {
            [void]$drift.Add($rel)
        }
    }
    return @($drift)
}

function Import-TelephoneSupervisorCommon {
    [CmdletBinding()]
    param()
    if ($script:TelephoneSupervisorCommonImported -and (Get-Command Get-TelephoneSupervisorVersionDirectory -ErrorAction SilentlyContinue)) {
        return
    }
    $supervisor = Join-Path $PSScriptRoot '..\supervisor\TelephoneSupervisor.Common.ps1'
    if (-not [IO.File]::Exists($supervisor)) { throw 'INSTALL_FAILED' }
    $escaped = $supervisor.Replace("'", "''")
    $block = [scriptblock]::Create(". '$escaped'")
    if ($null -ne $script:TelephoneInstallSessionState) {
        $null = $script:TelephoneInstallSessionState.InvokeCommand.InvokeScript($false, $block, $null, $null)
    } else {
        . $supervisor
    }
    $script:TelephoneSupervisorCommonImported = $true
}

function Publish-TelephoneInstallVersionPointer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][object[]]$Inventory,
        [switch]$SwitchCurrent
    )
    Import-TelephoneSupervisorCommon
    $versionId = [string]$Identity.sha256
    $versionDir = Get-TelephoneSupervisorVersionDirectory -InstallRoot $InstallRoot -VersionId $versionId
    if (-not [IO.Directory]::Exists($versionDir)) {
        [IO.Directory]::CreateDirectory($versionDir) | Out-Null
    }
    Assert-TelephoneInstallNoReparse -Path $versionDir -Label 'Version directory'
    Copy-TelephoneInstallInventory -SourceRoot $SourceRoot -InstallRoot $versionDir -Inventory $Inventory
    if ($SwitchCurrent) {
        $null = Write-TelephoneInstallCurrentPointer -InstallRoot $InstallRoot -VersionId $versionId -SourceSha256 $versionId
        $pendingPath = Join-Path $InstallRoot 'pending.json'
        if ([IO.File]::Exists($pendingPath)) {
            $null = Move-TelephonePathToRecycleBin -Path $pendingPath
        }
    } else {
        $pending = [ordered]@{
            protocol_version = 'telephone-line-install-pending-v1'
            version_id = [string]$versionId
            source_sha256 = [string]$versionId
            staged_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $null = Write-TelephoneJsonReplace -Path (Join-Path $InstallRoot 'pending.json') -Value $pending
    }
    return $versionId
}

function Complete-TelephoneInstallPendingActivationIfIdle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string]$StateRoot
    )
    Import-TelephoneSupervisorCommon
    $dest = Assert-TelephoneSupervisorCanonicalRoot -Path (Get-TelephoneSupervisorBaseInstallRoot -Path $InstallRoot) -Label 'Base install root'
    if (Test-TelephoneSupervisorVersionStorePath -Path $dest) {
        return [ordered]@{ switched = $false; reason = 'version-dir-refused' }
    }
    Assert-TelephoneInstallNoReparse -Path $dest -Label 'Install root'
    $lock = $null
    try {
        $lock = Open-TelephoneInstallActivationMutex -InstallRoot $dest
        $pendingPath = Join-Path $dest 'pending.json'
        if (-not [IO.File]::Exists($pendingPath)) {
            return [ordered]@{ switched = $false; reason = 'no-pending' }
        }
        $supState = if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
            Resolve-TelephoneSupervisorStateRoot -StateRoot $StateRoot
        } else {
            Resolve-TelephoneSupervisorStateRoot
        }
        $pinned = @(Get-TelephoneSupervisorPinnedVersionIds -StateRoot $supState)
        if (@($pinned).Count -gt 0) {
            return [ordered]@{ switched = $false; reason = 'pinned'; pinned_version_ids = @($pinned) }
        }
        $pending = (Read-TelephoneJson -Path $pendingPath).value
        $versionId = [string]$pending.version_id
        $versionDir = Get-TelephoneSupervisorVersionDirectory -InstallRoot $dest -VersionId $versionId
        if ($versionDir.Equals($dest, [StringComparison]::OrdinalIgnoreCase)) {
            return [ordered]@{ switched = $false; reason = 'version-dir-refused' }
        }
        if (-not [IO.Directory]::Exists($versionDir)) {
            return [ordered]@{ switched = $false; reason = 'pending-missing' }
        }
        Assert-TelephoneInstallNoReparse -Path $versionDir -Label 'Pending version directory'
        $inventory = @(Get-TelephoneInstallInventory -SourceRoot $versionDir)
        $identity = Get-TelephoneInstallSourceIdentity -Inventory $inventory
        $existing = Read-TelephoneInstallManifest -InstallRoot $dest
        $newPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($row in $inventory) { [void]$newPaths.Add([string]$row.path) }
        Copy-TelephoneInstallInventory -SourceRoot $versionDir -InstallRoot $dest -Inventory $inventory
        if ($null -ne $existing) {
            foreach ($row in @($existing.files)) {
                $rel = [string]$row.path
                if ($newPaths.Contains($rel)) { continue }
                $full = [IO.Path]::GetFullPath((Join-Path $dest ($rel.Replace('/', '\'))))
                if (-not (Test-TelephoneInstallPathInsideRoot -Path $full -Root $dest)) { throw 'UPDATE_FAILED' }
                if ([IO.File]::Exists($full) -and -not (Test-TelephoneInstallReparse -Path $full)) {
                    $null = Move-TelephonePathToRecycleBin -Path $full
                }
            }
        }
        $pathAppended = $false
        if ($null -ne $existing -and $existing.Contains('path_appended')) { $pathAppended = [bool]$existing.path_appended }
        Publish-TelephoneInstallManifest -InstallRoot $dest -SourceIdentity $identity -Files $inventory -PathAppended $pathAppended
        $null = Write-TelephoneInstallCurrentPointer -InstallRoot $dest -VersionId $versionId -SourceSha256 $versionId
        $null = Move-TelephonePathToRecycleBin -Path $pendingPath
        $null = Complete-TelephoneSupervisorInstallSurface -InstallRoot $dest
        return [ordered]@{ switched = $true; current_switched = $true; version_id = [string]$versionId }
    } finally {
        if ($null -ne $lock -and $null -ne $lock.mutex) {
            try { [void]$lock.mutex.ReleaseMutex() } catch { }
            $lock.mutex.Dispose()
        }
    }
}

function Complete-TelephoneSupervisorInstallSurface {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    Import-TelephoneSupervisorCommon
    $supState = Resolve-TelephoneSupervisorStateRoot
    $null = Initialize-TelephoneSupervisorLayout -StateRoot $supState
    return (Register-TelephoneSupervisorInstallSurface -InstallRoot $InstallRoot -StateRoot $supState)
}

function Invoke-TelephoneLineInstall {
    [CmdletBinding()]
    param(
        [string]$InstallRoot,
        [string]$SourceRoot,
        [switch]$AddToPath,
        [switch]$Force
    )

    try {
        $dest = Assert-TelephoneAllowedInstallRoot -InstallRoot (Resolve-TelephoneInstallRootValue -InstallRoot $InstallRoot)
        $source = Resolve-TelephoneSourceRootValue -SourceRoot $SourceRoot
        if ($dest.Equals($source, [StringComparison]::OrdinalIgnoreCase)) {
            return (New-TelephoneInstallResult -Ok $false -Action 'install' -Code 'SOURCE_EQUALS_INSTALL')
        }
        if (-not [IO.Directory]::Exists($source)) {
            return (New-TelephoneInstallResult -Ok $false -Action 'install' -Code 'SOURCE_ROOT_REQUIRED')
        }
        $inventory = @(Get-TelephoneInstallInventory -SourceRoot $source)
        $identity = Get-TelephoneInstallSourceIdentity -Inventory $inventory
        $existing = $null
        if ([IO.Directory]::Exists($dest)) {
            Assert-TelephoneInstallNoReparse -Path $dest -Label 'Install root'
            $existing = Read-TelephoneInstallManifest -InstallRoot $dest
        }
        $pathAlreadyRecorded = $false
        if ($null -ne $existing) {
            if (-not (Test-TelephoneInstallManifestProduct -Manifest $existing)) {
                return (New-TelephoneInstallResult -Ok $false -Action 'install' -Code 'MANIFEST_NOT_THIS_PRODUCT')
            }
            $pathAlreadyRecorded = [bool]$existing.path_appended
            $existingSha = [string]$existing.source_identity.sha256
            if ($existingSha -ceq [string]$identity.sha256 -and -not $Force) {
                $null = Complete-TelephoneSupervisorInstallSurface -InstallRoot $dest
                return (New-TelephoneInstallResult -Ok $true -Action 'install' -Code 'ALREADY_CURRENT' -Status 'already_current' -Extra ([ordered]@{
                    changed = $false
                    file_count = [int]$identity.file_count
                    path_appended = $pathAlreadyRecorded
                }))
            }
            if ($existingSha -cne [string]$identity.sha256 -and -not $Force) {
                return (New-TelephoneInstallResult -Ok $false -Action 'install' -Code 'INSTALL_EXISTS')
            }
        }

        if (-not [IO.Directory]::Exists($dest)) {
            [IO.Directory]::CreateDirectory($dest) | Out-Null
        }
        Assert-TelephoneInstallNoReparse -Path $dest -Label 'Install root'
        Copy-TelephoneInstallInventory -SourceRoot $source -InstallRoot $dest -Inventory $inventory
        if ($null -ne $existing) {
            $newPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($row in $inventory) { [void]$newPaths.Add([string]$row.path) }
            foreach ($row in @($existing.files)) {
                $rel = [string]$row.path
                if ($newPaths.Contains($rel)) { continue }
                $full = [IO.Path]::GetFullPath((Join-Path $dest ($rel.Replace('/', '\'))))
                if (-not (Test-TelephoneInstallPathInsideRoot -Path $full -Root $dest)) { throw 'INSTALL_FAILED' }
                if ([IO.File]::Exists($full) -and -not (Test-TelephoneInstallReparse -Path $full)) {
                    $null = Move-TelephonePathToRecycleBin -Path $full
                }
            }
        }

        $didAppend = $false
        $recordPath = $pathAlreadyRecorded
        if ($AddToPath -and -not $pathAlreadyRecorded) {
            $didAppend = [bool](Add-TelephoneInstallPathEntry -InstallRoot $dest)
            $recordPath = $didAppend -or $pathAlreadyRecorded
        }
        Publish-TelephoneInstallManifest -InstallRoot $dest -SourceIdentity $identity -Files $inventory -PathAppended $recordPath
        $versionId = Publish-TelephoneInstallVersionPointer -InstallRoot $dest -SourceRoot $source -Identity $identity -Inventory $inventory -SwitchCurrent
        $null = Complete-TelephoneSupervisorInstallSurface -InstallRoot $dest
        return (New-TelephoneInstallResult -Ok $true -Action 'install' -Code 'INSTALLED' -Status 'installed' -Extra ([ordered]@{
            changed = $true
            file_count = [int]$identity.file_count
            path_appended = [bool]$recordPath
            path_entry_added = [bool]$didAppend
            current_switched = $true
            version_id = [string]$versionId
        }))
    } catch {
        $code = [string]$_.Exception.Message
        if (-not $script:TelephoneInstallPublicMessage.Contains($code)) { $code = 'INSTALL_FAILED' }
        return (New-TelephoneInstallResult -Ok $false -Action 'install' -Code $code)
    }
}

function Invoke-TelephoneLineUninstall {
    [CmdletBinding()]
    param(
        [string]$InstallRoot,
        [switch]$RemoveState
    )

    try {
        $dest = Assert-TelephoneAllowedInstallRoot -InstallRoot (Resolve-TelephoneInstallRootValue -InstallRoot $InstallRoot)
        if (-not [IO.Directory]::Exists($dest)) {
            return (New-TelephoneInstallResult -Ok $true -Action 'uninstall' -Code 'ALREADY_CURRENT' -Status 'already_absent' -Extra ([ordered]@{ changed = $false; residue = $false }))
        }
        Assert-TelephoneInstallNoReparse -Path $dest -Label 'Install root'
        $manifest = Read-TelephoneInstallManifest -InstallRoot $dest
        if ($null -eq $manifest) {
            return (New-TelephoneInstallResult -Ok $false -Action 'uninstall' -Code 'MANIFEST_MISSING')
        }
        if (-not (Test-TelephoneInstallManifestProduct -Manifest $manifest)) {
            return (New-TelephoneInstallResult -Ok $false -Action 'uninstall' -Code 'MANIFEST_NOT_THIS_PRODUCT')
        }

        $stateRoot = Resolve-TelephoneStateRootValue
        if ($RemoveState) {
            if ([string]::IsNullOrWhiteSpace($stateRoot)) {
                return (New-TelephoneInstallResult -Ok $false -Action 'uninstall' -Code 'STATE_ROOT_REQUIRED')
            }
            $inFlight = Get-TelephoneInFlightJobCount -StateRoot $stateRoot
            if ($inFlight -gt 0) {
                return (New-TelephoneInstallResult -Ok $true -Action 'uninstall' -Code 'IN_FLIGHT_JOBS_PRESENT' -Status 'refused_in_flight' -Extra ([ordered]@{
                    changed = $false
                    in_flight_jobs = [int]$inFlight
                }))
            }
        }

        Import-TelephoneSupervisorCommon
        $supState = Resolve-TelephoneSupervisorStateRoot
        try { $null = Write-TelephoneSupervisorPause -StateRoot $supState -Paused $true } catch { }
        foreach ($run in @(Get-TelephoneSupervisorActiveRunList -StateRoot $supState)) {
            $null = Stop-TelephoneSupervisorExactRun -StateRoot $supState -RunId ([string]$run.run_id)
        }
        $null = Stop-TelephoneSupervisorExactProcess -StateRoot $supState
        Unregister-TelephoneSupervisorInstallSurface -InstallRoot $dest

        if ([bool]$manifest.path_appended) {
            Remove-TelephoneInstallPathEntry -InstallRoot $dest
        }
        $dashWatch = Join-Path $dest 'src\dashboard\TelephoneDashboard.Common.ps1'
        if ([IO.File]::Exists($dashWatch) -and -not (Test-TelephoneInstallReparse -Path $dashWatch)) {
            . $dashWatch
            $null = Stop-TelephoneDashboardExactWatcher -InstallRoot $dest
        }
        $null = Wait-TelephoneRecycleOwnershipQuiescence -StateRoot $supState
        if (-not [string]::IsNullOrWhiteSpace($stateRoot) -and -not $stateRoot.Equals($supState, [StringComparison]::OrdinalIgnoreCase)) {
            $null = Wait-TelephoneRecycleOwnershipQuiescence -StateRoot $stateRoot
        }
        foreach ($row in @($manifest.files)) {
            $rel = [string]$row.path
            if ([string]::IsNullOrWhiteSpace($rel) -or $rel.Contains('..')) { throw 'UNINSTALL_FAILED' }
            $full = [IO.Path]::GetFullPath((Join-Path $dest ($rel.Replace('/', '\'))))
            if (-not (Test-TelephoneInstallPathInsideRoot -Path $full -Root $dest)) { throw 'UNINSTALL_FAILED' }
            if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) {
                Assert-TelephoneInstallNoReparse -Path $full -Label 'Installed file'
                $null = Move-TelephonePathToRecycleBin -Path $full
            }
        }
        foreach ($extra in @('current.json', 'install-manifest.json')) {
            $extraPath = Join-Path $dest $extra
            if ([IO.File]::Exists($extraPath)) {
                Assert-TelephoneInstallNoReparse -Path $extraPath -Label 'Install pointer'
                $null = Move-TelephonePathToRecycleBin -Path $extraPath
            }
        }
        $versionsDir = Join-Path $dest 'versions'
        if ([IO.Directory]::Exists($versionsDir)) {
            Assert-TelephoneInstallNoReparse -Path $versionsDir -Label 'Version store'
            $null = Move-TelephonePathToRecycleBin -Path $versionsDir
        }
        $removed = Clear-TelephoneInstallEmptyDirectories -InstallRoot $dest
        $stateRemoved = $false
        if ($RemoveState) {
            $targets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            if (-not [string]::IsNullOrWhiteSpace($stateRoot) -and (Test-TelephoneRecyclePathPresent -Path $stateRoot)) {
                [void]$targets.Add((Resolve-TelephoneInstallCallerPath -Path $stateRoot))
            }
            if (-not [string]::IsNullOrWhiteSpace($supState) -and (Test-TelephoneRecyclePathPresent -Path $supState)) {
                [void]$targets.Add((Resolve-TelephoneInstallCallerPath -Path $supState))
            }
            $allGone = $true
            $anyTarget = $false
            foreach ($target in @($targets)) {
                $anyTarget = $true
                $recycled = Invoke-TelephoneInstallRecycleStateRoot -StateRoot $target -Label 'State root'
                if (-not [bool]$recycled.removed) { $allGone = $false }
            }
            $stateRemoved = ($anyTarget -and $allGone)
            $removed = Clear-TelephoneInstallEmptyDirectories -InstallRoot $dest
        }
        $residue = [bool]$removed.root_remains
        $code = if ($residue) { 'UNMANAGED_CONTENT_REMAINS' } else { 'UNINSTALLED' }
        $status = if ($residue) { 'uninstalled_unmanaged_remains' } else { 'uninstalled' }
        return (New-TelephoneInstallResult -Ok $true -Action 'uninstall' -Code $code -Status $status -Extra ([ordered]@{
            changed = $true
            residue = $residue
            state_removed = $stateRemoved
            state_preserved = (-not $stateRemoved)
        }))
    } catch {
        $code = [string]$_.Exception.Message
        if (-not $script:TelephoneInstallPublicMessage.Contains($code)) { $code = 'UNINSTALL_FAILED' }
        $extra = $null
        if ($code -ceq 'RECYCLE_BLOCKED') {
            $left = $false
            try { if (-not [string]::IsNullOrWhiteSpace($dest)) { $left = [bool](Get-TelephoneInstallRootResidue -InstallRoot $dest).root_remains } } catch { $left = $true }
            $extra = [ordered]@{
                residue = [bool]$left
                state_removed = $false
                state_preserved = $true
            }
        }
        return (New-TelephoneInstallResult -Ok $false -Action 'uninstall' -Code $code -Extra $extra)
    }
}

function Invoke-TelephoneLineUpdate {
    [CmdletBinding()]
    param(
        [string]$InstallRoot,
        [string]$SourceRoot
    )

    try {
        $dest = Assert-TelephoneAllowedInstallRoot -InstallRoot (Resolve-TelephoneInstallRootValue -InstallRoot $InstallRoot)
        $source = Resolve-TelephoneSourceRootValue -SourceRoot $SourceRoot
        if ($dest.Equals($source, [StringComparison]::OrdinalIgnoreCase)) {
            return (New-TelephoneInstallResult -Ok $false -Action 'update' -Code 'SOURCE_EQUALS_INSTALL')
        }
        if (-not [IO.Directory]::Exists($dest)) {
            return (New-TelephoneInstallResult -Ok $false -Action 'update' -Code 'MANIFEST_MISSING')
        }
        Assert-TelephoneInstallNoReparse -Path $dest -Label 'Install root'
        $existing = Read-TelephoneInstallManifest -InstallRoot $dest
        if ($null -eq $existing) {
            return (New-TelephoneInstallResult -Ok $false -Action 'update' -Code 'MANIFEST_MISSING')
        }
        if (-not (Test-TelephoneInstallManifestProduct -Manifest $existing)) {
            return (New-TelephoneInstallResult -Ok $false -Action 'update' -Code 'MANIFEST_NOT_THIS_PRODUCT')
        }

        $stateRoot = Resolve-TelephoneStateRootValue
        $inFlight = Get-TelephoneInFlightJobCount -StateRoot $stateRoot
        if ($inFlight -gt 0) {
            return (New-TelephoneInstallResult -Ok $true -Action 'update' -Code 'IN_FLIGHT_JOBS_PRESENT' -Status 'refused_in_flight' -Extra ([ordered]@{
                changed = $false
                in_flight_jobs = [int]$inFlight
            }))
        }

        Import-TelephoneSupervisorCommon
        $supState = Resolve-TelephoneSupervisorStateRoot
        $pinned = @(Get-TelephoneSupervisorPinnedVersionIds -StateRoot $supState)
        $inventory = @(Get-TelephoneInstallInventory -SourceRoot $source)
        $identity = Get-TelephoneInstallSourceIdentity -Inventory $inventory
        if ($pinned.Count -gt 0) {
            $versionId = Publish-TelephoneInstallVersionPointer -InstallRoot $dest -SourceRoot $source -Identity $identity -Inventory $inventory
            return (New-TelephoneInstallResult -Ok $true -Action 'update' -Code 'UPDATED' -Status 'staged_version' -Extra ([ordered]@{
                changed = $true
                file_count = [int]$identity.file_count
                state_preserved = $true
                current_switched = $false
                staged_version_id = [string]$versionId
                pinned_version_ids = @($pinned)
            }))
        }

        $before = Get-TelephoneInstallTreeFingerprint -Root $dest
        $newPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($row in $inventory) { [void]$newPaths.Add([string]$row.path) }
        Copy-TelephoneInstallInventory -SourceRoot $source -InstallRoot $dest -Inventory $inventory
        foreach ($row in @($existing.files)) {
            $rel = [string]$row.path
            if ($newPaths.Contains($rel)) { continue }
            $full = [IO.Path]::GetFullPath((Join-Path $dest ($rel.Replace('/', '\'))))
            if (-not (Test-TelephoneInstallPathInsideRoot -Path $full -Root $dest)) { throw 'UPDATE_FAILED' }
            if ([IO.File]::Exists($full) -and -not (Test-TelephoneInstallReparse -Path $full)) {
                $null = Move-TelephonePathToRecycleBin -Path $full
            }
        }
        Publish-TelephoneInstallManifest -InstallRoot $dest -SourceIdentity $identity -Files $inventory -PathAppended ([bool]$existing.path_appended)
        $versionId = Publish-TelephoneInstallVersionPointer -InstallRoot $dest -SourceRoot $source -Identity $identity -Inventory $inventory -SwitchCurrent
        $null = Complete-TelephoneSupervisorInstallSurface -InstallRoot $dest
        $dashCommon = Join-Path $dest 'src\dashboard\TelephoneDashboard.Common.ps1'
        if ([IO.File]::Exists($dashCommon) -and -not (Test-TelephoneInstallReparse -Path $dashCommon)) {
            . $dashCommon
            $watchScript = Join-Path $dest 'src\dashboard\Watch-TelephoneDashboard.ps1'
            $dashPaths = Get-TelephoneDashboardPaths
            $live = Read-TelephoneDashboardWatcherIdentity -Path ([string]$dashPaths.watcher)
            if ($null -ne $live -and (Test-TelephoneOwnerAlive -Owner $live) -and -not (Test-TelephoneDashboardWatcherIdentity -Identity $live -WatchScript $watchScript -InstallRoot $dest)) {
                $null = Stop-TelephoneDashboardExactWatcher -InstallRoot $dest -WatchScript $watchScript -AllowIncompatibleBuild
            }
        }
        $after = Get-TelephoneInstallTreeFingerprint -Root $dest
        return (New-TelephoneInstallResult -Ok $true -Action 'update' -Code 'UPDATED' -Status 'updated' -Extra ([ordered]@{
            changed = ([string]$before.sha256 -cne [string]$after.sha256)
            file_count = [int]$identity.file_count
            state_preserved = $true
            current_switched = $true
            version_id = [string]$versionId
        }))
    } catch {
        $code = [string]$_.Exception.Message
        if (-not $script:TelephoneInstallPublicMessage.Contains($code)) { $code = 'UPDATE_FAILED' }
        return (New-TelephoneInstallResult -Ok $false -Action 'update' -Code $code)
    }
}

function Get-TelephoneInstallAdapterReports {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $adapterRoot = Join-Path $InstallRoot 'src\adapters'
    $reports = [Collections.Generic.List[object]]::new()
    $validated = 0
    $errors = 0
    if (-not [IO.Directory]::Exists($adapterRoot)) {
        return [ordered]@{ validated = 0; expected = 8; errors = 1; routes = @() }
    }
    Assert-TelephoneInstallNoReparse -Path $adapterRoot -Label 'Adapter root'
    $core = Join-Path $InstallRoot 'src\core\TelephoneLine.Common.ps1'
    $contract = Join-Path $InstallRoot 'src\contracts\TelephoneLine.AdapterContract.ps1'
    if (-not [IO.File]::Exists($core) -or -not [IO.File]::Exists($contract)) {
        return [ordered]@{ validated = 0; expected = 8; errors = 1; routes = @() }
    }
    . $core
    . $contract
    foreach ($dir in @([IO.Directory]::EnumerateDirectories($adapterRoot))) {
        $item = Get-Item -LiteralPath $dir -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $descriptorPath = Join-Path $item.FullName 'adapter.json'
        if (-not [IO.File]::Exists($descriptorPath)) { continue }
        try {
            $loaded = Read-TelephoneAdapterDescriptor -Path $descriptorPath -AdapterRoot $item.FullName
            $descriptor = $loaded.descriptor
            [void]$reports.Add([ordered]@{
                route_id = [string]$descriptor.route_id
                display_name = [string]$descriptor.display_name
                dependency_boundary = [string]$descriptor.dependency_boundary
                boundary_declared_not_probed = $true
            })
            $validated += 1
        } catch {
            $errors += 1
            [void]$reports.Add([ordered]@{
                route_id = [string]$item.Name
                display_name = [string]$item.Name
                dependency_boundary = $null
                boundary_declared_not_probed = $true
                valid = $false
            })
        }
    }
    $arr = @($reports)
    [Array]::Sort($arr, [Comparison[object]]{ param($a, $b) [string]::CompareOrdinal([string]$a.route_id, [string]$b.route_id) })
    return [ordered]@{
        validated = [int]$validated
        expected = 8
        errors = [int]$errors
        routes = @($arr)
    }
}

function Invoke-TelephoneLineDoctor {
    [CmdletBinding()]
    param(
        [string]$InstallRoot,
        [string]$StateRoot
    )

    try {
        $dest = Assert-TelephoneAllowedInstallRoot -InstallRoot (Resolve-TelephoneInstallRootValue -InstallRoot $InstallRoot)
        $ps = $PSVersionTable.PSVersion
        $windowsAdequate = [bool]$IsWindows
        $powershellAdequate = ([int]$ps.Major -ge 7)
        $platform = [ordered]@{
            windows = [bool]$IsWindows
            windows_adequate = $windowsAdequate
            powershell_major = [int]$ps.Major
            powershell_minor = [int]$ps.Minor
            powershell_adequate = $powershellAdequate
        }
        $healthy = ($windowsAdequate -and $powershellAdequate)
        $code = 'HEALTHY'
        $manifestPresent = $false
        $identityMatch = $false
        $drift = @()
        $fileCount = 0
        if (-not [IO.Directory]::Exists($dest)) {
            $healthy = $false
            $code = 'MANIFEST_MISSING'
        } else {
            Assert-TelephoneInstallNoReparse -Path $dest -Label 'Install root'
            $manifest = Read-TelephoneInstallManifest -InstallRoot $dest
            if ($null -eq $manifest) {
                $healthy = $false
                $code = 'MANIFEST_MISSING'
            } elseif (-not (Test-TelephoneInstallManifestProduct -Manifest $manifest)) {
                $healthy = $false
                $code = 'MANIFEST_NOT_THIS_PRODUCT'
            } else {
                $manifestPresent = $true
                $fileCount = @($manifest.files).Count
                $drift = @(Confirm-TelephoneInstallFileIdentities -InstallRoot $dest -Manifest $manifest)
                $identityMatch = ($drift.Count -eq 0)
                if (-not $identityMatch) {
                    $healthy = $false
                    $code = 'DRIFT_DETECTED'
                }
            }
        }

        $adapterReport = [ordered]@{ validated = 0; expected = 8; errors = 0; routes = @() }
        if ([IO.Directory]::Exists($dest)) {
            $adapterReport = Get-TelephoneInstallAdapterReports -InstallRoot $dest
            if ([int]$adapterReport.validated -ne 8 -or [int]$adapterReport.errors -gt 0) {
                $healthy = $false
                if ($code -ceq 'HEALTHY') { $code = 'ADAPTER_DESCRIPTOR_INVALID' }
            }
        }

        $dashboardReport = [ordered]@{
            bundled_present = $false
            schemas_valid = $false
            config_present = $false
            config_valid = $false
            override_configured = $false
            opt_out = $false
            watcher_running = $false
            watcher_pid = 0
            watcher_identity_ok = $false
            observational = $true
            read_only = $true
        }
        $dashCommon = Join-Path $dest 'src\dashboard\TelephoneDashboard.Common.ps1'
        if ([IO.File]::Exists($dashCommon) -and -not (Test-TelephoneInstallReparse -Path $dashCommon)) {
            . $dashCommon
            $dashboardReport = Get-TelephoneDashboardDoctorReport -InstallRoot $dest -StateRoot $StateRoot
            if (-not [bool]$dashboardReport.bundled_present -or -not [bool]$dashboardReport.schemas_valid) {
                $healthy = $false
                if ($code -ceq 'HEALTHY') { $code = 'DRIFT_DETECTED' }
            }
        } elseif ([IO.Directory]::Exists($dest) -and [bool]$manifestPresent) {
            $healthy = $false
            if ($code -ceq 'HEALTHY') { $code = 'DRIFT_DETECTED' }
        }

        $controlPlaneReport = [ordered]@{
            bundled_present = $false
            required_files = 0
            missing = @()
            schemas_valid = $false
            schema_errors = @()
            current_state_is_single_projection = $false
            controller_is_authority_bounded = $false
            destructive_shared_host_tests_automatic = $false
        }
        $controlPlaneCommon = Join-Path $dest 'src\control-plane\TelephoneControlPlane.Common.ps1'
        if ([IO.File]::Exists($controlPlaneCommon) -and -not (Test-TelephoneInstallReparse -Path $controlPlaneCommon)) {
            . $controlPlaneCommon
            $controlPlaneReport = Get-TelephoneControlPlaneDoctorReport -ProductRoot $dest -SupervisorStateRoot $StateRoot
            if (-not [bool]$controlPlaneReport.bundled_present -or -not [bool]$controlPlaneReport.schemas_valid -or -not [bool]$controlPlaneReport.controller_is_authority_bounded) {
                $healthy = $false
                if ($code -ceq 'HEALTHY') { $code = 'DRIFT_DETECTED' }
            }
        } elseif ([IO.Directory]::Exists($dest) -and [bool]$manifestPresent) {
            $healthy = $false
            if ($code -ceq 'HEALTHY') { $code = 'DRIFT_DETECTED' }
        }

        $resolvedState = Resolve-TelephoneStateRootValue -StateRoot $StateRoot
        $stateReachable = $false
        $inFlight = 0
        if (-not [string]::IsNullOrWhiteSpace($resolvedState)) {
            $stateReachable = [IO.Directory]::Exists($resolvedState)
            if ($stateReachable) {
                $inFlight = Get-TelephoneInFlightJobCount -StateRoot $resolvedState
            }
        }

        $supervisorReport = [ordered]@{
            inbox = $false
            claimed = $false
            outbox = $false
            control = $false
            paused_by_pascal = $false
            task = [ordered]@{ registered = $false; action_ok = $false; principal_ok = $false }
            desktop = [ordered]@{ emergency = $false; console = $false }
            owner_ok = $true
            stale_owners = 0
            pid_reused = 0
            orphan_owners = 0
            current_version_id = ''
            pinned_version_ids = @()
            one_supervisor = $false
            current_version_identity_ok = $false
            pending_version_identity_ok = $true
            pinned_version_identities_ok = $true
        }
        if ([IO.Directory]::Exists($dest) -and [bool]$manifestPresent) {
            try {
                Import-TelephoneSupervisorCommon
                $supervisorReport = Get-TelephoneSupervisorDoctorReport -InstallRoot $dest -StateRoot $StateRoot
                $currentOk = $true
                $pendingOk = $true
                $pinnedOk = $true
                if (-not [string]::IsNullOrWhiteSpace([string]$supervisorReport.current_version_id)) {
                    $currentDir = Get-TelephoneSupervisorVersionDirectory -InstallRoot $dest -VersionId ([string]$supervisorReport.current_version_id)
                    if (-not [IO.Directory]::Exists($currentDir)) {
                        $currentOk = $false
                    } else {
                        try {
                            $curInv = @(Get-TelephoneInstallInventory -SourceRoot $currentDir)
                            $curId = Get-TelephoneInstallSourceIdentity -Inventory $curInv
                            $expected = if (-not [string]::IsNullOrWhiteSpace([string]$supervisorReport.current_source_sha256)) { [string]$supervisorReport.current_source_sha256 } else { [string]$supervisorReport.current_version_id }
                            if ([string]$curId.sha256 -cne $expected -and [string]$curId.sha256 -cne [string]$supervisorReport.current_version_id) { $currentOk = $false }
                        } catch { $currentOk = $false }
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$supervisorReport.pending_version_id)) {
                    $pendingDir = Get-TelephoneSupervisorVersionDirectory -InstallRoot $dest -VersionId ([string]$supervisorReport.pending_version_id)
                    if (-not [IO.Directory]::Exists($pendingDir)) {
                        $pendingOk = $false
                    } else {
                        try {
                            $penInv = @(Get-TelephoneInstallInventory -SourceRoot $pendingDir)
                            $penId = Get-TelephoneInstallSourceIdentity -Inventory $penInv
                            $expectedPending = if (-not [string]::IsNullOrWhiteSpace([string]$supervisorReport.pending_source_sha256)) { [string]$supervisorReport.pending_source_sha256 } else { [string]$supervisorReport.pending_version_id }
                            if ([string]$penId.sha256 -cne $expectedPending -and [string]$penId.sha256 -cne [string]$supervisorReport.pending_version_id) { $pendingOk = $false }
                        } catch { $pendingOk = $false }
                    }
                }
                foreach ($pinId in @($supervisorReport.pinned_version_ids)) {
                    $pinDir = Get-TelephoneSupervisorVersionDirectory -InstallRoot $dest -VersionId ([string]$pinId)
                    if (-not [IO.Directory]::Exists($pinDir)) { $pinnedOk = $false; continue }
                    try {
                        $pinInv = @(Get-TelephoneInstallInventory -SourceRoot $pinDir)
                        $pinIdent = Get-TelephoneInstallSourceIdentity -Inventory $pinInv
                        if ([string]$pinIdent.sha256 -cne [string]$pinId) { $pinnedOk = $false }
                    } catch { $pinnedOk = $false }
                }
                $supervisorReport.current_version_identity_ok = [bool]$currentOk
                $supervisorReport.pending_version_identity_ok = [bool]$pendingOk
                $supervisorReport.pinned_version_identities_ok = [bool]$pinnedOk
                $taskOk = [bool]$supervisorReport.task.registered -and [bool]$supervisorReport.task.action_ok -and [bool]$supervisorReport.task.principal_ok
                $layoutOk = [bool]$supervisorReport.inbox -and [bool]$supervisorReport.outbox -and [bool]$supervisorReport.control
                $desktopOk = [bool]$supervisorReport.desktop.emergency -and [bool]$supervisorReport.desktop.console
                $oneOk = [bool]$supervisorReport.one_supervisor
                if (-not $taskOk -or -not $layoutOk -or -not $desktopOk -or -not [bool]$supervisorReport.owner_ok -or -not $currentOk -or -not $pendingOk -or -not $pinnedOk -or -not $oneOk) {
                    $healthy = $false
                    if ($code -ceq 'HEALTHY') { $code = 'DRIFT_DETECTED' }
                }
            } catch {
                $healthy = $false
                if ($code -ceq 'HEALTHY') { $code = 'DRIFT_DETECTED' }
            }
        }

        if (-not $healthy -and $code -ceq 'HEALTHY') { $code = 'DOCTOR_FAILED' }
        return (New-TelephoneInstallResult -Ok $true -Action 'doctor' -Code $code -Status $(if ($healthy) { 'healthy' } else { 'unhealthy' }) -Extra ([ordered]@{
            changed = $false
            healthy = [bool]$healthy
            read_only = $true
            harness_probed = $false
            harness_launched = $false
            platform = $platform
            manifest = [ordered]@{
                present = [bool]$manifestPresent
                file_count = [int]$fileCount
                identity_match = [bool]$identityMatch
                drift = @($drift)
            }
            adapters = $adapterReport
            dashboard = $dashboardReport
            control_plane = $controlPlaneReport
            supervisor = $supervisorReport
            state = [ordered]@{
                resolved = (-not [string]::IsNullOrWhiteSpace($resolvedState))
                reachable = [bool]$stateReachable
                in_flight_jobs = [int]$inFlight
            }
        }))
    } catch {
        $code = [string]$_.Exception.Message
        if (-not $script:TelephoneInstallPublicMessage.Contains($code)) { $code = 'DOCTOR_FAILED' }
        return (New-TelephoneInstallResult -Ok $false -Action 'doctor' -Code $code -Extra ([ordered]@{
            changed = $false
            read_only = $true
            harness_probed = $false
            harness_launched = $false
        }))
    }
}

$script:TelephoneSupervisorCommonPath = Join-Path $PSScriptRoot '..\supervisor\TelephoneSupervisor.Common.ps1'
if ([IO.File]::Exists($script:TelephoneSupervisorCommonPath) -and -not $script:TelephoneSupervisorCommonImported) {
    . $script:TelephoneSupervisorCommonPath
    $script:TelephoneSupervisorCommonImported = $true
}

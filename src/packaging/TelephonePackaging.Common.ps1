# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest

if (-not $IsWindows) {
    throw 'Telephone Line v0.1 supports Windows only.'
}

Add-Type -AssemblyName System.IO.Compression

$script:TelephonePackagingResultProtocol = 'telephone-line-package-result-v1'
$script:TelephonePackagingManifestProtocol = 'telephone-line-release-manifest-v1'
$script:TelephonePackagingProduct = 'telephone-line'
$script:TelephonePackagingVersion = '0.1.0'
$script:TelephonePackagingLicense = 'MPL-2.0'
$script:TelephonePackagingPlatform = 'windows'
$script:TelephonePackagingSourceZipName = 'telephone-line-0.1.0-source.zip'
$script:TelephonePackagingReleaseZipName = 'telephone-line-0.1.0-windows.zip'
$script:TelephonePackagingRequiredTrees = @('src', 'schemas', 'docs')
$script:TelephonePackagingSourceOnlyTrees = @('.github', 'tests')
$script:TelephonePackagingRootFiles = @('README.md', 'LICENSE', 'CONTRIBUTING.md', 'SECURITY.md', 'THIRD-PARTY-NOTICES.md', '.gitattributes')
$script:TelephonePackagingZipTimestamp = [DateTimeOffset]::new(2001, 1, 1, 0, 0, 0, [TimeSpan]::Zero)

$script:TelephonePackagingExcludedSegments = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($name in @(
    '.control',
    '.git',
    'node_modules',
    'logs',
    'log',
    'receipts',
    'dispatches',
    'deliveries',
    'delivery',
    'cache',
    'caches',
    'state'
)) {
    [void]$script:TelephonePackagingExcludedSegments.Add($name)
}

$script:TelephonePackagingBinaryExtensions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($ext in @('.exe', '.dll', '.sys', '.com', '.scr', '.msi', '.msix', '.iso', '.img', '.so', '.dylib')) {
    [void]$script:TelephonePackagingBinaryExtensions.Add($ext)
}

$script:TelephonePackagingPublicCode = [ordered]@{
    PACKAGED = 'The packaging command completed.'
    PACKAGING_FAILED = 'The packaging command failed.'
    SOURCE_ROOT_REQUIRED = 'Source root is required and must contain the product trees.'
    REPARSE_POINT = 'A reparse point was encountered. Packaging refused.'
    EXCLUDED_PATH = 'An excluded path would have been included. Packaging refused.'
    OUTPUT_INSIDE_SOURCE = 'The output path is inside the source tree. Pass -OutputPath explicitly if that is intended.'
    OUTPUT_EXISTS = 'The output file already exists. Pass -Force to replace it.'
    OUTPUT_PATH_REQUIRED = 'Output path is required.'
    BINARY_REFUSED = 'A binary or installer image would have been included. Packaging refused.'
    LICENSE_MISSING = 'LICENSE is missing from the source root.'
    CATALOG_MISSING = 'The route catalog is missing from the source tree.'
}

function Get-TelephonePackagingPublicMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Code)
    if ($script:TelephonePackagingPublicCode.Contains($Code)) {
        return [string]$script:TelephonePackagingPublicCode[$Code]
    }
    return [string]$script:TelephonePackagingPublicCode['PACKAGING_FAILED']
}

function New-TelephonePackagingResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$Ok,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$Code,
        [object]$Artifact,
        [int]$EntryCount = 0
    )

    return [ordered]@{
        protocol_version = $script:TelephonePackagingResultProtocol
        ok = $Ok
        action = $Action
        code = $Code
        message = Get-TelephonePackagingPublicMessage -Code $Code
        artifact = $Artifact
        entry_count = [int]$EntryCount
    }
}

function ConvertTo-TelephonePackagingJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Value)
    return (($Value | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n")
}

function Get-TelephonePackagingSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-TelephonePackagingFileBytesAndHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    return [ordered]@{
        bytes = [int64]$bytes.Length
        sha256 = Get-TelephonePackagingSha256 -Bytes $bytes
    }
}

function Test-TelephonePackagingPathInsideRoot {
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

function Test-TelephonePackagingReparse {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path) -and -not [IO.Directory]::Exists($Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-TelephonePackagingNoReparse {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Label)
    if (Test-TelephonePackagingReparse -Path $Path) {
        throw 'REPARSE_POINT'
    }
    $null = $Label
}

function Get-TelephonePackagingRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$FullPath
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($FullPath)
    if (-not (Test-TelephonePackagingPathInsideRoot -Path $pathFull -Root $rootFull)) {
        throw 'PACKAGING_FAILED'
    }
    $relative = [IO.Path]::GetRelativePath($rootFull, $pathFull)
    if ($relative.StartsWith('..', [StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($relative)) {
        throw 'PACKAGING_FAILED'
    }
    return $relative.Replace('\', '/')
}

function Test-TelephonePackagingExcludedRelative {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Relative)
    $n = $Relative.Replace('\', '/').Trim('/')
    if ([string]::IsNullOrWhiteSpace($n)) { return $false }
    foreach ($segment in @($n.Split([char]'/'))) {
        if ($script:TelephonePackagingExcludedSegments.Contains($segment)) { return $true }
    }
    return $false
}

function Get-TelephonePackagingExclusionPatterns {
    [CmdletBinding()]
    param()
    return @(
        '.control/**',
        '.git/**',
        '**/node_modules/**',
        '**/logs/**',
        '**/log/**',
        '**/receipts/**',
        '**/dispatches/**',
        '**/deliveries/**',
        '**/delivery/**',
        '**/cache/**',
        '**/caches/**',
        '**/state/**',
        '**/*.{exe,dll,sys,com,scr,msi,msix,iso,img,so,dylib}',
        'user-profile/**',
        'root files other than README.md, LICENSE, CONTRIBUTING.md, SECURITY.md, THIRD-PARTY-NOTICES.md, and .gitattributes'
    )
}

function Resolve-TelephonePackagingSourceRoot {
    [CmdletBinding()]
    param([string]$SourceRoot)

    $root = $null
    if (-not [string]::IsNullOrWhiteSpace($SourceRoot)) {
        $root = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    } else {
        $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
    }
    if (-not [IO.Directory]::Exists($root)) { throw 'SOURCE_ROOT_REQUIRED' }
    Assert-TelephonePackagingNoReparse -Path $root -Label 'Source root'
    foreach ($tree in $script:TelephonePackagingRequiredTrees) {
        $dir = Join-Path $root $tree
        if (-not [IO.Directory]::Exists($dir)) { throw 'SOURCE_ROOT_REQUIRED' }
        Assert-TelephonePackagingNoReparse -Path $dir -Label 'Source tree'
    }
    $license = Join-Path $root 'LICENSE'
    if (-not [IO.File]::Exists($license)) { throw 'LICENSE_MISSING' }
    Assert-TelephonePackagingNoReparse -Path $license -Label 'Source license'
    return $root
}

function Resolve-TelephonePackagingOutputFile {
    [CmdletBinding()]
    param(
        [string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$DefaultFileName,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][bool]$OutputPathBound
    )

    $resolved = $null
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolved = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) $DefaultFileName))
    } else {
        $candidate = [IO.Path]::GetFullPath($OutputPath)
        $asDirectory = $OutputPath.EndsWith('\') -or $OutputPath.EndsWith('/') -or [IO.Directory]::Exists($candidate)
        if ($asDirectory) {
            $resolved = [IO.Path]::GetFullPath((Join-Path $candidate $DefaultFileName))
        } else {
            $resolved = $candidate
        }
    }
    $inside = Test-TelephonePackagingPathInsideRoot -Path $resolved -Root $SourceRoot
    if ($inside -and -not $OutputPathBound) {
        throw 'OUTPUT_INSIDE_SOURCE'
    }
    $parent = [IO.Path]::GetDirectoryName($resolved)
    if ([string]::IsNullOrWhiteSpace($parent)) { throw 'OUTPUT_PATH_REQUIRED' }
    if (-not [IO.Directory]::Exists($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    Assert-TelephonePackagingNoReparse -Path $parent -Label 'Output directory'
    return $resolved
}

function Write-TelephonePackagingUtf8File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text,
        [switch]$Force
    )

    if ([IO.File]::Exists($Path) -and -not $Force) { throw 'OUTPUT_EXISTS' }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Get-TelephoneRedistributableFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [ValidateSet('source', 'release')]
        [Parameter(Mandatory = $true)][string]$Kind
    )

    $root = Resolve-TelephonePackagingSourceRoot -SourceRoot $SourceRoot
    $trees = [Collections.Generic.List[string]]::new()
    foreach ($tree in $script:TelephonePackagingRequiredTrees) { [void]$trees.Add($tree) }
    if ($Kind -ceq 'source') {
        foreach ($tree in $script:TelephonePackagingSourceOnlyTrees) {
            $dir = Join-Path $root $tree
            if (-not [IO.Directory]::Exists($dir)) { throw 'SOURCE_ROOT_REQUIRED' }
            [void]$trees.Add($tree)
        }
    }

    $rows = [Collections.Generic.List[object]]::new()

    function Add-TelephonePackagingWalk {
        param([string]$Directory)
        Assert-TelephonePackagingNoReparse -Path $Directory -Label 'Source tree'
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Directory)) {
            $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'REPARSE_POINT'
            }
            $rel = Get-TelephonePackagingRelativePath -Root $root -FullPath $item.FullName
            if (Test-TelephonePackagingExcludedRelative -Relative $rel) {
                continue
            }
            if ($item.PSIsContainer) {
                Add-TelephonePackagingWalk -Directory $item.FullName
            } else {
                $ext = [IO.Path]::GetExtension($item.Name)
                if (-not [string]::IsNullOrWhiteSpace($ext) -and $script:TelephonePackagingBinaryExtensions.Contains($ext)) {
                    throw 'BINARY_REFUSED'
                }
                $id = Get-TelephonePackagingFileBytesAndHash -Path $item.FullName
                [void]$rows.Add([ordered]@{
                    path = $rel
                    bytes = [int64]$id.bytes
                    sha256 = [string]$id.sha256
                })
            }
        }
    }

    foreach ($tree in $trees) {
        Add-TelephonePackagingWalk -Directory (Join-Path $root $tree)
    }

    foreach ($name in $script:TelephonePackagingRootFiles) {
        $path = Join-Path $root $name
        if (-not [IO.File]::Exists($path)) { throw 'SOURCE_ROOT_REQUIRED' }
        Assert-TelephonePackagingNoReparse -Path $path -Label 'Root file'
        $rel = $name.Replace('\', '/')
        if (Test-TelephonePackagingExcludedRelative -Relative $rel) { throw 'EXCLUDED_PATH' }
        $id = Get-TelephonePackagingFileBytesAndHash -Path $path
        [void]$rows.Add([ordered]@{
            path = $rel
            bytes = [int64]$id.bytes
            sha256 = [string]$id.sha256
        })
    }

    $arr = @($rows)
    [Array]::Sort($arr, [Comparison[object]]{ param($a, $b) [string]::CompareOrdinal([string]$a.path, [string]$b.path) })
    foreach ($row in $arr) {
        if (Test-TelephonePackagingExcludedRelative -Relative ([string]$row.path)) {
            throw 'EXCLUDED_PATH'
        }
        if ([IO.Path]::IsPathRooted([string]$row.path) -or ([string]$row.path).Contains('\') -or ([string]$row.path).Contains('..')) {
            throw 'PACKAGING_FAILED'
        }
    }
    if ($arr.Count -lt 1) { throw 'SOURCE_ROOT_REQUIRED' }
    return @($arr)
}

function New-TelephoneDeterministicZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][object[]]$Files,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [switch]$Force
    )

    if ([IO.File]::Exists($OutputPath) -and -not $Force) { throw 'OUTPUT_EXISTS' }
    if ([IO.File]::Exists($OutputPath)) { [IO.File]::Delete($OutputPath) }

    $root = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $fileStream = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($fileStream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($row in @($Files)) {
                $posix = [string]$row.path
                if ($posix.Contains('\') -or $posix.StartsWith('/') -or $posix.Contains('..')) {
                    throw 'PACKAGING_FAILED'
                }
                $full = [IO.Path]::GetFullPath((Join-Path $root ($posix.Replace('/', '\'))))
                Assert-TelephonePackagingNoReparse -Path $full -Label 'Archive member'
                $data = [IO.File]::ReadAllBytes($full)
                $entry = $archive.CreateEntry($posix, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $script:TelephonePackagingZipTimestamp
                $entryStream = $entry.Open()
                try {
                    $entryStream.Write($data, 0, $data.Length)
                } finally {
                    $entryStream.Dispose()
                }
            }
        } finally {
            $archive.Dispose()
        }
    } catch {
        if ([IO.File]::Exists($OutputPath)) { [IO.File]::Delete($OutputPath) }
        throw
    }
}

function Get-TelephoneCatalogRouteIds {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SourceRoot)

    $path = Join-Path $SourceRoot 'src\catalog\routes.json'
    if (-not [IO.File]::Exists($path)) { throw 'CATALOG_MISSING' }
    Assert-TelephonePackagingNoReparse -Path $path -Label 'Route catalog'
    $text = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($path))
    $catalog = $text | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
    $ids = [Collections.Generic.List[string]]::new()
    foreach ($route in @($catalog.routes)) {
        [void]$ids.Add([string]$route.route_id)
    }
    if ($ids.Count -ne 8) { throw 'PACKAGING_FAILED' }
    return @($ids)
}

function New-TelephoneReleaseManifestObject {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SourceRoot)

    $files = @(Get-TelephoneRedistributableFiles -SourceRoot $SourceRoot -Kind 'source')
    $routeIds = @(Get-TelephoneCatalogRouteIds -SourceRoot $SourceRoot)
    $totalBytes = [int64]0
    $fileRows = [Collections.Generic.List[object]]::new()
    foreach ($row in $files) {
        $totalBytes += [int64]$row.bytes
        [void]$fileRows.Add([ordered]@{
            path = [string]$row.path
            bytes = [int64]$row.bytes
            sha256 = [string]$row.sha256
        })
    }

    return [ordered]@{
        protocol_version = $script:TelephonePackagingManifestProtocol
        product = $script:TelephonePackagingProduct
        version = $script:TelephonePackagingVersion
        license = $script:TelephonePackagingLicense
        platform = $script:TelephonePackagingPlatform
        denominator = 8
        route_ids = @($routeIds)
        artifacts = @(
            [ordered]@{
                name = $script:TelephonePackagingSourceZipName
                contains = 'src/, schemas/, docs/, .github/, tests/, and root README.md, LICENSE, CONTRIBUTING.md, SECURITY.md, THIRD-PARTY-NOTICES.md, .gitattributes'
                bytes = $null
                sha256 = $null
            },
            [ordered]@{
                name = $script:TelephonePackagingReleaseZipName
                contains = 'src/, schemas/, docs/, and root README.md, LICENSE, CONTRIBUTING.md, SECURITY.md, THIRD-PARTY-NOTICES.md, .gitattributes; excludes tests/ and .github/'
                bytes = $null
                sha256 = $null
            }
        )
        files = @($fileRows)
        counts = [ordered]@{
            files = [int]$fileRows.Count
            bytes = [int64]$totalBytes
        }
        excluded = @(Get-TelephonePackagingExclusionPatterns)
    }
}

function Invoke-TelephoneWriteArchive {
    [CmdletBinding()]
    param(
        [string]$SourceRoot,
        [string]$OutputPath,
        [switch]$Force,
        [Parameter(Mandatory = $true)][bool]$OutputPathBound,
        [Parameter(Mandatory = $true)][ValidateSet('source', 'release')][string]$Kind
    )

    $action = if ($Kind -ceq 'source') { 'source-archive' } else { 'release-zip' }
    $defaultName = if ($Kind -ceq 'source') { $script:TelephonePackagingSourceZipName } else { $script:TelephonePackagingReleaseZipName }
    try {
        $root = Resolve-TelephonePackagingSourceRoot -SourceRoot $SourceRoot
        $files = @(Get-TelephoneRedistributableFiles -SourceRoot $root -Kind $Kind)
        $out = Resolve-TelephonePackagingOutputFile -OutputPath $OutputPath -DefaultFileName $defaultName -SourceRoot $root -OutputPathBound $OutputPathBound
        New-TelephoneDeterministicZip -SourceRoot $root -Files $files -OutputPath $out -Force:$Force
        $id = Get-TelephonePackagingFileBytesAndHash -Path $out
        $artifact = [ordered]@{
            path = $out
            bytes = [int64]$id.bytes
            sha256 = [string]$id.sha256
        }
        return New-TelephonePackagingResult -Ok $true -Action $action -Code 'PACKAGED' -Artifact $artifact -EntryCount $files.Count
    } catch {
        $code = [string]$_.Exception.Message
        if (-not $script:TelephonePackagingPublicCode.Contains($code)) { $code = 'PACKAGING_FAILED' }
        return New-TelephonePackagingResult -Ok $false -Action $action -Code $code -Artifact $null -EntryCount 0
    }
}

function Invoke-TelephoneWriteReleaseManifest {
    [CmdletBinding()]
    param(
        [string]$SourceRoot,
        [string]$OutputPath,
        [switch]$Force,
        [Parameter(Mandatory = $true)][bool]$OutputPathBound
    )

    try {
        $root = Resolve-TelephonePackagingSourceRoot -SourceRoot $SourceRoot
        $defaultName = 'release-manifest.json'
        $out = $null
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $out = Join-Path $root $defaultName
        } else {
            $out = Resolve-TelephonePackagingOutputFile -OutputPath $OutputPath -DefaultFileName $defaultName -SourceRoot $root -OutputPathBound $OutputPathBound
        }
        $core = Join-Path $root 'src\core\TelephoneLine.Common.ps1'
        . $core
        $manifest = New-TelephoneReleaseManifestObject -SourceRoot $root
        $text = ConvertTo-TelephonePackagingJson -Value $manifest
        Assert-TelephoneJsonSchema -JsonText $text -SchemaName 'release-manifest' -Label 'release-manifest.json'
        Write-TelephonePackagingUtf8File -Path $out -Text $text -Force:$Force
        $id = Get-TelephonePackagingFileBytesAndHash -Path $out
        $artifact = [ordered]@{
            path = $out
            bytes = [int64]$id.bytes
            sha256 = [string]$id.sha256
        }
        return New-TelephonePackagingResult -Ok $true -Action 'release-manifest' -Code 'PACKAGED' -Artifact $artifact -EntryCount ([int]$manifest.counts.files)
    } catch {
        $code = [string]$_.Exception.Message
        if (-not $script:TelephonePackagingPublicCode.Contains($code)) { $code = 'PACKAGING_FAILED' }
        return New-TelephonePackagingResult -Ok $false -Action 'release-manifest' -Code $code -Artifact $null -EntryCount 0
    }
}

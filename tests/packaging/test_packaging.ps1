# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'src\core\TelephoneLine.Common.ps1')
. (Join-Path $repoRoot 'src\packaging\TelephonePackaging.Common.ps1')
$pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$assertions = 0
$packageSetExcludesPrivate = 0
$sourceArchiveDeterministic = 0
$releaseZipDeterministic = 0
$releaseZipExcludesTests = 0
$archivesContainLicense = 0
$manifestMatchesTree = 0
$manifestDeterministic = 0
$manifestRoutesEight = 0
$manifestSchemaValid = 0
$redistributionPrivacyClean = 0
$thirdPartyInventoryAccurate = 0
$archivesMarkdownLinksResolved = 0

function Assert-PackagingTest {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Get-FileSha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Write-Utf8File {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $parent = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllBytes($Path, [Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function Invoke-PackagingCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [string[]]$Arguments
    )
    $scriptPath = Join-Path $repoRoot ('src\packaging\' + $ScriptName)
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
        try { $json = $stdout | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String } catch { $json = $null }
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

function Get-ZipEntryNames {
    param([Parameter(Mandatory = $true)][string]$Path)
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $names = [Collections.Generic.List[string]]::new()
        foreach ($entry in $zip.Entries) {
            [void]$names.Add([string]$entry.FullName.Replace('\', '/'))
        }
        return @($names)
    } finally {
        $zip.Dispose()
    }
}

function Get-MarkdownWithoutCode {
    param([Parameter(Mandatory = $true)][string]$Text)
    $withoutFences = [regex]::Replace($Text, '(?s)```.*?```', ' ')
    return [regex]::Replace($withoutFences, '`[^`]*`', ' ')
}

function Convert-ZipRelativeLink {
    param(
        [Parameter(Mandatory = $true)][string]$FromEntry,
        [Parameter(Mandatory = $true)][string]$Href
    )
    $pathOnly = $Href.Split('#')[0].Replace('\', '/').Trim()
    if ([string]::IsNullOrWhiteSpace($pathOnly)) { return $null }
    $base = $FromEntry.Replace('\', '/')
    $dir = ''
    $slash = $base.LastIndexOf('/')
    if ($slash -ge 0) { $dir = $base.Substring(0, $slash) }
    $combined = if ([string]::IsNullOrWhiteSpace($dir)) { $pathOnly } else { ($dir + '/' + $pathOnly) }
    $parts = [Collections.Generic.List[string]]::new()
    foreach ($seg in @($combined.Split([char]'/'))) {
        if ([string]::IsNullOrWhiteSpace($seg) -or $seg -ceq '.') { continue }
        if ($seg -ceq '..') {
            if ($parts.Count -eq 0) { return $null }
            $parts.RemoveAt($parts.Count - 1)
            continue
        }
        [void]$parts.Add($seg)
    }
    return [string]::Join('/', $parts)
}

function Get-ZipMissingMarkdownLinks {
    param([Parameter(Mandatory = $true)][string]$Path)
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in $zip.Entries) {
            [void]$names.Add([string]$entry.FullName.Replace('\', '/'))
        }
        $missing = [Collections.Generic.List[string]]::new()
        $linkCount = 0
        foreach ($entry in $zip.Entries) {
            $name = [string]$entry.FullName.Replace('\', '/')
            if (-not $name.EndsWith('.md', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $reader = New-Object IO.StreamReader($entry.Open())
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $body = Get-MarkdownWithoutCode -Text $text
            foreach ($match in [regex]::Matches($body, '\[[^\]]*\]\(([^)]+)\)')) {
                $target = [string]$match.Groups[1].Value.Trim()
                if ([string]::IsNullOrWhiteSpace($target)) { continue }
                if ($target.StartsWith('#', [StringComparison]::Ordinal)) { continue }
                $lower = $target.ToLowerInvariant()
                if ($lower.StartsWith('http://') -or $lower.StartsWith('https://') -or $lower.StartsWith('mailto:')) { continue }
                $resolved = Convert-ZipRelativeLink -FromEntry $name -Href $target
                $script:assertions += 1
                $linkCount += 1
                if ([string]::IsNullOrWhiteSpace($resolved) -or -not $names.Contains($resolved)) {
                    [void]$missing.Add("$name -> $target")
                }
            }
        }
        return [ordered]@{ missing = @($missing); link_count = [int]$linkCount }
    } finally {
        $zip.Dispose()
    }
}

function New-PackagingFixtureTree {
    param([Parameter(Mandatory = $true)][string]$Root)
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    Write-Utf8File -Path (Join-Path $Root 'README.md') -Text "# fixture`n"
    Write-Utf8File -Path (Join-Path $Root 'LICENSE') -Text "LICENSE`n"
    Write-Utf8File -Path (Join-Path $Root 'CONTRIBUTING.md') -Text "contributing`n"
    Write-Utf8File -Path (Join-Path $Root 'SECURITY.md') -Text "security`n"
    Write-Utf8File -Path (Join-Path $Root 'THIRD-PARTY-NOTICES.md') -Text "notices`n"
    [IO.File]::WriteAllBytes((Join-Path $Root '.gitattributes'), [IO.File]::ReadAllBytes((Join-Path $repoRoot '.gitattributes')))
    Write-Utf8File -Path (Join-Path $Root 'src\core\hello.ps1') -Text "# fixture`n"
    Write-Utf8File -Path (Join-Path $Root 'schemas\example.schema.json') -Text "{`n}`n"
    Write-Utf8File -Path (Join-Path $Root 'docs\example.md') -Text "docs`n"
    Write-Utf8File -Path (Join-Path $Root '.github\workflows\ci.yml') -Text "name: fixture`n"
    Write-Utf8File -Path (Join-Path $Root 'tests\example.ps1') -Text "# test`n"
    Write-Utf8File -Path (Join-Path $Root '.control\secret.json') -Text "{`"secret`":true}`n"
    Write-Utf8File -Path (Join-Path $Root '.git\HEAD') -Text "ref: refs/heads/main`n"
    Write-Utf8File -Path (Join-Path $Root 'logs\app.log') -Text "log`n"
    Write-Utf8File -Path (Join-Path $Root 'receipts\r.json') -Text "{ }`n"
    Write-Utf8File -Path (Join-Path $Root 'dispatches\d.json') -Text "{ }`n"
    Write-Utf8File -Path (Join-Path $Root 'deliveries\out.json') -Text "{ }`n"
    Write-Utf8File -Path (Join-Path $Root 'cache\c.bin') -Text "cache`n"
    Write-Utf8File -Path (Join-Path $Root 'caches\x.bin') -Text "caches`n"
    Write-Utf8File -Path (Join-Path $Root 'state\runtime.json') -Text "{ }`n"
    Write-Utf8File -Path (Join-Path $Root 'node_modules\left-pad\index.js') -Text "module.exports=0`n"
    Write-Utf8File -Path (Join-Path $Root 'src\logs\nested.log') -Text "nested-log`n"
}

try {
    $fixture = Join-Path $testRoot 'fixture'
    New-PackagingFixtureTree -Root $fixture
    $sourceFiles = @(Get-TelephoneRedistributableFiles -SourceRoot $fixture -Kind 'source')
    $releaseFiles = @(Get-TelephoneRedistributableFiles -SourceRoot $fixture -Kind 'release')
    $sourcePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $sourceFiles) { [void]$sourcePaths.Add([string]$row.path) }
    $releasePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $releaseFiles) { [void]$releasePaths.Add([string]$row.path) }
    foreach ($forbidden in @(
        '.control/secret.json',
        '.git/HEAD',
        'logs/app.log',
        'receipts/r.json',
        'dispatches/d.json',
        'deliveries/out.json',
        'cache/c.bin',
        'caches/x.bin',
        'state/runtime.json',
        'node_modules/left-pad/index.js',
        'src/logs/nested.log'
    )) {
        Assert-PackagingTest ($sourcePaths.Contains($forbidden) -eq $false) "Source set included private path $forbidden"
        Assert-PackagingTest ($releasePaths.Contains($forbidden) -eq $false) "Release set included private path $forbidden"
    }
    Assert-PackagingTest ($sourcePaths.Contains('tests/example.ps1')) 'Source set omitted tests/.'
    Assert-PackagingTest ($sourcePaths.Contains('.github/workflows/ci.yml')) 'Source set omitted .github/.'
    Assert-PackagingTest ($releasePaths.Contains('tests/example.ps1') -eq $false) 'Release set included tests/.'
    Assert-PackagingTest ($releasePaths.Contains('.github/workflows/ci.yml') -eq $false) 'Release set included .github/.'
    Assert-PackagingTest ($sourcePaths.Contains('LICENSE')) 'Source set omitted LICENSE.'
    Assert-PackagingTest ($releasePaths.Contains('LICENSE')) 'Release set omitted LICENSE.'
    Assert-PackagingTest ($sourcePaths.Contains('THIRD-PARTY-NOTICES.md')) 'Source set omitted THIRD-PARTY-NOTICES.md.'
    Assert-PackagingTest ($releasePaths.Contains('THIRD-PARTY-NOTICES.md')) 'Release set omitted THIRD-PARTY-NOTICES.md.'
    Assert-PackagingTest ($sourcePaths.Contains('.gitattributes')) 'Source set omitted .gitattributes.'
    Assert-PackagingTest ($releasePaths.Contains('.gitattributes')) 'Release set omitted .gitattributes.'
    $script:packageSetExcludesPrivate = 1

    $src1 = Join-Path $testRoot 'fixture-source-1.zip'
    $src2 = Join-Path $testRoot 'fixture-source-2.zip'
    $srcRun1 = Invoke-PackagingCommand -ScriptName 'New-TelephoneSourceArchive.ps1' -Arguments @('-SourceRoot', $fixture, '-OutputPath', $src1)
    $srcRun2 = Invoke-PackagingCommand -ScriptName 'New-TelephoneSourceArchive.ps1' -Arguments @('-SourceRoot', $fixture, '-OutputPath', $src2)
    Assert-PackagingTest ($srcRun1.exit_code -eq 0 -and $srcRun1.json.ok -eq $true) ('Source archive 1 failed: ' + $srcRun1.stderr + $srcRun1.stdout)
    Assert-PackagingTest ($srcRun2.exit_code -eq 0 -and $srcRun2.json.ok -eq $true) ('Source archive 2 failed: ' + $srcRun2.stderr + $srcRun2.stdout)
    $srcHash1 = Get-FileSha256Hex -Path $src1
    $srcHash2 = Get-FileSha256Hex -Path $src2
    Assert-PackagingTest ($srcHash1 -ceq $srcHash2) 'Source archives over identical inputs were not byte-identical.'
    Assert-PackagingTest ([int64]$srcRun1.json.artifact.bytes -eq [int64]([IO.File]::ReadAllBytes($src1).Length)) 'Source archive identity bytes did not match the file.'
    $script:sourceArchiveDeterministic = 1

    $rel1 = Join-Path $testRoot 'fixture-release-1.zip'
    $rel2 = Join-Path $testRoot 'fixture-release-2.zip'
    $relRun1 = Invoke-PackagingCommand -ScriptName 'New-TelephoneReleaseZip.ps1' -Arguments @('-SourceRoot', $fixture, '-OutputPath', $rel1)
    $relRun2 = Invoke-PackagingCommand -ScriptName 'New-TelephoneReleaseZip.ps1' -Arguments @('-SourceRoot', $fixture, '-OutputPath', $rel2)
    Assert-PackagingTest ($relRun1.exit_code -eq 0 -and $relRun1.json.ok -eq $true) ('Release zip 1 failed: ' + $relRun1.stderr + $relRun1.stdout)
    Assert-PackagingTest ($relRun2.exit_code -eq 0 -and $relRun2.json.ok -eq $true) ('Release zip 2 failed: ' + $relRun2.stderr + $relRun2.stdout)
    Assert-PackagingTest ((Get-FileSha256Hex -Path $rel1) -ceq (Get-FileSha256Hex -Path $rel2)) 'Release ZIPs over identical inputs were not byte-identical.'
    $script:releaseZipDeterministic = 1

    $realSource = Join-Path $testRoot 'real-source.zip'
    $realRelease = Join-Path $testRoot 'real-release.zip'
    $realSrcRun = Invoke-PackagingCommand -ScriptName 'New-TelephoneSourceArchive.ps1' -Arguments @('-SourceRoot', $repoRoot, '-OutputPath', $realSource)
    $realRelRun = Invoke-PackagingCommand -ScriptName 'New-TelephoneReleaseZip.ps1' -Arguments @('-SourceRoot', $repoRoot, '-OutputPath', $realRelease)
    Assert-PackagingTest ($realSrcRun.exit_code -eq 0 -and $realSrcRun.json.ok -eq $true) ('Real source archive failed: ' + $realSrcRun.stderr + $realSrcRun.stdout)
    Assert-PackagingTest ($realRelRun.exit_code -eq 0 -and $realRelRun.json.ok -eq $true) ('Real release zip failed: ' + $realRelRun.stderr + $realRelRun.stdout)
    $realSourceNames = @(Get-ZipEntryNames -Path $realSource)
    $realReleaseNames = @(Get-ZipEntryNames -Path $realRelease)
    $fixtureSourceNames = @(Get-ZipEntryNames -Path $src1)
    $fixtureReleaseNames = @(Get-ZipEntryNames -Path $rel1)
    $sourceHasTests = $false
    $sourceHasGithub = $false
    $releaseHasTests = $false
    $releaseHasGithub = $false
    $privateInSource = $false
    foreach ($name in $realSourceNames) {
        Assert-PackagingTest ($name.Contains('\') -eq $false) "Source zip entry is not POSIX: $name"
        Assert-PackagingTest ([IO.Path]::IsPathRooted($name) -eq $false) "Source zip stored an absolute path: $name"
        if ($name -ceq 'tests' -or $name.StartsWith('tests/', [StringComparison]::Ordinal)) { $sourceHasTests = $true }
        if ($name -ceq '.github' -or $name.StartsWith('.github/', [StringComparison]::Ordinal)) { $sourceHasGithub = $true }
        if (Test-TelephonePackagingExcludedRelative -Relative $name) { $privateInSource = $true }
    }
    foreach ($name in $realReleaseNames) {
        Assert-PackagingTest ($name.Contains('\') -eq $false) "Release zip entry is not POSIX: $name"
        Assert-PackagingTest ([IO.Path]::IsPathRooted($name) -eq $false) "Release zip stored an absolute path: $name"
        if ($name -ceq 'tests' -or $name.StartsWith('tests/', [StringComparison]::Ordinal)) { $releaseHasTests = $true }
        if ($name -ceq '.github' -or $name.StartsWith('.github/', [StringComparison]::Ordinal)) { $releaseHasGithub = $true }
        if (Test-TelephonePackagingExcludedRelative -Relative $name) { throw "Release zip included excluded path $name" }
    }
    Assert-PackagingTest ($sourceHasTests) 'Source archive omitted tests/.'
    Assert-PackagingTest ($sourceHasGithub) 'Source archive omitted .github/.'
    Assert-PackagingTest ($releaseHasTests -eq $false) 'Release ZIP included tests/.'
    Assert-PackagingTest ($releaseHasGithub -eq $false) 'Release ZIP included .github/.'
    Assert-PackagingTest ($privateInSource -eq $false) 'Source archive included an excluded path.'
    Assert-PackagingTest ($fixtureSourceNames -contains 'tests/example.ps1') 'Fixture source archive omitted tests/.'
    Assert-PackagingTest ($fixtureReleaseNames -notcontains 'tests/example.ps1') 'Fixture release ZIP included tests/.'
    Assert-PackagingTest ($fixtureReleaseNames -notcontains '.github/workflows/ci.yml') 'Fixture release ZIP included .github/.'
    $script:releaseZipExcludesTests = 1

    Assert-PackagingTest ($realSourceNames -contains 'LICENSE') 'Source archive omitted LICENSE at root.'
    Assert-PackagingTest ($realReleaseNames -contains 'LICENSE') 'Release ZIP omitted LICENSE at root.'
    Assert-PackagingTest ($fixtureSourceNames -contains 'LICENSE') 'Fixture source archive omitted LICENSE.'
    Assert-PackagingTest ($fixtureReleaseNames -contains 'LICENSE') 'Fixture release ZIP omitted LICENSE.'
    Assert-PackagingTest ($realSourceNames -contains 'THIRD-PARTY-NOTICES.md') 'Source archive omitted THIRD-PARTY-NOTICES.md at root.'
    Assert-PackagingTest ($realReleaseNames -contains 'THIRD-PARTY-NOTICES.md') 'Release ZIP omitted THIRD-PARTY-NOTICES.md at root.'
    foreach ($required in @(
        'src/dashboard/Ensure-TelephoneDashboard.ps1',
        'src/dashboard/Watch-TelephoneDashboard.ps1',
        'src/dashboard/TelephoneDashboard.Reducer.ps1',
        'schemas/dashboard-config.schema.json',
        'schemas/dashboard-projection.schema.json',
        'docs/dashboard.md',
        'docs/examples/dashboard/config.placeholder.json'
    )) {
        Assert-PackagingTest ($realSourceNames -contains $required) "Source archive omitted $required"
        Assert-PackagingTest ($realReleaseNames -contains $required) "Release ZIP omitted $required"
    }
    Assert-PackagingTest ($fixtureSourceNames -contains 'THIRD-PARTY-NOTICES.md') 'Fixture source archive omitted THIRD-PARTY-NOTICES.md.'
    Assert-PackagingTest ($fixtureReleaseNames -contains 'THIRD-PARTY-NOTICES.md') 'Fixture release ZIP omitted THIRD-PARTY-NOTICES.md.'
    Assert-PackagingTest ($realSourceNames -contains '.gitattributes') 'Source archive omitted .gitattributes at root.'
    Assert-PackagingTest ($realReleaseNames -contains '.gitattributes') 'Release ZIP omitted .gitattributes at root.'
    Assert-PackagingTest ($fixtureSourceNames -contains '.gitattributes') 'Fixture source archive omitted .gitattributes.'
    Assert-PackagingTest ($fixtureReleaseNames -contains '.gitattributes') 'Fixture release ZIP omitted .gitattributes.'
    $script:archivesContainLicense = 1

    $manifestPath = Join-Path $repoRoot 'release-manifest.json'
    Assert-PackagingTest ([IO.File]::Exists($manifestPath)) 'release-manifest.json is missing.'
    $manifestText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($manifestPath))
    $manifest = $manifestText | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
    $treeFiles = @(Get-TelephoneRedistributableFiles -SourceRoot $repoRoot -Kind 'source')
    $manifestMap = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($row in @($manifest.files)) {
        $p = [string]$row.path
        Assert-PackagingTest ($manifestMap.ContainsKey($p) -eq $false) "Duplicate manifest path $p"
        $manifestMap[$p] = $row
        $full = [IO.Path]::GetFullPath((Join-Path $repoRoot ($p.Replace('/', '\'))))
        Assert-PackagingTest ([IO.File]::Exists($full)) "Manifest path missing from tree: $p"
        $id = Get-TelephonePackagingFileBytesAndHash -Path $full
        Assert-PackagingTest ([int64]$row.bytes -eq [int64]$id.bytes) "Manifest bytes mismatch for $p"
        Assert-PackagingTest ([string]$row.sha256 -ceq [string]$id.sha256) "Manifest sha256 mismatch for $p"
        Assert-PackagingTest ($p -cne 'release-manifest.json') 'Manifest listed itself in files.'
        Assert-PackagingTest ($p.Contains('\') -eq $false) "Manifest path is not POSIX: $p"
        Assert-PackagingTest ([IO.Path]::IsPathRooted($p) -eq $false) "Manifest path is absolute: $p"
    }
    foreach ($row in $treeFiles) {
        $p = [string]$row.path
        Assert-PackagingTest ($manifestMap.ContainsKey($p)) "Redistributable file missing from manifest: $p"
        Assert-PackagingTest ([int64]$manifestMap[$p].bytes -eq [int64]$row.bytes) "Manifest bytes drifted from resolver for $p"
        Assert-PackagingTest ([string]$manifestMap[$p].sha256 -ceq [string]$row.sha256) "Manifest sha256 drifted from resolver for $p"
    }
    Assert-PackagingTest ([int]$manifest.counts.files -eq $manifestMap.Count) 'Manifest counts.files does not match files length.'
    Assert-PackagingTest ($manifestMap.ContainsKey('release-manifest.json') -eq $false) 'Manifest files listed release-manifest.json.'
    $gaRows = @($manifest.files | Where-Object { [string]$_.path -ceq '.gitattributes' })
    Assert-PackagingTest ($gaRows.Count -eq 1) 'Manifest did not contain exactly one .gitattributes row.'
    $policyPath = Join-Path $repoRoot '.gitattributes'
    Assert-PackagingTest ([IO.File]::Exists($policyPath)) 'Product .gitattributes is missing.'
    $policyId = Get-TelephonePackagingFileBytesAndHash -Path $policyPath
    Assert-PackagingTest ([int64]$gaRows[0].bytes -eq [int64]$policyId.bytes) 'Manifest .gitattributes bytes did not match the policy file.'
    Assert-PackagingTest ([string]$gaRows[0].sha256 -ceq [string]$policyId.sha256) 'Manifest .gitattributes sha256 did not match the policy file.'
    $script:manifestMatchesTree = 1

    $man1 = Join-Path $testRoot 'manifest-1.json'
    $man2 = Join-Path $testRoot 'manifest-2.json'
    $manRun1 = Invoke-PackagingCommand -ScriptName 'New-TelephoneReleaseManifest.ps1' -Arguments @('-SourceRoot', $repoRoot, '-OutputPath', $man1, '-Force')
    $manRun2 = Invoke-PackagingCommand -ScriptName 'New-TelephoneReleaseManifest.ps1' -Arguments @('-SourceRoot', $repoRoot, '-OutputPath', $man2, '-Force')
    Assert-PackagingTest ($manRun1.exit_code -eq 0 -and $manRun1.json.ok -eq $true) ('Manifest regen 1 failed: ' + $manRun1.stderr + $manRun1.stdout)
    Assert-PackagingTest ($manRun2.exit_code -eq 0 -and $manRun2.json.ok -eq $true) ('Manifest regen 2 failed: ' + $manRun2.stderr + $manRun2.stdout)
    $manHash1 = Get-FileSha256Hex -Path $man1
    $manHash2 = Get-FileSha256Hex -Path $man2
    $manHashCommitted = Get-FileSha256Hex -Path $manifestPath
    Assert-PackagingTest ($manHash1 -ceq $manHash2) 'Regenerated manifests were not byte-identical.'
    Assert-PackagingTest ($manHash1 -ceq $manHashCommitted) 'Regenerated manifest was not byte-identical to the committed file.'
    $script:manifestDeterministic = 1

    $catalogPath = Join-Path $repoRoot 'src\catalog\routes.json'
    $catalogText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($catalogPath))
    $catalog = $catalogText | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
    $catalogIds = @($catalog.routes | ForEach-Object { [string]$_.route_id })
    $manifestIds = @($manifest.route_ids)
    Assert-PackagingTest ([int]$manifest.denominator -eq 8) 'Manifest denominator is not 8.'
    Assert-PackagingTest ($manifestIds.Count -eq 8) 'Manifest route_ids count is not 8.'
    Assert-PackagingTest ($catalogIds.Count -eq 8) 'Catalog route count is not 8.'
    for ($i = 0; $i -lt 8; $i++) {
        Assert-PackagingTest ([string]$manifestIds[$i] -ceq [string]$catalogIds[$i]) "Manifest route_id at $i does not match the catalog."
    }
    $script:manifestRoutesEight = 1

    $schemaPath = Get-TelephoneSchemaPath -Name 'release-manifest'
    $expectedSchema = [IO.Path]::GetFullPath((Join-Path $repoRoot 'schemas\release-manifest.schema.json'))
    Assert-PackagingTest ([IO.Path]::GetFullPath($schemaPath) -ceq $expectedSchema) 'Get-TelephoneSchemaPath did not return the shipped release-manifest schema.'
    Assert-TelephoneJsonSchema -JsonText $manifestText -SchemaName 'release-manifest' -Label 'release-manifest.json'
    $readBack = Read-TelephoneJson -Path $manifestPath -SchemaName 'release-manifest'
    Assert-PackagingTest ($null -ne $readBack.value) 'Read-TelephoneJson failed to read release-manifest.json.'
    $script:manifestSchemaValid = 1

    $created = @(
        'src/packaging/TelephonePackaging.Common.ps1',
        'src/packaging/New-TelephoneSourceArchive.ps1',
        'src/packaging/New-TelephoneReleaseZip.ps1',
        'src/packaging/New-TelephoneReleaseManifest.ps1',
        'schemas/release-manifest.schema.json',
        'release-manifest.json',
        '.gitattributes',
        'THIRD-PARTY-NOTICES.md',
        'docs/redistribution-audit.md',
        'docs/packaging.md',
        'docs/dashboard.md',
        'src/dashboard/Ensure-TelephoneDashboard.ps1',
        'tests/packaging/test_packaging.ps1',
        'README.md',
        'src/core/TelephoneLine.Common.ps1',
        'tests/contracts/test_contracts.ps1',
        'tests/Invoke-OfflineTests.ps1'
    )
    $usersWin = 'C:' + [char]92 + 'Users' + [char]92
    $usersUnix = '/' + 'Users' + '/'
    $privateRepoMarker = 'private' + '-' + 'repository' + '-' + 'marker'
    $internalOperatorMarker = 'internal' + '-' + 'operator' + '-' + 'alias'
    $unpublishedProjectMarker = 'unpublished' + '-' + 'project' + '-' + 'marker'
    $privacyPatterns = @(
        @{ id = 'users_prefix'; re = [regex][regex]::Escape($usersWin) },
        @{ id = 'unix_users'; re = [regex][regex]::Escape($usersUnix) },
        @{ id = 'private_repo_marker'; re = [regex][regex]::Escape($privateRepoMarker) },
        @{ id = 'internal_operator_marker'; re = [regex][regex]::Escape($internalOperatorMarker) },
        @{ id = 'unpublished_project_marker'; re = [regex][regex]::Escape($unpublishedProjectMarker) },
        @{ id = 'openai_sk'; re = [regex]('sk' + '-[A-Za-z0-9_-]{16,}') },
        @{ id = 'xai_key_value'; re = [regex]('\bxai' + '-[A-Za-z0-9]{20,}\b') },
        @{ id = 'bearer'; re = [regex]('Bearer' + '\s+[A-Za-z0-9._\-+/=]{20,}') },
        @{ id = 'jwt'; re = [regex]('eyJ' + '[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+') },
        @{ id = 'email'; re = [regex]('[A-Za-z0-9._%+-]+' + [char]64 + '[A-Za-z0-9.-]+\.[A-Za-z]{2,}') }
    )
    foreach ($rel in $created) {
        $full = Join-Path $repoRoot ($rel.Replace('/', '\'))
        Assert-PackagingTest ([IO.File]::Exists($full)) "Package file missing: $rel"
        $text = [IO.File]::ReadAllText($full)
        foreach ($pattern in $privacyPatterns) {
            Assert-PackagingTest ($pattern.re.IsMatch($text) -eq $false) ("Privacy hit " + [string]$pattern.id + ' ' + $rel)
        }
    }
    foreach ($name in ($realSourceNames + $realReleaseNames + $fixtureSourceNames + $fixtureReleaseNames)) {
        foreach ($pattern in $privacyPatterns) {
            Assert-PackagingTest ($pattern.re.IsMatch($name) -eq $false) ("Privacy hit in zip entry " + [string]$pattern.id + ' ' + $name)
        }
    }
    foreach ($row in @($manifest.files)) {
        $p = [string]$row.path
        foreach ($pattern in $privacyPatterns) {
            Assert-PackagingTest ($pattern.re.IsMatch($p) -eq $false) ("Privacy hit in manifest path " + [string]$pattern.id + ' ' + $p)
        }
    }
    $script:redistributionPrivacyClean = 1

    $noticesPath = Join-Path $repoRoot 'THIRD-PARTY-NOTICES.md'
    Assert-PackagingTest ([IO.File]::Exists($noticesPath)) 'THIRD-PARTY-NOTICES.md is missing.'
    $notices = [IO.File]::ReadAllText($noticesPath)
    Assert-PackagingTest ($notices.Contains('vendors no third-party source')) 'THIRD-PARTY-NOTICES.md does not state that nothing is vendored.'
    foreach ($match in [regex]::Matches($notices, '`([A-Za-z0-9._/-]+)`')) {
        $named = [string]$match.Groups[1].Value
        $isRepoPath = $named.StartsWith('src/', [StringComparison]::Ordinal) -or
            $named.StartsWith('docs/', [StringComparison]::Ordinal) -or
            $named.StartsWith('schemas/', [StringComparison]::Ordinal) -or
            $named.StartsWith('tests/', [StringComparison]::Ordinal) -or
            $named.StartsWith('.github/', [StringComparison]::Ordinal)
        if (-not $isRepoPath) { continue }
        $full = [IO.Path]::GetFullPath((Join-Path $repoRoot ($named.TrimEnd('/').Replace('/', '\'))))
        Assert-PackagingTest (([IO.File]::Exists($full) -or [IO.Directory]::Exists($full))) "Named third-party path missing: $named"
    }
    foreach ($match in [regex]::Matches($notices, '\[[^\]]+\]\((?!https?:)(?!mailto:)([^)#]+)(?:#[^)]*)?\)')) {
        $named = [string]$match.Groups[1].Value.Replace('\', '/')
        if ($named.StartsWith('../', [StringComparison]::Ordinal)) { continue }
        $full = [IO.Path]::GetFullPath((Join-Path $repoRoot ($named.Replace('/', '\'))))
        Assert-PackagingTest ([IO.File]::Exists($full)) "Named third-party link missing: $named"
    }
    $vendorNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('node_modules', 'vendor', 'third_party', 'third-party', 'bower_components')) {
        [void]$vendorNames.Add($name)
    }
    $overlayRoots = @(
        (Join-Path $repoRoot 'docs'),
        (Join-Path $repoRoot 'schemas'),
        (Join-Path $repoRoot 'src'),
        (Join-Path $repoRoot 'tests'),
        (Join-Path $repoRoot '.github')
    )
    foreach ($root in $overlayRoots) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Recurse -Directory -Force)) {
            Assert-PackagingTest ($vendorNames.Contains($dir.Name) -eq $false) ("Vendored directory present: " + $dir.FullName.Substring($repoRoot.Length).TrimStart('\').Replace('\', '/'))
        }
    }
    $pluginPackage = Join-Path $repoRoot 'src\adapters\deepsea-common\dsh-plugin\package.json'
    Assert-PackagingTest ([IO.File]::Exists($pluginPackage)) 'DeepSea plugin package.json is missing.'
    $plugin = ([Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($pluginPackage))) | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
    foreach ($key in @('dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies', 'bundledDependencies')) {
        Assert-PackagingTest ($plugin.Contains($key) -eq $false) "DeepSea plugin package.json declares $key"
    }
    $pluginRoot = Join-Path $repoRoot 'src\adapters\deepsea-common\dsh-plugin'
    foreach ($name in @('subscription-store.mjs', 'subscription-llm.mjs', 'llm-plugin.mjs', 'login-subscription.mjs', 'resolve-modules.mjs')) {
        Assert-PackagingTest ([IO.File]::Exists((Join-Path $pluginRoot $name))) "DeepSea plugin omitted $name."
    }
    foreach ($name in @('process-only-store.mjs', 'pi-oauth-llm.mjs')) {
        Assert-PackagingTest (-not [IO.File]::Exists((Join-Path $pluginRoot $name))) "DeepSea plugin still ships $name."
    }
    $resolveText = [IO.File]::ReadAllText((Join-Path $pluginRoot 'resolve-modules.mjs'))
    Assert-PackagingTest ($resolveText.Contains('pi-coding-agent') -eq $false) 'DeepSea plugin resolve-modules still loads PI coding-agent.'
    Assert-PackagingTest ($resolveText.Contains('process.cwd()') -eq $false) 'DeepSea plugin resolve-modules still walks from the current working directory.'
    $script:thirdPartyInventoryAccurate = 1

    foreach ($zipPath in @($realSource, $realRelease, $src1, $rel1)) {
        $linkReport = Get-ZipMissingMarkdownLinks -Path $zipPath
        Assert-PackagingTest ($linkReport.missing.Count -eq 0) ("Missing local Markdown links in " + [IO.Path]::GetFileName($zipPath) + ': ' + (@($linkReport.missing) -join '; '))
    }
    $script:archivesMarkdownLinksResolved = 1

    [ordered]@{
        success = $true
        assertions = $assertions
        package_set_excludes_private = $packageSetExcludesPrivate
        source_archive_deterministic = $sourceArchiveDeterministic
        release_zip_deterministic = $releaseZipDeterministic
        release_zip_excludes_tests = $releaseZipExcludesTests
        archives_contain_license = $archivesContainLicense
        manifest_matches_tree = $manifestMatchesTree
        manifest_deterministic = $manifestDeterministic
        manifest_routes_eight = $manifestRoutesEight
        manifest_schema_valid = $manifestSchemaValid
        redistribution_privacy_clean = $redistributionPrivacyClean
        third_party_inventory_accurate = $thirdPartyInventoryAccurate
        archives_markdown_links_resolved = $archivesMarkdownLinksResolved
    } | ConvertTo-Json -Compress
} catch {
    [ordered]@{
        success = $false
        error = [string]$_.Exception.Message
        assertions = $assertions
        package_set_excludes_private = $packageSetExcludesPrivate
        source_archive_deterministic = $sourceArchiveDeterministic
        release_zip_deterministic = $releaseZipDeterministic
        release_zip_excludes_tests = $releaseZipExcludesTests
        archives_contain_license = $archivesContainLicense
        manifest_matches_tree = $manifestMatchesTree
        manifest_deterministic = $manifestDeterministic
        manifest_routes_eight = $manifestRoutesEight
        manifest_schema_valid = $manifestSchemaValid
        redistribution_privacy_clean = $redistributionPrivacyClean
        third_party_inventory_accurate = $thirdPartyInventoryAccurate
        archives_markdown_links_resolved = $archivesMarkdownLinksResolved
    } | ConvertTo-Json -Compress
    exit 1
} finally {
    if ([IO.Directory]::Exists($testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# SPDX-License-Identifier: MPL-2.0
# Publish the bundled cockpit runtime into src/cockpit/runtime/win-x64.
# Maps local source paths to a generic prefix so binaries do not embed this machine.
# Recursive clean is only allowed for that owned runtime folder. A custom
# -OutputPath that already has files, resolves inside the source tree, or
# uses a reparse/alias is refused before any delete or publish.
[CmdletBinding()]
param(
    [string]$SdkCommand,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $here 'runtime\win-x64'
}
$csproj = Join-Path $here 'PascalCockpit.App\PascalCockpit.App.csproj'
if (-not [IO.File]::Exists($csproj)) { throw 'PascalCockpit.App.csproj is missing.' }

$dotnet = $SdkCommand
if ([string]::IsNullOrWhiteSpace($dotnet)) {
    $dotnet = [string](Get-Command dotnet -ErrorAction SilentlyContinue).Source
}
if ([string]::IsNullOrWhiteSpace($dotnet) -or -not [IO.File]::Exists($dotnet)) {
    throw 'dotnet SDK is required to rebuild the cockpit runtime.'
}

$srcMap = ($here.TrimEnd('\') + '=/_/src/cockpit')
$ownedRuntime = [IO.Path]::GetFullPath((Join-Path $here 'runtime\win-x64')).TrimEnd('\')
$outFull = [IO.Path]::GetFullPath($OutputPath).TrimEnd('\')

function Test-TelephoneCockpitReparseInChain {
    param([Parameter(Mandatory = $true)][string]$Path)
    $probe = $Path
    while (-not [string]::IsNullOrWhiteSpace($probe)) {
        if ([IO.Directory]::Exists($probe) -or [IO.File]::Exists($probe)) {
            $item = Get-Item -LiteralPath $probe -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'OUTPUT_REPARSE_REFUSED: output path involves a reparse point or alias.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($probe)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { break }
        $probe = $parent
    }
}

function Test-TelephoneCockpitPathEquals {
    param([string]$Left, [string]$Right)
    return [string]::Equals($Left.TrimEnd('\'), $Right.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}

function Test-TelephoneCockpitPathUnder {
    param([string]$Path, [string]$Root)
    $p = $Path.TrimEnd('\') + '\'
    $r = $Root.TrimEnd('\') + '\'
    return $p.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)
}

Test-TelephoneCockpitReparseInChain -Path $outFull
$sourceRoot = [IO.Path]::GetFullPath($here).TrimEnd('\')
$isOwnedRuntime = Test-TelephoneCockpitPathEquals -Left $outFull -Right $ownedRuntime
if (-not $isOwnedRuntime) {
    if (Test-TelephoneCockpitPathUnder -Path $outFull -Root $sourceRoot) {
        throw 'OUTPUT_INSIDE_SOURCE: custom output resolves inside the cockpit source tree.'
    }
    if ([IO.Directory]::Exists($outFull)) {
        $existing = @(Get-ChildItem -LiteralPath $outFull -Force)
        if ($existing.Count -gt 0) {
            throw 'OUTPUT_NOT_EMPTY: refusing to clean a non-owned output directory that already has files.'
        }
    }
} elseif ([IO.Directory]::Exists($outFull)) {
    Get-ChildItem -LiteralPath $outFull -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
}
[IO.Directory]::CreateDirectory($outFull) | Out-Null

$publishArgs = @(
    'publish', $csproj,
    '-c', 'Release',
    '-r', 'win-x64',
    '-o', $outFull,
    '--self-contained', 'true',
    '-p:PublishSingleFile=false',
    '-p:DebugType=none',
    '-p:DebugSymbols=false',
    '-p:Deterministic=true',
    '-p:ContinuousIntegrationBuild=true',
    '-p:SatelliteResourceLanguages=en',
    ('-p:PathMap=' + $srcMap)
)
& $dotnet @publishArgs
if ($LASTEXITCODE -ne 0) { throw 'Cockpit publish failed.' }

foreach ($junk in @(
    'createdump.exe',
    'PascalCockpit.App.pdb',
    'PascalCockpit.Views.pdb',
    'PascalCockpit.Collection.pdb',
    'PascalCockpit.Contracts.pdb',
    'PascalCockpit.Normalization.pdb',
    'PascalCockpit.Projection.pdb'
)) {
    $p = Join-Path $outFull $junk
    if ([IO.File]::Exists($p)) { Remove-Item -LiteralPath $p -Force }
}
Get-ChildItem -LiteralPath $outFull -Recurse -File -Filter '*.pdb' | Remove-Item -Force
$configCopy = Join-Path $outFull 'config'
if ([IO.Directory]::Exists($configCopy)) { Remove-Item -LiteralPath $configCopy -Recurse -Force }

$exe = Join-Path $outFull 'PascalCockpit.App.exe'
if (-not [IO.File]::Exists($exe)) { throw 'Publish did not produce PascalCockpit.App.exe.' }
Write-Host ('Published ' + $outFull)

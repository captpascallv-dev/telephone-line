# SPDX-License-Identifier: MPL-2.0
# Open the bundled cockpit from this Telephone Line tree. Does not start,
# stop, or replace the bundled dashboard, supervisor, or shared Codex host.
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$StateRoot,
    [string]$RegistryPath,
    [string]$DataDir,
    [string]$InstanceName,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The bundled cockpit supports Windows only.' }

$here = $PSScriptRoot
$exe = Join-Path $here 'runtime\win-x64\PascalCockpit.App.exe'
if (-not [IO.File]::Exists($exe)) {
    throw 'Cockpit runtime is missing. Expected src/cockpit/runtime/win-x64/PascalCockpit.App.exe.'
}

$shippedDefault = Join-Path $here 'config\default.json'
if (-not [IO.File]::Exists($shippedDefault)) {
    throw 'Shipped cockpit default.json is missing.'
}

if ([string]::IsNullOrWhiteSpace($InstanceName)) {
    $InstanceName = 'PascalCockpit.App.SingleInstance.bundled'
}
$env:PASCAL_COCKPIT_INSTANCE_NAME = $InstanceName

if ([string]::IsNullOrWhiteSpace($DataDir)) {
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $DataDir = Join-Path $local 'TelephoneLine\cockpit-data'
}
[IO.Directory]::CreateDirectory($DataDir) | Out-Null
$env:PASCAL_COCKPIT_DATA_DIR = [IO.Path]::GetFullPath($DataDir)

function Resolve-OptionalPath {
    param([string]$Path, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($full) -and -not [IO.Directory]::Exists($full)) {
        throw "$Label not found: $Path"
    }
    return $full
}

$resolvedConfig = $null
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $resolvedConfig = Resolve-OptionalPath -Path $ConfigPath -Label 'ConfigPath'
} elseif (-not [string]::IsNullOrWhiteSpace($env:PASCAL_COCKPIT_CONFIG)) {
    $resolvedConfig = Resolve-OptionalPath -Path $env:PASCAL_COCKPIT_CONFIG -Label 'PASCAL_COCKPIT_CONFIG'
} else {
    $registryPaths = [Collections.Generic.List[string]]::new()
    $extraPaths = [Collections.Generic.List[string]]::new()
    $reg = Resolve-OptionalPath -Path $RegistryPath -Label 'RegistryPath'
    if ($reg) { [void]$registryPaths.Add($reg) }
    $state = $StateRoot
    if ([string]::IsNullOrWhiteSpace($state)) { $state = [string]$env:TELEPHONE_LINE_STATE_ROOT }
    if (-not [string]::IsNullOrWhiteSpace($state)) {
        $resolvedState = Resolve-OptionalPath -Path $state -Label 'StateRoot'
        if ($resolvedState) { [void]$extraPaths.Add($resolvedState) }
    }
    $generated = Join-Path $env:PASCAL_COCKPIT_DATA_DIR 'launch-config.json'
    $obj = [ordered]@{
        registry_paths = @($registryPaths)
        additional_source_paths = @($extraPaths)
        refresh_seconds = 15
        max_file_bytes = 1048576
        max_files_per_refresh = 512
        read_only = $true
        allow_network = $false
        send_messages_automatically = $false
    }
    $json = (($obj | ConvertTo-Json -Depth 6) + "`n")
    [IO.File]::WriteAllText($generated, $json, [Text.UTF8Encoding]::new($false))
    if ($registryPaths.Count -eq 0 -and $extraPaths.Count -eq 0) {
        $resolvedConfig = $shippedDefault
    } else {
        $resolvedConfig = $generated
    }
}

$env:PASCAL_COCKPIT_CONFIG = $resolvedConfig
$argList = @('--config', $resolvedConfig)
$proc = Start-Process -FilePath $exe -WorkingDirectory ([IO.Path]::GetDirectoryName($exe)) -ArgumentList $argList -PassThru
Write-Host ('pid=' + $proc.Id)
if ($PassThru) { return $proc }

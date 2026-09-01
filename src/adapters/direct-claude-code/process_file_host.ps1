# SPDX-License-Identifier: MPL-2.0
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -Depth 20
if ([string]::IsNullOrWhiteSpace([string]$config.executable)) { throw 'Host executable is missing.' }
if (-not [IO.File]::Exists([string]$config.executable)) { throw 'Host executable does not exist.' }
if (-not [IO.Directory]::Exists([string]$config.working_directory)) { throw 'Host working directory does not exist.' }

$stdoutPath = [IO.Path]::GetFullPath([string]$config.stdout_path)
$stderrPath = [IO.Path]::GetFullPath([string]$config.stderr_path)
foreach ($path in @($stdoutPath, $stderrPath)) {
    $parent = [IO.Path]::GetDirectoryName($path)
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
}

$arguments = @($config.arguments | ForEach-Object { [string]$_ })
Push-Location -LiteralPath ([string]$config.working_directory)
try {
    & ([string]$config.executable) @arguments 1> $stdoutPath 2> $stderrPath
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
} finally {
    Pop-Location
}
exit $code

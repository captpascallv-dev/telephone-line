# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CounterPath,
    [ValidateRange(0, 30000)][int]$DelayMilliseconds = 0,
    [string]$FinalText = 'MOCK_ROUTE_DONE',
    [int]$ExitCode = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($DelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $DelayMilliseconds }
$parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($CounterPath))
if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::AppendAllText($CounterPath, "1`n", [Text.UTF8Encoding]::new($false))
[ordered]@{ success = ($ExitCode -eq 0); final_text = $FinalText } | ConvertTo-Json -Compress
exit $ExitCode

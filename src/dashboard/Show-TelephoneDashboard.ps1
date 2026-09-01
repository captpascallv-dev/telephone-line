# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$StateRoot,
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TelephoneDashboard.Common.ps1')
. (Join-Path $PSScriptRoot 'TelephoneDashboard.Projection.ps1')

if ([string]::IsNullOrWhiteSpace($StateRoot)) { $StateRoot = Get-TelephoneDashboardStateRoot }
$paths = Get-TelephoneDashboardPaths -StateRoot $StateRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = [string]$paths.config }
$projection = Get-TelephoneDashboardProjection -ConfigPath $ConfigPath
Write-Output (Format-TelephoneDashboardSummary -Projection $projection).TrimEnd()
Write-Output (($projection | ConvertTo-Json -Depth 16))

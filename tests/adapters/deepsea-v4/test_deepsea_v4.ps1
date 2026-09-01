# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')
& (Join-Path $repoRoot 'tests\adapters\Invoke-DeepSeaRouteContract.ps1') -TestRoot $TestRoot -RouteId 'deepsea-v4' -AdapterDir 'deepsea-v4' -EntrypointName 'Invoke-DeepSeaV4Headless.ps1'
exit 0

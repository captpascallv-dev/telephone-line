# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')
& (Join-Path $repoRoot 'tests\adapters\Invoke-DeepSeaRouteContract.ps1') -TestRoot $TestRoot -RouteId 'deepsea-codex-cli' -AdapterDir 'deepsea-codex-cli' -EntrypointName 'Invoke-DeepSeaCodexCli.ps1'
exit 0

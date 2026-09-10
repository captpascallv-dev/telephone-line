# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ProofPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DirectCursor.Common.ps1')
Register-DirectCursorMigrationContinuation -ProofPath $ProofPath | ConvertTo-Json -Depth 16

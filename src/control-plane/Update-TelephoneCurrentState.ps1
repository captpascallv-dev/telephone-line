# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ManifestFile)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TelephoneControlPlane.Common.ps1')

$result = Update-TelephoneControlPlaneState -ManifestFile $ManifestFile
[ordered]@{
    updated = [bool]$result.changed
    current_state = $result.current_identity
    continuation_capsule = $result.capsule_identity
    history_index = $result.history_identity
    projection_version = [int]$result.current.projection_version
    overall_state = [string]$result.current.overall_state
    requires_pascal = [bool]$result.current.requires_pascal
    terminal = [bool]$result.current.terminal
    project_judgment = $false
} | ConvertTo-Json -Depth 16

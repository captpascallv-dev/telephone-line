# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$CodexCommand,
    [string]$OutputPath,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexAppServerLead.Common.ps1')

try {
    $result = Invoke-CodexAppServerBindProfile -CodexCommand $CodexCommand -OutputPath $OutputPath -Force:$Force
    Write-CodexAppServerStdoutJson -Value ([ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-profile-result-v1'
        started = $false
        profile = $result.profile
        identity = $result.identity
        residue = [bool]$result.residue
    })
    exit 0
} catch {
    $failure = Get-CodexAppServerPublicFailure -Message ([string]$_.Exception.Message)
    Write-CodexAppServerStdoutJson -Value ([ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-profile-result-v1'
        started = $false
        error = [string]$failure.message
        code = [string]$failure.code
        residue = $false
    })
    exit 2
}

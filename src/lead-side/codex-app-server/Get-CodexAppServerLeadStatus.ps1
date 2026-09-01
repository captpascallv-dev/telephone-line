# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$StateRoot,
    [string]$RunId,
    [string]$SourcesPath,
    [string]$TelephoneStateRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexAppServerLead.Common.ps1')

try {
    if ([string]::IsNullOrWhiteSpace($SourcesPath) -and ([string]::IsNullOrWhiteSpace($StateRoot) -or [string]::IsNullOrWhiteSpace($RunId))) {
        Throw-CodexAppServerPublic -Code 'STATUS_SOURCES_INVALID'
    }
    if (-not [string]::IsNullOrWhiteSpace($RunId)) { Assert-CodexAppServerRunId -RunId $RunId }
    $result = Get-CodexAppServerStatusCore -StateRoot $StateRoot -RunId $RunId -SourcesPath $SourcesPath -TelephoneStateRoot $TelephoneStateRoot
    Write-CodexAppServerStdoutJson -Value $result
    exit 0
} catch {
    $failure = Get-CodexAppServerPublicFailure -Message ([string]$_.Exception.Message)
    Write-CodexAppServerStdoutJson -Value ([ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-status-result-v1'
        started = $false
        mutated = $false
        error = [string]$failure.message
        items = @()
    })
    exit 2
}

# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorktreePath,
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [Parameter(Mandatory = $true)][string]$ResumeSessionId,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [string]$CodexCommand,
    [string]$ProfilePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexAppServerLead.Common.ps1')

try {
    $result = Invoke-CodexAppServerWakeCore `
        -WorktreePath $WorktreePath `
        -PromptFile $PromptFile `
        -ResumeSessionId $ResumeSessionId `
        -RunId $RunId `
        -StateRoot $StateRoot `
        -CodexCommand $CodexCommand `
        -ProfilePath $ProfilePath
    if ($null -eq $result) { exit 2 }
    Write-CodexAppServerStdoutJson -Value $result
    exit 0
} catch {
    $failure = Get-CodexAppServerPublicFailure -Message ([string]$_.Exception.Message)
    Write-CodexAppServerStdoutJson -Value ([ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-wake-result-v1'
        started = $false
        existing = $false
        state = 'failed'
        error = [string]$failure.message
        code = [string]$failure.code
        fallback_required = [string]$failure.fallback_required
    })
    exit 2
}

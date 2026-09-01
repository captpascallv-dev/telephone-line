# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorktreePath,
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [string]$ResumeSessionId = '',
    [switch]$CreateNewThread,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [string]$CodexCommand,
    [string]$ProfilePath,
    [string]$BindingOutputPath,
    [switch]$Watchdog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexAppServerLead.Common.ps1')

try {
    if ($CreateNewThread -and -not [string]::IsNullOrWhiteSpace($ResumeSessionId)) {
        throw 'CreateNewThread refuses an existing session id.'
    }
    if (-not $CreateNewThread -and [string]::IsNullOrWhiteSpace($ResumeSessionId)) {
        throw 'ResumeSessionId must be the exact Codex thread id.'
    }
    if ($Watchdog) {
        $null = Invoke-CodexAppServerCallbackWatchdogCore `
            -WorktreePath $WorktreePath `
            -PromptFile $PromptFile `
            -ResumeSessionId $ResumeSessionId `
            -RunId $RunId `
            -StateRoot $StateRoot `
            -CodexCommand $CodexCommand `
            -ProfilePath $ProfilePath
        exit 0
    }
    $result = Invoke-CodexAppServerWorkerCore `
        -WorktreePath $WorktreePath `
        -PromptFile $PromptFile `
        -ResumeSessionId $ResumeSessionId `
        -RunId $RunId `
        -StateRoot $StateRoot `
        -CodexCommand $CodexCommand `
        -ProfilePath $ProfilePath `
        -BindingOutputPath $BindingOutputPath
    if ($null -eq $result -or ($result -is [Collections.IDictionary] -and $result.Contains('started') -and [bool]$result.started -eq $false)) {
        exit 2
    }
    exit 0
} catch {
    exit 2
}

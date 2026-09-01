# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorktreePath,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$BindingOutputPath,
    [ValidateSet('app-server', 'cli')][string]$CallbackTransport = 'app-server',
    [string]$CodexCommand,
    [string]$ResumeSessionId,
    [string]$CliLauncher,
    [string[]]$CliLauncherArguments,
    [string]$ProfilePath,
    [string]$PromptFile,
    [string]$RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexAppServerLead.Common.ps1')

try {
    $result = Invoke-CodexAppServerBuilderCore `
        -WorktreePath $WorktreePath `
        -StateRoot $StateRoot `
        -BindingOutputPath $BindingOutputPath `
        -CallbackTransport $CallbackTransport `
        -CodexCommand $CodexCommand `
        -ResumeSessionId $ResumeSessionId `
        -CliLauncher $CliLauncher `
        -CliLauncherArguments $CliLauncherArguments `
        -ProfilePath $ProfilePath `
        -PromptFile $PromptFile `
        -RunId $RunId
    Write-CodexAppServerStdoutJson -Value $result
    exit 0
} catch {
    $message = [string]$_.Exception.Message
    $failure = Get-CodexAppServerPublicFailure -Message $message
    Write-CodexAppServerStdoutJson -Value ([ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-binding-result-v1'
        callback_transport = $CallbackTransport
        started = $false
        thread_id = ''
        error = [string]$failure.message
        fallback_required = [string]$failure.fallback_required
    })
    exit 2
}

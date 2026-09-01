# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LeadRunRoot,
    [Parameter(Mandatory = $true)][string]$LeadWorktree,
    [Parameter(Mandatory = $true)][string]$LeadLauncher,
    [string[]]$LeadLauncherArguments,
    [string]$SessionId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$LineJobId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$ExecutorJobId,
    [Parameter(Mandatory = $true)][string]$TelephoneLineStateRoot,
    [Parameter(Mandatory = $true)][string]$DirectGrokStateRoot,
    [Parameter(Mandatory = $true)][string]$WorkspacePath,
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [Parameter(Mandatory = $true)][string]$BindingOutputPath,
    [Parameter(Mandatory = $true)][string]$RequestOutputPath,
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string]$Stage,
    [Parameter(Mandatory = $true)][string]$Summary,
    [ValidateSet('execution', 'review')][string]$Role = 'execution',
    [string]$Route = 'direct-grok-cli'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CursorExternalLead.Common.ps1')

$prepared = Get-CursorExternalPreparedDispatch `
    -LeadRunRoot $LeadRunRoot `
    -LeadWorktree $LeadWorktree `
    -LeadLauncher $LeadLauncher `
    -LeadLauncherArguments $LeadLauncherArguments `
    -SessionId $SessionId `
    -LineJobId $LineJobId `
    -ExecutorJobId $ExecutorJobId `
    -TelephoneLineStateRoot $TelephoneLineStateRoot `
    -DirectGrokStateRoot $DirectGrokStateRoot `
    -WorkspacePath $WorkspacePath `
    -PromptFile $PromptFile `
    -BindingOutputPath $BindingOutputPath `
    -RequestOutputPath $RequestOutputPath `
    -Project $Project `
    -Stage $Stage `
    -Summary $Summary `
    -Role $Role `
    -Route $Route

$bindingIdentity = Write-TelephoneJsonCreateNew -Path ([string]$prepared.binding_path) -Value $prepared.binding
$requestIdentity = Write-TelephoneJsonCreateNew -Path ([string]$prepared.request_path) -Value $prepared.request
$null = Read-TelephoneJson -Path ([string]$prepared.binding_path) -SchemaName 'lead-binding'
Assert-TelephoneDispatchRequestText -JsonText (([string](Read-TelephoneJson -Path ([string]$prepared.request_path)).text))

$result = [ordered]@{
    protocol_version = 'telephone-line-cursor-external-dispatch-result-v1'
    profile = 'cursor-external-lead'
    started = $false
    lead_should_exit_now_expected = $true
    session_id = [string]$prepared.session_id
    line_job_id = [string]$prepared.line_job_id
    executor_job_id = [string]$prepared.executor_job_id
    binding = $bindingIdentity
    request = $requestIdentity
    route = 'direct-grok-cli'
    operation = 'start'
    grok_timeout_seconds = 0
    wait_timeout_seconds = 0
}
Write-CursorExternalStdoutJson -Value $result
exit 0

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
    [string]$BindingOutputPath,
    [string]$RequestOutputPath,
    [string]$Project = 'preflight',
    [string]$Stage = 'preflight',
    [string]$Summary = 'read-only preflight',
    [ValidateSet('execution', 'review')][string]$Role = 'execution',
    [string]$Route = 'direct-grok-cli'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CursorExternalLead.Common.ps1')

function Add-CursorExternalPreflightCheck {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Checks,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('pass', 'fail')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Detail
    )
    $Checks.Add([ordered]@{
        id = $Id
        status = $Status
        detail = Protect-CursorExternalText -Text $Detail -MaxLength 1000
    })
}

$checks = [Collections.Generic.List[object]]::new()
$ready = $true
$sessionIdValue = ''
try {
    $bindingPath = if ([string]::IsNullOrWhiteSpace($BindingOutputPath)) {
        Join-Path ([IO.Path]::GetTempPath()) ('cursor-external-preflight-binding-' + [Guid]::NewGuid().ToString('N') + '.json')
    } else {
        $BindingOutputPath
    }
    $requestPath = if ([string]::IsNullOrWhiteSpace($RequestOutputPath)) {
        Join-Path ([IO.Path]::GetTempPath()) ('cursor-external-preflight-request-' + [Guid]::NewGuid().ToString('N') + '.json')
    } else {
        $RequestOutputPath
    }
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
        -BindingOutputPath $bindingPath `
        -RequestOutputPath $requestPath `
        -Project $Project `
        -Stage $Stage `
        -Summary $Summary `
        -Role $Role `
        -Route $Route
    $sessionIdValue = [string]$prepared.session_id
    Add-CursorExternalPreflightCheck -Checks $checks -Id 'prepared_dispatch' -Status pass -Detail 'Lead evidence, scratch, adapter, and create-new outputs are ready.'
} catch {
    $ready = $false
    Add-CursorExternalPreflightCheck -Checks $checks -Id 'prepared_dispatch' -Status fail -Detail ([string]$_.Exception.Message)
}

$result = [ordered]@{
    protocol_version = 'telephone-line-cursor-external-preflight-v1'
    profile = 'cursor-external-lead'
    started = $false
    ready = $ready
    session_id = $sessionIdValue
    checks = @($checks)
    allow_fast = $false
    absolute_task_timeout = $false
}
Write-CursorExternalStdoutJson -Value $result
if ($ready) { exit 0 }
exit 2

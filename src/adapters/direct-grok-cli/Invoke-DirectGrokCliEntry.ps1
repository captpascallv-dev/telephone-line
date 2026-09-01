# SPDX-License-Identifier: MPL-2.0
[CmdletBinding(DefaultParameterSetName = 'New')]
param(
    [Parameter(ParameterSetName = 'New', Mandatory = $true)][string]$WorkspacePath,
    [Parameter(ParameterSetName = 'New', Mandatory = $true)][string]$PromptFile,
    [Parameter(ParameterSetName = 'New')][string]$ResumeSessionId = '',
    [Parameter(ParameterSetName = 'New')][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$JobId,
    [Parameter(ParameterSetName = 'Recover', Mandatory = $true)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$RecoverJobId,
    [ValidateRange(0, 2147483647)][int]$GrokTimeoutSeconds = 0,
    [ValidateRange(0, 2147483647)][int]$WaitTimeoutSeconds = 0,
    [ValidateRange(65536, 67108864)][int]$MaxOutputBytes = 16777216,
    [string]$StateRoot,
    [string]$GrokCommand
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$route = Join-Path $PSScriptRoot 'Invoke-DirectGrokRoute.ps1'
$common = @{
    GrokTimeoutSeconds = $GrokTimeoutSeconds
    WaitTimeoutSeconds = $WaitTimeoutSeconds
    MaxOutputBytes = $MaxOutputBytes
}
if (-not [string]::IsNullOrWhiteSpace($StateRoot)) { $common['StateRoot'] = $StateRoot }
if (-not [string]::IsNullOrWhiteSpace($GrokCommand)) { $common['GrokCommand'] = $GrokCommand }

if ($PSCmdlet.ParameterSetName -ceq 'Recover') {
    & $route -Operation recover -JobId $RecoverJobId @common
} elseif (-not [string]::IsNullOrWhiteSpace($ResumeSessionId)) {
    if (-not [string]::IsNullOrWhiteSpace($JobId)) {
        & $route -Operation follow_up -NativeSessionId $ResumeSessionId -WorkspacePath $WorkspacePath -PromptFile $PromptFile -JobId $JobId @common
    } else {
        & $route -Operation follow_up -NativeSessionId $ResumeSessionId -WorkspacePath $WorkspacePath -PromptFile $PromptFile @common
    }
} else {
    if (-not [string]::IsNullOrWhiteSpace($JobId)) {
        & $route -Operation start -WorkspacePath $WorkspacePath -PromptFile $PromptFile -JobId $JobId @common
    } else {
        & $route -Operation start -WorkspacePath $WorkspacePath -PromptFile $PromptFile @common
    }
}
exit $LASTEXITCODE

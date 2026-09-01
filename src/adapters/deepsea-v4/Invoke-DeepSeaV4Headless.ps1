# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('start', 'follow_up', 'recover')][string]$Operation,
    [string]$NativeSessionId,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [string]$WorkspacePath,
    [string]$PromptFile,
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$JobId,
    [string]$DshCommand,
    [string]$MockHeadlessPath,
    [string]$Model,
    [string]$ReasoningEffort
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }
. (Join-Path $PSScriptRoot '..\deepsea-common\DeepSea.Common.ps1')

$route = [ordered]@{
    route_id = 'deepsea-v4'
    request_protocol = 'telephone-line-deepsea-v4-request-v1'
    receipt_protocol = 'telephone-line-deepsea-v4-receipt-v1'
    binding_protocol = 'telephone-line-deepsea-v4-binding-v1'
    result_protocol = 'telephone-line-deepsea-v4-result-v1'
    provider = 'deepseek-official'
    model = 'deepseek-v4-flash'
    reasoning_effort = ''
    allowed_reasoning_effort = @('off', 'high', 'max')
    include_subscription_oauth = $false
    supports_request_file = $false
    capabilities = [ordered]@{
        start = $true
        follow_up = $true
        recover = $true
        exact_native_session = $true
    }
    ExtraFields = { param([string]$Mode, [string[]]$AllowedWritePath) return [ordered]@{ secret_file_loaded = $false } }
}

$invoke = @{
    Route = $route
    Operation = $Operation
    NativeSessionId = $NativeSessionId
    StateRoot = $StateRoot
    WorkspacePath = $WorkspacePath
    PromptFile = $PromptFile
    JobId = $JobId
    DshCommand = $DshCommand
    MockHeadlessPath = $MockHeadlessPath
}
if ($PSBoundParameters.ContainsKey('Model')) {
    $invoke.Model = $Model
    $invoke.ModelSpecified = $true
}
if ($PSBoundParameters.ContainsKey('ReasoningEffort')) {
    $invoke.ReasoningEffort = $ReasoningEffort
    $invoke.ReasoningEffortSpecified = $true
}
Invoke-DeepSeaPublicAdapter @invoke

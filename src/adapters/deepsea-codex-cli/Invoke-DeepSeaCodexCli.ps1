# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('start', 'follow_up', 'recover')][string]$Operation,
    [string]$NativeSessionId,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [string]$WorkspacePath,
    [string]$PromptFile,
    [string]$RequestFile,
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$JobId,
    [string]$DshCommand,
    [string]$MockHeadlessPath,
    [string]$Model,
    [string]$ReasoningEffort,
    [string]$CommunityCredentialKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }
. (Join-Path $PSScriptRoot '..\deepsea-common\DeepSea.Common.ps1')

function Assert-DeepSeaCodexRequestFile {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Request)
    $operation = [string]$Request.operation
    if ($operation -cnotin @('start', 'status', 'recover')) {
        throw 'Request operation must be start, status, or recover.'
    }
    $publicOperation = ConvertTo-DeepSeaPublicOperation -Value $operation
    $allowedKeys = if ($publicOperation -eq 'start') {
        @('operation', 'job_id', 'binding_id', 'cwd', 'prompt')
    } else {
        @('operation', 'job_id', 'binding_id')
    }
    $actualKeys = @($Request.Keys)
    if (@($actualKeys | Where-Object { $_ -cnotin $allowedKeys }).Count -gt 0) { throw 'Request contains an unsupported field.' }
    if (@($allowedKeys | Where-Object { -not $Request.Contains($_) }).Count -gt 0) { throw 'Request is missing a required field.' }
    foreach ($required in @($allowedKeys | Where-Object { $_ -cne 'operation' })) {
        if ($null -eq $Request[$required] -or [string]::IsNullOrWhiteSpace([string]$Request[$required])) { throw "Request field $required is required." }
    }
    if ($Request.Contains('job_id') -and [string]$Request.job_id -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw 'Request field job_id is invalid.'
    }
    if ($publicOperation -eq 'start') {
        if (-not [IO.Path]::IsPathFullyQualified([string]$Request.cwd)) { throw 'cwd must be absolute.' }
        if (([string]$Request.prompt).Length -gt 12000) { throw 'Request prompt exceeds the durable runner limit.' }
    }
}

$route = [ordered]@{
    route_id = 'deepsea-codex-cli'
    request_protocol = 'telephone-line-deepsea-codex-cli-request-v1'
    receipt_protocol = 'telephone-line-deepsea-codex-cli-receipt-v1'
    binding_protocol = 'telephone-line-deepsea-codex-cli-binding-v1'
    result_protocol = 'telephone-line-deepsea-codex-cli-result-v1'
    provider = 'openai-codex'
    model = 'gpt-5.6-luna'
    reasoning_effort = 'high'
    allowed_reasoning_effort = @('minimal', 'low', 'medium', 'high', 'xhigh')
    include_subscription_oauth = $true
    supports_request_file = $true
    capabilities = [ordered]@{
        start = $true
        follow_up = $false
        recover = $true
        exact_native_session = $false
    }
    AssertRequestFile = ${function:Assert-DeepSeaCodexRequestFile}
}

$invoke = @{
    Route = $route
    Operation = $Operation
    NativeSessionId = $NativeSessionId
    StateRoot = $StateRoot
    WorkspacePath = $WorkspacePath
    PromptFile = $PromptFile
    RequestFile = $RequestFile
    JobId = $JobId
    DshCommand = $DshCommand
    MockHeadlessPath = $MockHeadlessPath
    CommunityCredentialKey = $CommunityCredentialKey
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

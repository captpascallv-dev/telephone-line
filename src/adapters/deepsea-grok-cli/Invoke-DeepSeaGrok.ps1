# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('start', 'follow_up', 'recover')][string]$Operation,
    [string]$NativeSessionId,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [string]$WorkspacePath,
    [string]$PromptFile,
    [string]$RequestFile,
    [ValidatePattern('^[A-Za-z0-9_-]{1,128}$')][string]$JobId,
    [string]$DshCommand,
    [string]$MockHeadlessPath,
    [string]$Model,
    [string]$ReasoningEffort
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }
. (Join-Path $PSScriptRoot '..\deepsea-common\DeepSea.Common.ps1')

function Assert-DeepSeaGrokId {
    param([Parameter(Mandatory = $true)][string]$Value, [Parameter(Mandatory = $true)][string]$Label)
    if ($Value -cnotmatch '^[A-Za-z0-9_.-]{1,128}$') { throw "$Label is invalid." }
}

function Assert-DeepSeaGrokRequest {
    param([Parameter(Mandatory = $true)][object]$Request)
    $operation = [string]$Request.operation
    if ($operation -cnotin @('start', 'status', 'recover')) {
        throw 'Request operation must be start, status, or recover.'
    }
    $publicOperation = ConvertTo-DeepSeaPublicOperation -Value $operation
    $allowedKeys = if ($publicOperation -eq 'start') {
        @('operation', 'job_id', 'binding_id', 'cwd', 'prompt')
    } elseif ($operation -ceq 'status') {
        @('operation', 'job_id', 'binding_id')
    } else {
        @('operation', 'binding_id')
    }
    $actualKeys = if ($Request -is [Collections.IDictionary]) { @($Request.Keys) } else { @($Request.PSObject.Properties.Name) }
    if (@($actualKeys | Where-Object { $_ -cnotin $allowedKeys }).Count -gt 0) { throw 'Request contains an unsupported field.' }

    $get = {
        param($Key)
        if ($Request -is [Collections.IDictionary]) { return $Request[$Key] }
        return $Request.$Key
    }
    $has = {
        param($Key)
        if ($Request -is [Collections.IDictionary]) { return $Request.Contains($Key) }
        return $null -ne $Request.PSObject.Properties[$Key]
    }

    if ($publicOperation -eq 'start') {
        foreach ($required in @('job_id', 'binding_id', 'cwd', 'prompt')) {
            $value = & $get $required
            if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { throw "Request field $required is required." }
        }
        Assert-DeepSeaJobId -Value ([string](& $get 'job_id'))
        Assert-DeepSeaGrokId -Value ([string](& $get 'binding_id')) -Label 'binding_id'
        if (-not [IO.Path]::IsPathFullyQualified([string](& $get 'cwd'))) { throw 'cwd must be absolute.' }
        if (([string](& $get 'prompt')).Length -gt 12000) { throw 'Request prompt exceeds the durable runner limit.' }
    } elseif ($operation -ceq 'status') {
        $hasJob = (& $has 'job_id') -and -not [string]::IsNullOrWhiteSpace([string](& $get 'job_id'))
        $hasBinding = (& $has 'binding_id') -and -not [string]::IsNullOrWhiteSpace([string](& $get 'binding_id'))
        if ($hasJob -eq $hasBinding) { throw 'Status requires exactly one of job_id or binding_id.' }
        if ($hasJob) { Assert-DeepSeaJobId -Value ([string](& $get 'job_id')) }
        if ($hasBinding) { Assert-DeepSeaGrokId -Value ([string](& $get 'binding_id')) -Label 'binding_id' }
    } else {
        if (-not (& $has 'binding_id') -or [string]::IsNullOrWhiteSpace([string](& $get 'binding_id'))) { throw 'Recover requires binding_id.' }
        Assert-DeepSeaGrokId -Value ([string](& $get 'binding_id')) -Label 'binding_id'
    }
}

$route = [ordered]@{
    route_id = 'deepsea-grok-cli'
    request_protocol = 'telephone-line-deepsea-grok-cli-request-v1'
    receipt_protocol = 'telephone-line-deepsea-grok-cli-receipt-v1'
    binding_protocol = 'telephone-line-deepsea-grok-cli-binding-v1'
    result_protocol = 'telephone-line-deepsea-grok-cli-result-v1'
    provider = 'xai'
    model = 'grok-4.6'
    reasoning_effort = 'xhigh'
    allowed_reasoning_effort = @('low', 'high', 'xhigh')
    include_subscription_oauth = $true
    supports_request_file = $true
    capabilities = [ordered]@{
        start = $true
        follow_up = $false
        recover = $true
        exact_native_session = $false
    }
    AssertRequestFile = ${function:Assert-DeepSeaGrokRequest}
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

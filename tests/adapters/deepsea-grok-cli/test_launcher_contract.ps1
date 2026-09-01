# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'tests\adapters\AdapterTest.Common.ps1')
$assertions = 0
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
$launcher = Join-Path $repoRoot 'src\adapters\deepsea-grok-cli\Invoke-DeepSeaGrok.ps1'
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

try {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$errors)
    Assert-AdapterTest ($errors.Count -eq 0) 'DeepSea Grok launcher did not parse.'
    $functionAsts = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in @('Assert-DeepSeaGrokId', 'Assert-DeepSeaGrokRequest')
    }, $true))
    Assert-AdapterTest ($functionAsts.Count -eq 2) 'Launcher contract functions are missing or duplicated.'
    foreach ($functionAst in $functionAsts) { . ([ScriptBlock]::Create($functionAst.Extent.Text)) }
    . (Join-Path $repoRoot 'src\adapters\deepsea-common\DeepSea.Common.ps1')

    $sample = [ordered]@{
        operation = 'start'
        job_id = 'grok-contract-start'
        binding_id = 'grok-contract-binding'
        cwd = 'C:\example\workspace'
        prompt = "line one`nline two"
    }
    $null = Assert-DeepSeaGrokRequest -Request $sample
    $relativeFailed = $false
    try {
        $null = Assert-DeepSeaGrokRequest -Request ([ordered]@{ operation = 'start'; job_id = 'a'; binding_id = 'b'; cwd = 'relative'; prompt = 'p' })
    } catch { $relativeFailed = $true }
    Assert-AdapterTest $relativeFailed 'Relative workspace was accepted.'
    $followFailed = $false
    try {
        $null = Assert-DeepSeaGrokRequest -Request ([ordered]@{ operation = 'followup'; job_id = 'a'; binding_id = 'b'; cwd = 'C:\w'; prompt = 'p' })
    } catch { $followFailed = $true }
    Assert-AdapterTest $followFailed 'Grok follow-up request was accepted.'
    $interruptFailed = $false
    try {
        $null = Assert-DeepSeaGrokRequest -Request ([ordered]@{ operation = 'interrupt'; binding_id = 'grok-contract-binding' })
    } catch { $interruptFailed = $true }
    Assert-AdapterTest $interruptFailed 'Grok interrupt request was accepted.'
    $escapeFailed = $false
    try {
        $null = Assert-DeepSeaGrokRequest -Request ([ordered]@{
            operation = 'start'
            job_id = '..\..\Windows\Temp\x'
            binding_id = 'grok-contract-binding'
            cwd = 'C:\example\workspace'
            prompt = 'p'
        })
    } catch { $escapeFailed = $true }
    Assert-AdapterTest $escapeFailed 'Escaped job_id was accepted.'
    $dotdotFailed = $false
    try {
        $null = Assert-DeepSeaGrokRequest -Request ([ordered]@{
            operation = 'start'
            job_id = '..'
            binding_id = 'grok-contract-binding'
            cwd = 'C:\example\workspace'
            prompt = 'p'
        })
    } catch { $dotdotFailed = $true }
    Assert-AdapterTest $dotdotFailed 'Dot-dot job_id was accepted.'
    $containFailed = $false
    try { $null = Get-DeepSeaJobPaths -Root (Join-Path $testRoot 'contain-state') -Id '..\..\outside\x' } catch { $containFailed = $true }
    Assert-AdapterTest $containFailed 'Get-DeepSeaJobPaths accepted a path-escaping job id.'
    $contained = Get-DeepSeaJobPaths -Root (Join-Path $testRoot 'contain-state') -Id 'grok-contract-start'
    Assert-AdapterTest ($contained.root.EndsWith('\jobs\grok-contract-start', [StringComparison]::OrdinalIgnoreCase)) 'Contained job path is not under jobs.'

    $childRoot = Join-Path $testRoot 'ops'
    $child = & ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoLogo -NoProfile -NonInteractive -File (Join-Path $repoRoot 'tests\adapters\Invoke-DeepSeaRouteContract.ps1') -TestRoot $childRoot -RouteId 'deepsea-grok-cli' -AdapterDir 'deepsea-grok-cli' -EntrypointName 'Invoke-DeepSeaGrok.ps1'
    $childJson = ($child | Select-Object -Last 1) | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ($childJson.success -eq $true) 'DeepSea Grok operation contract failed.'
    $script:assertions += [int]$childJson.assertions

    [ordered]@{
        success = $true
        true_dsh_headless_entry = 1
        sidecar_bypass = 0
        deepsea_prompt_transport = [int]$childJson.deepsea_prompt_transport
        deepsea_result_referenced = [int]$childJson.deepsea_result_referenced
        deepsea_native_binding = [int]$childJson.deepsea_native_binding
        production_shaped_dsh_invocation = [int]$childJson.production_shaped_dsh_invocation
        durable_generic_error_privacy = [int]$childJson.durable_generic_error_privacy
        follow_up_rejected = [int]$childJson.follow_up_rejected
        recover_no_provider = [int]$childJson.recover_no_provider
        provider_model_bound = [int]$childJson.provider_model_bound
        reasoning_effort_bound = [int]$childJson.reasoning_effort_bound
        deepsea_model_effort_override = [int]$childJson.deepsea_model_effort_override
        deepsea_model_effort_rejected = [int]$childJson.deepsea_model_effort_rejected
        profile_contained = [int]$childJson.profile_contained
        child_harness_launch = [int]$childJson.child_harness_launch
        assertions = $assertions
    } | ConvertTo-Json -Compress
} catch {
    [ordered]@{ success = $false; error = [string]$_.Exception.Message; assertions = $assertions } | ConvertTo-Json -Compress
    exit 1
} finally {
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

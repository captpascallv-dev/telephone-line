# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'tests\adapters\AdapterTest.Common.ps1')
$assertions = 0
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

try {
    $node = Get-Command node -ErrorAction SilentlyContinue
    Assert-AdapterTest ($null -ne $node -and -not [string]::IsNullOrWhiteSpace([string]$node.Source)) 'Node is required for the subscription store contract.'
    $scriptPath = Join-Path $PSScriptRoot 'test_subscription_store.mjs'
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = [string]$node.Source
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    [void]$info.ArgumentList.Add($scriptPath)
    [void]$info.ArgumentList.Add($testRoot)
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = [string]$stdoutTask.GetAwaiter().GetResult()
        $stderr = [string]$stderrTask.GetAwaiter().GetResult()
        Assert-AdapterTest ([int]$process.ExitCode -eq 0) "Subscription store node contract failed: $stderr $stdout"
        $parsed = ($stdout | Select-Object -Last 1) | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
        Assert-AdapterTest ($parsed.success -eq $true) 'Subscription store node contract did not report success.'
        $script:assertions += [int]$parsed.assertions
    } finally { $process.Dispose() }

    $llmText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\deepsea-common\dsh-plugin\subscription-llm.mjs'))
    Assert-AdapterTest ($llmText.Contains('function modelInputModalities(model)')) 'Catalog modality helper is missing.'
    Assert-AdapterTest ($llmText.Contains('inputModalities: modelInputModalities(found)')) 'resolveModel still hardcodes text-only modalities.'
    Assert-AdapterTest ($llmText.Contains("inputModalities: ['text']") -eq $false) 'resolveModel still contains a text-only modality literal.'
    Assert-AdapterTest ($llmText.Contains('reasoning: this.reasoning')) 'resolveModel does not advertise reasoning efforts.'
    Assert-AdapterTest ($llmText.Contains('this.models.stream(')) 'Subscription adapter does not dispatch through Models.stream.'
    Assert-AdapterTest ($llmText.Contains('reasoningEffort: String(options.reasoningEffort)')) 'Subscription adapter does not forward reasoning effort to the provider call.'
    Assert-AdapterTest ($llmText.Contains('this.models.streamSimple(') -eq $false) 'Subscription adapter still uses streamSimple, which clamps xhigh.'

    $runnerText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\deepsea-common\dsh-plugin\headless-runner.mjs'))
    Assert-AdapterTest ($runnerText.Contains('reasoningEffort: effort')) 'Headless runner does not install the configured reasoning effort.'

    $loginText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\deepsea-common\dsh-plugin\login-subscription.mjs'))
    Assert-AdapterTest ($loginText.Contains('communityPaths') -eq $true) 'Login helper does not mention community store mirroring.'
    Assert-AdapterTest ($loginText.Contains('USERPROFILE') -eq $false) 'Login helper prints a user-home path.'

    $commonText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\deepsea-common\DeepSea.Common.ps1'))
    $codexEntryText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\deepsea-codex-cli\Invoke-DeepSeaCodexCli.ps1'))
    Assert-AdapterTest ($commonText.Contains('TELEPHONE_LINE_DSH_CODEX_COMMUNITY_KEY')) 'DeepSea common does not bind the selected community credential key.'
    Assert-AdapterTest ($codexEntryText.Contains('[string]$CommunityCredentialKey')) 'DeepSea Codex entry does not expose the community credential key.'

    $resolveText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\deepsea-common\dsh-plugin\resolve-modules.mjs'))
    Assert-AdapterTest ($resolveText.Contains('process.cwd()') -eq $false) 'Module resolver still walks from the current working directory.'
    Assert-AdapterTest ($resolveText.Contains('pi-coding-agent') -eq $false) 'Module resolver still names PI coding-agent.'

    [ordered]@{
        success = $true
        assertions = $assertions
    } | ConvertTo-Json -Compress
} catch {
    [ordered]@{ success = $false; error = [string]$_.Exception.Message; assertions = $assertions } | ConvertTo-Json -Compress
    exit 1
} finally {
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

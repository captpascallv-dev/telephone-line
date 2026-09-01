# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$results = [ordered]@{
    protocol_version = 'telephone-line-existing-adapter-test-result-v1'
    success = $false
    routes = [ordered]@{}
    deepsea_prompt_transport = 0
    deepsea_result_referenced = 0
    deepsea_native_binding = 0
    production_shaped_dsh_invocation = 0
    pi_path_discovery = 0
    durable_generic_error_privacy = 0
    follow_up_rejected = 0
    recover_no_provider = 0
    cursor_unavailable = 0
    cursor_process_launch = 0
    v4_exact_native_session = 0
    provider_model_bound = 0
    reasoning_effort_bound = 0
    deepsea_model_effort_override = 0
    deepsea_model_effort_rejected = 0
    profile_contained = 0
    child_harness_launch = 0
    exact_native_session_truthful = 0
    descriptors_validated = 0
    codex_exact_session = 0
    codex_recover_no_rerun = 0
    claude_exact_session = 0
    claude_recover_no_rerun = 0
}

function Invoke-AdapterChild {
    param([Parameter(Mandatory = $true)][string]$ScriptPath, [Parameter(Mandatory = $true)][string]$ChildRoot)
    [IO.Directory]::CreateDirectory($ChildRoot) | Out-Null
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $ScriptPath, '-TestRoot', $ChildRoot
    )) { [void]$info.ArgumentList.Add([string]$argument) }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [ordered]@{
            exit_code = [int]$process.ExitCode
            stdout = [string]$stdoutTask.GetAwaiter().GetResult()
            stderr = [string]$stderrTask.GetAwaiter().GetResult()
        }
    } finally { $process.Dispose() }
}

try {
    $scripts = @(
        @{ name = 'descriptors'; script = 'tests\adapters\test_adapter_descriptors.ps1' },
        @{ name = 'direct-cursor'; script = 'tests\adapters\direct-cursor\test_direct_cursor_route.ps1' },
        @{ name = 'direct-grok-cli'; script = 'tests\adapters\direct-grok-cli\test_direct_grok_route.ps1' },
        @{ name = 'direct-pi'; script = 'tests\adapters\direct-pi\test_direct_pi_route.ps1' },
        @{ name = 'direct-codex-cli'; script = 'tests\adapters\direct-codex-cli\test_direct_codex_route.ps1' },
        @{ name = 'direct-claude-code'; script = 'tests\adapters\direct-claude-code\test_direct_claude_route.ps1' },
        @{ name = 'deepsea-codex-cli'; script = 'tests\adapters\deepsea-codex-cli\test_deepsea_codex_cli.ps1' },
        @{ name = 'deepsea-grok-cli'; script = 'tests\adapters\deepsea-grok-cli\test_launcher_contract.ps1' },
        @{ name = 'deepsea-subscription-store'; script = 'tests\adapters\deepsea-common\test_subscription_store.ps1' },
        @{ name = 'deepsea-v4'; script = 'tests\adapters\deepsea-v4\test_deepsea_v4.ps1' }
    )
    $total = 0
    foreach ($item in $scripts) {
        $childRoot = Join-Path $testRoot $item.name
        $run = Invoke-AdapterChild -ScriptPath (Join-Path $repoRoot $item.script) -ChildRoot $childRoot
        if ([int]$run.exit_code -ne 0) {
            throw "$($item.name) failed: $($run.stderr) $($run.stdout)"
        }
        $json = ($run.stdout | Select-Object -Last 1)
        $parsed = $json | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
        if ($parsed.success -ne $true) { throw "$($item.name) did not report success." }
        $count = [int]$parsed.assertions
        $total += $count
        $results.routes[$item.name] = [ordered]@{ assertions = $count; exit_code = 0 }
        foreach ($counter in @(
            'deepsea_prompt_transport',
            'deepsea_result_referenced',
            'deepsea_native_binding',
            'production_shaped_dsh_invocation',
            'pi_path_discovery',
            'durable_generic_error_privacy',
            'follow_up_rejected',
            'recover_no_provider',
            'cursor_unavailable',
            'cursor_process_launch',
            'v4_exact_native_session',
            'provider_model_bound',
            'reasoning_effort_bound',
            'deepsea_model_effort_override',
            'deepsea_model_effort_rejected',
            'profile_contained',
            'child_harness_launch',
            'exact_native_session_truthful',
            'descriptors_validated',
            'codex_exact_session',
            'codex_recover_no_rerun',
            'claude_exact_session',
            'claude_recover_no_rerun'
        )) {
            if ($parsed.Contains($counter)) { $results[$counter] = [int]$results[$counter] + [int]$parsed[$counter] }
        }
    }
    $results.success = $true
    $results.assertions = $total
    $results.exit_code = 0
    foreach ($counter in @(
        'deepsea_prompt_transport',
        'deepsea_result_referenced',
        'deepsea_native_binding',
        'production_shaped_dsh_invocation',
        'pi_path_discovery',
        'durable_generic_error_privacy',
        'follow_up_rejected',
        'recover_no_provider',
        'v4_exact_native_session',
        'provider_model_bound',
        'reasoning_effort_bound',
        'deepsea_model_effort_override',
        'deepsea_model_effort_rejected',
        'profile_contained',
        'exact_native_session_truthful',
        'codex_exact_session',
        'codex_recover_no_rerun',
        'claude_exact_session',
        'claude_recover_no_rerun'
    )) {
        if ([int]$results[$counter] -lt 1) { throw "Adapter tests did not prove $counter." }
    }
    if ([int]$results.descriptors_validated -ne 8) { throw 'Adapter tests did not validate 8 descriptors.' }
    if ([int]$results.cursor_process_launch -ne 0) { throw 'Cursor process-launch counter was not zero.' }
    if ([int]$results.child_harness_launch -ne 0) { throw 'Child Harness launch counter was not zero.' }
} catch {
    $results.success = $false
    $results.error = [string]$_.Exception.Message
    $results.exit_code = 1
    $results | ConvertTo-Json -Depth 16
    exit 1
} finally {
    if ([IO.Directory]::Exists($testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $results.residue = [IO.Directory]::Exists($testRoot)
}

if ($results.residue) {
    $results.success = $false
    $results.exit_code = 1
    $results | ConvertTo-Json -Depth 16
    exit 1
}

$results | ConvertTo-Json -Depth 16
exit 0

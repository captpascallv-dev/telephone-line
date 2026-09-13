# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'tests\adapters\AdapterTest.Common.ps1')
. (Join-Path $repoRoot 'src\adapters\deepsea-common\DeepSea.Common.ps1')
$assertions = 0
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

try {
    $common = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\deepsea-common\DeepSea.Common.ps1'))
    Assert-AdapterTest ($common.Contains('- id: web-fetch-http') -and $common.Contains('disabled: true')) 'Contained profile does not disable web-fetch-http with web.'
    $runner = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\deepsea-common\dsh-plugin\headless-runner.mjs'))
    Assert-AdapterTest ($runner.Contains('SessionSeq') -and $runner.Contains('eventAt(SessionSeq')) 'Headless runner still reads agent.session.events.'

    $stdout = "CANARY_PROMPT please ignore`nmodel said CANARY_RESPONSE`nsk-abcdefghijklmnopqrstuvwxyz012345`n"
    $stderr = "dsh: ERROR: waiting for service: web`nBearer super-secret-token`n"
    $diag = New-DeepSeaSafeDiagnostic -Stdout $stdout -Stderr $stderr -ExitCode 1
    Assert-AdapterTest ([string]$diag.excerpt -match 'waiting for service: web') 'Safe diagnostic dropped the real waiting-for-service error.'
    Assert-AdapterTest ([string]$diag.excerpt -notmatch 'CANARY_PROMPT' -and [string]$diag.excerpt -notmatch 'CANARY_RESPONSE') 'Safe diagnostic leaked prompt/response canaries.'
    Assert-AdapterTest ([string]$diag.excerpt -notmatch 'sk-abcdefghijklmnopqrstuvwxyz012345' -and [string]$diag.excerpt -notmatch 'super-secret-token') 'Safe diagnostic leaked credential material.'
    Assert-AdapterTest ([string]$diag.sha256 -cmatch '^[0-9a-f]{64}$') 'Safe diagnostic omitted a stream digest.'

    $workspace = Join-Path $testRoot 'workspace'
    $stateRoot = Join-Path $testRoot 'state'
    $promptPath = Join-Path $testRoot 'prompt.txt'
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    [IO.File]::WriteAllText($promptPath, 'dsh-fail-canary', [Text.UTF8Encoding]::new($false))
    $mockFail = Join-Path $testRoot 'mock-fail.ps1'
    @'
# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::Error.WriteLine("waiting for service: web")
[Console]::Error.WriteLine("CANARY_PROMPT leaked")
exit 1
'@ | Set-Content -LiteralPath $mockFail -Encoding utf8
    $invoke = Join-Path $repoRoot 'src\adapters\deepsea-v4\Invoke-DeepSeaV4Headless.ps1'
    $jobId = [Guid]::NewGuid().ToString('D')
    $run = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace,
        '-PromptFile', $promptPath, '-JobId', $jobId, '-MockHeadlessPath', $mockFail
    )
    Assert-AdapterTest ($run.exit_code -eq 4) "Official DSH entry did not preserve nonzero failure, exit=$($run.exit_code) $($run.stderr)"
    $receiptPath = Join-Path $stateRoot ("jobs\$jobId\receipt.json")
    Assert-AdapterTest ([IO.File]::Exists($receiptPath)) 'Failure omitted a receipt.'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ([string]$receipt.error_code -ceq 'ADAPTER_HEADLESS_INVOCATION_FAILED') 'Failure receipt missing adapter error_code.'
    Assert-AdapterTest ([bool]$receipt.transport_complete -eq $false) 'Failure receipt claimed transport complete.'
    Assert-AdapterTest ([string]$receipt.diagnostic_excerpt -match 'waiting for service: web') 'Failure receipt diagnostic omitted the service error.'
    Assert-AdapterTest ([string]$receipt.diagnostic_excerpt -notmatch 'CANARY_PROMPT') 'Failure receipt diagnostic leaked the prompt canary.'

    [ordered]@{
        success = $true
        assertions = $assertions
        official_nonzero_exit = 4
        diagnostic_kept = 1
    } | ConvertTo-Json -Compress
} finally {
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

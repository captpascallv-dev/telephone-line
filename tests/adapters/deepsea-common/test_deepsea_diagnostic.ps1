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
    Assert-AdapterTest ($common -notmatch 'CANARY_') 'Production diagnostic filter still special-cases test canary names.'
    $runner = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\deepsea-common\dsh-plugin\headless-runner.mjs'))
    Assert-AdapterTest ($runner.Contains('SessionSeq') -and $runner.Contains('eventAt(SessionSeq')) 'Headless runner still reads agent.session.events.'

    $nonce = [guid]::NewGuid().ToString('N')
    $privatePrompt = "Please explain this error in my private order $nonce"
    $privateResponse = "dsh: confidential answer $nonce"
    $privateAuth = "Authorization: service-key-$nonce"
    $workspace = Join-Path $testRoot 'workspace'
    $stateRoot = Join-Path $testRoot 'state'
    $promptPath = Join-Path $testRoot 'prompt.txt'
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    [IO.File]::WriteAllText($promptPath, "dsh-fail-$nonce", [Text.UTF8Encoding]::new($false))
    $mockFail = Join-Path $testRoot 'mock-fail.ps1'
    [IO.File]::WriteAllText($mockFail, @"
# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
[Console]::Error.WriteLine('$privateAuth')
[Console]::Error.WriteLine('waiting for service: web')
[Console]::Out.WriteLine('$privatePrompt')
[Console]::Out.WriteLine('$privateResponse')
exit 1
"@, [Text.UTF8Encoding]::new($false))
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
    $excerpt = [string]$receipt.diagnostic_excerpt
    Assert-AdapterTest ($excerpt -match 'waiting for service: web') 'Failure receipt diagnostic omitted the service error.'
    Assert-AdapterTest ($excerpt -notmatch [regex]::Escape($nonce)) 'Failure receipt diagnostic leaked the generated nonce.'
    Assert-AdapterTest ($excerpt -notmatch [regex]::Escape($privatePrompt)) 'Failure receipt diagnostic leaked the private prompt.'
    Assert-AdapterTest ($excerpt -notmatch [regex]::Escape($privateResponse)) 'Failure receipt diagnostic leaked the model response.'
    Assert-AdapterTest ($excerpt -notmatch [regex]::Escape($privateAuth) -and $excerpt -notmatch 'service-key-') 'Failure receipt diagnostic leaked the credential.'
    Assert-AdapterTest ([string]$receipt.diagnostic_sha256 -cmatch '^[0-9a-f]{64}$') 'Failure receipt omitted a stream digest.'
    $jobDir = Join-Path $stateRoot ("jobs\$jobId")
    $stdoutFiles = @(Get-ChildItem -LiteralPath $jobDir -File | Where-Object { $_.Name -match 'stdout|stderr|stream' })
    Assert-AdapterTest ($stdoutFiles.Count -eq 0) 'Failure wrote raw stream files into the job receipt directory.'

    [ordered]@{
        success = $true
        assertions = $assertions
        official_nonzero_exit = 4
        diagnostic_kept = 1
    } | ConvertTo-Json -Compress
} finally {
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

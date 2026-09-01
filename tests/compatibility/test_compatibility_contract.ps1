# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$assertions = 0
$contractStagesFive = 0
$contractFilesExist = 0
$contractCountersEmitted = 0
$contractDocAgrees = 0
$contractNoPaidModel = 0
$ciWorkflowOfflineShape = 0

function Assert-CompatTest {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Get-ContractDocStages {
    param([Parameter(Mandatory = $true)][string]$Text)
    $stages = [Collections.Generic.List[object]]::new()
    $inTable = $false
    foreach ($raw in @($Text.Split("`n"))) {
        $line = $raw.TrimEnd("`r")
        if ($line -match '^\|\s*stage\s*\|\s*proving_test\s*\|\s*proving_counter\s*\|') {
            $inTable = $true
            continue
        }
        if (-not $inTable) { continue }
        if ($line -match '^\|\s*-+') { continue }
        if (-not $line.StartsWith('|', [StringComparison]::Ordinal)) { break }
        $cells = [Collections.Generic.List[string]]::new()
        foreach ($part in @($line.Split([char]'|'))) {
            $cell = $part.Trim().Trim([char]0x60)
            if (-not [string]::IsNullOrWhiteSpace($cell)) { [void]$cells.Add($cell) }
        }
        if ($cells.Count -lt 3) { continue }
        [void]$stages.Add([ordered]@{
            name = [string]$cells[0]
            proving_test = [string]$cells[1]
            proving_counter = [string]$cells[2]
        })
    }
    return @($stages)
}

function Add-IntegerCounterNames {
    param($Node, [Collections.Generic.HashSet[string]]$Names)
    if ($Node -is [Collections.IDictionary]) {
        foreach ($key in @($Node.Keys)) {
            $value = $Node[$key]
            if ($value -is [byte] -or $value -is [int16] -or $value -is [uint16] -or $value -is [int] -or $value -is [uint32] -or $value -is [int64] -or $value -is [uint64] -or $value -is [decimal] -or $value -is [double]) {
                [void]$Names.Add([string]$key)
            } elseif ($value -is [Collections.IDictionary] -or $value -is [System.Collections.IEnumerable]) {
                Add-IntegerCounterNames -Node $value -Names $Names
            }
        }
        return
    }
    if ($Node -is [string] -or $Node -is [ValueType]) { return }
    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($item in @($Node)) {
            Add-IntegerCounterNames -Node $item -Names $Names
        }
    }
}

function Get-SuiteCounterNames {
    param([Parameter(Mandatory = $true)][object]$Contract)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $aggregatePath = Join-Path $testRoot 'suite-aggregate.json'
    if ([IO.File]::Exists($aggregatePath)) {
        $aggregateText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($aggregatePath))
        $aggregate = $aggregateText | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
        if ($aggregate.Contains('names')) {
            foreach ($name in @($aggregate.names)) { [void]$names.Add([string]$name) }
        }
        Add-IntegerCounterNames -Node $aggregate -Names $names
        return $names
    }

    $uniqueTests = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($stage in @($Contract.stages)) {
        $rel = [string]$stage.proving_test
        if ($seen.Add($rel)) { [void]$uniqueTests.Add($rel) }
    }
    $index = 0
    foreach ($rel in $uniqueTests) {
        $scriptPath = [IO.Path]::GetFullPath((Join-Path $repoRoot ($rel.Replace('/', '\'))))
        $childRoot = Join-Path $testRoot ('prove-' + $index.ToString())
        [IO.Directory]::CreateDirectory($childRoot) | Out-Null
        $index += 1
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $pwsh
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.CreateNoWindow = $true
        foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $scriptPath, '-TestRoot', $childRoot
        )) {
            [void]$info.ArgumentList.Add([string]$argument)
        }
        $process = [Diagnostics.Process]::Start($info)
        try {
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            $stdout = [string]$stdoutTask.GetAwaiter().GetResult()
            $stderr = [string]$stderrTask.GetAwaiter().GetResult()
            Assert-CompatTest ($process.ExitCode -eq 0) ("Proving test failed: $rel $stderr $stdout")
            $jsonLine = ($stdout | Select-Object -Last 1)
            $parsed = $jsonLine | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
            Add-IntegerCounterNames -Node $parsed -Names $names
        } finally {
            $process.Dispose()
        }
    }
    return $names
}

function Test-CiWorkflowShape {
    param([Parameter(Mandatory = $true)][string]$Text)
    $normalized = $Text.Replace("`r`n", "`n")
    Assert-CompatTest ($normalized -match '(?m)^on:\s*$') 'CI workflow is missing an on: block.'
    Assert-CompatTest ($normalized -match '(?m)^\s+push:\s*$') 'CI workflow is missing a push trigger.'
    Assert-CompatTest ($normalized -match '(?m)^\s+pull_request:\s*$') 'CI workflow is missing a pull_request trigger.'
    Assert-CompatTest ($normalized -match '(?m)^\s+workflow_dispatch:\s*$') 'CI workflow is missing workflow_dispatch.'
    Assert-CompatTest ($normalized -match '(?m)^\s+contents:\s*read\s*$') 'CI workflow permissions are not contents: read.'
    Assert-CompatTest ($normalized -match '(?m)^\s+runs-on:\s*windows-latest\s*$') 'CI job does not run on windows-latest.'
    Assert-CompatTest ($normalized.Contains('tests/Invoke-OfflineTests.ps1')) 'CI workflow does not run tests/Invoke-OfflineTests.ps1.'
    Assert-CompatTest ($normalized.Contains('LASTEXITCODE')) 'CI workflow does not fail the job on a non-zero exit code.'
    $uses = [regex]::Matches($normalized, '(?m)^\s+uses:\s*(\S+)\s*$')
    Assert-CompatTest ($uses.Count -ge 1) 'CI workflow has no uses: action.'
    foreach ($match in $uses) {
        $action = [string]$match.Groups[1].Value.Trim().Trim('"').Trim("'")
        Assert-CompatTest ($action -match '^actions/checkout@v\d+\.\d+\.\d+$') "CI workflow uses an unpinned or extra action: $action"
    }
    foreach ($forbidden in @(
        'schedule:',
        'cron:',
        'secrets.',
        'secrets:',
        'environment:',
        'self-hosted',
        'container:',
        'strategy:',
        'id-token',
        'packages:',
        'softprops/',
        'docker://'
    )) {
        Assert-CompatTest ($normalized.ToLowerInvariant().Contains($forbidden.ToLowerInvariant()) -eq $false) "CI workflow contains forbidden token: $forbidden"
    }
    Assert-CompatTest ([regex]::IsMatch($normalized, '(?im)\bpublish\b') -eq $false) 'CI workflow contains a publish step.'
    Assert-CompatTest ([regex]::IsMatch($normalized, '(?im)\bdeploy\b') -eq $false) 'CI workflow contains a deploy step.'
    Assert-CompatTest ([regex]::IsMatch($normalized, '(?m)^\s+release:\s*$') -eq $false) 'CI workflow contains a release trigger.'
    Assert-CompatTest ([regex]::IsMatch($normalized, '(?im)\bgit\s+push\b') -eq $false) 'CI workflow pushes.'
    $yamlCommand = Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue
    if ($null -ne $yamlCommand) {
        $null = $normalized | ConvertFrom-Yaml
    }
}

try {
    $contractPath = Join-Path $repoRoot 'tests\compatibility\compatibility-contract.json'
    $docPath = Join-Path $repoRoot 'docs\compatibility-contract.md'
    $ciPath = Join-Path $repoRoot '.github\workflows\ci.yml'
    $contractText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($contractPath))
    $docText = [IO.File]::ReadAllText($docPath)
    $ciText = [IO.File]::ReadAllText($ciPath)
    $contract = $contractText | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String

    Assert-CompatTest ([string]$contract.protocol -ceq 'telephone-line-compatibility-contract-v1') 'Compatibility contract protocol is not telephone-line-compatibility-contract-v1.'
    $expectedNames = @('dispatch', 'detached execution', 'durable receipt', 'exact Lead wake', 'next turn')
    $stages = @($contract.stages)
    Assert-CompatTest ($stages.Count -eq 5) 'Compatibility contract does not list exactly five stages.'
    for ($i = 0; $i -lt 5; $i++) {
        Assert-CompatTest ([string]$stages[$i].name -ceq [string]$expectedNames[$i]) ("Compatibility contract stage order differs at " + [string]$expectedNames[$i])
    }
    $script:contractStagesFive = 1

    foreach ($stage in $stages) {
        $rel = [string]$stage.proving_test
        Assert-CompatTest ($rel.Contains('\') -eq $false) "Proving test path is not POSIX: $rel"
        $full = [IO.Path]::GetFullPath((Join-Path $repoRoot ($rel.Replace('/', '\'))))
        Assert-CompatTest ([IO.File]::Exists($full)) "Named proving test is missing: $rel"
    }
    $script:contractFilesExist = 1

    $emitted = Get-SuiteCounterNames -Contract $contract
    foreach ($stage in $stages) {
        $counter = [string]$stage.proving_counter
        Assert-CompatTest ($emitted.Contains($counter)) "Named counter is not present in suite aggregate output: $counter"
    }
    $script:contractCountersEmitted = 1

    $docStages = @(Get-ContractDocStages -Text $docText)
    Assert-CompatTest ($docStages.Count -eq $stages.Count) 'Contract document stage count does not match the JSON mirror.'
    for ($i = 0; $i -lt $stages.Count; $i++) {
        Assert-CompatTest ([string]$docStages[$i].name -ceq [string]$stages[$i].name) 'Contract document stage name does not match the JSON mirror.'
        Assert-CompatTest ([string]$docStages[$i].proving_test -ceq [string]$stages[$i].proving_test) 'Contract document proving_test does not match the JSON mirror.'
        Assert-CompatTest ([string]$docStages[$i].proving_counter -ceq [string]$stages[$i].proving_counter) 'Contract document proving_counter does not match the JSON mirror.'
    }
    $script:contractDocAgrees = 1

    Assert-CompatTest ($docText.IndexOf('no paid model', [StringComparison]::OrdinalIgnoreCase) -ge 0) 'Contract document does not state the no-paid-model guarantee.'
    Assert-CompatTest ($docText.IndexOf('no network', [StringComparison]::OrdinalIgnoreCase) -ge 0) 'Contract document does not state the no-network guarantee.'
    Assert-CompatTest ([bool]$contract.no_paid_model -eq $true) 'Contract JSON does not set no_paid_model true.'
    Assert-CompatTest ([bool]$contract.no_network -eq $true) 'Contract JSON does not set no_network true.'
    $harnessExe = @(
        'codex.exe',
        'claude.exe',
        'cursor-agent.exe',
        'grok.exe',
        'dsh.exe',
        'pi.exe'
    )
    foreach ($stage in $stages) {
        $rel = [string]$stage.proving_test
        $full = [IO.Path]::GetFullPath((Join-Path $repoRoot ($rel.Replace('/', '\'))))
        $testText = [IO.File]::ReadAllText($full)
        foreach ($exe in $harnessExe) {
            Assert-CompatTest ($testText.IndexOf($exe, [StringComparison]::OrdinalIgnoreCase) -lt 0) "$rel references harness executable $exe."
        }
    }
    $script:contractNoPaidModel = 1

    Test-CiWorkflowShape -Text $ciText
    $script:ciWorkflowOfflineShape = 1

    [ordered]@{
        success = $true
        assertions = $assertions
        contract_stages_five = $contractStagesFive
        contract_files_exist = $contractFilesExist
        contract_counters_emitted = $contractCountersEmitted
        contract_doc_agrees = $contractDocAgrees
        contract_no_paid_model = $contractNoPaidModel
        ci_workflow_offline_shape = $ciWorkflowOfflineShape
    } | ConvertTo-Json -Compress
} catch {
    [ordered]@{
        success = $false
        error = [string]$_.Exception.Message
        assertions = $assertions
        contract_stages_five = $contractStagesFive
        contract_files_exist = $contractFilesExist
        contract_counters_emitted = $contractCountersEmitted
        contract_doc_agrees = $contractDocAgrees
        contract_no_paid_model = $contractNoPaidModel
        ci_workflow_offline_shape = $ciWorkflowOfflineShape
    } | ConvertTo-Json -Compress
    exit 1
} finally {
    if ([IO.Directory]::Exists($testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

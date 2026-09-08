# SPDX-License-Identifier: MPL-2.0
# Discriminating FrozenLeadLauncher stdout/exit/identity coverage.
# Wiring template only; does not claim Lead start/attach or waiter ack.
# Does not duplicate mock-lead-launcher wake/delivery assertions.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'src\core\TelephoneLine.Common.ps1')
$assertions = 0
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

function Assert-CallerLauncherTest {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Get-FrozenLeadThrowMessage {
    param(
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][string]$PromptFile,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [object[]]$ExtraArguments = @()
    )
    try {
        $null = Invoke-TelephoneFrozenLeadLauncher -LauncherPath $LauncherPath -ExtraArguments $ExtraArguments -Worktree $Worktree -PromptFile $PromptFile -SessionId $SessionId -RunId $RunId
        return $null
    } catch {
        return [string]$_.Exception.Message
    }
}

function Write-FixtureScript {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string[]]$Lines)
    [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
}

try {
    $example = Join-Path $repoRoot 'docs\examples\caller-supplied-lead\Invoke-GenericLeadLauncher.ps1'
    Assert-CallerLauncherTest ([IO.File]::Exists($example)) 'Stdout-contract wiring template is missing.'

    $worktree = Join-Path $testRoot 'worktree'
    $prompt = Join-Path $testRoot 'wake-prompt.txt'
    $runs = Join-Path $testRoot 'runs'
    [IO.Directory]::CreateDirectory($worktree) | Out-Null
    [IO.File]::WriteAllText($prompt, "fixture prompt`n", [Text.UTF8Encoding]::new($false))
    $sessionId = '01b00000-0000-7000-8000-000000000099'
    $runId = 'caller-supplied-valid'
    $extra = @('-StateRootOverride', $runs)

    $launch = Invoke-TelephoneFrozenLeadLauncher -LauncherPath $example -ExtraArguments $extra -Worktree $worktree -PromptFile $prompt -SessionId $sessionId -RunId $runId
    $expectedRoot = [IO.Path]::GetFullPath((Join-Path $runs $runId)).TrimEnd('\')
    Assert-CallerLauncherTest ([string]$launch.run_root -ceq $expectedRoot) 'Valid wiring template did not return the real run_root.'
    Assert-CallerLauncherTest ([string]$launch.state -cne 'started' -and [string]$launch.state -cne 'attached') 'Wiring template claimed started/attached.'
    Assert-CallerLauncherTest ([IO.File]::Exists((Join-Path ([string]$launch.run_root) 'frozen-wake-identity.json'))) 'Wiring template omitted frozen identity.'
    Assert-CallerLauncherTest (-not [IO.File]::Exists((Join-Path ([string]$launch.run_root) 'lead-wake-ack.json'))) 'Wiring template wrote lead-wake-ack.json.'

    $again = Invoke-TelephoneFrozenLeadLauncher -LauncherPath $example -ExtraArguments $extra -Worktree $worktree -PromptFile $prompt -SessionId $sessionId -RunId $runId
    Assert-CallerLauncherTest ([string]$again.run_root -ceq [string]$launch.run_root) 'Same frozen identity did not re-emit the same run_root.'
    Assert-CallerLauncherTest ([string]$again.state -cne 'attached' -and [string]$again.state -cne 'started') 'Re-emit claimed started/attached.'
    $valid_response = 1

    $otherSession = '01b00000-0000-7000-8000-000000000098'
    $mismatch = Get-FrozenLeadThrowMessage -LauncherPath $example -ExtraArguments $extra -Worktree $worktree -PromptFile $prompt -SessionId $otherSession -RunId $runId
    Assert-CallerLauncherTest ($mismatch -ceq 'Lead launcher failed.') 'Same RunId with a different frozen session was accepted.'
    $identity_refuse = 1

    $emptyPath = Join-Path $testRoot 'empty-stdout.ps1'
    Write-FixtureScript -Path $emptyPath -Lines @(
        'param([Parameter(Mandatory = $true)][string]$WorktreePath,[Parameter(Mandatory = $true)][string]$PromptFile,[Parameter(Mandatory = $true)][string]$ResumeSessionId,[Parameter(Mandatory = $true)][string]$RunId)',
        'exit 0'
    )
    $emptyThrown = Get-FrozenLeadThrowMessage -LauncherPath $emptyPath -Worktree $worktree -PromptFile $prompt -SessionId $sessionId -RunId 'empty-stdout'
    Assert-CallerLauncherTest ($emptyThrown -ceq 'Lead launcher failed.') 'Empty stdout on exit 0 was not rejected as Lead launcher failed.'

    $malformedPath = Join-Path $testRoot 'malformed-stdout.ps1'
    Write-FixtureScript -Path $malformedPath -Lines @(
        'param([Parameter(Mandatory = $true)][string]$WorktreePath,[Parameter(Mandatory = $true)][string]$PromptFile,[Parameter(Mandatory = $true)][string]$ResumeSessionId,[Parameter(Mandatory = $true)][string]$RunId)',
        '[Console]::Out.WriteLine("{not-json")',
        'exit 0'
    )
    $malformedThrown = Get-FrozenLeadThrowMessage -LauncherPath $malformedPath -Worktree $worktree -PromptFile $prompt -SessionId $sessionId -RunId 'malformed-stdout'
    Assert-CallerLauncherTest (-not [string]::IsNullOrWhiteSpace($malformedThrown)) 'Malformed stdout on exit 0 was accepted.'
    Assert-CallerLauncherTest ($malformedThrown -cne 'Lead launcher failed.') 'Malformed stdout did not reach JSON parse (unexpected empty-stdout path).'
    $missing_or_malformed_stdout = 1

    $failPath = Join-Path $testRoot 'failing-exit.ps1'
    Write-FixtureScript -Path $failPath -Lines @(
        'param([Parameter(Mandatory = $true)][string]$WorktreePath,[Parameter(Mandatory = $true)][string]$PromptFile,[Parameter(Mandatory = $true)][string]$ResumeSessionId,[Parameter(Mandatory = $true)][string]$RunId)',
        '[Console]::Out.WriteLine(''{"run_root":"Z:\\not-accepted"}'')',
        'exit 2'
    )
    $failThrown = Get-FrozenLeadThrowMessage -LauncherPath $failPath -Worktree $worktree -PromptFile $prompt -SessionId $sessionId -RunId 'failing-exit'
    Assert-CallerLauncherTest ($failThrown -ceq 'Lead launcher failed.') 'Nonzero exit with success-looking JSON was accepted.'
    $failing_exit = 1

    [ordered]@{
        success = $true
        valid_response = $valid_response
        identity_refuse = $identity_refuse
        missing_or_malformed_stdout = $missing_or_malformed_stdout
        failing_exit = $failing_exit
        assertions = $assertions
    } | ConvertTo-Json -Compress
} catch {
    [ordered]@{
        success = $false
        error = [string]$_.Exception.Message
        assertions = $assertions
    } | ConvertTo-Json -Compress
    exit 1
} finally {
    if ([IO.Directory]::Exists($testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

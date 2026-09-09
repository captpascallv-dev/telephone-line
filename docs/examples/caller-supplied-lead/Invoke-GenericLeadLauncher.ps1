# SPDX-License-Identifier: MPL-2.0
# FIXTURE / WIRING TEMPLATE for the FrozenLeadLauncher stdout contract.
# This is not a production Lead launcher. It does not start or resume a Lead,
# does not emit waiter-recognizable native events, and must not report
# started/attached. Directory existence is not an attach.
# Required real integration: a caller-supplied launcher that resumes the
# frozen session and produces Core-recognized wake evidence (canonical ack
# or lead-run.json plus thread.started then turn.started).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorktreePath,
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [Parameter(Mandatory = $true)][string]$ResumeSessionId,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$StateRootOverride
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-GenericLeadFailure {
    param([Parameter(Mandatory = $true)][string]$Message, [int]$Code = 1)
    [Console]::Error.WriteLine(('language_mode=' + [string]$ExecutionContext.SessionState.LanguageMode))
    [Console]::Error.WriteLine($Message)
    exit $Code
}

if (-not (Test-Path -LiteralPath $WorktreePath)) {
    Write-GenericLeadFailure "WorktreePath does not exist: $WorktreePath"
}
if (-not (Test-Path -LiteralPath $PromptFile)) {
    Write-GenericLeadFailure "PromptFile does not exist: $PromptFile"
}
if ([string]::IsNullOrWhiteSpace($ResumeSessionId)) {
    Write-GenericLeadFailure 'ResumeSessionId is required.'
}
if ([string]::IsNullOrWhiteSpace($RunId)) {
    Write-GenericLeadFailure 'RunId is required.'
}
if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$') {
    Write-GenericLeadFailure 'RunId is not a safe token.'
}
if ([string]::IsNullOrWhiteSpace($StateRootOverride)) {
    Write-GenericLeadFailure 'StateRootOverride is required for this wiring template.'
}

$stateRoot = [IO.Path]::GetFullPath($StateRootOverride).TrimEnd('\')
$runRoot = [IO.Path]::GetFullPath((Join-Path $stateRoot $RunId)).TrimEnd('\')
$prefix = $stateRoot + '\'
if (-not (($runRoot + '\').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $runRoot.Equals($stateRoot, [StringComparison]::OrdinalIgnoreCase))) {
    Write-GenericLeadFailure 'RunId escaped the state root.'
}

$worktreeFull = [IO.Path]::GetFullPath($WorktreePath).TrimEnd('\')
$promptFull = [IO.Path]::GetFullPath($PromptFile)
$promptBytes = [IO.File]::ReadAllBytes($promptFull)
$identity = [ordered]@{
    run_id = $RunId
    resume_session_id = $ResumeSessionId
    worktree = $worktreeFull
    prompt_file = $promptFull
    prompt_bytes = $promptBytes.Length
    prompt_sha256 = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($promptBytes))).Replace('-', '').ToLowerInvariant()
}
$identityPath = Join-Path $runRoot 'frozen-wake-identity.json'

if (Test-Path -LiteralPath $runRoot) {
    $item = Get-Item -LiteralPath $runRoot
    if (-not $item.PSIsContainer) {
        Write-GenericLeadFailure "run_root exists and is not a directory: $runRoot"
    }
    if (-not [IO.File]::Exists($identityPath)) {
        Write-GenericLeadFailure 'run_root exists without frozen identity; refusing directory-as-attach.'
    }
    $existing = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    if ([string]$existing.resume_session_id -cne [string]$identity.resume_session_id -or
        [string]$existing.worktree -cne [string]$identity.worktree -or
        [string]$existing.prompt_file -cne [string]$identity.prompt_file -or
        [string]$existing.prompt_sha256 -cne [string]$identity.prompt_sha256) {
        Write-GenericLeadFailure 'RunId is already bound to a different frozen wake identity.'
    }
} else {
    [IO.Directory]::CreateDirectory($runRoot) | Out-Null
    [IO.File]::WriteAllText($identityPath, (($identity | ConvertTo-Json -Compress -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
}

$diagPath = Join-Path $runRoot 'launcher-diagnostic.txt'
$diag = @(
    'fixture=stdout_contract_wiring_template',
    "run_id=$RunId",
    "worktree=$worktreeFull",
    "prompt_file=$promptFull"
) -join "`n"
[IO.File]::WriteAllText($diagPath, ($diag + "`n"), [Text.UTF8Encoding]::new($false))
[Console]::Error.WriteLine("generic-lead-launcher-fixture run_id=$RunId")

$payload = [ordered]@{
    run_id = $RunId
    run_root = $runRoot
    state = 'stdout_contract_fixture'
}
[Console]::Out.WriteLine(($payload | ConvertTo-Json -Compress -Depth 8))
exit 0

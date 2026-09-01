# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [Parameter(Mandatory = $true)][ValidateRange(1, [long]::MaxValue)][long]$ExpectedRequestBytes,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedRequestSha256,
    [Parameter(Mandatory = $true)][ValidateRange(1, [long]::MaxValue)][long]$ExpectedBridgeBytes,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedBridgeSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }
. (Join-Path $PSScriptRoot 'DirectCursor.Common.ps1')

$bridgeIdentity = Get-DirectFileIdentity -Path $PSCommandPath
if ([int64]$bridgeIdentity.bytes -ne $ExpectedBridgeBytes -or [string]$bridgeIdentity.sha256 -cne $ExpectedBridgeSha256) {
    throw 'Direct Cursor bridge identity changed before launch.'
}

$requestRead = Read-DirectJson -Path $RequestPath
if ([int64]$requestRead.identity.bytes -ne $ExpectedRequestBytes -or [string]$requestRead.identity.sha256 -cne $ExpectedRequestSha256) {
    throw 'Direct Cursor request identity changed before launch.'
}
$request = $requestRead.value
Assert-DirectKeys -Value $request -Keys @(
    'protocol_version', 'job_id', 'workspace', 'prompt', 'mode', 'model',
    'expected_account', 'expected_subscription', 'resume_session_id', 'allowed_write_paths',
    'allow_write', 'allow_fast', 'timeout_seconds', 'max_output_bytes', 'session_root', 'wrapper', 'cursor_agent_root'
) -Label 'Direct Cursor request'

if ([string]$request.protocol_version -cne 'telephone-line-direct-cursor-request-v1') { throw 'Unsupported Direct Cursor request protocol.' }
if ([string]$request.job_id -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'Direct Cursor job ID is invalid.' }
if ($request.prompt -isnot [Collections.IDictionary]) { throw 'Direct Cursor prompt binding is malformed.' }
Assert-DirectKeys -Value $request.prompt -Keys @('path', 'bytes', 'sha256') -Label 'Direct Cursor prompt binding'
$promptIdentity = Get-DirectFileIdentity -Path ([string]$request.prompt.path)
Assert-DirectIdentity -Expected $request.prompt -Actual $promptIdentity -Label 'Direct Cursor prompt'
if ([string]$request.mode -cnotin @('ReadOnly', 'Verify', 'Write')) { throw 'Direct Cursor mode is unsupported.' }
if ($request.allow_fast -ne $false) { throw 'Direct Cursor Fast mode is disabled.' }
if ($request.allow_write -isnot [bool] -or $request.allow_fast -isnot [bool]) { throw 'Direct Cursor Boolean controls are malformed.' }

$workspace = [IO.Path]::GetFullPath([string]$request.workspace).TrimEnd('\')
if (-not [IO.Directory]::Exists($workspace)) { throw 'Direct Cursor workspace does not exist.' }
$authority = Resolve-DirectCursorModeAuthority -Mode ([string]$request.mode) -AllowWrite ([bool]$request.allow_write) -AllowedWritePath ([string[]]@($request.allowed_write_paths)) -WorkspacePath $workspace
$allowedWritePaths = [string[]]@($authority.allowed_write_paths)
if ($authority.requires_linked_worktree -and -not (Test-Path -LiteralPath (Join-Path $workspace '.git') -PathType Leaf)) {
    throw 'Automated Write mode requires a pre-created linked Git worktree (.git file).'
}

if ($request.wrapper -isnot [Collections.IDictionary]) { throw 'Direct Cursor wrapper binding is malformed.' }
Assert-DirectKeys -Value $request.wrapper -Keys @('path', 'bytes', 'sha256') -Label 'Direct Cursor wrapper binding'
$adapterRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$expectedWrapperPath = [IO.Path]::GetFullPath((Join-Path $adapterRoot 'invoke_cursor_agent.ps1'))
if (-not $expectedWrapperPath.Equals([IO.Path]::GetFullPath([string]$request.wrapper.path), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Direct Cursor wrapper escaped the adapter root.'
}
$wrapperIdentity = Get-DirectFileIdentity -Path $expectedWrapperPath
Assert-DirectIdentity -Expected $request.wrapper -Actual $wrapperIdentity -Label 'Direct Cursor wrapper'

$sessionRoot = [IO.Path]::GetFullPath([string]$request.session_root).TrimEnd('\')
$parameters = @{
    WorkspacePath = $workspace
    PromptFile = [string]$promptIdentity.path
    Mode = [string]$authority.mode
    Model = [string]$request.model
    SessionRoot = $sessionRoot
    TimeoutSeconds = [int]$request.timeout_seconds
    MaxOutputBytes = [int]$request.max_output_bytes
}
if (-not [string]::IsNullOrWhiteSpace([string]$request.expected_account)) { $parameters.ExpectedAccount = [string]$request.expected_account }
if (-not [string]::IsNullOrWhiteSpace([string]$request.expected_subscription)) { $parameters.ExpectedSubscription = [string]$request.expected_subscription }
if (-not [string]::IsNullOrWhiteSpace([string]$request.resume_session_id)) { $parameters.ResumeSessionId = [string]$request.resume_session_id }
if (-not [string]::IsNullOrWhiteSpace([string]$request.cursor_agent_root)) { $parameters.CursorAgentRoot = [string]$request.cursor_agent_root }
if ($true -eq $authority.allow_write) { $parameters.AllowWrite = $true }
if ($allowedWritePaths.Count -gt 0) { $parameters.AllowedWritePath = $allowedWritePaths }

try {
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
    & $expectedWrapperPath @parameters
    $exitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
} finally {
    $parameters.Clear()
}
exit $exitCode

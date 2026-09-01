# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorktreePath,
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [Parameter(Mandatory = $true)][string]$ResumeSessionId,
    [Parameter(Mandatory = $true)][string]$RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$marker = [string]$env:TELEPHONE_TEST_CLI_FALLBACK_MARKER
if ([string]::IsNullOrWhiteSpace($marker)) {
    throw 'CLI fallback spy marker is missing.'
}
[IO.File]::AppendAllText($marker, ("cli-fallback run_id=$RunId session=$ResumeSessionId`n"), [Text.UTF8Encoding]::new($false))
$runRoot = Join-Path ([IO.Path]::GetTempPath()) ('cli-fallback-' + $RunId)
[IO.Directory]::CreateDirectory($runRoot) | Out-Null
[ordered]@{
    started = $true
    existing = $false
    state = 'completed'
    run_id = $RunId
    run_root = $runRoot
} | ConvertTo-Json -Compress

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
$marker = [string]$env:CURSOR_EXTERNAL_SPY_MARKER
if ([string]::IsNullOrWhiteSpace($marker)) {
    throw 'Spy launcher marker path is missing.'
}
$parent = [IO.Path]::GetDirectoryName($marker)
if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::AppendAllText($marker, ("invoked run_id=$RunId session=$ResumeSessionId`n"), [Text.UTF8Encoding]::new($false))
[ordered]@{
    started = $true
    state = 'completed'
    run_id = $RunId
    run_root = $parent
} | ConvertTo-Json -Compress
exit 0

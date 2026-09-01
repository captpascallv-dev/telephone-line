# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$Operation,
    [string]$StateRoot,
    [string]$WorkspacePath,
    [string]$PromptFile,
    [string]$JobId,
    [int]$GrokTimeoutSeconds = -1,
    [int]$WaitTimeoutSeconds = -1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[ordered]@{
    operation = [string]$Operation
    state_root = [string]$StateRoot
    workspace = [string]$WorkspacePath
    prompt = [string]$PromptFile
    job_id = [string]$JobId
    grok_timeout_seconds = [int]$GrokTimeoutSeconds
    wait_timeout_seconds = [int]$WaitTimeoutSeconds
} | ConvertTo-Json -Compress
exit 0

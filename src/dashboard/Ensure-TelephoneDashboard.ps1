# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TelephoneDashboard.Common.ps1')
$result = Invoke-TelephoneBundledDashboardEnsure
[ordered]@{
    healthy = [bool]$result.healthy
    started = [bool]$result.started
    already_running = [bool]$result.already_running
    watcher_pid = [int]$result.watcher_pid
    configured = [bool]$result.configured
    attempted = [bool]$result.attempted
    error_code = [string]$result.error_code
    source = [string]$result.source
    observational = $true
} | ConvertTo-Json -Compress

# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$CodexCommand,
    [string]$WorktreePath,
    [string]$StateRoot,
    [string]$ProfilePath,
    [ValidateSet('app-server', 'cli')][string]$CallbackTransport = 'app-server'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexAppServerLead.Common.ps1')

$checks = [Collections.Generic.List[object]]::new()
$ready = $true
function Add-Check {
    param([string]$Id, [string]$Status, [string]$Detail)
    $checks.Add([ordered]@{
        id = $Id
        status = $Status
        detail = Protect-CodexAppServerText -Text $Detail -MaxLength 1000
    })
}

try {
    $exe = Resolve-CodexAppServerExecutable -CodexCommand $CodexCommand
    $version = Get-CodexAppServerVersion -CodexCommand $exe
    Add-Check -Id 'codex_version' -Status pass -Detail $version
} catch {
    $ready = $false
    Add-Check -Id 'codex_version' -Status fail -Detail (Get-CodexAppServerPublicMessage -Code 'VERSION_PROBE_FAILED')
}

try {
    $bound = Invoke-CodexAppServerBindProfile -CodexCommand $CodexCommand
    Add-Check -Id 'schema_fingerprint' -Status pass -Detail ([string]$bound.profile.schema_fingerprint)
    if (-not [string]::IsNullOrWhiteSpace($ProfilePath) -and [IO.File]::Exists($ProfilePath)) {
        $existing = (Read-TelephoneJson -Path $ProfilePath -SchemaName 'codex-app-server-lead-profile').value
        $null = Assert-CodexAppServerProfileCurrent -Profile $existing -CodexCommand $CodexCommand
        Add-Check -Id 'profile_match' -Status pass -Detail 'bound profile matches the installed oracle'
    }
} catch {
    $ready = $false
    Add-Check -Id 'schema_fingerprint' -Status fail -Detail (Get-CodexAppServerPublicMessage -Code 'SCHEMA_OR_PROFILE_INVALID')
}

if (-not [string]::IsNullOrWhiteSpace($WorktreePath)) {
    try {
        $null = Assert-CodexAppServerNoReparseChain -Path (Assert-TelephoneDirectoryPath -Path $WorktreePath -Label 'Lead worktree') -Label 'Lead worktree'
        Add-Check -Id 'worktree' -Status pass -Detail 'worktree is a real directory'
    } catch {
        $ready = $false
        Add-Check -Id 'worktree' -Status fail -Detail (Get-CodexAppServerPublicMessage -Code 'WORKTREE_INVALID')
    }
}

if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
    try {
        $full = [IO.Path]::GetFullPath($StateRoot)
        Assert-CodexAppServerStateOutsidePackage -StateRoot $full
        if (-not [IO.Directory]::Exists($full)) { [IO.Directory]::CreateDirectory($full) | Out-Null }
        $null = Assert-CodexAppServerNoReparseChain -Path $full -Label 'State root'
        Add-Check -Id 'state_root' -Status pass -Detail 'state root is usable'
    } catch {
        $ready = $false
        Add-Check -Id 'state_root' -Status fail -Detail (Get-CodexAppServerPublicMessage -Code 'STATE_ROOT_INVALID')
    }
}

Add-Check -Id 'callback_transport' -Status pass -Detail $CallbackTransport
Add-Check -Id 'stdio_only' -Status pass -Detail 'preflight does not open websocket, unix, or experimental listeners'

$result = [ordered]@{
    protocol_version = 'telephone-line-codex-app-server-lead-preflight-v1'
    profile = 'codex-app-server-lead'
    started = $false
    ready = $ready
    callback_transport = $CallbackTransport
    checks = @($checks)
    allow_fast = $false
    absolute_task_timeout = $false
}
Write-CodexAppServerStdoutJson -Value $result
if ($ready) { exit 0 }
exit 2

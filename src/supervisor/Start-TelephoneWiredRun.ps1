# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestFile,
    [string]$StateRoot,
    [string]$InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TelephoneSupervisor.Common.ps1')
if (-not $IsWindows) { throw 'Telephone Line v0.1 supports Windows only.' }

$resolvedState = Resolve-TelephoneSupervisorStateRoot -StateRoot $StateRoot
$resolvedInstall = if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
    [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
} elseif (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_INSTALL_ROOT)) {
    [IO.Path]::GetFullPath([string]$env:TELEPHONE_LINE_INSTALL_ROOT).TrimEnd('\')
} else {
    [IO.Path]::GetFullPath((Join-Path ([string]$env:LOCALAPPDATA) 'TelephoneLine')).TrimEnd('\')
}

$requestRead = Read-TelephoneJson -Path $RequestFile
$request = $requestRead.value
if ($request -isnot [Collections.IDictionary]) { throw 'Supervisor request is invalid.' }
Assert-TelephoneJsonSchema -JsonText ([string]$requestRead.text) -SchemaName 'wired-supervisor-request' -Label 'wired supervisor request'
$providedHash = if ($request.Contains('request_sha256')) { [string]$request.request_sha256 } else { '' }
$worktree = Assert-TelephoneDirectoryPath -Path ([string]$request.worktree) -Label 'Supervisor worktree'
$executable = Assert-TelephoneRegularFilePath -Path ([string]$request.command.executable) -Label 'Supervisor command executable'
$workingDirectory = Assert-TelephoneDirectoryPath -Path ([string]$request.command.working_directory) -Label 'Supervisor command working directory'
$request.worktree = $worktree
$request.command.executable = $executable
$request.command.working_directory = $workingDirectory
$computedHash = Get-TelephoneSupervisorRequestHash -Request $request
if (-not [string]::IsNullOrWhiteSpace($providedHash) -and $providedHash -cne $computedHash) {
    throw 'Supervisor request hash does not match the canonical request bytes.'
}
$request['request_sha256'] = $computedHash
$null = Assert-TelephoneSupervisorRequestValue -Request $request

$pointer = Read-TelephoneInstallCurrentPointer -InstallRoot $resolvedInstall
if ($null -ne $pointer) {
    $matchesCurrent = ([string]$request.installed_version.version_id -ceq [string]$pointer.version_id) -or ([string]$request.installed_version.source_sha256 -ceq [string]$pointer.source_sha256)
    if (-not $matchesCurrent) {
        $pinned = @(Get-TelephoneSupervisorPinnedVersionIds -StateRoot $resolvedState)
        if ($pinned -notcontains [string]$request.installed_version.version_id) {
            throw 'Supervisor request version does not match the installed current or a pinned version.'
        }
    }
}

$published = Publish-TelephoneSupervisorInbox -StateRoot $resolvedState -Request $request
$triggered = $false
$launched = $false
if (-not [bool]$published.replayed) {
    $pause = Get-TelephoneSupervisorPause -StateRoot $resolvedState
    if (-not [bool]$pause.paused_by_pascal) {
        $supervisorScript = Join-Path $resolvedInstall 'src\supervisor\Invoke-TelephoneSupervisor.ps1'
        if (-not [IO.File]::Exists($supervisorScript)) {
            $supervisorScript = Join-Path $PSScriptRoot 'Invoke-TelephoneSupervisor.ps1'
        }
        $start = Invoke-TelephoneSupervisorTaskOperation -Operation start -InstallRoot $resolvedInstall -ActionScript $supervisorScript -ActionArguments ('-InstallRoot "' + $resolvedInstall + '" -StateRoot "' + $resolvedState + '"')
        $triggered = $true
        $launched = [bool]($start.Contains('started') -and [bool]$start.started)
    }
}

[ordered]@{
    published = [bool]$published.published
    replayed = [bool]$published.replayed
    triggered = [bool]$triggered
    launched = [bool]$launched
    run_id = [string]$request.run_id
    request_sha256 = [string]$published.request_sha256
    state_root = $resolvedState
    lead_should_exit_now = $true
    absolute_task_timeout = $false
    project_judgment = $false
} | ConvertTo-Json -Depth 16

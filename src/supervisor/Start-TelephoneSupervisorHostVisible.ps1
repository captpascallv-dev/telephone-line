# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$StateRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$scriptInstall = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$install = if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
    [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
} else {
    $scriptInstall
}
$supervisor = Join-Path $PSScriptRoot 'Invoke-TelephoneSupervisor.ps1'
$defaultState = Join-Path $install 'supervisor-state'
$state = if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
    [IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
} else {
    $defaultState
}
$status = Join-Path $state 'scheduled-task-supervisor-output.json'
foreach ($path in @($pwsh,$supervisor)) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Scheduled supervisor dependency is not a regular file.' }
}
if ([IO.Directory]::Exists($state)) {
    $stateItem = Get-Item -LiteralPath $state -Force -ErrorAction Stop
    if (-not $stateItem.PSIsContainer -or ($stateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Supervisor state root is not a regular directory.'
    }
} else {
    [IO.Directory]::CreateDirectory($state) | Out-Null
}
$failure = Join-Path $state 'scheduled-task-launcher-error.json'
try {
    $output = (& $supervisor -InstallRoot $install -StateRoot $state | Out-String)
    $scriptSucceeded = $?
    $lastExitVariable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
    $scriptExitCode = if ($null -ne $lastExitVariable) { $lastExitVariable.Value } else { $null }
    [IO.File]::WriteAllText($status, $output, [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($failure)) { [IO.File]::Delete($failure) }
    if (-not $scriptSucceeded) {
        if ($null -ne $scriptExitCode) { exit [int]$scriptExitCode }
        exit 1
    }
    exit 0
} catch {
    $record = [ordered]@{
        failed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        message = [string]$_.Exception.Message
        type = [string]$_.Exception.GetType().FullName
        stack = [string]$_.ScriptStackTrace
        requested_state_root = $state
        default_state_root = $defaultState
        explicit_state = (-not [string]::IsNullOrWhiteSpace($StateRoot))
    }
    [IO.File]::WriteAllText($failure, (($record | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    exit 1
}

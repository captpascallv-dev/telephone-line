# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$install = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$supervisor = Join-Path $PSScriptRoot 'Invoke-TelephoneSupervisor.ps1'
$state = Join-Path $install 'supervisor-state'
$status = Join-Path $state 'scheduled-task-supervisor-output.json'
foreach ($path in @($pwsh,$supervisor)) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Scheduled supervisor dependency is not a regular file.' }
}
if (-not [IO.Directory]::Exists($state)) { [IO.Directory]::CreateDirectory($state) | Out-Null }
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
    }
    [IO.File]::WriteAllText($failure, (($record | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    exit 1
}

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
$command = "`$ErrorActionPreference='Stop'; `$output=& '" + $supervisor.Replace("'", "''") + "' -InstallRoot '" + $install.Replace("'", "''") + "' -StateRoot '" + $state.Replace("'", "''") + "'|Out-String; [IO.File]::WriteAllText('" + $status.Replace("'", "''") + "',`$output,[Text.UTF8Encoding]::new(`$false)); exit 0"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = $pwsh
$info.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$process = [Diagnostics.Process]::Start($info)
if ($null -eq $process) { exit 1 }
$process.Dispose()
exit 0

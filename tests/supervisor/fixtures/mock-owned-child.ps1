# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MarkerFile,
    [int]$HoldMilliseconds = 8000,
    [switch]$SpawnSuccessor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$parent = [IO.Path]::GetDirectoryName($MarkerFile)
if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
$self = Get-Process -Id $PID
try {
    $row = [ordered]@{
        pid = [int]$PID
        start_time_utc_ticks = [int64]$self.StartTime.ToUniversalTime().Ticks
        started_at_utc = $self.StartTime.ToUniversalTime().ToString('o')
    }
    [IO.File]::WriteAllText($MarkerFile, (($row | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
} finally {
    $self.Dispose()
}
if ($SpawnSuccessor) {
    $successorMarker = Join-Path $parent ('successor-' + [IO.Path]::GetFileName($MarkerFile))
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath, '-MarkerFile', $successorMarker, '-HoldMilliseconds', ([string]$HoldMilliseconds)
    )) {
        [void]$info.ArgumentList.Add([string]$argument)
    }
    $successor = [Diagnostics.Process]::Start($info)
    $successor.Dispose()
    exit 0
}
$stopFile = Join-Path $parent ('stop-child-' + [string]$PID)
$deadline = [DateTimeOffset]::UtcNow.AddMilliseconds([Math]::Max(200, [int]$HoldMilliseconds))
while ([DateTimeOffset]::UtcNow -lt $deadline -and -not [IO.File]::Exists($stopFile)) {
    Start-Sleep -Milliseconds 50
}
exit 0

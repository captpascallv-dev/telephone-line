# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$request = Get-Content -LiteralPath $RequestFile -Raw | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
$store = [string]$request.store
if ([string]::IsNullOrWhiteSpace($store)) { $store = [string]$env:TELEPHONE_LINE_TASK_STORE }
if ([string]::IsNullOrWhiteSpace($store)) { throw 'Mock scheduler store is required.' }
$storeRoot = [IO.Path]::GetFullPath($store).TrimEnd('\')
if (-not [IO.Directory]::Exists($storeRoot)) { [IO.Directory]::CreateDirectory($storeRoot) | Out-Null }
$recordPath = Join-Path $storeRoot 'task.json'
$logPath = Join-Path $storeRoot 'operations.jsonl'
$op = [string]$request.operation
$payload = [ordered]@{
    operation = $op
    at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    task_name = [string]$request.task_name
    action_script = [string]$request.action_script
}
Add-Content -LiteralPath $logPath -Value (($payload | ConvertTo-Json -Compress) + "`n") -Encoding utf8
switch ($op) {
    'register' {
        $record = [ordered]@{
            task_name = [string]$request.task_name
            principal = 'LimitedUser'
            hidden = $true
            logon_type = 'InteractiveToken'
            action_script = [string]$request.action_script
            action_arguments = [string]$request.action_arguments
            install_root = [string]$request.install_root
            registered = $true
        }
        [IO.File]::WriteAllText($recordPath, (($record | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
        $record | ConvertTo-Json -Compress
    }
    'unregister' {
        if ([IO.File]::Exists($recordPath)) { [IO.File]::Delete($recordPath) }
        [ordered]@{ unregistered = $true } | ConvertTo-Json -Compress
    }
    'get' {
        if (-not [IO.File]::Exists($recordPath)) {
            [ordered]@{ registered = $false } | ConvertTo-Json -Compress
            break
        }
        $text = [IO.File]::ReadAllText($recordPath)
        Write-Output $text.TrimEnd()
    }
    'start' {
        if (-not [IO.File]::Exists($recordPath)) { throw 'Mock scheduled task is not registered.' }
        $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
        $expected = [string]$request.action_script
        if (-not [string]::IsNullOrWhiteSpace($expected) -and [string]$record.action_script -cne $expected) {
            throw 'Scheduled task action identity is wrong.'
        }
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $info.UseShellExecute = $true
        $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $argText = [string]$record.action_arguments
        if ($argText -match '(?i)^-NoLogo\s+-NoProfile\s+-NonInteractive\s+-ExecutionPolicy\s+Bypass\s+-WindowStyle\s+Hidden\s+-EncodedCommand\s+') {
            # Mirror the real scheduler action: EncodedCommand is the complete
            # pwsh argument surface and already contains the exact script path.
            $info.Arguments = $argText
        } else {
            $quotedScript = '"' + ([string]$record.action_script).Replace('"', '""') + '"'
            $info.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + $quotedScript
            if (-not [string]::IsNullOrWhiteSpace($argText)) {
                $info.Arguments = $info.Arguments + ' ' + $argText
            }
        }
        $process = [Diagnostics.Process]::Start($info)
        if ($null -eq $process) { throw 'Mock scheduled task start failed.' }
        $pidValue = [int]$process.Id
        $process.Dispose()
        [ordered]@{ started = $true; pid = $pidValue } | ConvertTo-Json -Compress
    }
    default { throw ('Unknown mock scheduler operation: ' + $op) }
}

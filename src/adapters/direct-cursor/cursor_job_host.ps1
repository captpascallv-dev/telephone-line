# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }

$gateName = $env:CURSOR_DISPATCH_GATE
$argumentsBase64 = $env:CURSOR_DISPATCH_ARGUMENTS_B64
$nodePath = $env:CURSOR_DISPATCH_NODE
$indexPath = $env:CURSOR_DISPATCH_INDEX

if ([string]::IsNullOrWhiteSpace($gateName) -or
    [string]::IsNullOrWhiteSpace($argumentsBase64) -or
    [string]::IsNullOrWhiteSpace($nodePath) -or
    [string]::IsNullOrWhiteSpace($indexPath)) {
    throw 'Cursor dispatch host environment is incomplete.'
}

$gate = [Threading.EventWaitHandle]::OpenExisting($gateName)
try {
    if (-not $gate.WaitOne(30000)) {
        throw 'Cursor dispatch host was not released by its Job Object owner.'
    }
} finally {
    $gate.Dispose()
}

$argumentsJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($argumentsBase64))
$cursorArguments = @($argumentsJson | ConvertFrom-Json)

Remove-Item Env:CURSOR_DISPATCH_GATE -ErrorAction SilentlyContinue
Remove-Item Env:CURSOR_DISPATCH_ARGUMENTS_B64 -ErrorAction SilentlyContinue
Remove-Item Env:CURSOR_DISPATCH_NODE -ErrorAction SilentlyContinue
Remove-Item Env:CURSOR_DISPATCH_INDEX -ErrorAction SilentlyContinue

& $nodePath $indexPath @cursorArguments
exit $LASTEXITCODE

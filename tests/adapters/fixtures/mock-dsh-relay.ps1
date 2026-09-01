# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens = @($args)
if ($tokens.Count -lt 4) { throw 'Executable DSH profile surface is missing.' }
$profile = $null
$resume = $null
$sessionOut = $null
$taskParts = [Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $tokens.Count; $i += 1) {
    $token = [string]$tokens[$i]
    if ($token -ceq '--profile') {
        $i += 1
        if ($i -ge $tokens.Count) { throw 'Executable DSH profile value is missing.' }
        $profile = [string]$tokens[$i]
        continue
    }
    if ($token -ceq '--resume') {
        $i += 1
        if ($i -ge $tokens.Count) { throw 'Executable DSH resume value is missing.' }
        $resume = [string]$tokens[$i]
        continue
    }
    if ($token -ceq '--session-out') {
        $i += 1
        if ($i -ge $tokens.Count) { throw 'Executable DSH session-out value is missing.' }
        $sessionOut = [string]$tokens[$i]
        continue
    }
    [void]$taskParts.Add($token)
}
if ($profile -cne 'headless') { throw 'Executable DSH profile surface is missing.' }
$task = [string]::Join(' ', @($taskParts))
$headless = Join-Path $PSScriptRoot 'mock-headless.ps1'
$invoke = @{
    Profile = 'headless'
    SessionOut = $sessionOut
    Task = $task
}
if (-not [string]::IsNullOrWhiteSpace($resume)) { $invoke.Resume = $resume }
& $headless @invoke
exit $LASTEXITCODE

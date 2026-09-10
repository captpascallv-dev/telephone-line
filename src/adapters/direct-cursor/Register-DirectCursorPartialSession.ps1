# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$FailedRequestPath,
    [Parameter(Mandatory = $true)][string]$FailedReceiptPath,
    [Parameter(Mandatory = $true)][string]$NativeTranscriptPath,
    [Parameter(Mandatory = $true)][string]$NativeMetaPath,
    [Parameter(Mandatory = $true)][string]$ObservedSessionId,
    [string]$OldBindingPath = '',
    [string]$FailedOwnerPath = '',
    [string]$ActualExecutionPath = '',
    [int]$CursorNodePid = 0,
    [int64]$CursorNodeStartTicks = 0,
    [string]$FixtureLabel = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }
. (Join-Path $PSScriptRoot 'DirectCursor.Common.ps1')

$result = Register-DirectCursorPartialSessionAdmission `
    -StateRoot $StateRoot `
    -FailedRequestPath $FailedRequestPath `
    -FailedReceiptPath $FailedReceiptPath `
    -NativeTranscriptPath $NativeTranscriptPath `
    -NativeMetaPath $NativeMetaPath `
    -ObservedSessionId $ObservedSessionId `
    -OldBindingPath $OldBindingPath `
    -FailedOwnerPath $FailedOwnerPath `
    -ActualExecutionPath $ActualExecutionPath `
    -CursorNodePid $CursorNodePid `
    -CursorNodeStartTicks $CursorNodeStartTicks `
    -FixtureLabel $FixtureLabel

$result | ConvertTo-Json -Depth 16
exit 0

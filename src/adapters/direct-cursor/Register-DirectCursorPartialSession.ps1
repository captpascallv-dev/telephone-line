# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$FailedRequestPath,
    [Parameter(Mandatory = $true)][string]$FailedReceiptPath,
    [Parameter(Mandatory = $true)][string]$NativeTranscriptPath,
    [Parameter(Mandatory = $true)][string]$NativeMetaPath,
    [Parameter(Mandatory = $true)][string]$ObservedSessionId,
    [Parameter(Mandatory = $true)][string]$OldBindingPath,
    [Parameter(Mandatory = $true)][string]$FailedOwnerPath,
    [Parameter(Mandatory = $true)][string]$ActualExecutionPath,
    [Parameter(Mandatory = $true)][string]$ExpectedEvidencePath,
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
    -ExpectedEvidencePath $ExpectedEvidencePath `
    -CursorNodePid $CursorNodePid `
    -CursorNodeStartTicks $CursorNodeStartTicks `
    -FixtureLabel $FixtureLabel

$result | ConvertTo-Json -Depth 16
exit 0

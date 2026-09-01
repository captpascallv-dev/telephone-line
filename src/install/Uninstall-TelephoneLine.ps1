# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$InstallRoot,
    [switch]$RemoveState
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Telephone Line v0.1 supports Windows only.' }
. (Join-Path $PSScriptRoot 'TelephoneLineInstall.Common.ps1')

$result = Invoke-TelephoneLineUninstall -InstallRoot $InstallRoot -RemoveState:$RemoveState
Write-Output (ConvertTo-TelephoneInstallJson -Value $result).TrimEnd()
if ($result.ok -eq $true) { exit 0 }
exit 1

# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$OutputPath,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TelephonePackaging.Common.ps1')

$result = Invoke-TelephoneWriteArchive -SourceRoot $SourceRoot -OutputPath $OutputPath -Force:$Force -OutputPathBound:$PSBoundParameters.ContainsKey('OutputPath') -Kind 'release'
Write-Output (ConvertTo-TelephonePackagingJson -Value $result).TrimEnd()
if ($result.ok -eq $true) { exit 0 }
exit 1

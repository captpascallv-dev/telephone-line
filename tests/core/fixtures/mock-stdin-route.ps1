# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$inputStream = [Console]::OpenStandardInput()
$memory = [IO.MemoryStream]::new()
try {
    $inputStream.CopyTo($memory)
    $bytes = $memory.ToArray()
} finally {
    $memory.Dispose()
    $inputStream.Dispose()
}
[ordered]@{
    success = $true
    stdin_base64 = [Convert]::ToBase64String($bytes)
} | ConvertTo-Json -Compress

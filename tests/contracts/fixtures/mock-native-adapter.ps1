# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('start', 'follow_up', 'recover')][string]$Operation,
    [string]$NativeSessionId,
    [Parameter(Mandatory = $true)][string]$SessionStore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-MockNativeSession {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { throw 'Mock native session store is missing.' }
    $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true)).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'Mock native session store is empty.' }
    return $text
}

switch ($Operation) {
    'start' {
        if (-not [string]::IsNullOrWhiteSpace($NativeSessionId)) { throw 'Mock adapter start must not receive a native session id.' }
        $session = 'mock-native-' + [Guid]::NewGuid().ToString('N')
        $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($SessionStore))
        if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        if ([IO.File]::Exists($SessionStore)) { throw 'Mock adapter start would overwrite an existing native session.' }
        [IO.File]::WriteAllText($SessionStore, $session + "`n", [Text.UTF8Encoding]::new($false))
        [ordered]@{ operation = 'start'; native_session_id = $session; automatic_rerun = $false } | ConvertTo-Json -Compress
    }
    'follow_up' {
        $expected = Read-MockNativeSession -Path $SessionStore
        if ([string]$NativeSessionId -cne $expected) { throw 'Mock adapter follow-up native session mismatch.' }
        [ordered]@{ operation = 'follow_up'; native_session_id = $expected; automatic_rerun = $false } | ConvertTo-Json -Compress
    }
    'recover' {
        $expected = Read-MockNativeSession -Path $SessionStore
        if ([string]$NativeSessionId -cne $expected) { throw 'Mock adapter recover native session mismatch.' }
        [ordered]@{ operation = 'recover'; native_session_id = $expected; automatic_rerun = $false; replacement_started = $false } | ConvertTo-Json -Compress
    }
}

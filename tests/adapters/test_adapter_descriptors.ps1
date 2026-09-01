# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'src\core\TelephoneLine.Common.ps1')
. (Join-Path $repoRoot 'src\contracts\TelephoneLine.AdapterContract.ps1')
. (Join-Path $PSScriptRoot 'AdapterTest.Common.ps1')
$assertions = 0
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

$expected = @{
    'direct-cursor' = @{ dir = 'direct-cursor'; start = $true; follow_up = $true; recover = $true; exact_native_session = $true }
    'direct-grok-cli' = @{ dir = 'direct-grok-cli'; start = $true; follow_up = $true; recover = $true; exact_native_session = $true }
    'direct-pi' = @{ dir = 'direct-pi'; start = $true; follow_up = $true; recover = $true; exact_native_session = $true }
    'direct-codex-cli' = @{ dir = 'direct-codex-cli'; start = $true; follow_up = $true; recover = $true; exact_native_session = $true }
    'direct-claude-code' = @{ dir = 'direct-claude-code'; start = $true; follow_up = $true; recover = $true; exact_native_session = $true }
    'deepsea-codex-cli' = @{ dir = 'deepsea-codex-cli'; start = $true; follow_up = $false; recover = $true; exact_native_session = $false }
    'deepsea-grok-cli' = @{ dir = 'deepsea-grok-cli'; start = $true; follow_up = $false; recover = $true; exact_native_session = $false }
    'deepsea-v4' = @{ dir = 'deepsea-v4'; start = $true; follow_up = $true; recover = $true; exact_native_session = $true }
}

try {
    $validated = 0
    foreach ($routeId in @($expected.Keys | Sort-Object)) {
        $route = $expected[$routeId]
        $adapterRoot = Join-Path $repoRoot ('src\adapters\' + $route.dir)
        $descriptorPath = Join-Path $adapterRoot 'adapter.json'
        $loaded = Read-TelephoneAdapterDescriptor -Path $descriptorPath -AdapterRoot $adapterRoot
        Assert-AdapterTest ([string]$loaded.descriptor.route_id -ceq [string]$routeId) 'Descriptor route id differs.'
        Assert-AdapterTest ([bool]$loaded.descriptor.capabilities.start -eq [bool]$route.start) "$routeId start capability differs."
        Assert-AdapterTest ([bool]$loaded.descriptor.capabilities.follow_up -eq [bool]$route.follow_up) "$routeId follow_up capability differs."
        Assert-AdapterTest ([bool]$loaded.descriptor.capabilities.recover -eq [bool]$route.recover) "$routeId recover capability differs."
        Assert-AdapterTest ([bool]$loaded.descriptor.capabilities.exact_native_session -eq [bool]$route.exact_native_session) "$routeId exact_native_session differs."
        $entry = [IO.Path]::GetFullPath([string]$loaded.entrypoint)
        $root = [IO.Path]::GetFullPath($adapterRoot).TrimEnd('\')
        Assert-AdapterTest ($entry.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) 'Entrypoint escaped the adapter root.'
        $item = Get-Item -LiteralPath $entry -Force
        Assert-AdapterTest (-not $item.PSIsContainer) 'Entrypoint is not a file.'
        Assert-AdapterTest (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Entrypoint is a reparse point.'
        if ([bool]$route.start) {
            $start = New-TelephoneAdapterInvocation -Adapter $loaded -Operation start
            Assert-AdapterTest ($null -eq $start.native_session_id) 'start carried a native session id.'
            Assert-AdapterTest ($start.automatic_rerun -eq $false) 'start advertised automatic rerun.'
            Assert-AdapterTest ([bool]$start.exact_native_session -eq [bool]$route.exact_native_session) 'start did not copy exact_native_session.'
        } else {
            $startFailed = $false
            try { $null = New-TelephoneAdapterInvocation -Adapter $loaded -Operation start } catch { $startFailed = $true }
            Assert-AdapterTest $startFailed "$routeId start invocation was accepted."
        }
        $followFailed = $false
        try { $null = New-TelephoneAdapterInvocation -Adapter $loaded -Operation follow_up } catch { $followFailed = $true }
        Assert-AdapterTest $followFailed 'follow_up without a native session id was accepted.'
        if ([bool]$route.follow_up) {
            $follow = New-TelephoneAdapterInvocation -Adapter $loaded -Operation follow_up -NativeSessionId 'native-1'
            Assert-AdapterTest ([string]$follow.native_session_id -ceq 'native-1') 'follow_up lost the native session id.'
            Assert-AdapterTest ([bool]$follow.exact_native_session -eq [bool]$route.exact_native_session) 'follow_up did not copy exact_native_session.'
        } else {
            $followCapFailed = $false
            try { $null = New-TelephoneAdapterInvocation -Adapter $loaded -Operation follow_up -NativeSessionId 'native-1' } catch { $followCapFailed = $true }
            Assert-AdapterTest $followCapFailed "$routeId follow_up invocation was accepted."
        }
        if ([bool]$route.recover) {
            $recover = New-TelephoneAdapterInvocation -Adapter $loaded -Operation recover -NativeSessionId 'native-1'
            Assert-AdapterTest ([string]$recover.native_session_id -ceq 'native-1') 'recover lost the transport session id.'
            Assert-AdapterTest ([bool]$recover.exact_native_session -eq [bool]$route.exact_native_session) 'recover did not copy exact_native_session.'
        } else {
            $recoverFailed = $false
            try { $null = New-TelephoneAdapterInvocation -Adapter $loaded -Operation recover -NativeSessionId 'native-1' } catch { $recoverFailed = $true }
            Assert-AdapterTest $recoverFailed "$routeId recover invocation was accepted."
        }
        $validated += 1
    }
    Assert-AdapterTest ($validated -eq 8) 'Expected 8/8 descriptors to validate.'

    $coreHits = 0
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src\core') -File -Filter '*.ps1')) {
        $text = [IO.File]::ReadAllText($file.FullName)
        foreach ($routeId in @($expected.Keys)) {
            if ($text.Contains([string]$routeId)) { $coreHits += 1 }
        }
    }
    Assert-AdapterTest ($coreHits -eq 0) 'Core source branched on public route ids.'

    [ordered]@{
        success = $true
        descriptors_validated = $validated
        core_route_id_hits = $coreHits
        exact_native_session_truthful = 1
        assertions = $assertions
    } | ConvertTo-Json -Compress
} catch {
    [ordered]@{ success = $false; error = [string]$_.Exception.Message; assertions = $assertions } | ConvertTo-Json -Compress
    exit 1
}

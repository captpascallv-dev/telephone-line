# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$Profile,
    [string]$Resume,
    [string]$SessionOut,
    [string]$Task,
    [string]$Mode,
    [string]$Prompt,
    [string]$PromptFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not [string]::IsNullOrWhiteSpace($PromptFile)) {
    throw 'Headless PromptFile is not accepted.'
}
if (-not [string]::IsNullOrWhiteSpace($Mode)) {
    throw 'Headless -Mode is not accepted.'
}
if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
    throw 'Headless -Prompt is not accepted.'
}
if ([string]::IsNullOrWhiteSpace($Profile) -or $Profile -cne 'headless') { throw 'Headless profile only.' }
if ([string]::IsNullOrWhiteSpace($Task)) { throw 'Headless mode requires a prompt identity.' }
if ([string]::IsNullOrWhiteSpace($SessionOut)) { throw 'Headless session-out path is required.' }

$dshHome = [string]$env:DSH_HOME
if ([string]::IsNullOrWhiteSpace($dshHome) -or -not [IO.Directory]::Exists($dshHome)) {
    throw 'Contained DSH home is missing.'
}
$patchPath = Join-Path $dshHome 'profiles\headless\cordis.patch.yml'
$pluginDir = Join-Path $dshHome 'profiles\headless\plugins\telephone-line'
if (-not [IO.File]::Exists($patchPath)) { throw 'Contained DSH profile patch is missing.' }
$patchItem = Get-Item -LiteralPath $patchPath -Force
if (($patchItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Contained DSH profile patch is a reparse point.' }
if (-not [IO.Directory]::Exists($pluginDir)) { throw 'Contained DSH plugin directory is missing.' }
$pluginItem = Get-Item -LiteralPath $pluginDir -Force
if (($pluginItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Contained DSH plugin directory is a reparse point.' }

$patchText = [IO.File]::ReadAllText($patchPath)
if ($patchText -cnotmatch '(?m)^\s+provider:\s+([A-Za-z0-9._:-]+)\s*$') { throw 'Contained profile provider is missing.' }
$provider = [string]$Matches[1]
if ($patchText -cnotmatch '(?m)^\s+model:\s+([A-Za-z0-9._:-]+)\s*$') { throw 'Contained profile model is missing.' }
$model = [string]$Matches[1]
$reasoningEffort = ''
if ($patchText -cmatch '(?m)^\s+reasoningEffort:\s+([A-Za-z0-9._:-]+)\s*$') {
    $reasoningEffort = [string]$Matches[1]
}

$counter = $env:TELEPHONE_LINE_MOCK_HEADLESS_COUNTER
if (-not [string]::IsNullOrWhiteSpace($counter)) {
    $count = if ([IO.File]::Exists($counter)) { [int][IO.File]::ReadAllText($counter) } else { 0 }
    [IO.File]::WriteAllText($counter, [string]($count + 1), [Text.UTF8Encoding]::new($false))
}

$capture = $env:TELEPHONE_LINE_MOCK_HEADLESS_CAPTURE
if (-not [string]::IsNullOrWhiteSpace($capture)) {
    $captureValue = [ordered]@{
        used_mode_headless = $false
        used_prompt_argument = $true
        used_prompt_file = $false
        used_profile_headless = $true
        used_dsh_profile = $true
        provider = $provider
        model = $model
        reasoning_effort = $reasoningEffort
        resume_session_id = [string]$Resume
        launched_codex_cli = $false
        launched_grok_cli = $false
        launched_cursor_agent = $false
        child_harness_launched = $false
        plugin_contained = $true
        prompt_sentinel_present = $false
    }
    $sentinel = [string]$env:TELEPHONE_LINE_MOCK_PROMPT_SENTINEL
    if (-not [string]::IsNullOrWhiteSpace($sentinel) -and $Task.Contains($sentinel)) {
        $captureValue.prompt_sentinel_present = $true
    }
    [IO.File]::WriteAllText($capture, (($captureValue | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}

$statePath = $env:TELEPHONE_LINE_MOCK_HEADLESS_STATE
$state = [ordered]@{ native_session_id = ''; result_nonce = 0 }
if (-not [string]::IsNullOrWhiteSpace($statePath) -and [IO.File]::Exists($statePath)) {
    $loaded = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable -Depth 8
    if ($loaded -is [Collections.IDictionary]) {
        $state.native_session_id = [string]$loaded.native_session_id
        $state.result_nonce = [int]$loaded.result_nonce
    }
}

if ([string]::IsNullOrWhiteSpace($Resume)) {
    $state.native_session_id = 'dsh-native-' + [Guid]::NewGuid().ToString('N')
} else {
    if ([string]::IsNullOrWhiteSpace($state.native_session_id) -or $Resume -cne [string]$state.native_session_id) {
        throw 'Headless native session id does not match the frozen session.'
    }
}

$sentinel = [string]$env:TELEPHONE_LINE_MOCK_PROMPT_SENTINEL
if (-not [string]::IsNullOrWhiteSpace($sentinel) -and -not $Task.Contains($sentinel)) {
    throw 'Headless prompt sentinel is missing.'
}

$state.result_nonce = [int]$state.result_nonce + 1
if (-not [string]::IsNullOrWhiteSpace($statePath)) {
    $parent = [IO.Path]::GetDirectoryName($statePath)
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($statePath, (($state | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}

$sessionParent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($SessionOut))
if (-not [IO.Directory]::Exists($sessionParent)) { [IO.Directory]::CreateDirectory($sessionParent) | Out-Null }
$sessionRecord = [ordered]@{
    protocol_version = 'telephone-line-dsh-session-v1'
    native_session_id = [string]$state.native_session_id
    provider = $provider
    model = $model
    loop_owner = 'dsh'
}
[IO.File]::WriteAllText($SessionOut, (($sessionRecord | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
[Console]::Error.WriteLine('telephone-line-dsh-session:' + [string]$state.native_session_id)
[Console]::Error.WriteLine('telephone-line-dsh-loop-owner:dsh')
[Console]::Error.WriteLine('telephone-line-dsh-provider:' + $provider)
[Console]::Error.WriteLine('telephone-line-dsh-model:' + $model)
if (-not [string]::IsNullOrWhiteSpace($reasoningEffort)) {
    [Console]::Error.WriteLine('telephone-line-dsh-reasoning-effort:' + $reasoningEffort)
}
[Console]::Error.WriteLine('telephone-line-dsh-child-harness:false')
Write-Output ('dsh-result-' + [string]$state.result_nonce)
exit 0

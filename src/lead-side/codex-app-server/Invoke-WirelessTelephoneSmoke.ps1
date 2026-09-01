# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CodexCommand,
    [Parameter(Mandatory = $true)][string]$ScratchRoot,
    [switch]$AllowModelTurns,
    [ValidateRange(60, 3600)][int]$TerminalTimeoutSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexAppServerLead.Common.ps1')

function Wait-WirelessSmokeTerminal {
    param([Parameter(Mandatory = $true)][string]$StateRoot, [Parameter(Mandatory = $true)][string]$RunId)
    $paths = Get-CodexAppServerRunPaths -StateRoot $StateRoot -RunId $RunId
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TerminalTimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if ([IO.File]::Exists($paths.result)) {
            $result = Read-CodexAppServerValidated -Path $paths.result -SchemaName 'codex-app-server-lead-result'
            $state = Get-CodexAppServerDictString -Dict $result -Key 'state'
            if (Test-CodexAppServerTurnTerminalDisposition -Disposition $state) { return $result }
        }
        Start-Sleep -Milliseconds 200
    }
    throw "Wireless smoke turn did not reach an official terminal: $RunId"
}

function Stop-WirelessSmokeOwners {
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    $runs = Join-Path ([IO.Path]::GetFullPath($StateRoot)) 'runs'
    if (-not [IO.Directory]::Exists($runs)) { return }
    foreach ($run in [IO.Directory]::EnumerateDirectories($runs)) {
        foreach ($name in @('child.json', 'owner.json')) {
            $path = Join-Path $run $name
            if (-not [IO.File]::Exists($path)) { continue }
            try {
                $record = (Read-TelephoneJson -Path $path).value
                if (Test-TelephoneOwnerAlive -Owner $record) {
                    Stop-Process -Id ([int]$record.pid) -Force -ErrorAction SilentlyContinue
                }
            } catch { }
        }
    }
}

$root = [IO.Path]::GetFullPath($ScratchRoot).TrimEnd('\')
if (-not $AllowModelTurns) { throw 'Wireless smoke requires explicit -AllowModelTurns.' }
Assert-CodexAppServerStateOutsidePackage -StateRoot $root
if ([IO.File]::Exists($root) -or [IO.Directory]::Exists($root)) { throw 'Wireless smoke ScratchRoot must not exist.' }
[IO.Directory]::CreateDirectory($root) | Out-Null
$worktree = Join-Path $root 'worktree'
$state = Join-Path $root 'state'
[IO.Directory]::CreateDirectory($worktree) | Out-Null
[IO.Directory]::CreateDirectory($state) | Out-Null
$profilePath = Join-Path $root 'profile.json'
$bindingPath = Join-Path $root 'lead-binding.json'
$resumeBindingPath = Join-Path $root 'lead-binding-resume.json'
$firstPrompt = Join-Path $root 'first-turn.md'
$callbackPrompt = Join-Path $root 'callback-turn.md'
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($firstPrompt, "Respond with exactly WIRELESS_SMOKE_FIRST_TURN_OK. Do not call tools.`n", $utf8)
[IO.File]::WriteAllText($callbackPrompt, "Respond with exactly WIRELESS_SMOKE_CALLBACK_OK. Do not call tools.`n", $utf8)
$firstRun = 'wireless-smoke-first-' + [Guid]::NewGuid().ToString('N')
$callbackRun = 'wireless-smoke-callback-' + [Guid]::NewGuid().ToString('N')

try {
    $bound = Invoke-CodexAppServerBindProfile -CodexCommand $CodexCommand -OutputPath $profilePath
    $profile = $bound.profile
    $approved = Get-CodexAppServerApprovedCompatibilityEntry -License $profile
    if ($null -eq $approved) { throw 'Wireless smoke Codex version is not approved.' }
    $null = Assert-CodexAppServerProfileCurrent -Profile $profile -CodexCommand $CodexCommand

    $created = Invoke-CodexAppServerBuilderCore `
        -WorktreePath $worktree `
        -StateRoot $state `
        -BindingOutputPath $bindingPath `
        -CallbackTransport app-server `
        -CodexCommand $CodexCommand `
        -ProfilePath $profilePath `
        -PromptFile $firstPrompt `
        -RunId $firstRun
    if (-not [bool]$created.started -or [string]::IsNullOrWhiteSpace([string]$created.thread_id)) {
        throw 'Wireless smoke durable create did not start.'
    }
    $threadId = [string]$created.thread_id
    $firstResult = Wait-WirelessSmokeTerminal -StateRoot $state -RunId $firstRun
    if ((Get-CodexAppServerDictString -Dict $firstResult -Key 'state') -cne 'completed') {
        throw 'Wireless smoke first turn did not complete.'
    }

    $callback = Invoke-CodexAppServerWakeCore `
        -WorktreePath $worktree `
        -PromptFile $callbackPrompt `
        -ResumeSessionId $threadId `
        -RunId $callbackRun `
        -StateRoot $state `
        -CodexCommand $CodexCommand `
        -ProfilePath $profilePath
    if (-not [bool]$callback.started) { throw 'Wireless smoke exact callback did not start.' }
    $callbackResult = Wait-WirelessSmokeTerminal -StateRoot $state -RunId $callbackRun
    if ((Get-CodexAppServerDictString -Dict $callbackResult -Key 'state') -cne 'completed') {
        throw 'Wireless smoke callback turn did not complete.'
    }

    $resumed = Invoke-CodexAppServerBuilderCore `
        -WorktreePath $worktree `
        -StateRoot $state `
        -BindingOutputPath $resumeBindingPath `
        -CallbackTransport app-server `
        -CodexCommand $CodexCommand `
        -ResumeSessionId $threadId `
        -ProfilePath $profilePath
    if ([string]$resumed.thread_id -cne $threadId) { throw 'Wireless smoke restart resumed another thread.' }

    $drift = [ordered]@{}
    foreach ($key in @($profile.Keys)) { $drift[$key] = $profile[$key] }
    $drift.schema_fingerprint = '0' * 64
    $driftRejected = $false
    try { $null = Assert-CodexAppServerProfileCurrent -Profile $drift -CodexCommand $CodexCommand } catch { $driftRejected = $true }
    if (-not $driftRejected) { throw 'Wireless smoke accepted an unapproved profile.' }

    Write-CodexAppServerStdoutJson -Value ([ordered]@{
        protocol_version = 'telephone-line-wireless-smoke-result-v1'
        success = $true
        codex_version = [string]$profile.codex_version
        adapter_rule = [string]$approved.AdapterRule
        thread_id = $threadId
        checks = [ordered]@{
            qualification_preflight = $true
            durable_create_first_turn = $true
            exact_callback = $true
            restart_exact_resume = $true
            unknown_profile_fail_closed = $true
        }
        service_tier = 'default'
        absolute_task_timeout = $false
        scratch_root = $root
    })
    exit 0
} catch {
    Stop-WirelessSmokeOwners -StateRoot $state
    $failure = Get-CodexAppServerPublicFailure -Message ([string]$_.Exception.Message)
    Write-CodexAppServerStdoutJson -Value ([ordered]@{
        protocol_version = 'telephone-line-wireless-smoke-result-v1'
        success = $false
        error = [string]$failure.message
        code = [string]$failure.code
        scratch_root = $root
    })
    exit 2
}

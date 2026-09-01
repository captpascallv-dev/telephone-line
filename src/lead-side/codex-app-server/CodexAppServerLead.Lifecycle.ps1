# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest

function Get-CodexAppServerWorkerPath {
    [CmdletBinding()]
    param()
    $path = Join-Path $PSScriptRoot 'Invoke-CodexAppServerLeadWorker.ps1'
    return Assert-TelephoneRegularFilePath -Path $path -Label 'Codex app-server Lead worker'
}

function Assert-CodexAppServerSameText {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ([string]$Left -cne [string]$Right) {
        Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
    }
}

function Assert-CodexAppServerCallbackIdentity {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Expected,
        [AllowNull()][object]$Actual
    )
    if ($Expected -isnot [Collections.IDictionary] -or $Actual -isnot [Collections.IDictionary]) {
        Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
    }
    Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $Expected -Key 'path') -Right (Get-CodexAppServerDictString -Dict $Actual -Key 'path') -Label 'callback path'
    $leftBytes = Get-CodexAppServerDictObject -Dict $Expected -Key 'bytes'
    $rightBytes = Get-CodexAppServerDictObject -Dict $Actual -Key 'bytes'
    if ([int64]$leftBytes -ne [int64]$rightBytes) {
        Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
    }
    Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $Expected -Key 'sha256') -Right (Get-CodexAppServerDictString -Dict $Actual -Key 'sha256') -Label 'callback hash'
}

function Get-CodexAppServerStringList {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    $out = [Collections.Generic.List[string]]::new()
    if ($Value -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace($Value)) { $out.Add([string]$Value) }
    } elseif ($null -ne $Value) {
        foreach ($item in $Value) {
            if ($item -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$item)) {
                $out.Add([string]$item)
            }
        }
    }
    return [string[]]@($out)
}

function Assert-CodexAppServerBaselineSet {
    [CmdletBinding()]
    param([AllowNull()][object]$Left, [AllowNull()][object]$Right)
    $a = @(Get-CodexAppServerStringList -Value $Left)
    $b = @(Get-CodexAppServerStringList -Value $Right)
    if ($a.Count -ne $b.Count) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
    for ($i = 0; $i -lt $a.Count; $i++) {
        if ($a[$i] -cne $b[$i]) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
    }
}

function Test-CodexAppServerTurnTerminalDisposition {
    [CmdletBinding()]
    param([AllowNull()][string]$Disposition)
    return (
        $Disposition -ceq 'completed' -or
        $Disposition -ceq 'failed' -or
        $Disposition -ceq 'interrupted'
    )
}

function Test-CodexAppServerTransportLossMessage {
    [CmdletBinding()]
    param([AllowNull()][string]$Message)
    $text = [string]$Message
    return (
        $text.IndexOf('stdio closed', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $text.IndexOf('stdio read timed out', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $text.IndexOf('process is not running', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $text.IndexOf('process failed to start', [StringComparison]::OrdinalIgnoreCase) -ge 0
    )
}

function Get-CodexAppServerRunDisposition {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Paths)
    if (-not [IO.File]::Exists($Paths.run)) { return '' }
    try {
        $run = (Read-TelephoneJson -Path $Paths.run -SchemaName 'codex-app-server-lead-run').value
    } catch {
        if (-not [IO.File]::Exists($Paths.run)) { return '' }
        throw
    }
    return Get-CodexAppServerDictString -Dict $run -Key 'disposition'
}

function Test-CodexAppServerCompleteOfficialTerminal {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Paths)
    if (-not (
        [IO.File]::Exists($Paths.intent) -and
        [IO.File]::Exists($Paths.run) -and
        [IO.File]::Exists($Paths.bound_turn) -and
        [IO.File]::Exists($Paths.ack) -and
        [IO.File]::Exists($Paths.final)
    )) { return $false }
    $disp = Get-CodexAppServerRunDisposition -Paths $Paths
    if (-not (Test-CodexAppServerTurnTerminalDisposition -Disposition $disp)) { return $false }
    $finalText = ([IO.File]::ReadAllText($Paths.final)).Trim()
    return ($finalText -ceq $disp)
}

function Test-CodexAppServerProvenTerminal {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Paths)
    return (Test-CodexAppServerCompleteOfficialTerminal -Paths $Paths)
}

function Write-CodexAppServerFailureRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$ThreadId
    )
    $phaseNow = 'none'
    if ([IO.File]::Exists($Paths.run)) {
        try { $phaseNow = Get-CodexAppServerCallbackWritePhase -Paths $Paths } catch { $phaseNow = 'none' }
    }
    if ($phaseNow -ceq 'terminal_publishing' -or $phaseNow -ceq 'terminal') { return }
    if (Test-CodexAppServerProvenTerminal -Paths $Paths) { return }
    $dispNow = Get-CodexAppServerRunDisposition -Paths $Paths
    if (Test-CodexAppServerTurnTerminalDisposition -Disposition $dispNow) { return }
    $runId = [IO.Path]::GetFileName([string]$Paths.run_root)
    $phase = 'none'
    $disposition = 'in_progress'
    $turnId = ''
    if ([IO.File]::Exists($Paths.run)) {
        try {
            $run = Read-CodexAppServerValidated -Path $Paths.run -SchemaName 'codex-app-server-lead-run'
            $runId = Get-CodexAppServerDictString -Dict $run -Key 'run_id'
            $phase = Get-CodexAppServerDictString -Dict $run -Key 'callback_write_phase'
            $disposition = Get-CodexAppServerDictString -Dict $run -Key 'disposition'
            $turnId = Get-CodexAppServerDictString -Dict $run -Key 'selected_turn_id'
        } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($turnId) -and [IO.File]::Exists($Paths.bound_turn)) {
        try {
            $bound = Read-CodexAppServerValidated -Path $Paths.bound_turn -SchemaName 'codex-app-server-lead-bound-turn'
            $turnId = Get-CodexAppServerDictString -Dict $bound -Key 'turn_id'
        } catch { $turnId = '' }
    }
    $null = Write-CodexAppServerValidatedReplace -Path $Paths.failure -Value ([ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-failure-v1'
        category = [string]$Category
        code = [string]$Code
        run_id = [string]$runId
        run_root = [string]$Paths.run_root
        thread_id = [string]$ThreadId
        turn_id = [string]$turnId
        callback_write_phase = [string]$phase
        disposition = [string]$disposition
        at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }) -SchemaName 'codex-app-server-lead-failure' -WriterLabel 'failure-snapshot'
}

function Write-CodexAppServerLauncherResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value,
        [string]$WriterLabel = 'terminal-result'
    )
    $null = Write-CodexAppServerValidatedReplace -Path $Path -Value $Value -SchemaName 'codex-app-server-lead-result' -WriterLabel $WriterLabel
}

function Test-CodexAppServerResultForwardAllowed {
    [CmdletBinding()]
    param([AllowNull()][string]$From, [AllowNull()][string]$To)
    if ([string]$From -ceq [string]$To) { return $true }
    if ([string]$From -ceq 'in_progress') { return $true }
    if ([string]$From -ceq 'recovered' -and (Test-CodexAppServerTurnTerminalDisposition -Disposition $To)) { return $true }
    if ([string]$From -ceq 'recovery_required' -and ($To -ceq 'recovered' -or (Test-CodexAppServerTurnTerminalDisposition -Disposition $To))) { return $true }
    return $false
}

function Get-CodexAppServerAllowedResultStates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Phase,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Disposition
    )
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($Phase -ceq 'none') {
        if ($Disposition -ceq 'fallback_required_cli') { [void]$allowed.Add('fallback_required_cli') }
        [void]$allowed.Add('in_progress')
        [void]$allowed.Add('failed')
        return $allowed
    }
    if ($Phase -ceq 'terminal_publishing') {
        [void]$allowed.Add('in_progress')
        [void]$allowed.Add('recovered')
        [void]$allowed.Add('recovery_required')
        return $allowed
    }
    if ($Phase -ceq 'terminal') {
        if (Test-CodexAppServerTurnTerminalDisposition -Disposition $Disposition) {
            [void]$allowed.Add($Disposition)
            [void]$allowed.Add('in_progress')
            [void]$allowed.Add('recovered')
            [void]$allowed.Add('recovery_required')
        }
        return $allowed
    }
    if ($Phase -ceq 'turn_bound' -or $Phase -ceq 'acknowledged' -or $Phase -ceq 'turn_start_sending') {
        [void]$allowed.Add('recovery_required')
    }
    if ($Disposition -ceq 'recovery_required') { [void]$allowed.Add('recovery_required') }
    if ($Disposition -ceq 'recovered') {
        [void]$allowed.Add('recovered')
        [void]$allowed.Add('recovery_required')
    }
    [void]$allowed.Add('in_progress')
    return $allowed
}

function Assert-CodexAppServerDurableDeclarations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [AllowNull()][object]$Run,
        [string]$BoundTurnId = ''
    )
    $phase = 'none'
    $disposition = ''
    $selected = ''
    $canonicalRoot = [string]$Paths.run_root
    if ($null -ne $Run) {
        $phase = Get-CodexAppServerDictString -Dict $Run -Key 'callback_write_phase'
        $disposition = Get-CodexAppServerDictString -Dict $Run -Key 'disposition'
        $selected = Get-CodexAppServerDictString -Dict $Run -Key 'selected_turn_id'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $Run -Key 'run_id') -Right $RunId -Label 'run id'
    }
    $expectedTurn = $selected
    if ([string]::IsNullOrWhiteSpace($expectedTurn)) { $expectedTurn = $BoundTurnId }
    $preBindEmptyTurn = ([string]::IsNullOrWhiteSpace($expectedTurn) -and ($phase -ceq 'none' -or $phase -ceq 'turn_start_sending'))
    if ([IO.File]::Exists($Paths.result)) {
        $result = Read-CodexAppServerValidated -Path $Paths.result -SchemaName 'codex-app-server-lead-result'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $result -Key 'run_id') -Right $RunId -Label 'result run id'
        if (-not (Test-CodexAppServerCanonicalPathEqual -Left (Get-CodexAppServerDictString -Dict $result -Key 'run_root') -Right $canonicalRoot)) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        $resultState = Get-CodexAppServerDictString -Dict $result -Key 'state'
        $allowed = Get-CodexAppServerAllowedResultStates -Phase $phase -Disposition $disposition
        if (-not $allowed.Contains($resultState)) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        if ((Test-CodexAppServerTurnTerminalDisposition -Disposition $resultState) -and $phase -cne 'terminal' -and $phase -cne 'terminal_publishing') {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        if ($phase -ceq 'terminal_publishing' -and (Test-CodexAppServerTurnTerminalDisposition -Disposition $resultState)) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        if ($resultState -ceq 'recovery_required' -and -not [IO.File]::Exists($Paths.recovery) -and $disposition -cne 'recovered' -and $phase -cne 'terminal_publishing' -and -not (Test-CodexAppServerTurnTerminalDisposition -Disposition $disposition)) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
    }
    if ([IO.File]::Exists($Paths.recovery)) {
        $recovery = Read-CodexAppServerValidated -Path $Paths.recovery -SchemaName 'codex-app-server-lead-recovery'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $recovery -Key 'run_id') -Right $RunId -Label 'recovery run id'
        if (-not (Test-CodexAppServerCanonicalPathEqual -Left (Get-CodexAppServerDictString -Dict $recovery -Key 'run_root') -Right $canonicalRoot)) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $recovery -Key 'thread_id') -Right $ThreadId -Label 'recovery thread id'
        $recoveryTurn = Get-CodexAppServerDictString -Dict $recovery -Key 'turn_id'
        if ($preBindEmptyTurn) {
            if (-not [string]::IsNullOrWhiteSpace($recoveryTurn)) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
        } else {
            if ([string]::IsNullOrWhiteSpace($expectedTurn) -or $recoveryTurn -cne $expectedTurn) {
                Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
            }
        }
        $recoveryPhase = Get-CodexAppServerDictString -Dict $recovery -Key 'callback_write_phase'
        $recoveryState = Get-CodexAppServerDictString -Dict $recovery -Key 'state'
        $turnState = Get-CodexAppServerHistoryTurnState -Phase $phase -HasBound ([IO.File]::Exists($Paths.bound_turn)) -HasAck ([IO.File]::Exists($Paths.ack))
        if (-not (Test-CodexAppServerDurableHistoryAllowed -Kind 'recovery' -RecordedPhase $recoveryPhase -RecordedState $recoveryState -CurrentPhase $phase -CurrentDisposition $disposition -TurnState $turnState)) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
    }
    if ($disposition -ceq 'recovery_required' -and -not [IO.File]::Exists($Paths.recovery)) {
        Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
    }
    if ([IO.File]::Exists($Paths.failure)) {
        $failure = Read-CodexAppServerValidated -Path $Paths.failure -SchemaName 'codex-app-server-lead-failure'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $failure -Key 'run_id') -Right $RunId -Label 'failure run id'
        if (-not (Test-CodexAppServerCanonicalPathEqual -Left (Get-CodexAppServerDictString -Dict $failure -Key 'run_root') -Right $canonicalRoot)) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $failure -Key 'thread_id') -Right $ThreadId -Label 'failure thread id'
        $failureTurn = Get-CodexAppServerDictString -Dict $failure -Key 'turn_id'
        if ($preBindEmptyTurn) {
            if (-not [string]::IsNullOrWhiteSpace($failureTurn)) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
        } elseif (-not [string]::IsNullOrWhiteSpace($expectedTurn) -and $failureTurn -cne $expectedTurn) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        $code = Get-CodexAppServerDictString -Dict $failure -Key 'code'
        $category = Get-CodexAppServerDictString -Dict $failure -Key 'category'
        if (-not $script:CodexAppServerFailureCodeTable.Contains($code)) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        $spec = $script:CodexAppServerFailureCodeTable[$code]
        if ([string]$spec.category -cne $category) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
        $failurePhase = Get-CodexAppServerDictString -Dict $failure -Key 'callback_write_phase'
        $failureDisp = Get-CodexAppServerDictString -Dict $failure -Key 'disposition'
        $turnState = Get-CodexAppServerHistoryTurnState -Phase $phase -HasBound ([IO.File]::Exists($Paths.bound_turn)) -HasAck ([IO.File]::Exists($Paths.ack))
        if (-not (Test-CodexAppServerDurableHistoryAllowed -Kind 'failure' -Code $code -Category $category -RecordedPhase $failurePhase -RecordedDisposition $failureDisp -CurrentPhase $phase -CurrentDisposition $disposition -TurnState $turnState)) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
    }
}

function Write-CodexAppServerStderrEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Evidence
    )
    $null = Write-CodexAppServerJsonReplace -Path $Path -Value ([ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-stderr-evidence-v1'
        line_count = [int]$Evidence.line_count
        byte_count = [int64]$Evidence.byte_count
        code_count = [int]$Evidence.code_count
        category = 'drained'
    })
}

function Start-CodexAppServerStderrDrain {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Client)
    $sync = [hashtable]::Synchronized(@{
        line_count = 0
        byte_count = [int64]0
        code_count = 0
    })
    $Client.stderr_sync = $sync
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($reader, $sync)
        try {
            while ($true) {
                $line = $reader.ReadLine()
                if ($null -eq $line) { break }
                $sync['line_count'] = [int]$sync['line_count'] + 1
                $sync['byte_count'] = [int64]$sync['byte_count'] + [int64]([Text.UTF8Encoding]::new($false).GetByteCount([string]$line) + 1)
                $sync['code_count'] = [int]$sync['code_count'] + 1
            }
        } catch { }
    }).AddArgument($Client.process.StandardError).AddArgument($sync)
    $Client.stderr_ps = $ps
    $Client.stderr_rs = $rs
    $Client.stderr_handle = $ps.BeginInvoke()
}

function Stop-CodexAppServerStderrDrain {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Client,
        [string]$EvidencePath = ''
    )
    if ($null -eq $Client) { return }
    try {
        if ($null -ne $Client.stderr_handle -and $null -ne $Client.stderr_ps) {
            $null = $Client.stderr_ps.EndInvoke($Client.stderr_handle)
        }
    } catch { }
    try { if ($null -ne $Client.stderr_ps) { $Client.stderr_ps.Dispose() } } catch { }
    try { if ($null -ne $Client.stderr_rs) { $Client.stderr_rs.Dispose() } } catch { }
    $Client.stderr_ps = $null
    $Client.stderr_rs = $null
    $Client.stderr_handle = $null
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath) -and $null -ne $Client.stderr_sync) {
        Write-CodexAppServerStderrEvidence -Path $EvidencePath -Evidence $Client.stderr_sync
    }
}

function Assert-CodexAppServerDurableChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][object]$CallbackIdentity,
        [Parameter(Mandatory = $true)][string]$Marker,
        [Parameter(Mandatory = $true)][object]$Profile,
        [string]$ProfilePath = ''
    )
    $requestedCallback = [ordered]@{
        path = [string]$CallbackIdentity.path
        bytes = [int64]$CallbackIdentity.bytes
        sha256 = [string]$CallbackIdentity.sha256
    }
    $profileFile = if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) { [IO.Path]::GetFullPath($ProfilePath) } else { [string]$Paths.profile }
    $compat = Get-CodexAppServerCompatibilityIdentity -Profile $Profile -ProfilePath $profileFile
    $intent = $null
    if ([IO.File]::Exists($Paths.intent)) {
        $intent = Read-CodexAppServerValidated -Path $Paths.intent -SchemaName 'codex-app-server-lead-intent'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $intent -Key 'run_id') -Right $RunId -Label 'run id'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $intent -Key 'thread_id') -Right $ThreadId -Label 'thread id'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $intent -Key 'worktree') -Right $Worktree -Label 'worktree'
        Assert-CodexAppServerCallbackIdentity -Expected (Get-CodexAppServerDictObject -Dict $intent -Key 'callback') -Actual $requestedCallback
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $intent -Key 'wake_marker') -Right $Marker -Label 'wake marker'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $intent -Key 'profile_fingerprint') -Right ([string]$compat.profile_fingerprint) -Label 'profile fingerprint'
    $stored = [ordered]@{
        codex_command = Get-CodexAppServerDictString -Dict $intent -Key 'codex_command'
        codex_version = Get-CodexAppServerDictString -Dict $intent -Key 'codex_version'
        executable_sha256 = Get-CodexAppServerDictString -Dict $intent -Key 'executable_sha256'
        profile_fingerprint = Get-CodexAppServerDictString -Dict $intent -Key 'profile_fingerprint'
        profile_sha256 = Get-CodexAppServerDictString -Dict $intent -Key 'profile_sha256'
        service_tier = Get-CodexAppServerDictString -Dict $intent -Key 'service_tier'
    }
        if (-not (Assert-CodexAppServerCompatibilityEqual -Expected $compat -Actual $stored)) {
            if (Test-CodexAppServerFallbackWindowClosed -Paths $Paths) {
                Throw-CodexAppServerPublic -Code 'COMPATIBILITY_DRIFT'
            }
            New-CodexAppServerFallbackRequiredError
        }
    }
    $run = $null
    if ([IO.File]::Exists($Paths.run)) {
        $run = Read-CodexAppServerValidated -Path $Paths.run -SchemaName 'codex-app-server-lead-run'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $run -Key 'run_id') -Right $RunId -Label 'run id'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $run -Key 'thread_id') -Right $ThreadId -Label 'thread id'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $run -Key 'worktree') -Right $Worktree -Label 'worktree'
        Assert-CodexAppServerCallbackIdentity -Expected (Get-CodexAppServerDictObject -Dict $run -Key 'callback') -Actual $requestedCallback
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $run -Key 'wake_marker') -Right $Marker -Label 'wake marker'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $run -Key 'profile_fingerprint') -Right ([string]$compat.profile_fingerprint) -Label 'profile fingerprint'
        $storedRun = [ordered]@{
            codex_command = Get-CodexAppServerDictString -Dict $run -Key 'codex_command'
            codex_version = Get-CodexAppServerDictString -Dict $run -Key 'codex_version'
            executable_sha256 = Get-CodexAppServerDictString -Dict $run -Key 'executable_sha256'
            profile_fingerprint = Get-CodexAppServerDictString -Dict $run -Key 'profile_fingerprint'
            profile_sha256 = Get-CodexAppServerDictString -Dict $run -Key 'profile_sha256'
            service_tier = Get-CodexAppServerDictString -Dict $run -Key 'service_tier'
        }
        if (-not (Assert-CodexAppServerCompatibilityEqual -Expected $compat -Actual $storedRun)) {
            if (Test-CodexAppServerFallbackWindowClosed -Paths $Paths) {
                Throw-CodexAppServerPublic -Code 'COMPATIBILITY_DRIFT'
            }
            New-CodexAppServerFallbackRequiredError
        }
        if ($null -ne $intent -and $intent.Contains('baseline_turn_ids') -and (Test-CodexAppServerJsonArray -Value $intent.baseline_turn_ids)) {
            Assert-CodexAppServerBaselineSet -Left $intent.baseline_turn_ids -Right (Get-CodexAppServerDictObject -Dict $run -Key 'baseline_turn_ids')
        }
    }
    $boundTurnId = ''
    if ([IO.File]::Exists($Paths.bound_turn)) {
        $bound = Read-CodexAppServerValidated -Path $Paths.bound_turn -SchemaName 'codex-app-server-lead-bound-turn'
        $boundThread = Get-CodexAppServerDictString -Dict $bound -Key 'thread_id'
        $boundTurnId = Get-CodexAppServerDictString -Dict $bound -Key 'turn_id'
        $boundState = Get-CodexAppServerDictString -Dict $bound -Key 'state'
        if ([string]::IsNullOrWhiteSpace($boundThread) -or [string]::IsNullOrWhiteSpace($boundTurnId) -or [string]::IsNullOrWhiteSpace($boundState)) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        Assert-CodexAppServerSameText -Left $boundThread -Right $ThreadId -Label 'bound thread id'
        if ($null -ne $run) {
            $selected = Get-CodexAppServerDictString -Dict $run -Key 'selected_turn_id'
            if (-not [string]::IsNullOrWhiteSpace($selected)) {
                Assert-CodexAppServerSameText -Left $selected -Right $boundTurnId -Label 'selected turn id'
            }
        }
    }
    if ([IO.File]::Exists($Paths.ack)) {
        $ack = Read-CodexAppServerValidated -Path $Paths.ack -SchemaName 'codex-app-server-lead-ack'
        $ackSession = Get-CodexAppServerDictString -Dict $ack -Key 'session_id'
        $ackTurn = Get-CodexAppServerDictString -Dict $ack -Key 'turn_id'
        if ([string]::IsNullOrWhiteSpace($ackSession) -or [string]::IsNullOrWhiteSpace($ackTurn)) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        Assert-CodexAppServerSameText -Left $ackSession -Right $ThreadId -Label 'ack session'
        if (-not [string]::IsNullOrWhiteSpace($boundTurnId)) {
            Assert-CodexAppServerSameText -Left $ackTurn -Right $boundTurnId -Label 'ack turn'
        }
        if ($null -ne $run) {
            $selected = Get-CodexAppServerDictString -Dict $run -Key 'selected_turn_id'
            if (-not [string]::IsNullOrWhiteSpace($selected)) {
                Assert-CodexAppServerSameText -Left $ackTurn -Right $selected -Label 'ack selected turn'
            }
        }
    }
    if ([IO.File]::Exists($Paths.owner)) {
        $null = Read-CodexAppServerValidated -Path $Paths.owner -SchemaName 'codex-app-server-lead-owner' -Code 'OWNER_INVALID'
    }
    if ([IO.File]::Exists($Paths.child)) {
        $null = Read-CodexAppServerValidated -Path $Paths.child -SchemaName 'codex-app-server-lead-child'
    }
    Assert-CodexAppServerDurableDeclarations -Paths $Paths -RunId $RunId -ThreadId $ThreadId -Run $run -BoundTurnId $boundTurnId
    Assert-CodexAppServerPhaseTable -Paths $Paths -Run $run -BoundTurnId $boundTurnId
}

function Assert-CodexAppServerPhaseTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [AllowNull()][object]$Run,
        [string]$BoundTurnId = ''
    )
    $hasIntent = [IO.File]::Exists($Paths.intent)
    $hasRun = [IO.File]::Exists($Paths.run)
    $hasBound = [IO.File]::Exists($Paths.bound_turn)
    $hasAck = [IO.File]::Exists($Paths.ack)
    $hasFinal = [IO.File]::Exists($Paths.final)
    $hasRecovery = [IO.File]::Exists($Paths.recovery)
    if ($hasRun -and -not $hasIntent) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
    if ($hasBound -and (-not $hasIntent -or -not $hasRun)) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
    if ($hasAck -and (-not $hasIntent -or -not $hasRun -or -not $hasBound)) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
    if ($hasFinal -and (-not $hasIntent -or -not $hasRun -or -not $hasBound -or -not $hasAck)) {
        Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
    }
    $selected = ''
    $runDisposition = ''
    $phase = 'none'
    $fallback = ''
    if ($hasRun) {
        if ($null -eq $Run) { $Run = Read-CodexAppServerValidated -Path $Paths.run -SchemaName 'codex-app-server-lead-run' }
        $selected = Get-CodexAppServerDictString -Dict $Run -Key 'selected_turn_id'
        $runDisposition = Get-CodexAppServerDictString -Dict $Run -Key 'disposition'
        $phase = Get-CodexAppServerDictString -Dict $Run -Key 'callback_write_phase'
        $fallback = Get-CodexAppServerDictString -Dict $Run -Key 'fallback_required'
        $terminalTarget = Get-CodexAppServerDictString -Dict $Run -Key 'terminal_target'
        if (-not $script:CodexAppServerCallbackWritePhases.Contains($phase)) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
    } else {
        $terminalTarget = ''
    }
    $boundState = ''
    if ($hasBound) {
        $bound = Read-CodexAppServerValidated -Path $Paths.bound_turn -SchemaName 'codex-app-server-lead-bound-turn'
        $boundState = Get-CodexAppServerDictString -Dict $bound -Key 'state'
        if ([string]::IsNullOrWhiteSpace($BoundTurnId)) {
            $BoundTurnId = Get-CodexAppServerDictString -Dict $bound -Key 'turn_id'
        }
    }
    $ackTurn = ''
    if ($hasAck) {
        $ack = Read-CodexAppServerValidated -Path $Paths.ack -SchemaName 'codex-app-server-lead-ack'
        $ackTurn = Get-CodexAppServerDictString -Dict $ack -Key 'turn_id'
        if (-not [string]::IsNullOrWhiteSpace($BoundTurnId)) {
            Assert-CodexAppServerSameText -Left $ackTurn -Right $BoundTurnId -Label 'ack turn'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($selected)) {
        if (-not $hasBound -or -not $hasAck) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
        Assert-CodexAppServerSameText -Left $selected -Right $BoundTurnId -Label 'selected turn id'
        Assert-CodexAppServerSameText -Left $selected -Right $ackTurn -Label 'selected ack turn'
    }
    if ($hasAck -and [string]::IsNullOrWhiteSpace($BoundTurnId)) {
        Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
    }
    if ($hasBound -and -not $hasAck) {
        if ($boundState -cne 'active') { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
        if ($phase -cne 'turn_bound' -and $phase -cne 'turn_start_sending') {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        if (-not [string]::IsNullOrWhiteSpace($selected)) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
        if ($runDisposition -cne 'in_progress' -and $runDisposition -cne 'recovery_required' -and $runDisposition -cne 'recovered') {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
    }
    if (-not $hasRun) {
        if ($hasBound -or $hasAck -or $hasFinal) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
        return
    }
    if ($phase -cne 'terminal_publishing' -and $phase -cne 'terminal' -and -not [string]::IsNullOrWhiteSpace($terminalTarget)) {
        Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
    }
    switch ($phase) {
        'none' {
            if ($hasBound -or $hasAck -or $hasFinal -or -not [string]::IsNullOrWhiteSpace($selected)) {
                Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
            }
            if ($runDisposition -ceq 'fallback_required_cli') {
                if ($fallback -cne 'cli') { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
            } elseif ($runDisposition -cne 'in_progress') {
                Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
            } elseif ($fallback -cne '') {
                Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
            }
        }
        'turn_start_sending' {
            if ($hasAck -or $hasFinal -or -not [string]::IsNullOrWhiteSpace($selected)) {
                Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
            }
        if ($hasBound -and $boundState -cne 'active') { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
        if ($fallback -ceq 'cli') { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
        if ($runDisposition -cne 'in_progress' -and $runDisposition -cne 'recovery_required' -and $runDisposition -cne 'recovered') {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        if ($runDisposition -ceq 'recovery_required' -and -not $hasRecovery) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        }
        'turn_bound' {
            if (-not $hasBound -or $hasFinal) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
            if ($fallback -ceq 'cli') { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
            if (-not [string]::IsNullOrWhiteSpace($selected)) {
                if (-not $hasAck) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
                Assert-CodexAppServerSameText -Left $selected -Right $BoundTurnId -Label 'selected turn id'
            }
            if ($boundState -cne 'active') { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
            if ($runDisposition -cne 'in_progress' -and $runDisposition -cne 'recovery_required' -and $runDisposition -cne 'recovered') {
                Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
            }
            if ($runDisposition -ceq 'recovery_required' -and -not $hasRecovery) {
                Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
            }
        }
        'acknowledged' {
            if (-not $hasBound -or -not $hasAck -or $hasFinal) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
            if ($fallback -ceq 'cli') { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
            if (-not [string]::IsNullOrWhiteSpace($terminalTarget)) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
            if ($boundState -cnotin @('active', 'pending', 'recovery_required')) {
                Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
            }
            if ($runDisposition -cnotin @('in_progress', 'recovered', 'recovery_required')) {
                Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
            }
            if ($runDisposition -ceq 'recovery_required' -and -not $hasRecovery) {
                Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
            }
        }
        'terminal_publishing' {
            if (-not $hasBound -or -not $hasAck) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
            if ($fallback -ceq 'cli') { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
            if (-not (Test-CodexAppServerTurnTerminalDisposition -Disposition $terminalTarget)) {
                Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
            }
            if ([string]::IsNullOrWhiteSpace($selected) -or $selected -cne $BoundTurnId) {
                Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
            }
            if ($runDisposition -cnotin @('in_progress', 'recovered')) {
                Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
            }
            if ($hasFinal) {
                $finalText = ([IO.File]::ReadAllText($Paths.final)).Trim()
                if ($finalText -cne $terminalTarget) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
                if ($boundState -cnotin @('active', 'pending', 'recovery_required', $terminalTarget)) {
                    Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
                }
            } else {
                if ($boundState -cnotin @('active', 'pending', 'recovery_required')) {
                    Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
                }
            }
        }
        'terminal' {
            if (-not $hasBound -or -not $hasAck -or -not $hasFinal) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
            if ($fallback -ceq 'cli') { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
            if (-not (Test-CodexAppServerTurnTerminalDisposition -Disposition $runDisposition)) {
                Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
            }
            if ($boundState -cne $runDisposition) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
            if ([string]::IsNullOrWhiteSpace($selected) -or $selected -cne $BoundTurnId) {
                Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
            }
            if ($terminalTarget -cne $runDisposition) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
            $finalText = ([IO.File]::ReadAllText($Paths.final)).Trim()
            if ($finalText -cne $runDisposition) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
        }
        default { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
    }
    if (Test-CodexAppServerTurnTerminalDisposition -Disposition $runDisposition) {
        if ($phase -cne 'terminal') { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
    }
    if ($hasFinal) {
        $finalText = ([IO.File]::ReadAllText($Paths.final)).Trim()
        if (-not (Test-CodexAppServerTurnTerminalDisposition -Disposition $finalText)) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        if ($phase -ceq 'terminal') {
            if ($finalText -cne $runDisposition) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
        } elseif ($phase -ceq 'terminal_publishing') {
            if ($finalText -cne $terminalTarget) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
        } else {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
    }
}

function Test-CodexAppServerUserMessageType {
    [CmdletBinding()]
    param([AllowNull()][string]$Type)
    return ($Type -ceq 'userMessage')
}

function Assert-CodexAppServerByteRange {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    Assert-CodexAppServerExactKeys -Dict $Value -Required $script:CodexAppServerByteRangeKeys -Allowed $script:CodexAppServerByteRangeKeys
    foreach ($key in @('start', 'end')) {
        if (-not (Test-CodexAppServerJsonInteger -Value $Value[$key])) {
            Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
        }
    }
}

function Assert-CodexAppServerTextElement {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    Assert-CodexAppServerExactKeys -Dict $Value -Required $script:CodexAppServerTextElementKeys -Allowed $script:CodexAppServerTextElementKeys
    Assert-CodexAppServerByteRange -Value $Value['byteRange']
    $placeholder = $Value['placeholder']
    if (-not (Test-CodexAppServerJsonNull -Value $placeholder) -and -not (Test-CodexAppServerJsonString -Value $placeholder)) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
}

function Assert-CodexAppServerUserInputText {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    Assert-CodexAppServerExactKeys -Dict $Value -Required $script:CodexAppServerUserInputTextKeys -Allowed $script:CodexAppServerUserInputTextKeys
    if ((Get-CodexAppServerDictString -Dict $Value -Key 'type') -cne 'text') {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    if (-not (Test-CodexAppServerJsonString -Value $Value['text'])) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    $elements = $Value['text_elements']
    if (-not (Test-CodexAppServerJsonArray -Value $elements)) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    foreach ($el in @($elements)) {
        Assert-CodexAppServerTextElement -Value $el
    }
}

function Assert-CodexAppServerOptionalImageDetail {
    [CmdletBinding()]
    param([AllowNull()][object]$Dict)
    if ($Dict -isnot [Collections.IDictionary] -or -not $Dict.Contains('detail')) { return }
    $detail = $Dict['detail']
    if (-not (Test-CodexAppServerJsonString -Value $detail) -or -not $script:CodexAppServerImageDetailAllowlist.Contains([string]$detail)) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
}

function Assert-CodexAppServerUserInputMember {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    if ($Value -isnot [Collections.IDictionary]) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
    $type = Get-CodexAppServerDictString -Dict $Value -Key 'type'
    if ($script:CodexAppServerUserInputAliasTypes.Contains($type) -or [string]::IsNullOrWhiteSpace($type)) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    switch ($type) {
        'text' { Assert-CodexAppServerUserInputText -Value $Value }
        'image' {
            Assert-CodexAppServerExactKeys -Dict $Value -Required @('type', 'url') -Allowed @('type', 'url', 'detail')
            if (-not (Test-CodexAppServerJsonString -Value $Value['url'])) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
            Assert-CodexAppServerOptionalImageDetail -Dict $Value
        }
        'localImage' {
            Assert-CodexAppServerExactKeys -Dict $Value -Required @('type', 'path') -Allowed @('type', 'path', 'detail')
            if (-not (Test-CodexAppServerJsonString -Value $Value['path'])) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
            Assert-CodexAppServerOptionalImageDetail -Dict $Value
        }
        'audio' {
            Assert-CodexAppServerExactKeys -Dict $Value -Required @('type', 'url') -Allowed @('type', 'url')
            if (-not (Test-CodexAppServerJsonString -Value $Value['url'])) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
        }
        'localAudio' {
            Assert-CodexAppServerExactKeys -Dict $Value -Required @('type', 'path') -Allowed @('type', 'path')
            if (-not (Test-CodexAppServerJsonString -Value $Value['path'])) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
        }
        'skill' {
            Assert-CodexAppServerExactKeys -Dict $Value -Required @('type', 'name', 'path') -Allowed @('type', 'name', 'path')
            if (-not (Test-CodexAppServerJsonString -Value $Value['name']) -or -not (Test-CodexAppServerJsonString -Value $Value['path'])) {
                Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
            }
        }
        'mention' {
            Assert-CodexAppServerExactKeys -Dict $Value -Required @('type', 'name', 'path') -Allowed @('type', 'name', 'path')
            if (-not (Test-CodexAppServerJsonString -Value $Value['name']) -or -not (Test-CodexAppServerJsonString -Value $Value['path'])) {
                Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
            }
        }
        default { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
    }
}

function Assert-CodexAppServerUserMessageItem {
    [CmdletBinding()]
    param([AllowNull()][object]$Item)
    if ($Item -isnot [Collections.IDictionary]) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
    Assert-CodexAppServerExactKeys -Dict $Item -Required $script:CodexAppServerUserMessageItemKeys -Allowed $script:CodexAppServerUserMessageItemKeys
    if ((Get-CodexAppServerDictString -Dict $Item -Key 'type') -cne 'userMessage') {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    $id = $Item['id']
    if (-not (Test-CodexAppServerJsonString -Value $id) -or [string]::IsNullOrWhiteSpace([string]$id)) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    $clientId = $Item['clientId']
    if (-not (Test-CodexAppServerJsonNull -Value $clientId) -and -not (Test-CodexAppServerJsonString -Value $clientId)) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    $content = $Item['content']
    if (-not (Test-CodexAppServerJsonArray -Value $content)) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    foreach ($part in @($content)) {
        Assert-CodexAppServerUserInputMember -Value $part
    }
}

function Get-CodexAppServerNodeTextValues {
    [CmdletBinding()]
    param([AllowNull()][object]$Node)
    $texts = [Collections.Generic.List[string]]::new()
    if ($Node -is [string]) {
        if (-not [string]::IsNullOrEmpty($Node)) { $texts.Add([string]$Node) }
        return [string[]]@($texts)
    }
    if ($Node -isnot [Collections.IDictionary]) { return [string[]]@() }
    $direct = Get-CodexAppServerDictString -Dict $Node -Key 'text'
    if (-not [string]::IsNullOrEmpty($direct)) { $texts.Add($direct) }
    foreach ($part in @(Get-CodexAppServerDictObject -Dict $Node -Key 'content')) {
        if ($part -is [string] -and -not [string]::IsNullOrEmpty($part)) { $texts.Add([string]$part); continue }
        if ($part -isnot [Collections.IDictionary]) { continue }
        $ptype = Get-CodexAppServerDictString -Dict $part -Key 'type'
        if ($ptype -ceq 'text') {
            $t = Get-CodexAppServerDictString -Dict $part -Key 'text'
            if (-not [string]::IsNullOrEmpty($t)) { $texts.Add($t) }
        }
    }
    return [string[]]@($texts)
}

function Get-CodexAppServerUserInputTexts {
    [CmdletBinding()]
    param([AllowNull()][object]$Turn)
    $texts = [Collections.Generic.List[string]]::new()
    if ($Turn -isnot [Collections.IDictionary]) {
        Write-Output -NoEnumerate -InputObject ([string[]]@())
        return
    }
    $items = Get-CodexAppServerDictObject -Dict $Turn -Key 'items'
    if (Test-CodexAppServerJsonNull -Value $items) {
        Write-Output -NoEnumerate -InputObject ([string[]]@())
        return
    }
    if (-not (Test-CodexAppServerJsonArray -Value $items)) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    foreach ($item in @($items)) {
        if ($item -isnot [Collections.IDictionary]) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
        $type = Get-CodexAppServerDictString -Dict $item -Key 'type'
        if ($script:CodexAppServerUserInputAliasTypes.Contains($type)) {
            Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
        }
        if (-not (Test-CodexAppServerUserMessageType -Type $type)) { continue }
        Assert-CodexAppServerUserMessageItem -Item $item
        foreach ($part in @($item['content'])) {
            if ((Get-CodexAppServerDictString -Dict $part -Key 'type') -cne 'text') { continue }
            $texts.Add([string]$part['text'])
        }
    }
    Write-Output -NoEnumerate -InputObject ([string[]]@($texts))
}

function Test-CodexAppServerExactUserInput {
    [CmdletBinding()]
    param([AllowNull()][object]$Turn, [Parameter(Mandatory = $true)][string]$ExpectedText)
    foreach ($text in @(Get-CodexAppServerUserInputTexts -Turn $Turn)) {
        if ([string]$text -ceq [string]$ExpectedText) { return $true }
    }
    return $false
}

function Find-CodexAppServerMatchingTurns {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Thread,
        [Parameter(Mandatory = $true)][string]$Marker,
        [AllowEmptyCollection()][object]$BaselineTurnIds,
        [string]$ExpectedText = ''
    )
    $baseline = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in @(Get-CodexAppServerStringList -Value $BaselineTurnIds)) {
        [void]$baseline.Add([string]$id)
    }
    $matches = [Collections.Generic.List[object]]::new()
    $unexplained = [Collections.Generic.List[string]]::new()
    if ($Thread -isnot [Collections.IDictionary]) {
        return [ordered]@{ matches = @(); unexplained = @() }
    }
    foreach ($turn in (Get-CodexAppServerJsonArrayItems -Value (Get-CodexAppServerDictObject -Dict $Thread -Key 'turns'))) {
        if ($turn -isnot [Collections.IDictionary]) { continue }
        $turnId = Get-CodexAppServerDictString -Dict $turn -Key 'id'
        $hasMarker = $false
        $extracted = Get-CodexAppServerUserInputTexts -Turn $turn
        if ($extracted -is [string]) { $extracted = [string[]](, [string]$extracted) }
        else { $extracted = @($extracted | ForEach-Object { [string]$_ }) }
        foreach ($text in $extracted) {
            if (Test-CodexAppServerTextHasMarker -Text ([string]$text) -Marker $Marker) {
                $hasMarker = $true
                break
            }
        }
        if ($hasMarker) {
            if ([string]::IsNullOrWhiteSpace($turnId)) { throw 'Wake-marker turn is missing a turn id.' }
            if (
                -not [string]::IsNullOrWhiteSpace($ExpectedText) -and
                -not (Test-CodexAppServerExactUserInput -Turn $turn -ExpectedText $ExpectedText)
            ) {
                throw 'Multiple or conflicting wake-marker turns were present.'
            }
            $matches.Add([ordered]@{ turn_id = $turnId; turn = $turn })
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($turnId) -and -not $baseline.Contains($turnId)) {
            $unexplained.Add($turnId)
        }
    }
    return [ordered]@{
        matches = @($matches)
        unexplained = @($unexplained)
    }
}

function Get-CodexAppServerPendingFlag {
    [CmdletBinding()]
    param([AllowNull()][string]$Method)
    if ([string]$Method -match 'requestApproval$') { return 'waitingOnApproval' }
    if ([string]$Method -match 'requestUserInput$') { return 'waitingOnUserInput' }
    return ''
}

function Add-CodexAppServerPending {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Id
    )
    if (-not $script:CodexAppServerPendingMethods.Contains($Method)) { return $false }
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    foreach ($item in @($Client.pending)) {
        if ([string]$item.id -ceq $Id) { return $true }
    }
    $Client.pending.Add([ordered]@{ method = $Method; id = $Id })
    $flag = Get-CodexAppServerPendingFlag -Method $Method
    $flags = [Collections.Generic.List[string]]::new()
    foreach ($existing in (Get-CodexAppServerStringRecords -Value $Client.last_status.active_flags)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$existing)) { $flags.Add([string]$existing) }
    }
    if (-not [string]::IsNullOrWhiteSpace($flag) -and $flags -notcontains $flag) { $flags.Add($flag) }
    $Client.last_status = [ordered]@{ status = 'active'; active_flags = @($flags) }
    return $true
}

function Resolve-CodexAppServerPending {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [string]$RequestId
    )
    if ([string]::IsNullOrWhiteSpace($RequestId)) { return }
    $kept = [Collections.Generic.List[object]]::new()
    foreach ($item in @($Client.pending)) {
        if ([string]$item.id -cne $RequestId) { $kept.Add($item) }
    }
    $Client.pending = $kept
    $flags = [Collections.Generic.List[string]]::new()
    foreach ($item in @($Client.pending)) {
        $flag = Get-CodexAppServerPendingFlag -Method ([string]$item.method)
        if (-not [string]::IsNullOrWhiteSpace($flag) -and $flags -notcontains $flag) { $flags.Add($flag) }
    }
    $status = Get-CodexAppServerDictString -Dict $Client.last_status -Key 'status'
    if ([string]::IsNullOrWhiteSpace($status)) { $status = 'active' }
    $Client.last_status = [ordered]@{ status = $status; active_flags = @($flags) }
}

function Get-CodexAppServerInboundThreadId {
    [CmdletBinding()]
    param([AllowNull()][object]$Message)
    if ($Message -isnot [Collections.IDictionary]) { return '' }
    $params = Get-CodexAppServerDictObject -Dict $Message -Key 'params'
    if ($params -isnot [Collections.IDictionary]) { return '' }
    $tid = Get-CodexAppServerDictString -Dict $params -Key 'threadId'
    if (-not [string]::IsNullOrWhiteSpace($tid)) { return $tid }
    $thread = Get-CodexAppServerDictObject -Dict $params -Key 'thread'
    return Get-CodexAppServerDictString -Dict $thread -Key 'id'
}

function Get-CodexAppServerInboundTurnId {
    [CmdletBinding()]
    param([AllowNull()][object]$Message)
    if ($Message -isnot [Collections.IDictionary]) { return '' }
    $params = Get-CodexAppServerDictObject -Dict $Message -Key 'params'
    if ($params -isnot [Collections.IDictionary]) { return '' }
    $turn = Get-CodexAppServerDictObject -Dict $params -Key 'turn'
    if ($turn -is [Collections.IDictionary]) {
        $idFromTurn = Get-CodexAppServerDictString -Dict $turn -Key 'id'
        if (-not [string]::IsNullOrWhiteSpace($idFromTurn)) { return $idFromTurn }
    }
    $turnId = Get-CodexAppServerDictString -Dict $params -Key 'turnId'
    if (-not [string]::IsNullOrWhiteSpace($turnId)) { return $turnId }
    return ''
}

function Test-CodexAppServerPendingContains {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][string]$RequestId
    )
    if ([string]::IsNullOrWhiteSpace($RequestId)) { return $false }
    foreach ($item in @($Client.pending)) {
        if ([string]$item.id -ceq $RequestId) { return $true }
    }
    return $false
}

function ConvertTo-CodexAppServerTurnDisposition {
    [CmdletBinding()]
    param([AllowNull()][object]$Turn)
    if ($Turn -isnot [Collections.IDictionary]) { return '' }
    $status = Get-CodexAppServerDictString -Dict $Turn -Key 'status'
    if (-not $script:CodexAppServerOfficialTerminals.Contains($status)) { return '' }
    return $status
}

function Test-CodexAppServerInboundExactKeys {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Dict,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Allowed,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Required
    )
    if ($Dict -isnot [Collections.IDictionary]) { return $false }
    foreach ($need in @($Required)) {
        if (-not $Dict.Contains($need)) { return $false }
    }
    foreach ($key in @($Dict.Keys)) {
        if (@($Allowed) -notcontains [string]$key) { return $false }
    }
    return $true
}

function Test-CodexAppServerNotificationEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [AllowNull()][object]$Message
    )
    $entry = Get-CodexAppServerApprovedCompatibilityEntry -License (Get-CodexAppServerCompatibilityLicenseFromClient -Client $Client)
    if ($null -eq $entry) { return $false }
    $mode = [string]$entry.NotificationEnvelopeMode
    $allowed = @($script:CodexAppServerNotificationEnvelopeKeys)
    if ($mode -ceq 'emitted-at-ms-optional') {
        $allowed = @($allowed + 'emittedAtMs')
    } elseif ($mode -cne 'strict-v0147') {
        return $false
    }
    if (-not (Test-CodexAppServerInboundExactKeys -Dict $Message -Required $script:CodexAppServerNotificationEnvelopeKeys -Allowed $allowed)) {
        return $false
    }
    if ($Message.Contains('emittedAtMs')) {
        $raw = $Message['emittedAtMs']
        if (-not (Test-CodexAppServerJsonInteger -Value $raw)) { return $false }
        try {
            if ([int64]$raw -lt 0) { return $false }
        } catch {
            return $false
        }
    }
    return $true
}

function Test-CodexAppServerPendingParams {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [AllowNull()][object]$Params
    )
    if (-not $script:CodexAppServerPendingParamSpecs.Contains($Method)) { return $false }
    $spec = $script:CodexAppServerPendingParamSpecs[$Method]
    return (Test-CodexAppServerInboundExactKeys -Dict $Params -Required @($spec.Required) -Allowed @($spec.Allowed))
}

function Apply-CodexAppServerInboundMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [AllowNull()][object]$Message,
        [string]$BoundTurnId = '',
        [string]$BoundThreadId = ''
    )
    if ($Message -isnot [Collections.IDictionary]) { return [ordered]@{ kind = 'ignored' } }
    if ([string]::IsNullOrWhiteSpace($BoundThreadId) -and $Client.Contains('bound_thread_id')) {
        $BoundThreadId = [string]$Client.bound_thread_id
    }
    if ([string]::IsNullOrWhiteSpace($BoundTurnId) -and $Client.Contains('bound_turn_id')) {
        $BoundTurnId = [string]$Client.bound_turn_id
    }
    $method = Get-CodexAppServerDictString -Dict $Message -Key 'method'
    $id = Get-CodexAppServerDictString -Dict $Message -Key 'id'
    $params = Get-CodexAppServerDictObject -Dict $Message -Key 'params'
    $inboundThread = Get-CodexAppServerInboundThreadId -Message $Message
    $inboundTurn = Get-CodexAppServerInboundTurnId -Message $Message
    if ($script:CodexAppServerPendingMethods.Contains($method) -and -not [string]::IsNullOrWhiteSpace($id)) {
        if (-not (Test-CodexAppServerInboundExactKeys -Dict $Message -Required $script:CodexAppServerPendingEnvelopeKeys -Allowed $script:CodexAppServerPendingEnvelopeKeys)) {
            return [ordered]@{ kind = 'ignored_request' }
        }
        if ([string]::IsNullOrWhiteSpace($BoundThreadId) -or [string]::IsNullOrWhiteSpace($BoundTurnId)) {
            return [ordered]@{ kind = 'ignored_request' }
        }
        if (-not (Test-CodexAppServerPendingParams -Method $method -Params $params)) {
            return [ordered]@{ kind = 'ignored_request' }
        }
        if ([string]::IsNullOrWhiteSpace($inboundThread) -or $inboundThread -cne $BoundThreadId) {
            return [ordered]@{ kind = 'ignored_request' }
        }
        if ([string]::IsNullOrWhiteSpace($inboundTurn) -or $inboundTurn -cne $BoundTurnId) {
            return [ordered]@{ kind = 'ignored_request' }
        }
        $accepted = Add-CodexAppServerPending -Client $Client -Method $method -Id $id
        return [ordered]@{ kind = $(if ($accepted) { 'pending' } else { 'ignored_request' }) }
    }
    if ($method -ceq 'thread/status/changed') {
        if (-not (Test-CodexAppServerNotificationEnvelope -Client $Client -Message $Message)) {
            return [ordered]@{ kind = 'ignored' }
        }
        if ([string]::IsNullOrWhiteSpace($BoundThreadId) -or [string]::IsNullOrWhiteSpace($inboundThread) -or $inboundThread -cne $BoundThreadId) {
            return [ordered]@{ kind = 'ignored' }
        }
        if (-not (Test-CodexAppServerInboundExactKeys -Dict $params -Allowed $script:CodexAppServerStatusNotificationKeys -Required $script:CodexAppServerStatusNotificationKeys)) {
            return [ordered]@{ kind = 'ignored' }
        }
        $statusNode = Get-CodexAppServerDictObject -Dict $params -Key 'status'
        $projected = ConvertTo-CodexAppServerProjectedStatus -StatusNode $statusNode
        if (-not [bool]$projected.valid) { return [ordered]@{ kind = 'ignored' } }
        if ($projected.status -cin @('idle', 'notLoaded', 'systemError')) {
            $Client.pending = [Collections.Generic.List[object]]::new()
            $Client.last_status = [ordered]@{ status = [string]$projected.status; active_flags = @() }
        } else {
            $flags = [Collections.Generic.List[string]]::new()
            foreach ($flag in (Get-CodexAppServerStringRecords -Value $projected.active_flags)) { $flags.Add([string]$flag) }
            foreach ($item in @($Client.pending)) {
                $flag = Get-CodexAppServerPendingFlag -Method ([string]$item.method)
                if (-not [string]::IsNullOrWhiteSpace($flag) -and $flags -notcontains $flag) { $flags.Add($flag) }
            }
            $Client.last_status = [ordered]@{ status = [string]$projected.status; active_flags = @($flags) }
        }
        return [ordered]@{ kind = 'status' }
    }
    if ($method -ceq 'serverRequest/resolved') {
        if (-not (Test-CodexAppServerNotificationEnvelope -Client $Client -Message $Message)) {
            return [ordered]@{ kind = 'ignored' }
        }
        if (-not (Test-CodexAppServerInboundExactKeys -Dict $params -Allowed $script:CodexAppServerResolvedNotificationKeys -Required $script:CodexAppServerResolvedNotificationKeys)) {
            return [ordered]@{ kind = 'ignored' }
        }
        $rid = Get-CodexAppServerDictString -Dict $params -Key 'requestId'
        if ([string]::IsNullOrWhiteSpace($inboundThread) -or $inboundThread -cne $BoundThreadId) {
            return [ordered]@{ kind = 'ignored' }
        }
        if ([string]::IsNullOrWhiteSpace($rid) -or -not (Test-CodexAppServerPendingContains -Client $Client -RequestId $rid)) {
            return [ordered]@{ kind = 'ignored' }
        }
        Resolve-CodexAppServerPending -Client $Client -RequestId $rid
        return [ordered]@{ kind = 'resolved' }
    }
    if ($method -ceq 'turn/completed') {
        if (-not (Test-CodexAppServerNotificationEnvelope -Client $Client -Message $Message)) {
            return [ordered]@{ kind = 'ignored' }
        }
        if ([string]::IsNullOrWhiteSpace($BoundThreadId) -or [string]::IsNullOrWhiteSpace($BoundTurnId)) {
            return [ordered]@{ kind = 'ignored' }
        }
        if (-not (Test-CodexAppServerInboundExactKeys -Dict $params -Allowed $script:CodexAppServerCompletedNotificationKeys -Required $script:CodexAppServerCompletedNotificationKeys)) {
            return [ordered]@{ kind = 'ignored' }
        }
        if ([string]::IsNullOrWhiteSpace($inboundThread) -or $inboundThread -cne $BoundThreadId) {
            return [ordered]@{ kind = 'ignored' }
        }
        $turn = Get-CodexAppServerDictObject -Dict $params -Key 'turn'
        try {
            $turnId = Assert-CodexAppServerTurnProjection -Turn $turn -ExpectedId $BoundTurnId
        } catch {
            return [ordered]@{ kind = 'ignored' }
        }
        $disp = ConvertTo-CodexAppServerTurnDisposition -Turn $turn
        if (-not (Test-CodexAppServerTurnTerminalDisposition -Disposition $disp)) {
            return [ordered]@{ kind = 'ignored' }
        }
        $Client.last_terminal = [ordered]@{ turn_id = $turnId; disposition = $disp }
        $Client.pending = [Collections.Generic.List[object]]::new()
        $status = Get-CodexAppServerDictString -Dict $Client.last_status -Key 'status'
        if ($status -ceq 'active' -or [string]::IsNullOrWhiteSpace($status)) { $status = 'idle' }
        $Client.last_status = [ordered]@{ status = $status; active_flags = @() }
        return [ordered]@{ kind = 'terminal'; disposition = $disp; turn_id = $turnId }
    }
    return [ordered]@{ kind = 'ignored' }
}

function New-CodexAppServerClient {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [string]$StorePath = '',
        [int]$ReadTimeoutMilliseconds = 60000
    )
    Assert-CodexAppServerListenStdioOnly -Arguments @('app-server', '--listen', 'stdio://')
    $info = New-CodexAppServerProcessStartInfo -CodexCommand $CodexCommand -Arguments @(
        'app-server', '--listen', 'stdio://'
    ) -WorkingDirectory $WorkingDirectory -RedirectStdio
    if (-not [string]::IsNullOrWhiteSpace($StorePath)) {
        $info.Environment['TELEPHONE_APP_SERVER_THREAD_STORE'] = [IO.Path]::GetFullPath($StorePath)
    }
    $process = [Diagnostics.Process]::Start($info)
    if ($null -eq $process) { throw 'Codex app-server process failed to start.' }
    $child = [ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-child-v1'
        pid = [int]$process.Id
        start_time_utc_ticks = [int64]$process.StartTime.ToUniversalTime().Ticks
        started_at_utc = $process.StartTime.ToUniversalTime().ToString('o')
    }
    $client = [ordered]@{
        process = $process
        child = $child
        pending = [Collections.Generic.List[object]]::new()
        last_status = [ordered]@{ status = 'notLoaded'; active_flags = @() }
        last_terminal = $null
        read_timeout_ms = [int]$ReadTimeoutMilliseconds
        accepted_turn_read = $false
        bound_thread_id = ''
        bound_turn_id = ''
        service_tier = ''
        stdout_read_task = $null
        stdout_concurrent_starts = 0
        stdout_read_reused = 0
        stderr_sync = $null
        stderr_ps = $null
        stderr_rs = $null
        stderr_handle = $null
    }
    Start-CodexAppServerStderrDrain -Client $client
    return $client
}

function Stop-CodexAppServerClient {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Client,
        [string]$StderrEvidencePath = ''
    )
    if ($null -eq $Client -or $null -eq $Client.process) {
        Stop-CodexAppServerStderrDrain -Client $Client -EvidencePath $StderrEvidencePath
        return
    }
    $process = $Client.process
    try {
        try {
            if ($null -ne $process.StandardInput) { $process.StandardInput.Close() }
        } catch { }
        if (-not $process.HasExited) {
            if (-not $process.WaitForExit(2000)) {
                try { $process.Kill($true) } catch { }
                $null = $process.WaitForExit(2000)
            }
        }
    } finally {
        Stop-CodexAppServerStderrDrain -Client $Client -EvidencePath $StderrEvidencePath
        $process.Dispose()
        $Client.process = $null
    }
}

function Receive-CodexAppServerUntilResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][string]$RequestId
    )
    while ($true) {
        $msg = Read-CodexAppServerRawMessage -Client $Client
        if ($null -eq $msg) { continue }
        $id = Get-CodexAppServerDictString -Dict $msg -Key 'id'
        if ($id -ceq $RequestId) {
            if ($msg.Contains('error')) { throw 'Codex app-server request failed.' }
            return ,(Get-CodexAppServerDictObject -Dict $msg -Key 'result')
        }
        $null = Apply-CodexAppServerInboundMessage -Client $Client -Message $msg
    }
}

function Save-CodexAppServerClientStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [string]$CallbackOwnerState = ''
    )
    $observed = [string]$CallbackOwnerState
    if ([string]::IsNullOrWhiteSpace($observed) -and [IO.File]::Exists($Paths.run)) {
        try {
            $runNow = Read-CodexAppServerValidated -Path $Paths.run -SchemaName 'codex-app-server-lead-run'
            $observed = Get-CodexAppServerObservedCallbackState -Run $runNow -Paths $Paths -OwnerAlive $true
        } catch { $observed = '' }
    }
    $null = Write-CodexAppServerProjectedStatus -Path $Paths.status -ThreadId $ThreadId -Status ([string]$Client.last_status.status) -ActiveFlags @($Client.last_status.active_flags) -Pending @($Client.pending) -CallbackOwnerState $observed
    if ($null -ne $Client.stderr_sync) {
        Write-CodexAppServerStderrEvidence -Path $Paths.stderr_evidence -Evidence $Client.stderr_sync
    }
}

function Write-CodexAppServerBoundTurnRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$TurnId,
        [Parameter(Mandatory = $true)][string]$State,
        [string]$WriterLabel = 'bound'
    )
    if ([string]::IsNullOrWhiteSpace($TurnId)) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
    $doc = [ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-bound-turn-v1'
        thread_id = [string]$ThreadId
        turn_id = [string]$TurnId
        state = [string]$State
        bound_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if ([IO.File]::Exists($Paths.bound_turn)) {
        $existing = Read-CodexAppServerValidated -Path $Paths.bound_turn -SchemaName 'codex-app-server-lead-bound-turn'
        $existingTurn = Get-CodexAppServerDictString -Dict $existing -Key 'turn_id'
        $existingThread = Get-CodexAppServerDictString -Dict $existing -Key 'thread_id'
        if ($existingTurn -cne $TurnId -or $existingThread -cne $ThreadId) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        $boundAt = Get-CodexAppServerDictString -Dict $existing -Key 'bound_at_utc'
        if (-not [string]::IsNullOrWhiteSpace($boundAt)) { $doc.bound_at_utc = $boundAt }
    }
    $null = Write-CodexAppServerValidatedReplace -Path $Paths.bound_turn -Value $doc -SchemaName 'codex-app-server-lead-bound-turn' -PublicationPoint 'bound' -WriterLabel $WriterLabel
}

function Set-CodexAppServerRunPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$Phase,
        [string]$Disposition = '',
        [string]$SelectedTurnId = '',
        [switch]$SetSelected,
        [string]$FallbackRequired = '',
        [switch]$SetFallback,
        [string]$TerminalTarget = '',
        [switch]$SetTerminalTarget,
        [string]$PublicationPoint = '',
        [string]$WriterLabel = ''
    )
    if (-not [IO.File]::Exists($Paths.run)) { return }
    $run = Read-CodexAppServerValidated -Path $Paths.run -SchemaName 'codex-app-server-lead-run'
    $run.callback_write_phase = [string]$Phase
    if (-not [string]::IsNullOrWhiteSpace($Disposition)) { $run.disposition = [string]$Disposition }
    if ($SetSelected) { $run.selected_turn_id = [string]$SelectedTurnId }
    if ($SetFallback) { $run.fallback_required = [string]$FallbackRequired }
    if ($SetTerminalTarget) { $run.terminal_target = [string]$TerminalTarget }
    $label = [string]$WriterLabel
    if ([string]::IsNullOrWhiteSpace($label)) { $label = [string]$PublicationPoint }
    $null = Write-CodexAppServerValidatedReplace -Path $Paths.run -Value $run -SchemaName 'codex-app-server-lead-run' -PublicationPoint $PublicationPoint -WriterLabel $label
}

function Update-CodexAppServerRunSelected {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$TurnId,
        [Parameter(Mandatory = $true)][string]$Disposition,
        [string]$Phase = '',
        [string]$PublicationPoint = 'selected-run',
        [string]$WriterLabel = ''
    )
    if (-not [IO.File]::Exists($Paths.run)) { return }
    $resolvedPhase = [string]$Phase
    if ([string]::IsNullOrWhiteSpace($resolvedPhase)) {
        $resolvedPhase = if (Test-CodexAppServerTurnTerminalDisposition -Disposition $Disposition) { 'terminal' } else { 'acknowledged' }
    }
    $target = ''
    $setTarget = $false
    if ($resolvedPhase -ceq 'terminal' -or $resolvedPhase -ceq 'terminal_publishing') {
        $target = [string]$Disposition
        $setTarget = $true
    }
    $label = [string]$WriterLabel
    if ([string]::IsNullOrWhiteSpace($label)) { $label = [string]$PublicationPoint }
    Set-CodexAppServerRunPhase -Paths $Paths -Phase $resolvedPhase -Disposition $Disposition -SelectedTurnId $TurnId -SetSelected -TerminalTarget $target -SetTerminalTarget:$setTarget -PublicationPoint $PublicationPoint -WriterLabel $label
}

function Confirm-CodexAppServerWakeAck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$TurnId
    )
    if (-not [IO.File]::Exists($Paths.ack)) {
        $null = Write-CodexAppServerValidatedReplace -Path $Paths.ack -Value (New-CodexAppServerWakeAck -SessionId $ThreadId -TurnId $TurnId) -SchemaName 'codex-app-server-lead-ack' -PublicationPoint 'ack' -WriterLabel 'ack'
        return
    }
    $ack = Read-CodexAppServerValidated -Path $Paths.ack -SchemaName 'codex-app-server-lead-ack'
    Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $ack -Key 'session_id') -Right $ThreadId -Label 'ack session'
    Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $ack -Key 'turn_id') -Right $TurnId -Label 'ack turn'
}

function Bind-CodexAppServerTurnAndAck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$TurnId,
        [string]$BoundState = 'active'
    )
    if ([IO.File]::Exists($Paths.recovery) -or [IO.File]::Exists($Paths.failure)) {
        Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
    }
    Write-CodexAppServerBoundTurnRecord -Paths $Paths -ThreadId $ThreadId -TurnId $TurnId -State $BoundState -WriterLabel 'bound'
    Set-CodexAppServerRunPhase -Paths $Paths -Phase 'turn_bound' -WriterLabel 'run-bound'
    Add-CodexAppServerTransition -Path $Paths.transitions -State 'turn_bound'
    Invoke-CodexAppServerMaybeCrash -Point 'after-turn-bind'
    Invoke-CodexAppServerMaybeCrash -Point 'before-ack'
    Confirm-CodexAppServerWakeAck -Paths $Paths -ThreadId $ThreadId -TurnId $TurnId
    Add-CodexAppServerTransition -Path $Paths.transitions -State 'acknowledged'
    $bindDisposition = 'in_progress'
    if ((Get-CodexAppServerRunDisposition -Paths $Paths) -ceq 'recovered') { $bindDisposition = 'recovered' }
    Update-CodexAppServerRunSelected -Paths $Paths -TurnId $TurnId -Disposition $bindDisposition -Phase 'acknowledged' -PublicationPoint 'selected-run' -WriterLabel 'acknowledged'
    Invoke-CodexAppServerMaybeCrash -Point 'after-ack-in-progress'
}

function Complete-CodexAppServerDeclarationRetirement {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Paths)
    if (-not (Test-CodexAppServerCompleteOfficialTerminal -Paths $Paths)) { return }
    Remove-CodexAppServerDeclarationFile -Path ([string]$Paths.failure) -WriterLabel 'failure-retirement'
    Remove-CodexAppServerDeclarationFile -Path ([string]$Paths.recovery) -WriterLabel 'recovery-retirement'
}

function Remove-CodexAppServerDeclarationFile {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Path,
        [string]$WriterLabel = ''
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return }
    if (-not [string]::IsNullOrWhiteSpace($WriterLabel)) {
        Invoke-CodexAppServerMaybeCrash -Point ($WriterLabel + ':before-delete')
        Invoke-CodexAppServerWriterScopedCrash -WriterLabel $WriterLabel -Cut 'before-delete'
    }
    try { [IO.File]::Delete($Path) } catch { }
    if (-not [string]::IsNullOrWhiteSpace($WriterLabel)) {
        Invoke-CodexAppServerMaybeCrash -Point ($WriterLabel + ':after-delete')
        Invoke-CodexAppServerWriterScopedCrash -WriterLabel $WriterLabel -Cut 'after-delete'
    }
}

function Test-CodexAppServerRecoveryCommitPending {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Paths)
    if ([IO.File]::Exists($Paths.recovery)) { return $true }
    $disp = Get-CodexAppServerRunDisposition -Paths $Paths
    if ($disp -ceq 'recovery_required') { return $true }
    $phase = Get-CodexAppServerCallbackWritePhase -Paths $Paths
    if ($phase -ceq 'none' -or $phase -ceq 'terminal_publishing' -or $phase -ceq 'terminal') { return $false }
    return [IO.File]::Exists($Paths.failure)
}

function Complete-CodexAppServerRecoveryCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$TurnId
    )
    if (-not (Test-CodexAppServerRecoveryCommitPending -Paths $Paths)) { return }
    if ([string]::IsNullOrWhiteSpace($TurnId)) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
    if ([IO.File]::Exists($Paths.bound_turn)) {
        $bound = Read-CodexAppServerValidated -Path $Paths.bound_turn -SchemaName 'codex-app-server-lead-bound-turn'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $bound -Key 'thread_id') -Right $ThreadId -Label 'bound thread id'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $bound -Key 'turn_id') -Right $TurnId -Label 'bound turn id'
    }
    if ([IO.File]::Exists($Paths.ack)) {
        $ack = Read-CodexAppServerValidated -Path $Paths.ack -SchemaName 'codex-app-server-lead-ack'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $ack -Key 'session_id') -Right $ThreadId -Label 'ack session'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $ack -Key 'turn_id') -Right $TurnId -Label 'ack turn'
    }
    if ([IO.File]::Exists($Paths.recovery)) {
        $recovery = Read-CodexAppServerValidated -Path $Paths.recovery -SchemaName 'codex-app-server-lead-recovery'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $recovery -Key 'thread_id') -Right $ThreadId -Label 'recovery thread id'
        $recoveryTurn = Get-CodexAppServerDictString -Dict $recovery -Key 'turn_id'
        if (-not [string]::IsNullOrWhiteSpace($recoveryTurn)) {
            Assert-CodexAppServerSameText -Left $recoveryTurn -Right $TurnId -Label 'recovery turn id'
        }
    }
    Remove-CodexAppServerDeclarationFile -Path ([string]$Paths.failure) -WriterLabel 'failure-retirement'
    Invoke-CodexAppServerMaybeCrash -Point 'after-failure-retired'
    if ([IO.File]::Exists($Paths.run)) {
        $run = Read-CodexAppServerValidated -Path $Paths.run -SchemaName 'codex-app-server-lead-run'
        $disp = Get-CodexAppServerDictString -Dict $run -Key 'disposition'
        $phaseNow = Get-CodexAppServerDictString -Dict $run -Key 'callback_write_phase'
        if ($disp -ceq 'recovery_required' -or ($disp -ceq 'in_progress' -and [IO.File]::Exists($Paths.recovery))) {
            $run.disposition = 'recovered'
            $run.fallback_required = ''
            if ($phaseNow -ceq 'turn_start_sending' -and [string]::IsNullOrWhiteSpace((Get-CodexAppServerDictString -Dict $run -Key 'selected_turn_id'))) {
                $run.selected_turn_id = ''
            }
            $null = Write-CodexAppServerValidatedReplace -Path $Paths.run -Value $run -SchemaName 'codex-app-server-lead-run' -WriterLabel 'recovered-run'
        }
    }
    if ([IO.File]::Exists($Paths.result)) {
        $null = Write-CodexAppServerOfficialLauncherResult -Paths $Paths -Started $false -Existing $true -State 'recovered' -RunId ([IO.Path]::GetFileName([string]$Paths.run_root)) -WriterLabel 'recovered-result'
    }
    Invoke-CodexAppServerMaybeCrash -Point 'after-recovery-commit-run'
    Remove-CodexAppServerDeclarationFile -Path ([string]$Paths.recovery) -WriterLabel 'recovery-retirement'
    Invoke-CodexAppServerMaybeCrash -Point 'after-recovery-retired'
}

function Complete-CodexAppServerTurnTerminal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$TurnId,
        [Parameter(Mandatory = $true)][string]$Disposition
    )
    if (Test-CodexAppServerTurnTerminalDisposition -Disposition $Disposition) {
        if ([IO.File]::Exists($Paths.status) -or -not [string]::IsNullOrWhiteSpace($ThreadId)) {
            $null = Write-CodexAppServerProjectedStatus -Path $Paths.status -ThreadId $ThreadId -Status 'idle' -ActiveFlags @() -Pending @()
        }
        Invoke-CodexAppServerMaybeCrash -Point 'before-terminal-intent'
        Set-CodexAppServerRunPhase -Paths $Paths -Phase 'terminal_publishing' -TerminalTarget $Disposition -SetTerminalTarget -PublicationPoint 'terminal-intent' -WriterLabel 'terminal-intent'
        Invoke-CodexAppServerMaybeCrash -Point 'after-terminal-intent'
        Write-CodexAppServerLauncherFinal -Path $Paths.final -State $Disposition
        Invoke-CodexAppServerMaybeCrash -Point 'after-terminal-final'
        Write-CodexAppServerBoundTurnRecord -Paths $Paths -ThreadId $ThreadId -TurnId $TurnId -State $Disposition -WriterLabel 'terminal-bound'
        Invoke-CodexAppServerMaybeCrash -Point 'after-terminal-bound'
        Update-CodexAppServerRunSelected -Paths $Paths -TurnId $TurnId -Disposition $Disposition -Phase 'terminal' -PublicationPoint 'selected-run' -WriterLabel 'terminal-run'
        Invoke-CodexAppServerMaybeCrash -Point 'after-terminal-run'
        Add-CodexAppServerTransition -Path $Paths.transitions -State ('terminal_' + $Disposition)
        return
    }
    Write-CodexAppServerBoundTurnRecord -Paths $Paths -ThreadId $ThreadId -TurnId $TurnId -State $Disposition
    Update-CodexAppServerRunSelected -Paths $Paths -TurnId $TurnId -Disposition $Disposition -Phase 'acknowledged' -PublicationPoint 'selected-run'
    Add-CodexAppServerTransition -Path $Paths.transitions -State ('terminal_' + $Disposition)
}

function Write-CodexAppServerOfficialLauncherResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][bool]$Started,
        [Parameter(Mandatory = $true)][bool]$Existing,
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$RunId,
        [string]$FallbackRequired = '',
        [string]$WriterLabel = 'terminal-result'
    )
    $result = New-CodexAppServerWakeResult -Started $Started -Existing $Existing -State $State -RunId $RunId -RunRoot ([string]$Paths.run_root) -FallbackRequired $FallbackRequired
    if ([IO.File]::Exists($Paths.result)) {
        $prior = Read-CodexAppServerValidated -Path $Paths.result -SchemaName 'codex-app-server-lead-result'
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $prior -Key 'run_id') -Right $RunId -Label 'result run id'
        if (-not (Test-CodexAppServerCanonicalPathEqual -Left (Get-CodexAppServerDictString -Dict $prior -Key 'run_root') -Right ([string]$Paths.run_root))) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        $from = Get-CodexAppServerDictString -Dict $prior -Key 'state'
        if (-not (Test-CodexAppServerResultForwardAllowed -From $from -To $State)) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        if ($from -ceq $State) {
            $prior.started = [bool]$Started
            $prior.existing = [bool]$Existing
            return $prior
        }
    }
    Write-CodexAppServerLauncherResult -Path $Paths.result -Value $result -WriterLabel $WriterLabel
    return $result
}

function Complete-CodexAppServerTerminalPublicationFromDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ThreadId
    )
    if (-not [IO.File]::Exists($Paths.run)) { return $null }
    $run = Read-CodexAppServerValidated -Path $Paths.run -SchemaName 'codex-app-server-lead-run'
    $phase = Get-CodexAppServerDictString -Dict $run -Key 'callback_write_phase'
    $target = Get-CodexAppServerDictString -Dict $run -Key 'terminal_target'
    $selected = Get-CodexAppServerDictString -Dict $run -Key 'selected_turn_id'
    $disp = Get-CodexAppServerDictString -Dict $run -Key 'disposition'
    if ($phase -ceq 'terminal_publishing') {
        if (-not (Test-CodexAppServerTurnTerminalDisposition -Disposition $target)) {
            Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
        }
        if ([string]::IsNullOrWhiteSpace($selected)) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
        Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $run -Key 'thread_id') -Right $ThreadId -Label 'thread id'
        if (-not [IO.File]::Exists($Paths.final)) {
            Write-CodexAppServerLauncherFinal -Path $Paths.final -State $target
        }
        Write-CodexAppServerBoundTurnRecord -Paths $Paths -ThreadId $ThreadId -TurnId $selected -State $target -WriterLabel 'terminal-bound'
        Update-CodexAppServerRunSelected -Paths $Paths -TurnId $selected -Disposition $target -Phase 'terminal' -PublicationPoint 'selected-run' -WriterLabel 'terminal-run'
        $written = Write-CodexAppServerOfficialLauncherResult -Paths $Paths -Started $true -Existing $true -State $target -RunId $RunId
        Complete-CodexAppServerDeclarationRetirement -Paths $Paths
        return $written
    }
    if ($phase -ceq 'terminal' -and (Test-CodexAppServerTurnTerminalDisposition -Disposition $disp)) {
        if ([IO.File]::Exists($Paths.result)) {
            $existing = Read-CodexAppServerValidated -Path $Paths.result -SchemaName 'codex-app-server-lead-result'
            $existingState = Get-CodexAppServerDictString -Dict $existing -Key 'state'
            if ($existingState -ceq $disp) {
                Complete-CodexAppServerDeclarationRetirement -Paths $Paths
                return $existing
            }
        }
        $written = Write-CodexAppServerOfficialLauncherResult -Paths $Paths -Started $true -Existing $true -State $disp -RunId $RunId
        Complete-CodexAppServerDeclarationRetirement -Paths $Paths
        return $written
    }
    return $null
}

function Complete-CodexAppServerBoundTurn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$TurnId,
        [Parameter(Mandatory = $true)][string]$Disposition
    )
    $boundState = if (Test-CodexAppServerTurnTerminalDisposition -Disposition $Disposition) { $Disposition } else { 'active' }
    Bind-CodexAppServerTurnAndAck -Paths $Paths -ThreadId $ThreadId -TurnId $TurnId -BoundState $boundState
    if (Test-CodexAppServerTurnTerminalDisposition -Disposition $Disposition) {
        Complete-CodexAppServerTurnTerminal -Paths $Paths -ThreadId $ThreadId -TurnId $TurnId -Disposition $Disposition
    }
}

function Get-CodexAppServerTurnById {
    [CmdletBinding()]
    param([AllowNull()][object]$Thread, [Parameter(Mandatory = $true)][string]$TurnId)
    if ($Thread -isnot [Collections.IDictionary]) { return $null }
    foreach ($turn in (Get-CodexAppServerJsonArrayItems -Value (Get-CodexAppServerDictObject -Dict $Thread -Key 'turns'))) {
        if ($turn -is [Collections.IDictionary] -and (Get-CodexAppServerDictString -Dict $turn -Key 'id') -ceq $TurnId) {
            return $turn
        }
    }
    return $null
}

function Wait-CodexAppServerBoundTurnTerminal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$TurnId
    )
    Save-CodexAppServerClientStatus -Client $Client -Paths $Paths -ThreadId $ThreadId
    if ($null -ne $Client.last_terminal -and [string]$Client.last_terminal.turn_id -ceq $TurnId) {
        $existingDisp = [string]$Client.last_terminal.disposition
        if (Test-CodexAppServerTurnTerminalDisposition -Disposition $existingDisp) {
            return $existingDisp
        }
    }
    Enable-CodexAppServerAcceptedTurnRead -Client $Client -ThreadId $ThreadId -TurnId $TurnId -EvidencePath ([string]$Paths.read_lifetime)
    while ($true) {
        $msg = Read-CodexAppServerRawMessage -Client $Client
        if ($null -eq $msg) { continue }
        $applied = Apply-CodexAppServerInboundMessage -Client $Client -Message $msg -BoundThreadId $ThreadId -BoundTurnId $TurnId
        if ([string]$applied.kind -cin @('pending', 'status', 'resolved', 'terminal')) {
            $boundState = if (@($Client.pending).Count -gt 0) { 'pending' } else { 'active' }
            if ([string]$applied.kind -cne 'terminal') {
                Write-CodexAppServerBoundTurnRecord -Paths $Paths -ThreadId $ThreadId -TurnId $TurnId -State $boundState
            }
            Save-CodexAppServerClientStatus -Client $Client -Paths $Paths -ThreadId $ThreadId
            Write-CodexAppServerReadLifetime -Path ([string]$Paths.read_lifetime) -Client $Client
        }
        if ([string]$applied.kind -ceq 'terminal') { return [string]$applied.disposition }
    }
}

function Send-CodexAppServerWakeTurnOnce {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$TurnText
    )
    Set-CodexAppServerRunPhase -Paths $Paths -Phase 'turn_start_sending' -PublicationPoint 'turn-start-sending' -WriterLabel 'turn-start-sending'
    Add-CodexAppServerTransition -Path $Paths.transitions -State 'turn_start_sending'
    Invoke-CodexAppServerMaybeCrash -Point 'after-ambiguous-write-pre'
    $started = $null
    try {
        $started = Invoke-CodexAppServerTurnStart -Client $Client -ThreadId $ThreadId -Text $TurnText
    } catch {
        Add-CodexAppServerTransition -Path $Paths.transitions -State 'turn_start_ambiguous'
        throw
    }
    Invoke-CodexAppServerMaybeCrash -Point 'after-ambiguous-write'
    return $started
}

function Get-CodexAppServerMatchRecords {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    $out = [Collections.Generic.List[object]]::new()
    if ([object]::ReferenceEquals($Value, $null)) {
        Write-Output -NoEnumerate -InputObject ([object[]]@())
        return
    }
    if ($Value -is [Collections.IDictionary]) {
        $out.Add($Value)
        Write-Output -NoEnumerate -InputObject ([object[]]@($out))
        return
    }
    foreach ($item in (Get-CodexAppServerJsonArrayItems -Value $Value)) {
        if ($item -is [Collections.IDictionary]) { $out.Add($item) }
    }
    Write-Output -NoEnumerate -InputObject ([object[]]@($out))
}

function Get-CodexAppServerStringRecords {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    $out = [Collections.Generic.List[string]]::new()
    if ([object]::ReferenceEquals($Value, $null)) {
        Write-Output -NoEnumerate -InputObject ([string[]]@())
        return
    }
    if ($Value -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace($Value)) { $out.Add([string]$Value) }
        Write-Output -NoEnumerate -InputObject ([string[]]@($out))
        return
    }
    foreach ($item in (Get-CodexAppServerJsonArrayItems -Value $Value)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$item)) { $out.Add([string]$item) }
    }
    Write-Output -NoEnumerate -InputObject ([string[]]@($out))
}

function Get-CodexAppServerUnixTime {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    if (Test-CodexAppServerJsonNull -Value $Value) { return $null }
    if (Test-CodexAppServerJsonNumber -Value $Value) {
        $n = [double]$Value
        if ([double]::IsNaN($n) -or [double]::IsInfinity($n) -or $n -le 0) { return $null }
        if ($n -ge 1.0e12) { $n = $n / 1000.0 }
        if ($n -ge 1.0e12) { return $null }
        return $n
    }
    if (Test-CodexAppServerJsonString -Value $Value) {
        try {
            $dto = [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            return ([double]$dto.ToUnixTimeMilliseconds() / 1000.0)
        } catch {
            return $null
        }
    }
    return $null
}

function Get-CodexAppServerIntentCreatedUnix {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Paths)
    if (-not [IO.File]::Exists($Paths.intent)) { return $null }
    $intent = Read-CodexAppServerValidated -Path $Paths.intent -SchemaName 'codex-app-server-lead-intent'
    $raw = $null
    if ($intent.Contains('created_at_utc')) { $raw = $intent['created_at_utc'] }
    return (Get-CodexAppServerUnixTime -Value $raw)
}

function Test-CodexAppServerTurnIsProvablePreIntent {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Turn,
        [AllowNull()][object]$IntentUnix
    )
    if ($Turn -isnot [Collections.IDictionary]) { return $false }
    if ($null -eq $IntentUnix) { return $false }
    $intent = [double]$IntentUnix
    if ([double]::IsNaN($intent) -or [double]::IsInfinity($intent) -or $intent -le 0) { return $false }
    $status = ''
    if ($Turn.Contains('status')) { $status = [string]$Turn['status'] }
    if (-not (Test-CodexAppServerTurnTerminalDisposition -Disposition $status)) { return $false }
    $rawStarted = $null
    $rawCompleted = $null
    if ($Turn.Contains('startedAt')) { $rawStarted = $Turn['startedAt'] }
    if ($Turn.Contains('completedAt')) { $rawCompleted = $Turn['completedAt'] }
    $started = Get-CodexAppServerUnixTime -Value $rawStarted
    $completed = Get-CodexAppServerUnixTime -Value $rawCompleted
    if ($null -eq $started -or $null -eq $completed) { return $false }
    if ([double]$started -gt [double]$completed) { return $false }
    $representedSecondEnd = [Math]::Floor([double]$completed) + 1.0
    return ($representedSecondEnd -le $intent)
}

function Get-CodexAppServerSiblingSelectedTurnIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId
    )
    $ids = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $stateRoot = ''
    if ($Paths -is [Collections.IDictionary] -and $Paths.Contains('state_root')) {
        $stateRoot = [string]$Paths.state_root
    }
    if ([string]::IsNullOrWhiteSpace($stateRoot) -and $Paths -is [Collections.IDictionary] -and $Paths.Contains('run_root')) {
        $runRoot = [IO.Path]::GetFullPath([string]$Paths.run_root)
        $runsDirGuess = [IO.Path]::GetDirectoryName($runRoot)
        if (-not [string]::IsNullOrWhiteSpace($runsDirGuess)) {
            $stateRoot = [IO.Path]::GetDirectoryName($runsDirGuess)
        }
    }
    if ([string]::IsNullOrWhiteSpace($stateRoot)) { return [string[]]@() }
    $runsDir = [IO.Path]::GetFullPath((Join-Path $stateRoot 'runs'))
    if (-not [IO.Directory]::Exists($runsDir)) { return [string[]]@() }
    $selfRun = [IO.Path]::GetFileName([string]$Paths.run_root)
    foreach ($dir in [IO.Directory]::GetDirectories($runsDir)) {
        try {
            $runId = [IO.Path]::GetFileName($dir)
            if ($runId -ceq $selfRun) { continue }
            Assert-CodexAppServerRunId -RunId $runId
            $sibling = Get-CodexAppServerRunPaths -StateRoot $stateRoot -RunId $runId
            if (-not [IO.File]::Exists($sibling.run) -or -not [IO.File]::Exists($sibling.bound_turn)) { continue }
            $run = Read-CodexAppServerValidated -Path $sibling.run -SchemaName 'codex-app-server-lead-run'
            $bound = Read-CodexAppServerValidated -Path $sibling.bound_turn -SchemaName 'codex-app-server-lead-bound-turn'
            if ((Get-CodexAppServerDictString -Dict $run -Key 'thread_id') -cne $ThreadId) { continue }
            $selected = Get-CodexAppServerDictString -Dict $run -Key 'selected_turn_id'
            $boundTurn = Get-CodexAppServerDictString -Dict $bound -Key 'turn_id'
            $boundThread = Get-CodexAppServerDictString -Dict $bound -Key 'thread_id'
            if ([string]::IsNullOrWhiteSpace($selected) -or $selected -cne $boundTurn) { continue }
            if ($boundThread -cne $ThreadId) { continue }
            if ($seen.Add($selected)) { $ids.Add($selected) }
        } catch {
            continue
        }
    }
    return [string[]]@($ids)
}

function Write-CodexAppServerCapturedBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Baseline
    )
    $ids = @(Get-CodexAppServerStringList -Value $Baseline)
    $gatePath = ''
    if ($Paths -is [Collections.IDictionary] -and $Paths.Contains('gate')) { $gatePath = [string]$Paths.gate }
    $gate = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($gatePath)) {
            $gate = Open-TelephoneExclusiveGate -Path $gatePath -WaitMilliseconds 60000
            if ($null -eq $gate) { throw 'Exclusive per-run gate is held by another launcher.' }
        }
        if ([IO.File]::Exists($Paths.intent)) {
            $intent = Read-CodexAppServerValidated -Path $Paths.intent -SchemaName 'codex-app-server-lead-intent'
            $intent.baseline_turn_ids = @($ids)
            $null = Write-CodexAppServerValidatedReplace -Path $Paths.intent -Value $intent -SchemaName 'codex-app-server-lead-intent'
        }
        if ([IO.File]::Exists($Paths.run)) {
            $run = Read-CodexAppServerValidated -Path $Paths.run -SchemaName 'codex-app-server-lead-run'
            $run.baseline_turn_ids = @($ids)
            $null = Write-CodexAppServerValidatedReplace -Path $Paths.run -Value $run -SchemaName 'codex-app-server-lead-run'
        }
    } finally {
        if ($null -ne $gate) { $gate.Dispose() }
    }
}

function Try-CodexAppServerAdoptPreIntentUnexplained {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Prepared,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$UnexplainedIds
    )
    if (@($UnexplainedIds).Count -eq 0) { return [string[]]@() }
    $intentUnix = Get-CodexAppServerIntentCreatedUnix -Paths $Paths
    if ($null -eq $intentUnix) { return $null }
    $preIntent = [Collections.Generic.List[string]]::new()
    foreach ($turnId in @($UnexplainedIds)) {
        $turn = Get-CodexAppServerTurnById -Thread $Prepared.thread -TurnId ([string]$turnId)
        if (-not (Test-CodexAppServerTurnIsProvablePreIntent -Turn $turn -IntentUnix $intentUnix)) {
            return $null
        }
        $preIntent.Add([string]$turnId)
    }
    return [string[]]@($preIntent)
}

function Test-CodexAppServerTurnIsActiveOwning {
    [CmdletBinding()]
    param([AllowNull()][object]$Turn)
    if ($Turn -isnot [Collections.IDictionary]) { return $false }
    $status = Get-CodexAppServerDictString -Dict $Turn -Key 'status'
    if (-not $script:CodexAppServerTurnStatusAllowlist.Contains($status)) { return $false }
    return -not (Test-CodexAppServerTurnTerminalDisposition -Disposition $status)
}

function Test-CodexAppServerCallbackStillPendingSend {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Paths)
    if (Test-CodexAppServerCompleteOfficialTerminal -Paths $Paths) { return $false }
    if (Test-CodexAppServerRunQueueRetired -Paths $Paths) { return $false }
    if ([IO.File]::Exists($Paths.bound_turn) -or [IO.File]::Exists($Paths.ack)) { return $false }
    $disp = Get-CodexAppServerRunDisposition -Paths $Paths
    if (Test-CodexAppServerTurnTerminalDisposition -Disposition $disp) { return $false }
    if ($disp -ceq 'recovery_required' -or $disp -ceq 'recovered') { return $false }
    $phase = Get-CodexAppServerCallbackWritePhase -Paths $Paths
    if ($phase -cne 'none' -and $phase -cne 'turn_start_sending') { return $false }
    return $true
}

function Get-CodexAppServerBlockingOwningTurnIds {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Thread,
        [Parameter(Mandatory = $true)][string]$Marker
    )
    $ids = [Collections.Generic.List[string]]::new()
    if ($Thread -isnot [Collections.IDictionary]) { return [string[]]@() }
    foreach ($turn in (Get-CodexAppServerJsonArrayItems -Value (Get-CodexAppServerDictObject -Dict $Thread -Key 'turns'))) {
        if ($turn -isnot [Collections.IDictionary]) { continue }
        if (-not (Test-CodexAppServerTurnIsActiveOwning -Turn $turn)) { continue }
        $turnId = Get-CodexAppServerDictString -Dict $turn -Key 'id'
        if ([string]::IsNullOrWhiteSpace($turnId)) { continue }
        $blob = ''
        try { $blob = [string](Get-CodexAppServerItemTextBlob -Node $turn) } catch { $blob = '' }
        if (Test-CodexAppServerTextHasMarker -Text $blob -Marker $Marker) { continue }
        $ids.Add($turnId)
    }
    return [string[]]@($ids)
}

function Get-CodexAppServerConflictingUnexplainedIds {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Thread,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object]$UnexplainedIds,
        [Parameter(Mandatory = $true)][string]$Marker,
        [string]$MatchedTurnId = ''
    )
    $blockers = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in @(Get-CodexAppServerBlockingOwningTurnIds -Thread $Thread -Marker $Marker)) {
        [void]$blockers.Add([string]$id)
    }
    $conflicts = [Collections.Generic.List[string]]::new()
    foreach ($id in @(Get-CodexAppServerStringList -Value $UnexplainedIds)) {
        if (-not [string]::IsNullOrWhiteSpace($MatchedTurnId) -and [string]$id -ceq [string]$MatchedTurnId) { continue }
        if ($blockers.Contains([string]$id)) { continue }
        $conflicts.Add([string]$id)
    }
    return [string[]]@($conflicts)
}

function Test-CodexAppServerThreadStatusBusy {
    [CmdletBinding()]
    param([AllowNull()][object]$Thread)
    if ($Thread -isnot [Collections.IDictionary]) { return $false }
    $projected = ConvertTo-CodexAppServerProjectedStatus -StatusNode (Get-CodexAppServerDictObject -Dict $Thread -Key 'status')
    if (-not [bool]$projected.valid) { return $false }
    return ([string]$projected.status -ceq 'active')
}

function Merge-CodexAppServerBaselineTurnIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Add
    )
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $merged = [Collections.Generic.List[string]]::new()
    foreach ($source in @($Paths.intent, $Paths.run)) {
        if ([string]::IsNullOrWhiteSpace([string]$source) -or -not [IO.File]::Exists($source)) { continue }
        $schema = if ([string]$source -ceq [string]$Paths.intent) { 'codex-app-server-lead-intent' } else { 'codex-app-server-lead-run' }
        try {
            $doc = Read-CodexAppServerValidated -Path $source -SchemaName $schema
            foreach ($id in @(Get-CodexAppServerStringList -Value (Get-CodexAppServerDictObject -Dict $doc -Key 'baseline_turn_ids'))) {
                if ($seen.Add([string]$id)) { $merged.Add([string]$id) }
            }
        } catch { }
    }
    foreach ($id in @(Get-CodexAppServerStringList -Value $Add)) {
        if ($seen.Add([string]$id)) { $merged.Add([string]$id) }
    }
    if ($merged.Count -eq 0) { return [string[]]@() }
    Write-CodexAppServerCapturedBaseline -Paths $Paths -Baseline @($merged)
    return [string[]]@($merged)
}

function Get-CodexAppServerThreadTurnIdsFromStore {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$StorePath,
        [Parameter(Mandatory = $true)][string]$ThreadId
    )
    if ([string]::IsNullOrWhiteSpace($StorePath) -or -not [IO.File]::Exists($StorePath)) { return [string[]]@() }
    $doc = $null
    try { $doc = Read-CodexAppServerJsonIfPresent -Path $StorePath } catch { return [string[]]@() }
    if ($doc -isnot [Collections.IDictionary]) { return [string[]]@() }
    $threads = Get-CodexAppServerDictObject -Dict $doc -Key 'threads'
    if ($threads -isnot [Collections.IDictionary] -or -not $threads.Contains($ThreadId)) { return [string[]]@() }
    return [string[]]@(Get-CodexAppServerStringList -Value (Get-CodexAppServerTurnIdsFromThread -Thread $threads[$ThreadId]))
}

function Test-CodexAppServerStoreContainsThread {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$StorePath,
        [Parameter(Mandatory = $true)][string]$ThreadId
    )
    if ([string]::IsNullOrWhiteSpace($StorePath) -or -not [IO.File]::Exists($StorePath)) { return $false }
    $doc = $null
    try { $doc = Read-CodexAppServerJsonIfPresent -Path $StorePath } catch { return $false }
    if ($doc -isnot [Collections.IDictionary]) { return $false }
    $threads = Get-CodexAppServerDictObject -Dict $doc -Key 'threads'
    return ($threads -is [Collections.IDictionary] -and $threads.Contains($ThreadId))
}

function Get-CodexAppServerReadOnlySnapshotCompatibilityLicense {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Profile = $null,
        [string]$ProfilePath = '',
        [Parameter(Mandatory = $true)][string]$CodexCommand
    )
    $resolved = $null
    if ($Profile -is [Collections.IDictionary]) {
        $resolved = $Profile
    } elseif (-not [string]::IsNullOrWhiteSpace($ProfilePath) -and [IO.File]::Exists($ProfilePath)) {
        try {
            $resolved = (Read-TelephoneJson -Path $ProfilePath -SchemaName 'codex-app-server-lead-profile').value
        } catch {
            Throw-CodexAppServerPublic -Code 'SCHEMA_OR_PROFILE_INVALID'
        }
    }
    if ($resolved -isnot [Collections.IDictionary]) {
        Throw-CodexAppServerPublic -Code 'SCHEMA_OR_PROFILE_INVALID'
    }
    return (Assert-CodexAppServerProfileCurrent -Profile $resolved -CodexCommand $CodexCommand)
}

function Invoke-CodexAppServerReadOnlyThreadSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [string]$StorePath = '',
        [AllowNull()][object]$Profile = $null,
        [string]$ProfilePath = ''
    )
    $snapshotClient = $null
    try {
        $live = Get-CodexAppServerReadOnlySnapshotCompatibilityLicense -Profile $Profile -ProfilePath $ProfilePath -CodexCommand $CodexCommand
        $clientStore = ''
        if (-not [string]::IsNullOrWhiteSpace($StorePath) -and [IO.File]::Exists($StorePath)) {
            $clientStore = $StorePath
        }
        $snapshotClient = New-CodexAppServerClient -CodexCommand $CodexCommand -WorkingDirectory $Worktree -StorePath $clientStore
        $snapshotClient.compatibility_license = $live
        Initialize-CodexAppServerSession -Client $snapshotClient
        $read = Invoke-CodexAppServerThreadRead -Client $snapshotClient -ThreadId $ThreadId -IncludeTurns $true
        $thread = $null
        if ($read -is [Collections.IDictionary] -and $read.Contains('thread')) { $thread = $read.thread }
        $readId = Get-CodexAppServerDictString -Dict $thread -Key 'id'
        if ([string]::IsNullOrWhiteSpace($readId) -or $readId -cne $ThreadId) {
            throw 'Read-only thread snapshot did not return the exact thread.'
        }
        return [string[]]@(Get-CodexAppServerStringList -Value (Get-CodexAppServerTurnIdsFromThread -Thread $thread))
    } finally {
        try { Stop-CodexAppServerClient -Client $snapshotClient } catch { }
    }
}

function Get-CodexAppServerAdmissionBaselineSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [string]$CodexCommand = '',
        [string]$Worktree = '',
        [AllowNull()][object]$Profile = $null,
        [string]$ProfilePath = ''
    )
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $ids = [Collections.Generic.List[string]]::new()
    $storePath = ''
    if ($Paths -is [Collections.IDictionary] -and $Paths.Contains('store')) { $storePath = [string]$Paths.store }
    $hasThread = Test-CodexAppServerStoreContainsThread -StorePath $storePath -ThreadId $ThreadId
    $proven = $false
    if ($hasThread) {
        $proven = $true
        foreach ($id in @(Get-CodexAppServerThreadTurnIdsFromStore -StorePath $storePath -ThreadId $ThreadId)) {
            if ($seen.Add([string]$id)) { $ids.Add([string]$id) }
        }
    } elseif (
        -not [string]::IsNullOrWhiteSpace($CodexCommand) -and
        -not [string]::IsNullOrWhiteSpace($Worktree)
    ) {
        try {
            foreach ($id in @(Invoke-CodexAppServerReadOnlyThreadSnapshot -CodexCommand $CodexCommand -Worktree $Worktree -ThreadId $ThreadId -StorePath '' -Profile $Profile -ProfilePath $ProfilePath)) {
                if ($seen.Add([string]$id)) { $ids.Add([string]$id) }
            }
            $proven = $true
        } catch {
            $proven = $false
            $ids.Clear()
            $seen.Clear()
        }
    }
    foreach ($id in @(Get-CodexAppServerSiblingSelectedTurnIds -Paths $Paths -ThreadId $ThreadId)) {
        if ($seen.Add([string]$id)) { $ids.Add([string]$id) }
    }
    return [ordered]@{
        proven = [bool]$proven
        ids = [string[]]@($ids)
    }
}

function Complete-CodexAppServerCallbackDiagnosticTerminal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$TransitionState,
        [string]$WriterLabel = 'legacy-empty-baseline'
    )
    Write-CodexAppServerFailureRecord -Paths $Paths -Category 'worker' -Code 'worker_failed' -ThreadId $ThreadId
    if ([IO.File]::Exists($Paths.run)) {
        try { Set-CodexAppServerRunQueueState -Paths $Paths -QueueState 'retired' } catch { }
    }
    $result = Write-CodexAppServerOfficialLauncherResult -Paths $Paths -Started $false -Existing $false -State 'failed' -RunId $RunId -WriterLabel $WriterLabel
    Add-CodexAppServerTransition -Path $Paths.transitions -State $TransitionState
    return $result
}

function Complete-CodexAppServerUnsafeLegacyEmptyBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    return (Complete-CodexAppServerCallbackDiagnosticTerminal -Paths $Paths -ThreadId $ThreadId -RunId $RunId -TransitionState 'legacy_empty_baseline_terminal' -WriterLabel 'legacy-empty-baseline')
}

function Update-CodexAppServerClientStatusFromThread {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [AllowNull()][object]$Thread
    )
    $projected = ConvertTo-CodexAppServerProjectedStatus -StatusNode (Get-CodexAppServerDictObject -Dict $Thread -Key 'status')
    if (-not [bool]$projected.valid) { return }
    $Client.last_status = [ordered]@{
        status = [string]$projected.status
        active_flags = @($projected.active_flags)
    }
}

function Reset-CodexAppServerBusySendPhase {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Paths)
    if (-not (Test-CodexAppServerCallbackStillPendingSend -Paths $Paths)) { return }
    if ([IO.File]::Exists($Paths.bound_turn) -or [IO.File]::Exists($Paths.ack)) { return }
    $phase = Get-CodexAppServerCallbackWritePhase -Paths $Paths
    if ($phase -cne 'turn_start_sending') { return }
    Set-CodexAppServerRunPhase -Paths $Paths -Phase 'none' -WriterLabel 'busy-revert'
    Set-CodexAppServerRunQueueState -Paths $Paths -QueueState 'queued'
}

function Wait-CodexAppServerCallbackEligibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Prepared,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$Marker,
        [Parameter(Mandatory = $true)][string]$TurnText,
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [AllowEmptyCollection()][object]$BaselineTurnIds = @()
    )
    $observedBlocking = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $knownBaseline = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in @(Get-CodexAppServerStringList -Value $BaselineTurnIds)) { [void]$knownBaseline.Add([string]$id) }
    foreach ($id in @(Get-CodexAppServerBlockingOwningTurnIds -Thread $Prepared.thread -Marker $Marker)) {
        [void]$observedBlocking.Add([string]$id)
        [void]$knownBaseline.Add([string]$id)
    }
    while ($true) {
        try {
            $fresh = Invoke-CodexAppServerThreadRead -Client $Prepared.client -ThreadId $ThreadId -IncludeTurns $true
            $Prepared.thread = $fresh.thread
            $Prepared.thread_id = $ThreadId
            Update-CodexAppServerClientStatusFromThread -Client $Prepared.client -Thread $fresh.thread
            $findBaseline = [Collections.Generic.List[string]]::new()
            foreach ($id in @($knownBaseline)) { $findBaseline.Add([string]$id) }
            foreach ($id in @($observedBlocking)) { if ($knownBaseline.Add([string]$id)) { $findBaseline.Add([string]$id) } }
            $found = Find-CodexAppServerMatchingTurns -Thread $Prepared.thread -Marker $Marker -BaselineTurnIds @($findBaseline) -ExpectedText $TurnText
            $matchRecords = @(Get-CodexAppServerMatchRecords -Value $found.matches)
            $unexplainedIds = @(Get-CodexAppServerStringRecords -Value $found.unexplained)
            if ($matchRecords.Count -gt 1) { throw 'Multiple or conflicting wake-marker turns were present.' }
            $matchedTurnId = ''
            if ($matchRecords.Count -eq 1) {
                $matchedTurnId = Get-CodexAppServerDictString -Dict $matchRecords[0] -Key 'turn_id'
            }
            $conflicts = @(Get-CodexAppServerConflictingUnexplainedIds -Thread $Prepared.thread -UnexplainedIds $unexplainedIds -Marker $Marker -MatchedTurnId $matchedTurnId)
            if ($conflicts.Count -gt 0) { throw 'Unexplained new turns were present on the resumed thread.' }
            $blocking = @(Get-CodexAppServerBlockingOwningTurnIds -Thread $Prepared.thread -Marker $Marker)
            foreach ($id in @($blocking)) {
                [void]$observedBlocking.Add([string]$id)
                [void]$knownBaseline.Add([string]$id)
            }
            if ($matchRecords.Count -eq 1) {
                Save-CodexAppServerClientStatus -Client $Prepared.client -Paths $Paths -ThreadId $ThreadId
                return [ordered]@{ prepared = $Prepared; action = 'attach'; blocking_ids = @($observedBlocking); matched_turn_id = $matchedTurnId }
            }
            $statusBusy = Test-CodexAppServerThreadStatusBusy -Thread $Prepared.thread
            if ($blocking.Count -gt 0 -or $statusBusy) {
                if (Test-CodexAppServerCallbackStillPendingSend -Paths $Paths) {
                    Set-CodexAppServerRunQueueState -Paths $Paths -QueueState 'queued'
                }
                Save-CodexAppServerClientStatus -Client $Prepared.client -Paths $Paths -ThreadId $ThreadId -CallbackOwnerState 'queued'
                Start-Sleep -Milliseconds 200
                continue
            }
            Save-CodexAppServerClientStatus -Client $Prepared.client -Paths $Paths -ThreadId $ThreadId
            return [ordered]@{ prepared = $Prepared; action = 'send'; blocking_ids = @($observedBlocking); matched_turn_id = '' }
        } catch {
            $waitMessage = [string]$_.Exception.Message
            if (
                $waitMessage -ceq 'Multiple or conflicting wake-marker turns were present.' -or
                $waitMessage -ceq 'Unexplained new turns were present on the resumed thread.' -or
                $waitMessage -ceq (Get-CodexAppServerPublicMessage -Code 'DURABLE_CHAIN_INVALID') -or
                $waitMessage -ceq (Get-CodexAppServerPublicMessage -Code 'OWNER_INVALID') -or
                $waitMessage -ceq (Get-CodexAppServerPublicMessage -Code 'THREAD_OWNER_CONFLICT') -or
                $waitMessage -ceq (Get-CodexAppServerPublicMessage -Code 'STABLE_PROTOCOL_INVALID')
            ) { throw }
            if (-not (Test-CodexAppServerTransportLossMessage -Message $waitMessage)) { throw }
            if (-not (Test-CodexAppServerCallbackStillPendingSend -Paths $Paths)) { throw }
            try { Stop-CodexAppServerClient -Client $Prepared.client -StderrEvidencePath ([string]$Paths.stderr_evidence) } catch { }
            $Prepared = Invoke-CodexAppServerConnectAndPrepare -CodexCommand $CodexCommand -Worktree $Worktree -ThreadId $ThreadId -StorePath ([string]$Paths.store) -Profile $Profile -StatusPath ([string]$Paths.status)
            foreach ($id in @(Get-CodexAppServerBlockingOwningTurnIds -Thread $Prepared.thread -Marker $Marker)) {
                [void]$observedBlocking.Add([string]$id)
                [void]$knownBaseline.Add([string]$id)
            }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Invoke-CodexAppServerRecoverOrSend {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Prepared,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$Marker,
        [Parameter(Mandatory = $true)][string]$TurnText,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object]$BaselineTurnIds,
        [string]$CodexCommand = '',
        [string]$Worktree = '',
        [AllowNull()][object]$Profile = $null,
        [string]$ProfilePath = ''
    )
    $storedBaseline = @(Get-CodexAppServerStringList -Value $BaselineTurnIds)
    $effectiveBaseline = [Collections.Generic.List[string]]::new()
    $effectiveSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in @($storedBaseline)) {
        if ($effectiveSeen.Add([string]$id)) { $effectiveBaseline.Add([string]$id) }
    }
    foreach ($id in @(Get-CodexAppServerStringList -Value (Get-CodexAppServerSiblingSelectedTurnIds -Paths $Paths -ThreadId $ThreadId))) {
        if ($effectiveSeen.Add([string]$id)) { $effectiveBaseline.Add([string]$id) }
    }
    $found = Find-CodexAppServerMatchingTurns -Thread $Prepared.thread -Marker $Marker -BaselineTurnIds @($effectiveBaseline) -ExpectedText $TurnText
    $matchRecords = [Collections.Generic.List[object]]::new()
    foreach ($item in (Get-CodexAppServerMatchRecords -Value $found.matches)) { $matchRecords.Add($item) }
    $unexplainedIds = [Collections.Generic.List[string]]::new()
    foreach ($item in (Get-CodexAppServerStringRecords -Value $found.unexplained)) { $unexplainedIds.Add([string]$item) }
    if ($matchRecords.Count -gt 1) { throw 'Multiple or conflicting wake-marker turns were present.' }
    if ($storedBaseline.Count -eq 0) {
        $adopted = [string[]]@()
        $adoptOk = $false
        $emptyConflicts = @(Get-CodexAppServerConflictingUnexplainedIds -Thread $Prepared.thread -UnexplainedIds @($unexplainedIds) -Marker $Marker -MatchedTurnId '')
        if ($unexplainedIds.Count -eq 0) {
            $adoptOk = $true
        } else {
            $adopted = Try-CodexAppServerAdoptPreIntentUnexplained -Prepared $Prepared -Paths $Paths -UnexplainedIds @($unexplainedIds)
            if ($null -ne $adopted) { $adoptOk = $true }
        }
        if ($adoptOk) {
            $captured = [Collections.Generic.List[string]]::new()
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($id in @(Get-CodexAppServerStringList -Value @($effectiveBaseline))) {
                if ($seen.Add([string]$id)) { $captured.Add([string]$id) }
            }
            foreach ($id in @(Get-CodexAppServerStringList -Value $adopted)) {
                if ($seen.Add([string]$id)) { $captured.Add([string]$id) }
            }
            if ($captured.Count -gt 0) {
                Write-CodexAppServerCapturedBaseline -Paths $Paths -Baseline @($captured)
            }
            $unexplainedIds.Clear()
        } elseif ($matchRecords.Count -eq 0 -and $emptyConflicts.Count -gt 0) {
            $migratedResult = Complete-CodexAppServerUnsafeLegacyEmptyBaseline -Paths $Paths -ThreadId $ThreadId -RunId ([IO.Path]::GetFileName([string]$Paths.run_root))
            return [ordered]@{
                turn_id = ''
                recovered = $false
                existing = $false
                migrated = $true
                result = $migratedResult
                prepared = $Prepared
            }
        }
    }

    if ([IO.File]::Exists($Paths.bound_turn) -or [IO.File]::Exists($Paths.ack)) {
        $turnId = ''
        if ([IO.File]::Exists($Paths.bound_turn)) {
            $bound = (Read-TelephoneJson -Path $Paths.bound_turn).value
            $turnId = Get-CodexAppServerDictString -Dict $bound -Key 'turn_id'
            $boundThread = Get-CodexAppServerDictString -Dict $bound -Key 'thread_id'
            if ([string]::IsNullOrWhiteSpace($turnId)) { throw 'Bound turn record is missing turn_id.' }
            if ($boundThread -cne $ThreadId) { throw 'Durable bound-turn thread does not match.' }
        }
        if ([IO.File]::Exists($Paths.ack)) {
            $ack = (Read-TelephoneJson -Path $Paths.ack).value
            $ackTurn = Get-CodexAppServerDictString -Dict $ack -Key 'turn_id'
            $ackSession = Get-CodexAppServerDictString -Dict $ack -Key 'session_id'
            if ([string]::IsNullOrWhiteSpace($ackTurn) -or [string]::IsNullOrWhiteSpace($ackSession)) {
                throw 'Durable wake acknowledgment is malformed.'
            }
            if ($ackSession -cne $ThreadId) { throw 'Durable ack session does not match.' }
            if ([string]::IsNullOrWhiteSpace($turnId)) { $turnId = $ackTurn }
            elseif ($ackTurn -cne $turnId) { throw 'Durable ack turn conflicts with the bound turn.' }
        }
        $presentIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($id in (Get-CodexAppServerStringRecords -Value (Get-CodexAppServerTurnIdsFromThread -Thread $Prepared.thread))) {
            [void]$presentIds.Add([string]$id)
        }
        if (-not $presentIds.Contains($turnId)) {
            throw 'Bound turn is missing from the resumed thread.'
        }
        $boundConflicts = @(Get-CodexAppServerConflictingUnexplainedIds -Thread $Prepared.thread -UnexplainedIds @($unexplainedIds) -Marker $Marker -MatchedTurnId $turnId)
        if ($boundConflicts.Count -gt 0) {
            throw 'Unexplained new turns were present on the resumed thread.'
        }
        if ($matchRecords.Count -eq 1) {
            $matchedId = Get-CodexAppServerDictString -Dict $matchRecords[0] -Key 'turn_id'
            if ($matchedId -cne $turnId) {
                throw 'Recovered wake-marker turn conflicts with the bound turn.'
            }
        }
        if (Test-CodexAppServerRecoveryCommitPending -Paths $Paths) {
            Complete-CodexAppServerRecoveryCommit -Paths $Paths -ThreadId $ThreadId -TurnId $turnId
        }
        Bind-CodexAppServerTurnAndAck -Paths $Paths -ThreadId $ThreadId -TurnId $turnId -BoundState 'active'
        return [ordered]@{ turn_id = $turnId; recovered = $true; existing = $true; prepared = $Prepared }
    }

    if ($matchRecords.Count -eq 1) {
        $turnId = Get-CodexAppServerDictString -Dict $matchRecords[0] -Key 'turn_id'
        $matchConflicts = @(Get-CodexAppServerConflictingUnexplainedIds -Thread $Prepared.thread -UnexplainedIds @($unexplainedIds) -Marker $Marker -MatchedTurnId $turnId)
        if ($matchConflicts.Count -gt 0) {
            throw 'Unexplained new turns were present on the resumed thread.'
        }
        if (Test-CodexAppServerRecoveryCommitPending -Paths $Paths) {
            Complete-CodexAppServerRecoveryCommit -Paths $Paths -ThreadId $ThreadId -TurnId $turnId
        }
        Set-CodexAppServerRunQueueState -Paths $Paths -QueueState 'callback_active'
        Bind-CodexAppServerTurnAndAck -Paths $Paths -ThreadId $ThreadId -TurnId $turnId -BoundState 'active'
        return [ordered]@{ turn_id = $turnId; recovered = $true; existing = $true; prepared = $Prepared }
    }

    $waitBaseline = [Collections.Generic.List[string]]::new()
    $waitSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in @(Get-CodexAppServerStringList -Value $effectiveBaseline)) {
        if ($waitSeen.Add([string]$id)) { $waitBaseline.Add([string]$id) }
    }
    if (-not [string]::IsNullOrWhiteSpace($CodexCommand) -and -not [string]::IsNullOrWhiteSpace($Worktree) -and $null -ne $Profile) {
        $waited = Wait-CodexAppServerCallbackEligibility `
            -Prepared $Prepared `
            -Paths $Paths `
            -ThreadId $ThreadId `
            -Marker $Marker `
            -TurnText $TurnText `
            -CodexCommand $CodexCommand `
            -Worktree $Worktree `
            -Profile $Profile `
            -ProfilePath $ProfilePath `
            -BaselineTurnIds @($waitBaseline)
        $Prepared = $waited.prepared
        foreach ($id in @(Get-CodexAppServerStringList -Value (Get-CodexAppServerDictObject -Dict $waited -Key 'blocking_ids'))) {
            if ($waitSeen.Add([string]$id)) { $waitBaseline.Add([string]$id) }
        }
        $found = Find-CodexAppServerMatchingTurns -Thread $Prepared.thread -Marker $Marker -BaselineTurnIds @($waitBaseline) -ExpectedText $TurnText
        $matchRecords = [Collections.Generic.List[object]]::new()
        foreach ($item in (Get-CodexAppServerMatchRecords -Value $found.matches)) { $matchRecords.Add($item) }
        $unexplainedIds = [Collections.Generic.List[string]]::new()
        foreach ($item in (Get-CodexAppServerStringRecords -Value $found.unexplained)) { $unexplainedIds.Add([string]$item) }
        if ($matchRecords.Count -gt 1) { throw 'Multiple or conflicting wake-marker turns were present.' }
        $waitMatched = ''
        if ($matchRecords.Count -eq 1) { $waitMatched = Get-CodexAppServerDictString -Dict $matchRecords[0] -Key 'turn_id' }
        $waitConflicts = @(Get-CodexAppServerConflictingUnexplainedIds -Thread $Prepared.thread -UnexplainedIds @($unexplainedIds) -Marker $Marker -MatchedTurnId $waitMatched)
        if ($waitConflicts.Count -gt 0) { throw 'Unexplained new turns were present on the resumed thread.' }
        if ($matchRecords.Count -eq 1) {
            if (Test-CodexAppServerRecoveryCommitPending -Paths $Paths) {
                Complete-CodexAppServerRecoveryCommit -Paths $Paths -ThreadId $ThreadId -TurnId $waitMatched
            }
            Set-CodexAppServerRunQueueState -Paths $Paths -QueueState 'callback_active'
            Bind-CodexAppServerTurnAndAck -Paths $Paths -ThreadId $ThreadId -TurnId $waitMatched -BoundState 'active'
            return [ordered]@{ turn_id = $waitMatched; recovered = $true; existing = $true; prepared = $Prepared }
        }
        $unexplainedIds.Clear()
    }

    $preSendConflicts = @(Get-CodexAppServerConflictingUnexplainedIds -Thread $Prepared.thread -UnexplainedIds @($unexplainedIds) -Marker $Marker -MatchedTurnId '')
    if ($preSendConflicts.Count -gt 0) {
        throw 'Unexplained new turns were present on the resumed thread.'
    }
    $phase = Get-CodexAppServerCallbackWritePhase -Paths $Paths
    if ($phase -cne 'none') {
        Write-CodexAppServerRecoveryRequired -Paths $Paths -ThreadId $ThreadId
        throw 'Ambiguous callback cannot start another turn.'
    }
    Remove-CodexAppServerDeclarationFile -Path ([string]$Paths.failure)
    Set-CodexAppServerRunQueueState -Paths $Paths -QueueState 'callback_active'
    $started = $null
    while ($null -eq $started) {
        try {
            $started = Send-CodexAppServerWakeTurnOnce -Client $Prepared.client -Paths $Paths -ThreadId $ThreadId -TurnText $TurnText
        } catch {
            $busyByError = Test-CodexAppServerBusyRequestError -ErrorRecord $_
            $busyByTruth = $false
            try {
                $freshBusy = Invoke-CodexAppServerThreadRead -Client $Prepared.client -ThreadId $ThreadId -IncludeTurns $true
                $Prepared.thread = $freshBusy.thread
                $busyByTruth = (
                    (@(Get-CodexAppServerBlockingOwningTurnIds -Thread $Prepared.thread -Marker $Marker).Count -gt 0) -or
                    (Test-CodexAppServerThreadStatusBusy -Thread $Prepared.thread)
                )
            } catch {
                $busyByTruth = $false
            }
            if (-not $busyByError -and -not $busyByTruth) { throw }
            Reset-CodexAppServerBusySendPhase -Paths $Paths
            if ([string]::IsNullOrWhiteSpace($CodexCommand) -or [string]::IsNullOrWhiteSpace($Worktree) -or $null -eq $Profile) { throw }
            $waitedBusy = Wait-CodexAppServerCallbackEligibility `
                -Prepared $Prepared `
                -Paths $Paths `
                -ThreadId $ThreadId `
                -Marker $Marker `
                -TurnText $TurnText `
                -CodexCommand $CodexCommand `
                -Worktree $Worktree `
                -Profile $Profile `
                -ProfilePath $ProfilePath `
                -BaselineTurnIds @($waitBaseline)
            $Prepared = $waitedBusy.prepared
            if ([string](Get-CodexAppServerDictString -Dict $waitedBusy -Key 'action') -ceq 'attach') {
                $attachId = Get-CodexAppServerDictString -Dict $waitedBusy -Key 'matched_turn_id'
                if ([string]::IsNullOrWhiteSpace($attachId)) { throw 'Eligible attach omitted turn id.' }
                if (Test-CodexAppServerRecoveryCommitPending -Paths $Paths) {
                    Complete-CodexAppServerRecoveryCommit -Paths $Paths -ThreadId $ThreadId -TurnId $attachId
                }
                Set-CodexAppServerRunQueueState -Paths $Paths -QueueState 'callback_active'
                Bind-CodexAppServerTurnAndAck -Paths $Paths -ThreadId $ThreadId -TurnId $attachId -BoundState 'active'
                return [ordered]@{ turn_id = $attachId; recovered = $true; existing = $true; prepared = $Prepared }
            }
            continue
        }
    }
    Bind-CodexAppServerTurnAndAck -Paths $Paths -ThreadId $ThreadId -TurnId ([string]$started.turn_id) -BoundState 'active'
    return [ordered]@{ turn_id = [string]$started.turn_id; recovered = $false; existing = $false; prepared = $Prepared }
}

function Write-CodexAppServerRecoveryRequired {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId
    )
    if (Test-CodexAppServerProvenTerminal -Paths $Paths) { return }
    $disp = Get-CodexAppServerRunDisposition -Paths $Paths
    if (Test-CodexAppServerTurnTerminalDisposition -Disposition $disp) { return }
    if ($disp -ceq 'recovered') { return }
    $phaseNow = Get-CodexAppServerCallbackWritePhase -Paths $Paths
    if ($phaseNow -ceq 'terminal_publishing' -or $phaseNow -ceq 'terminal') { return }
    $runId = [IO.Path]::GetFileName([string]$Paths.run_root)
    $phase = 'none'
    $recoveryTurn = ''
    $run = $null
    if ([IO.File]::Exists($Paths.run)) {
        $run = Read-CodexAppServerValidated -Path $Paths.run -SchemaName 'codex-app-server-lead-run'
        $runId = Get-CodexAppServerDictString -Dict $run -Key 'run_id'
        $phase = Get-CodexAppServerDictString -Dict $run -Key 'callback_write_phase'
        $recoveryTurn = Get-CodexAppServerDictString -Dict $run -Key 'selected_turn_id'
    }
    if ([IO.File]::Exists($Paths.bound_turn) -and [string]::IsNullOrWhiteSpace($recoveryTurn)) {
        try {
            $boundNow = Read-CodexAppServerValidated -Path $Paths.bound_turn -SchemaName 'codex-app-server-lead-bound-turn'
            $recoveryTurn = Get-CodexAppServerDictString -Dict $boundNow -Key 'turn_id'
        } catch { $recoveryTurn = '' }
    }
    if (-not [IO.File]::Exists($Paths.recovery)) {
        $null = Write-CodexAppServerValidatedReplace -Path $Paths.recovery -Value ([ordered]@{
            protocol_version = 'telephone-line-codex-app-server-lead-recovery-v1'
            state = 'recovery_required'
            run_id = [string]$runId
            run_root = [string]$Paths.run_root
            thread_id = [string]$ThreadId
            turn_id = [string]$recoveryTurn
            callback_write_phase = [string]$phase
            at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }) -SchemaName 'codex-app-server-lead-recovery' -WriterLabel 'recovery-declaration'
        Invoke-CodexAppServerMaybeCrash -Point 'after-recovery-record'
    }
    if ($null -ne $run) {
        $currentDisp = Get-CodexAppServerDictString -Dict $run -Key 'disposition'
        if ($currentDisp -cne 'recovery_required') {
            $run.disposition = 'recovery_required'
            $run.fallback_required = ''
            $null = Write-CodexAppServerValidatedReplace -Path $Paths.run -Value $run -SchemaName 'codex-app-server-lead-run' -WriterLabel 'recovery-required-run'
        }
    }
    if ([IO.File]::Exists($Paths.bound_turn) -and [IO.File]::Exists($Paths.ack) -and $phase -ceq 'acknowledged') {
        $bound = Read-CodexAppServerValidated -Path $Paths.bound_turn -SchemaName 'codex-app-server-lead-bound-turn'
        $turnId = Get-CodexAppServerDictString -Dict $bound -Key 'turn_id'
        if (-not [string]::IsNullOrWhiteSpace($turnId)) {
            Write-CodexAppServerBoundTurnRecord -Paths $Paths -ThreadId $ThreadId -TurnId $turnId -State 'recovery_required' -WriterLabel 'recovery-required-bound'
        }
    }
}

function New-CodexAppServerWakeResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$Started,
        [Parameter(Mandatory = $true)][bool]$Existing,
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [string]$FallbackRequired = ''
    )
    $doc = [ordered]@{
        started = [bool]$Started
        existing = [bool]$Existing
        state = [string]$State
        run_id = [string]$RunId
        run_root = [string]$RunRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($FallbackRequired)) { $doc.fallback_required = [string]$FallbackRequired }
    return $doc
}

function Test-CodexAppServerFallbackMessage {
    [CmdletBinding()]
    param([AllowNull()][string]$Message)
    return (
        [string]$Message.IndexOf('"fallback_required": "cli"', [StringComparison]::Ordinal) -ge 0 -or
        [string]$Message.IndexOf('"fallback_required":"cli"', [StringComparison]::Ordinal) -ge 0
    )
}

function Get-CodexAppServerCatchClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [AllowNull()][string]$Message
    )
    $phase = Get-CodexAppServerCallbackWritePhase -Paths $Paths
    $current = Get-CodexAppServerRunDisposition -Paths $Paths
    $windowClosed = Test-CodexAppServerFallbackWindowClosed -Paths $Paths
    $hasBoundOrAck = ([IO.File]::Exists($Paths.ack) -or [IO.File]::Exists($Paths.bound_turn))
    $proven = Test-CodexAppServerProvenTerminal -Paths $Paths
    $publishing = ($phase -ceq 'terminal_publishing')
    $alreadyRecovery = ($current -ceq 'recovery_required')
    $alreadyRecovered = ($current -ceq 'recovered')
    $fallback = ''
    $state = 'failed'
    $code = 'worker_failed'
    $publicationDisposition = 'in_progress'
    if (-not [string]::IsNullOrWhiteSpace($current) -and $current -cne 'recovery_required' -and $current -cne 'fallback_required_cli') {
        $publicationDisposition = [string]$current
    }
    $compatLike = (
        (Test-CodexAppServerCompatibilityFailureMessage -Message $Message) -or
        (Test-CodexAppServerFallbackMessage -Message $Message)
    )
    if ($alreadyRecovered) {
        $state = 'recovered'
        $code = 'worker_failed'
        $fallback = ''
        if ($compatLike) { $code = 'compatibility_drift_after_bind' }
        elseif ($hasBoundOrAck) { $code = 'transport_lost_before_terminal' }
    } elseif ($compatLike) {
        if ($proven) {
            $code = 'compatibility_drift_after_bind'
            $state = [string]$current
            $fallback = ''
        } elseif ($publishing) {
            $code = 'compatibility_drift_after_bind'
            $state = [string]$publicationDisposition
            $fallback = ''
        } elseif ($alreadyRecovery -or $windowClosed) {
            $code = 'compatibility_drift_after_bind'
            $state = 'recovery_required'
            $fallback = ''
        } else {
            $fallback = 'cli'
            $state = 'fallback_required_cli'
            $code = 'schema_or_version_mismatch'
        }
    } elseif ($hasBoundOrAck) {
        if ($proven) {
            $state = [string]$current
            $code = 'worker_failed'
        } elseif ($publishing) {
            $state = [string]$publicationDisposition
            $code = 'transport_lost_before_terminal'
        } else {
            $state = 'recovery_required'
            $code = 'transport_lost_before_terminal'
        }
    } elseif ($alreadyRecovery) {
        $state = 'recovery_required'
        $code = 'worker_failed'
        $fallback = ''
    } elseif ($windowClosed -and -not $proven -and -not $publishing) {
        $state = 'recovery_required'
        $code = 'worker_failed'
        $fallback = ''
    }
    return [ordered]@{
        state = [string]$state
        code = [string]$code
        fallback = [string]$fallback
        phase = [string]$phase
        current = [string]$current
        publishing = [bool]$publishing
        already_recovery = [bool]$alreadyRecovery
        already_recovered = [bool]$alreadyRecovered
        proven = [bool]$proven
    }
}

function Complete-CodexAppServerQueuedItemFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [AllowNull()][string]$Message,
        [bool]$Existing = $false
    )
    $classified = $null
    try {
        $classified = Get-CodexAppServerCatchClassification -Paths $Paths -Message $Message
    } catch {
        $classified = [ordered]@{
            state = 'failed'
            code = 'worker_failed'
            fallback = ''
            phase = 'none'
            current = ''
            publishing = $false
            already_recovery = $false
            already_recovered = $false
            proven = $false
        }
    }
    $fallback = [string]$classified.fallback
    $state = [string]$classified.state
    $code = [string]$classified.code
    $alreadyRecovered = $false
    if ($classified.Contains('already_recovered')) { $alreadyRecovered = [bool]$classified.already_recovered }
    if (-not $alreadyRecovered) {
        $skipDeclarations = (
            [bool]$classified.publishing -or
            [bool]$classified.proven -or
            [string]$classified.phase -ceq 'terminal_publishing' -or
            [string]$classified.phase -ceq 'terminal'
        )
        try {
            if (-not $skipDeclarations) {
                Write-CodexAppServerFailureRecord -Paths $Paths -Category 'worker' -Code $code -ThreadId $ThreadId
                Invoke-CodexAppServerMaybeCrash -Point 'after-failure-snapshot'
            }
        } catch { }
        $needRecovery = ($state -ceq 'recovery_required' -and -not $skipDeclarations)
        if ($needRecovery) {
            try {
                Write-CodexAppServerRecoveryRequired -Paths $Paths -ThreadId $ThreadId
            } catch { }
        } else {
            try {
                if ([IO.File]::Exists($Paths.run) -and -not (Test-CodexAppServerTurnTerminalDisposition -Disposition (Get-CodexAppServerRunDisposition -Paths $Paths))) {
                    $run = Read-CodexAppServerValidated -Path $Paths.run -SchemaName 'codex-app-server-lead-run'
                    $persist = [string]$state
                    if ($persist -ceq 'failed') { $persist = 'in_progress' }
                    if (Test-CodexAppServerTurnTerminalDisposition -Disposition $persist) { $persist = 'in_progress' }
                    $phaseNow = Get-CodexAppServerDictString -Dict $run -Key 'callback_write_phase'
                    if ([bool]$classified.already_recovery) {
                        $needRecovery = $true
                        $fallback = ''
                        $state = 'recovery_required'
                    }
                    if ($skipDeclarations) {
                        if ($persist -ceq 'recovery_required' -or $persist -ceq 'fallback_required_cli') {
                            $keep = Get-CodexAppServerDictString -Dict $run -Key 'disposition'
                            if ([string]::IsNullOrWhiteSpace($keep) -or $keep -ceq 'recovery_required' -or $keep -ceq 'fallback_required_cli') {
                                $keep = 'in_progress'
                            }
                            $persist = [string]$keep
                        }
                        $fallback = ''
                        $state = [string]$persist
                    }
                    if ($persist -ceq 'fallback_required_cli' -and $phaseNow -cne 'none') {
                        $needRecovery = $true
                        $fallback = ''
                        $state = 'recovery_required'
                    }
                    if ($needRecovery -and -not $skipDeclarations) {
                        Write-CodexAppServerRecoveryRequired -Paths $Paths -ThreadId $ThreadId
                    } elseif ($persist -cne 'recovery_required' -and -not $skipDeclarations) {
                        $run.disposition = $persist
                        $run.fallback_required = $fallback
                        $null = Write-CodexAppServerValidatedReplace -Path $Paths.run -Value $run -SchemaName 'codex-app-server-lead-run' -WriterLabel 'catch-run'
                    }
                }
            } catch { }
        }
    }
    $result = New-CodexAppServerWakeResult -Started $false -Existing $Existing -State $state -RunId $RunId -RunRoot ([string]$Paths.run_root) -FallbackRequired $fallback
    $resultState = [string]$state
    if ($resultState -ceq 'failed') { $resultState = 'in_progress' }
    if ([bool]$classified.already_recovery) { $resultState = 'recovery_required' }
    if ($alreadyRecovered) { $resultState = 'recovered' }
    $phaseNow = Get-CodexAppServerCallbackWritePhase -Paths $Paths
    if ([bool]$classified.publishing) {
        if ($resultState -ceq 'recovery_required' -or $resultState -ceq 'fallback_required_cli' -or (Test-CodexAppServerTurnTerminalDisposition -Disposition $resultState)) {
            $resultState = 'in_progress'
            $kept = Get-CodexAppServerRunDisposition -Paths $Paths
            if (-not [string]::IsNullOrWhiteSpace($kept) -and $kept -cne 'recovery_required' -and $kept -cne 'fallback_required_cli') {
                $resultState = [string]$kept
            }
        }
    }
    if (
        (Test-CodexAppServerTurnTerminalDisposition -Disposition $resultState) -and
        $phaseNow -cne 'terminal' -and
        $phaseNow -cne 'terminal_publishing'
    ) {
        $resultState = 'in_progress'
    }
    try { $null = Write-CodexAppServerOfficialLauncherResult -Paths $Paths -Started $false -Existing $Existing -State $resultState -RunId $RunId -FallbackRequired $fallback } catch { }
    return [ordered]@{
        result = $result
        state = [string]$resultState
        fallback_required = [string]$fallback
        classified = $classified
    }
}

function Test-CodexAppServerRunQueueRetired {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Paths)
    if (-not [IO.File]::Exists($Paths.run)) { return $false }
    try {
        $run = Read-CodexAppServerValidated -Path $Paths.run -SchemaName 'codex-app-server-lead-run'
        return ((Get-CodexAppServerDictString -Dict $run -Key 'queue_state') -ceq 'retired')
    } catch {
        return $false
    }
}

function Test-CodexAppServerRunStillQueued {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Paths)
    if (Test-CodexAppServerCompleteOfficialTerminal -Paths $Paths) { return $false }
    if (Test-CodexAppServerRunQueueRetired -Paths $Paths) { return $false }
    $disp = Get-CodexAppServerRunDisposition -Paths $Paths
    if (Test-CodexAppServerTurnTerminalDisposition -Disposition $disp) { return $false }
    return $true
}

function Set-CodexAppServerRunQueueState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$QueueState
    )
    if (-not [IO.File]::Exists($Paths.run)) { return }
    $run = Read-CodexAppServerValidated -Path $Paths.run -SchemaName 'codex-app-server-lead-run'
    $run.queue_state = [string]$QueueState
    $null = Write-CodexAppServerValidatedReplace -Path $Paths.run -Value $run -SchemaName 'codex-app-server-lead-run' -WriterLabel 'queue-state'
}

function Write-CodexAppServerQueuedCallback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][object]$CallbackIdentity,
        [Parameter(Mandatory = $true)][string]$Marker,
        [Parameter(Mandatory = $true)][object]$Profile,
        [string]$ProfilePath = '',
        [string]$CodexCommand = ''
    )
    $profileFile = if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) { [IO.Path]::GetFullPath($ProfilePath) } else { [string]$Paths.profile }
    $compat = Get-CodexAppServerCompatibilityIdentity -Profile $Profile -ProfilePath $profileFile
    [IO.Directory]::CreateDirectory($Paths.run_root) | Out-Null
    $baseline = [string[]]@()
    $intentExists = [IO.File]::Exists($Paths.intent)
    $runExists = [IO.File]::Exists($Paths.run)
    $snapshotProven = $true
    if (-not $intentExists -and -not $runExists) {
        $snapshot = Get-CodexAppServerAdmissionBaselineSnapshot -Paths $Paths -ThreadId $ThreadId -CodexCommand $CodexCommand -Worktree $Worktree -Profile $Profile -ProfilePath $profileFile
        $snapshotProven = [bool]$snapshot.proven
        $baseline = @(Get-CodexAppServerStringList -Value $snapshot.ids)
        if (-not $snapshotProven) {
            $baseline = [string[]]@()
        }
    } elseif ($intentExists) {
        try {
            $existingIntent = Read-CodexAppServerValidated -Path $Paths.intent -SchemaName 'codex-app-server-lead-intent'
            $baseline = @(Get-CodexAppServerStringList -Value (Get-CodexAppServerDictObject -Dict $existingIntent -Key 'baseline_turn_ids'))
        } catch {
            $baseline = [string[]]@()
        }
    }
    if (-not $intentExists) {
        $null = Write-CodexAppServerValidatedReplace -Path $Paths.intent -Value ([ordered]@{
            protocol_version = 'telephone-line-codex-app-server-lead-intent-v1'
            run_id = [string]$RunId
            thread_id = [string]$ThreadId
            worktree = [string]$Worktree
            callback = [ordered]@{
                path = [string]$CallbackIdentity.path
                bytes = [int64]$CallbackIdentity.bytes
                sha256 = [string]$CallbackIdentity.sha256
            }
            wake_marker = [string]$Marker
            profile_fingerprint = [string]$compat.profile_fingerprint
            codex_version = [string]$compat.codex_version
            executable_sha256 = [string]$compat.executable_sha256
            profile_sha256 = [string]$compat.profile_sha256
            codex_command = [string]$compat.codex_command
            service_tier = [string]$compat.service_tier
            baseline_turn_ids = @($baseline)
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }) -SchemaName 'codex-app-server-lead-intent'
    }
    if (-not $runExists) {
        $null = Write-CodexAppServerValidatedReplace -Path $Paths.run -Value ([ordered]@{
            protocol_version = $script:CodexAppServerRunProtocol
            run_id = [string]$RunId
            thread_id = [string]$ThreadId
            worktree = [string]$Worktree
            callback = [ordered]@{
                path = [string]$CallbackIdentity.path
                bytes = [int64]$CallbackIdentity.bytes
                sha256 = [string]$CallbackIdentity.sha256
            }
            wake_marker = [string]$Marker
            profile_fingerprint = [string]$compat.profile_fingerprint
            codex_version = [string]$compat.codex_version
            executable_sha256 = [string]$compat.executable_sha256
            profile_sha256 = [string]$compat.profile_sha256
            codex_command = [string]$compat.codex_command
            service_tier = [string]$compat.service_tier
            baseline_turn_ids = @($baseline)
            selected_turn_id = ''
            disposition = 'in_progress'
            callback_write_phase = 'none'
            terminal_target = ''
            fallback_required = ''
            queue_state = 'queued'
        }) -SchemaName 'codex-app-server-lead-run'
    }
    if ((-not $intentExists) -and (-not $runExists) -and -not $snapshotProven) {
        $failed = Complete-CodexAppServerCallbackDiagnosticTerminal -Paths $Paths -ThreadId $ThreadId -RunId $RunId -TransitionState 'admission_snapshot_unproven' -WriterLabel 'admission-snapshot-unproven'
        Write-Output -NoEnumerate -InputObject ([ordered]@{ queued = $false; result = $failed })
        return
    }
    Write-Output -NoEnumerate -InputObject ([ordered]@{ queued = $true; result = $null })
}

# Current Understanding (execution, 2026-08-27 owner-observe race):
# 1. Phase: close post-activation OWNER_INVALID race on candidate c0b1362c; preserve accepted proofs; amend the same one commit over 6c9d25e.
# 2. Denominator: thread-owner disappearance/replacement during observation is re-evaluated; stable malformed/wrong-thread remains OWNER_INVALID; ack/terminal already published wins; owner absence never invents success.
# 3. Only next step: Lifecycle observation retry + focused race regression, then frozen union.
# 4. Frozen non-goals: no Common/schema/dashboard/core mutation, no runtime activation, no real smoke.
# 5. Exit: WakeAmbiguityRepairOnly plus frozen union, clean one commit over 6c9d25e, self_accepted=false; not project PASS.
function Test-CodexAppServerConsumeOwnerObserveFault {
    [CmdletBinding()]
    param()
    $raw = [string][Environment]::GetEnvironmentVariable('TELEPHONE_TEST_APP_SERVER_OWNER_OBSERVE_FAULT')
    if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
    $remaining = 0
    if (-not [int]::TryParse($raw, [ref]$remaining) -or $remaining -le 0) { return $false }
    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_APP_SERVER_OWNER_OBSERVE_FAULT', [string]($remaining - 1), 'Process')
    return $true
}

function Read-CodexAppServerThreadOwner {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$ThreadPaths)
    $path = [string]$ThreadPaths.owner
    $attempts = 0
    while ($true) {
        if (-not [IO.File]::Exists($path)) { return $null }
        if (Test-CodexAppServerConsumeOwnerObserveFault) {
            Start-Sleep -Milliseconds 20
            $attempts += 1
            continue
        }
        $owner = $null
        try {
            $owner = Read-CodexAppServerValidated -Path $path -SchemaName 'codex-app-server-lead-owner' -Code 'OWNER_INVALID'
        } catch {
            if (-not [IO.File]::Exists($path)) { return $null }
            $attempts += 1
            if ($attempts -ge 8) { Throw-CodexAppServerPublic -Code 'OWNER_INVALID' }
            Start-Sleep -Milliseconds 25
            continue
        }
        Assert-CodexAppServerExactThreadOwnerIdentity -Owner $owner -ThreadId ([string]$ThreadPaths.thread_id)
        return $owner
    }
}

function Assert-CodexAppServerExactThreadOwnerIdentity {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Owner,
        [Parameter(Mandatory = $true)][string]$ThreadId
    )
    if ($Owner -isnot [Collections.IDictionary]) { Throw-CodexAppServerPublic -Code 'OWNER_INVALID' }
    $expected = [string]$ThreadId
    if ([string]::IsNullOrWhiteSpace($expected)) { Throw-CodexAppServerPublic -Code 'THREAD_ID_INVALID' }
    $stored = Get-CodexAppServerDictString -Dict $Owner -Key 'thread_id'
    if ([string]::IsNullOrWhiteSpace($stored) -or $stored -cne $expected) {
        Throw-CodexAppServerPublic -Code 'OWNER_INVALID'
    }
}

function Test-CodexAppServerThreadOwnerAlive {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$ThreadPaths)
    if (-not [IO.File]::Exists($ThreadPaths.owner)) { return $false }
    $owner = Read-CodexAppServerThreadOwner -ThreadPaths $ThreadPaths
    if ($null -eq $owner) { return $false }
    return (Test-TelephoneOwnerAlive -Owner $owner)
}

function Enter-CodexAppServerThreadOwner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$ThreadPaths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [string]$ActiveRunId = ''
    )
    Assert-CodexAppServerThreadId -ThreadId $ThreadId
    $self = New-CodexAppServerOwnerRecord -ThreadId $ThreadId -ActiveRunId $ActiveRunId
    $existing = Read-CodexAppServerThreadOwner -ThreadPaths $ThreadPaths
    if ($null -ne $existing) {
        if ((Test-TelephoneOwnerAlive -Owner $existing) -and [int]$existing.pid -ne [int]$PID) {
            Throw-CodexAppServerPublic -Code 'THREAD_OWNER_CONFLICT'
        }
        if ((Test-TelephoneOwnerAlive -Owner $existing) -and [int]$existing.pid -eq [int]$PID) {
            return $existing
        }
    }
    [IO.Directory]::CreateDirectory($ThreadPaths.thread_root) | Out-Null
    $null = Write-CodexAppServerValidatedReplace -Path $ThreadPaths.owner -Value $self -SchemaName 'codex-app-server-lead-owner' -PublicationPoint 'owner-replace'
    return $self
}

function Write-CodexAppServerRunOwnerProjection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][object]$Owner,
        [string]$ThreadId = '',
        [string]$ActiveRunId = ''
    )
    $doc = [ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-owner-v1'
        pid = [int]$Owner.pid
        start_time_utc_ticks = [int64]$Owner.start_time_utc_ticks
        started_at_utc = [string]$Owner.started_at_utc
    }
    $thread = [string]$ThreadId
    if ([string]::IsNullOrWhiteSpace($thread)) { $thread = Get-CodexAppServerDictString -Dict $Owner -Key 'thread_id' }
    $runId = [string]$ActiveRunId
    if ([string]::IsNullOrWhiteSpace($runId)) { $runId = Get-CodexAppServerDictString -Dict $Owner -Key 'active_run_id' }
    if (-not [string]::IsNullOrWhiteSpace($thread)) { $doc.thread_id = $thread }
    if (-not [string]::IsNullOrWhiteSpace($runId)) { $doc.active_run_id = $runId }
    $null = Write-CodexAppServerValidatedReplace -Path $Paths.owner -Value $doc -SchemaName 'codex-app-server-lead-owner' -PublicationPoint 'owner-replace'
}

function Complete-CodexAppServerRunOwnerRetirement {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Paths)
    if ([IO.File]::Exists($Paths.run)) {
        try { Set-CodexAppServerRunQueueState -Paths $Paths -QueueState 'retired' } catch { }
    }
    foreach ($name in @('owner', 'child')) {
        $path = [string]$Paths[$name]
        if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.File]::Exists($path)) { continue }
        try { [IO.File]::Delete($path) } catch { }
    }
}

function Complete-CodexAppServerThreadOwnerQuiesce {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$ThreadPaths,
        [AllowNull()][object]$Client,
        [string]$StderrEvidencePath = ''
    )
    try { Stop-CodexAppServerClient -Client $Client -StderrEvidencePath $StderrEvidencePath } catch { }
    if (-not [IO.File]::Exists($ThreadPaths.owner)) { return }
    try {
        $owner = Read-CodexAppServerValidated -Path $ThreadPaths.owner -SchemaName 'codex-app-server-lead-owner' -Code 'OWNER_INVALID'
        $storedThread = Get-CodexAppServerDictString -Dict $owner -Key 'thread_id'
        if ([int]$owner.pid -eq [int]$PID -and $storedThread -ceq [string]$ThreadPaths.thread_id) {
            try { [IO.File]::Delete($ThreadPaths.owner) } catch { }
        }
    } catch { }
}

function Get-CodexAppServerThreadQueueItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$Worktree
    )
    $items = [Collections.Generic.List[object]]::new()
    $runsDir = [IO.Path]::GetFullPath((Join-Path $StateRoot 'runs'))
    if (-not [IO.Directory]::Exists($runsDir)) { return @() }
    foreach ($dir in [IO.Directory]::GetDirectories($runsDir)) {
        $runId = [IO.Path]::GetFileName($dir)
        try { Assert-CodexAppServerRunId -RunId $runId } catch { Throw-CodexAppServerPublic -Code 'CALLBACK_QUEUE_INVALID' }
        $paths = Get-CodexAppServerRunPaths -StateRoot $StateRoot -RunId $runId
        if (-not [IO.File]::Exists($paths.intent)) { continue }
        $intent = $null
        try {
            $intent = Read-CodexAppServerValidated -Path $paths.intent -SchemaName 'codex-app-server-lead-intent'
        } catch {
            Throw-CodexAppServerPublic -Code 'CALLBACK_QUEUE_INVALID'
        }
        $intentThread = Get-CodexAppServerDictString -Dict $intent -Key 'thread_id'
        if ($intentThread -cne $ThreadId) { continue }
        $intentWorktree = Get-CodexAppServerDictString -Dict $intent -Key 'worktree'
        if ($intentWorktree -cne $Worktree) { Throw-CodexAppServerPublic -Code 'CALLBACK_QUEUE_INVALID' }
        if ([IO.File]::Exists($paths.run)) {
            try {
                $null = Read-CodexAppServerValidated -Path $paths.run -SchemaName 'codex-app-server-lead-run'
            } catch {
                Throw-CodexAppServerPublic -Code 'CALLBACK_QUEUE_INVALID'
            }
        }
        if (-not (Test-CodexAppServerRunStillQueued -Paths $paths)) { continue }
        $created = Get-CodexAppServerDictString -Dict $intent -Key 'created_at_utc'
        if ([string]::IsNullOrWhiteSpace($created)) { $created = '9999-12-31T00:00:00.0000000+00:00' }
        $items.Add([ordered]@{
            run_id = [string]$runId
            created_at_utc = [string]$created
            paths = $paths
            intent = $intent
        })
    }
    return @($items | Sort-Object { [string]$_.created_at_utc }, { [string]$_.run_id })
}

function Invoke-CodexAppServerProcessQueuedItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [AllowNull()][object]$Prepared
    )
    $intent = Read-CodexAppServerValidated -Path $Paths.intent -SchemaName 'codex-app-server-lead-intent'
    Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $intent -Key 'run_id') -Right $RunId -Label 'run id'
    Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $intent -Key 'thread_id') -Right $ThreadId -Label 'thread id'
    Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $intent -Key 'worktree') -Right $Worktree -Label 'worktree'
    $callback = Get-CodexAppServerDictObject -Dict $intent -Key 'callback'
    $promptPath = Get-CodexAppServerDictString -Dict $callback -Key 'path'
    $promptPath = Assert-TelephoneRegularFilePath -Path $promptPath -Label 'Prompt file'
    $promptIdentity = Get-TelephoneFileIdentity -Path $promptPath
    $marker = Get-CodexAppServerDictString -Dict $intent -Key 'wake_marker'
    Assert-CodexAppServerDurableChain -Paths $Paths -RunId $RunId -ThreadId $ThreadId -Worktree $Worktree -CallbackIdentity $promptIdentity -Marker $marker -Profile $Profile -ProfilePath $ProfilePath
    Clear-CodexAppServerPublishResidue -Directory $Paths.run_root
    $finished = Complete-CodexAppServerTerminalPublicationFromDisk -Paths $Paths -RunId $RunId -ThreadId $ThreadId
    if ($null -ne $finished) {
        Complete-CodexAppServerDeclarationRetirement -Paths $Paths
        Complete-CodexAppServerRunOwnerRetirement -Paths $Paths
        return [ordered]@{ prepared = $Prepared; result = $finished }
    }
    if (Test-CodexAppServerCompleteOfficialTerminal -Paths $Paths) {
        $disp = Get-CodexAppServerRunDisposition -Paths $Paths
        $written = Write-CodexAppServerOfficialLauncherResult -Paths $Paths -Started $true -Existing $true -State $disp -RunId $RunId
        Complete-CodexAppServerDeclarationRetirement -Paths $Paths
        Complete-CodexAppServerRunOwnerRetirement -Paths $Paths
        return [ordered]@{ prepared = $Prepared; result = $written }
    }
    $promptBytes = [IO.File]::ReadAllBytes([string]$promptIdentity.path)
    $promptText = [Text.UTF8Encoding]::new($false, $true).GetString($promptBytes)
    $turnText = New-CodexAppServerTurnInputText -PromptText $promptText -RunId $RunId
    if (Test-CodexAppServerCallbackStillPendingSend -Paths $Paths) {
        Set-CodexAppServerRunQueueState -Paths $Paths -QueueState 'queued'
    }
    $env:TELEPHONE_APP_SERVER_THREAD_STORE = [string]$Paths.store
    $preparedCreatedHere = $false
    if ($null -eq $Prepared -or $null -eq $Prepared.client) {
        $Prepared = Invoke-CodexAppServerConnectAndPrepare -CodexCommand $CodexCommand -Worktree $Worktree -ThreadId $ThreadId -StorePath ([string]$Paths.store) -Profile $Profile -StatusPath ([string]$Paths.status)
        $preparedCreatedHere = $true
    } else {
        $fresh = Invoke-CodexAppServerThreadRead -Client $Prepared.client -ThreadId $ThreadId -IncludeTurns $true
        $Prepared.thread = $fresh.thread
        $Prepared.baseline_turn_ids = [string[]](Get-CodexAppServerTurnIdsFromThread -Thread $fresh.thread)
        $Prepared.thread_id = $ThreadId
    }
    try {
    $null = Write-CodexAppServerValidatedReplace -Path $Paths.child -Value $Prepared.client.child -SchemaName 'codex-app-server-lead-child'
    Add-CodexAppServerTransition -Path $Paths.transitions -State 'baseline_recorded'
    $baseline = @(Get-CodexAppServerStringList -Value (Get-CodexAppServerDictObject -Dict $intent -Key 'baseline_turn_ids'))
    if ($baseline.Count -eq 0 -and [IO.File]::Exists($Paths.run)) {
        $runNow = Read-CodexAppServerValidated -Path $Paths.run -SchemaName 'codex-app-server-lead-run'
        $baseline = @(Get-CodexAppServerStringList -Value (Get-CodexAppServerDictObject -Dict $runNow -Key 'baseline_turn_ids'))
    }
    if (-not [IO.File]::Exists($Paths.run)) {
        $compat = Get-CodexAppServerCompatibilityIdentity -Profile $Profile -ProfilePath $ProfilePath
        $null = Write-CodexAppServerValidatedReplace -Path $Paths.run -Value ([ordered]@{
            protocol_version = $script:CodexAppServerRunProtocol
            run_id = [string]$RunId
            thread_id = [string]$ThreadId
            worktree = [string]$Worktree
            callback = [ordered]@{
                path = [string]$promptIdentity.path
                bytes = [int64]$promptIdentity.bytes
                sha256 = [string]$promptIdentity.sha256
            }
            wake_marker = $marker
            profile_fingerprint = [string]$compat.profile_fingerprint
            codex_version = [string]$compat.codex_version
            executable_sha256 = [string]$compat.executable_sha256
            profile_sha256 = [string]$compat.profile_sha256
            codex_command = [string]$compat.codex_command
            service_tier = [string]$compat.service_tier
            baseline_turn_ids = @($baseline)
            selected_turn_id = ''
            disposition = 'in_progress'
            callback_write_phase = 'none'
            terminal_target = ''
            fallback_required = ''
            queue_state = 'callback_active'
        }) -SchemaName 'codex-app-server-lead-run'
    }
    $wake = Invoke-CodexAppServerRecoverOrSend `
        -Prepared $Prepared `
        -Paths $Paths `
        -ThreadId $ThreadId `
        -Marker $marker `
        -TurnText $turnText `
        -BaselineTurnIds $baseline `
        -CodexCommand $CodexCommand `
        -Worktree $Worktree `
        -Profile $Profile `
        -ProfilePath $ProfilePath
    if ($wake -is [Collections.IDictionary] -and $wake.Contains('prepared') -and $null -ne $wake.prepared) {
        $Prepared = $wake.prepared
    }
    if ($wake -is [Collections.IDictionary] -and $wake.Contains('migrated') -and [bool]$wake.migrated) {
        Complete-CodexAppServerRunOwnerRetirement -Paths $Paths
        return [ordered]@{ prepared = $Prepared; result = $wake.result }
    }
    $Prepared.client.bound_thread_id = $ThreadId
    $Prepared.client.bound_turn_id = [string]$wake.turn_id
    Save-CodexAppServerClientStatus -Client $Prepared.client -Paths $Paths -ThreadId $ThreadId -CallbackOwnerState 'callback_active'
    $proven = ''
    if ([bool]$wake.recovered) {
        $fresh = Invoke-CodexAppServerThreadRead -Client $Prepared.client -ThreadId $ThreadId -IncludeTurns $true
        $Prepared.thread = $fresh.thread
        $threadTurn = Get-CodexAppServerTurnById -Thread $fresh.thread -TurnId ([string]$wake.turn_id)
        $proven = ConvertTo-CodexAppServerTurnDisposition -Turn $threadTurn
        if (-not (Test-CodexAppServerTurnTerminalDisposition -Disposition $proven) -and $null -ne $Prepared.client.last_terminal) {
            $lt = $Prepared.client.last_terminal
            if ([string]$lt.turn_id -ceq [string]$wake.turn_id -and (Test-CodexAppServerTurnTerminalDisposition -Disposition ([string]$lt.disposition))) {
                $proven = [string]$lt.disposition
            }
        }
    }
    if (Test-CodexAppServerTurnTerminalDisposition -Disposition $proven) {
        Complete-CodexAppServerTurnTerminal -Paths $Paths -ThreadId $ThreadId -TurnId ([string]$wake.turn_id) -Disposition $proven
    } else {
        $disp = Wait-CodexAppServerBoundTurnTerminal -Client $Prepared.client -Paths $Paths -ThreadId $ThreadId -TurnId ([string]$wake.turn_id)
        if (-not (Test-CodexAppServerTurnTerminalDisposition -Disposition $disp)) {
            throw 'Codex app-server stdio closed.'
        }
        Complete-CodexAppServerTurnTerminal -Paths $Paths -ThreadId $ThreadId -TurnId ([string]$wake.turn_id) -Disposition $disp
    }
    $state = Get-CodexAppServerRunDisposition -Paths $Paths
    $result = Write-CodexAppServerOfficialLauncherResult -Paths $Paths -Started $true -Existing ([bool]$wake.existing) -State $state -RunId $RunId
    Invoke-CodexAppServerMaybeCrash -Point 'after-terminal-result'
    Complete-CodexAppServerDeclarationRetirement -Paths $Paths
    Complete-CodexAppServerRunOwnerRetirement -Paths $Paths
    return [ordered]@{ prepared = $Prepared; result = $result }
    } catch {
        $queuedItemError = $_
        if ($preparedCreatedHere -and $null -ne $Prepared -and $null -ne $Prepared.client) {
            try { Stop-CodexAppServerClient -Client $Prepared.client -StderrEvidencePath ([string]$Paths.stderr_evidence) } catch { }
            try { $Prepared.client = $null } catch { }
        }
        throw $queuedItemError
    }
}

function Invoke-CodexAppServerThreadOwnerLoop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorktreePath,
        [Parameter(Mandatory = $true)][string]$ResumeSessionId,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [AllowNull()][object]$Prepared = $null,
        [string]$TriggerRunId = ''
    )
    $worktree = Assert-TelephoneDirectoryPath -Path $WorktreePath -Label 'Lead worktree'
    $worktree = Assert-CodexAppServerNoReparseChain -Path $worktree -Label 'Lead worktree'
    $threadId = [string]$ResumeSessionId
    Assert-CodexAppServerThreadId -ThreadId $threadId
    $threadPaths = Get-CodexAppServerThreadPaths -StateRoot $StateRoot -ThreadId $threadId
    $selfOwner = $null
    $gate = Open-TelephoneExclusiveGate -Path $threadPaths.gate -WaitMilliseconds 60000
    if ($null -eq $gate) { Throw-CodexAppServerPublic -Code 'THREAD_OWNER_CONFLICT' }
    Disable-CodexAppServerHandleInherit -FileStream $gate
    try {
        $selfOwner = Enter-CodexAppServerThreadOwner -ThreadPaths $threadPaths -ThreadId $threadId -ActiveRunId $TriggerRunId
    } finally {
        if ($null -ne $gate) { $gate.Dispose() }
    }
    if (-not [string]::IsNullOrWhiteSpace($TriggerRunId)) {
        $triggerPaths = Get-CodexAppServerRunPaths -StateRoot $StateRoot -RunId $TriggerRunId
        Write-CodexAppServerRunOwnerProjection -Paths $triggerPaths -Owner $selfOwner -ThreadId $threadId -ActiveRunId $TriggerRunId
        Add-CodexAppServerTransition -Path $triggerPaths.transitions -State 'owner_bound'
    }
    Invoke-CodexAppServerMaybeCrash -Point 'before-write'
    $clientWrapper = $null
    if ($null -ne $Prepared) { $clientWrapper = $Prepared.client }
    try {
        while ($true) {
            $queue = @(Get-CodexAppServerThreadQueueItems -StateRoot $StateRoot -ThreadId $threadId -Worktree $worktree)
            if ($queue.Count -eq 0) {
                $idleMs = Get-CodexAppServerOwnerIdleMilliseconds
                $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($idleMs)
                while ([DateTimeOffset]::UtcNow -lt $deadline) {
                    Start-Sleep -Milliseconds 50
                    $queue = @(Get-CodexAppServerThreadQueueItems -StateRoot $StateRoot -ThreadId $threadId -Worktree $worktree)
                    if ($queue.Count -gt 0) { break }
                }
                if ($queue.Count -eq 0) { break }
            }
            $item = $queue[0]
            $runId = [string]$item.run_id
            $paths = $item.paths
            $selfOwner = New-CodexAppServerOwnerRecord -ThreadId $threadId -ActiveRunId $runId
            $null = Write-CodexAppServerValidatedReplace -Path $threadPaths.owner -Value $selfOwner -SchemaName 'codex-app-server-lead-owner' -PublicationPoint 'owner-replace'
            Write-CodexAppServerRunOwnerProjection -Paths $paths -Owner $selfOwner -ThreadId $threadId -ActiveRunId $runId
            Add-CodexAppServerTransition -Path $paths.transitions -State 'owner_bound'
            try {
                $processed = Invoke-CodexAppServerProcessQueuedItem `
                    -Paths $paths `
                    -RunId $runId `
                    -ThreadId $threadId `
                    -Worktree $worktree `
                    -StateRoot $StateRoot `
                    -CodexCommand $CodexCommand `
                    -Profile $Profile `
                    -ProfilePath $ProfilePath `
                    -Prepared $Prepared
                $Prepared = $processed.prepared
                if ($null -ne $Prepared) { $clientWrapper = $Prepared.client }
            } catch {
                $itemMessage = [string]$_.Exception.Message
                $pendingSend = $false
                try { $pendingSend = Test-CodexAppServerCallbackStillPendingSend -Paths $paths } catch { $pendingSend = $false }
                if (
                    -not $pendingSend -and
                    $itemMessage -cne (Get-CodexAppServerPublicMessage -Code 'THREAD_OWNER_CONFLICT')
                ) {
                    try {
                        $null = Complete-CodexAppServerQueuedItemFailure -Paths $paths -ThreadId $threadId -RunId $runId -Message $itemMessage -Existing ([IO.File]::Exists($paths.ack))
                    } catch { }
                }
                throw
            }
        }
    } catch {
        $message = [string]$_.Exception.Message
        if ($message -ceq (Get-CodexAppServerPublicMessage -Code 'THREAD_OWNER_CONFLICT')) { throw }
        throw
    } finally {
        Complete-CodexAppServerThreadOwnerQuiesce -ThreadPaths $threadPaths -Client $clientWrapper
    }
}

function Invoke-CodexAppServerWorkerCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorktreePath,
        [Parameter(Mandatory = $true)][string]$PromptFile,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ResumeSessionId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [string]$CodexCommand,
        [string]$ProfilePath,
        [string]$BindingOutputPath
    )
    $worktree = Assert-TelephoneDirectoryPath -Path $WorktreePath -Label 'Lead worktree'
    $worktree = Assert-CodexAppServerNoReparseChain -Path $worktree -Label 'Lead worktree'
    $promptPath = Assert-TelephoneRegularFilePath -Path $PromptFile -Label 'Prompt file'
    $promptIdentity = Get-TelephoneFileIdentity -Path $promptPath
    $promptBytes = [IO.File]::ReadAllBytes([string]$promptIdentity.path)
    $promptText = [Text.UTF8Encoding]::new($false, $true).GetString($promptBytes)
    $threadId = [string]$ResumeSessionId
    $createNew = [string]::IsNullOrWhiteSpace($threadId)
    $bindingPath = ''
    if ($createNew) {
        if ([string]::IsNullOrWhiteSpace($BindingOutputPath)) { throw 'Durable create requires BindingOutputPath.' }
        $bindingPath = Assert-CodexAppServerBindingOutputPath -BindingOutputPath $BindingOutputPath
        if ([IO.File]::Exists($bindingPath) -or [IO.Directory]::Exists($bindingPath)) {
            throw 'Lead binding already exists; create-new refused.'
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($BindingOutputPath)) {
        throw 'BindingOutputPath is only valid for durable create.'
    }
    $marker = Get-CodexAppServerWakeMarker -RunId $RunId
    $turnText = New-CodexAppServerTurnInputText -PromptText $promptText -RunId $RunId
    $paths = Get-CodexAppServerRunPaths -StateRoot $StateRoot -RunId $RunId
    $exe = Resolve-CodexAppServerExecutable -CodexCommand $CodexCommand
    $profileFile = if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) { [IO.Path]::GetFullPath($ProfilePath) } else { [string]$paths.profile }
    if (-not [IO.File]::Exists($profileFile)) { throw 'Lead profile is missing; bind the installed Codex schema first.' }
    $profile = (Read-TelephoneJson -Path $profileFile -SchemaName 'codex-app-server-lead-profile').value
    $compat = Get-CodexAppServerCompatibilityIdentity -Profile $profile -ProfilePath $profileFile
    [IO.Directory]::CreateDirectory($paths.run_root) | Out-Null
    $clientWrapper = $null
    $existing = $false
    if (-not $createNew) {
        Invoke-CodexAppServerThreadOwnerLoop `
            -WorktreePath $worktree `
            -ResumeSessionId $threadId `
            -StateRoot ([IO.Path]::GetFullPath($StateRoot)) `
            -CodexCommand $exe `
            -Profile $profile `
            -ProfilePath $profileFile `
            -TriggerRunId $RunId
        if ([IO.File]::Exists($paths.result)) {
            return (Read-TelephoneJson -Path $paths.result -SchemaName 'codex-app-server-lead-result').value
        }
        $ackNow = [IO.File]::Exists($paths.ack)
        $dispNow = Get-CodexAppServerRunDisposition -Paths $paths
        $stateNow = if (Test-CodexAppServerTurnTerminalDisposition -Disposition $dispNow) { $dispNow } else { 'in_progress' }
        return New-CodexAppServerWakeResult -Started $ackNow -Existing $ackNow -State $stateNow -RunId $RunId -RunRoot ([string]$paths.run_root)
    }
    try {
        if (-not $createNew) {
            Assert-CodexAppServerDurableChain -Paths $paths -RunId $RunId -ThreadId $threadId -Worktree $worktree -CallbackIdentity $promptIdentity -Marker $marker -Profile $profile -ProfilePath $profileFile
        } elseif (
            [IO.File]::Exists($paths.intent) -or
            [IO.File]::Exists($paths.run) -or
            [IO.File]::Exists($paths.bound_turn) -or
            [IO.File]::Exists($paths.ack) -or
            [IO.File]::Exists($paths.result)
        ) {
            throw 'Durable create run already exists; create-new refused.'
        }
        Clear-CodexAppServerPublishResidue -Directory $paths.run_root
        if (-not $createNew) {
            $finished = Complete-CodexAppServerTerminalPublicationFromDisk -Paths $paths -RunId $RunId -ThreadId $threadId
            if ($null -ne $finished) { return $finished }
            if (Test-CodexAppServerCompleteOfficialTerminal -Paths $paths) {
                $disp = Get-CodexAppServerRunDisposition -Paths $paths
                $written = Write-CodexAppServerOfficialLauncherResult -Paths $paths -Started $true -Existing $true -State $disp -RunId $RunId
                Complete-CodexAppServerDeclarationRetirement -Paths $paths
                return $written
            }
        }
        if (-not $createNew) {
            $selfOwner = New-CodexAppServerOwnerRecord
            if (-not [IO.File]::Exists($paths.owner)) {
                $null = Write-CodexAppServerValidatedReplace -Path $paths.owner -Value $selfOwner -SchemaName 'codex-app-server-lead-owner'
            } else {
                $owner = Read-CodexAppServerValidated -Path $paths.owner -SchemaName 'codex-app-server-lead-owner' -Code 'OWNER_INVALID'
                if ((Test-TelephoneOwnerAlive -Owner $owner) -and [int]$owner.pid -ne [int]$PID) {
                    throw 'Live owner already holds this run.'
                }
                $null = Write-CodexAppServerValidatedReplace -Path $paths.owner -Value $selfOwner -SchemaName 'codex-app-server-lead-owner' -PublicationPoint 'owner-replace'
            }
            Add-CodexAppServerTransition -Path $paths.transitions -State 'owner_bound'
        }
        Invoke-CodexAppServerMaybeCrash -Point 'before-write'
        $env:TELEPHONE_APP_SERVER_THREAD_STORE = [string]$paths.store
        if ($createNew) {
            $live = Assert-CodexAppServerProfileCurrent -Profile $profile -CodexCommand $exe
            $newClient = New-CodexAppServerClient -CodexCommand $exe -WorkingDirectory $worktree -StorePath ([string]$paths.store)
            $newClient.compatibility_license = $live
            try {
                Initialize-CodexAppServerSession -Client $newClient
                $startedThread = Invoke-CodexAppServerThreadStart -Client $newClient -Worktree $worktree
                $threadId = [string]$startedThread.thread_id
                if ([string]::IsNullOrWhiteSpace($threadId)) { throw 'Durable create did not return a thread id.' }
                $prepared = [ordered]@{
                    client = $newClient
                    thread_id = $threadId
                    thread = $startedThread.thread
                    baseline_turn_ids = [string[]]@()
                    pending = @($newClient.pending)
                }
                $clientWrapper = $newClient
            } catch {
                Stop-CodexAppServerClient -Client $newClient
                throw
            }
            $selfOwner = New-CodexAppServerOwnerRecord
            $null = Write-CodexAppServerValidatedReplace -Path $paths.owner -Value $selfOwner -SchemaName 'codex-app-server-lead-owner'
            Add-CodexAppServerTransition -Path $paths.transitions -State 'owner_bound'
            $null = Write-CodexAppServerValidatedReplace -Path $paths.intent -Value ([ordered]@{
                protocol_version = 'telephone-line-codex-app-server-lead-intent-v1'
                run_id = [string]$RunId
                thread_id = $threadId
                worktree = $worktree
                callback = [ordered]@{
                    path = [string]$promptIdentity.path
                    bytes = [int64]$promptIdentity.bytes
                    sha256 = [string]$promptIdentity.sha256
                }
                wake_marker = $marker
                profile_fingerprint = [string]$compat.profile_fingerprint
                codex_version = [string]$compat.codex_version
                executable_sha256 = [string]$compat.executable_sha256
                profile_sha256 = [string]$compat.profile_sha256
                codex_command = [string]$compat.codex_command
                service_tier = [string]$compat.service_tier
                baseline_turn_ids = @()
                created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            }) -SchemaName 'codex-app-server-lead-intent'
        } else {
            $prepared = Invoke-CodexAppServerConnectAndPrepare -CodexCommand $exe -Worktree $worktree -ThreadId $threadId -StorePath ([string]$paths.store) -Profile $profile -StatusPath ([string]$paths.status)
            $clientWrapper = $prepared.client
            if (-not [IO.File]::Exists($paths.intent)) {
                $null = Write-CodexAppServerValidatedReplace -Path $paths.intent -Value ([ordered]@{
                    protocol_version = 'telephone-line-codex-app-server-lead-intent-v1'
                    run_id = [string]$RunId
                    thread_id = $threadId
                    worktree = $worktree
                    callback = [ordered]@{
                        path = [string]$promptIdentity.path
                        bytes = [int64]$promptIdentity.bytes
                        sha256 = [string]$promptIdentity.sha256
                    }
                    wake_marker = $marker
                    profile_fingerprint = [string]$compat.profile_fingerprint
                    codex_version = [string]$compat.codex_version
                    executable_sha256 = [string]$compat.executable_sha256
                    profile_sha256 = [string]$compat.profile_sha256
                    codex_command = [string]$compat.codex_command
                    service_tier = [string]$compat.service_tier
                    baseline_turn_ids = @($prepared.baseline_turn_ids)
                    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
                }) -SchemaName 'codex-app-server-lead-intent'
            }
        }
        $null = Write-CodexAppServerValidatedReplace -Path $paths.child -Value $prepared.client.child -SchemaName 'codex-app-server-lead-child'
        Add-CodexAppServerTransition -Path $paths.transitions -State 'baseline_recorded'
        $baseline = @($prepared.baseline_turn_ids)
        $intent = Read-CodexAppServerValidated -Path $paths.intent -SchemaName 'codex-app-server-lead-intent'
        if ($intent.Contains('baseline_turn_ids') -and (Test-CodexAppServerJsonArray -Value $intent.baseline_turn_ids)) {
            $baseline = @($intent.baseline_turn_ids | ForEach-Object { [string]$_ })
        } else {
            $intent.baseline_turn_ids = @($baseline)
            $null = Write-CodexAppServerValidatedReplace -Path $paths.intent -Value $intent -SchemaName 'codex-app-server-lead-intent'
        }
        if (-not [IO.File]::Exists($paths.run)) {
            $run = [ordered]@{
                protocol_version = $script:CodexAppServerRunProtocol
                run_id = [string]$RunId
                thread_id = $threadId
                worktree = $worktree
                callback = [ordered]@{
                    path = [string]$promptIdentity.path
                    bytes = [int64]$promptIdentity.bytes
                    sha256 = [string]$promptIdentity.sha256
                }
                wake_marker = $marker
                profile_fingerprint = [string]$compat.profile_fingerprint
                codex_version = [string]$compat.codex_version
                executable_sha256 = [string]$compat.executable_sha256
                profile_sha256 = [string]$compat.profile_sha256
                codex_command = [string]$compat.codex_command
                service_tier = [string]$compat.service_tier
                baseline_turn_ids = @($baseline)
                selected_turn_id = ''
                disposition = 'in_progress'
                callback_write_phase = 'none'
                terminal_target = ''
                fallback_required = ''
            }
            $null = Write-CodexAppServerValidatedReplace -Path $paths.run -Value $run -SchemaName 'codex-app-server-lead-run'
        }
        if ($createNew) {
            $startedTurn = Send-CodexAppServerWakeTurnOnce -Client $prepared.client -Paths $paths -ThreadId $threadId -TurnText $turnText
            $launcher = Get-CodexAppServerLauncherPath
            $launcherArgs = @(
                '-StateRoot', ([IO.Path]::GetFullPath($StateRoot)),
                '-CodexCommand', $exe,
                '-ProfilePath', $profileFile
            )
            $binding = New-CodexAppServerLeadBindingObject -SessionId $threadId -Worktree $worktree -LauncherPath $launcher -LauncherArguments $launcherArgs
            $null = Write-TelephoneJsonCreateNew -Path $bindingPath -Value $binding
            Bind-CodexAppServerTurnAndAck -Paths $paths -ThreadId $threadId -TurnId ([string]$startedTurn.turn_id) -BoundState 'active'
            $wake = [ordered]@{ turn_id = [string]$startedTurn.turn_id; recovered = $false; existing = $false }
        } else {
            $wake = Invoke-CodexAppServerRecoverOrSend -Prepared $prepared -Paths $paths -ThreadId $threadId -Marker $marker -TurnText $turnText -BaselineTurnIds $baseline
        }
        $existing = [bool]$wake.existing
        $prepared.client.bound_thread_id = $threadId
        $prepared.client.bound_turn_id = [string]$wake.turn_id
        Save-CodexAppServerClientStatus -Client $prepared.client -Paths $paths -ThreadId $threadId
        $proven = ''
        if ([bool]$wake.recovered) {
            $fresh = Invoke-CodexAppServerThreadRead -Client $prepared.client -ThreadId $threadId -IncludeTurns $true
            $prepared.thread = $fresh.thread
            $threadTurn = Get-CodexAppServerTurnById -Thread $fresh.thread -TurnId ([string]$wake.turn_id)
            $proven = ConvertTo-CodexAppServerTurnDisposition -Turn $threadTurn
            if (-not (Test-CodexAppServerTurnTerminalDisposition -Disposition $proven) -and $null -ne $prepared.client.last_terminal) {
                $lt = $prepared.client.last_terminal
                if ([string]$lt.turn_id -ceq [string]$wake.turn_id -and (Test-CodexAppServerTurnTerminalDisposition -Disposition ([string]$lt.disposition))) {
                    $proven = [string]$lt.disposition
                }
            }
        }
        if (Test-CodexAppServerTurnTerminalDisposition -Disposition $proven) {
            Complete-CodexAppServerTurnTerminal -Paths $paths -ThreadId $threadId -TurnId ([string]$wake.turn_id) -Disposition $proven
        } else {
            $disp = Wait-CodexAppServerBoundTurnTerminal -Client $prepared.client -Paths $paths -ThreadId $threadId -TurnId ([string]$wake.turn_id)
            if (-not (Test-CodexAppServerTurnTerminalDisposition -Disposition $disp)) {
                throw 'Codex app-server stdio closed.'
            }
            Complete-CodexAppServerTurnTerminal -Paths $paths -ThreadId $threadId -TurnId ([string]$wake.turn_id) -Disposition $disp
        }
        $state = Get-CodexAppServerRunDisposition -Paths $paths
        $result = Write-CodexAppServerOfficialLauncherResult -Paths $paths -Started $true -Existing $existing -State $state -RunId $RunId
        Invoke-CodexAppServerMaybeCrash -Point 'after-terminal-result'
        Complete-CodexAppServerDeclarationRetirement -Paths $paths
        return $result
    } catch {
        $message = [string]$_.Exception.Message
        $failure = Complete-CodexAppServerQueuedItemFailure -Paths $paths -ThreadId $threadId -RunId $RunId -Message $message -Existing $existing
        if ([string]$failure.fallback_required -ceq 'cli') { return $failure.result }
        throw
    } finally {
        Stop-CodexAppServerClient -Client $clientWrapper -StderrEvidencePath ([string]$paths.stderr_evidence)
    }
}

function Wait-CodexAppServerWorkerAck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][bool]$AckExisted,
        [int]$TimeoutSeconds = 60,
        [int]$ExpectedWorkerPid = 0,
        [AllowNull()][object]$ThreadPaths = $null
    )
    $waitSeconds = [int]$TimeoutSeconds
    if ($waitSeconds -lt 1) { $waitSeconds = 60 }
    $startupDeadline = [DateTimeOffset]::UtcNow.AddSeconds($waitSeconds)
    $deadWithoutResultSince = $null
    while ($true) {
        if ([IO.File]::Exists($Paths.ack)) {
            try {
                $ack = (Read-TelephoneJson -Path $Paths.ack).value
                Assert-CodexAppServerSameText -Left (Get-CodexAppServerDictString -Dict $ack -Key 'session_id') -Right $ThreadId -Label 'ack session'
                $turnId = Get-CodexAppServerDictString -Dict $ack -Key 'turn_id'
                if ([string]::IsNullOrWhiteSpace($turnId)) { throw 'Durable wake acknowledgment is malformed.' }
                $disp = Get-CodexAppServerRunDisposition -Paths $Paths
                $state = if (Test-CodexAppServerTurnTerminalDisposition -Disposition $disp) { $disp } else { 'in_progress' }
                return New-CodexAppServerWakeResult -Started $true -Existing $AckExisted -State $state -RunId ([IO.Path]::GetFileName($Paths.run_root)) -RunRoot ([string]$Paths.run_root)
            } catch {
                $cursor = $_.Exception
                $transientRead = $false
                while ($null -ne $cursor) {
                    if ($cursor -is [IO.IOException] -or $cursor -is [Text.DecoderFallbackException] -or $cursor -is [Text.Json.JsonException]) {
                        $transientRead = $true
                        break
                    }
                    $cursor = $cursor.InnerException
                }
                if ($transientRead -and [DateTimeOffset]::UtcNow -lt $startupDeadline) {
                    Start-Sleep -Milliseconds 50
                    continue
                }
                throw
            }
        }
        if ([IO.File]::Exists($Paths.result)) {
            $ownerNow = $null
            if ([IO.File]::Exists($Paths.owner)) {
                try { $ownerNow = (Read-TelephoneJson -Path $Paths.owner).value } catch { $ownerNow = $null }
            }
            $aliveNow = ($null -ne $ownerNow -and (Test-TelephoneOwnerAlive -Owner $ownerNow))
            $staleOwner = ($ExpectedWorkerPid -ne 0 -and $null -ne $ownerNow -and [int]$ownerNow.pid -ne $ExpectedWorkerPid)
            if (-not $aliveNow -and -not $staleOwner) {
                try {
                    $res = (Read-TelephoneJson -Path $Paths.result).value
                    if ($res -is [Collections.IDictionary]) {
                        $fb = Get-CodexAppServerDictString -Dict $res -Key 'fallback_required'
                        $started = $false
                        if ($res.Contains('started')) { $started = [bool]$res.started }
                        $resState = Get-CodexAppServerDictString -Dict $res -Key 'state'
                        if ($fb -ceq 'cli' -or $resState -ceq 'fallback_required_cli') { return $res }
                        if ($started -eq $false -and -not $aliveNow -and -not $staleOwner) { return $res }
                    }
                } catch { }
            }
        }
        $owner = $null
        if ([IO.File]::Exists($Paths.owner)) {
            try { $owner = (Read-TelephoneJson -Path $Paths.owner).value } catch { $owner = $null }
        }
        $threadOwnerAlive = $false
        if ($null -ne $ThreadPaths) {
            try {
                $threadOwnerAlive = Test-CodexAppServerThreadOwnerAlive -ThreadPaths $ThreadPaths
            } catch {
                $waitOwnerMessage = [string]$_.Exception.Message
                if ($waitOwnerMessage -ceq (Get-CodexAppServerPublicMessage -Code 'OWNER_INVALID')) {
                    if ([IO.File]::Exists($Paths.ack) -or [IO.File]::Exists($Paths.result) -or [IO.File]::Exists($Paths.final)) {
                        $threadOwnerAlive = $false
                    } else {
                        throw
                    }
                } else {
                    $threadOwnerAlive = $false
                }
            }
        }
        if ($threadOwnerAlive) {
            $deadWithoutResultSince = $null
            Start-Sleep -Milliseconds 50
            continue
        }
        if ($null -ne $owner -and -not (Test-TelephoneOwnerAlive -Owner $owner) -and -not [IO.File]::Exists($Paths.ack)) {
            if ($ExpectedWorkerPid -ne 0 -and [int]$owner.pid -ne $ExpectedWorkerPid) {
                $deadWithoutResultSince = $null
                Start-Sleep -Milliseconds 50
                continue
            }
            if ([IO.File]::Exists($Paths.result)) {
                try {
                    $res = (Read-TelephoneJson -Path $Paths.result).value
                    if ($res -is [Collections.IDictionary]) { return $res }
                } catch { }
            }
            if ($null -eq $deadWithoutResultSince) { $deadWithoutResultSince = [DateTimeOffset]::UtcNow }
            if (([DateTimeOffset]::UtcNow - $deadWithoutResultSince).TotalMilliseconds -lt 2000) {
                Start-Sleep -Milliseconds 50
                continue
            }
            throw 'Lead worker ended before accepting the resumed turn.'
        }
        if ([DateTimeOffset]::UtcNow -ge $startupDeadline) {
            throw 'Lead worker did not acknowledge the exact resumed turn within the startup window.'
        }
        $deadWithoutResultSince = $null
        Start-Sleep -Milliseconds 50
    }
}

function Invoke-CodexAppServerCreateWakeCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorktreePath,
        [Parameter(Mandatory = $true)][string]$PromptFile,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$BindingOutputPath,
        [string]$CodexCommand,
        [string]$ProfilePath
    )
    try { $null = Invoke-TelephoneDashboardEnsure } catch { }
    $worktree = Assert-TelephoneDirectoryPath -Path $WorktreePath -Label 'Lead worktree'
    $worktree = Assert-CodexAppServerNoReparseChain -Path $worktree -Label 'Lead worktree'
    $promptPath = Assert-TelephoneRegularFilePath -Path $PromptFile -Label 'Prompt file'
    $bindingPath = Assert-CodexAppServerBindingOutputPath -BindingOutputPath $BindingOutputPath
    if ([IO.File]::Exists($bindingPath) -or [IO.Directory]::Exists($bindingPath)) {
        throw 'Lead binding already exists; create-new refused.'
    }
    $paths = Get-CodexAppServerRunPaths -StateRoot $StateRoot -RunId $RunId
    foreach ($path in @($paths.intent, $paths.run, $paths.bound_turn, $paths.ack, $paths.result, $paths.owner)) {
        if ([IO.File]::Exists([string]$path) -or [IO.Directory]::Exists([string]$path)) {
            throw 'Durable create run already exists; create-new refused.'
        }
    }
    $exe = Resolve-CodexAppServerExecutable -CodexCommand $CodexCommand
    $profileFile = if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) { [IO.Path]::GetFullPath($ProfilePath) } else { [string]$paths.profile }
    if (-not [IO.File]::Exists($profileFile)) { throw 'Lead profile is missing; bind the installed Codex schema first.' }
    $profile = (Read-TelephoneJson -Path $profileFile -SchemaName 'codex-app-server-lead-profile').value
    $null = Assert-CodexAppServerProfileCurrent -Profile $profile -CodexCommand $exe
    [IO.Directory]::CreateDirectory($paths.run_root) | Out-Null
    $gate = Open-TelephoneExclusiveGate -Path $paths.gate -WaitMilliseconds 60000
    if ($null -eq $gate) { throw 'Exclusive per-run gate is held by another launcher.' }
    Disable-CodexAppServerHandleInherit -FileStream $gate
    try {
        $launch = Start-TelephoneHiddenPowerShell -ScriptPath (Get-CodexAppServerWorkerPath) -Arguments @(
            '-WorktreePath', $worktree,
            '-PromptFile', $promptPath,
            '-CreateNewThread',
            '-RunId', $RunId,
            '-StateRoot', ([IO.Path]::GetFullPath($StateRoot)),
            '-CodexCommand', $exe,
            '-ProfilePath', $profileFile,
            '-BindingOutputPath', $bindingPath
        )
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(60)
        $deadSince = $null
        while ([DateTimeOffset]::UtcNow -lt $deadline) {
            if ([IO.File]::Exists($bindingPath)) {
                $binding = $null
                try { $binding = (Read-TelephoneJson -Path $bindingPath -SchemaName 'lead-binding').value } catch { Start-Sleep -Milliseconds 50; continue }
                $threadId = Get-CodexAppServerDictString -Dict $binding -Key 'session_id'
                if ([string]::IsNullOrWhiteSpace($threadId)) { throw 'Durable create binding is missing the thread id.' }
                $left = [Math]::Max(1, [int][Math]::Ceiling(($deadline - [DateTimeOffset]::UtcNow).TotalSeconds))
                $wake = Wait-CodexAppServerWorkerAck -Paths $paths -ThreadId $threadId -AckExisted $false -TimeoutSeconds $left -ExpectedWorkerPid ([int]$launch.pid)
                if ($wake -isnot [Collections.IDictionary] -or -not [bool]$wake.started) {
                    throw 'Lead worker did not accept the durable create turn.'
                }
                $identity = Get-TelephoneFileIdentity -Path $bindingPath
                return [ordered]@{
                    protocol_version = 'telephone-line-codex-app-server-lead-binding-result-v1'
                    callback_transport = 'app-server'
                    started = $true
                    thread_id = $threadId
                    binding = $identity
                    fallback_required = ''
                }
            }
            if (-not (Test-TelephoneOwnerAlive -Owner $launch)) {
                if ($null -eq $deadSince) { $deadSince = [DateTimeOffset]::UtcNow }
                if (([DateTimeOffset]::UtcNow - $deadSince).TotalMilliseconds -ge 2000) {
                    throw 'Lead worker ended before publishing a durable create binding.'
                }
            } else {
                $deadSince = $null
            }
            Start-Sleep -Milliseconds 50
        }
        throw 'Lead worker did not publish a durable create binding within the startup window.'
    } finally {
        if ($null -ne $gate) { $gate.Dispose() }
    }
}

function Test-CodexAppServerWatchdogDisabled {
    [CmdletBinding()]
    param()
    foreach ($name in @(
        'TELEPHONE_TEST_APP_SERVER_NO_WATCHDOG',
        'TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT',
        'TELEPHONE_TEST_APP_SERVER_CRASH_AT',
        'TELEPHONE_TEST_APP_SERVER_PUBLISH_CRASH_AT'
    )) {
        $raw = [string][Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            try { $raw = [string](Get-Item -LiteralPath ("Env:$name") -ErrorAction SilentlyContinue).Value } catch { $raw = '' }
        }
        if (-not [string]::IsNullOrWhiteSpace($raw)) { return $true }
    }
    return $false
}

function Invoke-CodexAppServerCallbackWatchdogCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorktreePath,
        [Parameter(Mandatory = $true)][string]$PromptFile,
        [Parameter(Mandatory = $true)][string]$ResumeSessionId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [string]$CodexCommand,
        [string]$ProfilePath
    )
    $worktree = Assert-TelephoneDirectoryPath -Path $WorktreePath -Label 'Lead worktree'
    $promptPath = Assert-TelephoneRegularFilePath -Path $PromptFile -Label 'Prompt file'
    $threadId = [string]$ResumeSessionId
    Assert-CodexAppServerThreadId -ThreadId $threadId
    $paths = Get-CodexAppServerRunPaths -StateRoot $StateRoot -RunId $RunId
    $threadPaths = Get-CodexAppServerThreadPaths -StateRoot $StateRoot -ThreadId $threadId
    $exe = Resolve-CodexAppServerExecutable -CodexCommand $CodexCommand
    $profileFile = if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) { [IO.Path]::GetFullPath($ProfilePath) } else { [string]$paths.profile }
    $profile = (Read-TelephoneJson -Path $profileFile -SchemaName 'codex-app-server-lead-profile').value
    $self = New-CodexAppServerOwnerRecord -ThreadId $threadId -ActiveRunId $RunId
    $null = Write-TelephoneJsonReplace -Path ([string]$paths.lifecycle_owner) -Value $self
    $lastLaunch = $null
    while ($true) {
        if (Test-CodexAppServerCompleteOfficialTerminal -Paths $paths) { return }
        if (Test-CodexAppServerRunQueueRetired -Paths $paths) { return }
        $disp = Get-CodexAppServerRunDisposition -Paths $paths
        if (Test-CodexAppServerTurnTerminalDisposition -Disposition $disp) { return }
        $promptIdentity = Get-TelephoneFileIdentity -Path $promptPath
        $marker = Get-CodexAppServerWakeMarker -RunId $RunId
        try {
            Assert-CodexAppServerDurableChain -Paths $paths -RunId $RunId -ThreadId $threadId -Worktree $worktree -CallbackIdentity $promptIdentity -Marker $marker -Profile $profile -ProfilePath $profileFile
        } catch {
            return
        }
        $ownerAlive = Test-CodexAppServerThreadOwnerAlive -ThreadPaths $threadPaths
        if (-not $ownerAlive) {
            $launchAlive = Test-TelephoneOwnerAlive -Owner $lastLaunch
            if (-not $launchAlive) {
                $lastLaunch = Start-TelephoneHiddenPowerShell -ScriptPath (Get-CodexAppServerWorkerPath) -Arguments @(
                    '-WorktreePath', $worktree,
                    '-PromptFile', $promptPath,
                    '-ResumeSessionId', $threadId,
                    '-RunId', $RunId,
                    '-StateRoot', ([IO.Path]::GetFullPath($StateRoot)),
                    '-CodexCommand', $exe,
                    '-ProfilePath', $profileFile
                )
            }
        }
        Start-Sleep -Milliseconds 400
    }
}

function Start-CodexAppServerCallbackWatchdog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorktreePath,
        [Parameter(Mandatory = $true)][string]$PromptFile,
        [Parameter(Mandatory = $true)][string]$ResumeSessionId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [string]$CodexCommand,
        [string]$ProfilePath
    )
    if (Test-CodexAppServerWatchdogDisabled) { return $null }
    $paths = Get-CodexAppServerRunPaths -StateRoot $StateRoot -RunId $RunId
    $existing = $null
    if ([IO.File]::Exists([string]$paths.lifecycle_owner)) {
        try { $existing = (Read-TelephoneJson -Path ([string]$paths.lifecycle_owner)).value } catch { $existing = $null }
    }
    if (Test-TelephoneOwnerAlive -Owner $existing) { return $existing }
    return (Start-TelephoneHiddenPowerShell -ScriptPath (Get-CodexAppServerWorkerPath) -Arguments @(
        '-WorktreePath', $WorktreePath,
        '-PromptFile', $PromptFile,
        '-ResumeSessionId', $ResumeSessionId,
        '-RunId', $RunId,
        '-StateRoot', ([IO.Path]::GetFullPath($StateRoot)),
        '-CodexCommand', $CodexCommand,
        '-ProfilePath', $ProfilePath,
        '-Watchdog'
    ))
}

function Invoke-CodexAppServerWakeCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorktreePath,
        [Parameter(Mandatory = $true)][string]$PromptFile,
        [Parameter(Mandatory = $true)][string]$ResumeSessionId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [string]$CodexCommand,
        [string]$ProfilePath
    )
    try { $null = Invoke-TelephoneDashboardEnsure } catch { }
    $worktree = Assert-TelephoneDirectoryPath -Path $WorktreePath -Label 'Lead worktree'
    $worktree = Assert-CodexAppServerNoReparseChain -Path $worktree -Label 'Lead worktree'
    $promptPath = Assert-TelephoneRegularFilePath -Path $PromptFile -Label 'Prompt file'
    $promptIdentity = Get-TelephoneFileIdentity -Path $promptPath
    $threadId = [string]$ResumeSessionId
    if ([string]::IsNullOrWhiteSpace($threadId)) { throw 'ResumeSessionId must be the exact Codex thread id.' }
    Assert-CodexAppServerThreadId -ThreadId $threadId
    $marker = Get-CodexAppServerWakeMarker -RunId $RunId
    $paths = Get-CodexAppServerRunPaths -StateRoot $StateRoot -RunId $RunId
    $threadPaths = Get-CodexAppServerThreadPaths -StateRoot $StateRoot -ThreadId $threadId
    $exe = Resolve-CodexAppServerExecutable -CodexCommand $CodexCommand
    $profileFile = if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) { [IO.Path]::GetFullPath($ProfilePath) } else { [string]$paths.profile }
    if (-not [IO.File]::Exists($profileFile)) { throw 'Lead profile is missing; bind the installed Codex schema first.' }
    $profile = (Read-TelephoneJson -Path $profileFile -SchemaName 'codex-app-server-lead-profile').value
    [IO.Directory]::CreateDirectory($paths.run_root) | Out-Null
    if (
        [IO.File]::Exists($paths.run) -and
        (Test-CodexAppServerRunQueueRetired -Paths $paths) -and
        -not (Test-CodexAppServerCompleteOfficialTerminal -Paths $paths)
    ) {
        if ([IO.File]::Exists($paths.result)) {
            try {
                $retiredResult = (Read-TelephoneJson -Path $paths.result -SchemaName 'codex-app-server-lead-result').value
                if ($retiredResult -is [Collections.IDictionary]) {
                    Write-CodexAppServerStdoutJson -Value $retiredResult
                    return $null
                }
            } catch { }
        }
        $retiredWake = New-CodexAppServerWakeResult -Started $false -Existing $true -State 'failed' -RunId $RunId -RunRoot ([string]$paths.run_root)
        Write-CodexAppServerStdoutJson -Value $retiredWake
        return $null
    }
    $gate = Open-TelephoneExclusiveGate -Path $paths.gate -WaitMilliseconds 60000
    if ($null -eq $gate) { throw 'Exclusive per-run gate is held by another launcher.' }
    Disable-CodexAppServerHandleInherit -FileStream $gate
    $ackExisted = $false
    $expectedPid = 0
    $ackWaitReady = $false
    try {
        Assert-CodexAppServerDurableChain -Paths $paths -RunId $RunId -ThreadId $threadId -Worktree $worktree -CallbackIdentity $promptIdentity -Marker $marker -Profile $profile -ProfilePath $profileFile
        Clear-CodexAppServerPublishResidue -Directory $paths.run_root
        $finished = Complete-CodexAppServerTerminalPublicationFromDisk -Paths $paths -RunId $RunId -ThreadId $threadId
        if ($null -ne $finished) {
            if ($finished -is [Collections.IDictionary]) { $finished.existing = $true }
            return $finished
        }
        $proven = Test-CodexAppServerCompleteOfficialTerminal -Paths $paths
        if ($proven) {
            $disp = Get-CodexAppServerRunDisposition -Paths $paths
            $written = Write-CodexAppServerOfficialLauncherResult -Paths $paths -Started $true -Existing $true -State $disp -RunId $RunId
            Complete-CodexAppServerDeclarationRetirement -Paths $paths
            Complete-CodexAppServerRunOwnerRetirement -Paths $paths
            return $written
        }
        $ackExisted = [IO.File]::Exists($paths.ack)
        $null = Assert-CodexAppServerProfileCurrent -Profile $profile -CodexCommand $exe
        $threadGate = Open-TelephoneExclusiveGate -Path $threadPaths.gate -WaitMilliseconds 60000
        if ($null -eq $threadGate) { Throw-CodexAppServerPublic -Code 'THREAD_OWNER_CONFLICT' }
        Disable-CodexAppServerHandleInherit -FileStream $threadGate
        try {
            $admitted = Write-CodexAppServerQueuedCallback -Paths $paths -RunId $RunId -ThreadId $threadId -Worktree $worktree -CallbackIdentity $promptIdentity -Marker $marker -Profile $profile -ProfilePath $profileFile -CodexCommand $exe
            if ($admitted -is [Collections.IDictionary] -and $admitted.Contains('queued') -and [bool]$admitted.queued -eq $false) {
                if ($admitted.Contains('result') -and $null -ne $admitted.result) {
                    Write-CodexAppServerStdoutJson -Value $admitted.result
                }
                return $null
            }
            $threadOwnerAlive = Test-CodexAppServerThreadOwnerAlive -ThreadPaths $threadPaths
            if (
                [IO.File]::Exists($paths.ack) -and
                -not $proven -and
                (Get-CodexAppServerCallbackWritePhase -Paths $paths) -ceq 'acknowledged' -and
                (Get-CodexAppServerRunDisposition -Paths $paths) -cne 'recovered' -and
                -not $threadOwnerAlive
            ) {
                Write-CodexAppServerRecoveryRequired -Paths $paths -ThreadId $threadId
            }
            if (-not $threadOwnerAlive) {
                $launch = Start-TelephoneHiddenPowerShell -ScriptPath (Get-CodexAppServerWorkerPath) -Arguments @(
                    '-WorktreePath', $worktree,
                    '-PromptFile', $promptPath,
                    '-ResumeSessionId', $threadId,
                    '-RunId', $RunId,
                    '-StateRoot', ([IO.Path]::GetFullPath($StateRoot)),
                    '-CodexCommand', $exe,
                    '-ProfilePath', $profileFile
                )
                $expectedPid = [int]$launch.pid
            }
            $null = Start-CodexAppServerCallbackWatchdog `
                -WorktreePath $worktree `
                -PromptFile $promptPath `
                -ResumeSessionId $threadId `
                -RunId $RunId `
                -StateRoot $StateRoot `
                -CodexCommand $exe `
                -ProfilePath $profileFile
        } finally {
            if ($null -ne $threadGate) { $threadGate.Dispose() }
        }
        $ackWaitReady = $true
    } catch {
        $message = [string]$_.Exception.Message
        if (Test-CodexAppServerCompatibilityFailureMessage -Message $message) {
            $dispNow = Get-CodexAppServerRunDisposition -Paths $paths
            if ($dispNow -ceq 'recovered') { throw }
            if (Test-CodexAppServerFallbackWindowClosed -Paths $paths) {
                Write-CodexAppServerRecoveryRequired -Paths $paths -ThreadId $threadId
                $result = New-CodexAppServerWakeResult -Started $false -Existing $false -State 'recovery_required' -RunId $RunId -RunRoot ([string]$paths.run_root)
                Write-CodexAppServerStdoutJson -Value $result
                return $null
            }
            $result = New-CodexAppServerWakeResult -Started $false -Existing $false -State 'fallback_required_cli' -RunId $RunId -RunRoot ([string]$paths.run_root) -FallbackRequired 'cli'
            Write-CodexAppServerStdoutJson -Value $result
            return $null
        }
        throw
    } finally {
        if ($null -ne $gate) { $gate.Dispose(); $gate = $null }
    }
    if (-not $ackWaitReady) { return $null }
    $waited = Wait-CodexAppServerWorkerAck -Paths $paths -ThreadId $threadId -AckExisted $ackExisted -TimeoutSeconds (Get-CodexAppServerAckTimeoutSeconds) -ExpectedWorkerPid $expectedPid -ThreadPaths $threadPaths
    if ($waited -is [Collections.IDictionary] -and (
        (Get-CodexAppServerDictString -Dict $waited -Key 'fallback_required') -ceq 'cli' -or
        ($waited.Contains('started') -and [bool]$waited.started -eq $false)
    )) {
        Write-CodexAppServerStdoutJson -Value $waited
        return $null
    }
    if ($waited -is [Collections.IDictionary]) {
        $waited.run_id = [string]$RunId
        $waited.run_root = [string]$paths.run_root
        $waited.existing = [bool]$ackExisted
    }
    return $waited
}

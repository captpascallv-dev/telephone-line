# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }

function Get-DirectGrokFileIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Expected a regular file.'
    }
    $bytes = [IO.File]::ReadAllBytes($full)
    return [ordered]@{
        path = $item.FullName
        bytes = [int64]$bytes.Length
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
}

function Assert-DirectGrokIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Actual,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (
        [IO.Path]::GetFullPath([string]$Expected.path) -cne [IO.Path]::GetFullPath([string]$Actual.path) -or
        [int64]$Expected.bytes -ne [int64]$Actual.bytes -or
        [string]$Expected.sha256 -cne [string]$Actual.sha256
    ) {
        throw "$Label identity changed."
    }
}

function Read-DirectGrokJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $identity = Get-DirectGrokFileIdentity -Path $Path
    $bytes = [IO.File]::ReadAllBytes([string]$identity.path)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    return [ordered]@{
        identity = $identity
        value = $text | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
    }
}

function Assert-DirectGrokKeys {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Value,
        [Parameter(Mandatory = $true)][string[]]$Keys,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($Value.Count -ne $Keys.Count) { throw "$Label key count mismatch." }
    foreach ($key in $Keys) {
        if (-not $Value.Contains($key)) { throw "$Label is missing or has a wrong-case key: $key" }
    }
}

function Write-DirectGrokBytesCreateNew {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $stream = [IO.FileStream]::new($full, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    return Get-DirectGrokFileIdentity -Path $full
}

function Write-DirectGrokJsonCreateNew {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $json = ($Value | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    return Write-DirectGrokBytesCreateNew -Path $Path -Bytes $bytes
}

function Write-DirectGrokJsonReplace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $json = ($Value | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) + '.tmp-' + [Guid]::NewGuid().ToString('N'))
    $backup = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) + '.bak-' + [Guid]::NewGuid().ToString('N'))
    try {
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        if ([IO.File]::Exists($full)) {
            [IO.File]::Replace($temporary, $full, $backup)
            if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
        } else {
            [IO.File]::Move($temporary, $full)
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    }
    return Get-DirectGrokFileIdentity -Path $full
}

function Test-DirectGrokOwnerAlive {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Owner)

    try {
        $process = Get-Process -Id ([int]$Owner.pid) -ErrorAction Stop
        try {
            return $process.StartTime.ToUniversalTime().Ticks -eq [int64]$Owner.start_time_utc_ticks
        } finally {
            $process.Dispose()
        }
    } catch {
        return $false
    }
}

function Get-DirectGrokPublicErrorCatalog {
    return [ordered]@{
        ADAPTER_TRANSPORT_FAILED = 'Telephone-line adapter transport failed.'
        ADAPTER_NATIVE_SESSION_MISMATCH = 'Adapter native session id does not match the frozen session.'
        ADAPTER_NATIVE_SESSION_MISSING = 'Adapter native session id is missing or unknown.'
        ADAPTER_DURABLE_STATE_MISSING = 'Adapter durable state was not found.'
    }
}

function Get-DirectGrokPublicError {
    [CmdletBinding()]
    param([AllowNull()][string]$Text, [string]$ErrorCode)
    $catalog = Get-DirectGrokPublicErrorCatalog
    $code = [string]$ErrorCode
    if ([string]::IsNullOrWhiteSpace($code) -or -not $catalog.Contains($code)) { $code = 'ADAPTER_TRANSPORT_FAILED' }
    return [string]$catalog[$code]
}

function Protect-DirectGrokDiagnostic {
    [CmdletBinding()]
    param([AllowNull()][string]$Text, [int]$MaxLength = 4096)
    return Get-DirectGrokPublicError -Text $Text
}

function Get-DirectGrokJobArtifactPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$JobRoot)
    $root = [IO.Path]::GetFullPath($JobRoot).TrimEnd('\')
    return [ordered]@{
        root = $root
        cli_stdout = Join-Path $root 'cli-stdout.json'
        checkpoint = Join-Path $root 'completion-checkpoint.json'
        session_proof = Join-Path $root 'session-proof.json'
        stdout = Join-Path $root 'grok-result.json'
        receipt = Join-Path $root 'receipt.json'
        request = Join-Path $root 'request.json'
        owner = Join-Path $root 'owner.json'
    }
}

function Test-DirectGrokRoundTripTimestamp {
    [CmdletBinding()]
    param([AllowNull()][string]$Value)

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    try {
        $parsed = [DateTimeOffset]::ParseExact(
            $text,
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
        return $parsed.ToString('o') -ceq $text
    } catch {
        return $false
    }
}

function Test-DirectGrokCapturedStdoutIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Terminal,
        [Parameter(Mandatory = $true)][string]$CliStdoutPath
    )

    if ($Terminal.success -ne $true) { return $true }
    if (-not $Terminal.Contains('cli_stdout') -or $Terminal.cli_stdout -isnot [Collections.IDictionary]) { return $false }
    if ([string]::IsNullOrWhiteSpace($CliStdoutPath) -or -not [IO.File]::Exists($CliStdoutPath)) { return $false }
    try {
        $actual = Get-DirectGrokFileIdentity -Path $CliStdoutPath
        if ([int64]$actual.bytes -lt 2) { return $false }
        Assert-DirectGrokIdentity -Expected $Terminal.cli_stdout -Actual $actual -Label 'Direct Grok captured CLI stdout'
        return $true
    } catch {
        return $false
    }
}

function Test-DirectGrokTerminalMatchesRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Request,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Terminal,
        [string]$CliStdoutPath = ''
    )
    if ([string]$Terminal.protocol_version -cne 'telephone-line-direct-grok-result-v1') { return $false }
    if ($Terminal.success -isnot [bool]) { return $false }
    if (-not $Request.Contains('created_at_utc') -or -not (Test-DirectGrokRoundTripTimestamp -Value ([string]$Request.created_at_utc))) { return $false }
    if (-not $Terminal.Contains('created_at_utc') -or -not (Test-DirectGrokRoundTripTimestamp -Value ([string]$Terminal.created_at_utc))) { return $false }
    if ([string]$Terminal.created_at_utc -cne [string]$Request.created_at_utc) { return $false }
    if ([string]$Terminal.job_id -cne [string]$Request.job_id) { return $false }
    if ($Terminal.official_cli -ne $true) { return $false }
    if ([string]$Terminal.session_id -cne [string]$Request.session_id) { return $false }
    if ([bool]$Terminal.resumed -ne [bool]$Request.resume) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Terminal.workspace) -or [string]::IsNullOrWhiteSpace([string]$Request.workspace)) { return $false }
    if (-not [IO.Path]::GetFullPath([string]$Terminal.workspace).Equals([IO.Path]::GetFullPath([string]$Request.workspace), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($Request.prompt -isnot [Collections.IDictionary] -or $Terminal.prompt -isnot [Collections.IDictionary]) { return $false }
    if ([string]$Terminal.prompt.sha256 -cne [string]$Request.prompt.sha256) { return $false }
    if ($Terminal.Contains('automatic_rerun') -and [bool]$Terminal.automatic_rerun -ne $false) { return $false }
    if ($Terminal.Contains('replacement_started') -and [bool]$Terminal.replacement_started -ne $false) { return $false }
    if ([bool]$Terminal.success -eq $true -and -not (Test-DirectGrokCapturedStdoutIdentity -Terminal $Terminal -CliStdoutPath $CliStdoutPath)) { return $false }
    return $true
}

function Test-DirectGrokSessionProofMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Request,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Proof,
        [Parameter(Mandatory = $true)][string]$CliStdoutPath
    )
    if ([string]$Proof.protocol_version -cne 'telephone-line-direct-grok-session-proof-v1') { return $false }
    if ([string]$Proof.job_id -cne [string]$Request.job_id) { return $false }
    if ([string]$Proof.session_id -cne [string]$Request.session_id) { return $false }
    if (-not $Request.Contains('created_at_utc') -or -not (Test-DirectGrokRoundTripTimestamp -Value ([string]$Request.created_at_utc))) { return $false }
    if (-not $Proof.Contains('created_at_utc') -or -not (Test-DirectGrokRoundTripTimestamp -Value ([string]$Proof.created_at_utc))) { return $false }
    if ([string]$Proof.created_at_utc -cne [string]$Request.created_at_utc) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Proof.workspace) -or [string]::IsNullOrWhiteSpace([string]$Request.workspace)) { return $false }
    if (-not [IO.Path]::GetFullPath([string]$Proof.workspace).Equals([IO.Path]::GetFullPath([string]$Request.workspace), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($Request.prompt -isnot [Collections.IDictionary] -or $Proof.prompt -isnot [Collections.IDictionary]) { return $false }
    if ([string]$Proof.prompt.sha256 -cne [string]$Request.prompt.sha256) { return $false }
    if (-not [IO.File]::Exists($CliStdoutPath)) { return $false }
    if ($Proof.cli_stdout -isnot [Collections.IDictionary]) { return $false }
    try {
        $actual = Get-DirectGrokFileIdentity -Path $CliStdoutPath
        Assert-DirectGrokIdentity -Expected $Proof.cli_stdout -Actual $actual -Label 'Direct Grok captured CLI stdout'
    } catch {
        return $false
    }
    if ($Proof.Contains('automatic_rerun') -and [bool]$Proof.automatic_rerun -ne $false) { return $false }
    if ($Proof.Contains('replacement_started') -and [bool]$Proof.replacement_started -ne $false) { return $false }
    return $true
}

function ConvertTo-DirectGrokTerminalFromCliStdout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Request,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths
    )
    $cliPath = [string]$Paths.cli_stdout
    $proofPath = [string]$Paths.session_proof
    if (-not [IO.File]::Exists($cliPath) -or -not [IO.File]::Exists($proofPath)) { return $null }
    $proof = Read-DirectGrokTerminalCandidate -Path $proofPath
    if ($null -eq $proof) { return $null }
    if (-not (Test-DirectGrokSessionProofMatches -Request $Request -Proof $proof -CliStdoutPath $cliPath)) { return $null }
    $bytes = [IO.File]::ReadAllBytes($cliPath)
    if ($null -eq $bytes -or $bytes.Length -lt 2) { return $null }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $response = $null
    try {
        $response = $text | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
    } catch { return $null }
    if ($response -isnot [Collections.IDictionary]) { return $null }
    $returnedSession = if ($response.Contains('sessionId')) { [string]$response.sessionId } elseif ($response.Contains('session_id')) { [string]$response.session_id } else { '' }
    if ([string]::IsNullOrWhiteSpace($returnedSession) -or $returnedSession -cne [string]$Request.session_id) { return $null }
    $cliIdentity = Get-DirectGrokFileIdentity -Path $cliPath
    return [ordered]@{
        protocol_version = 'telephone-line-direct-grok-result-v1'
        job_id = [string]$Request.job_id
        success = $true
        error = $null
        workspace = [string]$Request.workspace
        prompt = $Request.prompt
        model_id = 'grok-4.6'
        reasoning_effort = 'xhigh'
        session_id = [string]$Request.session_id
        resumed = [bool]$Request.resume
        grok_exit_code = 0
        response = $response
        diagnostic = ''
        duration_ms = 0
        official_cli = $true
        reconciled = $true
        created_at_utc = [string]$Request.created_at_utc
        cli_stdout = $cliIdentity
        automatic_rerun = $false
        replacement_started = $false
    }
}

function Read-DirectGrokTerminalCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($null -eq $bytes -or $bytes.Length -lt 2) { return $null }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xFEFF)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        $doc = $text | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
        if ($doc -isnot [Collections.IDictionary]) { return $null }
        return $doc
    } catch {
        return $null
    }
}

function Resolve-DirectGrokDurableTerminal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Request
    )
    foreach ($name in @('stdout', 'checkpoint')) {
        $path = [string]$Paths[$name]
        $candidate = Read-DirectGrokTerminalCandidate -Path $path
        if ($null -ne $candidate -and (Test-DirectGrokTerminalMatchesRequest -Request $Request -Terminal $candidate -CliStdoutPath ([string]$Paths.cli_stdout))) {
            return $candidate
        }
    }
    $fromCli = ConvertTo-DirectGrokTerminalFromCliStdout -Request $Request -Paths $Paths
    if ($null -ne $fromCli -and (Test-DirectGrokTerminalMatchesRequest -Request $Request -Terminal $fromCli -CliStdoutPath ([string]$Paths.cli_stdout))) {
        return $fromCli
    }
    return $null
}

function Write-DirectGrokSessionProof {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Artifacts,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Request
    )
    if ([IO.File]::Exists([string]$Artifacts.session_proof)) { return Get-DirectGrokFileIdentity -Path ([string]$Artifacts.session_proof) }
    if (-not [IO.File]::Exists([string]$Artifacts.cli_stdout)) { return $null }
    $cliIdentity = Get-DirectGrokFileIdentity -Path ([string]$Artifacts.cli_stdout)
    $proof = [ordered]@{
        protocol_version = 'telephone-line-direct-grok-session-proof-v1'
        job_id = [string]$Request.job_id
        session_id = [string]$Request.session_id
        workspace = [string]$Request.workspace
        prompt = $Request.prompt
        created_at_utc = [string]$Request.created_at_utc
        cli_stdout = $cliIdentity
        automatic_rerun = $false
        replacement_started = $false
    }
    try { return Write-DirectGrokJsonCreateNew -Path ([string]$Artifacts.session_proof) -Value $proof }
    catch [IO.IOException] { return Get-DirectGrokFileIdentity -Path ([string]$Artifacts.session_proof) }
}

function Resolve-DirectGrokOfficialCommand {
    [CmdletBinding()]
    param([string]$GrokCommand)

    if (-not [string]::IsNullOrWhiteSpace($GrokCommand)) {
        $full = [IO.Path]::GetFullPath($GrokCommand)
        if (-not [IO.File]::Exists($full)) { throw 'Official Grok CLI path does not exist.' }
        return $full
    }
    $cmd = Get-Command 'grok' -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { $cmd = Get-Command 'grok.exe' -ErrorAction SilentlyContinue }
    if ($null -eq $cmd -or [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        throw 'Official Grok CLI was not found. Install the official CLI or pass -GrokCommand.'
    }
    return [IO.Path]::GetFullPath([string]$cmd.Source)
}

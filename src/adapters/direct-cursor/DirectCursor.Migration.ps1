# SPDX-License-Identifier: MPL-2.0
# Explicit, evidence-bound recovery of a continuation stopped for installation.
# The archived admission and its consumed counter are never rewritten.
function Assert-DirectCursorMigrationProof {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProofPath)
    $read = Read-DirectJson -Path $ProofPath
    $p = $read.value
    if ([string]$p.protocol_version -cne 'telephone-line-direct-cursor-migration-proof-v1' -or
        [string]$p.reason -cne 'authorized_installation_migration' -or
        [string]$p.service_tier -cne 'default') { throw 'Migration proof contract is invalid.' }
    if ([string]$p.job_id -cnotmatch '^[0-9a-f-]{36}$' -or [string]$p.native_session_id -cnotmatch '^[A-Za-z0-9._:-]+$') { throw 'Migration identity is invalid.' }
    foreach ($key in @('admission','registry','interrupted_request','interrupted_owner','transcript','meta','lead_binding','authority','stop_journal')) {
        $id = $p.evidence[$key]
        if ($null -eq $id) { throw "Migration $key evidence is missing." }
        Assert-DirectIdentity -Expected $id -Actual (Get-DirectFileIdentity -Path ([string]$id.path)) -Label "Migration $key"
    }
    $source = Get-DirectCanonicalDirectory -Path ([string]$p.source_state_root)
    $target = [IO.Path]::GetFullPath([string]$p.target_state_root).TrimEnd('\')
    if ($source.Equals($target, [StringComparison]::OrdinalIgnoreCase)) { throw 'Migration requires a new state root.' }
    Assert-DirectIdentity -Expected $p.evidence.admission -Actual (Get-DirectFileIdentity -Path (Get-DirectCursorPartialAdmissionPath -StateRoot $source -NativeSessionId ([string]$p.native_session_id))) -Label 'Archived admission'
    Assert-DirectIdentity -Expected $p.evidence.registry -Actual (Get-DirectFileIdentity -Path (Get-DirectCursorSessionRegistryPath -StateRoot $source)) -Label 'Archived registry'
    $a = Test-DirectCursorPartialAdmissionUsable -StateRoot $source -NativeSessionId ([string]$p.native_session_id)
    if ($null -eq $a -or [string]$a.status -cne 'provisional' -or [string]$a.acceptance -cne 'pending' -or [int]$a.continuation_remaining -ne 0) { throw 'Migration requires an already consumed provisional admission.' }
    foreach ($state in @($source,$target)) {
        if ([IO.File]::Exists((Join-Path $state ('sessions/' + $p.native_session_id + '/binding.json')))) { throw 'Migration cannot replace an accepted binding.' }
    }
    $r = (Read-DirectJson -Path ([string]$p.evidence.interrupted_request.path)).value
    $sourceJob = Join-Path $source ('jobs/' + [string]$a.continuation_job_id)
    Assert-DirectIdentity -Expected $p.evidence.interrupted_request -Actual (Get-DirectFileIdentity -Path (Join-Path $sourceJob 'request.json')) -Label 'Interrupted request'
    Assert-DirectIdentity -Expected $p.evidence.interrupted_owner -Actual (Get-DirectFileIdentity -Path (Join-Path $sourceJob 'owner.json')) -Label 'Interrupted owner'
    if ([IO.File]::Exists((Join-Path $sourceJob 'receipt.json'))) { throw 'Interrupted job already has a receipt; use its actual terminal disposition.' }
    if ([string]$r.job_id -cne [string]$a.continuation_job_id -or [string]$r.resume_session_id -cne [string]$a.native_session_id -or
        [string]$r.mode -cne [string]$a.mode -or [string]$r.model -cne [string]$a.model_id -or [string]$r.model -cne 'cursor-grok-4.6-xhigh' -or $r.allow_fast -ne $false) { throw 'Interrupted continuation binding mismatch.' }
    $workspace = [IO.Path]::GetFullPath([string]$a.workspace).TrimEnd('\')
    if (-not $workspace.Equals([IO.Path]::GetFullPath([string]$r.workspace).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase) -or
        (Get-DirectCursorSortedWriteScope -Paths $r.allowed_write_paths) -cne (Get-DirectCursorSortedWriteScope -Paths $a.allowed_write_paths)) { throw 'Migration workspace or write scope mismatch.' }
    if ($target.Equals($workspace,[StringComparison]::OrdinalIgnoreCase) -or $target.StartsWith($workspace + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Migration state cannot be inside the workspace.' }
    $meta = (Read-DirectJson -Path ([string]$p.evidence.meta.path)).value
    if ($meta.hasConversation -ne $true -or -not $workspace.Equals([IO.Path]::GetFullPath([string]$meta.cwd).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([string]$p.evidence.meta.path)) -cne [string]$a.native_session_id) { throw 'Migration native metadata mismatch.' }
    $null = Test-DirectCursorJsonlTranscript -Path ([string]$p.evidence.transcript.path) -ExpectedSessionId ([string]$a.native_session_id)
    # Evidence must be the original native files, with their current post-stop bytes.
    foreach ($key in @('meta','transcript')) {
        if (-not [IO.Path]::GetFullPath([string]$p.evidence[$key].path).Equals([IO.Path]::GetFullPath([string]$a.native_evidence[$key].path),[StringComparison]::OrdinalIgnoreCase)) { throw 'Migration native source path mismatch.' }
    }
    $lead = (Read-DirectJson -Path ([string]$p.evidence.lead_binding.path)).value
    if ([string]$lead.session_id -cne [string]$p.lead_session_id -or [string]::IsNullOrWhiteSpace([string]$p.lead_session_id)) { throw 'Migration Lead binding mismatch.' }
    $owner = (Read-DirectJson -Path ([string]$p.evidence.interrupted_owner.path)).value
    $null = Confirm-DirectCursorOwnerDead -Owner $owner -Source 'migration_interrupted_owner'
    $journal = (Read-DirectJson -Path ([string]$p.evidence.stop_journal.path)).value
    $stopped = @($journal | Where-Object { [int](Get-DirectNoteValue -Object $_ -Name 'pid') -eq [int]$owner.pid -and [int64](Get-DirectNoteValue -Object $_ -Name 'expected_ticks') -eq [int64]$owner.start_time_utc_ticks -and [string](Get-DirectNoteValue -Object $_ -Name 'state') -cin @('authorized_freeze_stop','already_absent') })
    if ($stopped.Count -lt 1) { throw 'Migration stop journal does not bind the interrupted owner.' }
    foreach ($extra in @($p.dead_owners)) { $null = Confirm-DirectCursorOwnerDead -Owner $extra -Source 'migration_related_owner' }
    return [ordered]@{ proof = $p; identity = $read.identity; admission = $a; target_state_root = $target; workspace = $workspace }
}

function Register-DirectCursorMigrationContinuation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProofPath)
    $checked = Assert-DirectCursorMigrationProof -ProofPath $ProofPath
    $p = $checked.proof
    $mutex = [Threading.Mutex]::new($false,(Get-DirectCursorWorkspaceMutexName -Workspace $checked.workspace))
    $held = $false
    try {
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Another Cursor dispatch already owns this workspace.' }
        $checked = Assert-DirectCursorMigrationProof -ProofPath $ProofPath
        $key = Get-DirectTextSha256 -Text ([string]$p.native_session_id + "`n" + [string]$checked.admission.continuation_job_id)
        $folder = Join-Path $checked.target_state_root ('migration-continuations/' + $key)
        $path = Join-Path $folder 'grant.json'
        $grant = [ordered]@{
            protocol_version = 'telephone-line-direct-cursor-migration-grant-v1'
            proof = $checked.identity
            native_session_id = [string]$p.native_session_id
            lead_session_id = [string]$p.lead_session_id
            job_id = [string]$p.job_id
            target_state_root = $checked.target_state_root
            workspace = $checked.workspace
            mode = [string]$checked.admission.mode
            model = [string]$checked.admission.model_id
            service_tier = 'default'
            allowed_write_paths = @($checked.admission.allowed_write_paths)
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            original_continuation_remaining = 0
            accepted_binding_written = $false
            provider_started = $false
        }
        [IO.Directory]::CreateDirectory($folder) | Out-Null
        if ([IO.File]::Exists($path)) {
            $old = (Read-DirectJson -Path $path).value
            Assert-DirectIdentity -Expected $old.proof -Actual $checked.identity -Label 'Existing migration proof'
        } else { $null = Write-DirectJsonCreateNew -Path $path -Value $grant }
        # The wrapper needs an observed native record in the new state. This is
        # explicitly pending; it carries no accepted binding or replenished quota.
        $grantIdentity = Get-DirectFileIdentity -Path $path
        $registryMutex = [Threading.Mutex]::new($false,'Global\TelephoneLineCursorSessionRegistry')
        $registryHeld = $false
        try {
            try { $registryHeld = $registryMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $registryHeld = $true }
            if (-not $registryHeld) { throw 'Cursor session registry is busy.' }
            $registryPath = Get-DirectCursorSessionRegistryPath -StateRoot $checked.target_state_root
            $registry = if ([IO.File]::Exists($registryPath)) { (Read-DirectJson -Path $registryPath).value } else { [ordered]@{schema_version=1;sessions=@()} }
            if ($registry.schema_version -ne 1) { throw 'Cursor session registry schema is unsupported.' }
            $rows = @($registry.sessions | Where-Object { $_.session_id -ceq $p.native_session_id })
            if ($rows.Count -gt 0) {
                if ($rows.Count -ne 1 -or [string]$rows[0].admission_kind -cne 'migration_observed' -or [string]$rows[0].acceptance -cne 'pending') { throw 'Conflicting migration registry record.' }
                Assert-DirectIdentity -Expected $rows[0].migration_grant -Actual $grantIdentity -Label 'Migration registry grant'
            } else {
                $now = [DateTimeOffset]::UtcNow.ToString('o')
                $registry.sessions = @($registry.sessions) + [ordered]@{
                    session_id=[string]$p.native_session_id; model_id=[string]$checked.admission.model_id
                    workspace=$checked.workspace; mode=[string]$checked.admission.mode
                    allowed_write_paths=@($checked.admission.allowed_write_paths)
                    last_dispatch_id=''; last_normalized_request_sha256=''; created_at=$now; last_used_at=$now
                    acceptance='pending'; admission_kind='migration_observed'; migration_grant=$grantIdentity
                    original_continuation_remaining=0
                }
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($registryPath)) | Out-Null
                $temp = $registryPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
                $null = Write-DirectJsonCreateNew -Path $temp -Value $registry
                [IO.File]::Move($temp,$registryPath,$true)
            }
        } finally { if ($registryHeld) { $registryMutex.ReleaseMutex() }; $registryMutex.Dispose() }
        return [ordered]@{ grant = $grantIdentity; provider_started = $false; archived_state_modified = $false; accepted_binding_written = $false }
    } finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Assert-DirectCursorMigrationContinuation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GrantPath,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$NativeSessionId,
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][string]$WorkspacePath,
        [Parameter(Mandatory = $true)][string]$Mode,
        [string[]]$AllowedWritePath,
        [switch]$Consume
    )
    $grantRead = Read-DirectJson -Path $GrantPath
    $g = $grantRead.value
    if ([string]$g.protocol_version -cne 'telephone-line-direct-cursor-migration-grant-v1') { throw 'Migration grant contract is invalid.' }
    Assert-DirectIdentity -Expected $g.proof -Actual (Get-DirectFileIdentity -Path ([string]$g.proof.path)) -Label 'Migration proof'
    $checked = Assert-DirectCursorMigrationProof -ProofPath ([string]$g.proof.path)
    $p = $checked.proof
    $key = Get-DirectTextSha256 -Text ([string]$p.native_session_id + "`n" + [string]$checked.admission.continuation_job_id)
    $expectedPath = Join-Path $checked.target_state_root ('migration-continuations/' + $key + '/grant.json')
    if (-not [IO.Path]::GetFullPath($GrantPath).Equals([IO.Path]::GetFullPath($expectedPath),[StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.Path]::GetFullPath($StateRoot).TrimEnd('\').Equals($checked.target_state_root,[StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.Path]::GetFullPath($WorkspacePath).TrimEnd('\').Equals($checked.workspace,[StringComparison]::OrdinalIgnoreCase) -or
        $NativeSessionId -cne [string]$p.native_session_id -or $JobId -cne [string]$p.job_id -or $Mode -cne [string]$checked.admission.mode) { throw 'Migration continuation identity mismatch.' }
    $scope = ConvertTo-DirectRelativeWritePaths -WorkspacePath $checked.workspace -Paths $AllowedWritePath
    if ((Get-DirectCursorSortedWriteScope -Paths $scope) -cne (Get-DirectCursorSortedWriteScope -Paths $checked.admission.allowed_write_paths)) { throw 'Migration continuation write scope mismatch.' }
    $record = Get-DirectCursorPartialRegistryRecord -StateRoot $checked.target_state_root -NativeSessionId $NativeSessionId
    if ($null -eq $record -or [string]$record.admission_kind -cne 'migration_observed' -or [string]$record.acceptance -cne 'pending') { throw 'Migration registry is missing or inconsistent.' }
    Assert-DirectIdentity -Expected $record.migration_grant -Actual $grantRead.identity -Label 'Migration registry grant'
    $claim = Join-Path ([IO.Path]::GetDirectoryName($expectedPath)) 'consumed.json'
    if ([IO.File]::Exists($claim)) { throw 'Migration continuation has already been consumed; recover the recorded job.' }
    if ($Consume) {
        $null = Write-DirectJsonCreateNew -Path $claim -Value ([ordered]@{
            protocol_version = 'telephone-line-direct-cursor-migration-consumption-v1'
            grant = $grantRead.identity
            job_id = $JobId
            native_session_id = $NativeSessionId
            consumed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            provider_started = $false
            automatic_rerun = $false
        })
    }
    return $checked
}

# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$CodexCommand,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexAppServerLead.Common.ps1')

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tl-app-server-qualification-' + [Guid]::NewGuid().ToString('N'))
try {
    $exe = Resolve-CodexAppServerExecutable -CodexCommand $CodexCommand
    $version = Get-CodexAppServerVersion -CodexCommand $exe
    $schema = Invoke-CodexAppServerGenerateSchema -CodexCommand $exe -OutputDirectory $tempRoot
    $surface = Get-CodexAppServerSchemaSurfaceFingerprint -SchemaDirectory $tempRoot
    $profile = New-CodexAppServerProfileObject -CodexCommand $exe -CodexVersion $version -Fingerprint $schema
    $approved = Get-CodexAppServerApprovedCompatibilityEntry -License $profile
    $matches = @(
        $script:CodexAppServerApprovedCompatibilityEntries | Where-Object {
            [int]$_.SurfaceFileCount -eq [int]$surface.file_count -and
            [int64]$_.SurfaceBytes -eq [int64]$surface.schema_bytes -and
            [string]$_.SurfaceFingerprint -ceq [string]$surface.fingerprint
        }
    )
    $evidence = Get-CodexAppServerCompatibilitySchemaEvidence -SchemaDirectory $tempRoot
    $matchedRules = @($matches | ForEach-Object { [string]$_.AdapterRule } | Select-Object -Unique)
    $matchedProjectIdModes = @($matches | ForEach-Object { [string]$_.ProjectIdMode } | Select-Object -Unique)
    $matchedNotificationModes = @($matches | ForEach-Object { [string]$_.NotificationEnvelopeMode } | Select-Object -Unique)
    $compatibleMatch = (
        $matches.Count -gt 0 -and
        $matchedRules.Count -eq 1 -and
        $matchedProjectIdModes.Count -eq 1 -and
        $matchedNotificationModes.Count -eq 1
    )
    $candidateRule = if ($compatibleMatch) { [string]$matchedRules[0] } else { '' }
    $candidateProjectIdMode = if ($compatibleMatch) { [string]$matchedProjectIdModes[0] } else { '' }
    $candidateNotificationMode = if ($compatibleMatch) { [string]$matchedNotificationModes[0] } else { '' }
    $result = [ordered]@{
        protocol_version = 'telephone-line-codex-app-server-qualification-v1'
        started = $false
        codex_version = $version
        schema_file_count = [int]$schema.file_count
        schema_bytes = [int64]$schema.schema_bytes
        schema_fingerprint = [string]$schema.fingerprint
        surface_file_count = [int]$surface.file_count
        surface_bytes = [int64]$surface.schema_bytes
        surface_fingerprint = [string]$surface.fingerprint
        approved = ($null -ne $approved)
        approved_adapter_rule = if ($null -ne $approved) { [string]$approved.AdapterRule } else { '' }
        approved_project_id_mode = if ($null -ne $approved) { [string]$approved.ProjectIdMode } else { '' }
        approved_notification_envelope_mode = if ($null -ne $approved) { [string]$approved.NotificationEnvelopeMode } else { '' }
        structurally_identical_versions = @($matches | ForEach-Object { [string]$_.CodexVersion })
        record_only_candidate = ($null -eq $approved -and $compatibleMatch)
        candidate_adapter_rule = $candidateRule
        candidate_project_id_mode = $candidateProjectIdMode
        candidate_notification_envelope_mode = $candidateNotificationMode
        requires_adapter_change = ($null -eq $approved -and -not $compatibleMatch)
        schema_evidence = $evidence
        candidate_record = [ordered]@{
            CodexVersion = $version
            SchemaFileCount = [int]$schema.file_count
            SchemaBytes = [int64]$schema.schema_bytes
            SchemaFingerprint = [string]$schema.fingerprint
            SurfaceFileCount = [int]$surface.file_count
            SurfaceBytes = [int64]$surface.schema_bytes
            SurfaceFingerprint = [string]$surface.fingerprint
            AdapterRule = $candidateRule
            ProjectIdMode = $candidateProjectIdMode
            NotificationEnvelopeMode = $candidateNotificationMode
        }
        service_tier = 'default'
        absolute_task_timeout = $false
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $full = Get-CodexAppServerCanonicalPath -Path $OutputPath
        Assert-CodexAppServerStateOutsidePackage -StateRoot ([IO.Path]::GetDirectoryName($full))
        $null = Write-CodexAppServerJsonReplace -Path $full -Value $result
    }
    Write-CodexAppServerStdoutJson -Value $result
    exit 0
} catch {
    $failure = Get-CodexAppServerPublicFailure -Message ([string]$_.Exception.Message)
    Write-CodexAppServerStdoutJson -Value ([ordered]@{
        protocol_version = 'telephone-line-codex-app-server-qualification-v1'
        started = $false
        approved = $false
        error = [string]$failure.message
        code = [string]$failure.code
    })
    exit 2
} finally {
    try { Remove-CodexAppServerDirectoryNative -Path $tempRoot -Label 'qualification schema temp' } catch { }
}

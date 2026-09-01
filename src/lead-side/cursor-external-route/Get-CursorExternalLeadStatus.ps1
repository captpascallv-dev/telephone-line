# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourcesPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CursorExternalLead.Common.ps1')

$sourcesRead = Read-TelephoneJson -Path $SourcesPath
$sourcesDoc = $sourcesRead.value
if ([string]$sourcesDoc.protocol_version -cne 'telephone-line-cursor-external-status-sources-v1') {
    throw 'Status sources protocol is invalid.'
}
if ($null -eq $sourcesDoc.sources -or $sourcesDoc.sources -is [string]) {
    throw 'Status sources list is missing.'
}

$items = [Collections.Generic.List[object]]::new()
$failClosed = $false
$failClosedDetail = ''

foreach ($source in @($sourcesDoc.sources)) {
    $sourceId = [string]$source.id
    $kind = [string]$source.kind
    $root = [string]$source.root
    $declaredIds = @()
    if ($source -is [Collections.IDictionary] -and $source.Contains('declared_running_ids') -and $null -ne $source.declared_running_ids) {
        $declaredIds = @($source.declared_running_ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $declaredRunningFlag = $false
    if ($source -is [Collections.IDictionary] -and $source.Contains('declared_running')) {
        $declaredRunningFlag = [bool]($source.declared_running -is [bool] -and $source.declared_running -eq $true)
    }

    $enumerated = [Collections.Generic.List[string]]::new()
    try {
        if ([string]::IsNullOrWhiteSpace($root)) { throw 'Source root is empty.' }
        $fullRoot = [IO.Path]::GetFullPath($root).TrimEnd('\')
        if ([IO.Directory]::Exists($fullRoot)) {
            foreach ($dir in [IO.Directory]::GetDirectories($fullRoot)) {
                $enumerated.Add($dir)
            }
        } elseif ([IO.File]::Exists($fullRoot)) {
            throw "Source root is a file, not a directory: $fullRoot"
        }
    } catch {
        $failClosed = $true
        $failClosedDetail = Protect-CursorExternalText -Text ("enumeration error on source ${sourceId}: $($_.Exception.Message)") -MaxLength 500
        continue
    }

    if ($declaredIds.Count -gt 0) {
        $enumeratedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($dir in $enumerated) {
            [void]$enumeratedNames.Add([IO.Path]::GetFileName($dir))
        }
        $missingDeclared = $false
        foreach ($declaredId in $declaredIds) {
            if (-not $enumeratedNames.Contains($declaredId)) {
                $failClosed = $true
                $failClosedDetail = "source $sourceId declared a running item that was not enumerated"
                $missingDeclared = $true
                break
            }
        }
        if ($missingDeclared) {
            continue
        }
    } elseif ($declaredRunningFlag -and $enumerated.Count -eq 0) {
        $failClosed = $true
        $failClosedDetail = "source $sourceId declared a running item but enumeration returned zero"
        continue
    }

    foreach ($jobRoot in $enumerated) {
        $stage = Resolve-CursorExternalJobStage -JobRoot $jobRoot
        $lead = Get-CursorExternalLeadIdentityFromJob -JobRoot $jobRoot
        $summary = ''
        foreach ($name in @('dispatch.json', 'request.json', 'lead-run.json', 'lead-binding.json')) {
            $path = Join-Path $jobRoot $name
            if ([IO.File]::Exists($path)) {
                $parsed = (Read-TelephoneJson -Path $path).value
                if ($parsed -is [Collections.IDictionary] -and $parsed.Contains('summary') -and -not [string]::IsNullOrWhiteSpace([string]$parsed.summary)) {
                    $summary = [string]$parsed.summary
                    break
                }
            }
        }
        $items.Add([ordered]@{
            source_id = $sourceId
            source_kind = $kind
            item_id = [IO.Path]::GetFileName($jobRoot)
            item_root = $jobRoot
            stage = $stage
            lead = $lead
            summary = Protect-CursorExternalText -Text $summary -MaxLength 500
        })
    }
}

$overall = if ($failClosed) { 'fail_closed' } else { 'ok' }
$result = [ordered]@{
    protocol_version = 'telephone-line-cursor-external-status-v1'
    profile = 'cursor-external-lead'
    overall_status = $overall
    started = $false
    mutated = $false
    fail_closed_detail = $failClosedDetail
    items = @($items)
}
Write-CursorExternalStdoutJson -Value $result
if ($failClosed) { exit 2 }
exit 0

# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [ValidateRange(1, 3600)][int]$CommandStartupGraceSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TelephoneLine.Common.ps1')
$null = Invoke-TelephoneDashboardEnsure

$state = Assert-TelephoneDirectoryPath -Path $StateRoot -Label 'State root'
$jobsRoot = Join-Path $state 'jobs'
$summary = [ordered]@{ scanned = 0; relays_started = 0; interrupted_receipts_created = 0; command_start_ambiguous_receipts_created = 0; command_start_pending = 0; already_delivered = 0 }
if (-not [IO.Directory]::Exists($jobsRoot)) { $summary | ConvertTo-Json -Compress; exit 0 }

foreach ($job in @(Get-ChildItem -LiteralPath $jobsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $summary.scanned += 1
    $paths = Get-TelephoneJobPaths -JobRoot $job.FullName
    if ([IO.File]::Exists($paths.delivery)) { $summary.already_delivered += 1; continue }
    if (-not [IO.File]::Exists($paths.receipt)) {
        $commandOwner = $null
        if ([IO.File]::Exists($paths.command_owner)) {
            $commandOwner = (Read-TelephoneJson -Path $paths.command_owner).value
        }
        if (-not (Test-TelephoneOwnerAlive -Owner $commandOwner) -and (Test-TelephoneCommandLaunchAlive -Paths $paths)) {
            $commandOwner = (Read-TelephoneJson -Path $paths.command_launch).value.owner
        }
        if (-not (Test-TelephoneOwnerAlive -Owner $commandOwner) -and -not [IO.File]::Exists($paths.command_owner)) {
            $commandOwner = $null
        }
        if ($null -eq $commandOwner -and [IO.File]::Exists($paths.command_start_intent)) {
            $dispatchRead = Read-TelephoneJson -Path $paths.dispatch -SchemaName 'dispatch'
            $dispatch = $dispatchRead.value
            $startIntent = (Read-TelephoneJson -Path $paths.command_start_intent).value
            if ([string]$startIntent.protocol_version -cne 'telephone-line-command-start-v1' -or
                [string]$startIntent.line_job_id -cne [string]$dispatch.line_job_id) {
                throw 'Telephone command start intent binding is invalid.'
            }
            Assert-TelephoneFileIdentity -Expected $dispatchRead.identity -Actual $startIntent.dispatch -Label 'Telephone command start dispatch'
            $expectedCommandHost = Get-TelephoneFileIdentity -Path (Join-Path $PSScriptRoot 'Invoke-TelephoneLineCommandHost.ps1')
            Assert-TelephoneFileIdentity -Expected $expectedCommandHost -Actual $startIntent.command_host -Label 'Telephone command start host'
            $created = [DateTimeOffset]::ParseExact([string]$startIntent.created_at_utc, 'o', [Globalization.CultureInfo]::InvariantCulture)
            if (([DateTimeOffset]::UtcNow - $created).TotalSeconds -lt $CommandStartupGraceSeconds) {
                $summary.command_start_pending += 1
            } else {
                $startGate = Open-TelephoneExclusiveGate -Path $paths.command_gate -WaitMilliseconds 100
                if ($null -eq $startGate) {
                    $summary.command_start_pending += 1
                } else {
                    try {
                        if ([IO.File]::Exists($paths.command_owner)) {
                            $commandOwner = (Read-TelephoneJson -Path $paths.command_owner).value
                        } elseif ((Test-TelephoneCommandLaunchAlive -Paths $paths)) {
                            $commandOwner = (Read-TelephoneJson -Path $paths.command_launch).value.owner
                            $summary.command_start_pending += 1
                        } elseif (-not [IO.File]::Exists($paths.receipt)) {
                            $receipt = New-TelephoneTransportFailureReceipt -DispatchRead $dispatchRead `
                                -ErrorCode 'COMMAND_START_AMBIGUOUS_NO_RERUN' `
                                -ErrorMessage 'The command host did not publish its startup identity. The external task was not automatically rerun.' `
                                -StartedAtUtc $null
                            try {
                                $null = Write-TelephoneJsonCreateNew -Path $paths.receipt -Value $receipt
                                $summary.command_start_ambiguous_receipts_created += 1
                            } catch [IO.IOException] { }
                        }
                    } finally {
                        $startGate.Dispose()
                    }
                }
            }
        }
        if (-not [IO.File]::Exists($paths.receipt)) {
            $sync = Sync-TelephoneCommandOwnerCompletion -Paths $paths
            if ([string]$sync -ceq 'interrupted') { $summary.interrupted_receipts_created += 1 }
        }
    }
    $relayOwner = if ([IO.File]::Exists($paths.relay_owner)) { (Read-TelephoneJson -Path $paths.relay_owner).value } else { $null }
    if (-not (Test-TelephoneOwnerAlive -Owner $relayOwner)) {
        $newRelay = Start-TelephoneHiddenPowerShell -ScriptPath (Join-Path $PSScriptRoot 'Invoke-TelephoneLineRelay.ps1') -Arguments @('-JobRoot', $job.FullName)
        $attemptPath = Join-Path $job.FullName ('relay-resume-' + [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') + '.json')
        $null = Write-TelephoneJsonCreateNew -Path $attemptPath -Value $newRelay
        $summary.relays_started += 1
    }
    if ([IO.File]::Exists($paths.receipt) -and -not [IO.File]::Exists($paths.delivery) -and -not [IO.File]::Exists($paths.relay_error)) {
        try {
            $dispatchForMailbox = (Read-TelephoneJson -Path $paths.dispatch).value
            $leadForMailbox = Read-TelephoneLeadBinding -Lead $dispatchForMailbox.lead
            $canonical = Get-TelephoneLeadCanonicalIdentity -Lead $leadForMailbox
            $null = Ensure-TelephoneLeadCollector -StateRoot $state -LeadKey ([string]$canonical.identity_sha256) -RelayScript (Join-Path $PSScriptRoot 'Invoke-TelephoneLineRelay.ps1')
        } catch { }
    }
    try {
        if ([IO.File]::Exists($paths.dispatch)) {
            $dispatch = (Read-TelephoneJson -Path $paths.dispatch).value
            $session = if ($null -ne $dispatch.lead) { [string]$dispatch.lead.session_id } else { '' }
            if (-not [string]::IsNullOrWhiteSpace([string]$dispatch.project) -and -not [string]::IsNullOrWhiteSpace($session)) {
                $null = Write-TelephonePublicLifecycleEvent -Root $job.FullName -Kind 'restart' -Transport 'wired' -Project ([string]$dispatch.project) -LeadSessionId $session -LineJobId ([string]$dispatch.line_job_id)
            }
        }
    } catch { }
}
$summary | ConvertTo-Json -Compress

# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('status', 'cancel-one', 'pause', 'emergency-stop-all', 'resume')][string]$Action,
    [string]$RunId,
    [switch]$Confirm,
    [string]$StateRoot,
    [string]$InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TelephoneSupervisor.Common.ps1')
if (-not $IsWindows) { throw 'Telephone Line v0.1 supports Windows only.' }

$control = [ordered]@{
    protocol_version = 'telephone-line-wired-supervisor-control-v1'
    action = [string]$Action
}
if (-not [string]::IsNullOrWhiteSpace($RunId)) { $control.run_id = [string]$RunId }
if ($PSBoundParameters.ContainsKey('Confirm')) { $control.confirm = [bool]$Confirm }
Assert-TelephoneJsonSchema -JsonText (ConvertTo-TelephoneSupervisorJson -Value $control) -SchemaName 'wired-supervisor-control' -Label 'wired supervisor control'

$resolvedState = Resolve-TelephoneSupervisorStateRoot -StateRoot $StateRoot
$resolvedInstall = if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
    [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
} else {
    ''
}

$result = [ordered]@{ ok = $true; action = [string]$Action; mutated = $false }
switch ([string]$Action) {
    'status' {
        $result.status = Get-TelephoneSupervisorStatus -StateRoot $resolvedState -InstallRoot $resolvedInstall
    }
    'pause' {
        $null = Write-TelephoneSupervisorPause -StateRoot $resolvedState -Paused $true
        $result.mutated = $true
        $result.paused_by_pascal = $true
        $result.status = Get-TelephoneSupervisorStatus -StateRoot $resolvedState -InstallRoot $resolvedInstall
    }
    'resume' {
        $null = Write-TelephoneSupervisorPause -StateRoot $resolvedState -Paused $false
        $result.mutated = $true
        $result.paused_by_pascal = $false
        $result.resurrected = $false
        $triggered = $false
        $supervisorScript = ''
        if (-not [string]::IsNullOrWhiteSpace($resolvedInstall)) {
            $supervisorScript = Join-Path $resolvedInstall 'src\supervisor\Invoke-TelephoneSupervisor.ps1'
        }
        if ([string]::IsNullOrWhiteSpace($supervisorScript) -or -not [IO.File]::Exists($supervisorScript)) {
            $supervisorScript = Join-Path $PSScriptRoot 'Invoke-TelephoneSupervisor.ps1'
        }
        try {
            $arguments = ('-StateRoot "' + $resolvedState + '"')
            if (-not [string]::IsNullOrWhiteSpace($resolvedInstall)) {
                $arguments = ('-InstallRoot "' + $resolvedInstall + '" ' + $arguments)
            }
            $null = Invoke-TelephoneSupervisorTaskOperation -Operation start -InstallRoot $resolvedInstall -ActionScript $supervisorScript -ActionArguments $arguments
            $triggered = $true
        } catch { }
        $result.triggered = [bool]$triggered
        $result.status = Get-TelephoneSupervisorStatus -StateRoot $resolvedState -InstallRoot $resolvedInstall
        Invoke-TelephoneSupervisorIdleVersionActivation -InstallRoot $resolvedInstall -StateRoot $resolvedState | Out-Null
    }
    'cancel-one' {
        if ([string]::IsNullOrWhiteSpace($RunId)) { throw 'cancel-one requires run_id.' }
        $stop = Stop-TelephoneSupervisorExactRun -StateRoot $resolvedState -RunId $RunId
        if (-not [bool]$stop.stopped -and [string]$stop.reason -cne 'job-missing-and-owner-dead') {
            $result.ok = $false
            $result.reason = [string]$stop.reason
        } else {
            $claimed = Read-TelephoneSupervisorOptionalRecord -Path (Get-TelephoneSupervisorRecordPath -StateRoot $resolvedState -Kind claimed -RunId $RunId)
            $request = if ($null -ne $claimed) { $claimed.value } else { $null }
            $null = Write-TelephoneSupervisorOutbox -StateRoot $resolvedState -RunId $RunId -Terminal 'cancelled' -Request $request
            $result.mutated = $true
            $result.stopped = [bool]$stop.stopped
        }
        $result.remaining_run_ids = @(Get-TelephoneSupervisorActiveRunList -StateRoot $resolvedState | ForEach-Object { [string]$_.run_id })
        $result.status = Get-TelephoneSupervisorStatus -StateRoot $resolvedState -InstallRoot $resolvedInstall
        Invoke-TelephoneSupervisorIdleVersionActivation -InstallRoot $resolvedInstall -StateRoot $resolvedState | Out-Null
    }
    'emergency-stop-all' {
        $status = Get-TelephoneSupervisorStatus -StateRoot $resolvedState -InstallRoot $resolvedInstall
        $result.active_before = @($status.active_runs)
        $result.active_count = @($status.active_runs).Count
        if (-not $Confirm) {
            $result.ok = $false
            $result.reason = 'confirm-required'
            $result.status = $status
            Write-Output (ConvertTo-TelephoneSupervisorJson -Value $result).TrimEnd()
            exit 1
        }
        $stopped = [Collections.Generic.List[object]]::new()
        $refused = [Collections.Generic.List[object]]::new()
        foreach ($run in @(Get-TelephoneSupervisorActiveRunList -StateRoot $resolvedState)) {
            $stop = Stop-TelephoneSupervisorExactRun -StateRoot $resolvedState -RunId ([string]$run.run_id)
            if ([bool]$stop.stopped -or [string]$stop.reason -ceq 'job-missing-and-owner-dead') {
                $claimed = Read-TelephoneSupervisorOptionalRecord -Path (Get-TelephoneSupervisorRecordPath -StateRoot $resolvedState -Kind claimed -RunId ([string]$run.run_id))
                $request = if ($null -ne $claimed) { $claimed.value } else { $null }
                $null = Write-TelephoneSupervisorOutbox -StateRoot $resolvedState -RunId ([string]$run.run_id) -Terminal 'cancelled' -Request $request
                [void]$stopped.Add([string]$run.run_id)
            } else {
                [void]$refused.Add([ordered]@{ run_id = [string]$run.run_id; reason = [string]$stop.reason })
            }
        }
        $null = Write-TelephoneSupervisorPause -StateRoot $resolvedState -Paused $true
        $result.mutated = $true
        $result.paused_by_pascal = $true
        $result.stopped_run_ids = @($stopped)
        $result.refused = @($refused)
        $result.remaining_run_ids = @(Get-TelephoneSupervisorActiveRunList -StateRoot $resolvedState | ForEach-Object { [string]$_.run_id })
        $result.status = Get-TelephoneSupervisorStatus -StateRoot $resolvedState -InstallRoot $resolvedInstall
        Invoke-TelephoneSupervisorIdleVersionActivation -InstallRoot $resolvedInstall -StateRoot $resolvedState | Out-Null
    }
}

Write-Output (ConvertTo-TelephoneSupervisorJson -Value $result).TrimEnd()
if ($result.ok -eq $true) { exit 0 }
exit 1

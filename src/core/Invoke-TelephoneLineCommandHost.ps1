# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$JobRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TelephoneLine.Common.ps1')

$paths = Get-TelephoneJobPaths -JobRoot $JobRoot
$dispatchRead = Read-TelephoneJson -Path $paths.dispatch -SchemaName 'dispatch'
$dispatch = $dispatchRead.value
$startGate = Open-TelephoneExclusiveGate -Path $paths.command_gate -WaitMilliseconds 30000
if ($null -eq $startGate) { throw 'The command host could not acquire its startup gate.' }
try {
    if ([IO.File]::Exists($paths.receipt)) { exit 0 }
    $selfProcess = Get-Process -Id $PID -ErrorAction Stop
    try {
        $selfOwner = [ordered]@{
            pid = [int]$PID
            start_time_utc_ticks = [int64]$selfProcess.StartTime.ToUniversalTime().Ticks
            started_at_utc = $selfProcess.StartTime.ToUniversalTime().ToString('o')
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID)) {
            $selfOwner.supervisor_run_id = [string]$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID
        }
    } finally {
        $selfProcess.Dispose()
    }
    try {
        $null = Write-TelephoneJsonCreateNew -Path $paths.command_owner -Value $selfOwner
    } catch [IO.IOException] {
        $existingOwner = (Read-TelephoneJson -Path $paths.command_owner).value
        if ([int]$existingOwner.pid -ne [int]$selfOwner.pid -or [int64]$existingOwner.start_time_utc_ticks -ne [int64]$selfOwner.start_time_utc_ticks) {
            throw 'Another command host already owns this telephone-line job.'
        }
    }
    if ([IO.File]::Exists($paths.receipt)) { exit 0 }
} finally {
    $startGate.Dispose()
}
$startedAt = [DateTimeOffset]::UtcNow
$exitCode = 1
$errorCode = $null
$errorMessage = $null

try {
    $existingChild = Read-TelephoneOptionalOwnerRecord -Path $paths.command_child
    $process = $null
    $childStartedAt = $startedAt.ToString('o')
    if ($null -ne $existingChild -and (Test-TelephoneOwnerAlive -Owner $existingChild)) {
        $process = Get-Process -Id ([int]$existingChild.pid) -ErrorAction Stop
        $childStartedAt = [string]$existingChild.started_at_utc
    } else {
        $command = $dispatch.command
        $executable = Assert-TelephoneRegularFilePath -Path ([string]$command.executable) -Label 'Route executable'
        $workingDirectory = Assert-TelephoneDirectoryPath -Path ([string]$command.working_directory) -Label 'Route working directory'
        $arguments = @($command.arguments | ForEach-Object { [string]$_ })
        $stdinPath = $null
        if ($null -ne $command.stdin) {
            $actualStdin = Get-TelephoneFileIdentity -Path ([string]$command.stdin.path)
            Assert-TelephoneFileIdentity -Expected $command.stdin -Actual $actualStdin -Label 'Route stdin'
            $stdinPath = [string]$actualStdin.path
        }
        foreach ($streamPath in @($paths.stdout, $paths.stderr)) {
            if ([IO.File]::Exists($streamPath)) { [IO.File]::Delete($streamPath) }
        }
        $startParams = @{
            FilePath = $executable
            WorkingDirectory = $workingDirectory
            PassThru = $true
            NoNewWindow = $true
            RedirectStandardOutput = [string]$paths.stdout
            RedirectStandardError = [string]$paths.stderr
        }
        if ($arguments.Count -gt 0) { $startParams.ArgumentList = $arguments }
        if (-not [string]::IsNullOrWhiteSpace($stdinPath)) { $startParams.RedirectStandardInput = $stdinPath }
        $process = Start-Process @startParams
        if ($null -eq $process) { throw 'Route process did not start.' }
        $childOwner = [ordered]@{
            protocol_version = 'telephone-line-command-child-v1'
            pid = [int]$process.Id
            start_time_utc_ticks = [int64]$process.StartTime.ToUniversalTime().Ticks
            started_at_utc = $process.StartTime.ToUniversalTime().ToString('o')
            line_job_id = [string]$dispatch.line_job_id
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID)) {
            $childOwner.supervisor_run_id = [string]$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID
        }
        $childStartedAt = [string]$childOwner.started_at_utc
        try {
            $null = Write-TelephoneJsonCreateNew -Path $paths.command_child -Value $childOwner
        } catch [IO.IOException] {
            $written = (Read-TelephoneJson -Path $paths.command_child).value
            if ([int]$written.pid -ne [int]$childOwner.pid -or [int64]$written.start_time_utc_ticks -ne [int64]$childOwner.start_time_utc_ticks) {
                throw 'Another command child already owns this telephone-line job.'
            }
        }
    }
    try {
        $process.WaitForExit()
        $exitCode = [int]$process.ExitCode
        Write-TelephoneCommandChildExit -Paths $paths -Dispatch $dispatch -ExitCode $exitCode
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
    $startedAt = [DateTimeOffset]::Parse($childStartedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
} catch {
    $exitCode = 1
    $errorCode = 'COMMAND_HOST_ERROR'
    $errorMessage = Get-TelephonePublicErrorMessage -ErrorCode $errorCode
}

if (-not [IO.File]::Exists($paths.receipt)) {
    if ([string]::IsNullOrWhiteSpace($errorCode)) {
        $receipt = New-TelephoneCommandBoundReceipt -DispatchRead $dispatchRead -Paths $paths -ExitCode $exitCode -StartedAtUtc $startedAt.ToString('o') -TransportComplete $true
    } else {
        $receipt = New-TelephoneCommandBoundReceipt -DispatchRead $dispatchRead -Paths $paths -ExitCode $exitCode -ErrorCode $errorCode -ErrorMessage $errorMessage -StartedAtUtc $startedAt.ToString('o') -TransportComplete $true
    }
    try {
        $null = Write-TelephoneJsonCreateNew -Path $paths.receipt -Value $receipt
    } catch [IO.IOException] {
        # A restart-safe replay never overwrites an existing durable receipt.
    }
}
$null = Invoke-TelephoneControlPlaneLifecycleWake -Dispatch $dispatch -JobRoot $JobRoot -Reason 'receipt-published'

exit ([int]$exitCode)

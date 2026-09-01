# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest

if (-not (Get-Command Get-TelephoneFileIdentity -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '..\core\TelephoneLine.Common.ps1')
}

function Read-TelephoneAdapterDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AdapterRoot
    )

    $root = Assert-TelephoneDirectoryPath -Path $AdapterRoot -Label 'Adapter root'
    $resolved = Assert-TelephoneContainedRegularFile -Path $Path -Root $root -Label 'Adapter descriptor'
    $read = Read-TelephoneJson -Path $resolved -SchemaName 'adapter'
    $descriptor = $read.value
    $entrypoint = Assert-TelephoneContainedRegularFile -Path ([string]$descriptor.windows_entrypoint) -Root $root -Label 'Adapter entrypoint'
    if ($descriptor.capabilities.exact_native_session -isnot [bool]) {
        throw 'Adapter exact_native_session must be a boolean.'
    }
    return [ordered]@{
        identity = $read.identity
        descriptor = $descriptor
        adapter_root = $root
        entrypoint = $entrypoint
    }
}

function Assert-TelephoneNativeSessionId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Actual,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Expected) -or [string]::IsNullOrWhiteSpace($Actual)) {
        throw "$Label native session id is required."
    }
    if ($Expected -cne $Actual) {
        throw "$Label native session id does not match the frozen session."
    }
}

function New-TelephoneAdapterInvocation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Adapter,
        [Parameter(Mandatory = $true)][ValidateSet('start', 'follow_up', 'recover')][string]$Operation,
        [string]$NativeSessionId,
        [string[]]$ExtraArguments
    )

    $descriptor = $Adapter.descriptor
    if (-not $descriptor.capabilities.Contains($Operation) -or [bool]$descriptor.capabilities[$Operation] -ne $true) {
        throw "Adapter does not advertise the $Operation capability."
    }
    $session = [string]$NativeSessionId
    if ($Operation -eq 'start') {
        if (-not [string]::IsNullOrWhiteSpace($session)) {
            throw 'Adapter start must not reuse a native session id.'
        }
    } elseif ($Operation -eq 'follow_up') {
        if ([string]::IsNullOrWhiteSpace($session)) {
            throw 'Adapter follow_up requires the exact native session id.'
        }
        if ($session -cnotmatch '^[A-Za-z0-9._:-]+$') {
            throw 'Adapter native session id is malformed.'
        }
    } else {
        if ([string]::IsNullOrWhiteSpace($session)) {
            throw 'Adapter recover requires the durable transport session id.'
        }
        if ($session -cnotmatch '^[A-Za-z0-9._:-]+$') {
            throw 'Adapter native session id is malformed.'
        }
    }
    $arguments = [Collections.Generic.List[string]]::new()
    [void]$arguments.Add('-Operation')
    [void]$arguments.Add($Operation)
    if ($Operation -ne 'start') {
        [void]$arguments.Add('-NativeSessionId')
        [void]$arguments.Add($session)
    }
    foreach ($item in @($ExtraArguments)) {
        if ($null -ne $item) { [void]$arguments.Add([string]$item) }
    }
    return [ordered]@{
        protocol_version = 'telephone-line-adapter-invocation-v1'
        route_id = [string]$descriptor.route_id
        operation = $Operation
        native_session_id = if ($Operation -eq 'start') { $null } else { $session }
        executable = [string]$Adapter.entrypoint
        arguments = @($arguments)
        automatic_rerun = $false
        exact_native_session = [bool]$descriptor.capabilities.exact_native_session
    }
}

function Assert-TelephoneAdapterFollowUpSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$StartResult,
        [Parameter(Mandatory = $true)][object]$FollowUpInvocation
    )

    if ([string]$FollowUpInvocation.operation -cne 'follow_up') {
        throw 'Follow-up invocation operation is invalid.'
    }
    Assert-TelephoneNativeSessionId -Expected ([string]$StartResult.native_session_id) -Actual ([string]$FollowUpInvocation.native_session_id) -Label 'Follow-up'
    if ([string]$FollowUpInvocation.route_id -cne [string]$StartResult.route_id) {
        throw 'Follow-up route id does not match the start result.'
    }
}

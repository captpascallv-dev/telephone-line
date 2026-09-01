# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest

$script:TelephoneDashboardPhases = @('idle', 'lead', 'execute', 'review', 'sync', 'modify', 'closure', 'closed')
$script:TelephoneDashboardForward = @{
    idle = @('lead')
    lead = @('execute')
    execute = @('review', 'sync', 'closure')
    review = @('sync', 'modify', 'closure')
    sync = @('review', 'modify', 'closure')
    modify = @('review', 'sync', 'closure')
    closure = @('closed')
    closed = @()
}
$script:TelephoneDashboardKindTarget = @{
    lead = 'lead'
    execute = 'execute'
    review = 'review'
    sync = 'sync'
    modify = 'modify'
    closure = 'closure'
    commit_closure = 'closed'
}

function New-TelephoneDashboardReducerState {
    [CmdletBinding()]
    param()
    return [ordered]@{
        phase = 'idle'
        lead_id = ''
        session_id = ''
        job_id = ''
        dashboard_visible = $false
        dashboard_disappeared = $false
        closure_receipt = ''
        restart_count = 0
        applied = 0
        rejected = [string[]]@()
        history = [string[]]@()
        duplicate_count = 0
        last_provenance = ''
    }
}

function New-TelephoneDashboardReducerEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [AllowEmptyString()][string]$LeadId = '',
        [AllowEmptyString()][string]$SessionId = '',
        [AllowEmptyString()][string]$JobId = '',
        [string]$Receipt = '',
        [string]$Provenance = '',
        [switch]$Ambiguous
    )
    return [ordered]@{
        kind = [string]$Kind
        lead_id = [string]$LeadId
        session_id = [string]$SessionId
        job_id = [string]$JobId
        receipt = [string]$Receipt
        provenance = [string]$Provenance
        ambiguous = [bool]$Ambiguous
    }
}

function Copy-TelephoneDashboardReducerState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$State)
    return [ordered]@{
        phase = [string]$State.phase
        lead_id = [string]$State.lead_id
        session_id = [string]$State.session_id
        job_id = [string]$State.job_id
        dashboard_visible = [bool]$State.dashboard_visible
        dashboard_disappeared = [bool]$State.dashboard_disappeared
        closure_receipt = [string]$State.closure_receipt
        restart_count = [int]$State.restart_count
        applied = [int]$State.applied
        rejected = @($State.rejected | ForEach-Object { [string]$_ })
        history = @($State.history | ForEach-Object { [string]$_ })
        duplicate_count = [int]$State.duplicate_count
        last_provenance = $(if ($State.Contains('last_provenance')) { [string]$State.last_provenance } else { '' })
    }
}

function Add-TelephoneDashboardRejected {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$State,
        [Parameter(Mandatory = $true)][string]$Code
    )
    $copy = Copy-TelephoneDashboardReducerState -State $State
    $copy.rejected = @($copy.rejected + @($Code))
    return $copy
}

function Test-TelephoneDashboardReducerBind {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$State,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Event
    )
    $kind = [string]$Event.kind
    if ($kind -cin @('live_callback', 'real_callback', 'telephone_callback', 'take_active')) {
        return 'LIVE_CALLBACK_FORBIDDEN'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Event.lead_id) -or [string]::IsNullOrWhiteSpace([string]$Event.session_id) -or [string]::IsNullOrWhiteSpace([string]$Event.job_id)) {
        return 'IDENTITY_INCOMPLETE'
    }
    if ([string]$State.phase -ceq 'idle') { return '' }
    if ([string]$Event.lead_id -cne [string]$State.lead_id) { return 'WRONG_LEAD' }
    if ([string]$Event.session_id -cne [string]$State.session_id) { return 'WRONG_SESSION' }
    if ([string]$Event.job_id -cne [string]$State.job_id) { return 'WRONG_JOB' }
    return ''
}

function Reduce-TelephoneDashboardEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$State,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Event
    )

    $reject = Test-TelephoneDashboardReducerBind -State $State -Event $Event
    if (-not [string]::IsNullOrWhiteSpace($reject)) {
        return (Add-TelephoneDashboardRejected -State $State -Code $reject)
    }

    $kind = [string]$Event.kind
    if ($kind -ceq 'restart') {
        $copy = Copy-TelephoneDashboardReducerState -State $State
        $closed = ([string]$State.phase -ceq 'closed')
        $copy.dashboard_visible = -not $closed
        $copy.dashboard_disappeared = $closed
        $copy.restart_count = [int]$State.restart_count + 1
        $copy.applied = [int]$State.applied + 1
        $copy.history = @($copy.history + @('restart'))
        return $copy
    }

    if ($kind -cin @('duplicate', 'duplicate_callback')) {
        $copy = Copy-TelephoneDashboardReducerState -State $State
        $copy.applied = [int]$State.applied + 1
        $copy.duplicate_count = [int]$State.duplicate_count + 1
        $copy.history = @($copy.history + @('duplicate'))
        $incoming = [string]$Event.provenance
        $stored = [string]$copy.last_provenance
        $flagged = ($Event.Contains('ambiguous') -and [bool]$Event['ambiguous'])
        $different = (-not [string]::IsNullOrWhiteSpace($incoming) -and -not [string]::IsNullOrWhiteSpace($stored) -and $incoming -cne $stored)
        $unverifiable = [string]::IsNullOrWhiteSpace($incoming) -and -not [string]::IsNullOrWhiteSpace($stored)
        if ($flagged -or $unverifiable -or $different) {
            $copy.rejected = @($copy.rejected + @('DUPLICATE_AMBIGUOUS'))
        } elseif (-not [string]::IsNullOrWhiteSpace($incoming) -and [string]::IsNullOrWhiteSpace($stored)) {
            $copy.last_provenance = $incoming
        }
        return $copy
    }

    if (-not $script:TelephoneDashboardKindTarget.ContainsKey($kind)) {
        return (Add-TelephoneDashboardRejected -State $State -Code 'UNKNOWN_EVENT')
    }
    $target = [string]$script:TelephoneDashboardKindTarget[$kind]
    $allowed = @($script:TelephoneDashboardForward[[string]$State.phase])
    if ($allowed -cnotcontains $target) {
        return (Add-TelephoneDashboardRejected -State $State -Code 'ILLEGAL_TRANSITION')
    }

    if ($kind -ceq 'lead') {
        $copy = New-TelephoneDashboardReducerState
        $copy.phase = 'lead'
        $copy.lead_id = [string]$Event.lead_id
        $copy.session_id = [string]$Event.session_id
        $copy.job_id = [string]$Event.job_id
        $copy.dashboard_visible = $true
        $copy.dashboard_disappeared = $false
        $copy.restart_count = [int]$State.restart_count
        $copy.applied = [int]$State.applied + 1
        $copy.rejected = @($State.rejected | ForEach-Object { [string]$_ })
        $copy.history = @($State.history + @('lead'))
        $copy.duplicate_count = [int]$State.duplicate_count
        if (-not [string]::IsNullOrWhiteSpace([string]$Event.provenance)) {
            $copy.last_provenance = [string]$Event.provenance
        } else {
            $copy.last_provenance = [string]$State.last_provenance
        }
        return $copy
    }

    if ($kind -ceq 'commit_closure') {
        $receipt = [string]$Event.receipt
        if ([string]::IsNullOrWhiteSpace($receipt)) {
            return (Add-TelephoneDashboardRejected -State $State -Code 'CLOSURE_RECEIPT_MISSING')
        }
        $copy = Copy-TelephoneDashboardReducerState -State $State
        $copy.phase = 'closed'
        $copy.dashboard_visible = $false
        $copy.dashboard_disappeared = $true
        $copy.closure_receipt = $receipt
        $copy.applied = [int]$State.applied + 1
        $copy.history = @($copy.history + @('commit_closure'))
        if (-not [string]::IsNullOrWhiteSpace([string]$Event.provenance)) {
            $copy.last_provenance = [string]$Event.provenance
        }
        return $copy
    }

    $copy = Copy-TelephoneDashboardReducerState -State $State
    $copy.phase = $target
    $copy.dashboard_visible = $true
    $copy.dashboard_disappeared = $false
    $copy.applied = [int]$State.applied + 1
    $copy.history = @($copy.history + @($kind))
    if (-not [string]::IsNullOrWhiteSpace([string]$Event.provenance)) {
        $copy.last_provenance = [string]$Event.provenance
    }
    return $copy
}

function Reduce-TelephoneDashboardEvents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Events,
        [Collections.IDictionary]$Start
    )
    $state = if ($null -eq $Start) { New-TelephoneDashboardReducerState } else { Copy-TelephoneDashboardReducerState -State $Start }
    foreach ($event in @($Events)) {
        $state = Reduce-TelephoneDashboardEvent -State $state -Event $event
    }
    return $state
}

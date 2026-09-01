# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [ValidateSet('Console', 'Emergency')][string]$Mode = 'Console',
    [ValidateSet('status', 'cancel-one', 'pause', 'emergency-stop-all', 'resume')][string]$Action,
    [string]$RunId,
    [switch]$Confirm,
    [string]$StateRoot,
    [string]$InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$controlScript = Join-Path $PSScriptRoot 'Invoke-TelephoneSupervisorControl.ps1'

function Invoke-TelephoneSupervisorControlAction {
    param(
        [Parameter(Mandatory = $true)][string]$ChosenAction,
        [string]$ChosenRunId,
        [switch]$ChosenConfirm
    )
    $arguments = [Collections.Generic.List[string]]::new()
    [void]$arguments.Add('-Action')
    [void]$arguments.Add($ChosenAction)
    if (-not [string]::IsNullOrWhiteSpace($ChosenRunId)) {
        [void]$arguments.Add('-RunId')
        [void]$arguments.Add($ChosenRunId)
    }
    if ($ChosenConfirm) { [void]$arguments.Add('-Confirm') }
    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        [void]$arguments.Add('-StateRoot')
        [void]$arguments.Add($StateRoot)
    }
    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        [void]$arguments.Add('-InstallRoot')
        [void]$arguments.Add($InstallRoot)
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $controlScript) + @($arguments)) {
        [void]$info.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [ordered]@{ exit_code = [int]$process.ExitCode; stdout = [string]$stdout; stderr = [string]$stderr }
    } finally {
        $process.Dispose()
    }
}

if (-not [string]::IsNullOrWhiteSpace($Action) -or [string]$env:TELEPHONE_LINE_SUPERVISOR_HEADLESS -match '^(?i:1|true|yes|on)$') {
    $chosen = if (-not [string]::IsNullOrWhiteSpace($Action)) { $Action } else { 'status' }
    $result = Invoke-TelephoneSupervisorControlAction -ChosenAction $chosen -ChosenRunId $RunId -ChosenConfirm:$Confirm
    Write-Output $result.stdout.TrimEnd()
    exit [int]$result.exit_code
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object System.Windows.Forms.Form
$form.Text = $(if ($Mode -ceq 'Emergency') { '有线电话｜紧急停止' } else { '有线电话｜控制台' })
$form.Width = 560
$form.Height = 460
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$label = New-Object System.Windows.Forms.Label
$label.Left = 16
$label.Top = 16
$label.Width = 520
$label.Height = 90
$label.Text = 'Loading status...'
$form.Controls.Add($label)
$list = New-Object System.Windows.Forms.ListBox
$list.Left = 16
$list.Top = 110
$list.Width = 520
$list.Height = 120
$form.Controls.Add($list)

function Refresh-TelephoneSupervisorUi {
    $statusResult = Invoke-TelephoneSupervisorControlAction -ChosenAction 'status'
    $text = [string]$statusResult.stdout
    try {
        $parsed = $text | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
        $status = $parsed.status
        $names = @($status.active_runs | ForEach-Object { [string]$_.name })
        $label.Text = ('Active wired runs: {0}`r`n{1}`r`nPaused by Pascal: {2}' -f @($status.active_runs).Count, ([string]::Join("`r`n", $names)), [bool]$status.paused_by_pascal)
        $list.Items.Clear()
        foreach ($run in @($status.active_runs)) {
            $row = ('{0}  {1}' -f [string]$run.run_id, $(if ($run.Contains('name')) { [string]$run.name } else { [string]$run.project }))
            [void]$list.Items.Add($row)
        }
    } catch {
        $label.Text = $text
    }
}

if ($Mode -ceq 'Emergency') {
    $confirmButton = New-Object System.Windows.Forms.Button
    $confirmButton.Text = '确认紧急停止全部'
    $confirmButton.Left = 16
    $confirmButton.Top = 250
    $confirmButton.Width = 220
    $confirmButton.Add_Click({
        $null = Invoke-TelephoneSupervisorControlAction -ChosenAction 'emergency-stop-all' -ChosenConfirm
        Refresh-TelephoneSupervisorUi
    })
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = '取消'
    $cancelButton.Left = 250
    $cancelButton.Top = 250
    $cancelButton.Width = 120
    $cancelButton.Add_Click({ $form.Close() })
    $form.Controls.Add($confirmButton)
    $form.Controls.Add($cancelButton)
} else {
    $y = 250
    foreach ($row in @(
        @{ text = '刷新状态'; action = 'status' },
        @{ text = '停止所选任务'; action = 'cancel-one' },
        @{ text = '暂停接单'; action = 'pause' },
        @{ text = '恢复接单'; action = 'resume' },
        @{ text = '紧急停止全部'; action = 'emergency-stop-all'; confirm = $true }
    )) {
        $button = New-Object System.Windows.Forms.Button
        $button.Text = [string]$row.text
        $button.Left = 16
        $button.Top = $y
        $button.Width = 180
        $captured = $row
        $button.Add_Click({
            $useConfirm = [bool]$captured.confirm
            $chosenRun = ''
            if ([string]$captured.action -ceq 'cancel-one') {
                if ($list.SelectedIndex -lt 0 -or $null -eq $list.SelectedItem) { return }
                $chosenRun = ([string]$list.SelectedItem).Split(' ', 2)[0]
                if ([string]::IsNullOrWhiteSpace($chosenRun)) { return }
            }
            $null = Invoke-TelephoneSupervisorControlAction -ChosenAction ([string]$captured.action) -ChosenRunId $chosenRun -ChosenConfirm:$useConfirm
            Refresh-TelephoneSupervisorUi
        })
        $form.Controls.Add($button)
        $y += 28
    }
}
Refresh-TelephoneSupervisorUi
[void]$form.ShowDialog()

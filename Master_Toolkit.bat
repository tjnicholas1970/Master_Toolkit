<# :
@echo off
color 0B
title IT Toolkit - console output (leave open)
echo ===================================================
echo   Loading Enterprise IT Master Toolkit v4.1...
echo   Bypassing Execution Policy Silently...
echo ===================================================
echo.
REM Original USB/folder path (for Autopilot CSV save hints)
set "USB_PATH=%~dp0"
REM On-disk path of this .bat (needed because Invoke-Expression clears MyInvocation path)
set "TOOLKIT_SCRIPT=%~f0"

REM -Encoding UTF8 avoids Windows PowerShell 5.1 mangling the script on non-ASCII systems
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([String]::Join([Environment]::NewLine, (Get-Content -LiteralPath '%~f0' -Encoding UTF8)))"

goto :eof
#>

# =====================================================================
# ================= POWERSHELL SCRIPT BEGINS HERE =====================
# =====================================================================

# ELEVATION CHECK (auto-relaunch elevated instead of just quitting)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $selfBat = $env:TOOLKIT_SCRIPT
    if ($selfBat -and (Test-Path -LiteralPath $selfBat)) {
        Write-Host "Not elevated - requesting Administrator rights (UAC)..." -ForegroundColor Yellow
        try {
            Start-Process -FilePath $selfBat -Verb RunAs -ErrorAction Stop
            return
        } catch {
            Write-Warning "Elevation was canceled or failed: $($_.Exception.Message)"
        }
    }
    Write-Warning "This toolkit requires Administrator privileges!"
    Read-Host "Press Enter to exit..."
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
try { $Host.UI.RawUI.WindowTitle = 'IT Toolkit - console output (leave open)' } catch { }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# =====================================================================
# TEMP STAGING (single .bat, USB can be removed, PC left clean when done)
# =====================================================================
# Runtime lives under ProgramData\IT-Toolkit-temp ONLY while the toolkit is
# active (or waiting for an update reboot). Closing the app cleans it up.
$Script:StageRoot = Join-Path $env:ProgramData 'IT-Toolkit-temp'
$Script:StagedScript = Join-Path $Script:StageRoot 'Master_Toolkit.bat'
$Script:StateFile = Join-Path $Script:StageRoot 'state.txt'
$Script:OriginUsbFile = Join-Path $Script:StageRoot 'origin_usb.txt'
$Script:LegacyStateFile = 'C:\IT_Provisioning_State.txt'
$Script:LegacyScriptCopy = 'C:\ProgramData\IT-Master-Toolkit.bat'
$Script:LegacyLogDir = 'C:\ProgramData\IT-Toolkit'
$Script:RebootPending = $false
$Script:ResumeTaskName = 'IT-Toolkit-Resume'
$Script:MaxUpdatePasses = 5
$Script:UpdateRebootNeeded = $false
$Script:BusyDepth = 0
$Script:LogBox = $null
$Script:GuiLogLines = New-Object System.Collections.Generic.List[string]
$Script:GuiLogEntries = New-Object System.Collections.Generic.List[object]
$Script:ActionHistory = New-Object System.Collections.Generic.List[object]
$Script:SessionStart = Get-Date
$Script:HealthBaseline = $null
$Script:Settings = $null
$Script:SettingsStatus = ''
$Script:SettingsFileName = 'Master_Toolkit_Settings.json'
$Script:SessionFile = Join-Path $Script:StageRoot 'session.xml'

function Get-ITToolkitSourcePath {
    foreach ($candidate in @($env:TOOLKIT_SCRIPT, $PSCommandPath, $MyInvocation.MyCommand.Path)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Clear-ITToolkitTempArtifacts {
    # Remove toolkit temp files so the PC stays clean for the next user.
    try {
        $runOnceKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
        Remove-ItemProperty -Path $runOnceKey -Name 'ITProvisioningResume' -ErrorAction SilentlyContinue
    } catch { }
    try {
        Unregister-ScheduledTask -TaskName $Script:ResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
    } catch { }

    foreach ($path in @(
            $Script:StateFile,
            $Script:OriginUsbFile,
            $Script:LegacyStateFile,
            $Script:LegacyScriptCopy,
            $Script:StagedScript
        )) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -LiteralPath $Script:StageRoot) {
        Remove-Item -LiteralPath $Script:StageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Clean older releases that wrote permanent logs under ProgramData\IT-Toolkit
    if (Test-Path -LiteralPath $Script:LegacyLogDir) {
        Remove-Item -LiteralPath $Script:LegacyLogDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-ITToolkitStaging {
    $source = Get-ITToolkitSourcePath
    $runningFromStage = $false
    if ($source -and $source.StartsWith($Script:StageRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $runningFromStage = $true
    }
    if ($env:IT_TOOLKIT_STAGED -eq '1') { $runningFromStage = $true }

    # Resume after reboot: already staged / RunOnce launched the local copy.
    if ((Test-Path -LiteralPath $Script:StateFile) -or (Test-Path -LiteralPath $Script:LegacyStateFile)) {
        return $true
    }

    if ($runningFromStage) { return $true }
    if ([string]::IsNullOrWhiteSpace($source)) { return $true }

    try {
        if (-not (Test-Path -LiteralPath $Script:StageRoot)) {
            New-Item -ItemType Directory -Path $Script:StageRoot -Force | Out-Null
        }
        Copy-Item -LiteralPath $source -Destination $Script:StagedScript -Force
        # Bring the settings file along so it still works after the USB is pulled
        $srcSettings = Join-Path (Split-Path -Parent $source) $Script:SettingsFileName
        if (Test-Path -LiteralPath $srcSettings) {
            Copy-Item -LiteralPath $srcSettings -Destination (Join-Path $Script:StageRoot $Script:SettingsFileName) -Force
        }

        $originUsb = $null
        if ($env:USB_PATH) { $originUsb = $env:USB_PATH.TrimEnd('\') }
        if ([string]::IsNullOrWhiteSpace($originUsb)) { $originUsb = Split-Path -Parent $source }
        Set-Content -LiteralPath $Script:OriginUsbFile -Value $originUsb -Encoding ASCII

        # Relaunch the local copy so the USB can be removed safely.
        $cmd = "set `"IT_TOOLKIT_STAGED=1`" && set `"TOOLKIT_SCRIPT=$($Script:StagedScript)`" && set `"USB_PATH=$originUsb`" && `"$($Script:StagedScript)`""
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -WindowStyle Normal
        return $false
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not create a temporary local copy. Keep the USB plugged in for this session.`r`n`r`n$($_.Exception.Message)",
            "IT Toolkit",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return $true
    }
}

# Stage to local disk (and exit this USB-launched instance) before showing UI.
if (-not (Initialize-ITToolkitStaging)) {
    return
}

# =====================================================================
# GLOBAL VARIABLES & STATE TRACKING
# =====================================================================
$StateFile = $Script:StateFile
$LocalScriptCopy = $Script:StagedScript

$Script:IsResume = (Test-Path -LiteralPath $Script:StateFile) -or (Test-Path -LiteralPath $Script:LegacyStateFile)

if ($Script:IsResume) {
    if (Test-Path -LiteralPath $Script:StateFile) {
        $Script:UsbPath = Get-Content -LiteralPath $Script:StateFile -ErrorAction SilentlyContinue | Select-Object -First 1
    } elseif (Test-Path -LiteralPath $Script:LegacyStateFile) {
        $Script:UsbPath = Get-Content -LiteralPath $Script:LegacyStateFile -ErrorAction SilentlyContinue | Select-Object -First 1
    }
} else {
    if (Test-Path -LiteralPath $Script:OriginUsbFile) {
        $Script:UsbPath = Get-Content -LiteralPath $Script:OriginUsbFile -ErrorAction SilentlyContinue | Select-Object -First 1
    } elseif ($env:USB_PATH) {
        $Script:UsbPath = $env:USB_PATH.TrimEnd('\')
    }
}
if ([string]::IsNullOrWhiteSpace($Script:UsbPath)) {
    $Script:UsbPath = [Environment]::GetFolderPath('Desktop')
}
# Line 3 of the state file records whether this resume loop started in OOBE
$Script:OobeMode = $false
$Script:RunningAsSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
if (Test-Path -LiteralPath $Script:StateFile) {
    $stLines = @(Get-Content -LiteralPath $Script:StateFile -ErrorAction SilentlyContinue)
    if ($stLines.Count -ge 3 -and ([string]$stLines[2]).Trim() -eq 'oobe') { $Script:OobeMode = $true }
}
# Reopened by the SYSTEM resume task on a normal (signed-in) desktop: run the update job only, UI locked.
$Script:LockedResume = ($Script:IsResume -and $Script:RunningAsSystem -and -not $Script:OobeMode)

function Write-GuiLog {
    param([string]$Message, [string]$Color = "White")
    # GUI-only logging by default (no permanent log files left on the PC).
    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] $Message"
    if (-not $Script:GuiLogLines) { $Script:GuiLogLines = New-Object System.Collections.Generic.List[string] }
    $Script:GuiLogLines.Add($line) | Out-Null
    if ($Script:GuiLogEntries) { $Script:GuiLogEntries.Add([pscustomobject]@{ Time = Get-Date; Message = $Message; Color = $Color }) | Out-Null }
    if ($Script:LogBox -and -not $Script:LogBox.IsDisposed) {
        $Script:LogBox.SelectionStart = $Script:LogBox.TextLength
        $Script:LogBox.SelectionLength = 0
        $Script:LogBox.SelectionColor = [System.Drawing.Color]::FromName($Color)
        $Script:LogBox.AppendText("$line`r`n")
        $Script:LogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

# ---------------------------------------------------------------------
# OWNED DIALOGS (v4.1)
# In OOBE the setup screen keeps pulling itself to the front. Prompts that had
# no owner could end up behind the always-on-top toolkit window, lose focus and
# get closed - which counted as Cancel. Every prompt now:
#   - is owned by the toolkit window and kept on top
#   - can only be closed with its own buttons (no X)
#   - reopens by itself if something closes it without a button click
#   - logs how it was closed
# ---------------------------------------------------------------------
function Get-ITToolkitDialogOwner {
    $o = Get-Variable -Name form -ValueOnly -ErrorAction SilentlyContinue
    if ($o -is [System.Windows.Forms.Form] -and -not $o.IsDisposed -and $o.Visible) { return $o }
    return $null
}

# Returns the DialogResult of the button clicked, or 'Unexpected' if the box kept getting closed without a click.
function Show-ITToolkitModal {
    param([System.Windows.Forms.Form]$Dialog, [string]$Name = 'Prompt', [int]$Reopens = 2)
    $owner = Get-ITToolkitDialogOwner
    $Dialog.ControlBox = $false
    $Dialog.TopMost = $true
    $Dialog.ShowInTaskbar = $false
    $Dialog.StartPosition = if ($owner) { 'CenterParent' } else { 'CenterScreen' }

    foreach ($c in $Dialog.Controls) {
        if ($c -is [System.Windows.Forms.Button] -and $c.DialogResult -ne [System.Windows.Forms.DialogResult]::None) {
            $c.Add_Click({ $Script:ModalClick = $this.DialogResult; $Script:ModalClickText = $this.Text })
        }
    }
    $Dialog.Add_FormClosing({ param($s, $e) $Script:ModalCloseReason = [string]$e.CloseReason })
    $Dialog.Add_Shown({ $this.Activate(); $this.BringToFront() })

    # Keep grabbing focus back while the box is open (OOBE steals it)
    $Script:ModalDialog = $Dialog
    $focusTimer = New-Object System.Windows.Forms.Timer
    $focusTimer.Interval = 1500
    $focusTimer.Add_Tick({
        try {
            $d = $Script:ModalDialog
            if ($d -and $d.Visible -and [System.Windows.Forms.Form]::ActiveForm -ne $d) { $d.TopMost = $true; $d.Activate() }
        } catch { }
    })

    for ($attempt = 0; $attempt -le $Reopens; $attempt++) {
        $Script:ModalClick = $null
        $Script:ModalClickText = $null
        $Script:ModalCloseReason = $null
        $focusTimer.Start()
        try {
            if ($owner) { [void]$Dialog.ShowDialog($owner) } else { [void]$Dialog.ShowDialog() }
        } finally {
            $focusTimer.Stop()
        }
        if ($null -ne $Script:ModalClick) {
            Write-GuiLog ("{0}: '{1}' clicked." -f $Name, $Script:ModalClickText) "Gray"
            $focusTimer.Dispose()
            return $Script:ModalClick
        }
        $why = if ($Script:ModalCloseReason) { $Script:ModalCloseReason } else { 'unknown' }
        if ($attempt -lt $Reopens) {
            Write-GuiLog ("{0} was closed without a button click (reason: {1}) - reopening it." -f $Name, $why) "Yellow"
            # owner may have changed state (e.g. TopMost re-applied in OOBE)
            $owner = Get-ITToolkitDialogOwner
        } else {
            Write-GuiLog ("{0} kept closing without a button click (reason: {1})." -f $Name, $why) "Red"
        }
    }
    $focusTimer.Dispose()
    return 'Unexpected'
}

function New-ITToolkitDialogButton {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, $Result, [string]$Style = 'normal')
    $colors = @{
        primary = [System.Drawing.Color]::FromArgb(0, 120, 215)
        danger  = [System.Drawing.Color]::FromArgb(170, 35, 35)
        normal  = [System.Drawing.Color]::FromArgb(48, 48, 54)
    }
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, 32)
    $b.BackColor = $colors[$Style]
    $b.ForeColor = [System.Drawing.Color]::White
    $b.FlatStyle = 'Flat'
    $b.DialogResult = $Result
    $Parent.Controls.Add($b)
    return $b
}

# Yes/No box built on the owned modal. Returns 'Yes', 'No' or 'Unexpected'.
function Show-ITToolkitYesNo {
    param([string]$Title, [string]$Message, [string]$YesText = 'Yes', [string]$NoText = 'No')
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $f.Size = New-Object System.Drawing.Size(500, 300)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Message
    $lbl.ForeColor = [System.Drawing.Color]::White
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $lbl.Location = New-Object System.Drawing.Point(20, 15)
    $lbl.Size = New-Object System.Drawing.Size(450, 185)
    $f.Controls.Add($lbl)

    $yes = New-ITToolkitDialogButton $f $YesText 20 210 130 ([System.Windows.Forms.DialogResult]::Yes) 'primary'
    $no = New-ITToolkitDialogButton $f $NoText 340 210 130 ([System.Windows.Forms.DialogResult]::No)
    $f.AcceptButton = $yes
    $f.CancelButton = $no

    $r = Show-ITToolkitModal -Dialog $f -Name ("'{0}' box" -f $Title)
    $f.Dispose()
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { return 'Yes' }
    if ($r -eq [System.Windows.Forms.DialogResult]::No) { return 'No' }
    return 'Unexpected'
}

function Confirm-DestructiveAction {
    param(
        [string]$Title,
        [string]$Message
    )
    # Owned by the toolkit window so it can't get lost behind it (always-on-top in OOBE)
    $owner = Get-ITToolkitDialogOwner
    if ($owner) {
        $result = [System.Windows.Forms.MessageBox]::Show($owner, $Message, $Title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    } else {
        $result = [System.Windows.Forms.MessageBox]::Show($Message, $Title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    }
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Invoke-ITToolkitCleanupLeftovers {
    Clear-ITToolkitTempArtifacts
    Write-GuiLog "Toolkit temporary files cleaned up. PC is clear." "Lime"
}

# --- NON-BLOCKING GUI HANDLER ---
function Wait-GuiProcess {
    param(
        $Process,
        [string]$HeartbeatLabel = '',
        [int]$HeartbeatSeconds = 60
    )
    if (-not $Process) { return }
    # Touch Handle right away so ExitCode is still readable after the process exits.
    try { $null = $Process.Handle } catch { }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $nextBeat = $HeartbeatSeconds
    while (-not $Process.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
        if ($HeartbeatLabel -and $sw.Elapsed.TotalSeconds -ge $nextBeat) {
            Write-GuiLog ("{0}... (elapsed {1:hh\:mm\:ss})" -f $HeartbeatLabel, $sw.Elapsed) "Gray"
            $nextBeat += $HeartbeatSeconds
        }
    }
    try { $Process.WaitForExit() } catch { }
}

# --- BUSY GUARD: disables tool buttons while a task runs, logs any error ---
# Names shown in ticket notes when a task is started by something other than a button
$Script:ActionFriendlyNames = @{
    'Run-ProvisioningUpdates' = 'Windows/Dell updates (resumed after reboot)'
    'Run-OobeResume'          = 'OOBE Prep (resumed after restart)'
    'Run-VerifyAndFix'        = 'Verify Fully Patched'
}
# Housekeeping actions that should not show up in ticket notes
$Script:ActionsNotLogged = @('Show-ITToolkitTicketNotes', 'Run-HealthReport', 'Run-SaveGuiLog', 'Open-ITToolkitSettings', 'Import-ITToolkitSettings', 'Run-ReloadSettings')

function Get-ITToolkitActionInfo {
    param([scriptblock]$Action)
    $cmdNames = @()
    try {
        $cmdNames = @($Action.Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    } catch { }
    $label = $null
    try {
        # $this = the button that was clicked (set by PowerShell for WinForms event handlers)
        $sender = Get-Variable -Name this -ValueOnly -ErrorAction Stop
        if ($sender -is [System.Windows.Forms.ButtonBase] -and $sender.Text) { $label = $sender.Text }
    } catch { }
    if (-not $label -and $cmdNames.Count -gt 0) {
        $first = $cmdNames[0]
        if ($Script:ActionFriendlyNames.ContainsKey($first)) { $label = $Script:ActionFriendlyNames[$first] }
        else { $label = ($first -replace '^(Run|Show|Invoke|New|Open)-', '') }
    }
    if (-not $label) { $label = 'Toolkit action' }
    $skip = $false
    $excl = $false
    foreach ($c in $cmdNames) {
        if ($Script:ActionsNotLogged -contains $c) { $skip = $true }
        if ($Script:ExclusiveCommands -contains $c) { $excl = $true }
    }
    return [pscustomobject]@{ Label = $label; Skip = $skip; Exclusive = $excl }
}

# Long update-type jobs. Only one of these at a time - but while one runs, every OTHER tool stays usable.
$Script:ExclusiveCommands = @(
    'Run-MasterUpdateSequence', 'Run-ProvisioningUpdates', 'Run-OobePrep', 'Run-OobeResume', 'Run-VerifyAndFix',
    'Run-VerifyFullyPatched', 'Run-NewPcSetup', 'Run-MasterCleanup', 'Run-FastNukeSoftwareDistribution',
    'Run-Ghostbuster', 'Run-Recovery', 'Run-RestartNow', 'Run-WingetUpdateAll', 'Run-DellInfo',
    'Invoke-ITToolkitCleanupLeftovers', 'Run-ClearWinSxS'
)
$Script:ExclusiveLabel = $null
$Script:LightDepth = 0

function Invoke-ToolkitAction {
    param([scriptblock]$Action)
    $info = Get-ITToolkitActionInfo -Action $Action
    $exclusive = $info.Exclusive

    if ($exclusive -and $Script:ExclusiveLabel) {
        Write-GuiLog ("'{0}' has to wait - '{1}' is still running. Everything else can be used meanwhile." -f $info.Label, $Script:ExclusiveLabel) "Yellow"
        return
    }
    if (-not $exclusive -and $Script:LightDepth -gt 0) { return }

    $startIdx = $Script:GuiLogEntries.Count
    $t0 = Get-Date
    $Script:BusyDepth++
    if ($exclusive) {
        $Script:ExclusiveLabel = $info.Label
        $Script:CurrentActionLabel = $info.Label
    } else {
        $Script:LightDepth++
        try { if ($panelContainer) { $panelContainer.Enabled = $false } } catch { }
    }
    try { Set-ITToolkitBusyIndicator $true $info.Label } catch { }
    try {
        & $Action
    } catch {
        Write-GuiLog ("ERROR: {0}" -f $_.Exception.Message) "Red"
    } finally {
        $Script:BusyDepth--
        if ($Script:BusyDepth -lt 0) { $Script:BusyDepth = 0 }
        if ($exclusive) {
            $Script:ExclusiveLabel = $null
        } else {
            $Script:LightDepth--
            if ($Script:LightDepth -le 0) {
                $Script:LightDepth = 0
                if (-not $Script:LockedResume) {
                    try { if ($panelContainer -and -not $panelContainer.IsDisposed) { $panelContainer.Enabled = $true } } catch { }
                }
            }
        }
        try {
            if ($Script:ExclusiveLabel) { Set-ITToolkitBusyIndicator $true $Script:ExclusiveLabel }
            elseif ($Script:LightDepth -eq 0) { Set-ITToolkitBusyIndicator $false }
        } catch { }
        if (-not $info.Skip) {
            try { Add-ITToolkitActionHistory -Label $info.Label -Start $t0 -StartIndex $startIdx } catch { }
        }
        if ($Script:RebootPending) {
            try { Save-ITToolkitSessionState } catch { }
        }
    }
}

function Add-ITToolkitActionHistory {
    param([string]$Label, [datetime]$Start, [int]$StartIndex)
    $entries = @()
    for ($i = $StartIndex; $i -lt $Script:GuiLogEntries.Count; $i++) { $entries += $Script:GuiLogEntries[$i] }
    $canceled = @($entries | Where-Object { $_.Message -match '(?i)\bcancel(l)?ed\b' }).Count -gt 0
    $errors = @($entries | Where-Object { $_.Color -eq 'Red' }).Count
    $warns = @($entries | Where-Object { $_.Color -eq 'Yellow' }).Count
    $outcome = if ($canceled -and $entries.Count -le 2) { 'canceled' }
               elseif ($errors -gt 0) { 'completed with errors' }
               elseif ($warns -gt 0) { 'completed with warnings' }
               else { 'completed' }
    # Keep the meaningful result lines (successes, warnings, errors), not the chatter
    $notes = @($entries |
        Where-Object { $_.Color -in @('Lime', 'Green', 'Red', 'Yellow') -and $_.Message -notmatch '^\s*=+' -and $_.Message -notmatch '^(Tip:|Still working)' } |
        ForEach-Object { $m = ($_.Message -replace '\s+', ' ').Trim(); if ($m.Length -gt 160) { $m.Substring(0, 157) + '...' } else { $m } } |
        Select-Object -Unique)
    if ($notes.Count -gt 8) {
        $bad = @($notes | Where-Object { $_ -match '(?i)fail|error|denied|not found|skipp' })
        $notes = @($bad + @($notes | Where-Object { $bad -notcontains $_ }) | Select-Object -First 8)
    }
    $Script:ActionHistory.Add([pscustomobject]@{
        Time    = $Start
        Name    = $Label
        Outcome = $outcome
        Minutes = [math]::Round(((Get-Date) - $Start).TotalMinutes, 1)
        Notes   = $notes
    }) | Out-Null
}

# --- BACKGROUND RUNSPACE RUNNER ---
# Runs long blocking work (Windows Update COM calls) on a separate thread so
# the window never goes "Not Responding". The job logs through $Sync.Queue
# and reports its current step through $Sync.Phase.
function Invoke-ITToolkitBackgroundJob {
    param(
        [scriptblock]$ScriptBlock,
        [int]$HeartbeatSeconds = 30,
        [hashtable]$Data = @{}
    )
    $sync = [hashtable]::Synchronized(@{
        Queue  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        Phase  = 'Working'
        Result = $null
    })
    foreach ($k in $Data.Keys) { $sync[$k] = $Data[$k] }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $sync)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    # Pass as text so the block is parsed inside the new runspace.
    [void]$ps.AddScript($ScriptBlock.ToString())

    $drain = {
        $item = $null
        while ($sync.Queue.TryDequeue([ref]$item)) {
            Write-GuiLog ([string]$item.M) ([string]$item.C)
        }
    }

    $handle = $ps.BeginInvoke()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $nextBeat = $HeartbeatSeconds
    while (-not $handle.IsCompleted) {
        & $drain
        if ($sw.Elapsed.TotalSeconds -ge $nextBeat) {
            Write-GuiLog ("Still working: {0} (elapsed {1:hh\:mm\:ss})" -f $sync.Phase, $sw.Elapsed) "Gray"
            $nextBeat += $HeartbeatSeconds
        }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
    }
    try {
        [void]$ps.EndInvoke($handle)
    } catch {
        Write-GuiLog ("Background task error: {0}" -f $_.Exception.Message) "Red"
    }
    & $drain
    foreach ($err in $ps.Streams.Error) {
        Write-GuiLog ("Background task error: {0}" -f $err.ToString()) "Red"
    }
    $ps.Dispose()
    $rs.Close()
    $rs.Dispose()
    return $sync.Result
}

# --- RELIABLE RESTART ---
function Invoke-ITToolkitRestart {
    param([int]$DelaySeconds = 10)
    Write-GuiLog ("Restarting this PC in {0} seconds..." -f $DelaySeconds) "Yellow"
    try { [SystemSleep]::SetThreadExecutionState([SystemSleep]::ES_CONTINUOUS) | Out-Null } catch { }

    # 1) shutdown.exe - most reliable; works even when WMI is unhealthy.
    try {
        $shutdownExe = Join-Path $env:SystemRoot 'System32\shutdown.exe'
        $p = Start-Process -FilePath $shutdownExe -ArgumentList '/r', '/f', '/t', "$DelaySeconds", '/d', 'p:2:17', '/c', '"IT Toolkit: restarting to finish updates"' -WindowStyle Hidden -PassThru -Wait
        if ($p.ExitCode -eq 0) {
            Write-GuiLog "Restart scheduled. Save any open work now." "Lime"
            return $true
        }
        if ($p.ExitCode -eq 1190) {
            Write-GuiLog "A restart is already scheduled on this PC." "Yellow"
            return $true
        }
        Write-GuiLog ("shutdown.exe returned {0}; trying fallback..." -f $p.ExitCode) "Yellow"
    } catch {
        Write-GuiLog ("shutdown.exe failed: {0}; trying fallback..." -f $_.Exception.Message) "Yellow"
    }

    # 2) Restart-Computer
    try {
        Restart-Computer -Force -ErrorAction Stop
        Write-GuiLog "Restart command sent." "Lime"
        return $true
    } catch {
        Write-GuiLog ("Restart-Computer failed: {0}" -f $_.Exception.Message) "Yellow"
    }

    # 3) WMI Win32Shutdown (6 = forced reboot)
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $r = Invoke-CimMethod -InputObject $os -MethodName Win32Shutdown -Arguments @{ Flags = 6; Reserved = 0 } -ErrorAction Stop
        if ($r.ReturnValue -eq 0) {
            Write-GuiLog "Restart command sent (WMI)." "Lime"
            return $true
        }
        Write-GuiLog ("WMI restart returned {0}." -f $r.ReturnValue) "Yellow"
    } catch {
        Write-GuiLog ("WMI restart failed: {0}" -f $_.Exception.Message) "Yellow"
    }

    Write-GuiLog "Could not restart automatically. Please restart from the Start menu." "Red"
    return $false
}

function Show-ITToolkitRebootPrompt {
    param([string]$Message = "Updates need a reboot. A temporary local copy will finish the job after you sign back in, then clean itself up.")
    $rbForm = New-Object System.Windows.Forms.Form
    $rbForm.Text = "Pending Reboot"
    $rbForm.Size = New-Object System.Drawing.Size(460, 180)
    $rbForm.StartPosition = "CenterScreen"
    $rbForm.FormBorderStyle = 'FixedDialog'
    $rbForm.MaximizeBox = $false
    $rbForm.MinimizeBox = $false
    $rbForm.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $rbForm.TopMost = $true

    $lblRb = New-Object System.Windows.Forms.Label
    $lblRb.Text = $Message
    $lblRb.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $lblRb.ForeColor = [System.Drawing.Color]::White
    $lblRb.Location = New-Object System.Drawing.Point(20, 15)
    $lblRb.Size = New-Object System.Drawing.Size(410, 55)
    $rbForm.Controls.Add($lblRb)

    $btnNow = New-Object System.Windows.Forms.Button
    $btnNow.Text = "Restart Now"
    $btnNow.Location = New-Object System.Drawing.Point(20, 85)
    $btnNow.Size = New-Object System.Drawing.Size(110, 35)
    $btnNow.BackColor = [System.Drawing.Color]::FromArgb(204, 0, 0)
    $btnNow.ForeColor = [System.Drawing.Color]::White
    $btnNow.FlatStyle = 'Flat'
    $btnNow.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $rbForm.Controls.Add($btnNow)

    $btnLater = New-Object System.Windows.Forms.Button
    $btnLater.Text = "Restart Later"
    $btnLater.Location = New-Object System.Drawing.Point(310, 85)
    $btnLater.Size = New-Object System.Drawing.Size(110, 35)
    $btnLater.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $btnLater.ForeColor = [System.Drawing.Color]::White
    $btnLater.FlatStyle = 'Flat'
    $btnLater.DialogResult = [System.Windows.Forms.DialogResult]::No
    $rbForm.Controls.Add($btnLater)
    $rbForm.CancelButton = $btnLater

    $rbResult = $rbForm.ShowDialog()
    $rbForm.Dispose()
    if ($rbResult -eq [System.Windows.Forms.DialogResult]::Yes) {
        [void](Invoke-ITToolkitRestart -DelaySeconds 10)
    } else {
        Write-GuiLog "Restart postponed. Updates will finish after the next restart + sign-in." "Yellow"
    }
}

function Run-RestartNow {
    if (-not (Confirm-DestructiveAction -Title "Restart PC" -Message "Restart this PC now? Unsaved work in other apps will be lost.")) {
        Write-GuiLog "Restart canceled." "Yellow"
        return
    }
    [void](Invoke-ITToolkitRestart -DelaySeconds 10)
}

# --- REBOOT RESUME HOOKS ---
function Get-ITToolkitResumePass {
    foreach ($f in @($Script:StateFile, $Script:LegacyStateFile)) {
        if (Test-Path -LiteralPath $f) {
            $lines = @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)
            if ($lines.Count -ge 2) {
                $n = 0
                if ([int]::TryParse(([string]$lines[1]).Trim(), [ref]$n)) { return $n }
            }
            return 1
        }
    }
    return 0
}

function Clear-ITToolkitResumeHooks {
    try { Unregister-ScheduledTask -TaskName $Script:ResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    try { Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'ITProvisioningResume' -ErrorAction SilentlyContinue } catch { }
    foreach ($path in @($Script:StateFile, $Script:LegacyStateFile)) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
    $Script:RebootPending = $false
}

function Register-ITToolkitResume {
    param([int]$Pass)
    if (-not (Test-Path -LiteralPath $Script:StageRoot)) {
        New-Item -ItemType Directory -Path $Script:StageRoot -Force | Out-Null
    }
    $inOobe = Test-ITToolkitOobe
    $mode = if ($inOobe) { 'oobe' } else { 'normal' }
    Set-Content -LiteralPath $Script:StateFile -Value @($Script:UsbPath, "$Pass", $mode) -Encoding ASCII -Force

    $currentScript = Get-ITToolkitSourcePath
    if ($currentScript -and (Test-Path -LiteralPath $currentScript)) {
        if ($currentScript -ne $Script:StagedScript) {
            Copy-Item -LiteralPath $currentScript -Destination $Script:StagedScript -Force
        }
    }
    if (-not (Test-Path -LiteralPath $Script:StagedScript)) {
        Write-GuiLog "WARNING: Could not save a local copy for reboot resume. Re-run the toolkit manually after restart." "Yellow"
        return
    }

    $cmdArgs = '/c set "IT_TOOLKIT_STAGED=1" && set "TOOLKIT_SCRIPT={0}" && set "USB_PATH={1}" && "{0}"' -f $Script:StagedScript, $Script:UsbPath

    # Preferred: a SYSTEM startup task that waits for the OOBE screen / ANY user's desktop and puts the
    # toolkit on it. Doesn't care which account signs in (the old per-user task did - that's why it never came back).
    if (Register-ITToolkitSystemResume -CmdArgs $cmdArgs -Mode $mode) {
        $Script:RebootPending = $true
        return
    }
    Write-GuiLog "Falling back to the per-user sign-in resume (only fires for the account that ran the toolkit)." "Yellow"

    # Fallback: scheduled task with "Run with highest privileges" for this account.
    # (The old HKCU RunOnce launched without admin rights, so the resume always died.)
    try {
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\cmd.exe') -Argument $cmdArgs
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $trigger.Delay = 'PT15S'
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $Script:ResumeTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'ITProvisioningResume' -ErrorAction SilentlyContinue
        Write-GuiLog ("Auto-resume armed for {0} (pass {1} of {2})." -f $user, $Pass, $Script:MaxUpdatePasses) "Gray"
    } catch {
        # Fallback: RunOnce. The toolkit now self-elevates, so this gives a UAC prompt instead of failing.
        Write-GuiLog ("Scheduled-task resume failed ({0}); using RunOnce fallback (expect a UAC prompt after sign-in)." -f $_.Exception.Message) "Yellow"
        Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'ITProvisioningResume' -Value ("cmd.exe " + $cmdArgs) -Force
    }
    $Script:RebootPending = $true
}

# =====================================================================
# KERNEL KEEP-AWAKE (Global Init)
# =====================================================================
$KeepAwakeCode = 'using System;
using System.Runtime.InteropServices; public class SystemSleep { [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)] public static extern uint SetThreadExecutionState(uint esFlags);
public const uint ES_CONTINUOUS = 0x80000000; public const uint ES_SYSTEM_REQUIRED = 0x00000001; public const uint ES_DISPLAY_REQUIRED = 0x00000002;
}'
Add-Type -TypeDefinition $KeepAwakeCode -ErrorAction SilentlyContinue
[SystemSleep]::SetThreadExecutionState([SystemSleep]::ES_CONTINUOUS -bor [SystemSleep]::ES_SYSTEM_REQUIRED -bor [SystemSleep]::ES_DISPLAY_REQUIRED) | Out-Null

# =====================================================================
# TOOLKIT FUNCTIONS
# =====================================================================

# --- FAST NUKE (restored from 2.1, with confirmation) ---
function Run-FastNukeSoftwareDistribution {
    if (-not (Confirm-TypeYes -Title "Fast Nuke SoftwareDistribution" -Message "This permanently deletes C:\Windows\SoftwareDistribution and can reclaim 70GB+. Windows Update will rebuild the folder.")) {
        Write-GuiLog "Fast Nuke canceled by operator." "Yellow"
        return
    }

    Write-GuiLog "CRITICAL: Initiating Bare-Metal SoftwareDistribution Nuke..." "Red"
    Write-GuiLog "Halting core update engine locks..." "Yellow"

    $Services = @("wuauserv", "bits", "cryptSvc", "msiserver")
    foreach ($Service in $Services) {
        Stop-Service -Name $Service -Force -ErrorAction SilentlyContinue
    }
    [System.Windows.Forms.Application]::DoEvents()

    Write-GuiLog "Executing raw rmdir. Window may appear frozen briefly..." "Yellow"
    $cmdArgs = "/c rmdir /s /q `"C:\Windows\SoftwareDistribution`""
    $proc = Start-Process "cmd.exe" -ArgumentList $cmdArgs -NoNewWindow -PassThru
    Wait-GuiProcess -Process $proc

    if (-not (Test-Path "C:\Windows\SoftwareDistribution")) {
        New-Item -ItemType Directory -Path "C:\Windows\SoftwareDistribution" -Force | Out-Null
        Write-GuiLog "Success: SoftwareDistribution folder cleared and recreated." "Lime"
    } else {
        Write-GuiLog "Wipe completed with file locks remaining. Check active tasks." "Yellow"
    }

    Write-GuiLog "Restarting update services..." "Yellow"
    foreach ($Service in $Services) {
        Start-Service -Name $Service -ErrorAction SilentlyContinue
    }
    Write-GuiLog "Nuke process finalized." "Cyan"
}

# --- THE AUTOMATED MASTER CLEANER ---
function Run-MasterCleanup {
    Write-GuiLog "=============================================" "Cyan"
    Write-GuiLog "LAUNCHING AUTOMATED MASTER MAINTENANCE LOOP" "Cyan"
    Write-GuiLog "=============================================" "Cyan"
    
    # 1. Flush Delivery Optimization Peer Caches
    Run-FlushDOCache
    
    # 2. Clear Orphaned MSI Installer files
    Run-ClearOrphans
    
    # 3. Clear hidden baseline patch cache
    Run-ClearPatchCache
    
    # 4. DISM WinSxS Superseded Sweep
    Run-ClearWinSxS
    
    # 5. Compress Cache Directory (Asynchronous background)
    Run-InstallerCompression
    
    Write-GuiLog "=== AUTOMATED MASTER CLEANUP COMPLETED ===" "Lime"
}

# --- THE AUTOMATED MASTER UPDATER ---
function Run-MasterUpdateSequence {
    Write-GuiLog "=============================================" "Cyan"
    Write-GuiLog "LAUNCHING AUTOMATED MASTER UPDATE SEQUENCE" "Cyan"
    Write-GuiLog "=============================================" "Cyan"
    
    # 1. Windows OS + Dell hardware patching (reboot prompt held until the end)
    Run-ProvisioningUpdates -DeferRebootPrompt

    # 2. 3rd Party Application Winget update sweep (runs BEFORE any reboot now)
    Run-WingetUpdateAll

    Write-GuiLog "=== AUTOMATED MASTER UPDATE COMPLETED ===" "Lime"

    # 3. Reboot last, so nothing is cut off mid-install. Otherwise prove it's clean.
    if ($Script:UpdateRebootNeeded) {
        Show-ITToolkitRebootPrompt
    } else {
        [void](Invoke-ITToolkitFinishLine)
    }
}

# --- DELIVERY OPTIMIZATION PURGE FUNCTION ---
function Run-FlushDOCache {
    Write-GuiLog "Neutralizing Delivery Optimization Peer Caches..." "Yellow"
    # The cmdlet talks to DoSvc, so run it BEFORE stopping the service.
    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { }
    }
    Stop-Service -Name "DoSvc" -Force -ErrorAction SilentlyContinue
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $DOCache = "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
        if (Test-Path $DOCache) {
            Remove-Item -Path "$DOCache\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-GuiLog "Delivery Optimization network peer cache cleared." "Lime"
    } catch {
        Write-GuiLog "Failed to clear out DO cache components." "Red"
    }
    
    Start-Service -Name "DoSvc" -ErrorAction SilentlyContinue
}

# --- PROVISIONING & PATCHING ---
# Group Tag prompt. Returns @{ Result = 'OK' | 'Cancel' | 'Unexpected'; Tag = '...' }
function Show-ITToolkitGroupTagPrompt {
    param([string]$Default = '', [string]$Note = '')
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Assign Group Tag"
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $f.Size = New-Object System.Drawing.Size(420, $(if ($Note) { 250 } else { 190 }))

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Enter Group Tag (or leave blank):"
    $lbl.ForeColor = [System.Drawing.Color]::White
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $lbl.Location = New-Object System.Drawing.Point(20, 18)
    $lbl.AutoSize = $true
    $f.Controls.Add($lbl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(20, 48)
    $tb.Size = New-Object System.Drawing.Size(365, 25)
    $tb.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $tb.Text = $Default
    $f.Controls.Add($tb)

    $y = 92
    if ($Note) {
        $n = New-Object System.Windows.Forms.Label
        $n.Text = $Note
        $n.ForeColor = [System.Drawing.Color]::Gold
        $n.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $n.Location = New-Object System.Drawing.Point(20, 84)
        $n.Size = New-Object System.Drawing.Size(365, 55)
        $f.Controls.Add($n)
        $y = 148
    }
    $ok = New-ITToolkitDialogButton $f 'Continue' 255 $y 130 ([System.Windows.Forms.DialogResult]::OK) 'primary'
    $cancel = New-ITToolkitDialogButton $f 'Cancel' 20 $y 100 ([System.Windows.Forms.DialogResult]::Cancel)
    $f.AcceptButton = $ok      # Enter (or a barcode scanner's Enter) = Continue
    $f.CancelButton = $cancel  # Esc = Cancel
    $f.Add_Shown({ $tb.Focus(); $tb.SelectAll() })

    $r = Show-ITToolkitModal -Dialog $f -Name 'Group Tag box'
    $tag = $tb.Text.Trim()
    $f.Dispose()
    $res = if ($r -eq [System.Windows.Forms.DialogResult]::OK) { 'OK' } elseif ($r -eq [System.Windows.Forms.DialogResult]::Cancel) { 'Cancel' } else { 'Unexpected' }
    return [pscustomobject]@{ Result = $res; Tag = $tag }
}

function Get-ITToolkitCleanSerial {
    return ([string](Get-CimInstance Win32_BIOS).SerialNumber -replace '[,"]', '').Trim()
}

# Saves the row two ways:
#   <USB>\Autopilot\AP_<serial>.csv  - just this device (import this one)
#   <USB>\AutopilotDevices.csv       - running list, ONE row per serial (old row replaced, never duplicated)
function Save-ITToolkitAutopilotRow {
    param([string]$Serial, [string]$Hash, [string]$Tag)
    $header = 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag'
    $row = "{0},,{1},{2}" -f $Serial, $Hash, ($Tag -replace '[,"]', '')

    $devFile = Get-ITToolkitAutopilotDeviceCsvPath -Serial $Serial
    $devDir = Split-Path -Parent $devFile
    if (-not (Test-Path -LiteralPath $devDir)) { New-Item -ItemType Directory -Path $devDir -Force | Out-Null }
    Set-Content -LiteralPath $devFile -Value @($header, $row) -Encoding ASCII -ErrorAction Stop

    $all = Get-ITToolkitAutopilotCsvPath
    $keep = @()
    $replaced = $false
    if (Test-Path -LiteralPath $all) {
        foreach ($l in @(Get-Content -LiteralPath $all -ErrorAction SilentlyContinue)) {
            if (-not $l.Trim() -or $l -like 'Device Serial Number,*') { continue }
            if ((($l -split ',')[0]).Trim('"').Trim() -eq $Serial) { $replaced = $true; continue }
            $keep += $l
        }
    }
    Set-Content -LiteralPath $all -Value (@($header) + $keep + @($row)) -Encoding ASCII -ErrorAction Stop
    return [pscustomobject]@{ DeviceFile = $devFile; AllFile = $all; Replaced = $replaced }
}

# Run-AutopilotHash: asks for the tag (pre-filled with what's on file for this serial) unless -TagProvided.
# Result in $Script:LastHashResult: 'Saved', 'Cancel', 'Unexpected' or 'Failed'
function Run-AutopilotHash {
    param([string]$GroupTag = '', [switch]$TagProvided)
    $Script:LastHashResult = 'Failed'
    if (-not $TagProvided) {
        $existing = Get-ITToolkitSavedGroupTag
        $default = if ($null -ne $existing) { $existing } else { [string](Get-ITToolkitSetting -Name 'DefaultGroupTag' -Default '') }
        $note = if ($null -ne $existing) { "This serial is already saved with tag '$existing'. Continue replaces that entry (no duplicate rows)." } else { '' }
        $p = Show-ITToolkitGroupTagPrompt -Default $default -Note $note
        if ($p.Result -ne 'OK') {
            $Script:LastHashResult = $p.Result
            Write-GuiLog ("Hash extraction canceled ({0})." -f $(if ($p.Result -eq 'Cancel') { 'Cancel clicked' } else { 'box kept closing on its own' })) "Yellow"
            return
        }
        $GroupTag = $p.Tag
    }

    Write-GuiLog ("Starting Autopilot Hash Extraction (Group Tag: '{0}')..." -f $GroupTag) "Cyan"
    if (-not $Script:UsbPath -or -not (Test-Path -LiteralPath $Script:UsbPath)) {
        Write-GuiLog ("Original USB path not available. Saving CSV to {0} instead." -f (Split-Path -Parent (Get-ITToolkitAutopilotCsvPath))) "Yellow"
    }

    try {
        $serial = Get-ITToolkitCleanSerial
        if (-not $serial) { Write-GuiLog "ERROR: Could not read the serial number from the BIOS." "Red"; return }
        $filter = "InstanceID='Ext' and ParentID='./DevDetail'"
        $devDetail = Get-CimInstance -Namespace root/cimv2/mdm/dmmap -Class MDM_DevDetail_Ext01 -Filter $filter -ErrorAction Stop
        $hash = $devDetail.DeviceHardwareData

        if ([string]::IsNullOrWhiteSpace($hash)) {
            Write-GuiLog "ERROR: Hash extraction empty. TPM read fault." "Red"
            return
        }

        # Same unquoted layout as Microsoft's Get-WindowsAutopilotInfo (Intune import is picky about quotes).
        $saved = Save-ITToolkitAutopilotRow -Serial $serial -Hash $hash -Tag $GroupTag
        $Script:LastHashResult = 'Saved'
        Write-GuiLog ("Autopilot hash saved for {0} with Group Tag '{1}'." -f $serial, $GroupTag) "Lime"
        Write-GuiLog ("  Import this file in Intune: {0}" -f $saved.DeviceFile) "Lime"
        if ($saved.Replaced) { Write-GuiLog ("  Replaced this serial's old row in {0} (no duplicates)." -f $saved.AllFile) "Gray" }
        else { Write-GuiLog ("  Also added to the running list: {0}" -f $saved.AllFile) "Gray" }
        Write-GuiLog "  Note: if this device is ALREADY registered in Autopilot, importing won't change its tag - edit the tag on the device in Intune instead." "Gray"
    } catch {
        Write-GuiLog "ERROR: $_" "Red"
    }
}

# ---------------------------------------------------------------------
# WINDOWS UPDATE ENGINE (runs on a background thread - GUI stays live)
# ---------------------------------------------------------------------
$Script:WindowsUpdateJob = {
    function Log { param([string]$M, [string]$C = 'White') $Sync.Queue.Enqueue([pscustomobject]@{ M = $M; C = $C }) }
    function Set-Phase { param([string]$P) $Sync.Phase = $P }

    $result = @{ Found = 0; Installed = 0; Failed = 0; Skipped = 0; RebootRequired = $false; Error = $null }
    $Sync.Result = $result

    $MU = '7971f918-a847-4430-9279-4a52d1efe18d'          # Microsoft Update service
    $UpgradeCat = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'  # "Upgrades" (feature updates)
    $rcNames = @{ 0 = 'Not started'; 1 = 'In progress'; 2 = 'Succeeded'; 3 = 'Succeeded with errors'; 4 = 'Failed'; 5 = 'Aborted' }

    function Get-HResultHint {
        param([string]$Text)
        if ($Text -match '(?i)8024402C|80244022|8024401C|80072EE2|80072EFD|80072F8F') { return 'Network/proxy/firewall problem reaching Microsoft.' }
        if ($Text -match '(?i)8024002E|80240438') { return 'Policy blocks direct Windows Update access (WSUS/SCCM/Intune managed).' }
        if ($Text -match '(?i)80070422') { return 'Windows Update service is disabled.' }
        if ($Text -match '(?i)80240016') { return 'Another install is already running. Try again in a few minutes.' }
        if ($Text -match '(?i)80070070|80070661') { return 'Low disk space.' }
        return $null
    }

    try {
        Set-Phase 'Preparing Windows Update'
        $session = New-Object -ComObject Microsoft.Update.Session
        $session.ClientApplicationID = 'IT Toolkit'

        # Register Microsoft Update ONLY if missing (it was re-registered on every run before).
        $muReady = $false
        try {
            $sm = New-Object -ComObject Microsoft.Update.ServiceManager
            $sm.ClientApplicationID = 'IT Toolkit'
            foreach ($svc in $sm.Services) { if ($svc.ServiceID -eq $MU) { $muReady = $true; break } }
            if (-not $muReady) {
                Log 'Registering Microsoft Update (Office / other MS products) - one time...' 'Gray'
                [void]$sm.AddService2($MU, 7, '')
                $muReady = $true
            }
        } catch {
            Log ("Microsoft Update registration failed ({0}). Using Windows Update only." -f $_.Exception.Message) 'Yellow'
        }

        # Try sources in order: Microsoft Update -> Windows Update -> whatever this PC is configured for (WSUS etc.)
        $sources = @()
        if ($muReady) { $sources += @{ Name = 'Microsoft Update'; Sel = 3; Id = $MU } }
        $sources += @{ Name = 'Windows Update'; Sel = 2; Id = $null }
        $sources += @{ Name = 'default/managed source'; Sel = 0; Id = $null }

        # BrowseOnly=0 = only updates Windows would install on its own (skips optional/preview drivers & updates).
        $criteria = "IsInstalled=0 and IsHidden=0 and BrowseOnly=0"
        $search = $null
        foreach ($src in $sources) {
            $searcher = $session.CreateUpdateSearcher()
            $searcher.ServerSelection = $src.Sel
            if ($src.Id) { $searcher.ServiceID = $src.Id }
            Set-Phase ("Scanning {0}" -f $src.Name)
            Log ("Scanning {0} for updates (often 2-10 min on a stale PC)..." -f $src.Name) 'Yellow'
            try {
                $search = $searcher.Search($criteria)
                break
            } catch {
                $hint = Get-HResultHint $_.Exception.Message
                Log ("Scan via {0} failed: {1}" -f $src.Name, $_.Exception.Message) 'Yellow'
                if ($hint) { Log ("  Hint: {0}" -f $hint) 'Yellow' }
                $search = $null
            }
        }
        if (-not $search) {
            $result.Error = 'All update scan sources failed.'
            Log 'Windows Update scan failed on every source. See messages above.' 'Red'
            return
        }

        # Filter out the things that make update runs hang or take hours.
        $toGet = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $search.Updates) {
            $isUpgrade = $false
            foreach ($c in $u.Categories) { if ($c.CategoryID -eq $UpgradeCat) { $isUpgrade = $true; break } }
            if ($isUpgrade) {
                Log ("Skipped (feature upgrade - do via Settings/Intune): {0}" -f $u.Title) 'Gray'
                $result.Skipped++; continue
            }
            if ($u.InstallationBehavior.CanRequestUserInput) {
                Log ("Skipped (needs user interaction, would hang): {0}" -f $u.Title) 'Gray'
                $result.Skipped++; continue
            }
            if ($u.Title -match '(?i)\bPreview\b') {
                Log ("Skipped (preview): {0}" -f $u.Title) 'Gray'
                $result.Skipped++; continue
            }
            if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch { } }
            [void]$toGet.Add($u)
        }

        $result.Found = $toGet.Count
        if ($toGet.Count -eq 0) {
            Log 'No applicable Windows updates found.' 'Green'
            return
        }

        $totalMB = 0
        foreach ($u in $toGet) { $totalMB += [math]::Round($u.MaxDownloadSize / 1MB, 0) }
        Log ("Found {0} update(s) (up to ~{1:N0} MB):" -f $toGet.Count, $totalMB) 'Cyan'
        foreach ($u in $toGet) { Log (" - {0}" -f $u.Title) 'Gray' }
        if ($Sync.ScanOnly) { return }   # final-check mode: count only, install nothing

        # ---------- DOWNLOAD (one at a time so you can see progress) ----------
        $ready = New-Object -ComObject Microsoft.Update.UpdateColl
        $i = 0
        foreach ($u in $toGet) {
            $i++
            if ($u.IsDownloaded) {
                Log ("[{0}/{1}] Already downloaded: {2}" -f $i, $toGet.Count, $u.Title) 'Gray'
                [void]$ready.Add($u); continue
            }
            Set-Phase ("Downloading {0}/{1}: {2}" -f $i, $toGet.Count, $u.Title)
            Log ("[{0}/{1}] Downloading: {2}" -f $i, $toGet.Count, $u.Title) 'Yellow'
            $one = New-Object -ComObject Microsoft.Update.UpdateColl
            [void]$one.Add($u)
            $dl = $session.CreateUpdateDownloader()
            $dl.Updates = $one
            try {
                $dr = $dl.Download()
                $code = [int]$dr.GetUpdateResult(0).ResultCode
                if ($code -eq 2 -or $code -eq 3) {
                    [void]$ready.Add($u)
                } else {
                    $result.Failed++
                    Log ("Download {0} (0x{1:X8}): {2}" -f $rcNames[$code], $dr.GetUpdateResult(0).HResult, $u.Title) 'Red'
                }
            } catch {
                $result.Failed++
                Log ("Download error: {0} - {1}" -f $u.Title, $_.Exception.Message) 'Red'
                $hint = Get-HResultHint $_.Exception.Message
                if ($hint) { Log ("  Hint: {0}" -f $hint) 'Yellow' }
            }
        }

        if ($ready.Count -eq 0) {
            Log 'Nothing downloaded successfully, skipping install.' 'Red'
            return
        }

        # ---------- INSTALL (one batch = how Windows does it, much faster than one-by-one) ----------
        $installer = $session.CreateUpdateInstaller()
        $waited = 0
        while ($installer.IsBusy -and $waited -lt 1200) {
            if ($waited % 60 -eq 0) { Log 'Windows Update is busy with another install - waiting for it to finish...' 'Yellow' }
            Set-Phase 'Waiting for another Windows Update install to finish'
            Start-Sleep -Seconds 10
            $waited += 10
        }
        if ($installer.RebootRequiredBeforeInstallation) {
            Log 'Windows says a reboot is required BEFORE more updates can install.' 'Yellow'
            $result.RebootRequired = $true
            return
        }

        $installer.ForceQuiet = $true
        $installer.AllowSourcePrompts = $false
        $installer.Updates = $ready
        Set-Phase ("Installing {0} update(s) - cumulative updates can take 10-30 min" -f $ready.Count)
        Log ("Installing {0} update(s). Cumulative updates can take 10-30 minutes; this is normal." -f $ready.Count) 'Cyan'

        $ir = $installer.Install()
        for ($j = 0; $j -lt $ready.Count; $j++) {
            $ur = $ir.GetUpdateResult($j)
            $title = $ready.Item($j).Title
            $code = [int]$ur.ResultCode
            if ($code -eq 2 -or $code -eq 3) {
                $result.Installed++
                Log ("Installed: {0}" -f $title) 'Lime'
            } else {
                $result.Failed++
                Log ("FAILED ({0}, 0x{1:X8}): {2}" -f $rcNames[$code], $ur.HResult, $title) 'Red'
            }
            if ($ur.RebootRequired) { $result.RebootRequired = $true }
        }
        if ($ir.RebootRequired) { $result.RebootRequired = $true }
    } catch {
        $result.Error = $_.Exception.Message
        Log ("Windows Update error: {0}" -f $_.Exception.Message) 'Red'
        $hint = Get-HResultHint $_.Exception.Message
        if ($hint) { Log ("  Hint: {0}" -f $hint) 'Yellow' }
    }
}

function Invoke-ITToolkitWindowsUpdatePass {
    $Script:WUPassResult = $null
    $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-GuiLog "Windows Update service (wuauserv) not found. Skipping Windows Update." "Red"
        return
    }
    if ($svc.StartType -eq 'Disabled') {
        Write-GuiLog "Windows Update service is DISABLED on this PC (often by policy). Skipping Windows Update." "Red"
        Write-GuiLog "  To allow it: Set-Service wuauserv -StartupType Manual (check policy first)." "Gray"
        return
    }
    $Script:WUPassResult = Invoke-ITToolkitBackgroundJob -ScriptBlock $Script:WindowsUpdateJob -HeartbeatSeconds 30
}

$Script:DcuExitText = @{
    0   = 'Updates applied'
    1   = 'Updates applied - restart required'
    2   = 'Fatal error inside Dell Command | Update'
    3   = 'Dell Command | Update reported an error'
    4   = 'Invalid system - not a Dell, or DCU was not run as admin'
    5   = 'Updates applied - restart and rescan required'
    6   = 'Another Dell Command | Update instance is already running'
    7   = 'This model is not supported by Dell Command | Update'
    8   = 'No update filters applied (check DCU settings / Intune policy)'
    107 = 'DCU rejected an option value (see DCU message)'
    3000 = 'Dell Client Management Service is not running'
    3001 = 'Dell Client Management Service is not installed'
    3002 = 'Dell Client Management Service is disabled'
    3003 = 'Dell Client Management Service is busy'
    3004 = 'Dell Command | Update is updating itself'
    3005 = 'Dell service is installing previously queued updates'
    500 = 'No updates found - Dell components are current'
    501 = 'No applicable updates found'
}

function Get-ITToolkitDcuPath {
    @("$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe", "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe") |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

function Test-ITToolkitIsDell {
    try { return ((Get-CimInstance Win32_ComputerSystem).Manufacturer -match 'Dell') } catch { return $false }
}

# Installs DCU (and its .NET 8 prerequisite) silently from <USB>\Dell if DCU is missing.
function Install-ITToolkitDcuFromUsb {
    $dir = $null
    foreach ($root in @($Script:UsbPath, $Script:StageRoot)) {
        if ($root) {
            $d = Join-Path $root 'Dell'
            if (Test-Path -LiteralPath $d) { $dir = $d; break }
        }
    }
    if (-not $dir) { return $false }

    $net = Get-ChildItem -LiteralPath $dir -Filter 'windowsdesktop-runtime-8*x64*.exe' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    $netInstalled = Test-Path "$env:ProgramFiles\dotnet\shared\Microsoft.WindowsDesktop.App\8.*"
    if ($net -and -not $netInstalled) {
        Write-GuiLog ("Installing .NET 8 Desktop Runtime from USB ({0})..." -f $net.Name) "Yellow"
        $p = Start-Process -FilePath $net.FullName -ArgumentList '/install', '/quiet', '/norestart' -PassThru
        Wait-GuiProcess -Process $p -HeartbeatLabel 'Installing .NET 8'
        if ($p.ExitCode -in 0, 3010, 1638) { Write-GuiLog ".NET 8 Desktop Runtime installed." "Lime" }
        else { Write-GuiLog (".NET 8 install returned {0}." -f $p.ExitCode) "Yellow" }
    }

    $inst = Get-ChildItem -LiteralPath $dir -Filter '*Command*Update*.exe' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $inst) {
        Write-GuiLog ("No Dell Command | Update installer found in {0}." -f $dir) "Yellow"
        return $false
    }
    Write-GuiLog ("Installing Dell Command | Update from USB ({0})..." -f $inst.Name) "Yellow"
    $p = Start-Process -FilePath $inst.FullName -ArgumentList '/s' -PassThru
    Wait-GuiProcess -Process $p -HeartbeatLabel 'Installing Dell Command | Update'
    for ($i = 0; $i -lt 30 -and -not (Get-ITToolkitDcuPath); $i++) { Start-Sleep -Seconds 2; [System.Windows.Forms.Application]::DoEvents() }
    if (Get-ITToolkitDcuPath) {
        Write-GuiLog "Dell Command | Update installed." "Lime"
        return $true
    }
    Write-GuiLog ("Dell Command | Update install did not complete (exit {0}). DCU 5.x needs the .NET 8 Desktop Runtime in the same USB folder." -f $p.ExitCode) "Red"
    return $false
}

function Wait-ITToolkitAcPower {
    try {
        if (@(Get-CimInstance Win32_Battery -ErrorAction Stop).Count -eq 0) { return }  # desktop
    } catch { return }
    while ([System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -ne 'Online') {
        Write-GuiLog "Laptop is on BATTERY - Dell won't flash BIOS/firmware without AC power." "Yellow"
        $r = [System.Windows.Forms.MessageBox]::Show(
            "This laptop is running on battery.`r`n`r`nDell BIOS/firmware updates need AC power. Plug in the charger, then click Retry.`r`n`r`nCancel = continue anyway (BIOS/firmware will likely be skipped).",
            "Plug in AC power", [System.Windows.Forms.MessageBoxButtons]::RetryCancel, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($r -ne [System.Windows.Forms.DialogResult]::Retry) {
            Write-GuiLog "Continuing on battery - BIOS/firmware may be skipped." "Yellow"
            return
        }
        Start-Sleep -Seconds 2
    }
    Write-GuiLog "AC power connected." "Gray"
}


# ---------------------------------------------------------------------
# LIVE DCU PROGRESS: tail DCU's console output + log while it runs
# ---------------------------------------------------------------------
function New-ITToolkitFileTail {
    param([string[]]$Paths)
    $t = @{ Files = @(); Seen = New-Object 'System.Collections.Generic.HashSet[string]'; Shown = 0 }
    foreach ($p in $Paths) {
        if ($p) { $t.Files += @{ Path = $p; Offset = 0L; Partial = ''; IsLog = ($p -like '*.log') } }
    }
    return $t
}

# Returns complete new lines since the last call (handles files still being written).
function Read-ITToolkitFileTail {
    param($Tail)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($f in $Tail.Files) {
        if (-not (Test-Path -LiteralPath $f.Path)) { continue }
        $fs = $null
        try {
            $fs = [System.IO.File]::Open($f.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite, Delete')
            if ($fs.Length -lt $f.Offset) { $f.Offset = 0L; $f.Partial = '' }   # file was recreated
            if ($fs.Length -eq $f.Offset) { continue }
            [void]$fs.Seek($f.Offset, [System.IO.SeekOrigin]::Begin)
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
            $chunk = $sr.ReadToEnd()
            $f.Offset = $fs.Length
            $text = $f.Partial + $chunk
            $parts = $text -split "`r?`n"
            $f.Partial = $parts[-1]                      # last piece may be an unfinished line
            for ($i = 0; $i -lt $parts.Count - 1; $i++) { $out.Add([pscustomobject]@{ Line = $parts[$i]; IsLog = $f.IsLog }) | Out-Null }
        } catch {
        } finally {
            if ($fs) { $fs.Dispose() }
        }
    }
    return , $out
}

# Turns a raw DCU line into something worth showing (or $null for noise / duplicates)
function Get-ITToolkitDcuProgressLine {
    param($Tail, [string]$Line, [bool]$IsLog)
    $l = $Line.Trim()
    # strip timestamps / severity tags that the log adds, e.g. "[2026-10-13 12:00:01] [Info]"
    $l = $l -replace '^\[?\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}[ T]\d{1,2}:\d{2}(:\d{2})?([.,]\d+)?\]?\s*', ''
    $l = $l -replace '^(\[[^\]]{1,20}\]\s*)+', ''
    $l = $l.Trim()
    if ($l.Length -lt 4) { return $null }
    if ($l -match '^[\s\.\-=\*%\d\|\\/#>]+$') { return $null }       # progress bars / percentages
    if ($l -match '^\d{1,3}\s*%') { return $null }
    # The log is chatty - only take the lines that describe real steps from it
    if ($IsLog -and $l -notmatch '(?i)download|install|applicable|reboot|restart|complet|success|fail|error|bios|firmware|driver|\b\d+ of \d+\b|scan result') { return $null }
    $key = ($l -replace '\d{1,3}\s*%', '' -replace '\s+', ' ').ToLowerInvariant()
    if (-not $Tail.Seen.Add($key)) { return $null }
    if ($l.Length -gt 150) { $l = $l.Substring(0, 147) + '...' }
    return $l
}

function Wait-ITToolkitDcuWithProgress {
    param($Process, [string[]]$Paths, [string]$Label)
    try { $null = $Process.Handle } catch { }
    $tail = New-ITToolkitFileTail -Paths $Paths
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # shared state (a hashtable so the flush block can update it)
    $st = @{ LastNew = 0.0; LastStep = ''; ConsoleLines = 0; LastConsole = -999.0 }
    $nextRead = 0
    $flush = {
        foreach ($item in (Read-ITToolkitFileTail -Tail $tail)) {
            $now = $sw.Elapsed.TotalSeconds
            # Prefer DCU's console output; use its log only when the console has been quiet for 30s+
            if ($item.IsLog -and $st.ConsoleLines -gt 0 -and ($now - $st.LastConsole) -lt 30) { continue }
            $show = Get-ITToolkitDcuProgressLine -Tail $tail -Line $item.Line -IsLog $item.IsLog
            if (-not $show) { continue }
            if (-not $item.IsLog) { $st.ConsoleLines++; $st.LastConsole = $now }
            $tail.Shown++
            if ($tail.Shown -le 250) {
                $color = if ($show -match '(?i)\bfail|error') { 'Red' } elseif ($show -match '(?i)complet|success|installed') { 'Lime' } else { 'Gray' }
                Write-GuiLog ("  DCU: {0}" -f $show) $color
            } elseif ($tail.Shown -eq 251) {
                Write-GuiLog "  DCU: (more progress in the DCU log)" "Gray"
            }
            if ($show -match '(?i)download|install|scan|check|apply|updat') {
                $st.LastStep = $show
                $short = if ($show.Length -gt 48) { $show.Substring(0, 45) + '...' } else { $show }
                try { Set-ITToolkitBusyIndicator $true ("Dell - " + $short) } catch { }
            }
            $st.LastNew = $now
        }
    }
    while (-not $Process.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
        if ($sw.Elapsed.TotalSeconds -ge $nextRead) {
            & $flush
            $nextRead = $sw.Elapsed.TotalSeconds + 1
        }
        # Nothing new for a minute: say we're still alive, and on what
        if ($sw.Elapsed.TotalSeconds - $st.LastNew -ge 60) {
            $what = if ($st.LastStep) { "still on: $($st.LastStep)" } else { 'still working' }
            Write-GuiLog ("  {0} - {1} (elapsed {2:hh\:mm\:ss})" -f $Label, $what, $sw.Elapsed) "Gray"
            $st.LastNew = $sw.Elapsed.TotalSeconds
        }
    }
    try { $Process.WaitForExit() } catch { }
    Start-Sleep -Milliseconds 300
    & $flush
    try { if ($Script:CurrentActionLabel) { Set-ITToolkitBusyIndicator $true $Script:CurrentActionLabel } } catch { }
}

# DCU wants option values WITHOUT quotes (quoted paths come back as exit 107).
function Format-ITToolkitDcuOption {
    param([string]$Name, [string]$Value)
    if ($Value -match '\s') { return ('-{0}="{1}"' -f $Name, $Value) }   # only quote if a space forces it
    return ('-{0}={1}' -f $Name, $Value)
}

# Runs dcu-cli; captures its log + console output.
# Results: $Script:DcuExitCode, $Script:DcuLogPath, $Script:DcuStdOutPath, $Script:DcuDroppedOptions
function Invoke-ITToolkitDcu {
    param([string]$DcuExe, [string[]]$Arguments, [string]$HeartbeatLabel = 'Dell Command | Update still running', [switch]$NoLog)
    $logDir = Join-Path $env:ProgramData 'IT-Toolkit-temp\DCU'
    New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
    $stamp = "{0}_{1:HHmmss}_{2}" -f ($Arguments[0] -replace '[^A-Za-z]', ''), (Get-Date), (Get-Random -Maximum 999)
    $Script:DcuLogPath = if ($NoLog) { $null } else { Join-Path $logDir ("dcu_{0}.log" -f $stamp) }
    $Script:DcuStdOutPath = Join-Path $logDir ("dcu_{0}_console.txt" -f $stamp)
    $argList = @($Arguments)
    if (-not $NoLog) { $argList += (Format-ITToolkitDcuOption -Name 'outputLog' -Value $Script:DcuLogPath) }

    $runOnce = {
        $p = Start-Process -FilePath $DcuExe -ArgumentList $argList -NoNewWindow -RedirectStandardOutput $Script:DcuStdOutPath -PassThru
        Wait-ITToolkitDcuWithProgress -Process $p -Paths @($Script:DcuStdOutPath, $Script:DcuLogPath) -Label 'Dell Command | Update'
        $Script:DcuExitCode = [int]$p.ExitCode
    }
    & $runOnce

    # 3000-3005 = the Dell Client Management Service isn't ready (stopped, disabled, busy, self-updating).
    # Fix what we can and wait it out instead of failing - very common right after first boot.
    $waited = 0
    $maxWait = 900   # 15 minutes
    while ($Script:DcuExitCode -ge 3000 -and $Script:DcuExitCode -le 3005 -and $waited -lt $maxWait) {
        $c = $Script:DcuExitCode
        $why = Get-ITToolkitDcuConsoleError
        $pause = 45
        if ($c -eq 3001) {
            Write-GuiLog ("Dell Client Management Service is not installed (exit 3001){0}. Reinstall Dell Command | Update (USB Dell folder)." -f $(if ($why) { ": $why" } else { '' })) "Red"
            break
        } elseif ($c -eq 3000) {
            Write-GuiLog "Dell Client Management Service isn't running (exit 3000) - starting it and retrying..." "Yellow"
            Start-Service -Name 'DellClientManagementService' -ErrorAction SilentlyContinue
            $pause = 10
        } elseif ($c -eq 3002) {
            Write-GuiLog "Dell Client Management Service is disabled (exit 3002) - enabling it and retrying..." "Yellow"
            Set-Service -Name 'DellClientManagementService' -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name 'DellClientManagementService' -ErrorAction SilentlyContinue
            $pause = 10
        } else {
            $what = switch ($c) { 3003 { 'busy with another task' } 3004 { 'updating Dell Command | Update itself' } 3005 { 'installing updates it already had queued' } default { 'not ready' } }
            Write-GuiLog ("Dell service is {0} (exit {1}) - waiting {2}s and retrying (attempt {3} of {4})..." -f $what, $c, $pause, ([math]::Floor($waited / 45) + 2), ([math]::Floor($maxWait / 45) + 1)) "Yellow"
            if ($why -and $waited -eq 0) { Write-GuiLog ("  DCU says: {0}" -f $why) "Gray" }
        }
        for ($i = 0; $i -lt ($pause * 10); $i++) { Start-Sleep -Milliseconds 100; [System.Windows.Forms.Application]::DoEvents() }
        $waited += $pause
        & $runOnce
    }
    if ($Script:DcuExitCode -ge 3000 -and $Script:DcuExitCode -le 3005 -and $Script:DcuExitCode -ne 3001) {
        Write-GuiLog ("Dell service still not ready after {0} minutes (exit {1}). Try again later, or restart the PC to clear it." -f [math]::Floor($maxWait / 60), $Script:DcuExitCode) "Red"
    }

    # 100-199 = DCU rejected the command line. Say what it rejected, then retry once with only the core options.
    if ($Script:DcuExitCode -ge 100 -and $Script:DcuExitCode -le 199 -and -not $NoLog) {
        $why = Get-ITToolkitDcuConsoleError
        Write-GuiLog ("DCU rejected the command options (exit {0}){1}" -f $Script:DcuExitCode, $(if ($why) { ": $why" } else { '.' })) "Yellow"
        $core = @($Arguments | Where-Object { $_ -notlike '-report=*' -and $_ -notlike '-outputLog=*' })
        $Script:DcuDroppedOptions = ($core.Count -lt $Arguments.Count)
        Write-GuiLog "Retrying with only the basic options..." "Gray"
        Invoke-ITToolkitDcu -DcuExe $DcuExe -Arguments $core -HeartbeatLabel $HeartbeatLabel -NoLog
        if ($Script:DcuExitCode -ge 100 -and $Script:DcuExitCode -le 199) {
            $why = Get-ITToolkitDcuConsoleError
            Write-GuiLog ("DCU still rejected the command (exit {0}){1}" -f $Script:DcuExitCode, $(if ($why) { ": $why" } else { '' })) "Red"
        }
        return
    }
}

# First error-looking line DCU printed to its console (that's where it explains 1xx codes)
function Get-ITToolkitDcuConsoleError {
    if (-not $Script:DcuStdOutPath -or -not (Test-Path -LiteralPath $Script:DcuStdOutPath)) { return $null }
    $lines = @(Get-Content -LiteralPath $Script:DcuStdOutPath -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
    $err = $lines | Where-Object { $_ -match '(?i)error|invalid|not valid|not supported|unrecognized|unknown|cannot|must' } | Select-Object -First 1
    if (-not $err) { $err = $lines | Select-Object -Last 1 }
    if ($err) { return ($err.Trim() -replace '\s+', ' ').TrimEnd('.') }
    return $null
}

function Write-ITToolkitDcuLogTail {
    param([string]$Path, [int]$Max = 12)
    $src = $Path
    if (-not $src -or -not (Test-Path -LiteralPath $src) -or (Get-Item -LiteralPath $src).Length -eq 0) { $src = $Script:DcuStdOutPath }
    if (-not $src -or -not (Test-Path -LiteralPath $src)) {
        Write-GuiLog "  (DCU wrote no output. Also check C:\ProgramData\Dell\UpdateService\Log)" "Gray"
        return
    }
    $lines = @(Get-Content -LiteralPath $src -Tail 80 -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
    $bad = @($lines | Where-Object { $_ -match '(?i)error|fail|exception|denied|unable|not supported|invalid|password|power|reboot' })
    $show = if ($bad.Count -gt 0) { $bad | Select-Object -Last $Max } else { $lines | Select-Object -Last $Max }
    Write-GuiLog "  --- Dell Command | Update output (key lines) ---" "Gray"
    foreach ($l in $show) { Write-GuiLog ("  " + $l.Trim()) "Yellow" }
    Write-GuiLog ("  Full DCU output: {0}" -f $src) "Gray"
}

function Invoke-ITToolkitDellUpdates {
    $Script:DellRebootNeeded = $false
    $Script:DellStatus = 'Not run'
    if (-not (Test-ITToolkitIsDell)) {
        $Script:DellStatus = 'Not a Dell'
        return
    }

    $dcuExe = Get-ITToolkitDcuPath
    if (-not $dcuExe) {
        Write-GuiLog "Dell Command | Update is not installed - checking the USB Dell folder for an installer..." "Yellow"
        if (Install-ITToolkitDcuFromUsb) { $dcuExe = Get-ITToolkitDcuPath }
    }
    if (-not $dcuExe) {
        $Script:DellStatus = 'SKIPPED - DCU not installed'
        Write-GuiLog "Dell BIOS / firmware / drivers were NOT updated: Dell Command | Update is missing." "Red"
        Write-GuiLog "  Fix: put the DCU installer (+ .NET 8 Desktop Runtime x64) in a folder named 'Dell' on the USB." "Gray"
        return
    }

    $ver = (Get-Item -LiteralPath $dcuExe).VersionInfo.ProductVersion
    Write-GuiLog ("Dell Command | Update {0} found." -f $ver) "Gray"
    try {
        if ([version]($ver -replace '[^\d\.].*$', '') -lt [version]'4.0') {
            Write-GuiLog "DCU is older than 4.x - trying to upgrade it from the USB Dell folder..." "Yellow"
            if (Install-ITToolkitDcuFromUsb) {
                $dcuExe = Get-ITToolkitDcuPath
                $ver = (Get-Item -LiteralPath $dcuExe).VersionInfo.ProductVersion
            }
        }
        if ([version]($ver -replace '[^\d\.].*$', '') -lt [version]'4.0') {
            $Script:DellStatus = 'SKIPPED - DCU too old'
            Write-GuiLog "This DCU version is too old for the toolkit (needs 4.x or newer). Update DCU (USB Dell folder)." "Red"
            return
        }
    } catch { }

    # Things that commonly cause exit codes 2/3/6: service stopped, DCU GUI open, another scan running
    $svc = Get-Service -Name 'DellClientManagementService' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Write-GuiLog "Starting Dell Client Management Service..." "Gray"
        Start-Service -Name 'DellClientManagementService' -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    Get-Process -Name 'DellCommandUpdate' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    Wait-ITToolkitAcPower

    Invoke-ITToolkitDcu -DcuExe $dcuExe -Arguments @('/configure', '-autoSuspendBitLocker=enable') -HeartbeatLabel 'Configuring DCU'
    if ($Script:DcuExitCode -ne 0) {
        Write-GuiLog ("DCU configure returned {0} (often just locked by policy - continuing)." -f $Script:DcuExitCode) "Gray"
    }

    Write-GuiLog "Applying Dell BIOS / firmware / drivers (Dell Command | Update)..." "Yellow"
    $attempt = 0
    do {
        $attempt++
        Invoke-ITToolkitDcu -DcuExe $dcuExe -Arguments @('/applyUpdates', '-reboot=disable')
        $code = $Script:DcuExitCode
        $retry = ($attempt -eq 1 -and $code -in 2, 3, 6)
        if ($retry) {
            $why = if ($Script:DcuExitText.ContainsKey($code)) { $Script:DcuExitText[$code] } else { "exit $code" }
            Write-GuiLog ("DCU: {0} (exit {1}). Resetting the Dell service and retrying once..." -f $why, $code) "Yellow"
            Write-ITToolkitDcuLogTail -Path $Script:DcuLogPath -Max 6
            Get-Process -Name 'DellCommandUpdate' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            if ($code -ne 6) { Restart-Service -Name 'DellClientManagementService' -Force -ErrorAction SilentlyContinue }
            # Give the service time to settle after a restart (otherwise the retry just gets "busy")
            for ($i = 0; $i -lt 300; $i++) { Start-Sleep -Milliseconds 100; [System.Windows.Forms.Application]::DoEvents() }
        }
    } while ($retry)

    $text = if ($Script:DcuExitText.ContainsKey($code)) { $Script:DcuExitText[$code] } elseif ($code -ge 100 -and $code -le 199) { 'DCU rejected the command options' } else { 'Unrecognized result' }
    switch ($code) {
        { $_ -in 0, 500, 501 } {
            $Script:DellStatus = 'OK'
            Write-GuiLog ("Dell: {0}." -f $text) "Green"
        }
        { $_ -in 1, 5 } {
            $Script:DellStatus = 'OK - restart needed'
            $Script:DellRebootNeeded = $true
            Write-GuiLog ("Dell: {0}." -f $text) "Yellow"
        }
        default {
            $Script:DellStatus = "FAILED (exit $code)"
            Write-GuiLog ("Dell updates FAILED: {0} (exit {1})." -f $text, $code) "Red"
            Write-ITToolkitDcuLogTail -Path $Script:DcuLogPath
            # Temp folder is wiped on close - keep a copy of the failure log
            try {
                if ($Script:DcuLogPath -and (Test-Path -LiteralPath $Script:DcuLogPath)) {
                    $keep = Join-Path (Get-ITToolkitOutputFolder) ("DCU_Failure_{0}_{1:yyyyMMdd_HHmmss}.log" -f $env:COMPUTERNAME, (Get-Date))
                    Copy-Item -LiteralPath $Script:DcuLogPath -Destination $keep -Force
                    Write-GuiLog ("  DCU failure log saved to: {0}" -f $keep) "Gray"
                }
            } catch { }
        }
    }
}

# Counts what's still missing without installing anything. Result in $Script:DellPendingCount (-1 = unknown)
function Get-ITToolkitDellPending {
    param([string]$UpdateType = '')
    $Script:DellPendingCount = -1
    $Script:DellPendingNames = @()
    $dcuExe = Get-ITToolkitDcuPath
    if (-not $dcuExe) { return }
    $rep = Join-Path $env:ProgramData ("IT-Toolkit-temp\DCU\scan_{0}" -f (Get-Random))
    New-Item -ItemType Directory -Path $rep -Force | Out-Null
    $scanArgs = @('/scan')
    if ($UpdateType) { $scanArgs += (Format-ITToolkitDcuOption -Name 'updateType' -Value $UpdateType) }
    $scanArgs += (Format-ITToolkitDcuOption -Name 'report' -Value $rep)
    $Script:DcuDroppedOptions = $false
    Invoke-ITToolkitDcu -DcuExe $dcuExe -Arguments $scanArgs -HeartbeatLabel 'Dell scan still running'
    $code = $Script:DcuExitCode
    if ($code -in 500, 501) {
        $Script:DellPendingCount = 0
    } elseif ($code -eq 0) {
        $names = @()
        foreach ($x in @(Get-ChildItem -LiteralPath $rep -Filter *.xml -Recurse -ErrorAction SilentlyContinue)) {
            try {
                [xml]$doc = Get-Content -LiteralPath $x.FullName -Raw
                foreach ($u in @($doc.SelectNodes('//update'))) { $names += ("{0} {1}" -f $u.name, $u.version).Trim() }
            } catch { }
        }
        if ($names.Count -eq 0 -and $Script:DcuStdOutPath -and (Test-Path -LiteralPath $Script:DcuStdOutPath)) {
            # No XML report (option dropped) - read the update list DCU printed instead, e.g. "1) Dell BIOS ..."
            $names = @(Get-Content -LiteralPath $Script:DcuStdOutPath -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '^\s*\d+\)\s+(.+)$' } | ForEach-Object { ($_ -replace '^\s*\d+\)\s+', '').Trim() })
            if ($names.Count -eq 0) { $names = @('Updates available (see DCU output)') }
        }
        $Script:DellPendingCount = $names.Count
        $Script:DellPendingNames = $names
    } else {
        $text = if ($Script:DcuExitText.ContainsKey($code)) { $Script:DcuExitText[$code] } else { "exit $code" }
        Write-GuiLog ("Dell scan problem: {0} (exit {1})" -f $text, $code) "Yellow"
        Write-ITToolkitDcuLogTail -Path $Script:DcuLogPath -Max 6
    }
    Remove-Item -LiteralPath $rep -Recurse -Force -ErrorAction SilentlyContinue
}

# The "is this device 100%?" check. Sets $Script:VerifyPassed.
function Run-VerifyFullyPatched {
    Write-GuiLog "=== FINAL CHECK: IS THIS DEVICE FULLY PATCHED? ===" "Cyan"
    $fails = @()

    # Windows Update (scan only)
    $wu = Invoke-ITToolkitBackgroundJob -ScriptBlock $Script:WindowsUpdateJob -HeartbeatSeconds 30 -Data @{ ScanOnly = $true }
    if (-not $wu -or $wu.Error) {
        $wuText = 'UNKNOWN (scan failed)'; $fails += 'Windows Update scan failed'
    } else {
        $wuText = [string]$wu.Found
        if ([int]$wu.Found -gt 0) { $fails += "$($wu.Found) Windows update(s) still pending" }
    }

    # Dell
    if (Test-ITToolkitIsDell) {
        Get-ITToolkitDellPending
        if ($Script:DellPendingCount -lt 0) {
            $dellText = if (Get-ITToolkitDcuPath) { "UNKNOWN (DCU scan exit $Script:DcuExitCode)" } else { 'UNKNOWN (DCU not installed)' }
            $fails += 'Dell status unknown'
        } else {
            $dellText = [string]$Script:DellPendingCount
            if ($Script:DellPendingCount -gt 0) { $fails += "$($Script:DellPendingCount) Dell update(s) still pending" }
        }
    } else {
        $dellText = 'n/a (not a Dell)'
    }

    $bios = Get-CimInstance Win32_BIOS
    $flags = @(Test-ITToolkitPendingReboot | Where-Object { $_ -ne 'PendingFileRenameOperations' })
    if ($flags.Count -gt 0) { $fails += 'restart pending' }

    Write-GuiLog ("Windows updates pending : {0}" -f $wuText) $(if ($wuText -eq '0') { 'Lime' } else { 'Red' })
    Write-GuiLog ("Dell updates pending    : {0}" -f $dellText) $(if ($dellText -eq '0' -or $dellText -like 'n/a*') { 'Lime' } else { 'Red' })
    foreach ($n in $Script:DellPendingNames) { Write-GuiLog ("    - {0}" -f $n) "Yellow" }
    Write-GuiLog ("BIOS version            : {0}" -f $bios.SMBIOSBIOSVersion) "White"
    Write-GuiLog ("Restart pending         : {0}" -f $(if ($flags.Count) { 'YES (' + ($flags -join ', ') + ')' } else { 'No' })) $(if ($flags.Count) { 'Red' } else { 'Lime' })

    $Script:VerifyPassed = ($fails.Count -eq 0)
    $Script:VerifyFailures = $fails
    if ($Script:VerifyPassed) {
        Write-GuiLog "RESULT: READY - Windows and Dell are fully up to date." "Lime"
    } else {
        Write-GuiLog ("RESULT: NOT READY - {0}." -f ($fails -join '; ')) "Red"
    }
}

function Run-ProvisioningUpdates {
    param([switch]$DeferRebootPrompt)

    $Script:UpdateRebootNeeded = $false
    $pass = Get-ITToolkitResumePass
    if ($Script:IsResume) {
        Write-GuiLog ("=== RESUMING UPDATE SEQUENCE AFTER REBOOT (pass {0} of {1}) ===" -f $pass, $Script:MaxUpdatePasses) "Cyan"
    } else {
        Write-GuiLog "Running OS updates..." "Cyan"
    }

    # ==================== WINDOWS UPDATES ====================
    # Rescan in-session if updates installed without needing a reboot
    # (Windows often offers follow-up updates right after).
    $installedTotal = 0
    $failedTotal = 0
    $wuReboot = $false
    for ($scan = 1; $scan -le 3; $scan++) {
        Invoke-ITToolkitWindowsUpdatePass
        $r = $Script:WUPassResult
        if (-not $r) { break }
        $installedTotal += [int]$r.Installed
        $failedTotal += [int]$r.Failed
        if ($r.RebootRequired) { $wuReboot = $true; break }
        if ([int]$r.Installed -eq 0) { break }
        if ($scan -lt 3) { Write-GuiLog "Installed updates without a reboot - rescanning for follow-ups..." "Cyan" }
    }

    # ==================== DELL UPDATES ====================
    Invoke-ITToolkitDellUpdates

    # ==================== REBOOT DECISION ====================
    $needReboot = $wuReboot -or $Script:DellRebootNeeded
    if (-not $needReboot -and $installedTotal -gt 0) {
        $flags = @(Test-ITToolkitPendingReboot | Where-Object { $_ -ne 'PendingFileRenameOperations' })
        if ($flags.Count -gt 0) { $needReboot = $true }
    }

    Write-GuiLog ("Windows Update summary: {0} installed, {1} failed." -f $installedTotal, $failedTotal) $(if ($failedTotal -gt 0) { 'Yellow' } else { 'Lime' })
    if ($Script:DellStatus -and $Script:DellStatus -ne 'Not a Dell') {
        Write-GuiLog ("Dell summary: {0}" -f $Script:DellStatus) $(if ($Script:DellStatus -like 'OK*') { 'Lime' } else { 'Red' })
    }

    if ($needReboot) {
        $Script:UpdateRebootNeeded = $true
        $nextPass = $pass + 1
        if ($nextPass -gt $Script:MaxUpdatePasses) {
            Write-GuiLog ("Reached {0} reboot cycles - auto-resume stopped to avoid a loop. Restart, then run Master Update again if needed." -f $Script:MaxUpdatePasses) "Yellow"
            Clear-ITToolkitResumeHooks
        } else {
            Register-ITToolkitResume -Pass $nextPass
        }
        if (-not $DeferRebootPrompt) {
            Show-ITToolkitRebootPrompt
        }
    } else {
        if ($Script:IsResume -or $installedTotal -gt 0) {
            Write-GuiLog "Update loop complete - nothing left that needs a reboot." "Lime"
        } else {
            Write-GuiLog "No missing updates found. Update loop complete." "Lime"
        }
        Clear-ITToolkitResumeHooks
    }
    $Script:IsResume = $false
}

function Run-SyncPolicy {
    Write-GuiLog "Forcing Group Policy and MDM Sync..." "Cyan"
    # "echo n|" answers gpupdate's "OK to log off/restart? (Y/N)" prompt, which used to hang this forever.
    $gpProc = Start-Process "cmd.exe" -ArgumentList '/c echo n| gpupdate.exe /force' -WindowStyle Hidden -PassThru
    Wait-GuiProcess -Process $gpProc -HeartbeatLabel 'gpupdate still running'
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq 'PushLaunch' -and $_.TaskPath -match 'EnterpriseMgmt' } | Start-ScheduledTask -ErrorAction SilentlyContinue
    Write-GuiLog "Policy sync parameters checked." "Lime"
}

function Run-WingetUpdateAll {
    $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $wg) {
        Write-GuiLog "winget not found for this account - skipping app updates." "Yellow"
        return
    }
    Write-GuiLog "Starting Winget mass application update (progress shows in the console window)..." "Cyan"
    $wgProc = Start-Process -FilePath $wg.Source -ArgumentList 'upgrade', '--all', '--silent', '--accept-source-agreements', '--accept-package-agreements' -NoNewWindow -PassThru
    Wait-GuiProcess -Process $wgProc -HeartbeatLabel 'Winget still upgrading apps' -HeartbeatSeconds 60
    $code = $wgProc.ExitCode
    if ($code -eq 0 -or $null -eq $code) {
        Write-GuiLog "Winget deployment updates verified." "Lime"
    } else {
        Write-GuiLog ("Winget finished with code 0x{0:X8} - some apps may not have updated (check console)." -f ([int]$code)) "Yellow"
    }
}

# --- MAINTENANCE & RECOVERY ---
function Run-KeepAwake {
    [SystemSleep]::SetThreadExecutionState([SystemSleep]::ES_CONTINUOUS -bor [SystemSleep]::ES_SYSTEM_REQUIRED -bor [SystemSleep]::ES_DISPLAY_REQUIRED) | Out-Null
    Write-GuiLog "System power state execution modified to Always Awake." "Lime"
}

function Run-Ghostbuster {
    Write-GuiLog "Starting Windows Update Ghostbuster..." "Cyan"
    $SourceFolder = "C:\Windows\SoftwareDistribution\Download"
    $TempFolder = "C:\TEMP\Ghostbuster_Archive_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

    Stop-Service -Name wuauserv, bits, cryptsvc, msiserver -Force -ErrorAction SilentlyContinue
    [System.Windows.Forms.Application]::DoEvents()

    if (Test-Path $SourceFolder) {
        $InitialSize = (Get-ChildItem $SourceFolder -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        New-Item -ItemType Directory -Path $TempFolder -Force | Out-Null
        Get-ChildItem -Path $SourceFolder -ErrorAction SilentlyContinue | Move-Item -Destination $TempFolder -Force -ErrorAction SilentlyContinue
        
        if ($InitialSize -gt 0) {
            $SizeGB = [math]::Round($InitialSize / 1GB, 2)
            Write-GuiLog "Archived and isolated $SizeGB GB of metadata payloads." "Lime"
        }
    }
    Start-Service -Name wuauserv, bits, cryptsvc, msiserver -ErrorAction SilentlyContinue
}

function Run-Recovery {
    Write-GuiLog "Starting Windows System Recovery..." "Cyan"
    Write-GuiLog "DISM RestoreHealth running (10-30 min is normal; progress shows in the console)..." "Yellow"
    $dismProc = Start-Process dism.exe -ArgumentList "/Online /Cleanup-Image /RestoreHealth" -NoNewWindow -PassThru
    Wait-GuiProcess -Process $dismProc -HeartbeatLabel 'DISM RestoreHealth still running'
    Write-GuiLog ("DISM exit code: {0}" -f $dismProc.ExitCode) $(if ($dismProc.ExitCode -eq 0) { 'Lime' } else { 'Yellow' })

    Write-GuiLog "SFC /scannow running..." "Yellow"
    $sfcProc = Start-Process sfc.exe -ArgumentList "/scannow" -NoNewWindow -PassThru
    Wait-GuiProcess -Process $sfcProc -HeartbeatLabel 'SFC still running'
    Write-GuiLog ("SFC exit code: {0}" -f $sfcProc.ExitCode) $(if ($sfcProc.ExitCode -eq 0) { 'Lime' } else { 'Yellow' })
    Write-GuiLog "OS core image health integrity scan complete." "Lime"
}

function Run-ClearOrphans {
    Write-GuiLog "Analyzing active installer engine bindings..." "Cyan"
    $BackupDir = "C:\InstallerBackup"
    $InstallerDir = "C:\Windows\Installer"
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir | Out-Null }
    
    $ValidFiles = @()
    $ProductKeys = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\*\Products\*\InstallProperties" -Name "LocalPackage" -ErrorAction SilentlyContinue
    $ValidFiles += $ProductKeys.LocalPackage | Split-Path -Leaf
    [System.Windows.Forms.Application]::DoEvents()

    $PatchKeys = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\*\Patches\*" -Name "LocalPackage" -ErrorAction SilentlyContinue
    $ValidFiles += $PatchKeys.LocalPackage | Split-Path -Leaf
    $ValidFiles = @($ValidFiles | Where-Object { $_ } | ForEach-Object { $_.ToLower() } | Select-Object -Unique)

    # Avoid Get-ChildItem -Include (broken without a trailing path wildcard)
    $TargetFiles = Get-ChildItem -Path $InstallerDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '\.ms[ip]$' }
    $Orphans = @()
    foreach ($File in $TargetFiles) {
        if ($ValidFiles -notcontains $File.Name.ToLower()) { $Orphans += $File }
    }

    if ($Orphans.Count -eq 0) {
        Write-GuiLog "No orphaned MSI/MSP files found." "Green"
        return
    }

    if (-not (Confirm-DestructiveAction -Title "Quarantine Orphan Installers" -Message "Move $($Orphans.Count) unreferenced MSI/MSP file(s) to $BackupDir ? Review carefully - false positives can break repair/uninstall.")) {
        Write-GuiLog "Orphan quarantine canceled by operator." "Yellow"
        return
    }
    
    $TotalBytes = 0; $MovedCount = 0
    foreach ($Orphan in $Orphans) {
        try {
            $TotalBytes += $Orphan.Length
            Move-Item -Path $Orphan.FullName -Destination $BackupDir -Force -ErrorAction Stop
            $MovedCount++
        } catch {
            Write-GuiLog "Failed to move $($Orphan.Name): $_" "Yellow"
        }
        [System.Windows.Forms.Application]::DoEvents()
    }
    Write-GuiLog "Swept $MovedCount abandoned MSIs. Storage recovered: $([math]::Round($TotalBytes / 1GB, 2)) GB" "Lime"
}

function Run-ClearPatchCache {
    $CachePath = 'C:\Windows\Installer\$PatchCache$\Managed' 
    if (Test-Path $CachePath) {
        try {
            Get-ChildItem -LiteralPath $CachePath -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction Stop
            Write-GuiLog "Successfully cleared hidden base repair patch cache folders." "Lime"
        } catch {
            Write-GuiLog ("Patch cache partially cleared (some files locked): {0}" -f $_.Exception.Message) "Yellow"
        }
    } else {
        Write-GuiLog "No baseline patch cache present." "Gray"
    }
}

function Run-InstallerCompression {
    Write-GuiLog "Compressing Installer System Directory..." "Yellow"
    try {
        $cProc = Start-Process -FilePath "compact.exe" -ArgumentList "/c /s:`"C:\Windows\Installer`" /i /q" -WindowStyle Hidden -PassThru
        Wait-GuiProcess -Process $cProc -HeartbeatLabel 'Compression still running'
        Write-GuiLog "NTFS structure directory compression finalized." "Lime"
    } catch { }
}

function Run-ClearWinSxS {
    Write-GuiLog "Executing Component Store WinSxS Superseded Sweep..." "Cyan"
    $dismProc = Start-Process "DISM.exe" -ArgumentList "/online /Cleanup-Image /StartComponentCleanup" -NoNewWindow -PassThru
    Wait-GuiProcess -Process $dismProc -HeartbeatLabel 'WinSxS cleanup still running'
    Write-GuiLog "WinSxS archive consolidation complete." "Lime"
}

function Run-NetworkReset {
    if (-not (Confirm-DestructiveAction -Title "Deep Network Reset" -Message "This releases the IP lease and resets Winsock/TCPIP. Remote sessions may drop. Continue?")) {
        Write-GuiLog "Network reset canceled by operator." "Yellow"
        return
    }
    Write-GuiLog "Initiating Deep Network Stack Reset..." "Yellow"
    ipconfig /flushdns | Out-Null
    ipconfig /release | Out-Null
    [System.Windows.Forms.Application]::DoEvents()
    ipconfig /renew | Out-Null
    netsh winsock reset | Out-Null
    netsh int ip reset | Out-Null
    Write-GuiLog "TCP/IP layers and local stack flushed completely. A reboot may be required." "Lime"
}

function Run-UnlockBitLocker {
    $unlockForm = New-Object System.Windows.Forms.Form
    $unlockForm.Text = "Unlock BitLocker Drive"
    $unlockForm.Size = New-Object System.Drawing.Size(350, 220)
    $unlockForm.StartPosition = "CenterScreen"
    $unlockForm.FormBorderStyle = 'FixedDialog'
    $unlockForm.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)

    $lblDrive = New-Object System.Windows.Forms.Label
    $lblDrive.Text = "Drive Letter (e.g. D:):"
    $lblDrive.ForeColor = [System.Drawing.Color]::White
    $lblDrive.Location = New-Object System.Drawing.Point(20, 20)
    $lblDrive.AutoSize = $true
    $unlockForm.Controls.Add($lblDrive)

    $txtDrive = New-Object System.Windows.Forms.TextBox
    $txtDrive.Location = New-Object System.Drawing.Point(20, 45)
    $txtDrive.Size = New-Object System.Drawing.Size(50, 25)
    $unlockForm.Controls.Add($txtDrive)

    $lblKey = New-Object System.Windows.Forms.Label
    $lblKey.Text = "Recovery Key or Password:"
    $lblKey.ForeColor = [System.Drawing.Color]::White
    $lblKey.Location = New-Object System.Drawing.Point(20, 80)
    $lblKey.AutoSize = $true
    $unlockForm.Controls.Add($lblKey)

    $txtKey = New-Object System.Windows.Forms.TextBox
    $txtKey.Location = New-Object System.Drawing.Point(20, 105)
    $txtKey.Size = New-Object System.Drawing.Size(295, 25)
    $txtKey.UseSystemPasswordChar = $true
    $unlockForm.Controls.Add($txtKey)

    $btnUnlock = New-Object System.Windows.Forms.Button
    $btnUnlock.Text = "Unlock"
    $btnUnlock.Location = New-Object System.Drawing.Point(215, 140)
    $btnUnlock.Size = New-Object System.Drawing.Size(100, 30)
    $btnUnlock.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnUnlock.ForeColor = [System.Drawing.Color]::White
    $btnUnlock.FlatStyle = 'Flat'
    $btnUnlock.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $unlockForm.Controls.Add($btnUnlock)
    $unlockForm.AcceptButton = $btnUnlock

    if ($unlockForm.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $tgtDrive = $txtDrive.Text.Trim().ToUpper()
        if ($tgtDrive.Length -eq 1) { $tgtDrive += ":" }
        $tgtKey = $txtKey.Text.Trim()
        
        try {
            $isRecovery = (($tgtKey -replace '[-\s]', '') -match '^\d{48}$')
            if ($isRecovery) {
                Unlock-BitLocker -MountPoint $tgtDrive -RecoveryPassword $tgtKey -ErrorAction Stop | Out-Null
            } else {
                $secStr = ConvertTo-SecureString $tgtKey -AsPlainText -Force
                Unlock-BitLocker -MountPoint $tgtDrive -Password $secStr -ErrorAction Stop | Out-Null
            }
            Write-GuiLog "Volume $tgtDrive unlocked successfully." "Lime"
        } catch {
            Write-GuiLog "BitLocker unlock failed: $($_.Exception.Message)" "Red"
        }
    }
}

function Run-ResetMediaDrivers {
    Write-GuiLog "Resetting Camera and Audio stack..." "Cyan"
    $devices = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Class -match "Camera|Media|AudioEndpoint" -and $_.Status -eq "Error" }
    foreach ($d in $devices) {
        Write-GuiLog ("Resetting: {0}" -f $d.FriendlyName) "Yellow"
        Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        [System.Windows.Forms.Application]::DoEvents()
    }
    foreach ($svc in @('Audiosrv', 'AudioEndpointBuilder')) {
        Restart-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Write-GuiLog ("Restarted service: {0}" -f $svc) "White"
    }
    Write-GuiLog "Camera/audio reset complete." "Lime"
}

# --- REMOVERS ---
function Run-RemoveAdobe {
    Write-GuiLog "Initiating Aggressive Adobe Removal..." "Yellow"
    # Stop-Process -Name does not glob; match Adobe processes explicitly
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match '^(Acrobat|AcroRd32|Adobe|Creative Cloud)' } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    $paths = @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*")
    $adobeApps = Get-ItemProperty $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match "Adobe" }
    
    if (-not $adobeApps) {
        Write-GuiLog "No Adobe applications found." "Green"
        return
    }

    $names = ($adobeApps | ForEach-Object { " - $($_.DisplayName)" }) -join "`r`n"
    if (-not (Confirm-DestructiveAction -Title "Remove Adobe" -Message "Uninstall these Adobe products?`r`n`r`n$names")) {
        Write-GuiLog "Adobe removal canceled." "Yellow"
        return
    }

    foreach ($app in $adobeApps) {
        $cmd = if ($app.QuietUninstallString) { $app.QuietUninstallString } else { $app.UninstallString }
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
        Write-GuiLog ("Removing: {0}" -f $app.DisplayName) "White"
        $rmProc = $null
        try {
            if ($cmd -match '(?i)msiexec' -and $cmd -match '(\{[0-9A-Fa-f\-]{36}\})') {
                # MSI product: always run a clean silent uninstall by product code
                $rmProc = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x $($Matches[1]) /qn /norestart" -WindowStyle Hidden -PassThru
            } elseif ($app.QuietUninstallString) {
                $rmProc = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$cmd`"" -WindowStyle Hidden -PassThru
            } else {
                # Split "C:\path\uninstall.exe" args  (quoted or unquoted)
                if ($cmd -match '^\s*"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $exeArgs = $Matches[2] }
                elseif ($cmd -match '^\s*(.+?\.exe)\s*(.*)$') { $exe = $Matches[1]; $exeArgs = $Matches[2] }
                else { $exe = $cmd; $exeArgs = '' }
                $exeArgs = ("$exeArgs /quiet /norestart").Trim()
                $rmProc = Start-Process -FilePath $exe -ArgumentList $exeArgs -PassThru -ErrorAction Stop
            }
            if ($rmProc) {
                Wait-GuiProcess -Process $rmProc -HeartbeatLabel ("Still removing {0}" -f $app.DisplayName)
                $ec = $rmProc.ExitCode
                if ($ec -eq 0 -or $ec -eq 3010 -or $ec -eq 1605) {
                    Write-GuiLog ("Removed: {0}{1}" -f $app.DisplayName, $(if ($ec -eq 3010) { ' (reboot needed)' } else { '' })) "Lime"
                } else {
                    Write-GuiLog ("Uninstaller for {0} exited with {1}." -f $app.DisplayName, $ec) "Yellow"
                }
            }
        } catch {
            Write-GuiLog ("Failed to remove {0}: {1}" -f $app.DisplayName, $_.Exception.Message) "Red"
        }
    }
    Write-GuiLog "Adobe removal pass complete." "Lime"
}

function Run-RemoveSAP {
    Write-GuiLog "Initiating SAP Removal..." "Yellow"
    Stop-Process -Name "saplogon", "sapgui", "nwbc" -Force -ErrorAction SilentlyContinue
    $sapSetup = "C:\Program Files (x86)\SAP\SAPsetup\setup\NwSapSetup.exe"
    
    if (Test-Path $sapSetup) {
        $sapProc = Start-Process $sapSetup -ArgumentList "/uninstall /all /nodlg" -NoNewWindow -PassThru
        Wait-GuiProcess -Process $sapProc -HeartbeatLabel 'SAP uninstall still running'
        if ($sapProc.ExitCode -eq 0 -or $sapProc.ExitCode -eq 3010) {
            Write-GuiLog "SAP GUI uninstalled cleanly." "Lime"
        } else {
            Write-GuiLog ("SAP uninstaller exited with {0}." -f $sapProc.ExitCode) "Yellow"
        }
    } else {
        Write-GuiLog "SAP setup engine (NwSapSetup.exe) not found - SAP GUI may not be installed." "Yellow"
    }
}

# --- DIAGNOSTICS & LOGGING ---
function Run-TreeSize {
    Write-GuiLog "Preparing Disk Analyzer (TreeSize)..." "Cyan"
    $tsPath = "$env:ProgramFiles\JAM Software\TreeSize Free\TreeSizeFree.exe"
    $tsPath86 = "${env:ProgramFiles(x86)}\JAM Software\TreeSize Free\TreeSizeFree.exe"
    
    if ((Test-Path $tsPath) -or (Test-Path $tsPath86)) {
        if (Test-Path $tsPath) { Start-Process $tsPath } else { Start-Process $tsPath86 }
    } else {
        $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $wg) {
            Write-GuiLog "TreeSize Free not found and winget is unavailable. Use Native Directory Scanner instead." "Yellow"
            return
        }
        Write-GuiLog "TreeSize Free not found. Launching clean Winget fetch..." "Yellow"
        $tsProc = Start-Process -FilePath $wg.Source -ArgumentList "install --id JAMSoftware.TreeSizeFree -e --accept-source-agreements --accept-package-agreements --silent" -NoNewWindow -PassThru
        Wait-GuiProcess -Process $tsProc -HeartbeatLabel 'Installing TreeSize'
        if (Test-Path $tsPath) { Start-Process $tsPath }
        elseif (Test-Path $tsPath86) { Start-Process $tsPath86 }
        else { Write-GuiLog "TreeSize install did not complete. Use Native Directory Scanner instead." "Yellow" }
    }
}

function Run-NativeDiskScanner {
    Write-GuiLog "Starting Native Disk Scan (C:\)..." "Cyan"
    $fso = New-Object -ComObject Scripting.FileSystemObject
    $folders = Get-ChildItem -Path "C:\" -Directory -Force -ErrorAction SilentlyContinue
    $results = @()
    
    foreach ($f in $folders) {
        # Skip junctions (e.g. "Documents and Settings") so nothing is double-counted
        if ($f.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        $size = $null
        try { $size = $fso.GetFolder($f.FullName).Size } catch { }
        if ($null -eq $size) {
            # FSO gives up on any access-denied subfolder (Windows, Users, ProgramData...),
            # which used to drop the BIGGEST folders from the list. Measure the slow way instead.
            Write-GuiLog ("Measuring {0} (slower path)..." -f $f.Name) "Gray"
            [System.Windows.Forms.Application]::DoEvents()
            $size = (Get-ChildItem -LiteralPath $f.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        }
        if ($null -ne $size) {
            $results += [PSCustomObject]@{ Name = $f.Name; Size = [double]$size }
        }
        [System.Windows.Forms.Application]::DoEvents()
    }
    
    $sorted = $results | Sort-Object Size -Descending | Select-Object -First 10
    Write-GuiLog "--- TOP 10 LARGEST DIRECTORIES ---" "Yellow"
    foreach ($r in $sorted) {
        $gb = [math]::Round($r.Size / 1GB, 2)
        if ($gb -gt 0) { Write-GuiLog "$($r.Name) - $gb GB" "White" }
    }
}

function Get-ITToolkitRecentEvents {
    param(
        [int]$Hours = 24,
        [int]$MaxEvents = 200
    )
    $start = (Get-Date).AddHours(-1 * $Hours)
    # Level 1=Critical, 2=Error
    Get-WinEvent -FilterHashtable @{ LogName = @('System', 'Application'); Level = 1, 2; StartTime = $start } -MaxEvents $MaxEvents -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, LevelDisplayName, LogName, ProviderName, Message
}

function Run-EventGrabber {
    Write-GuiLog "=== QUICK EVENT SCAN (BSOD / Unexpected Shutdown) ===" "Cyan"
    [System.Windows.Forms.Application]::DoEvents()

    $bsods = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001 } -MaxEvents 5 -ErrorAction SilentlyContinue)
    if ($bsods.Count -gt 0) {
        Write-GuiLog "[!] Recent BugCheck / BSOD events:" "Red"
        foreach ($b in $bsods) {
            $msg = if ($b.Message) { $b.Message.Substring(0, [math]::Min($b.Message.Length, 140)) } else { '(no message)' }
            Write-GuiLog (" {0:g} | {1}" -f $b.TimeCreated, $msg) "White"
        }
    } else {
        Write-GuiLog "No recent BugCheck (1001) events found." "Lime"
    }

    $power = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41 } -MaxEvents 5 -ErrorAction SilentlyContinue)
    if ($power.Count -gt 0) {
        Write-GuiLog "[!] Unexpected shutdown / Kernel-Power 41 events:" "Red"
        foreach ($p in $power) {
            Write-GuiLog (" {0:g} | Kernel-Power 41" -f $p.TimeCreated) "Yellow"
        }
    } else {
        Write-GuiLog "No recent Kernel-Power 41 events found." "Lime"
    }

    $crit = @(Get-ITToolkitRecentEvents -Hours 24 -MaxEvents 50)
    Write-GuiLog ("Critical/Error events in last 24h (sample): {0}" -f $crit.Count) "Cyan"
    Write-GuiLog "Tip: use Event Log Viewer for a scrollable/filterable list." "Gray"
}

function Run-ExportEventLogs {
    Write-GuiLog "Exporting Critical/Error events (7 days)..." "Yellow"
    $desktop = (Get-ITToolkitOutputFolder)
    $exportPath = Join-Path $desktop ("IT_EventLogs_{0}_{1:yyyyMMdd_HHmmss}.csv" -f $env:COMPUTERNAME, (Get-Date))
    $startTime = (Get-Date).AddDays(-7)
    [System.Windows.Forms.Application]::DoEvents()
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = @('System', 'Application'); Level = 1, 2; StartTime = $startTime } -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, LevelDisplayName, LogName, ProviderName, Message)

    if ($events.Count -eq 0) {
        Write-GuiLog "No Critical/Error events found in the last 7 days." "Yellow"
        return
    }
    $events | Export-Csv -Path $exportPath -NoTypeInformation -Encoding ASCII
    Write-GuiLog ("Exported {0} events to: {1}" -f $events.Count, $exportPath) "Lime"
}

function Show-EventLogViewer {
    Write-GuiLog "Opening Event Log Viewer (Critical/Error)..." "Cyan"

    $viewer = New-Object System.Windows.Forms.Form
    $viewer.Text = "Event Log Viewer - Critical / Error"
    $viewer.Size = New-Object System.Drawing.Size(980, 560)
    $viewer.StartPosition = "CenterScreen"
    $viewer.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Showing Critical and Error events. Double-click a row for full message."
    $lbl.ForeColor = [System.Drawing.Color]::White
    $lbl.Location = New-Object System.Drawing.Point(12, 10)
    $lbl.AutoSize = $true
    $viewer.Controls.Add($lbl)

    $cmbRange = New-Object System.Windows.Forms.ComboBox
    $cmbRange.DropDownStyle = 'DropDownList'
    $cmbRange.Items.AddRange(@('Last 6 hours', 'Last 24 hours', 'Last 7 days'))
    $cmbRange.SelectedIndex = 1
    $cmbRange.Location = New-Object System.Drawing.Point(12, 35)
    $cmbRange.Size = New-Object System.Drawing.Size(140, 25)
    $viewer.Controls.Add($cmbRange)

    $list = New-Object System.Windows.Forms.ListView
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.Location = New-Object System.Drawing.Point(12, 70)
    $list.Size = New-Object System.Drawing.Size(940, 390)
    $list.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
    $list.ForeColor = [System.Drawing.Color]::White
    [void]$list.Columns.Add('Time', 140)
    [void]$list.Columns.Add('Level', 70)
    [void]$list.Columns.Add('Log', 90)
    [void]$list.Columns.Add('Id', 60)
    [void]$list.Columns.Add('Source', 160)
    [void]$list.Columns.Add('Message', 400)
    $viewer.Controls.Add($list)

    $Script:EventViewerRows = @()

    $loadEvents = {
        $list.Items.Clear()
        $hours = switch ($cmbRange.SelectedIndex) { 0 { 6 } 1 { 24 } default { 168 } }
        $rows = @(Get-ITToolkitRecentEvents -Hours $hours -MaxEvents 300)
        $Script:EventViewerRows = $rows
        foreach ($ev in $rows) {
            $msg = if ($ev.Message) { ($ev.Message -replace '\s+', ' ').Trim() } else { '' }
            if ($msg.Length -gt 180) { $msg = $msg.Substring(0, 180) + '...' }
            $item = New-Object System.Windows.Forms.ListViewItem($ev.TimeCreated.ToString('g'))
            [void]$item.SubItems.Add([string]$ev.LevelDisplayName)
            [void]$item.SubItems.Add([string]$ev.LogName)
            [void]$item.SubItems.Add([string]$ev.Id)
            [void]$item.SubItems.Add([string]$ev.ProviderName)
            [void]$item.SubItems.Add($msg)
            $item.Tag = $ev
            if ($ev.LevelDisplayName -eq 'Critical') { $item.ForeColor = [System.Drawing.Color]::OrangeRed }
            elseif ($ev.LevelDisplayName -eq 'Error') { $item.ForeColor = [System.Drawing.Color]::Salmon }
            [void]$list.Items.Add($item)
        }
        $lbl.Text = ("Showing {0} Critical/Error events ({1}). Double-click a row for full message." -f $rows.Count, $cmbRange.SelectedItem)
        [System.Windows.Forms.Application]::DoEvents()
    }

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"
    $btnRefresh.Location = New-Object System.Drawing.Point(165, 33)
    $btnRefresh.Size = New-Object System.Drawing.Size(90, 28)
    $btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnRefresh.ForeColor = [System.Drawing.Color]::White
    $btnRefresh.FlatStyle = 'Flat'
    $btnRefresh.Add_Click({ & $loadEvents })
    $viewer.Controls.Add($btnRefresh)

    $btnExport = New-Object System.Windows.Forms.Button
    $btnExport.Text = "Export CSV (Desktop)"
    $btnExport.Location = New-Object System.Drawing.Point(265, 33)
    $btnExport.Size = New-Object System.Drawing.Size(140, 28)
    $btnExport.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $btnExport.ForeColor = [System.Drawing.Color]::White
    $btnExport.FlatStyle = 'Flat'
    $btnExport.Add_Click({
        if (-not $Script:EventViewerRows -or $Script:EventViewerRows.Count -eq 0) { return }
        $desktop = (Get-ITToolkitOutputFolder)
        $out = Join-Path $desktop ("IT_EventView_{0}_{1:yyyyMMdd_HHmmss}.csv" -f $env:COMPUTERNAME, (Get-Date))
        $Script:EventViewerRows | Export-Csv -Path $out -NoTypeInformation -Encoding ASCII
        [System.Windows.Forms.MessageBox]::Show(("Saved {0}" -f $out), 'Export') | Out-Null
    })
    $viewer.Controls.Add($btnExport)

    $btnOpenEv = New-Object System.Windows.Forms.Button
    $btnOpenEv.Text = "Open Event Viewer"
    $btnOpenEv.Location = New-Object System.Drawing.Point(415, 33)
    $btnOpenEv.Size = New-Object System.Drawing.Size(130, 28)
    $btnOpenEv.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $btnOpenEv.ForeColor = [System.Drawing.Color]::White
    $btnOpenEv.FlatStyle = 'Flat'
    $btnOpenEv.Add_Click({ Start-Process eventvwr.msc | Out-Null })
    $viewer.Controls.Add($btnOpenEv)

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = "Copy Selected"
    $btnCopy.Location = New-Object System.Drawing.Point(555, 33)
    $btnCopy.Size = New-Object System.Drawing.Size(110, 28)
    $btnCopy.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $btnCopy.ForeColor = [System.Drawing.Color]::White
    $btnCopy.FlatStyle = 'Flat'
    $btnCopy.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { return }
        $ev = $list.SelectedItems[0].Tag
        $textOut = @"
Time: $($ev.TimeCreated)
Level: $($ev.LevelDisplayName)
Log: $($ev.LogName)
Id: $($ev.Id)
Source: $($ev.ProviderName)

$($ev.Message)
"@
        [System.Windows.Forms.Clipboard]::SetText($textOut)
        Write-GuiLog "Selected event copied to clipboard." "Lime"
    })
    $viewer.Controls.Add($btnCopy)

    $list.Add_DoubleClick({
        if ($list.SelectedItems.Count -eq 0) { return }
        $ev = $list.SelectedItems[0].Tag
        [System.Windows.Forms.MessageBox]::Show(
            [string]$ev.Message,
            ("{0} Id {1}" -f $ev.LevelDisplayName, $ev.Id),
            [System.Windows.Forms.MessageBoxButtons]::OK
        ) | Out-Null
    })

    & $loadEvents
    [void]$viewer.ShowDialog()
}

function Open-WindowsEventViewer {
    Write-GuiLog "Launching Windows Event Viewer..." "Cyan"
    Start-Process eventvwr.msc | Out-Null
}


function Run-BitLockerExtractor {
    Write-GuiLog "Querying BitLocker protection state..." "Cyan"
    # Prefer Get-BitLockerVolume (do not dump full recovery keys into the on-screen log)
    try {
        $desktop = (Get-ITToolkitOutputFolder)
        $volumes = Get-BitLockerVolume -ErrorAction Stop
        foreach ($vol in $volumes) {
            $protectors = @($vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
            if ($protectors.Count -gt 0) {
                $exportPath = Join-Path $desktop ("BitLocker_{0}_{1}.txt" -f $env:COMPUTERNAME, ($vol.MountPoint -replace '[:\\]', ''))
                $protectors | ForEach-Object {
                    "MountPoint=$($vol.MountPoint); ProtectorId=$($_.KeyProtectorId); RecoveryPassword=$($_.RecoveryPassword)"
                } | Set-Content -LiteralPath $exportPath -Encoding ASCII
                Write-GuiLog "Recovery key for $($vol.MountPoint) saved to: $exportPath" "Lime"
            } else {
                Write-GuiLog "No recovery-password protector on $($vol.MountPoint) (status: $($vol.VolumeStatus))." "Yellow"
            }
            [System.Windows.Forms.Application]::DoEvents()
        }
    } catch {
        Write-GuiLog "BitLocker query failed: $($_.Exception.Message)" "Red"
    }
}

# --- ADMIN & ACCOUNTS ---
function Run-AddAdmin {
    param([string]$Username, [bool]$IsAzureAD)
    if ([string]::IsNullOrWhiteSpace($Username)) { return }
    $TargetUser = $Username.Trim()
    if ($IsAzureAD) {
        # Entra ID format is AzureAD\user@domain.com (full UPN - keep the domain)
        if ($TargetUser -notmatch '(?i)^AzureAD\\') {
            $TargetUser = "AzureAD\$TargetUser"
        }
        if ($TargetUser -notmatch '@') {
            Write-GuiLog "Tip: Azure AD accounts usually need the full email/UPN (user@company.com)." "Yellow"
        }
    }

    # Resolve the Administrators group by SID so it works on non-English Windows too
    $adminGroup = 'Administrators'
    try { $adminGroup = (Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop).Name } catch { }

    try {
        Add-LocalGroupMember -Group $adminGroup -Member $TargetUser -ErrorAction Stop
        Write-GuiLog "Access assignment success: $TargetUser added to Local Administrators." "Lime"
        return
    } catch {
        if ($_.Exception.Message -match '(?i)already a member') {
            Write-GuiLog "$TargetUser is already a Local Administrator." "Yellow"
            return
        }
        Write-GuiLog ("Add-LocalGroupMember failed ({0}); trying net localgroup..." -f $_.Exception.Message) "Gray"
    }

    # Fallback: net.exe handles Azure AD accounts that PowerShell cannot resolve yet
    $out = & net.exe localgroup "$adminGroup" "$TargetUser" /add 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-GuiLog "Access assignment success: $TargetUser added to Local Administrators." "Lime"
    } elseif ("$out" -match '1378') {
        Write-GuiLog "$TargetUser is already a Local Administrator." "Yellow"
    } else {
        Write-GuiLog ("Failed to add {0} to Administrators: {1}" -f $TargetUser, (("$out" -replace '\s+', ' ').Trim())) "Red"
    }
}

function Run-RemoveProfile {
    param([string]$Username)
    if ([string]::IsNullOrWhiteSpace($Username)) {
        Write-GuiLog "Enter a username / profile folder name first." "Yellow"
        return
    }
    $name = $Username.Trim()
    if ($name -match '(?i)^(Default|Default User|Public|Administrator|All Users)$') {
        Write-GuiLog "Refusing to delete built-in profile '$name'." "Red"
        return
    }
    if ($name -ieq $env:USERNAME) {
        Write-GuiLog "Refusing to delete the profile you are currently running as." "Red"
        return
    }
    try {
        # Exact folder match only (plus "name.DOMAIN" style suffixes) - "john" no longer also hits "johnny".
        $esc = [regex]::Escape($name)
        $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
            Where-Object { -not $_.Special -and $_.LocalPath -match "\\$esc(\.[^\\]+)?$" })
        if ($profiles.Count -eq 0) {
            Write-GuiLog "No profile folder found matching '$name'." "Yellow"
            return
        }
        foreach ($prof in $profiles) {
            if ($prof.Loaded) {
                Write-GuiLog ("Skipped {0}: that user is currently signed in. Sign them out (or reboot) first." -f $prof.LocalPath) "Red"
                continue
            }
            Write-GuiLog ("Deleting profile {0} ..." -f $prof.LocalPath) "Yellow"
            [System.Windows.Forms.Application]::DoEvents()
            $prof | Remove-CimInstance -ErrorAction Stop
            Write-GuiLog ("Profile deleted: {0}" -f $prof.LocalPath) "Lime"
        }
    } catch {
        Write-GuiLog ("Profile delete failed: {0}" -f $_.Exception.Message) "Red"
    }
}


# =====================================================================
# QUICK CHECKS & EXTRA FIELD TOOLS
# =====================================================================

function Run-SystemInfo {
    Write-GuiLog "=== SYSTEM INFO ===" "Cyan"
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        $bios = Get-CimInstance Win32_BIOS
        $os = Get-CimInstance Win32_OperatingSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        Write-GuiLog ("Hostname: {0}" -f $env:COMPUTERNAME) "White"
        Write-GuiLog ("User: {0}" -f $env:USERNAME) "White"
        Write-GuiLog ("Manufacturer/Model: {0} / {1}" -f $cs.Manufacturer, $cs.Model) "White"
        Write-GuiLog ("Serial: {0}" -f $bios.SerialNumber) "White"
        Write-GuiLog ("OS: {0} (Build {1})" -f $os.Caption, $os.BuildNumber) "White"
        Write-GuiLog ("CPU: {0}" -f $cpu.Name) "White"
        Write-GuiLog ("RAM: {0} GB" -f [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)) "White"
        $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' })
        if ($ips.Count -eq 0) {
            Write-GuiLog "IPv4: (none found)" "Yellow"
        } else {
            foreach ($ip in $ips) {
                Write-GuiLog ("IPv4: {0} ({1})" -f $ip.IPAddress, $ip.InterfaceAlias) "White"
            }
        }
        Write-GuiLog ("Domain/Workgroup: {0}" -f $cs.Domain) "White"

        # Also place a ticket-friendly summary on the clipboard
        $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } | ForEach-Object { $_.IPAddress })
        $clip = @"
Hostname: $env:COMPUTERNAME
User: $env:USERNAME
Manufacturer: $($cs.Manufacturer)
Model: $($cs.Model)
Serial: $($bios.SerialNumber)
OS: $($os.Caption) Build $($os.BuildNumber)
Domain: $($cs.Domain)
IPv4: $($ips -join ', ')
Collected: $(Get-Date -Format o)
"@
        try {
            [System.Windows.Forms.Clipboard]::SetText($clip)
            Write-GuiLog "System info also copied to clipboard." "Lime"
        } catch {
            Write-GuiLog "Could not copy system info to clipboard." "Yellow"
        }
    } catch {
        Write-GuiLog ("System info failed: {0}" -f $_.Exception.Message) "Red"
    }
}

function Test-ITToolkitPendingReboot {
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS RebootPending' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'WU RebootRequired' }
    try {
        $pfro = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($pfro -and $pfro.PendingFileRenameOperations) { $reasons += 'PendingFileRenameOperations' }
    } catch { }
    return $reasons
}

function Run-PendingRebootCheck {
    Write-GuiLog "=== PENDING REBOOT CHECK ===" "Cyan"
    $reasons = @(Test-ITToolkitPendingReboot)
    if ($reasons.Count -eq 0) {
        Write-GuiLog "No pending reboot flags detected." "Lime"
    } else {
        Write-GuiLog "Reboot IS pending:" "Yellow"
        foreach ($r in $reasons) { Write-GuiLog (" - {0}" -f $r) "Yellow" }
    }
}

function Run-FlushDns {
    Write-GuiLog "Flushing DNS resolver cache..." "Yellow"
    try {
        Clear-DnsClientCache -ErrorAction Stop
        Write-GuiLog "DNS cache cleared." "Lime"
    } catch {
        $p = Start-Process -FilePath 'ipconfig.exe' -ArgumentList '/flushdns' -NoNewWindow -PassThru -Wait
        if ($p.ExitCode -eq 0) { Write-GuiLog "DNS cache cleared (ipconfig)." "Lime" }
        else { Write-GuiLog "DNS flush may have failed." "Yellow" }
    }
}

function Run-ClearTempFiles {
    if (-not (Confirm-DestructiveAction -Title "Clear Temp Files" -Message "Delete files from the current user TEMP folder and C:\Windows\Temp? Open/locked files will be skipped.")) {
        Write-GuiLog "Temp cleanup canceled." "Yellow"
        return
    }
    Write-GuiLog "Clearing temporary files..." "Yellow"
    $targets = @($env:TEMP, $env:TMP, 'C:\Windows\Temp') | Where-Object { $_ } | Select-Object -Unique
    $freed = 0L
    $removed = 0
    foreach ($dir in $targets) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Write-GuiLog ("Scanning {0} ..." -f $dir) "Gray"
        Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $len = 0L
                if (-not $_.PSIsContainer) { $len = [int64]$_.Length }
                else {
                    $len = [int64]((Get-ChildItem -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)
                }
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                $freed += $len
                $removed++
            } catch { }
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    Write-GuiLog ("Temp cleanup done. Removed ~{0} items, ~{1} MB." -f $removed, [math]::Round($freed / 1MB, 1)) "Lime"
}

function Run-RestartExplorer {
    Write-GuiLog "Restarting Windows Explorer..." "Yellow"
    try {
        Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
        Start-Process explorer.exe | Out-Null
        Write-GuiLog "Explorer restarted." "Lime"
    } catch {
        Write-GuiLog ("Explorer restart failed: {0}" -f $_.Exception.Message) "Red"
    }
}

function Run-SaveGuiLog {
    $desktop = (Get-ITToolkitOutputFolder)
    $out = Join-Path $desktop ("ITToolkit_Log_{0}_{1:yyyyMMdd_HHmmss}.txt" -f $env:COMPUTERNAME, (Get-Date))
    try {
        $lines = @()
        if ($Script:GuiLogLines -and $Script:GuiLogLines.Count -gt 0) { $lines = @($Script:GuiLogLines) }
        elseif ($Script:LogBox) { $lines = @($Script:LogBox.Lines) }
        if ($lines.Count -eq 0) {
            Write-GuiLog "Nothing to save yet." "Yellow"
            return
        }
        Set-Content -LiteralPath $out -Value $lines -Encoding ASCII
        Write-GuiLog ("GUI log saved to: {0}" -f $out) "Lime"
    } catch {
        Write-GuiLog ("Save log failed: {0}" -f $_.Exception.Message) "Red"
    }
}

function Run-PrinterStatus {
    Write-GuiLog "=== PRINTER STATUS ===" "Cyan"
    try {
        $printers = @(Get-Printer -ErrorAction Stop)
        if ($printers.Count -eq 0) {
            Write-GuiLog "No printers found." "Yellow"
            return
        }
        foreach ($p in $printers) {
            $jobs = 0
            try { $jobs = @(Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue).Count } catch { }
            Write-GuiLog ("{0} | Status={1} | Default={2} | Jobs={3}" -f $p.Name, $p.PrinterStatus, $p.Default, $jobs) "White"
        }
    } catch {
        Write-GuiLog ("Printer query failed: {0}" -f $_.Exception.Message) "Red"
    }
}

function Run-ClearPrintQueue {
    if (-not (Confirm-DestructiveAction -Title "Clear Print Queue" -Message "Clear ALL queued print jobs on this PC?")) {
        Write-GuiLog "Print queue clear canceled." "Yellow"
        return
    }
    Write-GuiLog "Clearing print queues..." "Yellow"
    try {
        Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
        $spool = 'C:\Windows\System32\spool\PRINTERS'
        if (Test-Path $spool) {
            Get-ChildItem -LiteralPath $spool -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        Start-Service -Name Spooler -ErrorAction SilentlyContinue
        Write-GuiLog "Print spooler cleared and restarted." "Lime"
    } catch {
        Write-GuiLog ("Print queue clear failed: {0}" -f $_.Exception.Message) "Red"
        Start-Service -Name Spooler -ErrorAction SilentlyContinue
    }
}

function Run-BatteryReport {
    # Live status first, then optional HTML report
    Run-BatteryAcStatus
    Write-GuiLog "Generating battery report..." "Yellow"
    $desktop = (Get-ITToolkitOutputFolder)
    $out = Join-Path $desktop ("BatteryReport_{0}_{1:yyyyMMdd_HHmmss}.html" -f $env:COMPUTERNAME, (Get-Date))
    try {
        $batt = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
        if ($batt.Count -eq 0) {
            Write-GuiLog "No battery detected (desktop or battery WMI unavailable)." "Yellow"
            return
        }
        & powercfg.exe /batteryreport /output $out | Out-Null
        if (Test-Path -LiteralPath $out) {
            Write-GuiLog ("Battery report saved to: {0}" -f $out) "Lime"
            Start-Process $out | Out-Null
        } else {
            Write-GuiLog "Battery report was not created." "Yellow"
        }
    } catch {
        Write-GuiLog ("Battery report failed: {0}" -f $_.Exception.Message) "Red"
    }
}

function Run-TimeSync {
    Write-GuiLog "Forcing Windows time sync..." "Yellow"
    try {
        $p = Start-Process -FilePath 'w32tm.exe' -ArgumentList '/resync', '/force' -NoNewWindow -PassThru -Wait
        if ($p.ExitCode -eq 0) { Write-GuiLog "Time sync requested successfully." "Lime" }
        else { Write-GuiLog ("w32tm exit code: {0} (service may need a moment)." -f $p.ExitCode) "Yellow" }
        $status = & w32tm.exe /query /status 2>$null
        foreach ($line in ($status | Select-Object -First 6)) {
            if ($line) { Write-GuiLog $line.Trim() "Gray" }
        }
    } catch {
        Write-GuiLog ("Time sync failed: {0}" -f $_.Exception.Message) "Red"
    }
}

function Run-TpmSecureBootCheck {
    Write-GuiLog "=== TPM / SECURE BOOT ===" "Cyan"
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        Write-GuiLog ("TPM Present={0} Ready={1} Enabled={2} Activated={3}" -f $tpm.TpmPresent, $tpm.TpmReady, $tpm.TpmEnabled, $tpm.TpmActivated) "White"
    } catch {
        Write-GuiLog ("TPM query failed: {0}" -f $_.Exception.Message) "Yellow"
    }
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction Stop
        Write-GuiLog ("Secure Boot enabled: {0}" -f $sb) "White"
    } catch {
        Write-GuiLog ("Secure Boot check unavailable: {0}" -f $_.Exception.Message) "Yellow"
    }
}

function Run-DsregStatus {
    Write-GuiLog "=== AZURE AD / DSREG STATUS ===" "Cyan"
    try {
        $raw = & dsregcmd.exe /status 2>$null
        $keys = @(
            'AzureAdJoined',
            'EnterpriseJoined',
            'DomainJoined',
            'WorkplaceJoined',
            'DeviceId',
            'TenantName',
            'TenantId',
            'DeviceAuthStatus',
            'UserEmail',
            'WamAccount'
        )
        foreach ($line in $raw) {
            $trim = $line.Trim()
            foreach ($k in $keys) {
                if ($trim -like ("{0} :*" -f $k) -or $trim -like ("{0}:*" -f $k) -or $trim -match ("^\s*{0}\s*:" -f [regex]::Escape($k))) {
                    Write-GuiLog $trim "White"
                }
            }
        }
        Write-GuiLog "Tip: full detail available via dsregcmd /status in an elevated prompt." "Gray"
    } catch {
        Write-GuiLog ("dsregcmd failed: {0}" -f $_.Exception.Message) "Red"
    }
}

function Run-DiskHealthCheck {
    Write-GuiLog "=== DISK HEALTH / FREE SPACE ===" "Cyan"
    try {
        Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
            Write-GuiLog ("Disk {0}: {1} | Health={2} | Size={3} GB" -f $_.DeviceId, $_.FriendlyName, $_.HealthStatus, [math]::Round($_.Size / 1GB, 1)) "White"
        }
    } catch {
        Write-GuiLog "Physical disk health query unavailable." "Yellow"
    }
    try {
        Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object {
            $free = [math]::Round(($_.SizeRemaining / 1GB), 1)
            $size = [math]::Round(($_.Size / 1GB), 1)
            $pct = if ($_.Size -gt 0) { [math]::Round(($_.SizeRemaining / $_.Size) * 100, 0) } else { 0 }
            $color = if ($pct -lt 10) { 'Red' } elseif ($pct -lt 20) { 'Yellow' } else { 'White' }
            Write-GuiLog ("Volume {0}: {1} GB free of {2} GB ({3}%)" -f $_.DriveLetter, $free, $size, $pct) $color
        }
    } catch {
        Write-GuiLog ("Volume query failed: {0}" -f $_.Exception.Message) "Red"
    }
}

function Run-LocalAdminInventory {
    Write-GuiLog "=== LOCAL ADMIN / RDU INVENTORY ===" "Cyan"
    foreach ($group in @('Administrators', 'Remote Desktop Users')) {
        Write-GuiLog ("Group: {0}" -f $group) "Cyan"
        try {
            $members = @(Get-LocalGroupMember -Group $group -ErrorAction Stop)
            if ($members.Count -eq 0) { Write-GuiLog " (empty)" "Gray"; continue }
            foreach ($m in $members) {
                Write-GuiLog (" - {0} [{1}]" -f $m.Name, $m.ObjectClass) "White"
            }
        } catch {
            Write-GuiLog (" Could not read {0}: {1}" -f $group, $_.Exception.Message) "Yellow"
        }
    }
}

function Run-WingetOutdatedPreview {
    Write-GuiLog "=== WINGET OUTDATED APPS (PREVIEW) ===" "Cyan"
    Write-GuiLog "Listing upgrades only - nothing will be installed." "Gray"
    try {
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $winget) {
            Write-GuiLog "winget.exe not found on this PC." "Yellow"
            return
        }
        $output = & winget.exe upgrade --accept-source-agreements 2>&1
        foreach ($line in $output) {
            $s = "$line".TrimEnd()
            if ($s) { Write-GuiLog $s "White" }
            [System.Windows.Forms.Application]::DoEvents()
        }
        Write-GuiLog "Preview complete. Use Run Master Update to apply winget upgrades." "Lime"
    } catch {
        Write-GuiLog ("winget preview failed: {0}" -f $_.Exception.Message) "Red"
    }
}

function Run-AllQuickChecks {
    Write-GuiLog "=== RUNNING ALL READ-ONLY QUICK CHECKS ===" "Cyan"
    Run-SystemInfo
    Run-WhoIsLoggedOn
    Run-PendingRebootCheck
    Run-WindowsActivationStatus
    Run-DsregStatus
    Run-TpmSecureBootCheck
    Run-CertificateQuickView
    Run-ProxyWpadCheck
    Run-StartupAppsSummary
    Run-DefaultAppsQuickView
    Run-PrinterStatus
    Run-DiskHealthCheck
    Run-DiskPredictiveFailure
    Run-BatteryAcStatus
    Run-DisplayScalingInfo
    Run-UsbDeviceList
    Run-ProblemDevices
    Run-DellInfo -SkipScan
    Write-GuiLog "=== QUICK CHECKS COMPLETE ===" "Lime"
}



# =====================================================================
# MORE FIELD TOOLS
# =====================================================================

function Confirm-TypeYes {
    param([string]$Title, [string]$Message)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.Size = New-Object System.Drawing.Size(460, 200)
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Message + "`r`n`r`nType YES to confirm:"
    $lbl.ForeColor = [System.Drawing.Color]::White
    $lbl.Location = New-Object System.Drawing.Point(15, 15)
    $lbl.Size = New-Object System.Drawing.Size(410, 70)
    $f.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(15, 95)
    $txt.Size = New-Object System.Drawing.Size(200, 25)
    $f.Controls.Add($txt)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Confirm'
    $ok.Location = New-Object System.Drawing.Point(230, 93)
    $ok.Size = New-Object System.Drawing.Size(90, 28)
    $ok.BackColor = [System.Drawing.Color]::FromArgb(204, 0, 0)
    $ok.ForeColor = [System.Drawing.Color]::White
    $ok.FlatStyle = 'Flat'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $f.Controls.Add($ok)
    $f.AcceptButton = $ok

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(330, 93)
    $cancel.Size = New-Object System.Drawing.Size(90, 28)
    $cancel.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $cancel.ForeColor = [System.Drawing.Color]::White
    $cancel.FlatStyle = 'Flat'
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $f.Controls.Add($cancel)
    $f.CancelButton = $cancel

    if ($f.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $false }
    return ($txt.Text.Trim().ToUpperInvariant() -eq 'YES')
}

function Run-CopySystemInfoClipboard {
    Write-GuiLog "Building system info for clipboard..." "Cyan"
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        $bios = Get-CimInstance Win32_BIOS
        $os = Get-CimInstance Win32_OperatingSystem
        $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } | ForEach-Object { $_.IPAddress })
        $textOut = @"
Hostname: $env:COMPUTERNAME
User: $env:USERNAME
Manufacturer: $($cs.Manufacturer)
Model: $($cs.Model)
Serial: $($bios.SerialNumber)
OS: $($os.Caption) Build $($os.BuildNumber)
Domain: $($cs.Domain)
IPv4: $($ips -join ', ')
Collected: $(Get-Date -Format o)
"@
        [System.Windows.Forms.Clipboard]::SetText($textOut)
        Write-GuiLog "System info copied to clipboard." "Lime"
    } catch {
        Write-GuiLog ("Copy system info failed: {0}" -f $_.Exception.Message) "Red"
    }
}

function Run-WhoIsLoggedOn {
    Write-GuiLog "=== WHO IS LOGGED ON ===" "Cyan"
    try {
        $sessions = @(quser 2>$null)
        if ($sessions.Count -gt 0) {
            foreach ($line in $sessions) { Write-GuiLog $line.TrimEnd() "White" }
        } else {
            Write-GuiLog "quser returned no sessions; falling back to explorer processes." "Yellow"
        }
    } catch { }

    try {
        Get-CimInstance Win32_LoggedOnUser -ErrorAction SilentlyContinue |
            ForEach-Object {
                $p = $_.Antecedent
                if ($p -match 'Domain="([^"]+)".*Name="([^"]+)"') {
                    "{0}\{1}" -f $Matches[1], $Matches[2]
                }
            } | Select-Object -Unique | ForEach-Object {
                Write-GuiLog ("LoggedOnUser ref: {0}" -f $_) "Gray"
            }
    } catch { }

    try {
        Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty UserName -Unique |
            ForEach-Object { Write-GuiLog ("Explorer session user: {0}" -f $_) "White" }
    } catch {
        Write-GuiLog "Could not read explorer usernames (permissions)." "Yellow"
    }
}

function Run-StartupAppsSummary {
    Write-GuiLog "=== STARTUP APPS SUMMARY ===" "Cyan"
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($p in $paths) {
        Write-GuiLog ("[{0}]" -f $p) "Cyan"
        try {
            $props = Get-ItemProperty -Path $p -ErrorAction Stop
            $props.PSObject.Properties |
                Where-Object { $_.Name -notmatch '^PS' } |
                ForEach-Object { Write-GuiLog (" - {0} = {1}" -f $_.Name, $_.Value) "White" }
        } catch {
            Write-GuiLog " (none / inaccessible)" "Gray"
        }
    }
    try {
        $startupFolder = [Environment]::GetFolderPath('Startup')
        Write-GuiLog ("Startup folder: {0}" -f $startupFolder) "Cyan"
        Get-ChildItem -LiteralPath $startupFolder -ErrorAction SilentlyContinue | ForEach-Object {
            Write-GuiLog (" - {0}" -f $_.Name) "White"
        }
    } catch { }
}

function Run-WindowsActivationStatus {
    Write-GuiLog "=== WINDOWS ACTIVATION ===" "Cyan"
    try {
        $lic = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop |
            Select-Object -First 1
        if ($lic) {
            $map = @{ 0='Unlicensed'; 1='Licensed'; 2='OOBGrace'; 3='OOTGrace'; 4='NonGenuineGrace'; 5='Notification'; 6='ExtendedGrace' }
            $name = if ($map.ContainsKey([int]$lic.LicenseStatus)) { $map[[int]$lic.LicenseStatus] } else { [string]$lic.LicenseStatus }
            Write-GuiLog ("LicenseStatus: {0} ({1})" -f $name, $lic.LicenseStatus) "White"
            Write-GuiLog ("Description: {0}" -f $lic.Description) "Gray"
            Write-GuiLog ("PartialProductKey: {0}" -f $lic.PartialProductKey) "Gray"
        } else {
            Write-GuiLog "No licensing product with a partial key found." "Yellow"
        }
    } catch {
        Write-GuiLog ("Activation query failed: {0}" -f $_.Exception.Message) "Red"
    }
    try {
        $slmgr = & cscript.exe //Nologo "$env:SystemRoot\System32\slmgr.vbs" /xpr 2>&1
        foreach ($line in $slmgr) { if ("$line".Trim()) { Write-GuiLog ("slmgr: {0}" -f "$line".Trim()) "White" } }
    } catch { }
}

function Run-DefaultAppsQuickView {
    Write-GuiLog "=== DEFAULT APPS / ASSOCIATIONS (QUICK) ===" "Cyan"
    try {
        $http = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice' -ErrorAction SilentlyContinue).ProgId
        $https = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction SilentlyContinue).ProgId
        $pdf = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.pdf\UserChoice' -ErrorAction SilentlyContinue).ProgId
        Write-GuiLog ("HTTP handler ProgId: {0}" -f $(if ($http) { $http } else { '(not set)' })) "White"
        Write-GuiLog ("HTTPS handler ProgId: {0}" -f $(if ($https) { $https } else { '(not set)' })) "White"
        Write-GuiLog ("PDF handler ProgId: {0}" -f $(if ($pdf) { $pdf } else { '(not set)' })) "White"
        Write-GuiLog "Tip: change defaults in Windows Settings > Apps > Default apps." "Gray"
    } catch {
        Write-GuiLog ("Default apps query failed: {0}" -f $_.Exception.Message) "Red"
    }
}

function Run-ExportMappedDrivesPrinters {
    Write-GuiLog "Exporting mapped drives and printers..." "Yellow"
    $desktop = (Get-ITToolkitOutputFolder)
    $out = Join-Path $desktop ("MappedDrivesPrinters_{0}_{1:yyyyMMdd_HHmmss}.txt" -f $env:COMPUTERNAME, (Get-Date))
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("=== Mapped Drives ===") | Out-Null
    try {
        Get-PSDrive -PSProvider FileSystem | Where-Object { $_.DisplayRoot } | ForEach-Object {
            $lines.Add(("{0}: => {1}" -f $_.Name, $_.DisplayRoot)) | Out-Null
        }
    } catch { $lines.Add('(failed to query drives)') | Out-Null }
    $lines.Add('') | Out-Null
    $lines.Add('=== Printers ===') | Out-Null
    try {
        Get-Printer -ErrorAction Stop | ForEach-Object {
            $lines.Add(("{0} | Port={1} | Driver={2} | Default={3}" -f $_.Name, $_.PortName, $_.DriverName, $_.Default)) | Out-Null
        }
    } catch { $lines.Add('(failed to query printers)') | Out-Null }
    Set-Content -LiteralPath $out -Value $lines -Encoding ASCII
    Write-GuiLog ("Saved snapshot: {0}" -f $out) "Lime"
}

function Run-ClearIconThumbnailCache {
    if (-not (Confirm-DestructiveAction -Title 'Clear Icon/Thumbnail Cache' -Message 'Stop Explorer briefly and clear icon/thumbnail caches?')) {
        Write-GuiLog 'Icon/thumbnail cache clear canceled.' 'Yellow'
        return
    }
    Write-GuiLog 'Clearing icon and thumbnail caches...' 'Yellow'
    try {
        Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 700
        $local = $env:LOCALAPPDATA
        $targets = @(
            (Join-Path $local 'Microsoft\Windows\Explorer'),
            (Join-Path $local 'IconCache.db')
        )
        foreach ($t in $targets) {
            if (Test-Path -LiteralPath $t) {
                if ((Get-Item -LiteralPath $t).PSIsContainer) {
                    Get-ChildItem -LiteralPath $t -Filter 'iconcache*' -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                    Get-ChildItem -LiteralPath $t -Filter 'thumbcache*' -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                } else {
                    Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue
                }
            }
        }
        Start-Process explorer.exe | Out-Null
        Write-GuiLog 'Icon/thumbnail caches cleared and Explorer restarted.' 'Lime'
    } catch {
        Write-GuiLog ("Cache clear failed: {0}" -f $_.Exception.Message) 'Red'
        Start-Process explorer.exe -ErrorAction SilentlyContinue | Out-Null
    }
}

function Run-ResetStartSearch {
    if (-not (Confirm-DestructiveAction -Title 'Reset Start/Search' -Message 'Restart Start Menu / Search related processes and re-register shell experiences?')) {
        Write-GuiLog 'Start/Search reset canceled.' 'Yellow'
        return
    }
    Write-GuiLog 'Resetting Start Menu / Search experiences...' 'Yellow'
    try {
        Get-Process SearchApp, SearchHost, StartMenuExperienceHost, ShellExperienceHost -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        $pkg = Get-AppxPackage -Name Microsoft.Windows.ShellExperienceHost -ErrorAction SilentlyContinue
        if ($pkg) {
            Add-AppxPackage -DisableDevelopmentMode -Register "$($pkg.InstallLocation)\AppXManifest.xml" -ErrorAction SilentlyContinue
        }
        Write-GuiLog 'Start/Search processes restarted (best effort).' 'Lime'
    } catch {
        Write-GuiLog ("Start/Search reset failed: {0}" -f $_.Exception.Message) 'Red'
    }
}

function Run-RestoreNormalPower {
    Write-GuiLog 'Restoring normal power/sleep behavior...' 'Yellow'
    try {
        [SystemSleep]::SetThreadExecutionState([SystemSleep]::ES_CONTINUOUS) | Out-Null
        Write-GuiLog 'Keep-awake cleared. Windows may sleep normally again.' 'Lime'
    } catch {
        Write-GuiLog ("Power restore failed: {0}" -f $_.Exception.Message) 'Red'
    }
}

function New-SupportZip {
    Write-GuiLog 'Building support ZIP...' 'Yellow'
    $desktop = (Get-ITToolkitOutputFolder)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $work = Join-Path $env:TEMP ("ITToolkitSupport_{0}" -f $stamp)
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        # system info
        Run-CopySystemInfoClipboard | Out-Null
        $infoPath = Join-Path $work 'systeminfo.txt'
        try { [System.Windows.Forms.Clipboard]::GetText() | Set-Content -LiteralPath $infoPath -Encoding ASCII } catch { 'clipboard unavailable' | Set-Content $infoPath }

        if ($Script:GuiLogLines -and $Script:GuiLogLines.Count -gt 0) {
            Set-Content -LiteralPath (Join-Path $work 'toolkit_gui.log') -Value @($Script:GuiLogLines) -Encoding ASCII
        }

        try {
            & dsregcmd.exe /status 2>$null | Set-Content -LiteralPath (Join-Path $work 'dsreg_status.txt') -Encoding ASCII
        } catch { }

        try {
            @(Get-ITToolkitRecentEvents -Hours 24 -MaxEvents 100) |
                Export-Csv -Path (Join-Path $work 'events_24h_critical_error.csv') -NoTypeInformation -Encoding ASCII
        } catch { }

        $zip = Join-Path $desktop ("ITToolkit_Support_{0}_{1}.zip" -f $env:COMPUTERNAME, $stamp)
        if (Test-Path $zip) { Remove-Item $zip -Force }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($work, $zip)
        Write-GuiLog ("Support ZIP saved to: {0}" -f $zip) 'Lime'
    } catch {
        Write-GuiLog ("Support ZIP failed: {0}" -f $_.Exception.Message) 'Red'
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Run-AutopilotEnrollmentHints {
    Write-GuiLog '=== AUTOPILOT / ESP HINTS ===' 'Cyan'
    try {
        $auto = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\AutoPilot' -ErrorAction SilentlyContinue
        if ($auto) {
            $auto.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                Write-GuiLog (" AutoPilot.{0}={1}" -f $_.Name, $_.Value) 'White'
            }
        } else {
            Write-GuiLog 'No AutoPilot diagnostics key found.' 'Yellow'
        }
    } catch { }

    foreach ($name in @('CompanyPortal', 'Microsoft.Management.Services.IntuneWindowsAgent', 'omadmclient')) {
        $proc = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($proc) { Write-GuiLog ("Process running: {0}" -f $name) 'Lime' }
        else { Write-GuiLog ("Process not running: {0}" -f $name) 'Gray' }
    }
    Run-DsregStatus
}

function Run-IntuneSyncStatus {
    Write-GuiLog 'Forcing Intune/MDM sync and checking scheduled tasks...' 'Cyan'
    Run-SyncPolicy
    try {
        Get-ScheduledTask | Where-Object { $_.TaskPath -match 'EnterpriseMgmt' } | ForEach-Object {
            $info = $_ | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
            Write-GuiLog ("Task {0} | LastRun={1} | LastResult={2}" -f $_.TaskName, $info.LastRunTime, $info.LastTaskResult) 'White'
        }
    } catch {
        Write-GuiLog ("Could not read EnterpriseMgmt tasks: {0}" -f $_.Exception.Message) 'Yellow'
    }
}

function Run-CertificateQuickView {
    Write-GuiLog '=== CERTIFICATE QUICK VIEW ===' 'Cyan'
    $stores = @(
        @{ Path = 'Cert:\LocalMachine\My'; Label = 'Computer Personal' },
        @{ Path = 'Cert:\CurrentUser\My'; Label = 'User Personal' }
    )
    foreach ($s in $stores) {
        Write-GuiLog ("[{0}]" -f $s.Label) 'Cyan'
        try {
            Get-ChildItem -Path $s.Path -ErrorAction Stop | Sort-Object NotAfter | Select-Object -First 15 | ForEach-Object {
                $days = [int]($_.NotAfter - (Get-Date)).TotalDays
                $color = if ($days -lt 0) { 'Red' } elseif ($days -lt 30) { 'Yellow' } else { 'White' }
                Write-GuiLog (" - {0} | Expires {1:d} ({2}d) | {3}" -f $_.Subject, $_.NotAfter, $days, $_.Thumbprint) $color
            }
        } catch {
            Write-GuiLog (' (inaccessible)') 'Gray'
        }
    }
}

function Run-VpnAdapterReset {
    if (-not (Confirm-DestructiveAction -Title 'VPN Adapter Reset' -Message 'Disable and re-enable VPN-related adapters? Active VPN sessions will drop.')) {
        Write-GuiLog 'VPN adapter reset canceled.' 'Yellow'
        return
    }
    Write-GuiLog 'Resetting VPN-related adapters...' 'Yellow'
    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
            $_.InterfaceDescription -match 'VPN|WAN Miniport|PANGP|Cisco|AnyConnect|GlobalProtect|WireGuard|Tunnel' -or
            $_.Name -match 'VPN|Tunnel'
        })
        if ($adapters.Count -eq 0) {
            Write-GuiLog 'No VPN-like adapters found.' 'Yellow'
            return
        }
        foreach ($a in $adapters) {
            Write-GuiLog ("Cycling {0} ({1})" -f $a.Name, $a.InterfaceDescription) 'White'
            Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
        }
        Write-GuiLog 'VPN adapter reset complete.' 'Lime'
    } catch {
        Write-GuiLog ("VPN reset failed: {0}" -f $_.Exception.Message) 'Red'
    }
}

function Run-ProxyWpadCheck {
    Write-GuiLog '=== PROXY / WPAD CHECK ===' 'Cyan'
    try {
        $inet = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        Write-GuiLog ("ProxyEnable: {0}" -f $inet.ProxyEnable) 'White'
        Write-GuiLog ("ProxyServer: {0}" -f $(if ($inet.ProxyServer) { $inet.ProxyServer } else { '(none)' })) 'White'
        Write-GuiLog ("ProxyOverride: {0}" -f $(if ($inet.ProxyOverride) { $inet.ProxyOverride } else { '(none)' })) 'White'
        Write-GuiLog ("AutoConfigURL: {0}" -f $(if ($inet.AutoConfigURL) { $inet.AutoConfigURL } else { '(none)' })) 'White'
        Write-GuiLog ("AutoDetect: {0}" -f $inet.AutoDetect) 'White'
    } catch {
        Write-GuiLog ("Proxy registry read failed: {0}" -f $_.Exception.Message) 'Red'
    }
    try {
        $winhttp = & netsh.exe winhttp show proxy 2>&1
        foreach ($line in $winhttp) { if ("$line".Trim()) { Write-GuiLog ("winhttp: {0}" -f "$line".Trim()) 'Gray' } }
    } catch { }
}

function Run-UsbDeviceList {
    Write-GuiLog '=== USB DEVICES ===' 'Cyan'
    try {
        Get-PnpDevice -Class USB -ErrorAction SilentlyContinue | Sort-Object Status, FriendlyName | ForEach-Object {
            $color = if ($_.Status -ne 'OK') { 'Yellow' } else { 'White' }
            Write-GuiLog (" [{0}] {1}" -f $_.Status, $_.FriendlyName) $color
        }
    } catch {
        Write-GuiLog ("USB list failed: {0}" -f $_.Exception.Message) 'Red'
    }
}

function Run-UsbDeviceResetProblem {
    if (-not (Confirm-DestructiveAction -Title 'Re-enable Problem USB Devices' -Message 'Disable then enable USB devices that are not Status=OK?')) {
        Write-GuiLog 'USB re-enable canceled.' 'Yellow'
        return
    }
    Write-GuiLog 'Re-enabling problem USB devices...' 'Yellow'
    try {
        $bad = @(Get-PnpDevice -Class USB -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' })
        if ($bad.Count -eq 0) { Write-GuiLog 'No problem USB devices found.' 'Lime'; return }
        foreach ($d in $bad) {
            Write-GuiLog ("Cycling: {0}" -f $d.FriendlyName) 'White'
            Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 800
            Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        }
        Write-GuiLog 'USB problem-device cycle complete.' 'Lime'
    } catch {
        Write-GuiLog ("USB reset failed: {0}" -f $_.Exception.Message) 'Red'
    }
}

function Run-AudioEndpointReset {
    Write-GuiLog 'Restarting Windows Audio services...' 'Yellow'
    try {
        foreach ($svc in @('Audiosrv', 'AudioEndpointBuilder')) {
            Restart-Service -Name $svc -Force -ErrorAction SilentlyContinue
            Write-GuiLog ("Restarted service: {0}" -f $svc) 'White'
        }
        Write-GuiLog 'Audio services restarted.' 'Lime'
    } catch {
        Write-GuiLog ("Audio reset failed: {0}" -f $_.Exception.Message) 'Red'
    }
}

function Run-DisplayScalingInfo {
    Write-GuiLog '=== DISPLAY / SCALING INFO ===' 'Cyan'
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $i = 0
        [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
            $i++
            Write-GuiLog ("Screen {0}: Primary={1} Bounds={2}x{3} WorkingArea={4}x{5} BitsPerPixel={6}" -f $i, $_.Primary, $_.Bounds.Width, $_.Bounds.Height, $_.WorkingArea.Width, $_.WorkingArea.Height, $_.BitsPerPixel) 'White'
        }
        $dpi = Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction SilentlyContinue
        if ($dpi) {
            $scale = [math]::Round(($dpi.AppliedDPI / 96) * 100)
            Write-GuiLog ("AppliedDPI registry: {0} (~{1}% scaling)" -f $dpi.AppliedDPI, $scale) 'White'
        }
    } catch {
        Write-GuiLog ("Display info failed: {0}" -f $_.Exception.Message) 'Red'
    }
}

function Run-BatteryAcStatus {
    Write-GuiLog '=== BATTERY / AC STATUS ===' 'Cyan'
    try {
        $power = [System.Windows.Forms.SystemInformation]::PowerStatus
        Write-GuiLog ("AC line: {0}" -f $power.PowerLineStatus) 'White'
        Write-GuiLog ("Battery charge status: {0}" -f $power.BatteryChargeStatus) 'White'
        if ($power.BatteryLifePercent -ge 0 -and $power.BatteryLifePercent -le 1) {
            Write-GuiLog ("Battery life percent: {0}%" -f [math]::Round($power.BatteryLifePercent * 100)) 'White'
        }
        if ($power.BatteryLifeRemaining -ge 0) {
            Write-GuiLog ("Battery life remaining (sec): {0}" -f $power.BatteryLifeRemaining) 'Gray'
        }
    } catch {
        Write-GuiLog ("PowerStatus query failed: {0}" -f $_.Exception.Message) 'Yellow'
    }
    try {
        $batt = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
        if ($batt.Count -eq 0) {
            Write-GuiLog 'No Win32_Battery instance (likely a desktop).' 'Gray'
            return
        }
        foreach ($b in $batt) {
            Write-GuiLog ("WMI EstimatedChargeRemaining: {0}%" -f $b.EstimatedChargeRemaining) 'White'
            Write-GuiLog ("WMI BatteryStatus code: {0}" -f $b.BatteryStatus) 'Gray'
        }
    } catch {
        Write-GuiLog ("Battery WMI failed: {0}" -f $_.Exception.Message) 'Red'
    }
}

function Run-DiskPredictiveFailure {
    Write-GuiLog '=== DISK PREDICTIVE FAILURE ===' 'Cyan'
    try {
        Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
            $health = $_.HealthStatus
            $op = $_.OperationalStatus
            $color = if ($health -ne 'Healthy') { 'Red' } else { 'Lime' }
            Write-GuiLog ("Disk {0} ({1}): Health={2} Operational={3}" -f $_.DeviceId, $_.FriendlyName, $health, $op) $color
            if ($health -ne 'Healthy') {
                Write-GuiLog ' >>> ACTION: Backup data and replace this disk soon.' 'Red'
            }
        }
        Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.PredictFailure) {
                Write-GuiLog ("SMART PredictFailure=TRUE Reason={0}" -f $_.Reason) 'Red'
            } else {
                Write-GuiLog 'SMART PredictFailure=FALSE' 'Lime'
            }
        }
    } catch {
        Write-GuiLog ("Predictive failure query failed: {0}" -f $_.Exception.Message) 'Yellow'
    }
}


# =====================================================================
# v3.0 FEATURES
# =====================================================================

# ---------------------------------------------------------------------
# SETTINGS FILE (Master_Toolkit_Settings.json next to the .bat)
# ---------------------------------------------------------------------
$Script:DefaultSettingsJson = @'
{
  "_help": "Edit values, save, then close Notepad to apply. Keys starting with _ are ignored. Find winget app IDs with: winget search <name>",
  "DefaultGroupTag": "",
  "ComputerNamePrefix": "",
  "TimeZone": "Central Standard Time",
  "PowerPlan": "Balanced",
  "SleepTimeoutACMinutes": 0,
  "MonitorTimeoutACMinutes": 30,
  "StandardApps": [],
  "_StandardAppsExample": ["Google.Chrome", "7zip.7zip", "Adobe.Acrobat.Reader.64-bit"],
  "NetworkTests": [
    { "Name": "Entra ID sign-in",      "Host": "login.microsoftonline.com",          "Port": 443 },
    { "Name": "Device registration",   "Host": "enterpriseregistration.windows.net", "Port": 443 },
    { "Name": "Intune enrollment",     "Host": "enrollment.manage.microsoft.com",    "Port": 443 },
    { "Name": "Windows Update",        "Host": "sls.update.microsoft.com",           "Port": 443 },
    { "Name": "Outlook / Exchange",    "Host": "outlook.office365.com",              "Port": 443 },
    { "Name": "Teams",                 "Host": "teams.microsoft.com",                "Port": 443 }
  ],
  "_NetworkTestsExample": { "Name": "Domain controller", "Host": "dc01.company.local", "Port": 389 },
  "TicketSignature": ""
}
'@

function Get-ITToolkitSettingsPath {
    $candidates = @()
    if ($Script:UsbPath) { $candidates += (Join-Path $Script:UsbPath $Script:SettingsFileName) }
    $candidates += (Join-Path $Script:StageRoot $Script:SettingsFileName)
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Import-ITToolkitSettings {
    $settings = $Script:DefaultSettingsJson | ConvertFrom-Json
    $path = Get-ITToolkitSettingsPath
    if ($path) {
        try {
            $user = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($p in $user.PSObject.Properties) {
                if ($p.Name -notlike '_*') {
                    $settings | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
                }
            }
            $Script:SettingsStatus = "Settings loaded from $path"
        } catch {
            $Script:SettingsStatus = "SETTINGS FILE ERROR ($path): $($_.Exception.Message) - using defaults."
        }
    } else {
        $Script:SettingsStatus = "No settings file yet - using defaults (click Settings, bottom-left, to create one)."
    }
    $Script:Settings = $settings
}

function Get-ITToolkitSetting {
    param([string]$Name, $Default = $null)
    if ($Script:Settings -and ($Script:Settings.PSObject.Properties.Name -contains $Name)) {
        $v = $Script:Settings.$Name
        if ($null -ne $v) { return $v }
    }
    return $Default
}

function Open-ITToolkitSettings {
    $path = Get-ITToolkitSettingsPath
    if (-not $path) {
        $dir = $Script:UsbPath
        if (-not $dir -or -not (Test-Path -LiteralPath $dir) -or $dir.StartsWith($Script:StageRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $dir = (Get-ITToolkitOutputFolder)
        }
        $path = Join-Path $dir $Script:SettingsFileName
        try {
            Set-Content -LiteralPath $path -Value $Script:DefaultSettingsJson -Encoding ASCII -ErrorAction Stop
            Write-GuiLog "Created settings file: $path" "Lime"
        } catch {
            Write-GuiLog ("Could not create settings file at {0}: {1}" -f $path, $_.Exception.Message) "Red"
            return
        }
    }
    if ($path.StartsWith($Script:StageRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-GuiLog "Note: editing the temporary copy (USB not found). Copy changes back to your USB to keep them." "Yellow"
    }
    Write-GuiLog "Opening settings in Notepad. Save and CLOSE Notepad to apply." "Cyan"
    $np = Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$path`"" -PassThru
    Wait-GuiProcess -Process $np
    Run-ReloadSettings
}

function Run-ReloadSettings {
    Import-ITToolkitSettings
    $color = if ($Script:SettingsStatus -match 'ERROR') { 'Red' } else { 'Lime' }
    Write-GuiLog $Script:SettingsStatus $color
    try { Update-ITToolkitSetupDefaults } catch { }
}

# ---------------------------------------------------------------------
# SESSION STATE (survives the update reboot so notes/report stay complete)
# ---------------------------------------------------------------------
function Save-ITToolkitSessionState {
    try {
        if (-not (Test-Path -LiteralPath $Script:StageRoot)) { New-Item -ItemType Directory -Path $Script:StageRoot -Force | Out-Null }
        [pscustomobject]@{
            SessionStart = $Script:SessionStart
            History      = $Script:ActionHistory.ToArray()
            Entries      = [object[]]($Script:GuiLogEntries.ToArray() | Select-Object -Last 1500)
            Baseline     = [object[]]@($Script:HealthBaseline | Where-Object { $_ })
        } | Export-Clixml -LiteralPath $Script:SessionFile -Depth 5 -Force
    } catch { }
}

function Restore-ITToolkitSessionState {
    if (-not (Test-Path -LiteralPath $Script:SessionFile)) { return }
    try {
        $s = Import-Clixml -LiteralPath $Script:SessionFile
        if ($s.SessionStart) { $Script:SessionStart = [datetime]$s.SessionStart }
        foreach ($h in @($s.History)) { if ($h) { $Script:ActionHistory.Add($h) | Out-Null } }
        foreach ($e in @($s.Entries)) {
            if ($e) {
                $Script:GuiLogEntries.Add($e) | Out-Null
                $Script:GuiLogLines.Add(("[{0:HH:mm:ss}] {1}" -f ([datetime]$e.Time), $e.Message)) | Out-Null
            }
        }
        $b = @($s.Baseline | Where-Object { $_ })
        if ($b.Count -gt 0) { $Script:HealthBaseline = $b }
        $Script:SessionRestoredCount = $Script:ActionHistory.Count
    } catch { }
}

# ---------------------------------------------------------------------
# SIGNED-IN USER HELPERS (fixes run against the USER, not the admin running the toolkit)
# ---------------------------------------------------------------------
function Get-ITToolkitConsoleUser {
    $name = $null
    $sid = $null
    try { $name = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName } catch { }
    if ($name) {
        try { $sid = ([System.Security.Principal.NTAccount]$name).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { }
    }
    if (-not $name -or -not $sid) {
        # RDP / Azure AD fallback: owner of explorer.exe
        try {
            $exp = Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1
            if ($exp) {
                $o = Invoke-CimMethod -InputObject $exp -MethodName GetOwner -ErrorAction Stop
                $os = Invoke-CimMethod -InputObject $exp -MethodName GetOwnerSid -ErrorAction Stop
                if (-not $name -and $o.User) { $name = "{0}\{1}" -f $o.Domain, $o.User }
                if (-not $sid -and $os.Sid) { $sid = $os.Sid }
            }
        } catch { }
    }
    if (-not $name) { return $null }
    $profilePath = $null
    if ($sid) {
        try { $profilePath = (Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$sid'" -ErrorAction Stop).LocalPath } catch { }
    }
    return [pscustomobject]@{
        Name        = $name
        Sid         = $sid
        ProfilePath = $profilePath
        IsSelf      = ($sid -and $sid -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    }
}

# Runs a program inside the signed-in user's session (non-elevated, as them) via a one-shot task.
function Invoke-ITToolkitAsUser {
    param(
        [string]$Execute,
        [string]$Argument = '',
        [int]$TimeoutSeconds = 120
    )
    $Script:UserTaskExitCode = $null
    $u = Get-ITToolkitConsoleUser
    if (-not $u) {
        Write-GuiLog "No signed-in user found - this fix must run while the user is logged on." "Red"
        return
    }
    $taskName = 'IT-Toolkit-UserTask-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        $action = if ($Argument) { New-ScheduledTaskAction -Execute $Execute -Argument $Argument } else { New-ScheduledTaskAction -Execute $Execute }
        $principal = New-ScheduledTaskPrincipal -UserId $u.Name -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        $start = Get-Date
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $done = $false
        while (-not $done -and $sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Milliseconds 300
            [System.Windows.Forms.Application]::DoEvents()
            $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $i = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
            if ($t -and $i -and $t.State -ne 'Running' -and $t.State -ne 'Queued' -and $i.LastRunTime -and $i.LastRunTime -ge $start.AddSeconds(-5)) {
                $done = $true
                $Script:UserTaskExitCode = $i.LastTaskResult
            }
        }
        if (-not $done) {
            Write-GuiLog ("User-context task did not finish within {0}s." -f $TimeoutSeconds) "Yellow"
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        }
    } catch {
        Write-GuiLog ("Could not run as {0}: {1}" -f $u.Name, $_.Exception.Message) "Red"
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Invoke-ITToolkitUserPowerShell {
    param([string]$Script, [int]$TimeoutSeconds = 120)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Invoke-ITToolkitAsUser -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $enc" -TimeoutSeconds $TimeoutSeconds
}

function Get-ITToolkitJoinState {
    $r = [pscustomobject]@{ AzureAdJoined = $false; DomainJoined = $false }
    try {
        foreach ($l in (& dsregcmd.exe /status 2>$null)) {
            if ($l -match '^\s*AzureAdJoined\s*:\s*YES') { $r.AzureAdJoined = $true }
            if ($l -match '^\s*DomainJoined\s*:\s*YES') { $r.DomainJoined = $true }
        }
    } catch { }
    return $r
}

# ---------------------------------------------------------------------
# #1 SCCM / CONFIGMGR CLIENT
# ---------------------------------------------------------------------
$Script:SccmSchedules = @{
    'Hardware Inventory'              = @('{00000000-0000-0000-0000-000000000001}')
    'Software Inventory'              = @('{00000000-0000-0000-0000-000000000002}')
    'Discovery Data Collection'       = @('{00000000-0000-0000-0000-000000000003}')
    'Machine Policy'                  = @('{00000000-0000-0000-0000-000000000021}', '{00000000-0000-0000-0000-000000000022}')
    'Software Update Deployment Eval' = @('{00000000-0000-0000-0000-000000000108}')
    'Software Update Scan'            = @('{00000000-0000-0000-0000-000000000113}')
    'Application Deployment Eval'     = @('{00000000-0000-0000-0000-000000000121}')
}

function Test-ITToolkitSccmClient {
    if (-not (Get-Service -Name CcmExec -ErrorAction SilentlyContinue)) {
        Write-GuiLog "SCCM client (CcmExec) is not installed on this PC." "Yellow"
        return $false
    }
    return $true
}

function Run-SccmClientStatus {
    Write-GuiLog "=== SCCM CLIENT STATUS ===" "Cyan"
    if (-not (Test-ITToolkitSccmClient)) { return }
    $svc = Get-Service -Name CcmExec
    Write-GuiLog ("CcmExec service: {0}" -f $svc.Status) $(if ($svc.Status -eq 'Running') { 'White' } else { 'Red' })
    try {
        $c = Get-CimInstance -Namespace root\ccm -ClassName SMS_Client -ErrorAction Stop
        Write-GuiLog ("Client version: {0}" -f $c.ClientVersion) "White"
    } catch { Write-GuiLog "Client WMI namespace not responding (root\ccm). Consider Repair Client." "Red" }
    try {
        $site = Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName GetAssignedSite -ErrorAction Stop
        Write-GuiLog ("Site code: {0}" -f $site.sSiteCode) "White"
    } catch { }
    try {
        $mp = Get-CimInstance -Namespace root\ccm -ClassName SMS_Authority -ErrorAction Stop | Select-Object -First 1
        Write-GuiLog ("Management point: {0}" -f $mp.CurrentManagementPoint) "White"
    } catch { }
    try {
        $id = Get-CimInstance -Namespace root\ccm -ClassName CCM_Client -ErrorAction Stop
        Write-GuiLog ("Client GUID: {0}" -f $id.ClientId) "Gray"
    } catch { }
    try {
        $hw = Get-CimInstance -Namespace root\ccm\invagt -ClassName InventoryActionStatus -Filter "InventoryActionID='{00000000-0000-0000-0000-000000000001}'" -ErrorAction Stop
        if ($hw) { Write-GuiLog ("Last hardware inventory: {0}" -f $hw.LastCycleStartedDate) "White" }
    } catch { }
    try {
        $flags = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\CCM' -Name CoManagementFlags -ErrorAction Stop).CoManagementFlags
        Write-GuiLog ("Co-management: ENABLED (CoManagementFlags = {0})" -f $flags) "White"
    } catch { Write-GuiLog "Co-management: not enabled (no CoManagementFlags)." "Gray" }
    try {
        $ui = New-Object -ComObject UIResource.UIResourceMgr
        $cache = $ui.GetCacheInfo()
        Write-GuiLog ("ccmcache: {0} MB total, {1} MB free, location {2}" -f $cache.TotalSize, $cache.FreeSize, $cache.Location) "White"
    } catch { }
}

function Invoke-ITToolkitSccmAction {
    param([string[]]$Names)
    if (-not (Test-ITToolkitSccmClient)) { return }
    foreach ($n in $Names) {
        foreach ($id in $Script:SccmSchedules[$n]) {
            try {
                Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = $id } -ErrorAction Stop | Out-Null
                Write-GuiLog ("Triggered: {0}" -f $n) "Lime"
            } catch {
                Write-GuiLog ("Failed to trigger {0}: {1}" -f $n, $_.Exception.Message) "Red"
            }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 300
        }
    }
}

function Run-SccmAllActions {
    Write-GuiLog "Triggering all SCCM client actions..." "Cyan"
    Invoke-ITToolkitSccmAction -Names @('Machine Policy', 'Hardware Inventory', 'Software Inventory', 'Discovery Data Collection', 'Software Update Scan', 'Software Update Deployment Eval', 'Application Deployment Eval')
    Write-GuiLog "All actions triggered. Results show in Software Center / CCM logs over the next few minutes." "Lime"
}

function Run-SccmRepair {
    if (-not (Test-ITToolkitSccmClient)) { return }
    $exe = Join-Path $env:SystemRoot 'CCM\ccmrepair.exe'
    if (-not (Test-Path -LiteralPath $exe)) { Write-GuiLog "ccmrepair.exe not found in C:\Windows\CCM." "Red"; return }
    if (-not (Confirm-DestructiveAction -Title "Repair SCCM Client" -Message "Run ccmrepair? The client is reinstalled in place and may be unavailable for 5-15 minutes.")) {
        Write-GuiLog "SCCM repair canceled." "Yellow"; return
    }
    $p = Start-Process -FilePath $exe -WindowStyle Hidden -PassThru
    Wait-GuiProcess -Process $p -HeartbeatLabel 'ccmrepair still running'
    Write-GuiLog "ccmrepair started. Progress: C:\Windows\CCM\Logs\ccmrepair.log (and ccmsetup.log)." "Lime"
}

function Run-SccmClearCache {
    if (-not (Test-ITToolkitSccmClient)) { return }
    try {
        $ui = New-Object -ComObject UIResource.UIResourceMgr
        $cache = $ui.GetCacheInfo()
        $elements = @($cache.GetCacheElements())
    } catch {
        Write-GuiLog ("Could not read ccmcache: {0}" -f $_.Exception.Message) "Red"; return
    }
    if ($elements.Count -eq 0) { Write-GuiLog "ccmcache is already empty." "Green"; return }
    $sizeMB = [math]::Round((($elements | Measure-Object -Property ContentSize -Sum).Sum) / 1024, 0)
    if (-not (Confirm-DestructiveAction -Title "Clear ccmcache" -Message ("Delete {0} cached package(s) (~{1} MB)? Content re-downloads if needed again." -f $elements.Count, $sizeMB))) {
        Write-GuiLog "ccmcache clear canceled." "Yellow"; return
    }
    $removed = 0
    foreach ($e in $elements) {
        try {
            try { $cache.DeleteCacheElementEx($e.CacheElementID, $true) } catch { $cache.DeleteCacheElement($e.CacheElementID) }
            $removed++
        } catch {
            Write-GuiLog ("Could not remove {0} (in use?)" -f $e.ContentID) "Yellow"
        }
        [System.Windows.Forms.Application]::DoEvents()
    }
    Write-GuiLog ("Cleared {0} of {1} cache item(s), ~{2} MB." -f $removed, $elements.Count, $sizeMB) "Lime"
}

function Open-SoftwareCenter {
    try { Start-Process 'softwarecenter:' -ErrorAction Stop; Write-GuiLog "Software Center opened." "Lime" }
    catch {
        $sc = Join-Path $env:SystemRoot 'CCM\ClientUX\SCClient.exe'
        if (Test-Path $sc) { Start-Process $sc; Write-GuiLog "Software Center opened." "Lime" }
        else { Write-GuiLog "Software Center not found." "Yellow" }
    }
}

function Open-SccmLogsFolder {
    $d = Join-Path $env:SystemRoot 'CCM\Logs'
    if (Test-Path $d) { Start-Process explorer.exe $d } else { Write-GuiLog "C:\Windows\CCM\Logs not found." "Yellow" }
}

# ---------------------------------------------------------------------
# #2 INTUNE / IME
# ---------------------------------------------------------------------
$Script:ImeLogDir = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs'

function Run-RestartIme {
    $svc = Get-Service -Name IntuneManagementExtension -ErrorAction SilentlyContinue
    if (-not $svc) { Write-GuiLog "Intune Management Extension is not installed (no Win32 apps/scripts assigned yet?)." "Yellow"; return }
    Write-GuiLog "Restarting Intune Management Extension..." "Yellow"
    try {
        Restart-Service -Name IntuneManagementExtension -Force -ErrorAction Stop
        Write-GuiLog "IME restarted - it re-checks Win32 apps and scripts within a few minutes." "Lime"
    } catch {
        Write-GuiLog ("IME restart failed: {0}" -f $_.Exception.Message) "Red"
    }
}

function Run-RetryFailedWin32Apps {
    $root = 'HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps'
    if (-not (Test-Path $root)) { Write-GuiLog "No Win32 app records on this PC." "Yellow"; return }
    Write-GuiLog "Looking for failed Win32 app installs..." "Cyan"
    $failed = @()
    foreach ($userKey in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
        if ($userKey.PSChildName -notmatch '^(S-1-|0{8}-)') { continue }
        foreach ($appKey in @(Get-ChildItem -Path $userKey.PSPath -ErrorAction SilentlyContinue)) {
            if ($appKey.PSChildName -notmatch '^[0-9a-fA-F-]{36}_\d+$') { continue }
            $json = $null
            $sub = Join-Path $appKey.PSPath 'EnforcementStateMessage'
            if (Test-Path $sub) { $json = (Get-ItemProperty -Path $sub -ErrorAction SilentlyContinue).EnforcementStateMessage }
            if (-not $json) { $json = (Get-ItemProperty -Path $appKey.PSPath -ErrorAction SilentlyContinue).EnforcementStateMessage }
            if (-not $json) { continue }
            try { $state = $json | ConvertFrom-Json } catch { continue }
            if ([int]$state.EnforcementState -ge 5000 -and [int]$state.EnforcementState -lt 6000) {
                $failed += [pscustomobject]@{
                    UserKey = $userKey.PSPath
                    User    = $userKey.PSChildName
                    AppKey  = $appKey.PSPath
                    AppId   = ($appKey.PSChildName -split '_')[0]
                    Error   = $state.ErrorCode
                }
            }
        }
    }
    if ($failed.Count -eq 0) {
        Write-GuiLog "No failed Win32 apps found in IME records." "Green"
        return
    }
    foreach ($f in $failed) {
        Write-GuiLog ("Failed app {0} (error {1}) for {2}" -f $f.AppId, $f.Error, $f.User) "Yellow"
    }
    if (-not (Confirm-DestructiveAction -Title "Retry Failed Win32 Apps" -Message ("Reset {0} failed app(s) so Intune retries them now? (Clears their failed state + retry timer, then restarts IME.)" -f $failed.Count))) {
        Write-GuiLog "Win32 retry canceled." "Yellow"; return
    }
    foreach ($f in $failed) {
        Remove-Item -Path $f.AppKey -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($uk in ($failed | Select-Object -ExpandProperty UserKey -Unique)) {
        $grs = Join-Path $uk 'GRS'
        if (Test-Path $grs) { Remove-Item -Path $grs -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-GuiLog ("Reset {0} app record(s) and retry timers." -f $failed.Count) "Lime"
    Run-RestartIme
    Write-GuiLog "Tip: look up the app IDs in Intune > Apps (the GUID is in the app's URL)." "Gray"
}

function Run-MdmDiagnostics {
    $exe = Join-Path $env:SystemRoot 'System32\MdmDiagnosticsTool.exe'
    if (-not (Test-Path $exe)) { Write-GuiLog "MdmDiagnosticsTool.exe not found on this Windows build." "Red"; return }
    $desktop = (Get-ITToolkitOutputFolder)
    $zip = Join-Path $desktop ("MDMDiag_{0}_{1:yyyyMMdd_HHmmss}.zip" -f $env:COMPUTERNAME, (Get-Date))
    Write-GuiLog "Collecting MDM diagnostics (Autopilot, enrollment, provisioning, TPM)..." "Yellow"
    $p = Start-Process -FilePath $exe -ArgumentList '-area', 'Autopilot;DeviceEnrollment;DeviceProvisioning;TPM', '-zip', "`"$zip`"" -WindowStyle Hidden -PassThru
    Wait-GuiProcess -Process $p -HeartbeatLabel 'MDM diagnostics still collecting' -HeartbeatSeconds 30
    if (Test-Path -LiteralPath $zip) {
        Write-GuiLog ("MDM diagnostics saved to: {0}" -f $zip) "Lime"
    } else {
        Write-GuiLog ("MDM diagnostics did not produce a file (exit {0})." -f $p.ExitCode) "Red"
    }
}

function Open-ImeLogsFolder {
    if (Test-Path $Script:ImeLogDir) { Start-Process explorer.exe $Script:ImeLogDir } else { Write-GuiLog "IME logs folder not found." "Yellow" }
}

# ---------------------------------------------------------------------
# CMTRACE-STYLE LOG VIEWER (IME + SCCM logs)
# ---------------------------------------------------------------------
function Read-ITToolkitCMLogTail {
    param([string]$Path, [int]$MaxBytes = 3MB)
    $text = ''
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite, Delete')
        $start = [Math]::Max(0, $fs.Length - $MaxBytes)
        [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
        $text = $sr.ReadToEnd()
    } finally {
        if ($fs) { $fs.Dispose() }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    $rx = [regex]'(?s)<!\[LOG\[(.*?)\]LOG\]!><time="([^"]*)" date="([^"]*)" component="([^"]*)"[^>]*?type="(\d)"'
    $matches2 = $rx.Matches($text)
    if ($matches2.Count -gt 0) {
        foreach ($m in $matches2) {
            $time = $m.Groups[2].Value
            if ($time.Length -gt 8) { $time = $time.Substring(0, 8) }
            $rows.Add([pscustomobject]@{
                When      = ("{0} {1}" -f $m.Groups[3].Value, $time)
                Type      = [int]$m.Groups[5].Value
                Component = $m.Groups[4].Value
                Message   = $m.Groups[1].Value.Trim()
            }) | Out-Null
        }
    } else {
        # Plain-text log: one row per line, flag obvious errors
        foreach ($line in ($text -split "`r?`n")) {
            if (-not $line.Trim()) { continue }
            $t = if ($line -match '(?i)\berror\b|fail') { 3 } elseif ($line -match '(?i)\bwarn') { 2 } else { 1 }
            $rows.Add([pscustomobject]@{ When = ''; Type = $t; Component = ''; Message = $line.Trim() }) | Out-Null
        }
    }
    return , $rows
}

function Show-ITToolkitLogViewer {
    param([ValidateSet('Intune', 'SCCM')][string]$Preset = 'Intune')

    $logFiles = New-Object System.Collections.Generic.List[object]
    $imeOrder = @('IntuneManagementExtension.log', 'AppWorkload.log', 'AgentExecutor.log', 'AppActionProcessor.log', 'HealthScripts.log', 'Win32AppInventory.log')
    $ccmOrder = @('AppEnforce.log', 'AppDiscovery.log', 'AppIntentEval.log', 'execmgr.log', 'CAS.log', 'ContentTransferManager.log', 'DataTransferService.log', 'PolicyAgent.log', 'UpdatesDeployment.log', 'UpdatesHandler.log', 'WUAHandler.log', 'ScanAgent.log', 'LocationServices.log', 'ClientIDManagerStartup.log', 'CcmExec.log', 'ccmsetup.log', 'ccmrepair.log', 'CoManagementHandler.log')
    $imeList = @(); $ccmList = @()
    foreach ($n in $imeOrder) { $f = Join-Path $Script:ImeLogDir $n; if (Test-Path $f) { $imeList += [pscustomobject]@{ Label = "Intune: $n"; Path = $f } } }
    $ccmDir = Join-Path $env:SystemRoot 'CCM\Logs'
    foreach ($n in $ccmOrder) {
        $f = Join-Path $ccmDir $n
        if ($n -eq 'ccmsetup.log') { $f = Join-Path $env:SystemRoot 'ccmsetup\Logs\ccmsetup.log' }
        if (Test-Path $f) { $ccmList += [pscustomobject]@{ Label = "SCCM: $n"; Path = $f } }
    }
    if ($Preset -eq 'SCCM') { $all = @($ccmList + $imeList) } else { $all = @($imeList + $ccmList) }
    if ($all.Count -eq 0) {
        Write-GuiLog "No Intune (IME) or SCCM logs found on this PC." "Yellow"
        return
    }
    foreach ($x in $all) { $logFiles.Add($x) | Out-Null }

    $viewer = New-Object System.Windows.Forms.Form
    $viewer.Text = "Log Viewer - Intune / SCCM"
    $viewer.Size = New-Object System.Drawing.Size(1100, 640)
    $viewer.StartPosition = "CenterScreen"
    $viewer.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)

    $cmbFile = New-Object System.Windows.Forms.ComboBox
    $cmbFile.DropDownStyle = 'DropDownList'
    $cmbFile.Location = New-Object System.Drawing.Point(12, 12)
    $cmbFile.Size = New-Object System.Drawing.Size(300, 25)
    foreach ($lf in $logFiles) { [void]$cmbFile.Items.Add($lf.Label) }
    $cmbFile.SelectedIndex = 0
    $viewer.Controls.Add($cmbFile)

    $chkErr = New-Object System.Windows.Forms.CheckBox
    $chkErr.Text = "Errors / warnings only"
    $chkErr.ForeColor = [System.Drawing.Color]::White
    $chkErr.Location = New-Object System.Drawing.Point(325, 14)
    $chkErr.AutoSize = $true
    $viewer.Controls.Add($chkErr)

    $lblFind = New-Object System.Windows.Forms.Label
    $lblFind.Text = "Find:"
    $lblFind.ForeColor = [System.Drawing.Color]::White
    $lblFind.Location = New-Object System.Drawing.Point(490, 16)
    $lblFind.AutoSize = $true
    $viewer.Controls.Add($lblFind)

    $txtFind = New-Object System.Windows.Forms.TextBox
    $txtFind.Location = New-Object System.Drawing.Point(530, 12)
    $txtFind.Size = New-Object System.Drawing.Size(200, 25)
    $viewer.Controls.Add($txtFind)

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.ForeColor = [System.Drawing.Color]::Gray
    $lblInfo.Location = New-Object System.Drawing.Point(12, 45)
    $lblInfo.Size = New-Object System.Drawing.Size(1060, 18)
    $viewer.Controls.Add($lblInfo)

    $list = New-Object System.Windows.Forms.ListView
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.Location = New-Object System.Drawing.Point(12, 68)
    $list.Size = New-Object System.Drawing.Size(1060, 520)
    $list.Anchor = 'Top, Bottom, Left, Right'
    $list.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
    $list.ForeColor = [System.Drawing.Color]::White
    [void]$list.Columns.Add('Date / Time', 140)
    [void]$list.Columns.Add('Type', 60)
    [void]$list.Columns.Add('Component', 150)
    [void]$list.Columns.Add('Message', 690)
    $viewer.Controls.Add($list)

    $Script:LogViewerRows = $null
    $render = {
        $list.BeginUpdate()
        $list.Items.Clear()
        $needle = $txtFind.Text.Trim()
        $shown = 0
        $rows = $Script:LogViewerRows
        if ($rows) {
            $start = [Math]::Max(0, $rows.Count - 4000)
            for ($i = $rows.Count - 1; $i -ge $start; $i--) {
                $r = $rows[$i]
                if ($chkErr.Checked -and $r.Type -lt 2) { continue }
                if ($needle -and $r.Message -notlike "*$needle*" -and $r.Component -notlike "*$needle*") { continue }
                $msg = ($r.Message -replace '\s+', ' ')
                if ($msg.Length -gt 400) { $msg = $msg.Substring(0, 400) + '...' }
                $item = New-Object System.Windows.Forms.ListViewItem($r.When)
                [void]$item.SubItems.Add($(switch ($r.Type) { 3 { 'Error' } 2 { 'Warning' } default { 'Info' } }))
                [void]$item.SubItems.Add($r.Component)
                [void]$item.SubItems.Add($msg)
                $item.Tag = $r
                if ($r.Type -eq 3) { $item.ForeColor = [System.Drawing.Color]::Salmon }
                elseif ($r.Type -eq 2) { $item.ForeColor = [System.Drawing.Color]::Gold }
                [void]$list.Items.Add($item)
                $shown++
                if ($shown -ge 2000) { break }
            }
        }
        $list.EndUpdate()
        $total = if ($rows) { $rows.Count } else { 0 }
        $errs = if ($rows) { @($rows | Where-Object { $_.Type -eq 3 }).Count } else { 0 }
        $lblInfo.Text = ("{0}  |  {1} entries read (newest first), {2} errors  |  showing {3}  |  double-click a row for full text" -f $logFiles[$cmbFile.SelectedIndex].Path, $total, $errs, $shown)
    }
    $load = {
        $viewer.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $Script:LogViewerRows = Read-ITToolkitCMLogTail -Path $logFiles[$cmbFile.SelectedIndex].Path
        } catch {
            $Script:LogViewerRows = $null
            $lblInfo.Text = "Could not read log: $($_.Exception.Message)"
        }
        $viewer.Cursor = [System.Windows.Forms.Cursors]::Default
        & $render
    }

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"
    $btnRefresh.Location = New-Object System.Drawing.Point(745, 10)
    $btnRefresh.Size = New-Object System.Drawing.Size(80, 27)
    $btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnRefresh.ForeColor = [System.Drawing.Color]::White
    $btnRefresh.FlatStyle = 'Flat'
    $btnRefresh.Add_Click({ & $load })
    $viewer.Controls.Add($btnRefresh)

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = "Copy Selected"
    $btnCopy.Location = New-Object System.Drawing.Point(835, 10)
    $btnCopy.Size = New-Object System.Drawing.Size(105, 27)
    $btnCopy.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $btnCopy.ForeColor = [System.Drawing.Color]::White
    $btnCopy.FlatStyle = 'Flat'
    $btnCopy.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { return }
        $out = foreach ($it in $list.SelectedItems) { $r = $it.Tag; "{0} [{1}] {2}: {3}" -f $r.When, $it.SubItems[1].Text, $r.Component, $r.Message }
        [System.Windows.Forms.Clipboard]::SetText(($out -join "`r`n"))
    })
    $viewer.Controls.Add($btnCopy)

    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text = "Open in CMTrace"
    $btnOpen.Location = New-Object System.Drawing.Point(950, 10)
    $btnOpen.Size = New-Object System.Drawing.Size(120, 27)
    $btnOpen.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $btnOpen.ForeColor = [System.Drawing.Color]::White
    $btnOpen.FlatStyle = 'Flat'
    $btnOpen.Add_Click({
        $path = $logFiles[$cmbFile.SelectedIndex].Path
        $cm = Join-Path $env:SystemRoot 'CCM\CMTrace.exe'
        if (Test-Path $cm) { Start-Process $cm -ArgumentList "`"$path`"" } else { Start-Process notepad.exe -ArgumentList "`"$path`"" }
    })
    $viewer.Controls.Add($btnOpen)

    $cmbFile.Add_SelectedIndexChanged({ & $load })
    $chkErr.Add_CheckedChanged({ & $render })
    $txtFind.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { & $render; $e.SuppressKeyPress = $true } })
    $list.Add_DoubleClick({
        if ($list.SelectedItems.Count -eq 0) { return }
        $r = $list.SelectedItems[0].Tag
        [System.Windows.Forms.MessageBox]::Show([string]$r.Message, ("{0} - {1}" -f $r.Component, $r.When)) | Out-Null
    })

    $viewer.Add_Shown({ & $load })
    [void]$viewer.ShowDialog()
    $viewer.Dispose()
}

# ---------------------------------------------------------------------
# #3 OFFICE 365 FIX PACK
# ---------------------------------------------------------------------
function Get-ITToolkitTargetUserOrStop {
    $u = Get-ITToolkitConsoleUser
    if (-not $u -or -not $u.ProfilePath) {
        Write-GuiLog "No signed-in user (or their profile) found. Have the user sign in first." "Red"
        return $null
    }
    Write-GuiLog ("Target user: {0} ({1})" -f $u.Name, $u.ProfilePath) "Gray"
    return $u
}

function Stop-ITToolkitApps {
    param([string[]]$Names)
    $hit = @(Get-Process -Name $Names -ErrorAction SilentlyContinue)
    if ($hit.Count -gt 0) {
        $hit | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-GuiLog ("Closed: {0}" -f (($hit | Select-Object -ExpandProperty ProcessName -Unique) -join ', ')) "Gray"
    }
}

function Run-ClearTeamsCache {
    $u = Get-ITToolkitTargetUserOrStop
    if (-not $u) { return }
    if (-not (Confirm-DestructiveAction -Title "Clear Teams Cache" -Message "Close Teams and clear its cache for $($u.Name)? Chats/files are NOT deleted (they live in the cloud).")) {
        Write-GuiLog "Teams cache clear canceled." "Yellow"; return
    }
    Stop-ITToolkitApps -Names @('ms-teams', 'Teams', 'ms-teamsupdate', 'msteamsupdate')
    $cleared = 0
    $newTeams = Join-Path $u.ProfilePath 'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams'
    if (Test-Path -LiteralPath $newTeams) {
        Get-ChildItem -LiteralPath $newTeams -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-GuiLog "New Teams cache cleared." "Lime"; $cleared++
    }
    $classic = Join-Path $u.ProfilePath 'AppData\Roaming\Microsoft\Teams'
    if (Test-Path -LiteralPath $classic) {
        foreach ($sub in @('Application Cache', 'blob_storage', 'Cache', 'Code Cache', 'databases', 'GPUCache', 'IndexedDB', 'Local Storage', 'Service Worker', 'tmp')) {
            $p = Join-Path $classic $sub
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Write-GuiLog "Classic Teams cache cleared." "Lime"; $cleared++
    }
    if ($cleared -eq 0) { Write-GuiLog "No Teams cache folders found for this user." "Yellow"; return }
    Write-GuiLog "Relaunching Teams for the user..." "Gray"
    Invoke-ITToolkitAsUser -Execute (Join-Path $env:SystemRoot 'explorer.exe') -Argument 'shell:AppsFolder\MSTeams_8wekyb3d8bbwe!MSTeams' -TimeoutSeconds 30
    Write-GuiLog "Teams cache reset complete. First launch may take a minute." "Lime"
}

function Run-ResetOneDrive {
    $u = Get-ITToolkitTargetUserOrStop
    if (-not $u) { return }
    $exe = @(
        (Join-Path $u.ProfilePath 'AppData\Local\Microsoft\OneDrive\OneDrive.exe'),
        "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe",
        "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $exe) { Write-GuiLog "OneDrive.exe not found for this user." "Red"; return }
    if (-not (Confirm-DestructiveAction -Title "Reset OneDrive" -Message "Reset OneDrive for $($u.Name)? No files are deleted, but OneDrive re-syncs all libraries (can take a while on big libraries).")) {
        Write-GuiLog "OneDrive reset canceled." "Yellow"; return
    }
    Write-GuiLog "Resetting OneDrive (as the user)..." "Yellow"
    Invoke-ITToolkitAsUser -Execute $exe -Argument '/reset' -TimeoutSeconds 120
    for ($i = 0; $i -lt 80; $i++) { Start-Sleep -Milliseconds 100; [System.Windows.Forms.Application]::DoEvents() }
    Invoke-ITToolkitAsUser -Execute (Join-Path $env:SystemRoot 'System32\cmd.exe') -Argument ('/c start "" "{0}"' -f $exe) -TimeoutSeconds 30
    Write-GuiLog "OneDrive reset and restarted. The cloud icon may take a few minutes to finish re-syncing." "Lime"
}

function Run-FixOfficeSignIn {
    $u = Get-ITToolkitTargetUserOrStop
    if (-not $u) { return }
    if (-not $u.Sid) { Write-GuiLog "Could not resolve the user's SID." "Red"; return }
    if (-not (Confirm-DestructiveAction -Title "Fix Office Sign-in Loop" -Message "This closes Office/Teams for $($u.Name), clears cached Office sign-ins and the Windows token cache. They'll sign in again once. Continue?")) {
        Write-GuiLog "Office sign-in fix canceled." "Yellow"; return
    }
    Stop-ITToolkitApps -Names @('OUTLOOK', 'WINWORD', 'EXCEL', 'POWERPNT', 'ONENOTE', 'MSACCESS', 'MSPUB', 'lync', 'ms-teams', 'Teams')

    # 1) Office identity cache (backed up first)
    $idKey = "Registry::HKEY_USERS\$($u.Sid)\Software\Microsoft\Office\16.0\Common\Identity"
    if (Test-Path $idKey) {
        $bak = Join-Path $u.ProfilePath ("AppData\Local\Temp\ITToolkit_OfficeIdentity_{0:yyyyMMdd_HHmmss}.reg" -f (Get-Date))
        & reg.exe export "HKU\$($u.Sid)\Software\Microsoft\Office\16.0\Common\Identity" "$bak" /y 2>&1 | Out-Null
        Remove-Item -Path $idKey -Recurse -Force -ErrorAction SilentlyContinue
        Write-GuiLog "Office identity cache cleared (backup in user's Temp)." "Lime"
    } else {
        Write-GuiLog "No Office identity cache found (skipped)." "Gray"
    }

    # 2) Windows token broker accounts (renamed, not deleted)
    $tb = Join-Path $u.ProfilePath 'AppData\Local\Packages\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy\AC\TokenBroker\Accounts'
    if (Test-Path -LiteralPath $tb) {
        try {
            Rename-Item -LiteralPath $tb -NewName ("Accounts_bak_{0:yyyyMMdd_HHmmss}" -f (Get-Date)) -ErrorAction Stop
            Write-GuiLog "Token broker account cache reset." "Lime"
        } catch {
            Write-GuiLog ("Token broker cache in use, skipped: {0}" -f $_.Exception.Message) "Yellow"
        }
    }

    # 3) Credential Manager entries (must run as the user)
    $credScript = @'
$n = 0
foreach ($line in (cmdkey /list)) {
    if ($line -match '^\s*Target:\s*(.+?)\s*$') {
        $t = $Matches[1]
        if ($t -match 'MicrosoftOffice|msteams|OneDrive Cached Credential|Microsoft_OC|SSO_POP_|ADAL|MSOID') {
            cmdkey "/delete:$t" *> $null
            if ($LASTEXITCODE -ne 0 -and $t -match 'target=(.+)$') { cmdkey "/delete:$($Matches[1])" *> $null }
            $n++
        }
    }
}
exit $n
'@
    Invoke-ITToolkitUserPowerShell -Script $credScript -TimeoutSeconds 60
    if ($null -ne $Script:UserTaskExitCode) {
        Write-GuiLog ("Removed {0} cached Office/Teams credential(s)." -f $Script:UserTaskExitCode) "Lime"
    }
    Write-GuiLog "Done. Have the user open Outlook and sign in once - Teams/OneDrive will follow." "Lime"
}

function Get-ITToolkitOfficeC2R {
    $cfg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if (-not $cfg) { return $null }
    return $cfg
}

function Run-OfficeInfo {
    Write-GuiLog "=== OFFICE / M365 APPS ===" "Cyan"
    $cfg = Get-ITToolkitOfficeC2R
    if (-not $cfg) { Write-GuiLog "Click-to-Run Office not found (MSI Office or not installed)." "Yellow"; return }
    $channels = @{
        '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current Channel'
        '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Monthly Enterprise Channel'
        '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Semi-Annual Enterprise Channel'
        '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Current Channel (Preview)'
        'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Semi-Annual Enterprise (Preview)'
        '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Beta Channel'
    }
    $url = if ($cfg.UpdateChannel) { $cfg.UpdateChannel } else { $cfg.CDNBaseUrl }
    $chan = 'Unknown'
    foreach ($k in $channels.Keys) { if ($url -match $k) { $chan = $channels[$k] } }
    Write-GuiLog ("Products: {0}" -f $cfg.ProductReleaseIds) "White"
    Write-GuiLog ("Version: {0} ({1})" -f $cfg.VersionToReport, $cfg.Platform) "White"
    Write-GuiLog ("Channel: {0}" -f $chan) "White"
    Write-GuiLog ("Updates enabled: {0}" -f $(if ($cfg.UpdatesEnabled) { $cfg.UpdatesEnabled } else { 'default' })) "White"
}

function Run-OfficeRepair {
    param([ValidateSet('QuickRepair', 'FullRepair')][string]$Type = 'QuickRepair')
    $cfg = Get-ITToolkitOfficeC2R
    $exe = Join-Path $env:CommonProgramFiles 'Microsoft Shared\ClickToRun\OfficeClickToRun.exe'
    if (-not $cfg -or -not (Test-Path -LiteralPath $exe)) { Write-GuiLog "Click-to-Run Office not found." "Red"; return }
    $msg = if ($Type -eq 'QuickRepair') { "Run an Office QUICK repair? Office apps will be closed. Takes ~5-10 minutes, no internet needed." }
           else { "Run an Office ONLINE repair? Office apps will be closed and Office is fully re-downloaded and reinstalled (30-60+ min). Use only if Quick Repair didn't fix it." }
    if (-not (Confirm-DestructiveAction -Title "Office Repair" -Message $msg)) { Write-GuiLog "Office repair canceled." "Yellow"; return }
    $plat = if ($cfg.Platform) { $cfg.Platform } else { 'x64' }
    $cult = if ($cfg.ClientCulture) { $cfg.ClientCulture } else { 'en-us' }
    Write-GuiLog ("Starting Office {0} ({1}, {2})..." -f $Type, $plat, $cult) "Yellow"
    $p = Start-Process -FilePath $exe -ArgumentList "scenario=Repair platform=$plat culture=$cult forceappshutdown=True RepairType=$Type DisplayLevel=True" -PassThru
    Wait-GuiProcess -Process $p -HeartbeatLabel 'Office repair running' -HeartbeatSeconds 60
    Write-GuiLog "Office repair process finished (if a repair window is still open, let it complete)." "Lime"
}

function Run-OfficeUpdate {
    $exe = Join-Path $env:CommonProgramFiles 'Microsoft Shared\ClickToRun\OfficeC2RClient.exe'
    if (-not (Test-Path -LiteralPath $exe)) { Write-GuiLog "OfficeC2RClient.exe not found (Click-to-Run Office not installed)." "Red"; return }
    if (-not (Confirm-DestructiveAction -Title "Force Office Update" -Message "Check for and install Office updates now? Open Office apps will be closed.")) {
        Write-GuiLog "Office update canceled." "Yellow"; return
    }
    Start-Process -FilePath $exe -ArgumentList '/update user updatepromptuser=false forceappshutdown=true displaylevel=true' | Out-Null
    Write-GuiLog "Office update started - progress shows in the Office update window." "Lime"
}

# ---------------------------------------------------------------------
# #6 NETWORK
# ---------------------------------------------------------------------
function Test-ITToolkitEndpoint {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 3000)
    $r = [pscustomobject]@{ DnsOk = $false; DnsMs = $null; Ip = $null; TcpOk = $false; TcpMs = $null; Error = $null }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $ar = [System.Net.Dns]::BeginGetHostAddresses($HostName, $null, $null)
        while (-not $ar.AsyncWaitHandle.WaitOne(50)) {
            [System.Windows.Forms.Application]::DoEvents()
            if ($sw.ElapsedMilliseconds -gt $TimeoutMs) { throw "DNS timeout" }
        }
        $addrs = [System.Net.Dns]::EndGetHostAddresses($ar)
        $r.DnsOk = $true; $r.DnsMs = $sw.ElapsedMilliseconds
        $r.Ip = ($addrs | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1)
        if (-not $r.Ip) { $r.Ip = $addrs | Select-Object -First 1 }
    } catch {
        $r.Error = "DNS failed: " + ($_.Exception.Message -replace '^Exception calling .*?: ', '')
        return $r
    }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $sw.Restart()
        $ar = $client.BeginConnect($r.Ip, $Port, $null, $null)
        while (-not $ar.AsyncWaitHandle.WaitOne(50)) {
            [System.Windows.Forms.Application]::DoEvents()
            if ($sw.ElapsedMilliseconds -gt $TimeoutMs) { throw "TCP timeout after $TimeoutMs ms" }
        }
        $client.EndConnect($ar)
        $r.TcpOk = $true; $r.TcpMs = $sw.ElapsedMilliseconds
    } catch {
        $r.Error = "TCP $Port failed: " + ($_.Exception.Message -replace '^Exception calling .*?: ', '')
    } finally {
        $client.Close()
    }
    return $r
}

function Run-ConnectivityTests {
    Write-GuiLog "=== CONNECTIVITY TESTS ===" "Cyan"
    $tests = @(Get-ITToolkitSetting -Name 'NetworkTests' -Default @())
    if ($tests.Count -eq 0) { Write-GuiLog "No tests defined in settings (NetworkTests)." "Yellow"; return }
    $pass = 0; $fail = 0
    foreach ($t in $tests) {
        if (-not $t.Host) { continue }
        $port = if ($t.Port) { [int]$t.Port } else { 443 }
        $res = Test-ITToolkitEndpoint -HostName $t.Host -Port $port
        $label = "{0,-22} {1}:{2}" -f $t.Name, $t.Host, $port
        if ($res.TcpOk) {
            $pass++
            Write-GuiLog ("[PASS] {0}  (DNS {1} ms, connect {2} ms)" -f $label, $res.DnsMs, $res.TcpMs) "Lime"
        } else {
            $fail++
            Write-GuiLog ("[FAIL] {0}  {1}" -f $label, $res.Error) "Red"
        }
    }
    $color = if ($fail -eq 0) { 'Lime' } else { 'Yellow' }
    Write-GuiLog ("Connectivity: {0} passed, {1} failed." -f $pass, $fail) $color
    if ($fail -gt 0) { Write-GuiLog "Tip: all failing = network/proxy/firewall. Only some failing = DNS or a blocked service." "Gray" }
}

function Run-NetworkSummary {
    Write-GuiLog "=== NETWORK SUMMARY ===" "Cyan"
    try {
        $cfgs = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.NetAdapter.Status -eq 'Up' })
        if ($cfgs.Count -eq 0) { Write-GuiLog "No connected network adapters." "Red"; return }
        foreach ($c in $cfgs) {
            Write-GuiLog ("{0} ({1}, {2})" -f $c.InterfaceAlias, $c.InterfaceDescription, $c.NetAdapter.LinkSpeed) "White"
            Write-GuiLog ("  IPv4: {0}" -f (($c.IPv4Address | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }) -join ', ')) "White"
            $gw = $c.IPv4DefaultGateway | Select-Object -First 1 -ExpandProperty NextHop
            Write-GuiLog ("  Gateway: {0}" -f $(if ($gw) { $gw } else { '(none)' })) "White"
            Write-GuiLog ("  DNS: {0}" -f (($c.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ', ')) "White"
            if ($gw) {
                try {
                    $reply = (New-Object System.Net.NetworkInformation.Ping).Send($gw, 1000)
                    if ($reply.Status -eq 'Success') { Write-GuiLog ("  Gateway ping: {0} ms" -f $reply.RoundtripTime) "Lime" }
                    else { Write-GuiLog ("  Gateway ping: {0}" -f $reply.Status) "Yellow" }
                } catch { }
            }
            [System.Windows.Forms.Application]::DoEvents()
        }
        $prof = Get-NetConnectionProfile -ErrorAction SilentlyContinue
        foreach ($p in $prof) { Write-GuiLog ("Network profile: {0} = {1} ({2})" -f $p.InterfaceAlias, $p.NetworkCategory, $p.IPv4Connectivity) "Gray" }
    } catch {
        Write-GuiLog ("Network summary failed: {0}" -f $_.Exception.Message) "Red"
    }
}

function Run-WifiDetails {
    Write-GuiLog "=== WI-FI DETAILS ===" "Cyan"
    $out = & netsh.exe wlan show interfaces 2>&1
    if ("$out" -match '(?i)no wireless interface|service .* is not running|There is no wireless') {
        Write-GuiLog "No Wi-Fi adapter / WLAN service on this PC." "Yellow"; return
    }
    $keep = '^\s*(Name|Description|State|SSID|BSSID|Network type|Radio type|Authentication|Band|Channel|Receive rate|Transmit rate|Signal)\s*:'
    foreach ($l in $out) {
        if ("$l" -match $keep) {
            $color = 'White'
            if ("$l" -match 'Signal\s*:\s*(\d+)%') { $sig = [int]$Matches[1]; $color = if ($sig -lt 40) { 'Red' } elseif ($sig -lt 65) { 'Yellow' } else { 'Lime' } }
            Write-GuiLog ("{0}" -f "$l".Trim()) $color
        }
    }
}

function Run-WifiReport {
    Write-GuiLog "Generating Windows Wi-Fi report (last 3 days of connection history)..." "Yellow"
    $p = Start-Process -FilePath 'netsh.exe' -ArgumentList 'wlan', 'show', 'wlanreport' -WindowStyle Hidden -PassThru
    Wait-GuiProcess -Process $p -HeartbeatLabel 'Wi-Fi report still building'
    $src = 'C:\ProgramData\Microsoft\Windows\WlanReport\wlan-report-latest.html'
    if (-not (Test-Path $src)) { Write-GuiLog "Wi-Fi report was not created (no WLAN adapter?)." "Red"; return }
    $dst = Join-Path ((Get-ITToolkitOutputFolder)) ("WlanReport_{0}_{1:yyyyMMdd_HHmmss}.html" -f $env:COMPUTERNAME, (Get-Date))
    Copy-Item -LiteralPath $src -Destination $dst -Force
    Write-GuiLog ("Wi-Fi report saved to: {0}" -f $dst) "Lime"
    Start-Process $dst | Out-Null
}

function Get-ITToolkitCustomTarget {
    $h = $txtNetHost.Text.Trim()
    if (-not $h) { Write-GuiLog "Enter a host name or IP first." "Yellow"; return $null }
    return $h
}

function Run-CustomPing {
    $h = Get-ITToolkitCustomTarget
    if (-not $h) { return }
    Write-GuiLog ("Pinging {0}..." -f $h) "Cyan"
    $ping = New-Object System.Net.NetworkInformation.Ping
    $ok = 0
    for ($i = 1; $i -le 4; $i++) {
        try {
            $r = $ping.Send($h, 1500)
            if ($r.Status -eq 'Success') { $ok++; Write-GuiLog ("Reply from {0}: {1} ms" -f $r.Address, $r.RoundtripTime) "White" }
            else { Write-GuiLog ("{0}" -f $r.Status) "Yellow" }
        } catch { Write-GuiLog ("Ping failed: {0}" -f $_.Exception.InnerException.Message) "Red"; break }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 400
    }
    Write-GuiLog ("Ping {0}: {1}/4 replies." -f $h, $ok) $(if ($ok -eq 4) { 'Lime' } elseif ($ok -gt 0) { 'Yellow' } else { 'Red' })
    if ($ok -eq 0) { Write-GuiLog "Note: many servers/cloud services block ping. Try Test Port instead." "Gray" }
}

function Run-CustomPortTest {
    $h = Get-ITToolkitCustomTarget
    if (-not $h) { return }
    $port = 0
    if (-not [int]::TryParse($txtNetPort.Text.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        Write-GuiLog "Enter a valid port (1-65535)." "Yellow"; return
    }
    $r = Test-ITToolkitEndpoint -HostName $h -Port $port
    if ($r.TcpOk) { Write-GuiLog ("[PASS] {0}:{1} reachable (resolved {2}, DNS {3} ms, connect {4} ms)" -f $h, $port, $r.Ip, $r.DnsMs, $r.TcpMs) "Lime" }
    else { Write-GuiLog ("[FAIL] {0}:{1} - {2}" -f $h, $port, $r.Error) "Red" }
}

function Run-CustomTraceroute {
    $h = Get-ITToolkitCustomTarget
    if (-not $h) { return }
    Write-GuiLog ("Traceroute to {0} (max 20 hops)..." -f $h) "Cyan"
    $tmp = [System.IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath 'tracert.exe' -ArgumentList '-d', '-h', '20', '-w', '750', $h -NoNewWindow -RedirectStandardOutput $tmp -PassThru
    Wait-GuiProcess -Process $p -HeartbeatLabel 'Traceroute running' -HeartbeatSeconds 15
    foreach ($l in (Get-Content -LiteralPath $tmp -ErrorAction SilentlyContinue)) { if ($l.Trim()) { Write-GuiLog $l.TrimEnd() "White" } }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Write-GuiLog "Traceroute complete." "Lime"
}

# ---------------------------------------------------------------------
# #8 PROBLEM DEVICES  /  #9 DELL INFO
# ---------------------------------------------------------------------
$Script:PnpErrorText = @{
    1 = 'Not configured correctly'; 3 = 'Driver corrupted or low memory'; 10 = 'Device cannot start'; 12 = 'Resource conflict'
    14 = 'Restart required'; 18 = 'Reinstall drivers'; 19 = 'Registry problem'; 21 = 'Being removed'; 22 = 'Disabled'
    24 = 'Not present / not working'; 28 = 'Drivers not installed'; 29 = 'Disabled in BIOS/firmware'; 31 = 'Not working properly'
    32 = 'Driver service disabled'; 37 = 'Driver failed to initialize'; 39 = 'Driver missing or corrupt'; 41 = 'Driver loaded but hardware not found'
    43 = 'Device reported a problem and was stopped'; 47 = 'Prepared for safe removal'; 48 = 'Driver blocked'; 52 = 'Unsigned driver'
}

function Get-ITToolkitProblemDevices {
    @(Get-CimInstance -ClassName Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue |
        Where-Object { $_.ConfigManagerErrorCode -ne 45 })
}

function Run-ProblemDevices {
    Write-GuiLog "=== PROBLEM DEVICES (Device Manager yellow bangs) ===" "Cyan"
    $devs = Get-ITToolkitProblemDevices
    if ($devs.Count -eq 0) { Write-GuiLog "No problem devices. Device Manager is clean." "Lime"; return }
    foreach ($d in $devs) {
        $code = [int]$d.ConfigManagerErrorCode
        $why = if ($Script:PnpErrorText.ContainsKey($code)) { $Script:PnpErrorText[$code] } else { 'See Device Manager' }
        $color = if ($code -eq 22) { 'Yellow' } else { 'Red' }
        $name = if ($d.Name) { $d.Name } else { '(Unknown device)' }
        Write-GuiLog ("{0}  [Code {1}: {2}]" -f $name, $code, $why) $color
        $hwid = @($d.HardwareID) | Select-Object -First 1
        if ($hwid) { Write-GuiLog ("    Hardware ID: {0}" -f $hwid) "Gray" }
    }
    Write-GuiLog ("{0} problem device(s). Tip: search the Hardware ID to find the right driver; Code 28 = no driver installed." -f $devs.Count) "Yellow"
}

function Run-RescanHardware {
    Write-GuiLog "Scanning for hardware changes..." "Yellow"
    $out = & pnputil.exe /scan-devices 2>&1
    if ($LASTEXITCODE -eq 0) { Write-GuiLog "Hardware rescan complete." "Lime" }
    else { Write-GuiLog ("Rescan result: {0}" -f (("$out" -replace '\s+', ' ').Trim())) "Yellow" }
    Run-ProblemDevices
}

function Run-DellInfo {
    param([switch]$SkipScan)
    Write-GuiLog "=== DELL / BIOS INFO ===" "Cyan"
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    Write-GuiLog ("Model: {0} {1}" -f $cs.Manufacturer, $cs.Model) "White"
    Write-GuiLog ("Service tag / serial: {0}" -f $bios.SerialNumber) "White"
    $rel = if ($bios.ReleaseDate) { ([datetime]$bios.ReleaseDate).ToString('yyyy-MM-dd') } else { 'unknown' }
    Write-GuiLog ("BIOS: {0} (released {1})" -f $bios.SMBIOSBIOSVersion, $rel) "White"
    if ($bios.ReleaseDate -and ((Get-Date) - [datetime]$bios.ReleaseDate).TotalDays -gt 730) {
        Write-GuiLog "BIOS is over 2 years old." "Yellow"
    }
    if ($cs.Manufacturer -notmatch 'Dell') {
        Write-GuiLog "Not a Dell - BIOS update check skipped." "Gray"
        return
    }
    try { [System.Windows.Forms.Clipboard]::SetText([string]$bios.SerialNumber); Write-GuiLog "Service tag copied to clipboard." "Gray" } catch { }
    if ($SkipScan) { return }

    if (-not (Get-ITToolkitDcuPath)) { Write-GuiLog "Install Dell Command | Update to check for a newer BIOS (or use Dell Warranty Page)." "Yellow"; return }
    Write-GuiLog "Asking Dell Command | Update for BIOS/firmware updates (1-3 min)..." "Yellow"
    Get-ITToolkitDellPending -UpdateType 'bios,firmware'
    if ($Script:DellPendingCount -eq 0) {
        Write-GuiLog "BIOS/firmware is current." "Lime"
    } elseif ($Script:DellPendingCount -gt 0) {
        foreach ($n in $Script:DellPendingNames) { Write-GuiLog ("UPDATE AVAILABLE: {0}" -f $n) "Yellow" }
        Write-GuiLog "Run Master Update to apply Dell updates (BitLocker is auto-suspended)." "Gray"
    }
}

function Open-DellWarranty {
    $cs = Get-CimInstance Win32_ComputerSystem
    $tag = (Get-CimInstance Win32_BIOS).SerialNumber
    if ($cs.Manufacturer -notmatch 'Dell') { Write-GuiLog ("Not a Dell ({0})." -f $cs.Manufacturer) "Yellow"; return }
    Start-Process ("https://www.dell.com/support/home/en-us/product-support/servicetag/{0}/overview" -f $tag.Trim()) | Out-Null
    Write-GuiLog ("Opened Dell support page for service tag {0}." -f $tag) "Lime"
}

# ---------------------------------------------------------------------
# #7 BEFORE / AFTER HEALTH REPORT
# ---------------------------------------------------------------------
function Get-ITToolkitHealthSnapshot {
    $rows = New-Object System.Collections.Generic.List[object]
    $add = { param($n, $v) $rows.Add([pscustomobject]@{ Name = $n; Value = [string]$v }) | Out-Null }
    & $add 'Captured' ((Get-Date).ToString('yyyy-MM-dd HH:mm'))
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        & $add 'Windows build' ("{0} ({1}.{2})" -f $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR)
    } catch { }
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $up = (Get-Date) - $os.LastBootUpTime
        & $add 'Uptime' ("{0}d {1}h {2}m" -f $up.Days, $up.Hours, $up.Minutes)
    } catch { }
    try {
        $v = Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
        & $add 'C: free space' ("{0:N1} GB of {1:N0} GB ({2}%)" -f ($v.SizeRemaining / 1GB), ($v.Size / 1GB), [math]::Round($v.SizeRemaining / $v.Size * 100))
    } catch { }
    $pr = @(Test-ITToolkitPendingReboot)
    & $add 'Pending reboot' $(if ($pr.Count) { 'Yes - ' + ($pr -join ', ') } else { 'No' })
    try {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $cnt = $searcher.GetTotalHistoryCount()
        if ($cnt -gt 0) {
            $last = $searcher.QueryHistory(0, [Math]::Min($cnt, 20)) | Where-Object { $_.ResultCode -eq 2 } | Sort-Object Date -Descending | Select-Object -First 1
            if ($last) { & $add 'Last update installed' ("{0:yyyy-MM-dd} - {1}" -f $last.Date.ToLocalTime(), $last.Title) }
        }
    } catch { }
    try { & $add 'Problem devices' (@(Get-ITToolkitProblemDevices).Count) } catch { }
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        & $add 'Defender real-time' $(if ($mp.RealTimeProtectionEnabled) { 'On' } else { 'OFF' })
        & $add 'Defender signature age' ("{0} day(s)" -f $mp.AntivirusSignatureAge)
    } catch { }
    try {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        & $add 'BitLocker (C:)' ("{0} / {1}" -f $bl.ProtectionStatus, $bl.VolumeStatus)
    } catch { }
    $j = Get-ITToolkitJoinState
    & $add 'Entra / domain join' ("Entra: {0}, Domain: {1}" -f $(if ($j.AzureAdJoined) { 'Yes' } else { 'No' }), $(if ($j.DomainJoined) { 'Yes' } else { 'No' }))
    try {
        $c = Get-CimInstance -Namespace root\ccm -ClassName SMS_Client -ErrorAction Stop
        & $add 'SCCM client' $c.ClientVersion
    } catch { & $add 'SCCM client' 'Not installed / not responding' }
    $ime = Get-Service -Name IntuneManagementExtension -ErrorAction SilentlyContinue
    & $add 'Intune Mgmt Extension' $(if ($ime) { [string]$ime.Status } else { 'Not installed' })
    return $rows.ToArray()
}

function Run-CaptureBaseline {
    Write-GuiLog "Capturing baseline health snapshot (for the before/after report)..." "Gray"
    [System.Windows.Forms.Application]::DoEvents()
    $Script:HealthBaseline = @(Get-ITToolkitHealthSnapshot)
    Write-GuiLog "Baseline captured." "Gray"
}

function ConvertTo-ITToolkitHtml { param([string]$Text) [System.Net.WebUtility]::HtmlEncode([string]$Text) }

function Run-HealthReport {
    Write-GuiLog "Building before/after health report..." "Yellow"
    $after = @(Get-ITToolkitHealthSnapshot)
    $before = @($Script:HealthBaseline | Where-Object { $_ -and $_.Name })
    $beforeMap = @{}
    foreach ($b in $before) { $beforeMap[$b.Name] = $b.Value }

    $cs = Get-CimInstance Win32_ComputerSystem
    $serial = (Get-CimInstance Win32_BIOS).SerialNumber
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(@"
<!doctype html><html><head><meta charset="utf-8"><title>Health Report - $env:COMPUTERNAME</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;background:#f4f5f7;color:#1d1f23;margin:0;padding:24px}
.wrap{max-width:980px;margin:0 auto;background:#fff;border-radius:10px;padding:24px 28px;box-shadow:0 1px 4px rgba(0,0,0,.08)}
h1{margin:0 0 4px;font-size:22px} .sub{color:#5b6270;margin-bottom:18px}
h2{font-size:16px;margin:26px 0 8px;border-bottom:1px solid #e3e5e8;padding-bottom:6px}
table{border-collapse:collapse;width:100%;font-size:14px} th,td{text-align:left;padding:7px 10px;border-bottom:1px solid #eceef1;vertical-align:top}
th{background:#f0f2f5;font-weight:600} tr.chg td{background:#fff8e1} td.n{font-weight:600;white-space:nowrap}
.ok{color:#1e7d32}.warn{color:#a15c00}.err{color:#b3261e}
ul{margin:4px 0 0 18px;padding:0} li{margin:2px 0;color:#444}
details{margin-top:8px} pre{background:#1e1e1e;color:#ddd;padding:12px;border-radius:6px;font-size:12px;max-height:420px;overflow:auto;white-space:pre-wrap}
</style></head><body><div class="wrap">
"@)
    [void]$sb.Append(("<h1>PC Health Report - {0}</h1>" -f (ConvertTo-ITToolkitHtml $env:COMPUTERNAME)))
    [void]$sb.Append(("<div class='sub'>{0} {1} &middot; Serial {2} &middot; Session {3:MM/dd/yyyy h:mm tt} - {4:h:mm tt}</div>" -f (ConvertTo-ITToolkitHtml $cs.Manufacturer), (ConvertTo-ITToolkitHtml $cs.Model), (ConvertTo-ITToolkitHtml $serial), $Script:SessionStart, (Get-Date)))
    [void]$sb.Append("<h2>Before / After</h2><table><tr><th>Check</th><th>Before</th><th>After</th></tr>")
    foreach ($a in $after) {
        $bv = if ($beforeMap.ContainsKey($a.Name)) { $beforeMap[$a.Name] } else { '-' }
        $cls = if ($a.Name -ne 'Captured' -and $a.Name -ne 'Uptime' -and $bv -ne '-' -and $bv -ne $a.Value) { " class='chg'" } else { '' }
        [void]$sb.Append(("<tr{0}><td class='n'>{1}</td><td>{2}</td><td>{3}</td></tr>" -f $cls, (ConvertTo-ITToolkitHtml $a.Name), (ConvertTo-ITToolkitHtml $bv), (ConvertTo-ITToolkitHtml $a.Value)))
    }
    [void]$sb.Append("</table>")
    if ($before.Count -eq 0) { [void]$sb.Append("<p class='warn'>No baseline was captured this session, so only the current state is shown.</p>") }

    [void]$sb.Append("<h2>Work performed</h2>")
    if ($Script:ActionHistory.Count -eq 0) {
        [void]$sb.Append("<p>No toolkit actions were run this session.</p>")
    } else {
        [void]$sb.Append("<table><tr><th>Time</th><th>Action</th><th>Result</th></tr>")
        foreach ($h in $Script:ActionHistory) {
            $cls = switch -Regex ($h.Outcome) { 'errors' { 'err' } 'warnings|canceled' { 'warn' } default { 'ok' } }
            $notes = ''
            if (@($h.Notes).Count -gt 0) { $notes = '<ul>' + ((@($h.Notes) | ForEach-Object { '<li>' + (ConvertTo-ITToolkitHtml $_) + '</li>' }) -join '') + '</ul>' }
            [void]$sb.Append(("<tr><td>{0:h:mm tt}</td><td><b>{1}</b>{2}</td><td class='{3}'>{4}</td></tr>" -f ([datetime]$h.Time), (ConvertTo-ITToolkitHtml $h.Name), $notes, $cls, (ConvertTo-ITToolkitHtml $h.Outcome)))
        }
        [void]$sb.Append("</table>")
    }
    $logText = (@($Script:GuiLogLines) | Select-Object -Last 600) -join "`n"
    [void]$sb.Append(("<details><summary>Full toolkit log</summary><pre>{0}</pre></details>" -f (ConvertTo-ITToolkitHtml $logText)))
    [void]$sb.Append("</div></body></html>")

    $out = Join-Path ((Get-ITToolkitOutputFolder)) ("HealthReport_{0}_{1:yyyyMMdd_HHmmss}.html" -f $env:COMPUTERNAME, (Get-Date))
    Set-Content -LiteralPath $out -Value $sb.ToString() -Encoding UTF8
    Write-GuiLog ("Health report saved to: {0}" -f $out) "Lime"
    Start-Process $out | Out-Null
}

# ---------------------------------------------------------------------
# #4 TICKET NOTES
# ---------------------------------------------------------------------
function Get-ITToolkitTicketNotes {
    $cs = Get-CimInstance Win32_ComputerSystem
    $serial = (Get-CimInstance Win32_BIOS).SerialNumber
    $u = Get-ITToolkitConsoleUser
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add(("Device: {0} | {1} {2} | Serial {3}" -f $env:COMPUTERNAME, $cs.Manufacturer, $cs.Model, $serial))
    $L.Add(("Signed-in user: {0}" -f $(if ($u) { $u.Name } else { '(none)' })))
    $L.Add(("Work session: {0:MM/dd/yyyy h:mm tt} - {1:h:mm tt}" -f $Script:SessionStart, (Get-Date)))
    $L.Add('')
    if ($Script:ActionHistory.Count -eq 0) {
        $L.Add('No toolkit actions run yet this session.')
    } else {
        $L.Add('Actions performed:')
        foreach ($h in $Script:ActionHistory) {
            $dur = if ([double]$h.Minutes -ge 1) { " ({0} min)" -f $h.Minutes } else { '' }
            $L.Add(("- {0:h:mm tt}  {1} - {2}{3}" -f ([datetime]$h.Time), $h.Name, $h.Outcome, $dur))
            foreach ($n in @($h.Notes)) { $L.Add("    * $n") }
        }
    }
    $L.Add('')
    $pr = @(Test-ITToolkitPendingReboot | Where-Object { $_ -ne 'PendingFileRenameOperations' })
    $L.Add(("Restart pending: {0}" -f $(if ($pr.Count) { 'Yes' } else { 'No' })))
    $sig = Get-ITToolkitSetting -Name 'TicketSignature' -Default ''
    if ($sig) { $L.Add(''); $L.Add($sig) }
    return ($L -join "`r`n")
}

function Show-ITToolkitTicketNotes {
    $text = Get-ITToolkitTicketNotes
    try { [System.Windows.Forms.Clipboard]::SetText($text) } catch { }
    Write-GuiLog "Ticket notes copied to clipboard (edit in the window if needed)." "Lime"

    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Ticket Notes - edit, then Copy"
    $f.Size = New-Object System.Drawing.Size(760, 560)
    $f.StartPosition = 'CenterScreen'
    $f.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.ScrollBars = 'Vertical'
    $tb.WordWrap = $true
    $tb.Font = New-Object System.Drawing.Font("Consolas", 10)
    $tb.Location = New-Object System.Drawing.Point(12, 12)
    $tb.Size = New-Object System.Drawing.Size(720, 450)
    $tb.Anchor = 'Top, Bottom, Left, Right'
    $tb.Text = $text
    $f.Controls.Add($tb)
    $bCopy = New-Object System.Windows.Forms.Button
    $bCopy.Text = 'Copy'
    $bCopy.Location = New-Object System.Drawing.Point(12, 472)
    $bCopy.Size = New-Object System.Drawing.Size(110, 32)
    $bCopy.Anchor = 'Bottom, Left'
    $bCopy.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $bCopy.ForeColor = [System.Drawing.Color]::White
    $bCopy.FlatStyle = 'Flat'
    $bCopy.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($tb.Text); $bCopy.Text = 'Copied!' })
    $f.Controls.Add($bCopy)
    $bSave = New-Object System.Windows.Forms.Button
    $bSave.Text = 'Save to Desktop'
    $bSave.Location = New-Object System.Drawing.Point(132, 472)
    $bSave.Size = New-Object System.Drawing.Size(130, 32)
    $bSave.Anchor = 'Bottom, Left'
    $bSave.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $bSave.ForeColor = [System.Drawing.Color]::White
    $bSave.FlatStyle = 'Flat'
    $bSave.Add_Click({
        $p = Join-Path ((Get-ITToolkitOutputFolder)) ("TicketNotes_{0}_{1:yyyyMMdd_HHmmss}.txt" -f $env:COMPUTERNAME, (Get-Date))
        Set-Content -LiteralPath $p -Value $tb.Text -Encoding ASCII
        $bSave.Text = 'Saved'
    })
    $f.Controls.Add($bSave)
    $tb.SelectionStart = 0
    [void]$f.ShowDialog()
    $f.Dispose()
}

# ---------------------------------------------------------------------
# #5 NEW PC SETUP
# ---------------------------------------------------------------------
function Get-ITToolkitDefaultPcName {
    $prefix = [string](Get-ITToolkitSetting -Name 'ComputerNamePrefix' -Default '')
    if (-not $prefix) { return $env:COMPUTERNAME }
    $serial = ((Get-CimInstance Win32_BIOS).SerialNumber -replace '[^A-Za-z0-9]', '')
    $name = ($prefix + $serial)
    if ($name.Length -gt 15) { $name = $name.Substring(0, 15) }
    return $name.ToUpper()
}

function Update-ITToolkitSetupDefaults {
    if (-not $txtSetupName) { return }
    $txtSetupName.Text = Get-ITToolkitDefaultPcName
    $tz = [string](Get-ITToolkitSetting -Name 'TimeZone' -Default '')
    if ($tz -and $cmbSetupTz.Items.Contains($tz)) { $cmbSetupTz.SelectedItem = $tz }
    $pp = [string](Get-ITToolkitSetting -Name 'PowerPlan' -Default 'Balanced')
    if ($cmbSetupPower.Items.Contains($pp)) { $cmbSetupPower.SelectedItem = $pp }
    $apps = @(Get-ITToolkitSetting -Name 'StandardApps' -Default @() | Where-Object { $_ })
    $chkSetupApps.Text = ("Install standard apps ({0} in settings)" -f $apps.Count)
    if ($apps.Count -eq 0) { $chkSetupApps.Checked = $false }
}

function Add-SetupStep {
    param([string]$Key, [string]$Text)
    $it = New-Object System.Windows.Forms.ListViewItem($Text)
    $it.Name = $Key
    [void]$it.SubItems.Add('Pending')
    [void]$it.SubItems.Add('')
    $it.ForeColor = [System.Drawing.Color]::Gray
    [void]$lstSetup.Items.Add($it)
}

function Set-SetupStep {
    param([string]$Key, [string]$Status, [string]$Detail = '')
    $it = $lstSetup.Items[$Key]
    if (-not $it) { return }
    $it.SubItems[1].Text = $Status
    $it.SubItems[2].Text = $Detail
    $it.ForeColor = switch ($Status) {
        'OK'      { [System.Drawing.Color]::LimeGreen }
        'Running' { [System.Drawing.Color]::Cyan }
        'Failed'  { [System.Drawing.Color]::Salmon }
        'Warning' { [System.Drawing.Color]::Gold }
        default   { [System.Drawing.Color]::Gray }
    }
    $it.EnsureVisible()
    [System.Windows.Forms.Application]::DoEvents()
}

function Run-NewPcSetup {
    $apps = @(Get-ITToolkitSetting -Name 'StandardApps' -Default @() | Where-Object { $_ })
    $plan = @()
    if ($chkSetupRename.Checked) { $plan += "Rename PC to $($txtSetupName.Text.Trim())" }
    if ($chkSetupTz.Checked) { $plan += "Time zone: $($cmbSetupTz.SelectedItem)" }
    if ($chkSetupPower.Checked) { $plan += "Power plan: $($cmbSetupPower.SelectedItem)" }
    if ($chkSetupApps.Checked) { $plan += "Install $($apps.Count) app(s)" }
    if ($chkSetupBitLocker.Checked) { $plan += "Back up BitLocker key" }
    if ($chkSetupUpdate.Checked) { $plan += "Run Master Update" }
    if ($plan.Count -eq 0) { Write-GuiLog "Nothing selected." "Yellow"; return }
    if (-not (Confirm-DestructiveAction -Title "New PC Setup" -Message ("Run these steps?`r`n`r`n - " + ($plan -join "`r`n - ")))) {
        Write-GuiLog "New PC setup canceled." "Yellow"; return
    }

    $lstSetup.Items.Clear()
    if ($chkSetupRename.Checked) { Add-SetupStep 'rename' 'Rename computer' }
    if ($chkSetupTz.Checked) { Add-SetupStep 'tz' 'Set time zone + sync clock' }
    if ($chkSetupPower.Checked) { Add-SetupStep 'power' 'Power plan + timeouts' }
    if ($chkSetupApps.Checked) { foreach ($a in $apps) { Add-SetupStep ("app:$a") ("Install $a") } }
    if ($chkSetupBitLocker.Checked) { Add-SetupStep 'bitlocker' 'Back up BitLocker recovery key' }
    if ($chkSetupUpdate.Checked) { Add-SetupStep 'update' 'Master Update (Windows/Dell/winget)' }

    Write-GuiLog "=== NEW PC SETUP ===" "Cyan"
    $renamed = $false

    # --- Rename ---
    if ($chkSetupRename.Checked) {
        Set-SetupStep 'rename' 'Running'
        $newName = $txtSetupName.Text.Trim().ToUpper()
        if ($newName -eq $env:COMPUTERNAME.ToUpper()) {
            Set-SetupStep 'rename' 'OK' 'Already named that'
        } elseif ($newName -notmatch '^[A-Z0-9-]{1,15}$' -or $newName -match '^\d+$' -or $newName.StartsWith('-')) {
            Set-SetupStep 'rename' 'Failed' 'Invalid name (1-15 letters/numbers/hyphens, not all digits)'
            Write-GuiLog "Rename skipped: invalid computer name '$newName'." "Red"
        } else {
            try {
                $cs = Get-CimInstance Win32_ComputerSystem
                if ($cs.PartOfDomain) {
                    $cred = Get-Credential -Message "Domain account allowed to rename $env:COMPUTERNAME in AD"
                    if (-not $cred) { throw "No domain credentials entered" }
                    Rename-Computer -NewName $newName -DomainCredential $cred -Force -WarningAction SilentlyContinue -ErrorAction Stop
                } else {
                    Rename-Computer -NewName $newName -Force -WarningAction SilentlyContinue -ErrorAction Stop
                }
                $renamed = $true
                Set-SetupStep 'rename' 'OK' "Becomes $newName after restart"
                Write-GuiLog "Computer will be renamed to $newName at next restart." "Lime"
            } catch {
                Set-SetupStep 'rename' 'Failed' $_.Exception.Message
                Write-GuiLog ("Rename failed: {0}" -f $_.Exception.Message) "Red"
            }
        }
    }

    # --- Time zone ---
    if ($chkSetupTz.Checked) {
        Set-SetupStep 'tz' 'Running'
        try {
            Set-TimeZone -Id ([string]$cmbSetupTz.SelectedItem) -ErrorAction Stop
            Start-Process -FilePath 'w32tm.exe' -ArgumentList '/resync', '/force' -WindowStyle Hidden -Wait
            Set-SetupStep 'tz' 'OK' ([string]$cmbSetupTz.SelectedItem)
            Write-GuiLog ("Time zone set to {0}." -f $cmbSetupTz.SelectedItem) "Lime"
        } catch {
            Set-SetupStep 'tz' 'Failed' $_.Exception.Message
            Write-GuiLog ("Time zone failed: {0}" -f $_.Exception.Message) "Red"
        }
    }

    # --- Power ---
    if ($chkSetupPower.Checked) {
        Set-SetupStep 'power' 'Running'
        $alias = switch ([string]$cmbSetupPower.SelectedItem) { 'High performance' { 'SCHEME_MIN' } 'Power saver' { 'SCHEME_MAX' } default { 'SCHEME_BALANCED' } }
        $out = & powercfg.exe /setactive $alias 2>&1
        $okPlan = ($LASTEXITCODE -eq 0)
        $detail = if ($okPlan) { [string]$cmbSetupPower.SelectedItem } else { "Plan not available on this PC (Modern Standby?)" }
        $sleep = Get-ITToolkitSetting -Name 'SleepTimeoutACMinutes' -Default $null
        $mon = Get-ITToolkitSetting -Name 'MonitorTimeoutACMinutes' -Default $null
        if ($null -ne $sleep) { & powercfg.exe /change standby-timeout-ac ([int]$sleep) 2>&1 | Out-Null; $detail += "; sleep(AC)=$sleep min" }
        if ($null -ne $mon) { & powercfg.exe /change monitor-timeout-ac ([int]$mon) 2>&1 | Out-Null; $detail += "; screen(AC)=$mon min" }
        Set-SetupStep 'power' $(if ($okPlan) { 'OK' } else { 'Warning' }) $detail
        Write-GuiLog ("Power: {0}" -f $detail) $(if ($okPlan) { 'Lime' } else { 'Yellow' })
    }

    # --- Apps ---
    if ($chkSetupApps.Checked -and $apps.Count -gt 0) {
        $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
        foreach ($a in $apps) {
            $key = "app:$a"
            if (-not $wg) { Set-SetupStep $key 'Failed' 'winget not available for this account'; continue }
            if ($a -notmatch '^[A-Za-z0-9][A-Za-z0-9\.\-_+]*$') { Set-SetupStep $key 'Failed' 'Invalid winget ID'; continue }
            Set-SetupStep $key 'Running' 'Installing (see console window)...'
            $p = Start-Process -FilePath $wg.Source -ArgumentList 'install', '--id', $a, '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements' -NoNewWindow -PassThru
            Wait-GuiProcess -Process $p -HeartbeatLabel "Still installing $a"
            $code = [int]$p.ExitCode
            if ($code -eq 0) { Set-SetupStep $key 'OK' 'Installed'; Write-GuiLog "Installed $a." "Lime" }
            elseif ($code -eq -1978335189 -or $code -eq -1978335135) { Set-SetupStep $key 'OK' 'Already installed / up to date'; Write-GuiLog "$a already installed." "Green" }
            else { Set-SetupStep $key 'Failed' ("winget code 0x{0:X8}" -f $code); Write-GuiLog ("Install of {0} failed (0x{1:X8})." -f $a, $code) "Red" }
        }
    }

    # --- BitLocker ---
    if ($chkSetupBitLocker.Checked) {
        Set-SetupStep 'bitlocker' 'Running'
        try {
            $mp = $env:SystemDrive
            $vol = Get-BitLockerVolume -MountPoint $mp -ErrorAction Stop
            if ($vol.VolumeStatus -eq 'FullyDecrypted' -and $vol.ProtectionStatus -ne 'On') {
                Set-SetupStep 'bitlocker' 'Warning' 'BitLocker is not enabled on C: (Intune policy may still be pending)'
                Write-GuiLog "BitLocker not enabled on C: - nothing to back up yet." "Yellow"
            } else {
                $rp = @($vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
                if ($rp.Count -eq 0) {
                    Add-BitLockerKeyProtector -MountPoint $mp -RecoveryPasswordProtector -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
                    $rp = @((Get-BitLockerVolume -MountPoint $mp).KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
                    Write-GuiLog "Added a recovery password protector to C:." "Gray"
                }
                $j = Get-ITToolkitJoinState
                $done = @()
                if ($j.AzureAdJoined) {
                    BackupToAAD-BitLockerKeyProtector -MountPoint $mp -KeyProtectorId $rp[0].KeyProtectorId -ErrorAction Stop | Out-Null
                    $done += 'Entra ID'
                }
                if ($j.DomainJoined) {
                    try { Backup-BitLockerKeyProtector -MountPoint $mp -KeyProtectorId $rp[0].KeyProtectorId -ErrorAction Stop | Out-Null; $done += 'AD' }
                    catch { Write-GuiLog ("AD backup failed: {0}" -f $_.Exception.Message) "Yellow" }
                }
                if ($done.Count -gt 0) {
                    Set-SetupStep 'bitlocker' 'OK' ("Escrowed to " + ($done -join ' + '))
                    Write-GuiLog ("BitLocker key backed up to {0}." -f ($done -join ' + ')) "Lime"
                } else {
                    Set-SetupStep 'bitlocker' 'Warning' 'Not Entra or domain joined - nowhere to escrow'
                    Write-GuiLog "Device is not Entra/domain joined - BitLocker key not escrowed." "Yellow"
                }
            }
        } catch {
            Set-SetupStep 'bitlocker' 'Failed' $_.Exception.Message
            Write-GuiLog ("BitLocker backup failed: {0}" -f $_.Exception.Message) "Red"
        }
    }

    # --- Master Update ---
    if ($chkSetupUpdate.Checked) {
        Set-SetupStep 'update' 'Running' 'See log below...'
        Run-MasterUpdateSequence
        Set-SetupStep 'update' 'OK' $(if ($Script:UpdateRebootNeeded) { 'Done - restart needed (auto-resumes)' } else { 'Done' })
        if ($renamed -and -not $Script:UpdateRebootNeeded) {
            Show-ITToolkitRebootPrompt -Message "The computer rename takes effect after a restart."
        }
    } elseif ($renamed) {
        Show-ITToolkitRebootPrompt -Message "The computer rename takes effect after a restart."
    }
    Write-GuiLog "=== NEW PC SETUP FINISHED ===" "Lime"
}

# ---------------------------------------------------------------------
# OOBE SUPPORT
# ---------------------------------------------------------------------
function Test-ITToolkitOobe {
    if ($Script:OobeMode) { return $true }
    if ($env:USERNAME -match '^defaultuser\d+$') { return $true }
    try {
        $s = Get-ItemProperty -Path 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
        if ($s.OOBEInProgress -eq 1 -or $s.SystemSetupInProgress -eq 1) { return $true }
    } catch { }
    return $false
}

# Where saved files go. In OOBE the temp account's Desktop gets wiped, so use the USB instead.
function Get-ITToolkitOutputFolder {
    $desktop = [Environment]::GetFolderPath('Desktop')
    # SYSTEM's own Desktop is hidden in System32 - use the USB, else the Public Desktop everyone can see
    if ($Script:RunningAsSystem -and -not (Test-ITToolkitOobe)) {
        $desktop = if ($env:PUBLIC) { [System.IO.Path]::Combine($env:PUBLIC, 'Desktop') } else { 'C:\Users\Public\Desktop' }
    }
    if (-not (Test-ITToolkitOobe) -and -not $Script:RunningAsSystem) { return $desktop }
    $usb = $Script:UsbPath
    if ($usb -and $usb -ne $desktop -and (Test-Path -LiteralPath $usb) -and
        -not $usb.StartsWith($Script:StageRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $dir = Join-Path $usb 'ITToolkit_Output'
        try {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            return $dir
        } catch { }
    }
    if ((Test-ITToolkitOobe) -and -not $Script:OobeOutputWarned) {
        $Script:OobeOutputWarned = $true
        Write-GuiLog "OOBE: USB not found - saving to the temporary Desktop. Copy files off before OOBE finishes!" "Yellow"
    }
    return $desktop
}

function Get-ITToolkitAutopilotCsvPath {
    $csvDir = $Script:UsbPath
    if ([string]::IsNullOrWhiteSpace($csvDir) -or -not (Test-Path -LiteralPath $csvDir)) { $csvDir = Get-ITToolkitOutputFolder }
    return (Join-Path $csvDir 'AutopilotDevices.csv')
}

function Get-ITToolkitAutopilotDeviceCsvPath {
    param([string]$Serial = (Get-ITToolkitCleanSerial))
    $dir = Join-Path (Split-Path -Parent (Get-ITToolkitAutopilotCsvPath)) 'Autopilot'
    return (Join-Path $dir ("AP_{0}.csv" -f ($Serial -replace '[^A-Za-z0-9_-]', '_')))
}

# Group tag saved for this serial ('' = saved with no tag), or $null if this serial isn't saved yet.
function Get-ITToolkitSavedGroupTag {
    $serial = Get-ITToolkitCleanSerial
    if (-not $serial) { return $null }
    foreach ($csv in @((Get-ITToolkitAutopilotDeviceCsvPath -Serial $serial), (Get-ITToolkitAutopilotCsvPath))) {
        if (-not (Test-Path -LiteralPath $csv)) { continue }
        $hit = $null
        foreach ($l in @(Get-Content -LiteralPath $csv -ErrorAction SilentlyContinue)) {
            $f = @($l -split ',')
            if ($f.Count -ge 3 -and $f[0].Trim('"').Trim() -eq $serial) { $hit = $f }   # last match wins (older files may have duplicates)
        }
        if ($hit) { if ($hit.Count -ge 4) { return $hit[3].Trim('"').Trim() } else { return '' } }
    }
    return $null
}

function Test-ITToolkitAutopilotHashSaved {
    return ($null -ne (Get-ITToolkitSavedGroupTag))
}

# After Retry/Skip/Stop when the hash step didn't save. Returns 'Retry', 'Skip' or 'Stop'.
function Show-ITToolkitHashChoice {
    param([string]$Reason)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Autopilot hash not saved"
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $f.Size = New-Object System.Drawing.Size(480, 220)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "$Reason`r`n`r`nRetry = ask for the Group Tag again.`r`nSkip hash = keep going with time zone, power and updates (extract the hash later from Device Setup).`r`nStop = end OOBE Prep here."
    $lbl.ForeColor = [System.Drawing.Color]::White
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $lbl.Location = New-Object System.Drawing.Point(20, 12)
    $lbl.Size = New-Object System.Drawing.Size(430, 110)
    $f.Controls.Add($lbl)

    $retry = New-ITToolkitDialogButton $f 'Retry' 20 132 130 ([System.Windows.Forms.DialogResult]::Retry) 'primary'
    [void](New-ITToolkitDialogButton $f 'Skip hash' 165 132 130 ([System.Windows.Forms.DialogResult]::Ignore))
    [void](New-ITToolkitDialogButton $f 'Stop' 310 132 130 ([System.Windows.Forms.DialogResult]::Abort) 'danger')
    $f.AcceptButton = $retry

    $r = Show-ITToolkitModal -Dialog $f -Name 'Hash not saved box'
    $f.Dispose()
    if ($r -eq [System.Windows.Forms.DialogResult]::Ignore) { return 'Skip' }
    if ($r -eq [System.Windows.Forms.DialogResult]::Abort) { return 'Stop' }
    return 'Retry'   # Retry clicked, or the box itself kept closing - safest is to ask again
}

function Set-ITToolkitTimeZoneFromSettings {
    $tz = [string](Get-ITToolkitSetting -Name 'TimeZone' -Default '')
    if (-not $tz) { Write-GuiLog "No TimeZone in settings - time zone skipped." "Yellow"; return }
    try {
        Set-TimeZone -Id $tz -ErrorAction Stop
        Start-Process -FilePath 'w32tm.exe' -ArgumentList '/resync', '/force' -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
        Write-GuiLog "Time zone set to $tz." "Lime"
    } catch {
        Write-GuiLog ("Time zone '{0}' failed: {1}" -f $tz, $_.Exception.Message) "Red"
    }
}

function Set-ITToolkitPowerFromSettings {
    $plan = [string](Get-ITToolkitSetting -Name 'PowerPlan' -Default 'Balanced')
    $alias = switch ($plan) { 'High performance' { 'SCHEME_MIN' } 'Power saver' { 'SCHEME_MAX' } default { 'SCHEME_BALANCED' } }
    & powercfg.exe /setactive $alias 2>&1 | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    $detail = if ($ok) { $plan } else { "$plan not available on this PC (Modern Standby?)" }
    $sleep = Get-ITToolkitSetting -Name 'SleepTimeoutACMinutes' -Default $null
    $mon = Get-ITToolkitSetting -Name 'MonitorTimeoutACMinutes' -Default $null
    if ($null -ne $sleep) { & powercfg.exe /change standby-timeout-ac ([int]$sleep) 2>&1 | Out-Null; $detail += "; sleep(AC)=$sleep min" }
    if ($null -ne $mon) { & powercfg.exe /change monitor-timeout-ac ([int]$mon) 2>&1 | Out-Null; $detail += "; screen(AC)=$mon min" }
    Write-GuiLog ("Power: {0}" -f $detail) $(if ($ok) { 'Lime' } else { 'Yellow' })
}

# One click at OOBE: hash -> time zone -> power -> Windows/Dell updates. Safe to re-run.
# v4.1: always asks for the Group Tag (pre-filled with what's on file), never quietly stops.
function Run-OobePrep {
    $oobe = Test-ITToolkitOobe
    $existing = Get-ITToolkitSavedGroupTag
    $tz = [string](Get-ITToolkitSetting -Name 'TimeZone' -Default '(not set)')
    $plan = [string](Get-ITToolkitSetting -Name 'PowerPlan' -Default 'Balanced')
    $steps = @()
    $steps += $(if ($null -ne $existing) { "Autopilot hash - saved with tag '$existing' (you can confirm or change it)" } else { 'Extract Autopilot hash + Group Tag to the USB' })
    $steps += "Time zone: $tz"
    $steps += "Power plan: $plan"
    $steps += 'Windows + Dell updates (no apps)'
    $msg = "Run OOBE Prep?`r`n`r`n - " + ($steps -join "`r`n - ")
    if (-not $oobe) { $msg += "`r`n`r`n(This PC doesn't look like it's in OOBE - that's fine, it still works.)" }
    $go = Show-ITToolkitYesNo -Title 'OOBE Prep' -Message $msg -YesText 'Start' -NoText 'Cancel'
    if ($go -ne 'Yes') {
        if ($go -eq 'Unexpected') { Write-GuiLog "OOBE Prep didn't start - its confirm box kept closing on its own. Click OOBE Prep again." "Red" }
        else { Write-GuiLog "OOBE Prep canceled." "Yellow" }
        return
    }

    Write-GuiLog "=== OOBE PREP ===" "Cyan"

    # 1) Hash + Group Tag first so Intune can sync + assign the profile while updates run
    $Script:OobeGroupTag = $null
    $hashStep = 'pending'
    for ($try = 1; $hashStep -eq 'pending'; $try++) {
        $existing = Get-ITToolkitSavedGroupTag
        $default = if ($null -ne $existing) { $existing } else { [string](Get-ITToolkitSetting -Name 'DefaultGroupTag' -Default '') }
        $note = if ($null -ne $existing) { "Already saved with tag '$existing'. Leave it to keep it, or change it to replace the entry." } else { '' }
        $p = Show-ITToolkitGroupTagPrompt -Default $default -Note $note
        $reason = $null
        if ($p.Result -eq 'OK') {
            if ($null -ne $existing -and $p.Tag -ceq $existing) {
                Write-GuiLog ("Autopilot hash already saved with Group Tag '{0}' - kept as is." -f $existing) "Green"
                $Script:OobeGroupTag = $existing
                $hashStep = 'done'
                break
            }
            Run-AutopilotHash -GroupTag $p.Tag -TagProvided
            if ($Script:LastHashResult -eq 'Saved') {
                $Script:OobeGroupTag = $p.Tag
                Write-GuiLog ("NEXT: import {0} in Intune now (Devices > Enrollment > Windows Autopilot > Devices > Import) so the profile assigns while updates run." -f (Get-ITToolkitAutopilotDeviceCsvPath)) "Cyan"
                $hashStep = 'done'
                break
            }
            $reason = 'The hash could not be extracted (see the red line in the log).'
        } elseif ($p.Result -eq 'Cancel') {
            $reason = 'You clicked Cancel on the Group Tag box.'
        } else {
            $reason = 'The Group Tag box kept closing on its own (OOBE stealing focus).'
        }

        if ($try -ge 5) {
            Write-GuiLog "Hash step failed 5 times - skipping it. Extract the hash later from Device Setup." "Red"
            $hashStep = 'skipped'
            break
        }
        $choice = Show-ITToolkitHashChoice -Reason $reason
        if ($choice -eq 'Skip') {
            Write-GuiLog "Autopilot hash SKIPPED - continuing with time zone, power and updates. Extract it later from Device Setup." "Yellow"
            $hashStep = 'skipped'
        } elseif ($choice -eq 'Stop') {
            Write-GuiLog "OOBE Prep stopped at the hash step." "Yellow"
            return
        } else {
            Write-GuiLog "Retrying the Group Tag / hash step..." "Gray"
        }
    }

    # 2) + 3) Time zone and power
    Set-ITToolkitTimeZoneFromSettings
    Set-ITToolkitPowerFromSettings

    # 4) Windows + Dell updates only (apps come from Autopilot/Intune later)
    Run-ProvisioningUpdates -DeferRebootPrompt

    # 5) Finish (auto-restart countdown + self-reopen in OOBE)
    if ($oobe) {
        Complete-ITToolkitOobePass
    } elseif ($Script:UpdateRebootNeeded) {
        Show-ITToolkitRebootPrompt -Message "Updates need a restart. The toolkit resumes the update loop after you sign back in."
    } else {
        Complete-ITToolkitOobePass
    }
}


# ---------------------------------------------------------------------
# OOBE AUTO-RESUME
# A SYSTEM startup task waits for the OOBE screen, then puts the toolkit
# window back on it (same technique as psexec -s -i). No sign-in needed.
# ---------------------------------------------------------------------
$Script:OobeLaunchCs = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class ITToolkitOobeLaunch {
    [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool DuplicateTokenEx(IntPtr tok, uint access, IntPtr attrs, int level, int type, out IntPtr dup);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetTokenInformation(IntPtr tok, int cls, ref uint val, uint len);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string sys, string name, out long luid);

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct TOKEN_PRIVILEGES { public int Count; public long Luid; public int Attr; }
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr tok, bool disableAll, ref TOKEN_PRIVILEGES tp, int len, IntPtr prev, IntPtr retLen);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessAsUser(IntPtr tok, string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);

    static void Enable(IntPtr tok, string name) {
        long luid;
        if (LookupPrivilegeValue(null, name, out luid)) {
            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.Count = 1; tp.Luid = luid; tp.Attr = 2;
            AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        }
    }

    // Returns 0 on success, otherwise a Win32 error code.
    public static int Launch(string cmdLine, uint sessionId) {
        IntPtr tok;
        if (!OpenProcessToken(GetCurrentProcess(), 0xF01FF, out tok)) return Marshal.GetLastWin32Error();
        Enable(tok, "SeTcbPrivilege");
        Enable(tok, "SeAssignPrimaryTokenPrivilege");
        Enable(tok, "SeIncreaseQuotaPrivilege");
        IntPtr dup;
        if (!DuplicateTokenEx(tok, 0x02000000, IntPtr.Zero, 2, 1, out dup)) { int e1 = Marshal.GetLastWin32Error(); CloseHandle(tok); return e1; }
        CloseHandle(tok);
        uint s = sessionId;
        if (!SetTokenInformation(dup, 12, ref s, 4)) { int e2 = Marshal.GetLastWin32Error(); CloseHandle(dup); return e2; }
        STARTUPINFO si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        si.lpDesktop = "winsta0\\default";
        PROCESS_INFORMATION pi;
        StringBuilder sb = new StringBuilder(cmdLine, 32767);
        bool ok = CreateProcessAsUser(dup, null, sb, IntPtr.Zero, IntPtr.Zero, false, 0x00000010, IntPtr.Zero, null, ref si, out pi);
        int err = ok ? 0 : Marshal.GetLastWin32Error();
        if (ok) { CloseHandle(pi.hProcess); CloseHandle(pi.hThread); }
        CloseHandle(dup);
        return err;
    }
}
'@

$Script:OobeLauncherTemplate = @'
$log = '__LOG__'
function L([string]$m) { try { Add-Content -LiteralPath $log -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m) } catch { } }
L ('Resume launcher started as SYSTEM (mode: __MODE__)')
try { Add-Type -Path '__CS__' -ErrorAction Stop } catch { L ("Add-Type failed: " + $_.Exception.Message); exit 1 }
$none = [uint32]4294967295
$sid = $none
$deadline = (Get-Date).AddMinutes(__MINUTES__)
while ((Get-Date) -lt $deadline) {
    $sid = [ITToolkitOobeLaunch]::WTSGetActiveConsoleSessionId()
    if ($sid -ne $none -and $sid -ne 0) {
        $ui = @(Get-Process -Name __PROCS__ -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sid })
        if ($ui.Count -gt 0) { L ("Screen ready in session {0} ({1})" -f $sid, ($ui[0].ProcessName)); break }
    }
    Start-Sleep -Seconds 5
}
if ($sid -eq $none -or $sid -eq 0 -or (Get-Date) -ge $deadline) { L 'Nobody signed in / no screen found before the deadline - giving up'; exit 2 }
Start-Sleep -Seconds 15
$r = [ITToolkitOobeLaunch]::Launch('__CMD__', $sid)
L ("Launch into session {0} returned {1} (0 = OK)" -f $sid, $r)
exit $r
'@

function Register-ITToolkitSystemResume {
    param([string]$CmdArgs, [ValidateSet('oobe', 'normal')][string]$Mode = 'normal')
    try {
        $csPath = Join-Path $Script:StageRoot 'oobe_launch.cs'
        $psPath = Join-Path $Script:StageRoot 'resume_launcher.ps1'
        $logPath = Join-Path $Script:StageRoot 'resume_launcher.log'
        Set-Content -LiteralPath $csPath -Value $Script:OobeLaunchCs -Encoding ASCII -ErrorAction Stop
        $cmdLine = [System.IO.Path]::Combine($env:SystemRoot, 'System32', 'cmd.exe') + ' ' + $CmdArgs
        # OOBE: wait for the OOBE screen (10 min). Normal: wait for anyone's desktop (up to 12 h).
        $procs = if ($Mode -eq 'oobe') { "'WWAHost', 'CloudExperienceHostBroker', 'explorer'" } else { "'explorer'" }
        $minutes = if ($Mode -eq 'oobe') { 20 } else { 720 }
        $launcher = $Script:OobeLauncherTemplate.Replace('__LOG__', $logPath.Replace("'", "''")).Replace('__CS__', $csPath.Replace("'", "''")).Replace('__CMD__', $cmdLine.Replace("'", "''")).Replace('__PROCS__', $procs).Replace('__MINUTES__', "$minutes").Replace('__MODE__', $Mode)
        Set-Content -LiteralPath $psPath -Value $launcher -Encoding ASCII -ErrorAction Stop

        $ps = [System.IO.Path]::Combine($env:SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
        $action = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $psPath)
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 13)
        Register-ScheduledTask -TaskName $Script:ResumeTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'ITProvisioningResume' -ErrorAction SilentlyContinue
        $where = if ($Mode -eq 'oobe') { 'on the OOBE screen' } else { "as soon as anyone signs in" }
        Write-GuiLog ("Auto-resume armed: the toolkit reopens by itself after the restart, {0}." -f $where) "Gray"
        return $true
    } catch {
        Write-GuiLog ("SYSTEM auto-resume setup failed: {0}" -f $_.Exception.Message) "Yellow"
        return $false
    }
}

# If the toolkit is started by hand while a resume was pending, show why the auto-reopen didn't happen
function Show-ITToolkitResumeDiagnostics {
    $logPath = Join-Path $Script:StageRoot 'resume_launcher.log'
    if (-not (Test-Path -LiteralPath $logPath)) {
        Write-GuiLog "Auto-reopen didn't run after the restart (no launcher log - the startup task never fired)." "Yellow"
        return
    }
    Write-GuiLog "Auto-reopen launcher log (last lines):" "Gray"
    foreach ($l in (Get-Content -LiteralPath $logPath -Tail 5 -ErrorAction SilentlyContinue)) { Write-GuiLog ("  " + $l) "Gray" }
}

# 30-second "continue or pause" when updates are about to pick back up. Returns $true = continue.
function Show-ITToolkitResumePrompt {
    param([int]$Seconds = 30)
    $pass = Get-ITToolkitResumePass
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Resume updates?"
    $f.Size = New-Object System.Drawing.Size(470, 200)
    $f.StartPosition = "CenterScreen"
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.ControlBox = $false
    $f.TopMost = $true
    $f.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Picking the update job back up where it left off (pass $pass of $($Script:MaxUpdatePasses)).`r`n`r`nPause to use the toolkit without updates running - you can start them again any time from Home."
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $lbl.ForeColor = [System.Drawing.Color]::White
    $lbl.Location = New-Object System.Drawing.Point(20, 12)
    $lbl.Size = New-Object System.Drawing.Size(420, 66)
    $f.Controls.Add($lbl)

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $lblCount.ForeColor = [System.Drawing.Color]::Gold
    $lblCount.Location = New-Object System.Drawing.Point(20, 80)
    $lblCount.Size = New-Object System.Drawing.Size(420, 22)
    $lblCount.Text = "Continuing in $Seconds seconds..."
    $f.Controls.Add($lblCount)

    $bGo = New-Object System.Windows.Forms.Button
    $bGo.Text = "Continue Now"
    $bGo.Location = New-Object System.Drawing.Point(20, 112)
    $bGo.Size = New-Object System.Drawing.Size(130, 34)
    $bGo.BackColor = [System.Drawing.Color]::FromArgb(30, 135, 70)
    $bGo.ForeColor = [System.Drawing.Color]::White
    $bGo.FlatStyle = 'Flat'
    $bGo.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $f.Controls.Add($bGo)

    $bPause = New-Object System.Windows.Forms.Button
    $bPause.Text = "Pause Updates"
    $bPause.Location = New-Object System.Drawing.Point(310, 112)
    $bPause.Size = New-Object System.Drawing.Size(130, 34)
    $bPause.BackColor = [System.Drawing.Color]::FromArgb(48, 48, 54)
    $bPause.ForeColor = [System.Drawing.Color]::White
    $bPause.FlatStyle = 'Flat'
    $bPause.DialogResult = [System.Windows.Forms.DialogResult]::No
    $f.Controls.Add($bPause)

    $Script:ResumeLeft = $Seconds
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $Script:ResumeLeft--
        $lblCount.Text = "Continuing in $($Script:ResumeLeft) seconds..."
        if ($Script:ResumeLeft -le 0) { $timer.Stop(); $f.DialogResult = [System.Windows.Forms.DialogResult]::Yes }
    })
    $f.Add_Shown({ $timer.Start(); $f.Activate() })
    $r = $f.ShowDialog()
    $timer.Stop(); $timer.Dispose(); $f.Dispose()
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

# Locked resume window (SYSTEM on a user's desktop): close itself a minute after the job is done
function Close-ITToolkitAfterDelay {
    param([int]$Seconds = 60, [string]$Message = 'Updates finished.')
    Write-GuiLog ("{0} This window closes in {1} seconds." -f $Message, $Seconds) "Lime"
    $Script:CloseTimer = New-Object System.Windows.Forms.Timer
    $Script:CloseTimer.Interval = $Seconds * 1000
    $Script:CloseTimer.Add_Tick({ $Script:CloseTimer.Stop(); $form.Close() })
    $Script:CloseTimer.Start()
}

function Show-ITToolkitRebootCountdown {
    param([string]$Message, [int]$Seconds = 60)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Restarting"
    $f.Size = New-Object System.Drawing.Size(470, 210)
    $f.StartPosition = "CenterScreen"
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.ControlBox = $false
    $f.TopMost = $true
    $f.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Message
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $lbl.ForeColor = [System.Drawing.Color]::White
    $lbl.Location = New-Object System.Drawing.Point(20, 15)
    $lbl.Size = New-Object System.Drawing.Size(420, 60)
    $f.Controls.Add($lbl)

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $lblCount.ForeColor = [System.Drawing.Color]::Gold
    $lblCount.Location = New-Object System.Drawing.Point(20, 80)
    $lblCount.Size = New-Object System.Drawing.Size(420, 24)
    $lblCount.Text = "Restarting in $Seconds seconds..."
    $f.Controls.Add($lblCount)

    $bNow = New-Object System.Windows.Forms.Button
    $bNow.Text = "Restart Now"
    $bNow.Location = New-Object System.Drawing.Point(20, 118)
    $bNow.Size = New-Object System.Drawing.Size(120, 35)
    $bNow.BackColor = [System.Drawing.Color]::FromArgb(204, 0, 0)
    $bNow.ForeColor = [System.Drawing.Color]::White
    $bNow.FlatStyle = 'Flat'
    $bNow.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $f.Controls.Add($bNow)

    $bCancel = New-Object System.Windows.Forms.Button
    $bCancel.Text = "Cancel"
    $bCancel.Location = New-Object System.Drawing.Point(320, 118)
    $bCancel.Size = New-Object System.Drawing.Size(120, 35)
    $bCancel.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $bCancel.ForeColor = [System.Drawing.Color]::White
    $bCancel.FlatStyle = 'Flat'
    $bCancel.DialogResult = [System.Windows.Forms.DialogResult]::No
    $f.Controls.Add($bCancel)

    $Script:CountdownLeft = $Seconds
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $Script:CountdownLeft--
        $lblCount.Text = "Restarting in $($Script:CountdownLeft) seconds..."
        if ($Script:CountdownLeft -le 0) {
            $timer.Stop()
            $f.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        }
    })
    $f.Add_Shown({ $timer.Start(); $f.Activate() })
    $r = $f.ShowDialog()
    $timer.Stop()
    $timer.Dispose()
    $f.Dispose()
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
        [void](Invoke-ITToolkitRestart -DelaySeconds 10)
    } else {
        Write-GuiLog "Auto-restart canceled. Restart when ready - the toolkit still reopens on its own afterwards." "Yellow"
    }
}

# End of an OOBE Prep pass (first run or after a reboot)
function Complete-ITToolkitOobePass {
    if ($Script:UpdateRebootNeeded) {
        if ($Script:RebootPending) {
            Show-ITToolkitRebootCountdown -Seconds 60 -Message "Updates need a restart.`r`n`r`nThe toolkit reopens by itself after the restart and keeps going - you can walk away."
        } else {
            Show-ITToolkitRebootPrompt -Message "Updates need a restart, but auto-resume is off for this one (setup failed or the reboot limit was reached). After the reboot: Shift+F10, run the toolkit, click OOBE Prep."
        }
    } else {
        # Verify - and if anything is still missing, fix it automatically (no clicks needed)
        $r = Invoke-ITToolkitFinishLine -AutoFix
        if ($r -eq 'Ready') {
            Write-GuiLog "=== OOBE PREP COMPLETE - Windows + Dell fully patched ===" "Lime"
            $tagOnFile = Get-ITToolkitSavedGroupTag
            $tagLine = if ($null -eq $tagOnFile) { 'Group Tag: (hash not saved on this USB)' } elseif ($tagOnFile) { "Group Tag: $tagOnFile" } else { 'Group Tag: (blank)' }
            Write-GuiLog $tagLine $(if ($null -eq $tagOnFile) { 'Yellow' } else { 'Lime' })
            Write-GuiLog "Before shipping: confirm the device's Autopilot profile shows 'Assigned' in Intune, then restart so OOBE downloads it." "Yellow"
            Show-ITToolkitRebootPrompt -Message "READY - Windows and Dell are fully up to date. $tagLine`r`n`r`nCheck Intune first: the Autopilot profile should show Assigned for this device. Then restart so OOBE picks up the profile."
        } elseif ($r -eq 'NotReady') {
            Write-GuiLog "=== OOBE PREP: NOT READY TO SHIP ===" "Red"
        }
    }
}


# ---------------------------------------------------------------------
# FINISH LINE: verify, and if NOT READY fix it (updates and/or restart),
# then verify again. Returns 'Ready', 'Restarting', 'NotReady' or 'Declined'.
#   -AutoFix : don't ask first (used by the hands-off OOBE loop)
# ---------------------------------------------------------------------
function Invoke-ITToolkitFinishLine {
    param([switch]$AutoFix)
    $maxRounds = 2
    for ($round = 0; $round -le $maxRounds; $round++) {
        Run-VerifyFullyPatched
        if ($Script:VerifyPassed) { return 'Ready' }

        $pendingUpdates = @($Script:VerifyFailures | Where-Object { $_ -match 'still pending' }).Count -gt 0
        $needsRestart = $Script:VerifyFailures -contains 'restart pending'
        $other = @($Script:VerifyFailures | Where-Object { $_ -notmatch 'still pending' -and $_ -ne 'restart pending' })

        # Nothing the toolkit can fix by itself (scan failed, DCU missing, etc.)
        if (-not $pendingUpdates -and -not $needsRestart) {
            Write-GuiLog "NOT READY - this needs a look (see the messages above)." "Red"
            [System.Windows.Forms.MessageBox]::Show(
                ("NOT READY:`r`n`r`n - " + ($Script:VerifyFailures -join "`r`n - ") + "`r`n`r`nThe toolkit can't fix this one automatically - check the log above for the reason."),
                'Verify Fully Patched', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return 'NotReady'
        }
        if ($round -eq $maxRounds) {
            Write-GuiLog ("Still NOT READY after {0} automatic update rounds - an update may be failing repeatedly. Check the FAILED lines above." -f $maxRounds) "Red"
            [System.Windows.Forms.MessageBox]::Show(
                ("Still NOT READY after {0} automatic update rounds:`r`n`r`n - {1}`r`n`r`nAn update is probably failing every time - check the red FAILED lines in the log." -f $maxRounds, ($Script:VerifyFailures -join "`r`n - ")),
                'Verify Fully Patched', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return 'NotReady'
        }

        if (-not $AutoFix) {
            $plan = if ($pendingUpdates) { 'install the pending updates (restarting and resuming on its own if needed), then check again' } else { 'restart, reopen itself afterwards and check again' }
            $extra = if ($other.Count) { "`r`n`r`nAlso noted (can't be auto-fixed): " + ($other -join '; ') } else { '' }
            $ans = [System.Windows.Forms.MessageBox]::Show(
                ("NOT READY:`r`n`r`n - " + ($Script:VerifyFailures -join "`r`n - ") + "`r`n`r`nFix it now? The toolkit will $plan." + $extra),
                'Verify Fully Patched', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) {
                Write-GuiLog "Fix declined - device left NOT READY." "Yellow"
                return 'Declined'
            }
            $AutoFix = $true   # asked once - don't ask again on the next round
        }

        if ($pendingUpdates) {
            Write-GuiLog "=== NOT READY -> installing the pending updates ===" "Cyan"
            Run-ProvisioningUpdates -DeferRebootPrompt
            if ($Script:UpdateRebootNeeded) {
                Request-ITToolkitResumeRestart -Reason 'Updates need a restart.'
                return 'Restarting'
            }
            continue   # installed without a restart -> verify again
        }

        # Only a restart is outstanding: arm the resume so the check re-runs afterwards, then restart
        $next = (Get-ITToolkitResumePass) + 1
        if ($next -le $Script:MaxUpdatePasses) { Register-ITToolkitResume -Pass $next }
        Request-ITToolkitResumeRestart -Reason 'A restart is pending.'
        return 'Restarting'
    }
    return 'NotReady'
}

# Restart with the right UI: hands-off countdown in OOBE, normal prompt otherwise
function Request-ITToolkitResumeRestart {
    param([string]$Reason)
    if ($Script:RebootPending -and (Test-ITToolkitOobe)) {
        Show-ITToolkitRebootCountdown -Seconds 60 -Message "$Reason`r`n`r`nThe toolkit reopens by itself after the restart, finishes up and checks again - you can walk away."
    } elseif ($Script:RebootPending) {
        Show-ITToolkitRebootPrompt -Message "$Reason The toolkit reopens after you sign back in, finishes up and checks again."
    } else {
        Show-ITToolkitRebootPrompt -Message "$Reason (Auto-resume is off - after the restart, run the toolkit and click Verify Fully Patched.)"
    }
}

# Button entry point
function Run-VerifyAndFix {
    $r = Invoke-ITToolkitFinishLine
    if ($r -eq 'Ready') {
        [System.Windows.Forms.MessageBox]::Show("READY - Windows and Dell are fully up to date and no restart is pending.", 'Verify Fully Patched',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
}

# What runs when the toolkit reopens itself after an OOBE reboot
function Run-OobeResume {
    Write-GuiLog "=== OOBE PREP: RESUMED AFTER RESTART ===" "Cyan"
    Run-ProvisioningUpdates -DeferRebootPrompt
    Complete-ITToolkitOobePass
}


# Load settings + restore pre-reboot session before the window is built
Import-ITToolkitSettings
if ($Script:IsResume) { Restore-ITToolkitSessionState }

# =====================================================================
# GUI LAYER (v3.4 layout)
# =====================================================================
$Script:Clr = @{
    Window    = [System.Drawing.Color]::FromArgb(24, 24, 27)
    Sidebar   = [System.Drawing.Color]::FromArgb(16, 16, 18)
    Header    = [System.Drawing.Color]::FromArgb(32, 32, 36)
    Log       = [System.Drawing.Color]::FromArgb(12, 12, 14)
    Text      = [System.Drawing.Color]::FromArgb(235, 235, 240)
    SubText   = [System.Drawing.Color]::FromArgb(150, 150, 160)
    Section   = [System.Drawing.Color]::FromArgb(70, 170, 255)
    Line      = [System.Drawing.Color]::FromArgb(50, 50, 56)
    NavIdle   = [System.Drawing.Color]::FromArgb(16, 16, 18)
    NavActive = [System.Drawing.Color]::FromArgb(40, 40, 46)
    NavText   = [System.Drawing.Color]::FromArgb(190, 190, 200)
}
$Script:BtnStyles = @{
    normal  = @([System.Drawing.Color]::FromArgb(48, 48, 54),  [System.Drawing.Color]::FromArgb(64, 64, 72))
    primary = @([System.Drawing.Color]::FromArgb(0, 110, 200), [System.Drawing.Color]::FromArgb(20, 135, 230))
    success = @([System.Drawing.Color]::FromArgb(30, 135, 70), [System.Drawing.Color]::FromArgb(40, 160, 85))
    warn    = @([System.Drawing.Color]::FromArgb(165, 95, 0),  [System.Drawing.Color]::FromArgb(190, 115, 10))
    danger  = @([System.Drawing.Color]::FromArgb(170, 35, 35), [System.Drawing.Color]::FromArgb(200, 50, 50))
}
$Script:ColX = @(20, 263, 506)
$Script:ColW = 233
$Script:RowH = 34
$Script:RowGap = 7

$Script:Tips = New-Object System.Windows.Forms.ToolTip
$Script:Tips.AutoPopDelay = 15000
$Script:Tips.InitialDelay = 350
$Script:Tips.ReshowDelay = 150

# ---------- building blocks ----------
function New-ToolButton {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [scriptblock]$Action, [string]$Style = 'normal', [string]$Tip = '', [switch]$Bold)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Script:BtnStyles[$Style][0]
    $b.FlatAppearance.MouseOverBackColor = $Script:BtnStyles[$Style][1]
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Bold) { $b.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold) }
    else { $b.Font = New-Object System.Drawing.Font("Segoe UI", 9) }
    if ($Action) {
        $b.Tag = $Action
        $b.Add_Click({ param($sender, $e) Invoke-ToolkitAction $sender.Tag })
    }
    if ($Tip) { $Script:Tips.SetToolTip($b, $Tip) }
    $Parent.Controls.Add($b)
    return $b
}

function New-ToolPanel {
    param([string]$Title, [string]$Subtitle = '')
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'
    $p.Visible = $false
    $p.AutoScroll = $true
    $p.BackColor = $Script:Clr.Window
    $panelContainer.Controls.Add($p)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Title
    $l.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $l.ForeColor = $Script:Clr.Text
    $l.Location = New-Object System.Drawing.Point(18, 10)
    $l.AutoSize = $true
    $p.Controls.Add($l)
    if ($Subtitle) {
        $s = New-Object System.Windows.Forms.Label
        $s.Text = $Subtitle
        $s.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $s.ForeColor = $Script:Clr.SubText
        $s.Location = New-Object System.Drawing.Point(20, 38)
        $s.Size = New-Object System.Drawing.Size(720, 18)
        $p.Controls.Add($s)
    }
    return $p
}

function Add-Section {
    param($Panel, [string]$Text, [ref]$Y)
    $Y.Value += 8
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text.ToUpper()
    $l.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
    $l.ForeColor = $Script:Clr.Section
    $l.Location = New-Object System.Drawing.Point(20, $Y.Value)
    $l.AutoSize = $true
    $Panel.Controls.Add($l)
    $line = New-Object System.Windows.Forms.Panel
    $line.BackColor = $Script:Clr.Line
    $line.Location = New-Object System.Drawing.Point(20, ($Y.Value + 19))
    $line.Size = New-Object System.Drawing.Size(719, 1)
    $Panel.Controls.Add($line)
    $Y.Value += 27
}

# Items: @{ T = text; A = {action}; S = style; Tip = tooltip; Span = columns }
function Add-ButtonRow {
    param($Panel, [ref]$Y, [object[]]$Items)
    $col = 0
    foreach ($it in $Items) {
        $span = if ($it.Span) { [int]$it.Span } else { 1 }
        $w = ($Script:ColW * $span) + (10 * ($span - 1))
        $style = if ($it.S) { $it.S } else { 'normal' }
        [void](New-ToolButton -Parent $Panel -Text $it.T -X $Script:ColX[$col] -Y $Y.Value -W $w -H $Script:RowH -Action $it.A -Style $style -Tip $it.Tip)
        $col += $span
    }
    $Y.Value += $Script:RowH + $Script:RowGap
}

function New-UiLabel {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 0, [int]$H = 0, $Color = $null, [float]$Size = 9, [switch]$Bold)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $l.Font = New-Object System.Drawing.Font("Segoe UI", $Size, $style)
    $l.ForeColor = if ($Color) { $Color } else { $Script:Clr.Text }
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    if ($W -gt 0) { $l.Size = New-Object System.Drawing.Size($W, $H) } else { $l.AutoSize = $true }
    $Parent.Controls.Add($l)
    return $l
}

function Set-ITToolkitBusyIndicator {
    param([bool]$On, [string]$Label = '')
    if (-not $Script:LblBusy) { return }
    if ($On) {
        $Script:LblBusy.Text = if ($Label) { "WORKING: $Label" } else { 'WORKING...' }
        $Script:LblBusy.Visible = $true
    } else {
        $Script:LblBusy.Visible = $false
    }
}

# ---------- window ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Enterprise IT Master Toolkit v4.1"
$form.Size = New-Object System.Drawing.Size(1000, 820)
$form.StartPosition = "CenterScreen"
$form.BackColor = $Script:Clr.Window
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.ShowInTaskbar = $true
try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path) } catch { }

$form.Add_FormClosing({
    param($sender, $e)
    if ($Script:BusyDepth -gt 0) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "A task (e.g. updates) is still running. Closing now can leave it half-finished.`r`n`r`nClose anyway?",
            "IT Toolkit",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true }
    }
})

$form.Add_FormClosed({
    [SystemSleep]::SetThreadExecutionState([SystemSleep]::ES_CONTINUOUS) | Out-Null
    if (-not $Script:RebootPending) {
        Clear-ITToolkitTempArtifacts
    } else {
        Save-ITToolkitSessionState
    }
})

# ---------- sidebar ----------
$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Width = 220
$sidebar.Dock = 'Left'
$sidebar.BackColor = $Script:Clr.Sidebar
$form.Controls.Add($sidebar)

[void](New-UiLabel $sidebar 'IT TOOLKIT' 20 16 -Size 15 -Bold)
[void](New-UiLabel $sidebar 'Master Toolkit v4.1' 22 46 -Color $Script:Clr.SubText -Size 8.5)

# ---------- header strip (device info + busy indicator) ----------
$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(220, 0)
$header.Size = New-Object System.Drawing.Size(764, 50)
$header.BackColor = $Script:Clr.Header
$form.Controls.Add($header)

$devName = $env:COMPUTERNAME
$devLine = ''
try {
    $hcs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $hbios = Get-CimInstance Win32_BIOS -ErrorAction Stop
    $hUser = if ($hcs.UserName) { $hcs.UserName } else { '(no one signed in)' }
    $devLine = "{0} {1}   |   SN {2}   |   User: {3}" -f $hcs.Manufacturer, $hcs.Model, $hbios.SerialNumber, $hUser
} catch { }
[void](New-UiLabel $header $devName 16 6 -Size 11 -Bold)
[void](New-UiLabel $header $devLine 17 28 -Color $Script:Clr.SubText -Size 8.5)

$Script:LblBusy = New-UiLabel $header 'WORKING...' 400 26 350 20 ([System.Drawing.Color]::Gold) 9 -Bold
$Script:LblBusy.TextAlign = 'MiddleRight'
$Script:LblBusy.Visible = $false

# ---------- content area ----------
$panelContainer = New-Object System.Windows.Forms.Panel
$panelContainer.Location = New-Object System.Drawing.Point(220, 50)
$panelContainer.Size = New-Object System.Drawing.Size(764, 450)
$panelContainer.BackColor = $Script:Clr.Window
$form.Controls.Add($panelContainer)

# =====================================================================
# HOME
# =====================================================================
$pnlHome = New-ToolPanel 'Home' 'Everyday workflows. Hover any button for details.'

function New-HomeCard {
    param([int]$X, [int]$Y, [string]$Title, [string]$Desc, [scriptblock]$Action, [string]$Style, [string]$Tip)
    [void](New-ToolButton -Parent $pnlHome -Text $Title -X $X -Y $Y -W 350 -H 44 -Action $Action -Style $Style -Tip $Tip -Bold)
    [void](New-UiLabel $pnlHome $Desc ($X + 2) ($Y + 48) 348 34 $Script:Clr.SubText 8.5)
}
New-HomeCard 20 70 'OOBE Prep' 'New device at OOBE: Autopilot hash, time zone, power plan, then Windows + Dell updates until clean.' { Run-OobePrep } 'success' 'Run from Shift+F10 at OOBE. Reopens itself after each restart and finishes with a fully-patched check.'
New-HomeCard 384 70 'Run Master Update' 'Windows + Dell + winget app updates. Restarts and resumes on its own, then verifies.' { Run-MasterUpdateSequence } 'primary' 'Full update loop for a signed-in device.'
New-HomeCard 20 162 'Verify Fully Patched' 'Final check before shipping. If anything is missing it offers to install it and re-checks.' { Run-VerifyAndFix } 'success' 'Checks first. If NOT READY it offers to install what is missing (and restart if needed), then checks again.'
New-HomeCard 384 162 'Run System Cleanup' 'Frees disk space: delivery cache, orphaned installers, WinSxS, Installer compression.' { Run-MasterCleanup } 'normal' 'Asks before moving orphaned installer files.'
New-HomeCard 20 254 'Copy Ticket Notes' 'Everything you did this session, with results, ready to paste into the ticket.' { Show-ITToolkitTicketNotes } 'normal' 'Opens an editable preview and copies it to the clipboard.'
New-HomeCard 384 254 'Before / After Report' 'HTML report of what changed since the toolkit opened, plus the work log.' { Run-HealthReport } 'normal' 'Saved to the Desktop (or the USB during OOBE) and opened.'

# =====================================================================
# DEVICE SETUP
# =====================================================================
$pnlSetup = New-ToolPanel 'Device Setup' 'OOBE / Autopilot on the right. Full setup on the left, after the first sign-in.'

[void](New-UiLabel $pnlSetup 'NEW PC SETUP' 20 66 -Color $Script:Clr.Section -Size 8.5 -Bold)
[void](New-UiLabel $pnlSetup 'OOBE / AUTOPILOT' 506 66 -Color $Script:Clr.Section -Size 8.5 -Bold)

function New-SetupCheck {
    param([string]$Text, [int]$Y, [bool]$Checked = $true, [int]$W = 135)
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $Text
    $c.ForeColor = $Script:Clr.Text
    $c.Location = New-Object System.Drawing.Point(20, $Y)
    $c.Size = New-Object System.Drawing.Size($W, 24)
    $c.Checked = $Checked
    $pnlSetup.Controls.Add($c)
    return $c
}

$chkSetupRename = New-SetupCheck 'Rename PC to:' 90 $false
$txtSetupName = New-Object System.Windows.Forms.TextBox
$txtSetupName.Location = New-Object System.Drawing.Point(160, 90)
$txtSetupName.Size = New-Object System.Drawing.Size(180, 25)
$txtSetupName.CharacterCasing = 'Upper'
$txtSetupName.MaxLength = 15
$pnlSetup.Controls.Add($txtSetupName)
$Script:Tips.SetToolTip($chkSetupRename, 'Leave off for Autopilot devices - Autopilot names them.')

$chkSetupTz = New-SetupCheck 'Time zone:' 120
$cmbSetupTz = New-Object System.Windows.Forms.ComboBox
$cmbSetupTz.DropDownStyle = 'DropDownList'
$cmbSetupTz.Location = New-Object System.Drawing.Point(160, 120)
$cmbSetupTz.Size = New-Object System.Drawing.Size(320, 25)
try { foreach ($z in (Get-TimeZone -ListAvailable | Sort-Object BaseUtcOffset, Id)) { [void]$cmbSetupTz.Items.Add($z.Id) } } catch { }
try { $cmbSetupTz.SelectedItem = (Get-TimeZone).Id } catch { }
$pnlSetup.Controls.Add($cmbSetupTz)

$chkSetupPower = New-SetupCheck 'Power plan:' 150
$cmbSetupPower = New-Object System.Windows.Forms.ComboBox
$cmbSetupPower.DropDownStyle = 'DropDownList'
$cmbSetupPower.Location = New-Object System.Drawing.Point(160, 150)
$cmbSetupPower.Size = New-Object System.Drawing.Size(180, 25)
[void]$cmbSetupPower.Items.AddRange(@('Balanced', 'High performance', 'Power saver'))
$cmbSetupPower.SelectedIndex = 0
$pnlSetup.Controls.Add($cmbSetupPower)

$chkSetupApps = New-SetupCheck 'Install standard apps' 180 $true 330
$chkSetupBitLocker = New-SetupCheck 'Back up BitLocker key to Entra ID / AD' 210 $true 330
$chkSetupUpdate = New-SetupCheck 'Run Master Update when done' 240 $true 330

[void](New-ToolButton -Parent $pnlSetup -Text 'Run Setup' -X 20 -Y 272 -W 233 -H 34 -Action { Run-NewPcSetup } -Style 'success' -Tip 'Runs the checked steps above. Progress shows in the list below.' -Bold)
[void](New-ToolButton -Parent $pnlSetup -Text 'Edit app list...' -X 263 -Y 272 -W 150 -H 34 -Action { Open-ITToolkitSettings } -Tip 'Opens the settings file (StandardApps).')

[void](New-ToolButton -Parent $pnlSetup -Text 'OOBE Prep' -X 506 -Y 90 -W 233 -H 44 -Action { Run-OobePrep } -Style 'success' -Tip 'Hash + time zone + power + Windows/Dell updates. Hands-off after the first click.' -Bold)
[void](New-ToolButton -Parent $pnlSetup -Text 'Extract Autopilot Hash' -X 506 -Y 141 -W 233 -H 34 -Action { Run-AutopilotHash } -Tip 'Asks for the Group Tag (pre-filled if this serial is already saved), then saves Autopilot\AP_<serial>.csv on the USB. Re-running replaces the entry instead of duplicating it.')
[void](New-ToolButton -Parent $pnlSetup -Text 'Verify Fully Patched' -X 506 -Y 182 -W 233 -H 34 -Action { Run-VerifyAndFix } -Tip 'Checks first; if NOT READY it offers to fix it and checks again.')
[void](New-UiLabel $pnlSetup 'Import the CSV in Intune while updates run so the profile assigns in time.' 508 222 230 44 $Script:Clr.SubText 8)

$lstSetup = New-Object System.Windows.Forms.ListView
$lstSetup.View = 'Details'
$lstSetup.FullRowSelect = $true
$lstSetup.GridLines = $false
$lstSetup.HeaderStyle = 'Nonclickable'
$lstSetup.Location = New-Object System.Drawing.Point(20, 316)
$lstSetup.Size = New-Object System.Drawing.Size(719, 124)
$lstSetup.BackColor = $Script:Clr.Log
$lstSetup.ForeColor = $Script:Clr.Text
$lstSetup.BorderStyle = 'FixedSingle'
[void]$lstSetup.Columns.Add('Step', 260)
[void]$lstSetup.Columns.Add('Status', 80)
[void]$lstSetup.Columns.Add('Detail', 355)
$pnlSetup.Controls.Add($lstSetup)

Update-ITToolkitSetupDefaults

# =====================================================================
# QUICK CHECKS (read-only)
# =====================================================================
$pnlQuick = New-ToolPanel 'Quick Checks' 'Read-only. Nothing here changes the PC.'
[void](New-ToolButton -Parent $pnlQuick -Text 'Run All Checks' -X 506 -Y 14 -W 233 -H 32 -Action { Run-AllQuickChecks } -Style 'primary' -Tip 'Runs every read-only check on this tab in one go.' -Bold)
$y = 56
Add-Section $pnlQuick 'Device & Identity' ([ref]$y)
Add-ButtonRow $pnlQuick ([ref]$y) @(
    @{ T = 'System Info (+ Clipboard)'; A = { Run-SystemInfo }; Tip = 'Name, model, serial, OS, IP. Also copied for the ticket.' },
    @{ T = 'Who Is Logged On'; A = { Run-WhoIsLoggedOn } },
    @{ T = 'Pending Reboot Check'; A = { Run-PendingRebootCheck } }
)
Add-ButtonRow $pnlQuick ([ref]$y) @(
    @{ T = 'Windows Activation'; A = { Run-WindowsActivationStatus } },
    @{ T = 'TPM / Secure Boot'; A = { Run-TpmSecureBootCheck } },
    @{ T = 'Certificates'; A = { Run-CertificateQuickView }; Tip = 'Machine + user personal certs, expiring ones highlighted.' }
)
Add-Section $pnlQuick 'Hardware' ([ref]$y)
Add-ButtonRow $pnlQuick ([ref]$y) @(
    @{ T = 'Disk Health / Free Space'; A = { Run-DiskHealthCheck } },
    @{ T = 'Disk Predictive Failure'; A = { Run-DiskPredictiveFailure }; Tip = 'SMART failure prediction.' },
    @{ T = 'Problem Devices'; A = { Run-ProblemDevices }; Tip = 'Device Manager yellow bangs with plain-English error codes.' }
)
Add-ButtonRow $pnlQuick ([ref]$y) @(
    @{ T = 'Battery Status / Report'; A = { Run-BatteryReport } },
    @{ T = 'Display / Scaling'; A = { Run-DisplayScalingInfo } },
    @{ T = 'USB Devices'; A = { Run-UsbDeviceList } }
)
Add-ButtonRow $pnlQuick ([ref]$y) @(
    @{ T = 'Dell / BIOS Info + Update Check'; A = { Run-DellInfo }; Tip = 'BIOS version and whether Dell has a newer BIOS/firmware.' },
    @{ T = 'Dell Warranty Page'; A = { Open-DellWarranty } }
)
Add-Section $pnlQuick 'Apps & Settings' ([ref]$y)
Add-ButtonRow $pnlQuick ([ref]$y) @(
    @{ T = 'Startup Apps'; A = { Run-StartupAppsSummary } },
    @{ T = 'Default Apps'; A = { Run-DefaultAppsQuickView } },
    @{ T = 'Printer Status'; A = { Run-PrinterStatus } }
)
Add-ButtonRow $pnlQuick ([ref]$y) @(
    @{ T = 'Winget Updates (Preview)'; A = { Run-WingetOutdatedPreview }; Tip = 'Lists app updates without installing anything.' }
)

# =====================================================================
# FIXES
# =====================================================================
$pnlFixes = New-ToolPanel 'Fixes' 'Common Windows repairs. Orange / red buttons ask before changing anything big.'
$y = 62
Add-Section $pnlFixes 'Windows Update Repair' ([ref]$y)
Add-ButtonRow $pnlFixes ([ref]$y) @(
    @{ T = 'SFC / DISM Repair'; A = { Run-Recovery }; S = 'primary'; Tip = 'DISM RestoreHealth then SFC. 15-40 minutes.' },
    @{ T = 'Update Ghostbuster'; A = { Run-Ghostbuster }; Tip = 'Moves stuck update downloads aside so Windows Update re-downloads them.' },
    @{ T = 'Fast Nuke SoftwareDistribution'; A = { Run-FastNukeSoftwareDistribution }; S = 'danger'; Tip = 'Deletes the whole update cache. Type YES to confirm.' }
)
Add-Section $pnlFixes 'Desktop & Shell' ([ref]$y)
Add-ButtonRow $pnlFixes ([ref]$y) @(
    @{ T = 'Restart Explorer'; A = { Run-RestartExplorer } },
    @{ T = 'Reset Start / Search'; A = { Run-ResetStartSearch } },
    @{ T = 'Clear Icon / Thumbnail Cache'; A = { Run-ClearIconThumbnailCache } }
)
Add-Section $pnlFixes 'Devices' ([ref]$y)
Add-ButtonRow $pnlFixes ([ref]$y) @(
    @{ T = 'Reset Camera / Audio'; A = { Run-ResetMediaDrivers } },
    @{ T = 'Re-enable Problem USB'; A = { Run-UsbDeviceResetProblem } },
    @{ T = 'Rescan Hardware'; A = { Run-RescanHardware } }
)
Add-Section $pnlFixes 'Cleanup, Time & Power' ([ref]$y)
Add-ButtonRow $pnlFixes ([ref]$y) @(
    @{ T = 'Clear Temp Files'; A = { Run-ClearTempFiles }; S = 'warn' },
    @{ T = 'Clear Print Queue'; A = { Run-ClearPrintQueue }; S = 'warn' },
    @{ T = 'Force Time Sync'; A = { Run-TimeSync } }
)
Add-ButtonRow $pnlFixes ([ref]$y) @(
    @{ T = 'Keep PC Awake'; A = { Run-KeepAwake }; Tip = 'Stops sleep while the toolkit is open (on by default).' },
    @{ T = 'Allow Normal Sleep'; A = { Run-RestoreNormalPower } },
    @{ T = 'Unlock BitLocker Drive'; A = { Run-UnlockBitLocker }; Tip = 'Unlock a locked data drive with its password or recovery key.' }
)

# =====================================================================
# NETWORK
# =====================================================================
$pnlNetwork = New-ToolPanel 'Network' 'Connection status, reachability tests and network resets.'
$y = 62
Add-Section $pnlNetwork 'Status' ([ref]$y)
Add-ButtonRow $pnlNetwork ([ref]$y) @(
    @{ T = 'Network Summary'; A = { Run-NetworkSummary }; S = 'primary'; Tip = 'Adapters, IPs, gateway (with ping), DNS servers.' },
    @{ T = 'Wi-Fi Details'; A = { Run-WifiDetails }; Tip = 'SSID, signal strength, band, link speed.' },
    @{ T = 'Wi-Fi Report (HTML)'; A = { Run-WifiReport }; Tip = 'Windows WLAN report: 3 days of connects/disconnects.' }
)
Add-ButtonRow $pnlNetwork ([ref]$y) @(
    @{ T = 'Run Connectivity Tests'; A = { Run-ConnectivityTests }; S = 'primary'; Span = 2; Tip = 'DNS + port checks against Microsoft/Intune endpoints. Edit the list in Settings (NetworkTests).' },
    @{ T = 'Proxy / WPAD Check'; A = { Run-ProxyWpadCheck } }
)
Add-Section $pnlNetwork 'Custom Test' ([ref]$y)
[void](New-UiLabel $pnlNetwork 'Host / IP:' 20 ($y + 4))
$txtNetHost = New-Object System.Windows.Forms.TextBox
$txtNetHost.Location = New-Object System.Drawing.Point(90, $y)
$txtNetHost.Size = New-Object System.Drawing.Size(300, 25)
$pnlNetwork.Controls.Add($txtNetHost)
[void](New-UiLabel $pnlNetwork 'Port:' 410 ($y + 4))
$txtNetPort = New-Object System.Windows.Forms.TextBox
$txtNetPort.Location = New-Object System.Drawing.Point(450, $y)
$txtNetPort.Size = New-Object System.Drawing.Size(60, 25)
$txtNetPort.Text = '443'
$pnlNetwork.Controls.Add($txtNetPort)
$y += 34
Add-ButtonRow $pnlNetwork ([ref]$y) @(
    @{ T = 'Ping'; A = { Run-CustomPing } },
    @{ T = 'Test Port'; A = { Run-CustomPortTest }; S = 'primary'; Tip = 'Best test for cloud services - many block ping.' },
    @{ T = 'Traceroute'; A = { Run-CustomTraceroute } }
)
Add-Section $pnlNetwork 'Fixes' ([ref]$y)
Add-ButtonRow $pnlNetwork ([ref]$y) @(
    @{ T = 'Flush DNS'; A = { Run-FlushDns } },
    @{ T = 'VPN Adapter Reset'; A = { Run-VpnAdapterReset }; S = 'warn' },
    @{ T = 'Deep Network Reset'; A = { Run-NetworkReset }; S = 'warn'; Tip = 'Release/renew + Winsock/TCP-IP reset. Remote sessions will drop.' }
)

# =====================================================================
# OFFICE 365
# =====================================================================
$pnlOffice = New-ToolPanel 'Office 365' "Fixes target the SIGNED-IN user's profile, even if you elevated with another admin account."
$y = 62
Add-Section $pnlOffice 'Teams / OneDrive / Sign-in' ([ref]$y)
Add-ButtonRow $pnlOffice ([ref]$y) @(
    @{ T = 'Clear Teams Cache'; A = { Run-ClearTeamsCache }; S = 'primary'; Tip = 'Closes Teams, clears new + classic cache, relaunches it.' },
    @{ T = 'Reset OneDrive'; A = { Run-ResetOneDrive }; S = 'warn'; Tip = 'No files deleted; OneDrive re-syncs.' },
    @{ T = 'Fix Office Sign-in Loop'; A = { Run-FixOfficeSignIn }; S = 'warn'; Tip = 'Clears cached Office identities, token cache and Office credentials.' }
)
Add-Section $pnlOffice 'Office Apps' ([ref]$y)
Add-ButtonRow $pnlOffice ([ref]$y) @(
    @{ T = 'Office Version / Channel'; A = { Run-OfficeInfo } },
    @{ T = 'Force Office Update'; A = { Run-OfficeUpdate }; S = 'primary' },
    @{ T = 'Office Quick Repair'; A = { Run-OfficeRepair -Type QuickRepair }; S = 'warn'; Tip = '5-10 minutes, no download.' }
)
Add-ButtonRow $pnlOffice ([ref]$y) @(
    @{ T = 'Office Online Repair (full)'; A = { Run-OfficeRepair -Type FullRepair }; S = 'danger'; Tip = 'Re-downloads and reinstalls Office (30-60+ min). Use if Quick Repair fails.' }
)

# =====================================================================
# SCCM / INTUNE
# =====================================================================
$pnlEndpoint = New-ToolPanel 'SCCM / Intune' 'ConfigMgr client actions and Intune troubleshooting.'
$y = 62
Add-Section $pnlEndpoint 'ConfigMgr (SCCM) Client' ([ref]$y)
Add-ButtonRow $pnlEndpoint ([ref]$y) @(
    @{ T = 'Client Status'; A = { Run-SccmClientStatus }; S = 'primary'; Tip = 'Version, site, management point, co-management, cache.' },
    @{ T = 'Run ALL Client Actions'; A = { Run-SccmAllActions }; S = 'primary' },
    @{ T = 'Open Software Center'; A = { Open-SoftwareCenter } }
)
Add-ButtonRow $pnlEndpoint ([ref]$y) @(
    @{ T = 'Machine Policy'; A = { Invoke-ITToolkitSccmAction -Names 'Machine Policy' } },
    @{ T = 'Hardware Inventory'; A = { Invoke-ITToolkitSccmAction -Names 'Hardware Inventory' } },
    @{ T = 'App Deployment Eval'; A = { Invoke-ITToolkitSccmAction -Names 'Application Deployment Eval' } }
)
Add-ButtonRow $pnlEndpoint ([ref]$y) @(
    @{ T = 'Software Update Scan'; A = { Invoke-ITToolkitSccmAction -Names 'Software Update Scan' } },
    @{ T = 'Software Update Eval'; A = { Invoke-ITToolkitSccmAction -Names 'Software Update Deployment Eval' } },
    @{ T = 'SCCM Log Viewer'; A = { Show-ITToolkitLogViewer -Preset SCCM }; Tip = 'AppEnforce, CAS, WUAHandler and more - errors in red.' }
)
Add-ButtonRow $pnlEndpoint ([ref]$y) @(
    @{ T = 'Repair Client (ccmrepair)'; A = { Run-SccmRepair }; S = 'warn' },
    @{ T = 'Clear ccmcache'; A = { Run-SccmClearCache }; S = 'warn' },
    @{ T = 'Open CCM Logs Folder'; A = { Open-SccmLogsFolder } }
)
Add-Section $pnlEndpoint 'Intune' ([ref]$y)
Add-ButtonRow $pnlEndpoint ([ref]$y) @(
    @{ T = 'Intune Sync + Last Result'; A = { Run-IntuneSyncStatus }; S = 'primary' },
    @{ T = 'Restart IME Service'; A = { Run-RestartIme } },
    @{ T = 'Retry Failed Win32 Apps'; A = { Run-RetryFailedWin32Apps }; S = 'warn'; Tip = 'Clears failed state + retry timer so Intune retries now.' }
)
Add-ButtonRow $pnlEndpoint ([ref]$y) @(
    @{ T = 'Intune Log Viewer'; A = { Show-ITToolkitLogViewer -Preset Intune }; Tip = 'IME / AppWorkload logs - errors in red.' },
    @{ T = 'MDM Diagnostics ZIP'; A = { Run-MdmDiagnostics } },
    @{ T = 'Open IME Logs Folder'; A = { Open-ImeLogsFolder } }
)
Add-ButtonRow $pnlEndpoint ([ref]$y) @(
    @{ T = 'Autopilot / ESP Hints'; A = { Run-AutopilotEnrollmentHints } },
    @{ T = 'Entra / dsreg Status'; A = { Run-DsregStatus } }
)

# =====================================================================
# DIAGNOSTICS
# =====================================================================
$pnlDiag = New-ToolPanel 'Diagnostics' 'Event logs, disk usage and exports for escalations.'
$y = 62
Add-Section $pnlDiag 'Event Logs' ([ref]$y)
Add-ButtonRow $pnlDiag ([ref]$y) @(
    @{ T = 'Event Log Viewer'; A = { Show-EventLogViewer }; S = 'primary'; Tip = 'Critical/Error events, filterable, double-click for detail.' },
    @{ T = 'Quick BSOD / Power Scan'; A = { Run-EventGrabber } },
    @{ T = 'Export Errors CSV'; A = { Run-ExportEventLogs } }
)
Add-ButtonRow $pnlDiag ([ref]$y) @(
    @{ T = 'Open Windows Event Viewer'; A = { Open-WindowsEventViewer } }
)
Add-Section $pnlDiag 'Disk Space' ([ref]$y)
Add-ButtonRow $pnlDiag ([ref]$y) @(
    @{ T = 'Largest Folders on C:'; A = { Run-NativeDiskScanner }; Tip = 'Top 10 folders by size. No install needed.' },
    @{ T = 'TreeSize'; A = { Run-TreeSize }; Tip = 'Launches TreeSize Free (installs it with winget if missing).' }
)
Add-Section $pnlDiag 'Reports & Exports' ([ref]$y)
Add-ButtonRow $pnlDiag ([ref]$y) @(
    @{ T = 'Support ZIP'; A = { New-SupportZip }; S = 'primary'; Tip = 'System info, toolkit log, dsreg and 24h of errors in one ZIP.' },
    @{ T = 'Export Drives + Printers'; A = { Run-ExportMappedDrivesPrinters }; Tip = 'Snapshot before a reimage or profile rebuild.' },
    @{ T = 'Extract BitLocker Keys'; A = { Run-BitLockerExtractor }; S = 'warn'; Tip = 'Saves recovery keys to a text file - handle securely.' }
)

# =====================================================================
# USERS & APPS
# =====================================================================
$pnlAdmin = New-ToolPanel 'Users & Apps' 'Local accounts, profiles and aggressive software removal.'
$y = 62
Add-Section $pnlAdmin 'Local Accounts' ([ref]$y)
[void](New-UiLabel $pnlAdmin 'Username (or profile folder name):' 20 ($y + 2))
$radLocal = New-Object System.Windows.Forms.RadioButton
$radLocal.Text = "Local / Domain"
$radLocal.Location = New-Object System.Drawing.Point(263, $y)
$radLocal.ForeColor = $Script:Clr.Text
$radLocal.AutoSize = $true
$radLocal.Checked = $true
$pnlAdmin.Controls.Add($radLocal)
$radAzure = New-Object System.Windows.Forms.RadioButton
$radAzure.Text = "Entra ID (Azure AD)"
$radAzure.Location = New-Object System.Drawing.Point(390, $y)
$radAzure.ForeColor = $Script:Clr.Text
$radAzure.AutoSize = $true
$pnlAdmin.Controls.Add($radAzure)
$Script:Tips.SetToolTip($radAzure, 'Use the full email / UPN, e.g. jdoe@company.com')
$y += 26
$txtAdminUser = New-Object System.Windows.Forms.TextBox
$txtAdminUser.Location = New-Object System.Drawing.Point(20, $y)
$txtAdminUser.Size = New-Object System.Drawing.Size(476, 25)
$pnlAdmin.Controls.Add($txtAdminUser)
$y += 34
Add-ButtonRow $pnlAdmin ([ref]$y) @(
    @{ T = 'Add as Local Admin'; A = { Run-AddAdmin -Username $txtAdminUser.Text -IsAzureAD $radAzure.Checked }; S = 'primary' },
    @{ T = 'Delete Profile'; S = 'danger'; Tip = 'Permanently deletes the profile folder + registry. Type YES to confirm.'; A = {
            if (-not (Confirm-TypeYes -Title 'Delete Profile' -Message ("Permanently delete local profile for '{0}'?" -f $txtAdminUser.Text))) {
                Write-GuiLog 'Profile delete canceled.' 'Yellow'
                return
            }
            Run-RemoveProfile -Username $txtAdminUser.Text
        }
    },
    @{ T = 'List Local Admins / RDU'; A = { Run-LocalAdminInventory } }
)
Add-Section $pnlAdmin 'Software Removal' ([ref]$y)
Add-ButtonRow $pnlAdmin ([ref]$y) @(
    @{ T = 'Remove Adobe (all products)'; A = { Run-RemoveAdobe }; S = 'danger'; Tip = 'Lists every Adobe product found and asks before uninstalling.' },
    @{ T = 'Remove SAP GUI'; A = { Run-RemoveSAP }; S = 'danger' }
)

# =====================================================================
# SIDEBAR NAVIGATION (grouped)
# =====================================================================
$Script:NavButtons = New-Object System.Collections.Generic.List[object]
$Script:NavIndicator = New-Object System.Windows.Forms.Panel
$Script:NavIndicator.BackColor = $Script:Clr.Section
$Script:NavIndicator.Size = New-Object System.Drawing.Size(4, 34)
$sidebar.Controls.Add($Script:NavIndicator)

function Select-ITToolkitNav {
    param($Button)
    foreach ($n in $Script:NavButtons) {
        $n.Tag.Visible = $false
        $n.BackColor = $Script:Clr.NavIdle
        $n.ForeColor = $Script:Clr.NavText
    }
    $Button.Tag.Visible = $true
    $Button.BackColor = $Script:Clr.NavActive
    $Button.ForeColor = [System.Drawing.Color]::White
    $Script:NavIndicator.Location = New-Object System.Drawing.Point(0, $Button.Top)
    $Script:NavIndicator.BringToFront()
}

$navGroups = @(
    @{ Name = 'WORKFLOWS'; Items = @(@('Home', $pnlHome), @('Device Setup', $pnlSetup)) },
    @{ Name = 'TROUBLESHOOT'; Items = @(@('Quick Checks', $pnlQuick), @('Fixes', $pnlFixes), @('Network', $pnlNetwork), @('Office 365', $pnlOffice), @('SCCM / Intune', $pnlEndpoint)) },
    @{ Name = 'TOOLS'; Items = @(@('Diagnostics', $pnlDiag), @('Users & Apps', $pnlAdmin)) }
)
$navY = 80
foreach ($g in $navGroups) {
    [void](New-UiLabel $sidebar $g.Name 20 $navY -Color ([System.Drawing.Color]::FromArgb(110, 110, 120)) -Size 7.5 -Bold)
    $navY += 20
    foreach ($item in $g.Items) {
        $nb = New-Object System.Windows.Forms.Button
        $nb.Text = $item[0]
        $nb.Size = New-Object System.Drawing.Size(220, 34)
        $nb.Location = New-Object System.Drawing.Point(0, $navY)
        $nb.FlatStyle = 'Flat'
        $nb.FlatAppearance.BorderSize = 0
        $nb.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(32, 32, 38)
        $nb.BackColor = $Script:Clr.NavIdle
        $nb.ForeColor = $Script:Clr.NavText
        $nb.Font = New-Object System.Drawing.Font("Segoe UI", 10)
        $nb.TextAlign = 'MiddleLeft'
        $nb.Padding = New-Object System.Windows.Forms.Padding(22, 0, 0, 0)
        $nb.Cursor = [System.Windows.Forms.Cursors]::Hand
        $nb.Tag = $item[1]
        $nb.Add_Click({ param($sender, $e) Select-ITToolkitNav $sender })
        $sidebar.Controls.Add($nb)
        $Script:NavButtons.Add($nb) | Out-Null
        $navY += 34
    }
    $navY += 10
}

# Sidebar footer: always-available utilities
[void](New-ToolButton -Parent $sidebar -Text 'Settings' -X 12 -Y 655 -W 196 -H 30 -Action { Open-ITToolkitSettings } -Tip 'Edit Master_Toolkit_Settings.json (apps, time zone, network tests, signature). Applies when Notepad closes.')
[void](New-ToolButton -Parent $sidebar -Text 'Clean Up Toolkit Leftovers' -X 12 -Y 690 -W 196 -H 30 -Action { $Script:RebootPending = $false; Invoke-ITToolkitCleanupLeftovers } -Tip 'Removes the temp copy, resume task and state files. Normally automatic on close.')
[void](New-ToolButton -Parent $sidebar -Text 'Restart PC' -X 12 -Y 725 -W 196 -H 30 -Action { Run-RestartNow } -Style 'danger' -Tip 'Asks first. Any armed update resume still happens after the restart.')

Select-ITToolkitNav $Script:NavButtons[0]

# =====================================================================
# ACTIVITY LOG
# =====================================================================
$logPanel = New-Object System.Windows.Forms.Panel
$logPanel.Location = New-Object System.Drawing.Point(220, 500)
$logPanel.Size = New-Object System.Drawing.Size(764, 282)
$logPanel.BackColor = $Script:Clr.Log
$form.Controls.Add($logPanel)

$logTop = New-Object System.Windows.Forms.Panel
$logTop.BackColor = $Script:Clr.Line
$logTop.Location = New-Object System.Drawing.Point(0, 0)
$logTop.Size = New-Object System.Drawing.Size(764, 1)
$logPanel.Controls.Add($logTop)

[void](New-UiLabel $logPanel 'ACTIVITY LOG' 12 10 -Color $Script:Clr.SubText -Size 8.5 -Bold)

function New-LogToolButton {
    param([string]$Text, [int]$X, [scriptblock]$OnClick, [string]$Tip)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, 5)
    $b.Size = New-Object System.Drawing.Size(92, 24)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Script:BtnStyles.normal[0]
    $b.FlatAppearance.MouseOverBackColor = $Script:BtnStyles.normal[1]
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Add_Click($OnClick)
    if ($Tip) { $Script:Tips.SetToolTip($b, $Tip) }
    $logPanel.Controls.Add($b)
}
New-LogToolButton 'Ticket Notes' 362 { Invoke-ToolkitAction { Show-ITToolkitTicketNotes } } 'Copy a write-up of this session for the ticket.'
New-LogToolButton 'Save Log' 462 { Invoke-ToolkitAction { Run-SaveGuiLog } } 'Save the full log to a text file.'
New-LogToolButton 'Copy' 562 { try { [System.Windows.Forms.Clipboard]::SetText($Script:LogBox.Text) } catch { } } 'Copy the visible log to the clipboard.'
New-LogToolButton 'Clear' 662 { $Script:LogBox.Clear() } 'Clears the screen only - ticket notes and reports keep everything.'

$Script:LogBox = New-Object System.Windows.Forms.RichTextBox
$Script:LogBox.Location = New-Object System.Drawing.Point(12, 36)
$Script:LogBox.Size = New-Object System.Drawing.Size(742, 236)
$Script:LogBox.BackColor = $Script:Clr.Log
$Script:LogBox.ForeColor = $Script:Clr.Text
$Script:LogBox.Font = New-Object System.Drawing.Font("Consolas", 9.5)
$Script:LogBox.ReadOnly = $true
$Script:LogBox.ScrollBars = 'Vertical'
$Script:LogBox.BorderStyle = 'None'
$logPanel.Controls.Add($Script:LogBox)

# Locked resume (SYSTEM on someone's desktop): progress only - no admin tools exposed
if ($Script:LockedResume) {
    $panelContainer.Enabled = $false
    $sidebar.Enabled = $false
    $lockBadge = New-UiLabel $header ' RESUMED UPDATES - PROGRESS ONLY ' 470 6 0 0 ([System.Drawing.Color]::White) 8 -Bold
    $lockBadge.BackColor = $Script:BtnStyles.primary[0]
    $Script:Tips.SetToolTip($lockBadge, 'Reopened automatically after a restart. Tools are locked; this window closes itself when the job is done. Run the toolkit from the USB to use the tools.')
}

# OOBE badge in the header
if (Test-ITToolkitOobe) {
    $oobeBadge = New-UiLabel $header ' OOBE MODE ' 672 6 0 0 ([System.Drawing.Color]::White) 8 -Bold
    $oobeBadge.BackColor = $Script:BtnStyles.success[0]
}

# =====================================================================
# STARTUP / AUTO-RESUME
# =====================================================================
$form.Add_Shown({
    $c = if ($Script:SettingsStatus -match 'ERROR') { 'Red' } else { 'Gray' }
    Write-GuiLog $Script:SettingsStatus $c
    if ($Script:IsResume -and $Script:SessionRestoredCount) {
        Write-GuiLog ("Restored {0} action(s) from before the reboot (ticket notes + report stay complete)." -f $Script:SessionRestoredCount) "Gray"
    }
    if (-not $Script:HealthBaseline) {
        try { Run-CaptureBaseline } catch { }
    }
    if (Test-ITToolkitOobe) {
        $form.TopMost = $true
        $form.Activate()
        Write-GuiLog "OOBE detected: click OOBE Prep on the Home tab. Files save to the USB (ITToolkit_Output) instead of the temporary Desktop." "Cyan"
    }
    if ($Script:IsResume) {
        # Disarm the resume hook right away so it can't fire again; it's re-armed if another reboot is needed.
        try { Unregister-ScheduledTask -TaskName $Script:ResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        try { Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'ITProvisioningResume' -ErrorAction SilentlyContinue } catch { }
        if (-not $Script:RunningAsSystem) { Show-ITToolkitResumeDiagnostics }   # opened by hand = auto-reopen didn't happen
        $Script:RebootPending = $true   # keep staged files until this pass decides

        if (-not (Show-ITToolkitResumePrompt -Seconds 30)) {
            Clear-ITToolkitResumeHooks
            Write-GuiLog "Updates PAUSED. The toolkit is all yours - start them again any time with Run Master Update / OOBE Prep / Verify Fully Patched." "Yellow"
            if ($Script:LockedResume) { Close-ITToolkitAfterDelay -Seconds 5 -Message 'Updates paused.' }
            return
        }
        if ($Script:OobeMode) {
            Invoke-ToolkitAction { Run-OobeResume }
        } else {
            Invoke-ToolkitAction { Run-ProvisioningUpdates; if (-not $Script:UpdateRebootNeeded) { [void](Invoke-ITToolkitFinishLine -AutoFix) } }
        }
        # Locked resume window: close itself once the job is finished (stays open if another restart is armed)
        if ($Script:LockedResume -and -not $Script:RebootPending) {
            Close-ITToolkitAfterDelay -Seconds 60 -Message 'Update job finished.'
        }
    }
})

Write-GuiLog "Master Toolkit v4.1 online. USB can be removed. Temp files clean up when you close this window." "Cyan"
# Application.Run = proper main window: minimizes to the taskbar and restores normally.
# (ShowDialog made it a dialog owned by the console, which minimized to a stub that wouldn't come back.)
[System.Windows.Forms.Application]::Run($form)

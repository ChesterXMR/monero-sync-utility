<#
    MoneroTray.ps1

    System tray control for the Monero sync utility.

    Left-click opens the sync history window. Closing that window leaves the
    tray icon running -- only "Exit" on the right-click menu quits.

    The icon shows schedule state:
      - Monero orange logo = automation ARMED
      - Greyscale logo     = automation PAUSED (no automatic runs)

    Pause/resume and the run frequency both live on the right-click menu and
    in the history window. Nothing here ever interrupts a sync in progress.

    Start it with Start-Tray.vbs for no console window, or run directly to
    watch the console output.
#>

[CmdletBinding()]
param(
    [string] $TaskName = 'Monero Sync Utility',
    [string] $DataDir  = 'E:\Monero Blockchain',
    [int]    $RpcPort  = 18081
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- High-DPI ------------------------------------------------------------
# Must run BEFORE any window is created, or Windows falls back to bitmap
# scaling: the whole UI is rendered at 96 DPI then stretched, which is what
# made text blurry and clipped mid-word ("syncing" -> "syncinq") on this
# high-DPI display.
#
# The trade-off is that WinForms then lays out in real physical pixels, so
# every size must be multiplied by $script:UiScale below -- otherwise the
# window renders at a fraction of its intended size.
if (-not ('Native.DpiAware' -as [type])) {
    Add-Type -Namespace Native -Name DpiAware -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("shcore.dll")]
public static extern int SetProcessDpiAwareness(int value);
[DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
'@
}

# Try newest to oldest: per-monitor v2 (Win10 1703+), then per-monitor, then
# the legacy system-wide call.
$dpiSet = $false
try {
    # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
    $dpiSet = [Native.DpiAware]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))
} catch { }
if (-not $dpiSet) {
    try { $dpiSet = ([Native.DpiAware]::SetProcessDpiAwareness(2) -eq 0) } catch { }
}
if (-not $dpiSet) {
    try { [void][Native.DpiAware]::SetProcessDPIAware() } catch { }
}

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# --- Taskbar identity ----------------------------------------------------
# Without its own AppUserModelID the window is grouped under powershell.exe and
# shows PowerShell's icon in the taskbar and Start menu, because the process
# really is PowerShell. Setting a distinct ID makes Windows treat it as a
# separate application and use the window's own icon.
if (-not ('Native.AppId' -as [type])) {
    Add-Type -Namespace Native -Name AppId -MemberDefinition @'
[DllImport("shell32.dll", SetLastError = true)]
public static extern int SetCurrentProcessExplicitAppUserModelID(
    [MarshalAs(UnmanagedType.LPWStr)] string AppID);
'@
}
try { [void][Native.AppId]::SetCurrentProcessExplicitAppUserModelID('MoneroSyncUtility.Tray') } catch { }

# Live display scale. Now that the process is DPI-aware this reports the real
# DPI (240 on a 250%-scaled display) rather than a flat 96.
#
# PIXEL dimensions -- window size, row heights, padding -- are multiplied by
# this via S(). Font POINT sizes are NOT: Windows already renders points at the
# display's DPI, so scaling them as well would double-count and produce
# enormous text.
$script:UiScale = 1.0
try {
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    if ($g.DpiX -ge 96) { $script:UiScale = $g.DpiX / 96.0 }
    $g.Dispose()
} catch { }

function S {
    param([double] $n)
    [int][math]::Round($n * $script:UiScale)
}

# Single-instance guard. Without this, launching the tray by hand when the
# login shortcut has already started it leaves two icons in the tray, each
# toggling the same task and fighting over the state.
$trayMutex = New-Object System.Threading.Mutex($false, 'Global\MoneroSyncTray')
if (-not $trayMutex.WaitOne(0)) {
    Write-Host 'The Monero tray icon is already running.' -ForegroundColor Yellow
    exit 0
}

. (Join-Path $PSScriptRoot 'MoneroChecks.ps1')
. (Join-Path $PSScriptRoot 'MoneroHistory.ps1')
. (Join-Path $PSScriptRoot 'MoneroSettings.ps1')
. (Join-Path $PSScriptRoot 'MoneroDaemon.ps1')

$monerodPath = 'C:\Program Files\Monero GUI Wallet\monerod.exe'

# Shown in the header's read-only command box, for running a sync by hand.
# This is the bare daemon command, deliberately: it is what the user types in
# a terminal. Note it is NOT what "Sync now" runs -- unsupervised, monerod has
# no preflight checks, does not stop itself when synced, and records no history
# row; it is ended with Ctrl+C.
$script:ManualSyncCommand = '& "{0}" --data-dir "{1}"' -f $monerodPath, $DataDir

# Request files read by Sync-Monero.ps1 once a second while monerod runs.
$script:StopFlag      = Join-Path $PSScriptRoot '.state\request-stop'
$script:TerminateFlag = Join-Path $PSScriptRoot '.state\request-terminate'

$syncScript = Join-Path $PSScriptRoot 'Sync-Monero.ps1'
$stateDir   = Join-Path $PSScriptRoot '.state'
$logDir     = Join-Path $PSScriptRoot 'logs'
$statusFile = Join-Path $stateDir 'last-run.json'

if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir | Out-Null }

# ---------------------------------------------------------------------------
# Icons
# ---------------------------------------------------------------------------
# The Monero logo is pulled from the GUI wallet's embedded icon; the paused
# state is the same image desaturated, so both read as obviously the same
# logo in two states rather than two unrelated pictures.

$guiExe = 'C:\Program Files\Monero GUI Wallet\monero-wallet-gui.exe'

if (-not ('Native.IconEx' -as [type])) {
    Add-Type -Namespace Native -Name IconEx -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Auto)]
public static extern uint ExtractIconEx(string file, int index, IntPtr[] large, IntPtr[] small, uint count);
[DllImport("user32.dll")]
public static extern bool DestroyIcon(IntPtr handle);
'@
}

function Get-ColorIcon {
    # ExtractIconEx is preferred over ExtractAssociatedIcon because it returns
    # the 32x32 icon rather than the 16x16 one, which matters on a high-DPI
    # display where a small icon is visibly blurry in the title bar.
    if (Test-Path -LiteralPath $guiExe) {
        try {
            $large = New-Object IntPtr[] 1
            $small = New-Object IntPtr[] 1
            $n = [Native.IconEx]::ExtractIconEx($guiExe, 0, $large, $small, 1)

            if ($small[0] -ne [IntPtr]::Zero) { [void][Native.IconEx]::DestroyIcon($small[0]) }

            if ($n -gt 0 -and $large[0] -ne [IntPtr]::Zero) {
                $ico = [System.Drawing.Icon]::FromHandle($large[0]).Clone()
                [void][Native.IconEx]::DestroyIcon($large[0])
                return $ico
            }
        } catch { }

        try { return [System.Drawing.Icon]::ExtractAssociatedIcon($guiExe) } catch { }
    }
    # Fallback: draw a plain orange disc so the tray still works if the GUI
    # wallet is not installed at the expected path.
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 102, 0))
    $g.FillEllipse($brush, 2, 2, 28, 28)
    $brush.Dispose(); $g.Dispose()
    $h = $bmp.GetHicon()
    $ico = [System.Drawing.Icon]::FromHandle($h).Clone()
    $bmp.Dispose()
    return $ico
}

function ConvertTo-GreyIcon {
    param([System.Drawing.Icon] $Icon)

    $src  = $Icon.ToBitmap()
    $dest = New-Object System.Drawing.Bitmap $src.Width, $src.Height

    for ($x = 0; $x -lt $src.Width; $x++) {
        for ($y = 0; $y -lt $src.Height; $y++) {
            $p = $src.GetPixel($x, $y)
            # Luminance weights, then darkened slightly so "paused" reads as
            # dimmed rather than merely colourless.
            $l = [int](($p.R * 0.30) + ($p.G * 0.59) + ($p.B * 0.11))
            $l = [int]($l * 0.75)
            $dest.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($p.A, $l, $l, $l))
        }
    }

    $src.Dispose()
    $h   = $dest.GetHicon()
    $ico = [System.Drawing.Icon]::FromHandle($h).Clone()
    $dest.Dispose()
    return $ico
}

$iconColor = Get-ColorIcon
$iconGrey  = ConvertTo-GreyIcon -Icon $iconColor

# ---------------------------------------------------------------------------
# Scheduled task state
# ---------------------------------------------------------------------------

# The Get-ScheduledTask / Enable-ScheduledTask cmdlets take ~2.4 SECONDS per
# call on this machine, and the tray was calling them three times per click
# plus once per timer tick -- which is what made it take up to a minute to
# respond. The Schedule.Service COM object does the same job in ~9ms once its
# connection is warm, so it is created once and reused.
$script:TaskSvc    = $null
$script:TaskFolder = $null

function Get-TaskObject {
    try {
        if (-not $script:TaskSvc) {
            $script:TaskSvc = New-Object -ComObject Schedule.Service
            $script:TaskSvc.Connect()
            $script:TaskFolder = $script:TaskSvc.GetFolder('\')
        }
        return $script:TaskFolder.GetTask($TaskName)
    } catch {
        # Task missing, or the COM connection went stale -- drop it so the
        # next call rebuilds rather than failing forever.
        $script:TaskSvc = $null
        return $null
    }
}

function Get-TaskState {
    $t = Get-TaskObject
    if (-not $t) { return 'missing' }
    if (-not $t.Enabled) { return 'paused' }
    return 'armed'
}

function Set-TaskArmed {
    param([bool] $Armed)

    $t = Get-TaskObject
    if (-not $t) { return $false }

    try {
        $t.Enabled = $Armed
        return $true
    } catch {
        return $false
    }
}

# --- Run frequency --------------------------------------------------------
# Stored on the task's repetition trigger as an ISO 8601 duration. Tracked in
# MINUTES rather than hours so sub-hourly intervals (PT30M) are supported.

# Single source of truth for the offered intervals, shared by the menu and the
# history-window dropdown so the two can never drift.
$script:IntervalChoices = @(
    @{ Minutes = 30;   Label = '30 minutes' }
    @{ Minutes = 60;   Label = '1 hour' }
    @{ Minutes = 120;  Label = '2 hours' }
    @{ Minutes = 180;  Label = '3 hours' }
    @{ Minutes = 240;  Label = '4 hours' }
    @{ Minutes = 360;  Label = '6 hours' }
    @{ Minutes = 480;  Label = '8 hours' }
    @{ Minutes = 720;  Label = '12 hours' }
    @{ Minutes = 1440; Label = '24 hours' }
)

# --- Sync cap -------------------------------------------------------------
# Wall-clock limit on the syncing phase, stored in .state\settings.json and
# read by Sync-Monero.ps1 on each run.

$script:SyncCapChoices = @(
    @{ Minutes = 30;   Label = '30 minutes' }
    @{ Minutes = 60;   Label = '1 hour' }
    @{ Minutes = 120;  Label = '2 hours' }
    @{ Minutes = 180;  Label = '3 hours' }
    @{ Minutes = 240;  Label = '4 hours' }
    @{ Minutes = 360;  Label = '6 hours' }
    @{ Minutes = 720;  Label = '12 hours' }
)

function Get-SyncCapMinutes {
    (Get-MoneroSettings -Root $PSScriptRoot).MaxSyncMinutes
}

function Set-SyncCapMinutes {
    param([int] $Minutes)

    if (-not (Set-MoneroSetting -Root $PSScriptRoot -Name 'MaxSyncMinutes' -Value $Minutes)) {
        return $false
    }

    # The task's own execution limit must stay comfortably above the sync cap.
    # Task Scheduler terminates a task that exceeds it WITHOUT running cleanup,
    # which is how a daemon was orphaned on 29 Aug -- so the limit is widened
    # to the cap plus an hour of headroom for the LMDB flush.
    try {
        $t = Get-TaskObject
        if ($t) {
            $xml   = [xml]$t.Xml
            $hours = [math]::Max(2, [math]::Ceiling(($Minutes + 60) / 60))
            $xml.Task.Settings.ExecutionTimeLimit = "PT${hours}H"

            $def = $script:TaskSvc.NewTask(0)
            $def.XmlText = $xml.OuterXml
            [void]$script:TaskFolder.RegisterTaskDefinition(
                $TaskName, $def, 6, $null, $null, $def.Principal.LogonType)
        }
    } catch {
        # The setting itself saved; only the task limit could not be widened.
    }

    return $true
}

function Format-Interval {
    param([int] $Minutes)
    $c = $script:IntervalChoices | Where-Object { $_.Minutes -eq $Minutes } | Select-Object -First 1
    if ($c) { return $c.Label }
    if ($Minutes -ge 60 -and $Minutes % 60 -eq 0) { return "$($Minutes / 60) hours" }
    return "$Minutes minutes"
}

function Get-TaskIntervalMinutes {
    $t = Get-TaskObject
    if (-not $t) { return 0 }

    try {
        $iso = ([xml]$t.Xml).Task.Triggers.CalendarTrigger.Repetition.Interval
        # Durations can combine both parts, e.g. PT1H30M.
        if ($iso -match '^PT(?:(\d+)H)?(?:(\d+)M)?$') {
            $h = if ($matches[1]) { [int]$matches[1] } else { 0 }
            $m = if ($matches[2]) { [int]$matches[2] } else { 0 }
            return ($h * 60) + $m
        }
    } catch { }
    return 0
}

function Set-TaskIntervalMinutes {
    param([int] $Minutes)

    try {
        $t = Get-TaskObject
        if (-not $t) { return $false }

        $xml = [xml]$t.Xml
        $rep = $xml.Task.Triggers.CalendarTrigger.Repetition
        if (-not $rep) { return $false }

        $rep.Interval = if ($Minutes % 60 -eq 0) { "PT$($Minutes / 60)H" } else { "PT${Minutes}M" }
        $rep.Duration = 'P1D'

        # RegisterTaskDefinition with TASK_UPDATE (6) rewrites the existing
        # task in place, preserving its principal and settings.
        $def = $script:TaskSvc.NewTask(0)
        $def.XmlText = $xml.OuterXml
        [void]$script:TaskFolder.RegisterTaskDefinition($TaskName, $def, 6, $null, $null, $def.Principal.LogonType)
        return $true
    } catch {
        Write-Host "Could not change interval: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ---------------------------------------------------------------------------
# Tray icon
# ---------------------------------------------------------------------------

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$tray.ContextMenuStrip = $menu

$miStatus  = $menu.Items.Add('Status')
$miStatus.Enabled = $false
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miHistory = $menu.Items.Add('Sync history...')
$miHistory.Font = New-Object System.Drawing.Font($menu.Font, [System.Drawing.FontStyle]::Bold)
$miSyncNow = $menu.Items.Add('Sync now')
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miToggle  = $menu.Items.Add('Pause automatic syncing')

# Frequency submenu, mirroring the dropdown in the history window.
$miFreq = New-Object System.Windows.Forms.ToolStripMenuItem('Run every')
foreach ($choice in $script:IntervalChoices) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem($choice.Label)
    $item.Tag = $choice.Minutes
    $item.Add_Click({
        $mins = $this.Tag
        if ($mins -eq (Get-TaskIntervalMinutes)) { return }
        if (Set-TaskIntervalMinutes -Minutes $mins) {
            Show-Balloon 'Monero Sync' ("Now syncing every {0}." -f (Format-Interval $mins))
            Update-HistoryHeader
        } else {
            Show-Balloon 'Monero Sync' 'Could not change the frequency.' 'Error'
        }
    })
    [void]$miFreq.DropDownItems.Add($item)
}
[void]$menu.Items.Add($miFreq)

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miChecks  = $menu.Items.Add('Run checks now')
$miLogs    = $menu.Items.Add('Open logs folder')
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miExit    = $menu.Items.Add('Exit')

# Tracks a hand-started run so the UI can show it and prevent overlap.
$script:RunningJob = $null

# Cached so the timer does not re-read and re-parse the JSON every tick; it is
# only re-read when the file's timestamp actually changes.
$script:LastRunText  = 'no runs yet'
$script:LastRunStamp = [datetime]::MinValue

function Get-LastRunText {
    if (-not (Test-Path -LiteralPath $statusFile)) { return 'no runs yet' }

    try {
        $w = (Get-Item -LiteralPath $statusFile).LastWriteTime
        if ($w -gt $script:LastRunStamp) {
            $script:LastRunStamp = $w
            $s = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json
            $when = [datetime]::Parse($s.FinishedAt).ToString('MMM d HH:mm')
            $script:LastRunText = "$($s.Status) at $when"
        }
        return $script:LastRunText
    } catch {
        return 'unknown'
    }
}

# The single source of truth for "is a sync actually happening". Reality
# first: a running monerod, or a live supervisor holding the mutex. A
# background job is only trusted BRIEFLY -- during the ~4 min LMDB load before
# the daemon appears -- so a job that hangs or exited-early cannot leave the
# tray stuck on "SYNCING" (which is exactly the stale state that showed a sync
# with no monerod).
function Test-Syncing {
    $mon = Test-MonerodRunning -RpcPort $RpcPort
    if ($mon.Running) { return $true }
    if (Test-SupervisorRunning) { return $true }

    if ($script:RunningJob -and $script:RunningJob.State -eq 'Running') {
        $age = ((Get-Date) - $script:RunningJob.PSBeginTime).TotalMinutes
        if ($age -lt 6) { return $true }   # still in the LMDB-load window
    }
    return $false
}

function Update-Tray {
    $state   = Get-TaskState
    $syncing = Test-Syncing

    # A sync in progress always shows the colour icon regardless of whether
    # the schedule is armed, because something is actively happening.
    if ($state -eq 'armed' -or $syncing) {
        $tray.Icon = $iconColor
    } else {
        $tray.Icon = $iconGrey
    }

    $mins  = Get-TaskIntervalMinutes
    $every = if ($mins -gt 0) { 'every ' + (Format-Interval $mins) } else { '' }

    $stateText = switch ($state) {
        'armed'   { "Automatic syncing ON $every".Trim() }
        'paused'  { 'Automatic syncing PAUSED' }
        'missing' { 'Scheduled task not installed' }
    }

    foreach ($item in $miFreq.DropDownItems) { $item.Checked = ($item.Tag -eq $mins) }

    $activity = if ($syncing) { 'SYNCING NOW' } else { 'idle' }

    # Tray tooltips are capped at 63 characters; longer text is silently
    # dropped by Windows, so keep this short.
    $tip = "Monero Sync - $activity`n$stateText"
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $tray.Text = $tip

    $miStatus.Text = "$activity  |  last: $(Get-LastRunText)"

    $miToggle.Text = if ($state -eq 'armed') { 'Pause automatic syncing' } else { 'Resume automatic syncing' }
    $miToggle.Enabled  = ($state -ne 'missing')
    $miSyncNow.Enabled = -not $syncing
}

function Show-Balloon {
    param([string] $Title, [string] $Text, [string] $Level = 'Info')
    $tray.BalloonTipTitle = $Title
    $tray.BalloonTipText  = $Text
    $tray.BalloonTipIcon  = $Level
    $tray.ShowBalloonTip(4000)
}

function Invoke-Toggle {
    $t = Get-TaskObject

    if (-not $t) {
        Show-Balloon 'Monero Sync' 'Scheduled task not installed. Run Install-Task.ps1 first.' 'Warning'
        return
    }

    $nowArmed = -not $t.Enabled

    # Flip the icon before doing the work, so the click feels instant even if
    # the COM call takes a moment.
    $tray.Icon = if ($nowArmed) { $iconColor } else { $iconGrey }

    try {
        $t.Enabled = $nowArmed
    } catch {
        Show-Balloon 'Monero Sync' "Could not change the task: $($_.Exception.Message)" 'Error'
        Update-Tray
        return
    }

    Update-Tray

    if ($nowArmed) {
        Show-Balloon 'Monero Sync' 'Automatic syncing resumed (every 3 hours).'
    } else {
        Show-Balloon 'Monero Sync' 'Automatic syncing paused. A sync already running is not affected.'
    }
}

function Invoke-SyncNow {
    if ($script:RunningJob -and $script:RunningJob.State -eq 'Running') {
        Show-Balloon 'Monero Sync' 'A sync is already running.' 'Warning'
        return
    }

    $mon = Test-MonerodRunning -RpcPort $RpcPort
    if ($mon.Running) {
        Show-Balloon 'Monero Sync' "monerod is already running - $($mon.Detail)" 'Warning'
        return
    }

    # Run in a background job so the tray stays responsive. The sync script
    # does its own preflight, so a forced run is still safe.
    $script:RunningJob = Start-Job -ScriptBlock {
        param($script)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script
    } -ArgumentList $syncScript

    Update-Tray
    Show-Balloon 'Monero Sync' 'Sync started. This takes ~10 minutes minimum.'
}

function Test-SupervisorRunning {
    <#
        Is a Sync-Monero.ps1 run in progress? It holds this mutex for its
        whole lifetime, so failing to grab it means a supervisor is alive.
    #>
    try {
        $m = New-Object System.Threading.Mutex($false, 'Global\MoneroSyncUtility')
        try {
            if ($m.WaitOne(0)) { $m.ReleaseMutex(); return $false }
            return $true
        } finally { $m.Dispose() }
    } catch {
        return $false
    }
}

function Invoke-StopSync {
    <#
        Graceful stop. If a supervising run exists it is asked to stop via the
        request file, so it performs the shutdown, the marker check and the
        history entry itself. With no supervisor (an orphan or a hand-started
        daemon) the "monerod exit" command is run directly.
    #>
    $mon = Test-MonerodRunning -RpcPort $RpcPort
    if (-not $mon.Running) {
        Show-Balloon 'Monero Sync' 'Nothing is syncing.' 'Info'
        Update-RunControls
        return
    }

    if (Test-SupervisorRunning) {
        Set-Content -LiteralPath $script:StopFlag -Value (Get-Date -Format o) -Encoding ascii
        Show-Balloon 'Monero Sync' 'Stop requested. monerod is shutting down gracefully - you will be notified when it has exited.'
    } else {
        [void](Send-MonerodStop -RpcPort $RpcPort -TimeoutSeconds 60 -MonerodPath $monerodPath -DataDir $DataDir)
        Show-Balloon 'Monero Sync' 'Stop signal sent to monerod. It will exit once the database is flushed.'
    }

    $script:BtnStop.Enabled = $false   # one request is enough
}

function Invoke-Terminate {
    <#
        Force-kill. The one deliberate exception to "never kill monerod",
        gated behind a confirmation that spells out the cost.
    #>
    $procs = @(Get-Process -Name monerod -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) {
        Show-Balloon 'Monero Sync' 'Nothing to terminate - monerod is not running.' 'Info'
        Update-RunControls
        return
    }

    $msg = "This kills monerod instantly, WITHOUT flushing the database.`n`n" +
           "That is the exact thing that has corrupted the blockchain before. " +
           "Only do this if the daemon is genuinely stuck and a graceful stop has already failed.`n`n" +
           ("Terminate monerod (PID {0}) now?" -f $procs[0].Id)

    $r = [System.Windows.Forms.MessageBox]::Show(
        $msg, 'Terminate monerod?',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2)

    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    # Flag first, so the supervising run records TERMINATED rather than an
    # unexplained crash when it sees the process vanish.
    Set-Content -LiteralPath $script:TerminateFlag -Value (Get-Date -Format o) -Encoding ascii

    foreach ($p in $procs) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
    }

    Show-Balloon 'Monero Sync' 'monerod terminated. The database was NOT flushed - watch the next run for problems.' 'Warning'
    Update-RunControls
}

function Update-RunControls {
    # Stop and Terminate are only pressable while monerod is actually running.
    if (-not $script:BtnStop -or $script:BtnStop.IsDisposed) { return }

    $running = (Test-MonerodRunning -RpcPort $RpcPort).Running
    $script:BtnStop.Enabled      = $running
    $script:BtnTerminate.Enabled = $running

    # A disabled flat button keeps its BackColor, so grey it out explicitly.
    $script:BtnTerminate.BackColor = if ($running) {
        [System.Drawing.Color]::FromArgb(178, 34, 34)
    } else {
        [System.Drawing.SystemColors]::ControlDark
    }
}

function Invoke-ClearOutput {
    <#
        Blanks the Live output pane and the rolling sync.log behind it, so
        the next run starts on a clean terminal. Run history is not touched.
    #>
    if ($script:LogBox -and -not $script:LogBox.IsDisposed) { $script:LogBox.Clear() }
    $script:LogPos = 0

    # Clear-Content keeps the file in place for any run currently appending;
    # the rotated backup is simply deleted.
    try { Clear-Content -LiteralPath (Join-Path $logDir 'sync.log') -ErrorAction Stop } catch { }
    try { Remove-Item  -LiteralPath (Join-Path $logDir 'sync.log.1') -Force -ErrorAction Stop } catch { }
}

function Invoke-ClearHistory {
    <#
        Deletes the entire run history -- every row in the table and the
        files behind it. Confirmed first because it cannot be undone. The
        blockchain and the daemon's own log are not touched.
    #>
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Delete the entire run history?`n`nEvery row in the table and the history files are removed. This cannot be undone. The blockchain itself is not touched.",
        'Clear history?',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2)

    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    foreach ($f in @(
        (Join-Path $logDir   'history.jsonl'),
        (Join-Path $logDir   'sync-history.log'),
        (Join-Path $stateDir 'last-run.json')
    )) {
        try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop } catch { }
    }

    # Reset the cached "last run" text so the tray stops showing a run that
    # no longer exists on disk.
    $script:LastRunStamp = [datetime]::MinValue
    $script:LastRunText  = 'no runs yet'

    Update-HistoryGrid
    Update-HistoryHeader
}

function Show-HistoryWindow {
    <#
        Sync history. Shown non-modally and reused if already open, so the
        tray icon stays alive when the window is closed -- only Exit quits.
    #>

    # A disposed form cannot be reused; drop the stale reference so a fresh
    # one is built below rather than the icon silently doing nothing.
    if ($script:HistoryForm -and $script:HistoryForm.IsDisposed) {
        $script:HistoryForm = $null
        $script:LogBox      = $null
        $script:LogPos      = 0
    }

    if ($script:HistoryForm -and -not $script:HistoryForm.IsDisposed) {
        # Closing the window hides it rather than disposing it, so a reopened
        # window must be Show()n again -- Activate() alone does nothing to a
        # hidden form, which left the icon looking dead after the first close.
        if (-not $script:HistoryForm.Visible) { $script:HistoryForm.Show() }

        # Restore if it was minimised, then bring it to the front.
        if ($script:HistoryForm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
            $script:HistoryForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        }

        # TopMost toggle forces the window in front even when Windows would
        # otherwise refuse to steal focus from the active application.
        $script:HistoryForm.TopMost = $true
        $script:HistoryForm.BringToFront()
        $script:HistoryForm.Activate()
        $script:HistoryForm.TopMost = $false

        Update-HistoryGrid
        Update-HistoryHeader
        Update-LogView
        return
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = 'Monero Sync History'
    $form.StartPosition = 'CenterScreen'
    $form.Icon          = $iconColor

    # Because the process is per-monitor DPI-aware, WinForms lays out in real
    # physical pixels -- so a fixed 860x500 renders at 40% of its intended size
    # on a 250%-scaled display. Every size below goes through S(), which
    # multiplies by the live scale factor read at run time.
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)
    # Taller than before to make room for the live output pane below the grid.
    $form.ClientSize    = New-Object System.Drawing.Size((S 860), (S 700))
    $form.MinimumSize   = New-Object System.Drawing.Size((S 680), (S 480))
    $form.BackColor     = [System.Drawing.SystemColors]::Control

    # --- header strip: schedule state + controls ---
    #
    # Laid out with a TableLayoutPanel rather than absolute Location values.
    # Absolute positions combined with Anchor='Top,Right' pushed these controls
    # outside the panel's initial width, so they rendered off-screen and the
    # header looked empty apart from its labels.
    $panel = New-Object System.Windows.Forms.TableLayoutPanel
    $panel.Dock        = 'Top'
    # Fixed height, NOT AutoSize: an AutoSize panel plus a row-spanning button
    # anchored Top+Bottom feed each other and the panel grows without bound
    # (measured at 1756px). Height is in scaled units, so it tracks DPI.
    # Three rows: status text, frequency, sync cap + pause. Row 2's column 0
    # also carries the manual-command field, which is the tallest thing in
    # that row and sets the extra height.
    $panel.Height      = (S 186)
    $panel.ColumnCount = 4
    $panel.RowCount    = 4
    $panel.Padding     = New-Object System.Windows.Forms.Padding((S 16), (S 10), (S 16), (S 10))
    $panel.BackColor   = [System.Drawing.SystemColors]::Window

    # Column 0 (status text) takes the slack; the control columns size to fit.
    [void]$panel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$panel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$panel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$panel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$panel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$panel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$panel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$panel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

    $lblState = New-Object System.Windows.Forms.Label
    $lblState.AutoSize  = $true
    $lblState.Anchor    = 'Left,Bottom'
    $lblState.Margin    = New-Object System.Windows.Forms.Padding(0, 0, 0, 2)
    $lblState.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
    $panel.Controls.Add($lblState, 0, 0)

    $lblNext = New-Object System.Windows.Forms.Label
    $lblNext.AutoSize   = $true
    $lblNext.Anchor     = 'Left,Top'
    $lblNext.Margin     = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
    $lblNext.Font       = New-Object System.Drawing.Font('Segoe UI', 9)
    $lblNext.ForeColor  = [System.Drawing.SystemColors]::GrayText
    $panel.Controls.Add($lblNext, 0, 1)

    # AutoSize so the label is exactly as wide as its text: a fixed width
    # inside an auto-sized column leaves the caption stranded far to the left
    # of its dropdown. Anchor Right+vertical-centre keeps it beside the combo
    # and on the same centre line.
    $lblEvery = New-Object System.Windows.Forms.Label
    $lblEvery.Text      = '&Run every'
    $lblEvery.AutoSize  = $true
    $lblEvery.TextAlign = 'MiddleRight'
    $lblEvery.Anchor    = 'Right'
    $lblEvery.Margin    = New-Object System.Windows.Forms.Padding(0, 0, (S 10), 0)
    $panel.Controls.Add($lblEvery, 1, 0)

    # AutoSize on the interactive controls: a fixed pixel width is what clipped
    # "Pause automatic syncing" mid-word once the display scaled to 125%.
    $cboFreq = New-Object System.Windows.Forms.ComboBox
    $cboFreq.AutoSize      = $true
    $cboFreq.MinimumSize   = New-Object System.Drawing.Size((S 130), 0)
    $cboFreq.DropDownStyle = 'DropDownList'
    $cboFreq.Anchor        = 'Right'
    $cboFreq.Margin        = New-Object System.Windows.Forms.Padding(0, (S 4), 0, (S 4))
    foreach ($c in $script:IntervalChoices) { [void]$cboFreq.Items.Add($c.Label) }
    $panel.Controls.Add($cboFreq, 2, 0)

    # Row 1: the sync cap, mirroring the frequency control above it.
    $lblCap = New-Object System.Windows.Forms.Label
    $lblCap.Text      = 'Give up after'
    $lblCap.AutoSize  = $true
    $lblCap.TextAlign = 'MiddleRight'
    $lblCap.Anchor    = 'Right'
    $lblCap.Margin    = New-Object System.Windows.Forms.Padding(0, 0, (S 10), 0)
    $panel.Controls.Add($lblCap, 1, 1)

    $cboCap = New-Object System.Windows.Forms.ComboBox
    $cboCap.AutoSize      = $true
    $cboCap.MinimumSize   = New-Object System.Drawing.Size((S 130), 0)
    $cboCap.DropDownStyle = 'DropDownList'
    $cboCap.Anchor        = 'Right'
    $cboCap.Margin        = New-Object System.Windows.Forms.Padding(0, (S 4), 0, (S 4))
    foreach ($c in $script:SyncCapChoices) { [void]$cboCap.Items.Add($c.Label) }
    $panel.Controls.Add($cboCap, 2, 1)

    # The bare monerod command, for running a sync by hand in a terminal.
    # Styled as a sibling of the dropdowns beside it: a bordered white field at
    # control height, the same 9pt as "Next run", and a Copy button built the
    # same way as Pause. Read-only but selectable -- ReadOnly rather than
    # Enabled=$false, because a disabled TextBox greys its text out and cannot
    # be selected at all.
    $cmdRow = New-Object System.Windows.Forms.Panel
    $cmdRow.Anchor  = 'Left,Bottom'
    $cmdRow.Margin  = New-Object System.Windows.Forms.Padding(0, (S 10), (S 24), 0)

    $lblCmd = New-Object System.Windows.Forms.Label
    $lblCmd.Text      = 'Run manually in a terminal'
    $lblCmd.AutoSize  = $true
    $lblCmd.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
    $lblCmd.ForeColor = [System.Drawing.SystemColors]::GrayText
    $lblCmd.Location  = New-Object System.Drawing.Point(0, 0)

    # Fixed at the Pause button's height (S 28) rather than AutoSize: an
    # unparented AutoSize button reports a pre-DPI PreferredSize, which left
    # the field 9px shorter than the button and the button clipped by its row.
    $fieldH = (S 28)
    $btnCopyCmd = New-Object System.Windows.Forms.Button
    $btnCopyCmd.Text = 'Copy'
    $btnCopyCmd.Size = New-Object System.Drawing.Size((S 72), $fieldH)

    $txtCmd = New-Object System.Windows.Forms.TextBox
    $txtCmd.Text        = $script:ManualSyncCommand
    $txtCmd.ReadOnly    = $true
    $txtCmd.Font        = New-Object System.Drawing.Font('Consolas', 9)
    $txtCmd.BackColor   = [System.Drawing.SystemColors]::Window
    $txtCmd.ForeColor   = [System.Drawing.SystemColors]::WindowText
    $txtCmd.BorderStyle = 'None'
    # Keep the caret off it on open, and stop typing/paste even via shortcuts.
    $txtCmd.TabStop          = $false
    $txtCmd.ShortcutsEnabled = $true   # Ctrl+C must still work
    $txtCmd.Add_KeyPress({ $_.Handled = $true })

    # A single-line TextBox cannot be made taller than its font, so it sits
    # inside a bordered white panel that IS control height, which is what
    # makes it line up with the Copy button and read like the dropdowns.
    $txtW   = [System.Windows.Forms.TextRenderer]::MeasureText(
                  $script:ManualSyncCommand, $txtCmd.Font).Width + (S 4)

    $cmdBox = New-Object System.Windows.Forms.Panel
    $cmdBox.BorderStyle = 'FixedSingle'
    $cmdBox.BackColor   = [System.Drawing.SystemColors]::Window
    $cmdBox.Size        = New-Object System.Drawing.Size(($txtW + (S 16)), $fieldH)

    $txtCmd.Width    = $txtW
    $txtCmd.Location = New-Object System.Drawing.Point((S 7), [int](($cmdBox.ClientSize.Height - $txtCmd.Height) / 2))
    $cmdBox.Controls.Add($txtCmd)

    $fieldTop = $lblCmd.PreferredHeight + (S 4)
    $cmdBox.Location     = New-Object System.Drawing.Point(0, $fieldTop)
    $btnCopyCmd.Location = New-Object System.Drawing.Point(($cmdBox.Width + (S 8)), $fieldTop)

    $cmdRow.Controls.Add($lblCmd)
    $cmdRow.Controls.Add($cmdBox)
    $cmdRow.Controls.Add($btnCopyCmd)
    $cmdRow.Size = New-Object System.Drawing.Size(
        ($btnCopyCmd.Location.X + $btnCopyCmd.Width),
        ($fieldTop + $fieldH))
    # Column 0 of the last control row -- the empty space under the status
    # text -- extended under the label/dropdown columns but stopping short of
    # column 3, so it never runs past the Sync now block into a full-width bar.
    # Column 0 alone is 993px, and the 85-character command needs 1008px even
    # at an already-too-small 6.5pt; the span buys the width instead of
    # shrinking the text to illegibility.
    $panel.Controls.Add($cmdRow, 0, 3)
    $panel.SetColumnSpan($cmdRow, 3)

    $btnCopyCmd.Add_Click({
        try {
            [System.Windows.Forms.Clipboard]::SetText($script:ManualSyncCommand)
            $script:CopyBtn.Text = 'Copied'
            $script:CopyRevertAt = (Get-Date).AddSeconds(2)
        } catch {
            # Clipboard can be locked by another process; say so rather than
            # silently appearing to have copied.
            $script:CopyBtn.Text = 'Failed'
            $script:CopyRevertAt = (Get-Date).AddSeconds(2)
        }
    })

    # The Pause button spans BOTH the label and dropdown columns. It is wider
    # than the dropdowns, so parking it in the dropdown column alone forced
    # that column to the button's width and the right-anchored dropdowns then
    # started ~80px away from their labels -- the "massive gap". Spanning lets
    # the dropdown column stay exactly as wide as the dropdowns.
    $btnPause = New-Object System.Windows.Forms.Button
    $btnPause.AutoSize     = $true
    $btnPause.AutoSizeMode = 'GrowAndShrink'
    $btnPause.Anchor       = 'Right'
    $btnPause.Padding      = New-Object System.Windows.Forms.Padding((S 10), (S 4), (S 10), (S 4))
    $btnPause.Margin       = New-Object System.Windows.Forms.Padding(0, (S 3), 0, 0)
    $panel.Controls.Add($btnPause, 1, 2)
    $panel.SetColumnSpan($btnPause, 2)

    $btnSyncNow = New-Object System.Windows.Forms.Button
    $btnSyncNow.Text        = '&Sync now'
    $btnSyncNow.AutoSize    = $true
    $btnSyncNow.AutoSizeMode = 'GrowAndShrink'
    $btnSyncNow.MinimumSize = New-Object System.Drawing.Size((S 120), 0)
    $btnSyncNow.Anchor      = 'Top,Bottom,Right'
    $btnSyncNow.Margin      = New-Object System.Windows.Forms.Padding((S 14), 0, 0, 0)
    $btnSyncNow.Padding     = New-Object System.Windows.Forms.Padding((S 10), (S 6), (S 10), (S 6))
    $btnSyncNow.Font        = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $panel.Controls.Add($btnSyncNow, 3, 0)
    # Span every row so it stands as the primary action, full header height.
    $panel.SetRowSpan($btnSyncNow, 4)

    # Hairline under the header, separating it from the grid.
    $rule = New-Object System.Windows.Forms.Panel
    $rule.Dock      = 'Top'
    $rule.Height    = [math]::Max(1, (S 1))
    $rule.BackColor = [System.Drawing.SystemColors]::ControlDark

    $form.Controls.Add($rule)
    $form.Controls.Add($panel)

    # --- grid ---
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock                        = 'Fill'
    $grid.ReadOnly                    = $true
    $grid.AllowUserToAddRows          = $false
    $grid.AllowUserToDeleteRows       = $false
    $grid.AllowUserToResizeRows       = $false
    $grid.RowHeadersVisible           = $false
    $grid.SelectionMode               = 'FullRowSelect'
    $grid.MultiSelect                 = $false
    $grid.AutoSizeColumnsMode         = 'Fill'
    $grid.BackgroundColor             = [System.Drawing.SystemColors]::Window
    $grid.BorderStyle                 = 'None'
    $grid.EnableHeadersVisualStyles   = $false
    $grid.CellBorderStyle             = 'SingleHorizontal'
    $grid.GridColor                   = [System.Drawing.SystemColors]::ControlLight

    # Header: slightly taller with real padding so it does not crowd the rows.
    $grid.ColumnHeadersDefaultCellStyle.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.SystemColors]::Control
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.SystemColors]::ControlText
    $grid.ColumnHeadersDefaultCellStyle.Padding   = New-Object System.Windows.Forms.Padding((S 8), (S 6), (S 8), (S 6))
    $grid.ColumnHeadersHeightSizeMode = 'AutoSize'

    # Rows: generous padding and height so the table stays legible when the
    # display is scaled. AllowUserToResizeRows is off, so this is stable.
    $grid.DefaultCellStyle.Font    = New-Object System.Drawing.Font('Segoe UI', 9)
    $grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding((S 8), (S 5), (S 8), (S 5))
    $grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.SystemColors]::Highlight
    $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.SystemColors]::HighlightText
    $grid.RowTemplate.Height       = (S 30)

    # Zebra striping: the eye tracks a row across six columns far more easily.
    $grid.AlternatingRowsDefaultCellStyle.BackColor =
        [System.Drawing.Color]::FromArgb(247, 247, 247)

    foreach ($c in @(
        @{N='When';    H='Started';  W=132; A='MiddleLeft'}
        @{N='Result';  H='Result';   W=140; A='MiddleLeft'}
        @{N='Blocks';  H='Blocks';   W=74;  A='MiddleRight'}
        @{N='Height';  H='Height';   W=100; A='MiddleRight'}
        @{N='Took';    H='Runtime';  W=84;  A='MiddleRight'}
        @{N='Clean';   H='Shutdown'; W=92;  A='MiddleCenter'}
    )) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name       = $c.N
        $col.HeaderText = $c.H
        $col.FillWeight = $c.W
        # Numbers right-aligned so heights and block counts line up in columns.
        $col.DefaultCellStyle.Alignment = $c.A
        $col.HeaderCell.Style.Alignment = $c.A
        $grid.Columns.Add($col) | Out-Null
    }

    # --- live log ---
    # Tails logs\sync.log from disk rather than capturing job output, so a run
    # started by Task Scheduler is just as visible as one started from the
    # Sync now button.
    $logPanel = New-Object System.Windows.Forms.Panel
    $logPanel.Dock    = 'Fill'
    $logPanel.Padding = New-Object System.Windows.Forms.Padding(0)

    # A SplitContainer is used rather than a bare Splitter: the legacy Splitter
    # binds to whichever docked sibling precedes it, which in this layout put
    # the handle at the very bottom of the form where dragging did nothing.
    # SplitContainer owns both panes explicitly, so the divider always works.
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock             = 'Fill'
    $split.Orientation      = [System.Windows.Forms.Orientation]::Horizontal
    # A wide grab strip: at 250% scaling a 6px divider is only ~2 logical
    # pixels of hit area, which is very hard to catch with the mouse.
    $split.SplitterWidth    = (S 12)
    $split.BackColor        = [System.Drawing.SystemColors]::ControlDark
    # Only the grid grows when the window is resized; the log pane keeps the
    # height the user chose.
    $split.FixedPanel       = [System.Windows.Forms.FixedPanel]::Panel2

    # Panel1MinSize / Panel2MinSize are deliberately NOT set here. Before the
    # form is laid out the control has no real height, so its default
    # SplitterDistance is smaller than these minimums would allow and the
    # setter throws "SplitterDistance must be between Panel1MinSize and
    # Width - Panel2MinSize" -- which crashed the window on open. They are
    # applied after Show(), once the real height is known.

    $logHead = New-Object System.Windows.Forms.Panel
    $logHead.Dock      = 'Top'
    $logHead.Height    = (S 30)
    $logHead.BackColor = [System.Drawing.SystemColors]::Control

    $lblLog = New-Object System.Windows.Forms.Label
    $lblLog.Text      = 'Live output'
    $lblLog.Dock      = 'Left'
    $lblLog.AutoSize  = $false
    $lblLog.Width     = (S 210)
    $lblLog.TextAlign = 'MiddleLeft'
    $lblLog.Padding   = New-Object System.Windows.Forms.Padding((S 16), 0, 0, 0)
    $lblLog.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $logHead.Controls.Add($lblLog)

    $btnOpenLog = New-Object System.Windows.Forms.Button
    $btnOpenLog.Text     = 'Open log file'
    $btnOpenLog.Dock     = 'Right'
    $btnOpenLog.Width    = (S 110)
    $btnOpenLog.FlatStyle = 'System'
    $btnOpenLog.Margin   = New-Object System.Windows.Forms.Padding(0)
    $logHead.Controls.Add($btnOpenLog)

    # Run controls. Docked Right, so the first added sits furthest right:
    #   [Stop sync] [skull Terminate] [Open log file]
    $btnTerminate = New-Object System.Windows.Forms.Button
    $btnTerminate.Text      = ("{0}  Terminate" -f [char]0x2620)
    $btnTerminate.Dock      = 'Right'
    $btnTerminate.Width     = (S 130)
    $btnTerminate.FlatStyle = 'Flat'
    $btnTerminate.FlatAppearance.BorderSize = 0
    $btnTerminate.BackColor = [System.Drawing.SystemColors]::ControlDark
    $btnTerminate.ForeColor = [System.Drawing.Color]::White
    $btnTerminate.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $btnTerminate.Enabled   = $false
    $logHead.Controls.Add($btnTerminate)

    $btnStop = New-Object System.Windows.Forms.Button
    $btnStop.Text      = 'Stop sync'
    $btnStop.Dock      = 'Right'
    $btnStop.Width     = (S 100)
    $btnStop.FlatStyle = 'System'
    $btnStop.Enabled   = $false
    $logHead.Controls.Add($btnStop)

    # Housekeeping. Added after the run controls, so these dock further left:
    #   [Clear history] [Clear output] [Stop sync] [Terminate] [Open log file]
    $btnClearOut = New-Object System.Windows.Forms.Button
    $btnClearOut.Text      = 'Clear output'
    $btnClearOut.Dock      = 'Right'
    $btnClearOut.Width     = (S 110)
    $btnClearOut.FlatStyle = 'System'
    $logHead.Controls.Add($btnClearOut)

    $btnClearHist = New-Object System.Windows.Forms.Button
    $btnClearHist.Text      = 'Clear history'
    $btnClearHist.Dock      = 'Right'
    $btnClearHist.Width     = (S 115)
    $btnClearHist.FlatStyle = 'System'
    $logHead.Controls.Add($btnClearHist)

    $script:BtnStop      = $btnStop
    $script:BtnTerminate = $btnTerminate

    $btnStop.Add_Click({      Invoke-StopSync })
    $btnTerminate.Add_Click({ Invoke-Terminate })
    $btnClearOut.Add_Click({  Invoke-ClearOutput })
    $btnClearHist.Add_Click({ Invoke-ClearHistory })

    $logBox = New-Object System.Windows.Forms.RichTextBox
    $logBox.Dock         = 'Fill'
    $logBox.ReadOnly     = $true
    $logBox.BorderStyle  = 'None'
    $logBox.BackColor    = [System.Drawing.Color]::FromArgb(24, 24, 24)
    $logBox.ForeColor    = [System.Drawing.Color]::FromArgb(220, 220, 220)
    $logBox.Font         = New-Object System.Drawing.Font('Consolas', 9)
    $logBox.WordWrap     = $false
    $logBox.ScrollBars   = 'Both'
    $logBox.DetectUrls   = $false

    $logPanel.Controls.Add($logBox)
    $logPanel.Controls.Add($logHead)

    $script:LogBox     = $logBox
    $script:LogLabel   = $lblLog
    $script:LogPos     = 0
    $script:LogPanel   = $logPanel

    $btnOpenLog.Add_Click({
        $p = Join-Path $logDir 'sync.log'
        if (Test-Path -LiteralPath $p) { Start-Process notepad.exe $p }
    })

    # --- status bar ---
    $status = New-Object System.Windows.Forms.Label
    $status.Dock       = 'Bottom'
    $status.AutoSize   = $false
    $status.Height     = (S 34)
    $status.TextAlign  = 'MiddleLeft'
    $status.Padding    = New-Object System.Windows.Forms.Padding((S 16), 0, (S 16), 0)
    $status.ForeColor  = [System.Drawing.SystemColors]::GrayText
    $status.BackColor  = [System.Drawing.SystemColors]::Control
    $status.BorderStyle = 'None'

    # Dock order matters: bottom-docked controls must be added BEFORE the
    # Fill-docked grid, or the grid claims the whole client area first and the
    # log panel is squeezed out.
    # Grip dots down the middle of the divider, the standard visual cue that a
    # bar is draggable. The resize CURSOR is drawn by Windows at the size set
    # in Settings > Accessibility > Mouse pointer, and an application cannot
    # enlarge it -- so the affordance is made obvious in the bar itself.
    $split.Add_Paint({
        param($s, $e)
        $mid  = [int]($s.SplitterDistance + ($s.SplitterWidth / 2))
        $cx   = [int]($s.Width / 2)
        $r    = [math]::Max(1, [int]($script:UiScale * 1.5))
        $gap  = [int]($script:UiScale * 8)
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(120, 255, 255, 255))
        try {
            foreach ($i in -3..3) {
                $e.Graphics.FillEllipse($brush, ($cx + ($i * $gap) - $r), ($mid - $r), ($r * 2), ($r * 2))
            }
        } finally { $brush.Dispose() }
    })

    # Repaint the grip as the divider moves.
    $split.Add_SplitterMoved({ $this.Invalidate() })

    # Grid on top, log pane below, divider between them.
    $split.Panel1.Controls.Add($grid)
    $split.Panel2.Controls.Add($logPanel)

    $form.Controls.Add($status)
    $form.Controls.Add($split)
    $split.BringToFront()

    $script:HistoryForm    = $form
    $script:HistoryGrid    = $grid
    $script:HistoryStatus  = $status
    $script:HistoryState   = $lblState
    $script:HistoryNext    = $lblNext
    $script:CopyBtn        = $btnCopyCmd
    $script:HistoryPause   = $btnPause
    $script:HistoryFreq    = $cboFreq
    $script:HistoryCap     = $cboCap
    $script:HistorySyncNow = $btnSyncNow

    $cboCap.Add_SelectedIndexChanged({
        if ($script:SuppressCapEvent) { return }

        $mins = $script:SyncCapChoices[$script:HistoryCap.SelectedIndex].Minutes
        if ($mins -eq (Get-SyncCapMinutes)) { return }

        if (Set-SyncCapMinutes -Minutes $mins) {
            Show-Balloon 'Monero Sync' ("A sync now gives up after {0}." -f (Format-Interval $mins))
        } else {
            Show-Balloon 'Monero Sync' 'Could not save the sync cap.' 'Error'
        }
    })

    $btnPause.Add_Click({
        Invoke-Toggle
        Update-HistoryHeader
    })

    $btnSyncNow.Add_Click({
        Invoke-SyncNow
        Update-HistoryHeader
    })

    $cboFreq.Add_SelectedIndexChanged({
        if ($script:SuppressFreqEvent) { return }

        $mins = $script:IntervalChoices[$script:HistoryFreq.SelectedIndex].Minutes
        if ($mins -eq (Get-TaskIntervalMinutes)) { return }

        if (Set-TaskIntervalMinutes -Minutes $mins) {
            Show-Balloon 'Monero Sync' ("Now syncing every {0}." -f (Format-Interval $mins))
            Update-HistoryHeader
        } else {
            Show-Balloon 'Monero Sync' 'Could not change the frequency.' 'Error'
        }
    })

    # Closing the window must NOT quit the tray -- hide it instead so the icon
    # and the schedule keep running.
    $form.Add_FormClosing({
        param($s, $e)
        if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $e.Cancel = $true
            $s.Hide()
        }
    })

    Update-HistoryHeader
    Update-HistoryGrid
    Update-LogView
    $form.Show()
    $form.Activate()

    # Position the divider and apply the pane minimums now that the form is
    # laid out and the SplitContainer has a real height. Order matters:
    # SplitterDistance first, then the minimums, or the setters conflict.
    try {
        $target = $split.Height - (S 190) - $split.SplitterWidth
        $floor  = (S 120)
        if ($target -lt $floor) { $target = [int]($split.Height / 2) }
        if ($target -gt $floor) { $split.SplitterDistance = $target }

        # Only clamp if the current layout can actually accommodate it.
        if ($split.SplitterDistance -ge (S 120)) { $split.Panel1MinSize = (S 120) }
        if (($split.Height - $split.SplitterDistance - $split.SplitterWidth) -ge (S 70)) {
            $split.Panel2MinSize = (S 70)
        }
    } catch {
        # A layout too small for the preferred sizes is not worth failing over;
        # the divider still works, just without minimums.
    }
}

function Update-LogView {
    <#
        Appends whatever is new in logs\sync.log to the live output pane.

        Reads by byte offset rather than re-reading the file, and only touches
        the control when there is something to add -- the timer calls this
        every few seconds while the window is open.
    #>
    if (-not $script:HistoryForm -or $script:HistoryForm.IsDisposed) { return }
    if (-not $script:LogBox -or $script:LogBox.IsDisposed) { return }

    $path = Join-Path $logDir 'sync.log'
    if (-not (Test-Path -LiteralPath $path)) {
        if ($script:LogBox.TextLength -eq 0) {
            $script:LogBox.Text = '  (no sync has run yet)'
        }
        return
    }

    $new = ''
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            # The log rotates, so a shrunken file means a fresh one: start over
            # rather than seeking past the end.
            if ($fs.Length -lt $script:LogPos) {
                $script:LogPos = 0
                $script:LogBox.Clear()
            }

            # On first open, show only the tail so the pane starts on the
            # current run instead of replaying the whole file.
            if ($script:LogPos -eq 0 -and $fs.Length -gt 20000) {
                $script:LogPos = $fs.Length - 20000
            }

            # Capture the length BEFORE reading: disposing the StreamReader
            # closes the underlying stream, so $fs.Length afterwards is
            # unreliable and the next tick would re-read the whole file.
            $endPos = $fs.Length

            [void]$fs.Seek($script:LogPos, 'Begin')
            $sr = New-Object System.IO.StreamReader($fs)
            try { $new = $sr.ReadToEnd() } finally { $sr.Dispose() }
            $script:LogPos = $endPos
        } finally { try { $fs.Dispose() } catch { } }
    } catch {
        return
    }

    if (-not $new -or $new -notmatch '\S') { return }

    $atBottom = $true
    try {
        # Only auto-scroll if the user has not scrolled up to read something.
        $atBottom = ($script:LogBox.SelectionStart -ge ($script:LogBox.TextLength - 2))
    } catch { }

    foreach ($line in ($new -split "`r?`n")) {
        if ($line -notmatch '\S') { continue }

        # Colour by the level column the sync script writes.
        $colour = switch -Regex ($line) {
            '\sERROR\s' { [System.Drawing.Color]::FromArgb(255, 120, 110); break }
            '\sWARN\s'  { [System.Drawing.Color]::FromArgb(240, 190,  90); break }
            '\sOK\s'    { [System.Drawing.Color]::FromArgb(120, 215, 130); break }
            '\sSTEP\s'  { [System.Drawing.Color]::FromArgb(120, 190, 255); break }
            default     { [System.Drawing.Color]::FromArgb(200, 200, 200) }
        }

        $script:LogBox.SelectionStart  = $script:LogBox.TextLength
        $script:LogBox.SelectionLength = 0
        $script:LogBox.SelectionColor  = $colour
        $script:LogBox.AppendText($line + "`r`n")
    }

    # Keep the buffer bounded so a long run cannot grow it without limit.
    if ($script:LogBox.Lines.Count -gt 600) {
        $keep = $script:LogBox.Lines[-400..-1]
        $script:LogBox.Clear()
        foreach ($l in $keep) { $script:LogBox.AppendText($l + "`r`n") }
        $atBottom = $true
    }

    if ($atBottom) {
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    }
}

function Update-HistoryHeader {
    if (-not $script:HistoryForm -or $script:HistoryForm.IsDisposed) { return }

    $state = Get-TaskState
    $mins = Get-TaskIntervalMinutes

    switch ($state) {
        'armed' {
            $script:HistoryState.Text      = 'Automatic syncing is ON'
            $script:HistoryState.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 40)
            $script:HistoryPause.Text      = 'Pause automatic syncing'
        }
        'paused' {
            $script:HistoryState.Text      = 'Automatic syncing is PAUSED'
            $script:HistoryState.ForeColor = [System.Drawing.Color]::FromArgb(170, 90, 0)
            $script:HistoryPause.Text      = 'Resume automatic syncing'
        }
        default {
            $script:HistoryState.Text      = 'Scheduled task not installed'
            $script:HistoryState.ForeColor = [System.Drawing.Color]::Firebrick
            $script:HistoryPause.Text      = 'Not available'
        }
    }

    $script:HistoryPause.Enabled = ($state -ne 'missing')
    $script:HistoryFreq.Enabled  = ($state -ne 'missing')

    # The sync cap is a plain setting, so it stays editable even when the
    # scheduled task is missing.
    $cap = Get-SyncCapMinutes
    $capIdx = -1
    for ($i = 0; $i -lt $script:SyncCapChoices.Count; $i++) {
        if ($script:SyncCapChoices[$i].Minutes -eq $cap) { $capIdx = $i; break }
    }
    if ($capIdx -ge 0 -and $script:HistoryCap.SelectedIndex -ne $capIdx) {
        $script:SuppressCapEvent = $true
        $script:HistoryCap.SelectedIndex = $capIdx
        $script:SuppressCapEvent = $false
    }

    # Disabled while a sync is running, matching the menu item.
    $busy = Test-Syncing
    $script:HistorySyncNow.Enabled = -not $busy
    $script:HistorySyncNow.Text    = if ($busy) { 'Syncing...' } else { 'Sync now' }

    Update-RunControls

    if ($script:LogLabel -and -not $script:LogLabel.IsDisposed) {
        if ($busy) {
            $script:LogLabel.Text      = 'Live output  -  SYNCING'
            $script:LogLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 45)
        } else {
            $script:LogLabel.Text      = 'Live output  -  idle'
            $script:LogLabel.ForeColor = [System.Drawing.SystemColors]::GrayText
        }
    }

    $nextText = 'Next run: unknown'
    try {
        $t = Get-TaskObject
        if ($t -and $state -eq 'armed' -and $t.NextRunTime) {
            $nextText = 'Next run: ' + ([datetime]$t.NextRunTime).ToString('ddd d MMM, HH:mm')
        } elseif ($state -eq 'paused') {
            $nextText = 'No runs scheduled while paused'
        }
    } catch { }
    $script:HistoryNext.Text = $nextText

    if ($mins -gt 0) {
        $idx = -1
        for ($i = 0; $i -lt $script:IntervalChoices.Count; $i++) {
            if ($script:IntervalChoices[$i].Minutes -eq $mins) { $idx = $i; break }
        }
        if ($idx -ge 0) {
            $script:SuppressFreqEvent = $true
            $script:HistoryFreq.SelectedIndex = $idx
            $script:SuppressFreqEvent = $false
        }
    }
}

function Update-HistoryGrid {
    if (-not $script:HistoryForm -or $script:HistoryForm.IsDisposed) { return }

    $entries = @(Get-HistoryEntries -Root $PSScriptRoot -Last 200)
    $grid    = $script:HistoryGrid

    $grid.SuspendLayout()
    $grid.Rows.Clear()

    foreach ($e in $entries) {
        $when = try { [datetime]::Parse($e.StartedAt).ToString('ddd d MMM  HH:mm') } catch { '?' }

        # Plain-language result rather than the internal status code.
        $result = switch -Regex ($e.Status) {
            '^OK$'            { 'Synced' }
            '^PARTIAL$'       { 'Partial sync' }
            '^INTERRUPTED$'   { 'Interrupted' }
            '^SKIP-NOTMOUNTED$' { 'Skipped - drive locked' }
            '^SKIP-VBOX$'     { 'Skipped - VM running' }
            '^SKIP-RUNNING$'  { 'Skipped - already running' }
            '^SKIP-OVERLAP$'  { 'Skipped - run in progress' }
            '^STOPPED-VBOX$'  { 'Stopped - VM started' }
            '^STOPPED-USER$'  { 'Stopped by you' }
            '^TERMINATED$'    { 'TERMINATED - not flushed' }
            '^ERROR-STUCK'    { 'Daemon would not stop' }
            '^ERROR'          { 'Error' }
            default           { $e.Status }
        }

        $blocks = if ($e.Blocks -gt 0) { '+{0}' -f $e.Blocks } elseif ($e.Status -eq 'OK') { '0' } else { '' }
        $height = if ($e.EndHeight -gt 0) { '{0:N0}' -f $e.EndHeight } else { '' }
        $took   = if ($e.Minutes -gt 0) { '{0:N1} min' -f $e.Minutes } else { '' }

        $clean = if ($e.MarkersTotal -gt 0) {
            if ($e.MarkersSeen -ge $e.MarkersTotal) { 'clean' }
            elseif ($e.MarkersSeen -gt 0)           { "{0}/{1}" -f $e.MarkersSeen, $e.MarkersTotal }
            else                                    { 'NOT CLEAN' }
        } else { '' }

        $i = $grid.Rows.Add($when, $result, $blocks, $height, $took, $clean)
        $row = $grid.Rows[$i]

        if ($e.Status -eq 'OK') {
            $row.Cells['Result'].Style.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 45)
        } elseif ($e.Status -like 'SKIP*' -or $e.Status -like 'STOPPED-*') {
            $row.Cells['Result'].Style.ForeColor = [System.Drawing.Color]::FromArgb(150, 105, 0)
        } else {
            $row.Cells['Result'].Style.ForeColor = [System.Drawing.Color]::FromArgb(178, 34, 34)
            $row.Cells['Result'].Style.Font =
                New-Object System.Drawing.Font('Segoe UI Semibold', 9)
            # Set both backgrounds so the tint survives zebra striping, which
            # would otherwise overwrite it on every second row.
            $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(253, 240, 238)
            $row.Cells['Result'].Style.BackColor = [System.Drawing.Color]::FromArgb(253, 240, 238)
            foreach ($cell in $row.Cells) {
                $cell.Style.BackColor = [System.Drawing.Color]::FromArgb(253, 240, 238)
            }
        }

        if ($clean -eq 'NOT CLEAN') {
            $row.Cells['Clean'].Style.ForeColor = [System.Drawing.Color]::FromArgb(178, 34, 34)
            $row.Cells['Clean'].Style.Font =
                New-Object System.Drawing.Font('Segoe UI Semibold', 9)
        } elseif ($clean -eq 'clean') {
            $row.Cells['Clean'].Style.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 45)
        }
    }

    $grid.ResumeLayout()

    $ok     = @($entries | Where-Object { $_.Status -eq 'OK' }).Count
    $blocks = ($entries | Where-Object { $_.Blocks -gt 0 } | Measure-Object -Property Blocks -Sum).Sum
    if (-not $blocks) { $blocks = 0 }

    $script:HistoryStatus.Text =
        '{0} runs shown   |   {1} synced   |   {2:N0} blocks total' -f $entries.Count, $ok, $blocks
}

function Invoke-ShowChecks {
    $mount   = Test-BlockchainMounted -DataDir $DataDir
    $vbox    = Test-VirtualBoxRunning
    $monerod = Test-MonerodRunning -RpcPort $RpcPort

    $canRun = $mount.Mounted -and -not $monerod.Running -and -not $vbox.Running

    $lines = @(
        "Blockchain : $(if ($mount.Mounted) { 'MOUNTED' } else { 'NOT MOUNTED' })"
        "             $($mount.Detail)"
        ''
        "VirtualBox : $(if ($vbox.Running) { 'VM RUNNING' } else { 'no VM' })"
        "             $($vbox.Detail)"
        ''
        "monerod    : $(if ($monerod.Running) { 'RUNNING' } else { 'not running' })"
        "             $($monerod.Detail)"
        ''
        "Verdict    : $(if ($canRun) { 'CLEAR TO SYNC' } else { 'WOULD SKIP' })"
        ''
        "Schedule   : $(Get-TaskState)"
        "Last run   : $(Get-LastRunText)"
    ) -join "`n"

    [System.Windows.Forms.MessageBox]::Show(
        $lines, 'Monero Sync - preflight checks',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $(if ($canRun) { 'Information' } else { 'Warning' })
    ) | Out-Null
}

# --- Wiring ---------------------------------------------------------------

# Left click opens the history window; right click opens the menu (handled by
# the ContextMenuStrip). Clicking the icon never changes the schedule -- pause
# and resume live on the menu and in the history window.
$tray.add_MouseClick({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-HistoryWindow }
})

$miToggle.add_Click({  Invoke-Toggle; Update-HistoryHeader })
$miHistory.add_Click({ Show-HistoryWindow })
$miSyncNow.add_Click({ Invoke-SyncNow })
$miChecks.add_Click({  Invoke-ShowChecks })
$miLogs.add_Click({
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    Start-Process explorer.exe $logDir
})

$menu.add_Opening({ Update-Tray })

# Refresh state periodically so the icon reflects runs started elsewhere
# (by Task Scheduler, or by hand from a terminal).
$timer = New-Object System.Windows.Forms.Timer
# 15s rather than 5s: this only catches state changed elsewhere (a scheduled
# run starting, or a sync launched from a terminal). Clicks update the icon
# immediately on their own, so a slower background poll costs nothing.
$timer.Interval = 15000
$timer.add_Tick({
    if ($script:RunningJob -and $script:RunningJob.State -ne 'Running') {
        $done = $script:RunningJob
        $script:RunningJob = $null
        Receive-Job $done -ErrorAction SilentlyContinue | Out-Null
        Remove-Job  $done -Force -ErrorAction SilentlyContinue
        Show-Balloon 'Monero Sync' "Sync finished - $(Get-LastRunText)"
    }
    Update-Tray

    # Keep an open history window current as scheduled runs complete.
    if ($script:HistoryForm -and -not $script:HistoryForm.IsDisposed -and $script:HistoryForm.Visible) {
        Update-HistoryGrid
        Update-HistoryHeader
        Update-LogView
    }
})

# Separate, faster timer purely for the live log, so output appears promptly
# without making the expensive grid/task-state refresh run every 2s.
$logTimer = New-Object System.Windows.Forms.Timer
$logTimer.Interval = 2000
$logTimer.add_Tick({
    if ($script:HistoryForm -and -not $script:HistoryForm.IsDisposed -and $script:HistoryForm.Visible) {
        Update-LogView
        Update-RunControls

        # Revert the Copy button's transient "Copied"/"Failed" label.
        if ($script:CopyRevertAt -and (Get-Date) -ge $script:CopyRevertAt) {
            $script:CopyRevertAt = $null
            if ($script:CopyBtn -and -not $script:CopyBtn.IsDisposed) {
                $script:CopyBtn.Text = 'Copy'
            }
        }
    }
})
$logTimer.Start()
$timer.Start()

$miExit.add_Click({
    $timer.Stop()
    $logTimer.Stop()
    # Dispose the history form directly: its FormClosing handler cancels
    # user-initiated closes, so Close() alone would not let the app exit.
    if ($script:HistoryForm -and -not $script:HistoryForm.IsDisposed) {
        $script:HistoryForm.Dispose()
    }
    $tray.Visible = $false
    $tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

# Released in finally{} below so a second copy can start after this one ends.

Update-Tray

if ((Get-TaskState) -eq 'missing') {
    Show-Balloon 'Monero Sync' 'Scheduled task not installed. Run Install-Task.ps1 to enable automatic syncing.' 'Warning'
}

Write-Host 'Monero tray running. Right-click the tray icon for options.' -ForegroundColor Cyan
Write-Host 'Left-click toggles automatic syncing on/off.' -ForegroundColor DarkGray

try {
    [System.Windows.Forms.Application]::Run()
}
finally {
    if ($tray) { $tray.Visible = $false; $tray.Dispose() }
    $trayMutex.ReleaseMutex()
    $trayMutex.Dispose()
}




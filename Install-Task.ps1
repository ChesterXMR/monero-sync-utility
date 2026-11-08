<#
    Install-Task.ps1

    Registers Sync-Monero.ps1 with Task Scheduler to run every 3 hours.

    Runs as the CURRENT USER with "run only when user is logged on", because
    VeraCrypt mounts E: per-session by default. A task running as SYSTEM or
    while logged off would not see the volume, and every run would fail the
    mount check.

    (If you later configure E: as a VeraCrypt system favorite volume, this can
    be changed to run whether logged on or not.)

    Run this once. Use -Remove to unregister.
#>

[CmdletBinding()]
param(
    [string] $TaskName = 'Monero Sync Utility',
    [int]    $IntervalHours = 1,

    # Runs land on the hour mark.
    [int]    $StartMinute = 0,

    [switch] $Remove
)

$ErrorActionPreference = 'Stop'

$scriptPath   = Join-Path $PSScriptRoot 'Sync-Monero.ps1'
$trayLauncher = Join-Path $PSScriptRoot 'Start-Tray.vbs'

# The tray starts via a Startup-folder shortcut rather than a second scheduled
# task: Startup runs in the interactive desktop session, which is where a tray
# icon has to live to be visible.
$startupDir   = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDir 'Monero Sync Tray.lnk'

function Install-TrayShortcut {
    if (-not (Test-Path -LiteralPath $trayLauncher)) {
        Write-Host 'Start-Tray.vbs not found - skipping startup shortcut.' -ForegroundColor Yellow
        return $false
    }

    $wsh = New-Object -ComObject WScript.Shell
    $sc  = $wsh.CreateShortcut($shortcutPath)
    # wscript.exe (not cscript) so the launcher itself shows no console.
    $sc.TargetPath       = Join-Path $env:WINDIR 'System32\wscript.exe'
    $sc.Arguments        = '"{0}"' -f $trayLauncher
    $sc.WorkingDirectory = $PSScriptRoot
    $sc.IconLocation     = 'C:\Program Files\Monero GUI Wallet\monero-wallet-gui.exe,0'
    $sc.Description      = 'Monero sync utility tray icon'
    $sc.Save()
    return $true
}

function Remove-TrayShortcut {
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
        return $true
    }
    return $false
}

if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
    } else {
        Write-Host "No scheduled task named '$TaskName'." -ForegroundColor Yellow
    }

    if (Remove-TrayShortcut) {
        Write-Host 'Removed tray startup shortcut.' -ForegroundColor Green
    } else {
        Write-Host 'No tray startup shortcut found.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host 'Note: a tray icon already running is not closed by this.' -ForegroundColor DarkGray
    Write-Host 'Right-click it and choose Exit.' -ForegroundColor DarkGray
    exit 0
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Write-Host "Sync-Monero.ps1 not found next to this script." -ForegroundColor Red
    exit 1
}

# Launched through wscript.exe rather than powershell.exe directly: Task
# Scheduler shows a console window for powershell.exe even with
# -WindowStyle Hidden, because the window exists before PowerShell can act on
# that argument. wscript.exe creates no console at all.
$runner = Join-Path $PSScriptRoot 'Run-Sync.vbs'

$action = New-ScheduledTaskAction `
    -Execute (Join-Path $env:WINDIR 'System32\wscript.exe') `
    -Argument ('"{0}"' -f $runner) `
    -WorkingDirectory $PSScriptRoot

$trigger = New-ScheduledTaskTrigger `
    -Daily `
    -At ([datetime]::Today.AddMinutes($StartMinute))

# Repeat through the day at the chosen interval.
$trigger.Repetition = (New-ScheduledTaskTrigger -Once `
    -At ([datetime]::Today.AddMinutes($StartMinute)) `
    -RepetitionInterval (New-TimeSpan -Hours $IntervalHours) `
    -RepetitionDuration (New-TimeSpan -Days 1)).Repetition

# DisallowStartIfOnBatteries stays at its default of True -- a run should not
# begin on battery.
#
# StopIfGoingOnBatteries is deliberately DISABLED, however. When Task Scheduler
# "stops" a task it terminates the process outright; it does not run the
# script's cleanup, so a run killed that way leaves monerod orphaned with no
# graceful shutdown. That is the most likely cause of the 29 Aug orphan which
# ran unsupervised for 5.5 hours and died with zero shutdown markers.
#
# Letting an in-flight run finish is far safer than having it killed mid-sync:
# the script caps its own runtime and always shuts the daemon down properly.
$settings = New-ScheduledTaskSettingsSet `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -DontStopOnIdleEnd `
    -Hidden `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2)

# Task Scheduler creates tasks at BELOW_NORMAL priority (7), which the whole
# process tree inherits -- and made monerod's LMDB load take minutes instead
# of the ~1 second it takes when run by hand at Normal priority. Force NORMAL
# (5). The cmdlet does not expose this, so it is set on the XML below.
$settings.Priority = 5

# Interactive = runs as the logged-on user, which is what makes the
# VeraCrypt-mounted E: visible to the task.
$principal = New-ScheduledTaskPrincipal `
    -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive `
    -RunLevel Limited

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Replaced existing task '$TaskName'." -ForegroundColor Yellow
}

Register-ScheduledTask `
    -TaskName    $TaskName `
    -Action      $action `
    -Trigger     $trigger `
    -Settings    $settings `
    -Principal   $principal `
    -Description 'Syncs the Monero blockchain on the VeraCrypt volume, then shuts monerod down gracefully.' | Out-Null

$trayInstalled = Install-TrayShortcut

Write-Host ''
Write-Host "Registered '$TaskName'" -ForegroundColor Green
Write-Host ''
Write-Host ("  runs        every {0} hours, starting at {1:00}:{2:00}" -f $IntervalHours, 0, $StartMinute)
Write-Host ("  as          {0} (only when logged on)" -f ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name))
Write-Host  '  on battery  will not start'
Write-Host  '  overlap     skipped if a run is still going'
Write-Host ''

if ($trayInstalled) {
    Write-Host 'Tray icon set to start at login' -ForegroundColor Green
    Write-Host ("  shortcut    {0}" -f $shortcutPath)
    Write-Host ''
}

Write-Host 'Runs hidden - no console window will appear.' -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Start the tray now (without logging out):' -ForegroundColor Cyan
Write-Host ("  wscript.exe `"{0}`"" -f $trayLauncher) -ForegroundColor White
Write-Host ''
Write-Host 'Run a sync now to test:' -ForegroundColor Cyan
Write-Host ("  Start-ScheduledTask -TaskName '{0}'" -f $TaskName) -ForegroundColor White
Write-Host ''
Write-Host 'Remove everything (task + startup shortcut):' -ForegroundColor Cyan
Write-Host  '  .\Install-Task.ps1 -Remove' -ForegroundColor White
Write-Host ''

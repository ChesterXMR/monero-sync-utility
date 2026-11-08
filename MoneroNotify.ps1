<#
    MoneroNotify.ps1

    Desktop notifications from the sync script, which runs hidden with no
    console and no tray of its own. Used to tell the user when a run has to
    stop early -- e.g. a VirtualBox VM started mid-sync -- and, more
    importantly, when the daemon has fully exited and it is safe to proceed.

    Tries a Windows toast first (works from a hidden process in the user's
    session), then falls back to a temporary tray balloon.

    Not meant to be run directly.
#>

function Send-UserNotification {
    param(
        [string] $Title,
        [string] $Message,
        [ValidateSet('Info', 'Warning', 'Error')]
        [string] $Level = 'Info'
    )

    # --- 1. Windows toast -------------------------------------------------
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

        # PowerShell's own AppUserModelID. Toasts need a registered app id and
        # this one exists on every Windows install, so the toast shows as
        # "Windows PowerShell" rather than being silently dropped.
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

        $t = [System.Security.SecurityElement]::Escape($Title)
        $m = [System.Security.SecurityElement]::Escape($Message)
        $xml = "<toast scenario='reminder'><visual><binding template='ToastGeneric'><text>$t</text><text>$m</text></binding></visual></toast>"

        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        return $true
    } catch { }

    # --- 2. Fallback: temporary tray balloon -------------------------------
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon            = [System.Drawing.SystemIcons]::Information
        $ni.Visible         = $true
        $ni.BalloonTipTitle = $Title
        $ni.BalloonTipText  = $Message
        $ni.BalloonTipIcon  = $Level
        $ni.ShowBalloonTip(8000)

        # A balloon needs a message pump to render; run one briefly.
        $end = (Get-Date).AddSeconds(6)
        while ((Get-Date) -lt $end) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }

        $ni.Visible = $false
        $ni.Dispose()
        return $true
    } catch {
        return $false
    }
}

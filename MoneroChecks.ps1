<#
    MoneroChecks.ps1

    Shared preflight checks, dot-sourced by both Sync-Monero.ps1 and
    MoneroTray.ps1 so the scheduled run and the tray's "Run checks now" can
    never disagree about what counts as safe to run.

    Not meant to be run directly.
#>

# Actual VM processes only. VBoxSVC.exe is deliberately excluded: it lingers as
# a background COM service for minutes after everything is closed, and treating
# it as "VirtualBox is running" would block runs constantly.
$script:VmProcessNames = @('VBoxHeadless', 'VirtualBoxVM')

function Test-MonerodRunning {
    param([int] $RpcPort = 18081)

    $proc = @(Get-Process -Name 'monerod' -ErrorAction SilentlyContinue)

    # The port check is the elevation-proof signal. If monerod was started
    # elevated, Get-Process still finds it but .Path/.StartTime read back
    # blank, so never depend on those properties here.
    #
    # GetActiveTcpListeners() is used rather than Get-NetTCPConnection: the
    # cmdlet takes ~400ms, this takes ~30ms, and the tray polls every few
    # seconds. The tradeoff is no owning-PID, which only affected a cosmetic
    # detail string.
    $portOpen = $false
    try {
        $portOpen = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().
                      GetActiveTcpListeners() | Where-Object { $_.Port -eq $RpcPort }).Count -gt 0
    } catch {
        # Fall back to the slow-but-certain path if the API is unavailable.
        $portOpen = @(Get-NetTCPConnection -LocalPort $RpcPort -State Listen -ErrorAction SilentlyContinue).Count -gt 0
    }

    $detail = if ($proc.Count -gt 0 -and $portOpen) {
        "PID $($proc[0].Id), listening on $RpcPort"
    } elseif ($proc.Count -gt 0) {
        "PID $($proc[0].Id), RPC port not yet open"
    } elseif ($portOpen) {
        "port $RpcPort in use"
    } else {
        "no process, port $RpcPort free"
    }

    [pscustomobject]@{
        Running = ($proc.Count -gt 0 -or $portOpen)
        Detail  = $detail
        Process = $(if ($proc.Count -gt 0) { $proc[0] } else { $null })
    }
}

function Test-VirtualBoxRunning {
    $vms = @(Get-Process -Name $script:VmProcessNames -ErrorAction SilentlyContinue)

    $detail = if ($vms.Count -gt 0) {
        'VM active: ' + (($vms | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ', ')
    } else {
        'no VM processes'
    }

    [pscustomobject]@{
        Running = ($vms.Count -gt 0)
        Detail  = $detail
    }
}

function Test-BlockchainMounted {
    param([string] $DataDir = 'E:\Monero Blockchain')

    # Get-Volume is deliberately not used: VeraCrypt volumes do not reliably
    # surface through the storage provider and it returns nothing for E:,
    # which would produce false "not mounted" exits.
    #
    # Presence of the LMDB data file is the real proof the volume is mounted
    # AND populated. Pointing monerod at a missing or empty folder would start
    # a fresh sync from block 0 onto unencrypted disk -- the worst failure
    # this utility can have.
    $dbPath = Join-Path $DataDir 'lmdb\data.mdb'

    $driveOk  = Test-Path -LiteralPath ((Split-Path $DataDir -Qualifier) + '\')
    $folderOk = Test-Path -LiteralPath $DataDir
    $dbOk     = Test-Path -LiteralPath $dbPath

    $detail = if ($dbOk) {
        'data.mdb present, {0:N1} GB map' -f ((Get-Item -LiteralPath $dbPath).Length / 1GB)
    } elseif ($folderOk) {
        'folder present but data.mdb MISSING'
    } elseif ($driveOk) {
        "drive present but '$DataDir' MISSING"
    } else {
        'drive not mounted'
    }

    [pscustomobject]@{
        Mounted = $dbOk
        Detail  = $detail
    }
}

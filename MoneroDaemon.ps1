<#
    MoneroDaemon.ps1

    Shared daemon control, dot-sourced by Sync-Monero.ps1 and MoneroTray.ps1.

    The one rule here: monerod is NEVER force-killed. Killing it mid-flush is
    the corruption vector this whole utility exists to avoid. Every path either
    shuts the daemon down gracefully or leaves it alone and says so.

    Not meant to be run directly.
#>

# The daemon's own farewell markers. Matched exactly, because loose patterns
# produce false positives: monerod logs "state: stopping adding blocks in state
# synchronizing" constantly as routine peer chatter, so anything matching bare
# "stopping" or "stopped" would confirm a graceful shutdown from unrelated
# network traffic.
$script:ShutdownMarkers = @(
    'Deinitializing core'
    'Stopping cryptonote protocol'
    'Cryptonote protocol stopped successfully'
    'Stopping core RPC server'
)

function Get-MonerodProcesses {
    @(Get-Process -Name 'monerod' -ErrorAction SilentlyContinue)
}

function Invoke-MonerodCommand {
    <#
        Runs "monerod.exe --data-dir X <command>" as a client -- the same
        terminal command a person would type -- and returns its output.

        The one guard that must never be removed: the client itself has NO
        timeout and blocks for as long as a busy daemon takes to answer
        (measured at 126s, and once ~24 minutes, which hung an entire run).
        So the client runs as a separate process and is KILLED past the
        timeout. Killing the client is harmless -- it is not the daemon.
    #>
    param(
        [string] $MonerodPath,
        [string] $DataDir,
        [string] $Command,
        [int]    $TimeoutSeconds = 30
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $MonerodPath
    $psi.Arguments              = ('--data-dir "{0}" {1}' -f $DataDir, $Command)
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()

    # Async reads so a full pipe can never deadlock the client.
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()

    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch { }
        [void]$p.WaitForExit(5000)
        return [pscustomobject]@{ TimedOut = $true; Output = '' }
    }

    [pscustomobject]@{
        TimedOut = $false
        Output   = (@($outTask.Result, $errTask.Result) -join "`n")
    }
}

function Get-MonerodStatus {
    <#
        "monerod.exe --data-dir X status", parsed. Returns $null when the
        daemon is not up yet or too busy to answer -- callers treat that
        exactly like the old unanswered poll.

        Sample: "Height: 3751215/3751227 (99.9%) on mainnet, not mining,
                 net hash 6.02 GH/s, v16, 12(out)+0(in) connections, uptime.."
    #>
    param(
        [string] $MonerodPath,
        [string] $DataDir,
        [int]    $TimeoutSeconds = 30
    )

    $r = Invoke-MonerodCommand -MonerodPath $MonerodPath -DataDir $DataDir `
                               -Command 'status' -TimeoutSeconds $TimeoutSeconds
    if ($r.TimedOut) { return $null }

    if ($r.Output -match 'Height:\s*(\d+)/(\d+)\s*\(([\d.]+)%\)') {
        $h = [long]$matches[1]
        $t = [long]$matches[2]
        $peers = if ($r.Output -match '(\d+)\(out\)') { [int]$matches[1] } else { 0 }

        return [pscustomobject]@{
            Height = $h
            Target = $t
            Synced = ($t -gt 0 -and $h -ge $t)
            Peers  = $peers
        }
    }

    # "Error: Couldn't connect to daemon" or anything unparseable.
    return $null
}

function Send-MonerodStop {
    <#
        Asks a running daemon to shut down via "monerod.exe --data-dir X exit"
        -- the terminal command -- through the timeout-guarded client runner.

        A timeout does NOT mean the daemon ignored the request; it is often
        just too busy to reply while already acting on it. Callers decide the
        real outcome by watching the process exit.
    #>
    param(
        [int]    $RpcPort = 18081,
        [int]    $TimeoutSeconds = 60,
        [string] $MonerodPath,
        [string] $DataDir,
        [scriptblock] $Logger = $null
    )

    function _log($m, $lvl = 'INFO') {
        if ($Logger) { & $Logger $m $lvl } else { Write-Host $m }
    }

    if (-not ($MonerodPath -and (Test-Path -LiteralPath $MonerodPath))) {
        _log "  monerod.exe not found at: $MonerodPath" 'WARN'
        return $false
    }

    $r = Invoke-MonerodCommand -MonerodPath $MonerodPath -DataDir $DataDir `
                               -Command 'exit' -TimeoutSeconds $TimeoutSeconds

    if ($r.TimedOut) {
        _log '  exit command gave no reply in time (daemon busy) - it may still be stopping.' 'WARN'
        return $false
    }

    foreach ($l in ($r.Output -split "`r?`n")) {
        if ($l -match '\S') { _log "  exit | $l" }
    }

    return ($r.Output -match 'Stop signal sent')
}

function Wait-MonerodExit {
    <#
        Waits for the given processes to exit on their own. Never force-kills:
        a stuck monerod is recoverable, a killed one may not be. Returns $true
        only if every process actually exited.
    #>
    param(
        [System.Diagnostics.Process[]] $Processes,
        [int] $TimeoutMinutes = 40,
        [scriptblock] $Logger = $null,
        [scriptblock] $OnTick = $null
    )

    function _log($m, $lvl = 'INFO') {
        if ($Logger) { & $Logger $m $lvl } else { Write-Host $m }
    }

    $start      = Get-Date
    $deadline   = $start.AddMinutes($TimeoutMinutes)
    $lastReport = 0

    while ((Get-Date) -lt $deadline) {
        $alive = @($Processes | Where-Object {
            try { $_.Refresh(); -not $_.HasExited } catch { $false }
        })

        if ($alive.Count -eq 0) { return $true }

        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        if ($elapsed -ge $lastReport + 15) {
            $lastReport = $elapsed
            if ($OnTick) { & $OnTick }
            _log ("  flushing... {0}s elapsed ({1} daemon(s) still running)" -f $elapsed, $alive.Count)
        }

        Start-Sleep -Seconds 1
    }

    return $false
}

function Test-ShutdownMarkers {
    <#
        Confirms the daemon logged its own shutdown sequence rather than merely
        disappearing. This is the only real proof it closed the database
        cleanly instead of being cut off.
    #>
    param([string] $LogPath, [int] $TailLines = 200)

    $seen = @()
    if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) {
        return [pscustomobject]@{ Seen = $seen; Total = $script:ShutdownMarkers.Count }
    }

    $tail = @(Get-Content -LiteralPath $LogPath -Tail $TailLines -ErrorAction SilentlyContinue)
    foreach ($m in $script:ShutdownMarkers) {
        if ($tail -match [regex]::Escape($m)) { $seen += $m }
    }

    [pscustomobject]@{ Seen = $seen; Total = $script:ShutdownMarkers.Count }
}

function Stop-AllMonerod {
    <#
        Gracefully stops every monerod on the machine and waits for them to go.

        Called at the start of a run so a daemon orphaned by a previously
        crashed supervisor is cleaned up instead of blocking the schedule --
        that orphan once blocked three consecutive runs for 5.5 hours and was
        eventually killed with zero shutdown markers.

        Note this also stops a daemon started by hand. That is deliberate: the
        utility owns this database, and a leftover daemon must never be left
        running. It is logged whenever it happens.
    #>
    param(
        [int]    $RpcPort = 18081,
        [string] $MonerodPath,
        [string] $DataDir,
        [int]    $TimeoutMinutes = 40,
        [int]    $StopRequestTimeoutSeconds = 60,
        [scriptblock] $Logger = $null
    )

    function _log($m, $lvl = 'INFO') {
        if ($Logger) { & $Logger $m $lvl } else { Write-Host $m }
    }

    $existing = Get-MonerodProcesses
    if ($existing.Count -eq 0) {
        return [pscustomobject]@{ Found = 0; Stopped = $true }
    }

    _log ("Found {0} monerod process(es) already running: {1}" -f `
          $existing.Count, (($existing | ForEach-Object { "PID $($_.Id)" }) -join ', ')) 'WARN'
    _log 'These were not started by this run. Stopping them gracefully first.' 'WARN'

    [void](Send-MonerodStop -RpcPort $RpcPort -TimeoutSeconds $StopRequestTimeoutSeconds `
                            -MonerodPath $MonerodPath -DataDir $DataDir -Logger $Logger)

    $gone = Wait-MonerodExit -Processes $existing -TimeoutMinutes $TimeoutMinutes -Logger $Logger

    if ($gone) {
        _log 'Pre-existing daemon(s) shut down cleanly.' 'OK'
    } else {
        _log ("Pre-existing daemon(s) did not exit within {0} min." -f $TimeoutMinutes) 'ERROR'
        _log 'They have NOT been force-killed. Leave them to finish.' 'ERROR'
    }

    [pscustomobject]@{ Found = $existing.Count; Stopped = $gone }
}

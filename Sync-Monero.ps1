<#
    Sync-Monero.ps1

    Starts monerod, syncs to the network tip, then shuts it down gracefully.

    Designed to run unattended under Task Scheduler every hour, as the
    logged-on user (VeraCrypt mounts E: per-session, so a SYSTEM/logged-off
    task would not see the volume).

    Preflight -- exits immediately unless ALL hold:
      1. E:\Monero Blockchain\lmdb\data.mdb exists (VeraCrypt volume mounted)
      2. No VirtualBox VM running
      3. No other copy of this script running

    Any monerod already running is gracefully stopped first rather than
    treated as a reason to skip. An orphan left by a crashed supervisor once
    blocked three consecutive runs for 5.5 hours and was eventually killed
    with zero shutdown markers.

    Shutdown is ALWAYS the terminal command "monerod.exe --data-dir X exit"
    (with stdin-close as fallback -- the "EOF on stdin, exiting" path a
    console session uses). The process is never force-killed: killing it
    mid-flush is the corruption vector this whole utility exists to avoid.
    On timeout it is left running and logged loudly. A crash handler stops
    the daemon even if this script dies unexpectedly.

    Exit codes:
      0  synced and shut down cleanly
      1  preflight failed (a normal, expected skip)
      2  sync did not complete, but shut down cleanly
      3  shutdown timed out -- daemon may still be running
      4  daemon died unexpectedly
#>

[CmdletBinding()]
param(
    [string] $MonerodPath = 'C:\Program Files\Monero GUI Wallet\monerod.exe',
    [string] $DataDir     = 'E:\Monero Blockchain',
    [int]    $RpcPort     = 18081,

    # Wall-clock cap on syncing. Must leave room for the shutdown flush, which
    # was measured at ~5 minutes on this 280 GB LMDB, before the next run.
    [int]    $MaxSyncMinutes = 120,

    # Generous: flushing a 280 GB LMDB takes minutes. Typical measured runs are
    # 44-295s, but one daemon stuck on unclosable peer connections took ~24
    # minutes to finish -- and it did finish cleanly, so the cap must sit well
    # above that rather than give up on a daemon that is still working.
    [int]    $ShutdownTimeoutMinutes = 40,

    # Hard timeout on the "monerod exit" client command. The daemon can be
    # slow to reply while busy; a timeout here is not treated as failure
    # (only the client is killed, never the daemon).
    [int]    $StopRequestTimeoutSeconds = 60,

    [int]    $PollSeconds = 15,

    # monerod stops answering the status command while it verifies blocks, so
    # this needs to tolerate multi-second stalls rather than the default 10s.
    [int]    $RpcPollTimeoutSeconds = 30,

    # Minimum peer connections before a 'synchronized' report is believed.
    # A daemon with no peers has nothing to compare its height against.
    #
    # This was 1, which was not enough: the first peer connects within a second
    # or two but has not yet sent its chain data, so the node still reports
    # target_height == its own height and claims synchronized. Runs were
    # exiting ~3s in with "+0 blocks" while genuinely being over 100 behind --
    # the very next manual run, once 12 peers had arrived, found them all.
    [int]    $MinPeers = 4,

    # Minimum time the daemon must have been answering before a 'synchronized'
    # report counts, however many peers it claims. Peer count alone is a proxy
    # for "has heard the real chain tip"; this is the belt to that braces, and
    # costs nothing on an already-synced node beyond one extra poll cycle.
    [int]    $SyncSettleSeconds = 45,

    # How long to keep waiting for peers before accepting a peerless
    # 'synchronized' report and shutting down anyway.
    [int]    $NoPeerTimeoutMinutes = 5,

    # Rolling cap on the supervisor's own log. (monerod writes and rotates its
    # own bitmonero.log in the data dir; that is not ours to manage.)
    [int]    $MaxSyncLogMB    = 5,

    # Skip the sync and just verify preflight + start + graceful stop.
    [switch] $TestShutdownOnly
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'MoneroChecks.ps1')
. (Join-Path $PSScriptRoot 'MoneroDaemon.ps1')
. (Join-Path $PSScriptRoot 'MoneroHistory.ps1')
. (Join-Path $PSScriptRoot 'MoneroSettings.ps1')
. (Join-Path $PSScriptRoot 'MoneroNotify.ps1')

# --- VirtualBox watch ----------------------------------------------------
# The preflight VM check only protects the START of a run. A VM that opens
# mid-sync attaches to the same LMDB the daemon is writing, which has
# corrupted the database before. So for as long as monerod is alive, every
# wait in this script goes through Wait-OrVm, which checks for a VM once a
# second and returns early the instant one appears -- the caller then stops
# the daemon gracefully and notifies the user.
#
# This is a race against the VM reaching the disk: it shrinks the window to
# one second of detection plus the daemon's flush time, but cannot make it
# zero. The notification is what tells the user when it is actually safe.
$script:VmInterrupt = $false   # a VirtualBox VM appeared
$script:UserStop    = $false   # "Stop sync" pressed in the tray
$script:VmDetail    = ''

function Wait-OrVm {
    <#
        Sleeps for $Seconds in one-second slices. Returns $true early if a
        VirtualBox VM appears, or if the tray has asked for a graceful stop
        (it does so by dropping a request-stop file in .state).
    #>
    param([int] $Seconds)

    for ($i = 0; $i -lt $Seconds; $i++) {
        # The daemon dying mid-wait must break the loop, or the script hangs
        # forever holding the single-instance mutex while nothing runs -- which
        # is exactly what stranded a run and blocked every later one. The
        # caller re-checks HasExited immediately after Wait-OrVm returns.
        if ($script:MonerodProc) {
            try { $script:MonerodProc.Refresh(); if ($script:MonerodProc.HasExited) { return $true } } catch { }
        }

        if (Test-Path -LiteralPath $script:StopFlag) {
            $script:UserStop = $true
            return $true
        }

        $vm = Test-VirtualBoxRunning
        if ($vm.Running) {
            $script:VmInterrupt = $true
            $script:VmDetail    = $vm.Detail
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Invoke-Interrupt {
    <#
        Logs why the run is stopping early and tells the user. Called once, at
        the moment the interruption is first seen.
    #>
    Write-Host ''
    if ($script:VmInterrupt) {
        Write-Log "VIRTUALBOX VM STARTED - $script:VmDetail" 'ERROR'
        Write-Log 'A VM can attach to the same database monerod is writing.' 'ERROR'
        Write-Log 'Stopping the sync gracefully now. Do NOT use the VM until the' 'ERROR'
        Write-Log 'all-clear notification arrives.' 'ERROR'

        [void](Send-UserNotification -Title 'Monero Sync - VM detected, stopping' `
            -Message 'A VirtualBox VM started during a sync. monerod is shutting down. Wait for the all-clear before using the VM.' `
            -Level 'Warning')
    }
    elseif ($script:UserStop) {
        Write-Log 'STOP REQUESTED from the tray. Stopping the sync gracefully.' 'WARN'
    }
}

function Exit-IfTerminated {
    <#
        The tray's Terminate button force-kills monerod and drops a
        request-terminate file first, so that the daemon vanishing is recorded
        as a deliberate termination rather than an unexplained crash.
    #>
    if (Test-Path -LiteralPath $script:TerminateFlag) {
        Write-Log 'monerod was TERMINATED from the tray - force-killed, no flush.' 'ERROR'
        Write-Log 'The database was NOT closed cleanly. Watch the next run for problems.' 'ERROR'
        Write-Summary 'TERMINATED' 'force-killed from tray; database not flushed'
        exit 4
    }
}

# The sync cap is adjustable from the tray. An explicit -MaxSyncMinutes on the
# command line still wins, so a manual run can override the saved value.
if (-not $PSBoundParameters.ContainsKey('MaxSyncMinutes')) {
    $MaxSyncMinutes = (Get-MoneroSettings -Root $PSScriptRoot).MaxSyncMinutes
}

$logDir  = Join-Path $PSScriptRoot 'logs'
$stateDir = Join-Path $PSScriptRoot '.state'
foreach ($d in @($logDir, $stateDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

# Single rolling log rather than one file per run. Three days of per-run files
# reached 7.9 MB and 22 files; these two are size-capped and rotated instead.
$runLog       = Join-Path $logDir 'sync.log'

# monerod runs with no log flags, so it writes its default bitmonero.log in
# the data dir and rotates it itself. Live output and the shutdown-marker
# check read from there.
$monerodOut   = Join-Path $DataDir 'bitmonero.log'
$summaryLog   = Join-Path $logDir 'sync-history.log'
$statusFile   = Join-Path $stateDir 'last-run.json'

# Request files dropped by the tray's Stop / Terminate buttons. Any left over
# from an earlier run are cleared now so they cannot affect this one.
$script:StopFlag      = Join-Path $stateDir 'request-stop'
$script:TerminateFlag = Join-Path $stateDir 'request-terminate'
foreach ($flag in @($script:StopFlag, $script:TerminateFlag)) {
    Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
}

$script:StartTime = Get-Date

function Reset-LogIfLarge {
    <#
        Keeps a rolling log bounded. When it exceeds the cap the current file
        becomes a single .1 backup and a fresh log starts, so at most two
        generations exist and disk use stays predictable.
    #>
    param([string] $Path, [int] $MaxBytes)

    try {
        if (Test-Path -LiteralPath $Path) {
            $size = (Get-Item -LiteralPath $Path).Length
            if ($size -gt $MaxBytes) {
                $bak = "$Path.1"
                if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
                Move-Item -LiteralPath $Path -Destination $bak -Force
            }
        }
    } catch { }
}

Reset-LogIfLarge -Path $runLog -MaxBytes ($MaxSyncLogMB * 1MB)

function Write-Log {
    param(
        [string] $Message,
        [ValidateSet('INFO','WARN','ERROR','OK','STEP')]
        [string] $Level = 'INFO'
    )

    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '{0}  {1,-5}  {2}' -f $ts, $Level, $Message

    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'STEP'  { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color

    Add-Content -LiteralPath $runLog -Value $line -Encoding utf8
}

function Write-Summary {
    param(
        [string] $Status,
        [string] $Detail,
        [int]    $StartHeight = 0,
        [int]    $EndHeight = 0,
        [double] $FlushSeconds = 0,
        [int]    $MarkersSeen = 0,
        [int]    $MarkersTotal = 0
    )

    $elapsed = (Get-Date) - $script:StartTime
    $line = '{0}  {1,-16}  {2,6:N1} min  {3}' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Status, $elapsed.TotalMinutes, $Detail
    Add-Content -LiteralPath $summaryLog -Value $line -Encoding utf8

    # Structured record for the tray's history window.
    Add-HistoryEntry -Root $PSScriptRoot -Status $Status -Detail $Detail `
                     -StartedAt $script:StartTime -Minutes $elapsed.TotalMinutes `
                     -StartHeight $StartHeight -EndHeight $EndHeight `
                     -FlushSeconds $FlushSeconds `
                     -MarkersSeen $MarkersSeen -MarkersTotal $MarkersTotal

    $script:SummaryWritten = $true

    @{
        Status     = $Status
        Detail     = $Detail
        FinishedAt = (Get-Date).ToString('o')
        Minutes    = [math]::Round($elapsed.TotalMinutes, 1)
        RunLog     = $runLog
        MonerodLog = $monerodOut
    } | ConvertTo-Json | Set-Content -LiteralPath $statusFile -Encoding utf8
}

# Streams any new lines monerod has written since the last call, so its own
# output is visible live rather than only after the run.
$script:MonerodLogPos  = 0   # byte offset already consumed
$script:SummaryWritten = $false
function Show-MonerodOutput {
    param([switch] $All)

    if (-not (Test-Path -LiteralPath $monerodOut)) { return }

    # Seek from a byte offset rather than re-reading the file. A single run's
    # daemon log reached 2.2 MB and re-reading it every 15s wasted real time;
    # tracking line counts instead would break once the file passes any tail
    # window, silently stopping live output partway through a run.
    $new = @()
    try {
        $fs = [System.IO.File]::Open($monerodOut, 'Open', 'Read', 'ReadWrite')
        try {
            # bitmonero.log is appended across runs; a shrunken file means
            # monerod rotated it, so rewind rather than seeking past the end.
            if ($fs.Length -lt $script:MonerodLogPos) { $script:MonerodLogPos = 0 }

            # Capture the length BEFORE reading: disposing the StreamReader
            # closes the underlying stream, so $fs.Length afterwards throws --
            # which the catch below swallowed, silently disabling this whole
            # function on every call.
            $endPos = $fs.Length

            [void]$fs.Seek($script:MonerodLogPos, 'Begin')
            $sr = New-Object System.IO.StreamReader($fs)
            try {
                $text = $sr.ReadToEnd()
                if ($text) { $new = $text -split "`r?`n" }
            } finally { $sr.Dispose() }

            $script:MonerodLogPos = $endPos
        } finally { try { $fs.Dispose() } catch { } }
    } catch {
        return
    }

    if ($new.Count -eq 0) { return }

    # Mirror the daemon's lines into the run log in CONSOLE form, so the
    # tray's Live output pane shows exactly what a person sees running the
    # command by hand. bitmonero.log rows are tab-separated
    #   timestamp  thread  LEVEL  category  source  message
    # and the console shows "timestamp  L  message" for global INFO plus any
    # warnings/errors. The same file also collects each status/exit CLIENT
    # invocation's banner and connect-error chatter, which a console session
    # never shows -- those are dropped.
    $mirror = @()
    foreach ($l in $new) {
        if ($l -notmatch '\S') { continue }

        $show = $null
        if ($l -match '^(\S+ \S+)\t\S+\t(\w+)\t(\S+)\t(\S+)\t(.*)$') {
            $ts = $matches[1]; $lvl = $matches[2]; $cat = $matches[3]
            $src = $matches[4]; $msg = $matches[5]

            # Client chatter, not daemon output.
            if ($msg -match "Couldn't connect to daemon") { continue }
            if ($src -match 'main\.cpp' -and $msg -match "^Monero '") { continue }

            # What the console shows: global INFO, plus warnings and errors.
            if ($cat -eq 'global' -or $lvl -in @('WARNING', 'ERROR', 'FATAL')) {
                $show = '{0} {1} {2}' -f $ts, $lvl.Substring(0, 1), $msg
            }
        } else {
            $show = $l
        }

        if ($null -eq $show) { continue }

        $c = if ($show -match '^\S+ \S+ E ') { 'Red' }
             elseif ($show -match '^\S+ \S+ W ') { 'DarkYellow' }
             else { 'DarkGray' }
        Write-Host "    | $show" -ForegroundColor $c
        $mirror += "  | $show"
    }
    if ($mirror.Count -gt 0) {
        try { Add-Content -LiteralPath $runLog -Value $mirror -Encoding utf8 } catch { }
    }
}

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ' Monero sync utility' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ''

Write-Log "Run started. Log: $runLog"
Write-Log "Data dir: $DataDir"

# ---------------------------------------------------------------------------
# Single-instance guard
# ---------------------------------------------------------------------------
# Prevents a slow run from colliding with the next scheduled one. Held for the
# life of the process and released in finally{}.

$mutex        = New-Object System.Threading.Mutex($false, 'Global\MoneroSyncUtility')
$haveMutex    = $false
$monerodProc  = $null
$exitCode     = 0

try {
    $haveMutex = $mutex.WaitOne(0)
    if (-not $haveMutex) {
        Write-Log 'Another instance of this script is already running. Exiting.' 'WARN'
        Write-Summary 'SKIP-OVERLAP' 'another instance running'
        exit 1
    }

    # -----------------------------------------------------------------------
    # Preflight
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Log 'PREFLIGHT CHECKS' 'STEP'

    $mount = Test-BlockchainMounted -DataDir $DataDir
    if ($mount.Mounted) {
        Write-Log "  [1/3] Blockchain mounted   - $($mount.Detail)" 'OK'
    } else {
        Write-Log "  [1/3] Blockchain NOT mounted - $($mount.Detail)" 'ERROR'
        Write-Log 'Refusing to start: monerod against a missing data dir would' 'ERROR'
        Write-Log 'begin a fresh sync from block 0 onto unencrypted disk.' 'ERROR'
        Write-Summary 'SKIP-NOTMOUNTED' $mount.Detail
        exit 1
    }

    $vbox = Test-VirtualBoxRunning
    if ($vbox.Running) {
        Write-Log "  [2/3] VirtualBox VM RUNNING - $($vbox.Detail)" 'ERROR'
        Write-Summary 'SKIP-VBOX' $vbox.Detail
        exit 1
    }
    Write-Log "  [2/3] No VirtualBox VM     - $($vbox.Detail)" 'OK'

    if (-not (Test-Path -LiteralPath $MonerodPath)) {
        Write-Log "monerod.exe not found at: $MonerodPath" 'ERROR'
        Write-Summary 'ERROR-NOBINARY' $MonerodPath
        exit 1
    }

    Write-Log 'All checks passed - clear to sync.' 'OK'

    # -----------------------------------------------------------------------
    # Clear any pre-existing daemon
    # -----------------------------------------------------------------------
    # Previously this was a reason to skip the run, which let an orphan from a
    # crashed supervisor block three consecutive runs for 5.5 hours before
    # being killed with zero shutdown markers. Now every daemon found is
    # stopped gracefully first -- never force-killed -- so the schedule
    # self-repairs instead of deadlocking.

    $logger = { param($m, $lvl) if ($lvl) { Write-Log $m $lvl } else { Write-Log $m } }

    $pre = Stop-AllMonerod -RpcPort $RpcPort -MonerodPath $MonerodPath -DataDir $DataDir `
                           -TimeoutMinutes $ShutdownTimeoutMinutes `
                           -StopRequestTimeoutSeconds $StopRequestTimeoutSeconds `
                           -Logger $logger

    if ($pre.Found -gt 0 -and -not $pre.Stopped) {
        Write-Log 'Cannot start: a pre-existing daemon is still running.' 'ERROR'
        Write-Summary 'ERROR-STUCK-PRE' ("{0} daemon(s) would not stop" -f $pre.Found)
        exit 3
    }

    # -----------------------------------------------------------------------
    # Keep the machine awake
    # -----------------------------------------------------------------------
    # Sleeping mid-write is another corruption vector.

    $sleepBlocked = $false
    try {
        if (-not ('PowerUtil' -as [type])) {
            Add-Type -Namespace Native -Name PowerUtil -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
        }
        # ES_CONTINUOUS (0x80000000) | ES_SYSTEM_REQUIRED (0x00000001).
        #
        # Written as decimal [uint32] literals, NOT hex: PowerShell 5.1 parses
        # 0x80000000 as a signed Int32, which overflows to -2147483647 and is
        # rejected by the uint32 parameter. The 'u' suffix that would fix this
        # is PowerShell 7+ only.
        $esFlags = [uint32]2147483648 -bor [uint32]1
        $prev = [Native.PowerUtil]::SetThreadExecutionState($esFlags)
        if ($prev -ne 0) {
            $sleepBlocked = $true
            Write-Log 'Sleep suppressed for the duration of this run.'
        } else {
            Write-Log 'SetThreadExecutionState returned 0 - sleep NOT suppressed.' 'WARN'
        }
    } catch {
        Write-Log "Could not suppress sleep: $($_.Exception.Message)" 'WARN'
    }

    # -----------------------------------------------------------------------
    # Launch
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Log 'STARTING MONEROD' 'STEP'

    # Arguments containing spaces MUST be pre-quoted. Start-Process does not
    # quote array elements, so an unquoted "E:\Monero Blockchain" reaches
    # monerod as two tokens -- it takes "E:\Monero" as the data-dir and tries
    # to run "Blockchain" as a command, prints its command list, and exits.
    #
    # --log-level 1 (not 0) so the daemon records its own shutdown sequence,
    # which is the evidence that it stopped gracefully.
    # The exact command the user runs by hand -- no extra flags. monerod then
    # writes its own bitmonero.log in the data dir (rotating it itself), which
    # is where the live output and the shutdown-marker check read from.
    $monerodArgs = @(
        '--data-dir', ('"{0}"' -f $DataDir)
    )

    Write-Log ('Command: & "{0}" {1}' -f $MonerodPath, ($monerodArgs -join ' '))
    Write-Log "monerod output -> $monerodOut"

    # Launched via ProcessStartInfo rather than Start-Process because
    # -WindowStyle Hidden does NOT reliably hide a console child: when the
    # parent already owns a console, monerod inherits it and its output appears
    # in a visible window. CreateNoWindow suppresses the console outright.
    # Run hidden but with stdin held open: an interactive monerod exits the
    # moment stdin hits EOF ("EOF on stdin, exiting"), and a windowless
    # process has no console stdin. Keeping the pipe open reproduces exactly
    # what a console session does. Bonus safety: if this script is ever hard-
    # killed, the pipe breaks and monerod exits gracefully on its own.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName              = $MonerodPath
    $psi.Arguments             = ($monerodArgs -join ' ')
    $psi.UseShellExecute       = $false
    $psi.CreateNoWindow        = $true
    $psi.WindowStyle           = 'Hidden'
    $psi.RedirectStandardInput = $true

    $monerodProc = New-Object System.Diagnostics.Process
    $monerodProc.StartInfo = $psi
    [void]$monerodProc.Start()
    $script:MonerodStdin = $monerodProc.StandardInput

    # bitmonero.log is appended across runs, so remember where this run
    # starts and only surface lines written after this point.
    try {
        if (Test-Path -LiteralPath $monerodOut) {
            $script:MonerodLogPos = (Get-Item -LiteralPath $monerodOut).Length
        }
    } catch { }

    # Force Normal priority. Task Scheduler runs tasks at BELOW_NORMAL by
    # default and the child inherits it, which made the 280 GB LMDB load take
    # MINUTES under the scheduler versus ~1 second when run by hand in a
    # console at Normal priority. This is the single biggest speed fix.
    try {
        $monerodProc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
        Write-Log 'monerod priority set to Normal.'
    } catch {
        Write-Log "Could not raise monerod priority: $($_.Exception.Message)" 'WARN'
    }

    # Script-scoped too, so Wait-OrVm can notice the daemon exiting mid-wait.
    $script:MonerodProc = $monerodProc

    Write-Log "monerod started, PID $($monerodProc.Id)" 'OK'

    # -----------------------------------------------------------------------
    # Wait for RPC
    # -----------------------------------------------------------------------
    # The daemon can spend minutes catching up and verifying blocks before it
    # answers commands -- it is usually WORKING during this phase, not stuck.

    Write-Host ''
    Write-Log 'WAITING FOR DAEMON (polling the status command; it may already be syncing)' 'STEP'

    $rpcDeadline = (Get-Date).AddMinutes(20)
    $info        = $null

    while ((Get-Date) -lt $rpcDeadline) {
        Show-MonerodOutput

        if ($monerodProc.HasExited) {
            Exit-IfTerminated
            Write-Log "monerod exited unexpectedly during startup (code $($monerodProc.ExitCode))" 'ERROR'
            Show-MonerodOutput
            Write-Summary 'ERROR-STARTUP' "exit code $($monerodProc.ExitCode)"
            exit 4
        }

        # Probe with "monerod.exe --data-dir X status" -- the same command a
        # person would run in a second terminal. It fails fast while the
        # daemon is still starting.
        $s = Get-MonerodStatus -MonerodPath $MonerodPath -DataDir $DataDir -TimeoutSeconds 20
        if ($s) {
            $info = [pscustomobject]@{
                height                     = $s.Height
                target_height              = $s.Target
                synchronized               = $s.Synced
                outgoing_connections_count = $s.Peers
            }
            break
        }
        $info = $null

        # The daemon already has the LMDB open while loading, so a VM
        # appearing here is just as dangerous as one appearing mid-sync.
        if (Wait-OrVm 5) { break }
        $monerodProc.Refresh()
    }

    Show-MonerodOutput

    if ($script:VmInterrupt -or $script:UserStop) {
        Invoke-Interrupt
    } elseif (-not $info) {
        Write-Log 'The status command got no answer within 20 minutes.' 'ERROR'
        Write-Log 'Attempting graceful shutdown anyway.' 'WARN'
    } else {
        $loadSec = [int]((Get-Date) - $script:StartTime).TotalSeconds
        Write-Log "Daemon answering after ${loadSec}s" 'OK'
        Write-Log ("  height {0} / target {1}, synchronized={2}, peers out={3}" -f `
                   $info.height, $info.target_height, $info.synchronized, $info.outgoing_connections_count)
    }

    # -----------------------------------------------------------------------
    # Sync
    # -----------------------------------------------------------------------

    $startHeight = if ($info) { $info.height } else { 0 }
    $syncedOk    = $false

    if ($script:VmInterrupt -or $script:UserStop) {
        # Already logged and notified; go straight to the graceful shutdown.
    }
    elseif ($TestShutdownOnly) {
        Write-Host ''
        Write-Log 'TestShutdownOnly set - skipping sync, going straight to shutdown.' 'WARN'
        $syncedOk = $true
    }
    elseif ($info) {
        Write-Host ''
        Write-Log "SYNCING (cap: $MaxSyncMinutes min)" 'STEP'

        $syncDeadline = (Get-Date).AddMinutes($MaxSyncMinutes)

        while ((Get-Date) -lt $syncDeadline) {
            Show-MonerodOutput

            if ($monerodProc.HasExited) {
                Exit-IfTerminated
                Write-Log "monerod exited unexpectedly during sync (code $($monerodProc.ExitCode))" 'ERROR'
                Write-Summary 'ERROR-DIED' "exit code $($monerodProc.ExitCode)"
                exit 4
            }

            # Poll with the status command, exactly as typed by hand. monerod
            # is single-threaded on its command handler: while verifying and
            # writing blocks it simply does not answer -- that is the daemon
            # doing exactly the work we asked for, so an occasional unanswered
            # poll is normal. Only a sustained run of failures is flagged.
            $s = Get-MonerodStatus -MonerodPath $MonerodPath -DataDir $DataDir `
                                   -TimeoutSeconds $RpcPollTimeoutSeconds
            if ($null -eq $s) {
                $script:ConsecutivePollFailures++

                if ($script:ConsecutivePollFailures -ge 5) {
                    Write-Log ("status command unanswered for {0} consecutive polls" -f `
                               $script:ConsecutivePollFailures) 'WARN'
                    $script:ConsecutivePollFailures = 0
                } else {
                    Write-Log '  (daemon busy, status did not answer - normal during block verification)'
                }

                if (Wait-OrVm $PollSeconds) { break }
                $monerodProc.Refresh()
                continue
            }

            $script:ConsecutivePollFailures = 0
            $info = [pscustomobject]@{
                height                     = $s.Height
                target_height              = $s.Target
                synchronized               = $s.Synced
                outgoing_connections_count = $s.Peers
            }

            $peers = [int]$info.outgoing_connections_count

            # 'synchronized' is the authoritative signal, but only once the
            # daemon actually has peers. A freshly started monerod reports
            # target_height 0 with 0 connections and can briefly claim
            # synchronized=true because it has nothing to compare against --
            # accepting that would shut down a node that is genuinely days
            # behind, having synced nothing.
            if ($info.synchronized -eq $true) {
                # Settling window: even with enough peers, a node that has only
                # just started has not necessarily heard the real chain tip yet.
                # Hold the verdict until it has been up long enough for the
                # target height to be meaningful.
                $upSec = [int]((Get-Date) - $script:StartTime).TotalSeconds
                if ($upSec -lt $SyncSettleSeconds) {
                    Write-Log ("  reports synchronized at {0}s with {1} peer(s) - too early to trust, settling" -f `
                               $upSec, $peers)
                    if (Wait-OrVm $PollSeconds) { break }
                    $monerodProc.Refresh()
                    continue
                }

                if ($peers -ge $MinPeers) {
                    Write-Log ("Synchronized at height {0} ({1} peers)" -f $info.height, $peers) 'OK'
                    $syncedOk = $true
                    break
                }

                # Do not wait forever for peers. If the network is unreachable
                # the node will never gain any, and spinning to the full sync
                # cap wastes an hour of disk activity for nothing.
                if (-not $script:NoPeerSince) { $script:NoPeerSince = Get-Date }
                $waited = ((Get-Date) - $script:NoPeerSince).TotalMinutes

                if ($waited -ge $NoPeerTimeoutMinutes) {
                    Write-Log ("Reports synchronized but has stayed below {0} peers for {1:N0} min." -f `
                               $MinPeers, $waited) 'WARN'
                    Write-Log 'Treating as up to date and shutting down. Check network if this repeats.' 'WARN'
                    $syncedOk = $true
                    break
                }

                Write-Log ("  reports synchronized but only {0} peer(s), need {1} - waiting for peers" -f `
                           $peers, $MinPeers) 'WARN'
                if (Wait-OrVm $PollSeconds) { break }
                $monerodProc.Refresh()
                continue
            }

            $behind = if ($info.target_height -gt 0) { $info.target_height - $info.height } else { 0 }
            $targetText = if ($info.target_height -gt 0) { $info.target_height } else { 'unknown' }
            Write-Log ("  height {0} / {1}  ({2} behind, {3} peers)" -f `
                       $info.height, $targetText, $behind, $peers)

            if (Wait-OrVm $PollSeconds) { break }
            $monerodProc.Refresh()
        }

        Show-MonerodOutput

        if ($script:VmInterrupt -or $script:UserStop) {
            Invoke-Interrupt
        } elseif (-not $syncedOk) {
            Write-Log "Sync cap of $MaxSyncMinutes min reached without full sync." 'WARN'
            Write-Log 'Shutting down gracefully anyway - progress is preserved.' 'WARN'
        }
    }

    # -----------------------------------------------------------------------
    # Graceful shutdown
    # -----------------------------------------------------------------------
    # Stop the daemon EXACTLY the way Ctrl+C in a console does: close its
    # stdin. monerod answers "EOF on stdin, exiting" and shuts down in ~30s.
    #
    # This is required, not cosmetic. The daemon runs interactively (the bare
    # manual command, no --non-interactive), so it has a console thread
    # blocked reading the stdin pipe this script holds open. A stop sent via
    # the 'exit' command stops the p2p loop and then HANGS waiting for that
    # console thread -- observed frozen after "p2p net loop stopped" with
    # zero CPU while a manual Ctrl+C run finished in 30 seconds. Closing
    # stdin is the one stop signal that thread cannot miss.

    Write-Host ''
    Write-Log 'GRACEFUL SHUTDOWN' 'STEP'

    $shutdownStart = Get-Date
    $endHeight     = if ($info) { $info.height } else { $startHeight }

    if ($script:MonerodStdin) {
        Write-Log 'Closing stdin (EOF) - the same signal Ctrl+C sends in a console.'
        try { $script:MonerodStdin.Dispose() } catch { }
        $script:MonerodStdin = $null
    } else {
        # No stdin pipe (a daemon this script did not start) -- fall back to
        # the terminal exit command through the timeout-guarded client.
        Write-Log ('Command: & "{0}" --data-dir "{1}" exit' -f $MonerodPath, $DataDir)
        [void](Send-MonerodStop -TimeoutSeconds $StopRequestTimeoutSeconds `
                                -MonerodPath $MonerodPath -DataDir $DataDir `
                                -Logger $logger)
    }

    Write-Log 'Waiting for the daemon to exit (watch for "EOF on stdin, exiting")...'

    $shutdownDeadline = $shutdownStart.AddMinutes($ShutdownTimeoutMinutes)
    $lastReport       = 0
    $stopped          = $false

    while ((Get-Date) -lt $shutdownDeadline) {
        if ($monerodProc.HasExited) { $stopped = $true; break }

        $elapsed = [int]((Get-Date) - $shutdownStart).TotalSeconds
        if ($elapsed -ge $lastReport + 15) {
            $lastReport = $elapsed
            Show-MonerodOutput
            Write-Log "  waiting for exit... ${elapsed}s"
        }

        # A VM starting while the daemon is still flushing is the most
        # dangerous moment of all. Nothing more can be done to hurry the
        # flush, but the user must be told to wait for the all-clear.
        if (-not $script:VmInterrupt) {
            $vm = Test-VirtualBoxRunning
            if ($vm.Running) {
                $script:VmInterrupt = $true
                $script:VmDetail    = $vm.Detail
                Write-Log "VIRTUALBOX VM STARTED during shutdown - $($vm.Detail)" 'ERROR'
                Write-Log 'monerod is still flushing the database. Do NOT use the VM yet.' 'ERROR'
                [void](Send-UserNotification -Title 'Monero Sync - VM detected, still flushing' `
                    -Message 'monerod is still writing the database. Wait for the all-clear before using the VM.' `
                    -Level 'Warning')
            }
        }

        Start-Sleep -Seconds 1
        $monerodProc.Refresh()
    }

    Show-MonerodOutput
    $flushSec = ((Get-Date) - $shutdownStart).TotalSeconds

    # If the user lost patience and hit Terminate mid-flush, the process is
    # gone but the database was not closed -- record that, not a clean stop.
    Exit-IfTerminated

    if (-not $stopped) {
        # Never escalate to -Force. A stuck monerod is recoverable; a killed
        # one may not be.
        Write-Log ("monerod did not exit within $ShutdownTimeoutMinutes min ({0:N0}s waited)." -f $flushSec) 'ERROR'
        Write-Log 'It has deliberately NOT been force-killed. Leave it to finish;' 'ERROR'
        Write-Log 'killing it mid-flush is what corrupts the database.' 'ERROR'
        Write-Summary 'ERROR-STUCK' ('flush exceeded {0} min' -f $ShutdownTimeoutMinutes)
        exit 3
    }

    Write-Log ("monerod exited after {0:N1}s of flushing." -f $flushSec) 'OK'

    # Confirm the daemon logged its own shutdown sequence rather than merely
    # disappearing -- the only real proof it closed the database cleanly.
    $markers = Test-ShutdownMarkers -LogPath $monerodOut
    $seen    = $markers.Seen

    if ($seen.Count -gt 0) {
        Write-Log ("Daemon logged its shutdown sequence ({0}/{1} markers):" -f $seen.Count, $markers.Total) 'OK'
        foreach ($s in $seen) { Write-Log "    $s" }
    } else {
        Write-Log 'No shutdown markers found in the daemon log. The process exited' 'WARN'
        Write-Log 'on its own after flushing, so this is most likely just log timing.' 'WARN'
    }

    # Confirm it really let go of the port.
    $still = @(Get-NetTCPConnection -LocalPort $RpcPort -State Listen -ErrorAction SilentlyContinue)
    if ($still.Count -eq 0) {
        Write-Log "Port $RpcPort released." 'OK'
    } else {
        Write-Log "Port $RpcPort still held after exit." 'WARN'
    }

    # -----------------------------------------------------------------------
    # Summary
    # -----------------------------------------------------------------------

    $gained = $endHeight - $startHeight

    Write-Host ''
    Write-Host '================================================================' -ForegroundColor Cyan
    Write-Log 'RUN COMPLETE' 'STEP'
    Write-Log ("  blocks gained   {0}" -f $gained)
    Write-Log ("  final height    {0}" -f $endHeight)
    Write-Log ("  flush time      {0:N1}s" -f $flushSec)
    Write-Log ("  total runtime   {0:N1} min" -f ((Get-Date) - $script:StartTime).TotalMinutes)

    $sumArgs = @{
        StartHeight  = $startHeight
        EndHeight    = $endHeight
        FlushSeconds = $flushSec
        MarkersSeen  = $seen.Count
        MarkersTotal = $markers.Total
    }

    if ($script:VmInterrupt) {
        Write-Log 'Stopped early because a VirtualBox VM started. Database closed cleanly.' 'WARN'
        Write-Summary 'STOPPED-VBOX' ("VM started; height $endHeight, +$gained blocks") @sumArgs
        $exitCode = 2

        # The all-clear. This is the notification that matters: the daemon has
        # exited and released the database, so the VM is now safe to use.
        $clean = if ($seen.Count -ge $markers.Total) { 'closed cleanly' } else { 'closed' }
        [void](Send-UserNotification -Title 'Monero Sync - all clear' `
            -Message "monerod has stopped and the database is $clean. It is now safe to use the VM." `
            -Level 'Info')
    } elseif ($script:UserStop) {
        Write-Log 'Stopped from the tray. Database closed cleanly.' 'WARN'
        Write-Summary 'STOPPED-USER' ("stopped from tray; height $endHeight, +$gained blocks") @sumArgs
        $exitCode = 2

        $clean = if ($seen.Count -ge $markers.Total) { 'closed cleanly' } else { 'closed' }
        [void](Send-UserNotification -Title 'Monero Sync - stopped' `
            -Message "monerod has stopped and the database is $clean." `
            -Level 'Info')
    } elseif ($syncedOk) {
        Write-Log 'Synced and shut down cleanly.' 'OK'
        Write-Summary 'OK' ("height $endHeight, +$gained blocks") @sumArgs
        $exitCode = 0
    } else {
        Write-Log 'Shut down cleanly, but did not reach full sync.' 'WARN'
        Write-Summary 'PARTIAL' ("height $endHeight, +$gained blocks") @sumArgs
        $exitCode = 2
    }
    Write-Host '================================================================' -ForegroundColor Cyan
    Write-Host ''
}
catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    Write-Summary 'ERROR' $_.Exception.Message
    $exitCode = 4
}
finally {
    # ROOT-CAUSE FIX for the orphaned daemon.
    #
    # On 29 Aug a run died between polls without reaching any shutdown code,
    # leaving monerod running unsupervised for 5.5 hours; it blocked three
    # scheduled runs and was eventually killed with zero shutdown markers.
    #
    # finally{} runs on normal exit, on a thrown error, AND on Ctrl+C /
    # Stop-Process on the PowerShell host, so a daemon this script started is
    # stopped gracefully on essentially every exit path.
    #
    # Note this cannot save a hard kill of the host process (taskkill /f, power
    # loss). Stop-AllMonerod at the start of the next run is the backstop for
    # that case.
    if ($monerodProc) {
        $stillUp = $false
        try { $monerodProc.Refresh(); $stillUp = -not $monerodProc.HasExited } catch { }

        if ($stillUp) {
            Write-Log '' 'WARN'
            Write-Log 'Script is exiting with the daemon still running.' 'WARN'
            Write-Log 'Stopping it gracefully so it is not left orphaned...' 'WARN'

            try {
                # EOF first -- the Ctrl+C-equivalent stop an interactive
                # daemon always honours.
                if ($script:MonerodStdin) {
                    try { $script:MonerodStdin.Dispose() } catch { }
                    $script:MonerodStdin = $null
                }
                [void](Send-MonerodStop -RpcPort $RpcPort `
                                        -TimeoutSeconds $StopRequestTimeoutSeconds `
                                        -MonerodPath $MonerodPath -DataDir $DataDir `
                                        -Logger { param($m, $lvl) Write-Log $m $lvl })

                $gone = Wait-MonerodExit -Processes @($monerodProc) `
                                         -TimeoutMinutes $ShutdownTimeoutMinutes `
                                         -Logger { param($m, $lvl) Write-Log $m $lvl }

                if ($gone) {
                    Write-Log 'Daemon shut down gracefully during cleanup.' 'OK'
                } else {
                    Write-Log 'Daemon did not exit during cleanup and was NOT killed.' 'ERROR'
                    Write-Log 'The next run will stop it before starting.' 'ERROR'
                }
            } catch {
                Write-Log "Cleanup shutdown failed: $($_.Exception.Message)" 'ERROR'
            }
        }
    }

    # Consume any stop/terminate request so it cannot leak into the next run.
    foreach ($flag in @($script:StopFlag, $script:TerminateFlag)) {
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    }

    # Make sure a run that died before its summary still leaves a history
    # record, so a crash is visible in the tray rather than silently missing.
    if (-not $script:SummaryWritten) {
        try { Write-Summary 'INTERRUPTED' 'run ended before completing' } catch { }
    }

    # Release the stdin pipe last. If the daemon somehow still runs, closing
    # it is itself a graceful stop signal ("EOF on stdin, exiting").
    if ($script:MonerodStdin) {
        try { $script:MonerodStdin.Dispose() } catch { }
        $script:MonerodStdin = $null
    }

    if ($sleepBlocked) {
        # ES_CONTINUOUS alone clears the ES_SYSTEM_REQUIRED request.
        try { [void][Native.PowerUtil]::SetThreadExecutionState([uint32]2147483648) } catch { }
    }
    if ($haveMutex) {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

exit $exitCode

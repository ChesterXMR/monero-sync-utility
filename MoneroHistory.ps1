<#
    MoneroHistory.ps1

    Structured run history, shared by Sync-Monero.ps1 (which appends) and
    MoneroTray.ps1 (which displays).

    Stored as JSON Lines -- one self-contained JSON object per line -- so an
    append is a single atomic write and a partially written line can never
    corrupt earlier entries. The plain-text sync-history.log stays alongside it
    for reading by eye.

    Not meant to be run directly.
#>

function Get-HistoryPath {
    param([string] $Root)
    Join-Path $Root 'logs\history.jsonl'
}

function Add-HistoryEntry {
    param(
        [string] $Root,
        [string] $Status,
        [string] $Detail,
        [datetime] $StartedAt,
        [double] $Minutes,
        [int] $StartHeight = 0,
        [int] $EndHeight   = 0,
        [double] $FlushSeconds = 0,
        [int] $MarkersSeen = 0,
        [int] $MarkersTotal = 0
    )

    $entry = [ordered]@{
        StartedAt    = $StartedAt.ToString('o')
        FinishedAt   = (Get-Date).ToString('o')
        Status       = $Status
        Detail       = $Detail
        Minutes      = [math]::Round($Minutes, 1)
        StartHeight  = $StartHeight
        EndHeight    = $EndHeight
        Blocks       = [math]::Max(0, $EndHeight - $StartHeight)
        FlushSeconds = [math]::Round($FlushSeconds, 1)
        MarkersSeen  = $MarkersSeen
        MarkersTotal = $MarkersTotal
    }

    $path = Get-HistoryPath -Root $Root
    $dir  = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    # Compress to one line so each entry is exactly one JSON Lines record.
    $json = $entry | ConvertTo-Json -Compress

    # Retry briefly: the tray may be reading the file at the same moment.
    for ($i = 0; $i -lt 5; $i++) {
        try {
            Add-Content -LiteralPath $path -Value $json -Encoding utf8 -ErrorAction Stop
            break
        } catch {
            Start-Sleep -Milliseconds 150
        }
    }
}

function Get-HistoryEntries {
    param(
        [string] $Root,
        [int] $Last = 200
    )

    $path = Get-HistoryPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) { return @() }

    $lines = @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue |
               Where-Object { $_ -match '\S' })

    if ($lines.Count -gt $Last) { $lines = $lines[($lines.Count - $Last)..($lines.Count - 1)] }

    $out = @()
    foreach ($l in $lines) {
        # A malformed line (killed mid-write) must not break the whole view.
        try { $out += ($l | ConvertFrom-Json) } catch { }
    }

    # Newest first for display.
    [array]::Reverse($out)
    return $out
}

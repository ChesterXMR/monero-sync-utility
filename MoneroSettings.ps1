<#
    MoneroSettings.ps1

    User-adjustable settings, shared by Sync-Monero.ps1 (which reads them) and
    MoneroTray.ps1 (which writes them).

    Stored as JSON in .state\settings.json. Anything missing falls back to the
    default, so a hand-edited or partial file cannot break a run.

    Not meant to be run directly.
#>

$script:SettingsDefaults = @{
    # Wall-clock cap on the syncing phase. On reaching it the run shuts the
    # daemon down gracefully and records PARTIAL rather than OK; progress is
    # kept and the next run continues from there.
    MaxSyncMinutes = 120
}

function Get-SettingsPath {
    param([string] $Root)
    Join-Path $Root '.state\settings.json'
}

function Get-MoneroSettings {
    param([string] $Root)

    $s = @{}
    foreach ($k in $script:SettingsDefaults.Keys) { $s[$k] = $script:SettingsDefaults[$k] }

    $path = Get-SettingsPath -Root $Root
    if (Test-Path -LiteralPath $path) {
        try {
            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($k in @($s.Keys)) {
                if ($null -ne $json.$k) { $s[$k] = $json.$k }
            }
        } catch {
            # A corrupt file must not stop a sync -- fall back to defaults.
        }
    }

    [pscustomobject]$s
}

function Set-MoneroSetting {
    param(
        [string] $Root,
        [string] $Name,
        $Value
    )

    $path = Get-SettingsPath -Root $Root
    $dir  = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    $current = Get-MoneroSettings -Root $Root
    $out = @{}
    foreach ($p in $current.PSObject.Properties) { $out[$p.Name] = $p.Value }
    $out[$Name] = $Value

    try {
        ($out | ConvertTo-Json) | Set-Content -LiteralPath $path -Encoding utf8 -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

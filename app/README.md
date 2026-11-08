# Monero Sync (desktop app)

A single Windows exe for the Monero sync utility: a tray app with a window,
a folder picker, start at sign-in, and an on-the-hour scheduler. **The syncing
itself is done by the PowerShell scripts in the parent folder, unchanged.**
The exe carries them inside it.

## Using it

1. Run `monero-sync.exe`. On first launch the window opens on **Settings**.
2. **Blockchain folder**: pick the folder that contains `lmdb\data.mdb`
   (or the `lmdb` folder itself, or `data.mdb`; all three resolve to the
   same `-DataDir`).
3. **monerod.exe** is found automatically if the Monero GUI wallet is installed
   in the usual place, sits next to the exe, or is on `PATH`; otherwise browse
   to it.

From then on it syncs **every hour, on the hour** (13:00, 14:00, …).

- **Closing the window** hides it to the tray. Left-click the tray icon to
  bring it back; right-click for the menu. Only **Exit** quits.
- **Starts at sign-in** by default (an `HKCU\...\Run` entry, no admin
  needed). An automatic start goes straight to the tray. Turn it off in
  Settings.
- The tray icon is **orange** while automatic syncing is on or a sync is
  running, **grey** while paused.
- Exiting doesn't interrupt a sync in progress: the script is its own process
  and finishes cleanly by itself, as it did with the old tray.

## Timing

Runs start only on the clock grid, counted from midnight: hourly means
exactly :00. They don't depend on when the last sync ran or how long it took.
A slot is skipped (and noted in the live output) only when:

- a sync is still running at that moment,
- the PC is on battery (optional, on by default, like the old task), or
- the slot was missed by more than 2 minutes because the PC was asleep or the
  app wasn't running. It is **not** run late; the next run is the next :00.

The old scheduled task ran missed slots whenever the PC woke up, which is
where off-the-hour runs came from.

## How it uses the scripts

On launch the exe unpacks `Sync-Monero.ps1`, `MoneroChecks.ps1`,
`MoneroDaemon.ps1`, `MoneroHistory.ps1`, `MoneroSettings.ps1` and
`MoneroNotify.ps1` into its data folder,
`%APPDATA%\com.monerosync.utility\`. That folder then holds `logs\` and
`.state\` exactly as the repo folder did before.

| Action | What runs |
|---|---|
| Scheduled run / **Sync now** | `powershell.exe -File Sync-Monero.ps1 -DataDir … -MonerodPath … -MaxSyncMinutes …`, hidden |
| **Stop sync** | writes `.state\request-stop`, which the script polls every second; with no script running, `Send-MonerodStop` from `MoneroDaemon.ps1` |
| **☠ Terminate** | writes `.state\request-terminate`, then force-kills monerod (confirmed first) |
| **Run checks** | `Test-BlockchainMounted`, `Test-VirtualBoxRunning`, `Test-MonerodRunning` from `MoneroChecks.ps1` |
| History table / live output | reads `logs\history.jsonl` and `logs\sync.log` written by the script |

The window's every-2-seconds status line (is monerod up, is data.mdb there)
is a quick native probe, because starting PowerShell that often would be slow.
It is display-only; all decisions are made by the scripts.

To keep your old run history, copy the old `logs\history.jsonl` into
`%APPDATA%\com.monerosync.utility\logs\`.

Set `MONERO_SYNC_HOME` to use a different data folder (e.g. portable use).

## Building

Requires Rust and the Tauri CLI (`cargo install tauri-cli --version "^2"`).
No Node.js is needed; the UI is plain HTML/CSS/JS in `ui/`.

```powershell
cd app\src-tauri
cargo tauri dev                       # run it
cargo tauri build                     # release build
cargo test -- --include-ignored       # tests; the ignored one runs the real script
```

The scripts are embedded at build time from the parent folder, so rebuild
after editing them.

`cargo tauri build` produces:

- `src-tauri\target\release\monero-sync.exe`: the portable single exe. Copy it
  anywhere and run it. It needs Windows PowerShell 5.1 and the WebView2
  runtime, both built into Windows 10 and 11.
- `src-tauri\target\release\bundle\nsis\Monero Sync_1.0.0_x64-setup.exe`: an
  optional installer that also installs WebView2 if it's missing.

## Migrating from the scheduled task

Remove the old task and login shortcut so only the app schedules runs:

```powershell
..\Install-Task.ps1 -Remove
```

Then right-click the old tray icon → Exit. (If both are left running they
can't collide, because the script's single-instance mutex is shared, but the
old task would keep its off-the-hour behaviour.)

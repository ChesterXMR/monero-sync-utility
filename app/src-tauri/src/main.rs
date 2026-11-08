// No console window in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod daemon;
mod engine;
mod history;
mod settings;
mod tray;
mod winproc;

use std::path::Path;
use std::process::Command;
use std::sync::atomic::Ordering;
use std::sync::Arc;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, RunEvent, WindowEvent};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt as _};
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind, MessageDialogResult};
use tauri_plugin_notification::NotificationExt;

use engine::{result_label, Engine};
use history::Entry;
use settings::{format_minutes, Settings, INTERVAL_CHOICES, SYNC_CAP_CHOICES};
use tray::{show_main, Tray};

/// Passed by the login entry, so an automatic start stays in the tray.
const AUTOSTART_ARG: &str = "--autostart";

fn eng(app: &AppHandle) -> Arc<Engine> {
    app.state::<Arc<Engine>>().inner().clone()
}

fn refresh_tray(app: &AppHandle) {
    if let Some(t) = app.try_state::<Arc<Tray>>() {
        t.refresh(&eng(app));
    }
}

/// Native yes/no box; true only if `ok_label` was pressed.
fn confirm(app: &AppHandle, title: &str, message: &str, ok_label: &str, cancel_label: &str) -> bool {
    let mut d = app
        .dialog()
        .message(message)
        .title(title)
        .kind(MessageDialogKind::Warning)
        .buttons(MessageDialogButtons::OkCancelCustom(ok_label.into(), cancel_label.into()));
    if let Some(w) = app.get_webview_window("main") {
        if w.is_visible().unwrap_or(false) {
            d = d.parent(&w);
        }
    }
    match d.blocking_show_with_result() {
        MessageDialogResult::Ok | MessageDialogResult::Yes => true,
        MessageDialogResult::Custom(s) => s == ok_label,
        _ => false,
    }
}

fn apply_autostart(app: &AppHandle, s: &Settings) -> Result<(), String> {
    let al = app.autolaunch();
    if s.start_at_login {
        // Re-enabling rewrites the entry, so it follows the exe if moved.
        al.enable().map_err(|e| e.to_string())
    } else if al.is_enabled().unwrap_or(false) {
        al.disable().map_err(|e| e.to_string())
    } else {
        Ok(())
    }
}

fn open_path(p: &Path) {
    let _ = Command::new("explorer").arg(p).spawn();
}

// ---------------------------------------------------------------------------
// Tray menu
// ---------------------------------------------------------------------------

pub fn on_menu(app: &AppHandle, id: &str) {
    let e = eng(app);
    match id {
        "open" => show_main(app),
        "sync_now" => match e.start_run(true) {
            Ok(()) => e.notify("Monero Sync", "Sync started. You'll be notified when it finishes."),
            Err(msg) => e.notify("Monero Sync", &msg),
        },
        "toggle" => {
            let on = !e.settings().automatic;
            match e.update_settings(|s| s.automatic = on) {
                Ok(s) if on => e.notify("Monero Sync", &format!("Automatic syncing resumed (every {}).", format_minutes(s.interval_minutes))),
                Ok(_) => e.notify("Monero Sync", "Automatic syncing paused. A sync already running is not affected."),
                Err(msg) => e.notify("Monero Sync", &msg),
            }
        }
        "checks" => {
            show_main(app);
            let _ = app.emit("show-checks", ());
        }
        "logs" => open_path(&e.paths.logs),
        "exit" => request_quit(app),
        other => {
            if let Some(m) = other.strip_prefix("freq_").and_then(|m| m.parse::<u32>().ok()) {
                if e.update_settings(|s| s.interval_minutes = m).is_ok() {
                    e.notify("Monero Sync", &format!("Now syncing every {}.", format_minutes(m)));
                }
            }
        }
    }
    refresh_tray(app);
}

/// Exit. A sync in progress is its own PowerShell process and carries on to
/// a clean finish without the app, exactly as with the old tray.
fn request_quit(app: &AppHandle) {
    eng(app).quitting.store(true, Ordering::SeqCst);
    app.exit(0);
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StatusDto {
    automatic: bool,
    interval_minutes: u32,
    max_sync_minutes: u32,
    next_run: Option<String>,
    syncing: bool,
    engine_running: bool,
    legacy_running: bool,
    stop_requested: bool,
    monerod_running: bool,
    monerod_detail: String,
    run_started_at: Option<String>,
    last_run: Option<Entry>,
    data_dir: String,
    blockchain_ok: bool,
    blockchain_detail: String,
    monerod_path: String,
    monerod_configured: String,
    monerod_found: bool,
    start_at_login: bool,
    skip_on_battery: bool,
    manual_command: String,
    app_data_dir: String,
    interval_choices: Vec<u32>,
    cap_choices: Vec<u32>,
}

#[tauri::command]
async fn get_status(app: AppHandle) -> Result<StatusDto, String> {
    let e = eng(&app);
    let s = e.settings();
    let own = e.own_run();
    let engine_running = own.is_some();
    let mon = daemon::check_monerod(s.rpc_port);
    let mutex = e.supervisor_running();
    let chain = daemon::check_blockchain(&s.data_dir);
    let resolved = settings::resolve_monerod(&s.monerod_path);
    let exe = resolved.as_ref().map(|p| p.display().to_string()).unwrap_or_else(|| "monerod.exe".into());
    let dd = if s.data_dir.is_empty() { "<blockchain folder>".to_string() } else { s.data_dir.clone() };

    Ok(StatusDto {
        automatic: s.automatic,
        interval_minutes: s.interval_minutes,
        max_sync_minutes: s.max_sync_minutes,
        next_run: e.next_run().map(|t| t.to_rfc3339()),
        syncing: engine_running || mon.ok || mutex,
        engine_running,
        legacy_running: mutex && !engine_running,
        stop_requested: e.stop_requested(),
        monerod_running: mon.ok,
        monerod_detail: mon.detail,
        run_started_at: own.map(|r| r.started_at.to_rfc3339()),
        last_run: e.last_entry(),
        blockchain_ok: chain.ok,
        blockchain_detail: chain.detail,
        data_dir: s.data_dir.clone(),
        monerod_found: resolved.is_some(),
        monerod_path: resolved.map(|p| p.display().to_string()).unwrap_or_default(),
        monerod_configured: s.monerod_path.clone(),
        start_at_login: s.start_at_login,
        skip_on_battery: s.skip_on_battery,
        manual_command: format!("& \"{exe}\" --data-dir \"{dd}\""),
        app_data_dir: e.paths.root.display().to_string(),
        interval_choices: INTERVAL_CHOICES.to_vec(),
        cap_choices: SYNC_CAP_CHOICES.to_vec(),
    })
}

#[tauri::command]
async fn get_history(app: AppHandle) -> Result<Vec<Entry>, String> {
    Ok(history::read(&eng(&app).paths.history, 200))
}

#[derive(Serialize)]
struct LogChunk {
    pos: u64,
    text: String,
    reset: bool,
}

#[tauri::command]
async fn read_log(app: AppHandle, pos: Option<u64>) -> Result<LogChunk, String> {
    let (pos, text, reset) = engine::read_log_from(&eng(&app).paths.sync_log, pos);
    Ok(LogChunk { pos, text, reset })
}

#[tauri::command]
async fn sync_now(app: AppHandle) -> Result<(), String> {
    let r = eng(&app).start_run(true);
    refresh_tray(&app);
    r
}

#[tauri::command]
async fn stop_sync(app: AppHandle) -> Result<String, String> {
    eng(&app).request_stop()
}

#[tauri::command]
async fn terminate_sync(app: AppHandle) -> Result<String, String> {
    let procs = winproc::find(&["monerod"]);
    let Some(first) = procs.first() else {
        return Ok("Nothing to terminate - monerod is not running.".into());
    };
    let msg = format!(
        "This kills monerod instantly, WITHOUT flushing the database.\n\n\
         That is the exact thing that has corrupted the blockchain before. Only do this if the daemon \
         is genuinely stuck and a graceful stop has already failed.\n\nTerminate monerod (PID {}) now?",
        first.pid
    );
    if !confirm(&app, "Terminate monerod?", &msg, "Terminate", "Cancel") {
        return Ok(String::new());
    }
    Ok(eng(&app).terminate())
}

#[tauri::command]
async fn set_automatic(app: AppHandle, on: bool) -> Result<(), String> {
    eng(&app).update_settings(|s| s.automatic = on)?;
    refresh_tray(&app);
    Ok(())
}

#[tauri::command]
async fn set_interval(app: AppHandle, minutes: u32) -> Result<(), String> {
    eng(&app).update_settings(|s| s.interval_minutes = minutes)?;
    refresh_tray(&app);
    Ok(())
}

#[tauri::command]
async fn set_sync_cap(app: AppHandle, minutes: u32) -> Result<(), String> {
    eng(&app).update_settings(|s| s.max_sync_minutes = minutes).map(|_| ())
}

#[tauri::command]
async fn set_option(app: AppHandle, key: String, value: bool) -> Result<(), String> {
    let e = eng(&app);
    let s = e.update_settings(|s| match key.as_str() {
        "startAtLogin" => s.start_at_login = value,
        "skipOnBattery" => s.skip_on_battery = value,
        _ => {}
    })?;
    if key == "startAtLogin" {
        apply_autostart(&app, &s)?;
    }
    Ok(())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DataDirResult {
    data_dir: String,
    warning: Option<String>,
}

fn save_data_dir(app: &AppHandle, input: &str) -> Result<DataDirResult, String> {
    let e = eng(app);
    if e.is_running() {
        return Err("Stop the running sync before changing the blockchain folder.".into());
    }
    let (dir, warning) = settings::normalize_data_dir(input)?;
    let text = dir.display().to_string();
    e.update_settings(|s| s.data_dir = text.clone())?;
    Ok(DataDirResult { data_dir: text, warning })
}

#[tauri::command]
async fn set_data_dir(app: AppHandle, path: String) -> Result<DataDirResult, String> {
    save_data_dir(&app, &path)
}

#[tauri::command]
async fn pick_data_dir(app: AppHandle) -> Result<Option<DataDirResult>, String> {
    let mut d = app.dialog().file().set_title("Choose the Monero blockchain folder (or its lmdb folder)");
    let current = eng(&app).settings().data_dir;
    if !current.is_empty() && Path::new(&current).exists() {
        d = d.set_directory(&current);
    }
    match d.blocking_pick_folder() {
        None => Ok(None),
        Some(fp) => {
            let p = fp.into_path().map_err(|e| e.to_string())?;
            save_data_dir(&app, &p.display().to_string()).map(Some)
        }
    }
}

fn save_monerod(app: &AppHandle, input: &str) -> Result<String, String> {
    let input = input.trim().trim_matches('"').trim().to_string();
    if !input.is_empty() {
        let p = Path::new(&input);
        if !p.is_file() {
            return Err(format!("No file at {input}"));
        }
        if !p.file_name().map(|n| n.to_string_lossy().to_ascii_lowercase().starts_with("monerod")).unwrap_or(false) {
            return Err("That doesn't look like monerod.exe.".into());
        }
    }
    eng(app).update_settings(|s| s.monerod_path = input.clone())?;
    Ok(input)
}

#[tauri::command]
async fn set_monerod_path(app: AppHandle, path: String) -> Result<String, String> {
    save_monerod(&app, &path)
}

#[tauri::command]
async fn pick_monerod(app: AppHandle) -> Result<Option<String>, String> {
    let picked = app
        .dialog()
        .file()
        .set_title("Locate monerod.exe")
        .add_filter("monerod", &["exe"])
        .blocking_pick_file();
    match picked {
        None => Ok(None),
        Some(fp) => {
            let p = fp.into_path().map_err(|e| e.to_string())?;
            save_monerod(&app, &p.display().to_string()).map(Some)
        }
    }
}

/// Preflight through MoneroChecks.ps1, plus the few things only the app knows.
#[tauri::command]
async fn run_checks(app: AppHandle) -> Result<serde_json::Value, String> {
    let e = eng(&app);
    let s = e.settings();
    let mut v = e.run_checks()?;
    let bin = settings::resolve_monerod(&s.monerod_path);
    let ok = |k: &str| v.get(k).and_then(|x| x.as_bool()).unwrap_or(false);
    let clear = ok("blockchainOk") && !ok("vmRunning") && !ok("monerodRunning") && bin.is_some();
    let extra = serde_json::json!({
        "binaryOk": bin.is_some(),
        "binaryDetail": bin.map(|p| p.display().to_string()).unwrap_or_else(|| "not found".into()),
        "onBattery": winproc::on_battery(),
        "skipOnBattery": s.skip_on_battery,
        "clear": clear,
        "schedule": if s.automatic { format!("every {}, on the grid", format_minutes(s.interval_minutes)) } else { "paused".into() },
        "lastRun": e.last_entry().map(|l| format!("{} - {}", result_label(&l.status), l.finished_at)).unwrap_or_else(|| "no runs yet".into()),
    });
    if let (Some(obj), Some(more)) = (v.as_object_mut(), extra.as_object()) {
        obj.extend(more.clone());
    }
    Ok(v)
}

#[tauri::command]
async fn clear_output(app: AppHandle) -> Result<(), String> {
    eng(&app).clear_output();
    Ok(())
}

#[tauri::command]
async fn clear_history(app: AppHandle) -> Result<bool, String> {
    let ok = confirm(
        &app,
        "Clear history?",
        "Delete the entire run history?\n\nEvery row in the table and the history files are removed. \
         This cannot be undone. The blockchain itself is not touched.",
        "Delete history",
        "Cancel",
    );
    if ok {
        eng(&app).clear_history();
        refresh_tray(&app);
    }
    Ok(ok)
}

#[tauri::command]
async fn open_folder(app: AppHandle, which: String) -> Result<(), String> {
    let e = eng(&app);
    match which.as_str() {
        "logs" => open_path(&e.paths.logs),
        "data" => open_path(&e.paths.root),
        "logfile" => {
            if e.paths.sync_log.exists() {
                let _ = Command::new("notepad.exe").arg(&e.paths.sync_log).spawn();
            }
        }
        _ => {}
    }
    Ok(())
}

// ---------------------------------------------------------------------------

fn main() {
    tauri::Builder::default()
        // Must be first: a second launch just brings this window forward.
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| show_main(app)))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, Some(vec![AUTOSTART_ARG])))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .setup(|app| {
            // MONERO_SYNC_HOME overrides the data folder (portable use, testing).
            let root = match std::env::var_os("MONERO_SYNC_HOME") {
                Some(p) if !p.is_empty() => std::path::PathBuf::from(p),
                _ => app.path().app_data_dir()?,
            };
            let (engine, first_run) = Engine::new(root);

            let handle = app.handle().clone();
            engine.set_notifier(Box::new(move |title, body| {
                let _ = handle.notification().builder().title(title).body(body).show();
            }));
            app.manage(engine.clone());

            // Start-at-login is on by default; a first run registers it.
            if let Err(err) = apply_autostart(app.handle(), &engine.settings()) {
                engine.log("WARN", &format!("Could not update start-at-login: {err}"));
            }

            let tray = tray::build(app.handle(), &engine)?;
            tray.spawn_updater(engine.clone());
            app.manage(tray);

            engine.spawn_scheduler();

            let autostarted = std::env::args().any(|a| a == AUTOSTART_ARG);
            let configured = !engine.settings().data_dir.is_empty();
            if first_run || !configured || !autostarted {
                show_main(app.handle());
            }
            Ok(())
        })
        // Closing the window only hides it; the tray and schedule keep running.
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![
            get_status,
            get_history,
            read_log,
            sync_now,
            stop_sync,
            terminate_sync,
            set_automatic,
            set_interval,
            set_sync_cap,
            set_option,
            set_data_dir,
            pick_data_dir,
            set_monerod_path,
            pick_monerod,
            run_checks,
            clear_output,
            clear_history,
            open_folder,
        ])
        .build(tauri::generate_context!())
        .expect("failed to build Monero Sync")
        .run(|_app, event| {
            // Only an explicit Exit (which passes a code) ends the app.
            if let RunEvent::ExitRequested { api, code, .. } = event {
                if code.is_none() {
                    api.prevent_exit();
                }
            }
        });
}

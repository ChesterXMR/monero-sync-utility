//! Runs the PowerShell sync scripts and schedules them.
//!
//! The scripts are embedded in the exe byte-for-byte and unpacked into the
//! app's data folder, which becomes their $PSScriptRoot -- so logs\ and
//! .state\ live there, exactly as they did next to the scripts before. All
//! sync logic (preflight, graceful shutdown, VM watch, history) stays in
//! Sync-Monero.ps1; this module only launches it, signals it through the
//! request files it already watches, and keeps the clock.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use chrono::{DateTime, Local, TimeZone};

use crate::daemon;
use crate::history::{self, Entry};
use crate::settings::{self, Settings};
use crate::winproc::{self, CREATE_NO_WINDOW, NORMAL_PRIORITY_CLASS};

/// Held by Sync-Monero.ps1 for its whole run.
pub const SUPERVISOR_MUTEX: &str = "Global\\MoneroSyncUtility";

/// A slot missed by more than this (PC asleep, app not running) is skipped
/// rather than run late: runs only ever start on the clock grid.
const LATE_GRACE: Duration = Duration::from_secs(120);

const SCRIPTS: &[(&str, &[u8])] = &[
    ("Sync-Monero.ps1", include_bytes!("../../../Sync-Monero.ps1")),
    ("MoneroChecks.ps1", include_bytes!("../../../MoneroChecks.ps1")),
    ("MoneroDaemon.ps1", include_bytes!("../../../MoneroDaemon.ps1")),
    ("MoneroHistory.ps1", include_bytes!("../../../MoneroHistory.ps1")),
    ("MoneroSettings.ps1", include_bytes!("../../../MoneroSettings.ps1")),
    ("MoneroNotify.ps1", include_bytes!("../../../MoneroNotify.ps1")),
];

/// Used only when monerod.exe can't be found, so the script itself records
/// ERROR-NOBINARY in the history rather than the run silently not happening.
const DEFAULT_MONEROD: &str = r"C:\Program Files\Monero GUI Wallet\monerod.exe";

pub struct Paths {
    pub root: PathBuf,
    pub logs: PathBuf,
    pub settings: PathBuf,
    pub sync_log: PathBuf,
    pub history: PathBuf,
    pub summary_log: PathBuf,
    pub last_run: PathBuf,
    pub stop_flag: PathBuf,
    pub terminate_flag: PathBuf,
}

#[derive(Clone)]
pub struct RunInfo {
    pub started_at: DateTime<Local>,
}

type Notifier = Box<dyn Fn(&str, &str) + Send + Sync>;

pub struct Engine {
    pub paths: Paths,
    settings: RwLock<Settings>,
    run: Mutex<Option<RunInfo>>,
    next_run: Mutex<Option<(DateTime<Local>, u32)>>,
    last_entry: Mutex<(u64, Option<SystemTime>, Option<Entry>)>,
    notifier: OnceLock<Notifier>,
    pub quitting: AtomicBool,
}

/// Plain-language result for a status code (same wording as the old tray).
pub fn result_label(status: &str) -> String {
    let s = match status {
        "OK" => "Synced",
        "PARTIAL" => "Partial sync",
        "INTERRUPTED" => "Interrupted",
        "SKIP-NOTMOUNTED" => "Skipped - drive locked",
        "SKIP-VBOX" => "Skipped - VM running",
        "SKIP-RUNNING" => "Skipped - already running",
        "SKIP-OVERLAP" => "Skipped - run in progress",
        "STOPPED-VBOX" => "Stopped - VM started",
        "STOPPED-USER" => "Stopped by you",
        "TERMINATED" => "TERMINATED - not flushed",
        s if s.starts_with("ERROR-STUCK") => "Daemon would not stop",
        s if s.starts_with("ERROR") => "Error",
        s => s,
    };
    s.to_string()
}

/// First point on the interval grid (counted from local midnight) strictly
/// after `now`. Hourly therefore means 13:00, 14:00, 15:00 ... regardless of
/// when the previous run happened or how long it took.
pub fn next_boundary(now: DateTime<Local>, interval: u32) -> DateTime<Local> {
    let interval = interval.max(1) as i64;
    let midnight = now.date_naive().and_hms_opt(0, 0, 0).unwrap();
    let since = (now.naive_local() - midnight).num_minutes();
    let mut t = midnight + chrono::Duration::minutes((since / interval + 1) * interval);
    let tomorrow = midnight + chrono::Duration::days(1);
    if t > tomorrow {
        t = tomorrow;
    }
    Local
        .from_local_datetime(&t)
        .earliest()
        .unwrap_or(now + chrono::Duration::minutes(interval))
}

fn powershell_exe() -> PathBuf {
    let sys = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
    let p = Path::new(&sys).join(r"System32\WindowsPowerShell\v1.0\powershell.exe");
    if p.is_file() { p } else { PathBuf::from("powershell.exe") }
}

/// Single-quoted PowerShell string literal.
fn ps_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "''"))
}

fn base64(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for c in bytes.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if c.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

impl Engine {
    pub fn new(root: PathBuf) -> (Arc<Engine>, bool) {
        let logs = root.join("logs");
        let state = root.join(".state");
        let _ = fs::create_dir_all(&logs);
        let _ = fs::create_dir_all(&state);
        let paths = Paths {
            settings: root.join("settings.json"),
            sync_log: logs.join("sync.log"),
            history: logs.join("history.jsonl"),
            summary_log: logs.join("sync-history.log"),
            last_run: state.join("last-run.json"),
            stop_flag: state.join("request-stop"),
            terminate_flag: state.join("request-terminate"),
            logs,
            root,
        };
        let (settings, first_run) = Settings::load(&paths.settings);
        if first_run {
            let _ = settings.save(&paths.settings);
        }
        let eng = Arc::new(Engine {
            paths,
            settings: RwLock::new(settings),
            run: Mutex::new(None),
            next_run: Mutex::new(None),
            last_entry: Mutex::new((0, None, None)),
            notifier: OnceLock::new(),
            quitting: AtomicBool::new(false),
        });
        if let Err(e) = eng.install_scripts() {
            eng.log("ERROR", &format!("Could not unpack the sync scripts: {e}"));
        }
        (eng, first_run)
    }

    /// Writes the embedded scripts next to logs\ and .state\, replacing any
    /// copy that differs (so an updated exe brings updated scripts).
    pub fn install_scripts(&self) -> std::io::Result<()> {
        for (name, bytes) in SCRIPTS {
            let p = self.paths.root.join(name);
            if fs::read(&p).map(|cur| cur != *bytes).unwrap_or(true) {
                fs::write(&p, bytes)?;
            }
        }
        Ok(())
    }

    pub fn set_notifier(&self, f: Notifier) {
        let _ = self.notifier.set(f);
    }

    pub fn notify(&self, title: &str, body: &str) {
        if let Some(n) = self.notifier.get() {
            n(title, body);
        }
    }

    pub fn settings(&self) -> Settings {
        self.settings.read().unwrap().clone()
    }

    pub fn update_settings(&self, f: impl FnOnce(&mut Settings)) -> Result<Settings, String> {
        let mut s = self.settings.write().unwrap();
        let mut next = s.clone();
        f(&mut next);
        next.sanitize();
        next.save(&self.paths.settings).map_err(|e| format!("Could not save settings: {e}"))?;
        if next.interval_minutes != s.interval_minutes || next.automatic != s.automatic {
            *self.next_run.lock().unwrap() = None;
        }
        *s = next.clone();
        Ok(next)
    }

    fn monerod_arg(s: &Settings) -> String {
        match settings::resolve_monerod(&s.monerod_path) {
            Some(p) => p.display().to_string(),
            None if !s.monerod_path.trim().is_empty() => s.monerod_path.trim().trim_matches('"').to_string(),
            None => DEFAULT_MONEROD.to_string(),
        }
    }

    // --- state --------------------------------------------------------------

    /// The run this app launched, if it is still going.
    pub fn own_run(&self) -> Option<RunInfo> {
        self.run.lock().unwrap().clone()
    }

    pub fn is_running(&self) -> bool {
        self.own_run().is_some()
    }

    /// A Sync-Monero.ps1 run is in progress -- ours, or one started elsewhere.
    pub fn supervisor_running(&self) -> bool {
        winproc::mutex_held(SUPERVISOR_MUTEX)
    }

    pub fn syncing(&self) -> bool {
        self.is_running() || self.supervisor_running() || !winproc::find(&["monerod"]).is_empty()
    }

    pub fn stop_requested(&self) -> bool {
        self.paths.stop_flag.exists()
    }

    /// Most recent history entry, re-read only when the file changes.
    pub fn last_entry(&self) -> Option<Entry> {
        let meta = fs::metadata(&self.paths.history).ok();
        let key = (meta.as_ref().map(|m| m.len()).unwrap_or(0), meta.and_then(|m| m.modified().ok()));
        let mut cache = self.last_entry.lock().unwrap();
        if cache.0 != key.0 || cache.1 != key.1 {
            *cache = (key.0, key.1, history::read(&self.paths.history, 1).into_iter().next());
        }
        cache.2.clone()
    }

    /// A line in sync.log, in the script's own format.
    pub fn log(&self, level: &str, msg: &str) {
        let line = format!("{}  {:<5}  {}\r\n", Local::now().format("%Y-%m-%d %H:%M:%S"), level, msg);
        if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&self.paths.sync_log) {
            let _ = f.write_all(line.as_bytes());
        }
    }

    pub fn clear_output(&self) {
        let _ = OpenOptions::new().write(true).truncate(true).open(&self.paths.sync_log);
        let _ = fs::remove_file(self.paths.sync_log.with_extension("log.1"));
    }

    pub fn clear_history(&self) {
        let _ = fs::remove_file(&self.paths.history);
        let _ = fs::remove_file(&self.paths.summary_log);
        let _ = fs::remove_file(&self.paths.last_run);
        *self.last_entry.lock().unwrap() = (0, None, None);
    }

    // --- PowerShell -----------------------------------------------------------

    /// Runs a snippet with the scripts' folder as the working directory and
    /// returns stdout. The snippet is passed encoded, so no quoting issues.
    fn powershell(&self, script: &str, timeout: Duration) -> Result<String, String> {
        let utf16: Vec<u8> = script.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
        let mut child = Command::new(powershell_exe())
            .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand"])
            .arg(base64(&utf16))
            .current_dir(&self.paths.root)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .creation_flags(CREATE_NO_WINDOW)
            .spawn()
            .map_err(|e| format!("Could not start PowerShell: {e}"))?;

        let mut so = child.stdout.take().unwrap();
        let mut se = child.stderr.take().unwrap();
        let t_out = thread::spawn(move || {
            let mut s = String::new();
            let _ = so.read_to_string(&mut s);
            s
        });
        let t_err = thread::spawn(move || {
            let mut s = String::new();
            let _ = se.read_to_string(&mut s);
            s
        });

        let deadline = Instant::now() + timeout;
        loop {
            match child.try_wait() {
                Ok(Some(st)) => {
                    let out = t_out.join().unwrap_or_default();
                    let err = t_err.join().unwrap_or_default();
                    return if st.success() { Ok(out) } else { Err(format!("PowerShell failed: {}", err.trim())) };
                }
                Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(100)),
                _ => {
                    let _ = child.kill();
                    return Err("PowerShell did not answer in time.".into());
                }
            }
        }
    }

    /// Preflight via MoneroChecks.ps1 -- the same functions the sync uses.
    pub fn run_checks(&self) -> Result<serde_json::Value, String> {
        let s = self.settings();
        if s.data_dir.trim().is_empty() {
            return Err("Choose the blockchain folder first (Settings).".into());
        }
        let script = format!(
            "$ErrorActionPreference = 'Stop'\n\
             . (Join-Path {root} 'MoneroChecks.ps1')\n\
             $m = Test-BlockchainMounted -DataDir {dd}\n\
             $v = Test-VirtualBoxRunning\n\
             $d = Test-MonerodRunning -RpcPort {port}\n\
             [pscustomobject]@{{ blockchainOk = [bool]$m.Mounted; blockchainDetail = [string]$m.Detail; \
             vmRunning = [bool]$v.Running; vmDetail = [string]$v.Detail; \
             monerodRunning = [bool]$d.Running; monerodDetail = [string]$d.Detail }} | ConvertTo-Json -Compress",
            root = ps_quote(&self.paths.root.display().to_string()),
            dd = ps_quote(s.data_dir.trim()),
            port = s.rpc_port,
        );
        let out = self.powershell(&script, Duration::from_secs(30))?;
        serde_json::from_str(out.trim()).map_err(|e| format!("Unexpected checks output: {e}"))
    }

    // --- control ----------------------------------------------------------------

    pub fn start_run(self: &Arc<Self>, manual: bool) -> Result<(), String> {
        let s = self.settings();
        if s.data_dir.trim().is_empty() {
            return Err("Choose the blockchain folder first (Settings).".into());
        }
        if self.is_running() || self.supervisor_running() {
            return Err("A sync is already running.".into());
        }
        if manual {
            let mon = daemon::check_monerod(s.rpc_port);
            if mon.ok {
                return Err(format!("monerod is already running ({}). Stop it first.", mon.detail));
            }
        }
        let _ = self.install_scripts();

        let mut run = self.run.lock().unwrap();
        if run.is_some() {
            return Err("A sync is already running.".into());
        }
        let before = self.last_entry().map(|e| e.finished_at);

        // Exactly what Run-Sync.vbs ran, plus the settings as parameters.
        let child = Command::new(powershell_exe())
            .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"])
            .arg(self.paths.root.join("Sync-Monero.ps1"))
            .arg("-DataDir")
            .arg(s.data_dir.trim())
            .arg("-MonerodPath")
            .arg(Self::monerod_arg(&s))
            .arg("-MaxSyncMinutes")
            .arg(s.max_sync_minutes.to_string())
            .arg("-RpcPort")
            .arg(s.rpc_port.to_string())
            .current_dir(&self.paths.root)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW | NORMAL_PRIORITY_CLASS)
            .spawn()
            .map_err(|e| format!("Could not start PowerShell: {e}"))?;

        *run = Some(RunInfo { started_at: Local::now() });
        drop(run);

        let eng = Arc::clone(self);
        let mut child = child;
        thread::spawn(move || {
            let code = loop {
                match child.try_wait() {
                    Ok(Some(st)) => break st.code(),
                    Ok(None) => thread::sleep(Duration::from_secs(1)),
                    Err(_) => break None,
                }
            };
            *eng.run.lock().unwrap() = None;

            let last = eng.last_entry();
            let recorded = last.as_ref().map(|e| Some(&e.finished_at) != before.as_ref()).unwrap_or(false);
            if !recorded {
                let msg = format!("Sync-Monero.ps1 exited (code {}) without recording a result.", code.map(|c| c.to_string()).unwrap_or_else(|| "?".into()));
                eng.log("ERROR", &msg);
                if !eng.quitting.load(Ordering::SeqCst) {
                    eng.notify("Monero Sync", &msg);
                }
            } else if manual && !eng.quitting.load(Ordering::SeqCst) {
                if let Some(e) = last {
                    eng.notify("Monero Sync", &format!("Sync finished - {} ({})", result_label(&e.status), e.detail));
                }
            }
        });
        Ok(())
    }

    /// Graceful stop, as the old tray did it: ask the running script via its
    /// request file, or with no script running, send monerod the terminal
    /// `exit` command through MoneroDaemon.ps1.
    pub fn request_stop(self: &Arc<Self>) -> Result<String, String> {
        if self.supervisor_running() {
            fs::write(&self.paths.stop_flag, Local::now().to_rfc3339()).map_err(|e| format!("Could not request a stop: {e}"))?;
            return Ok("Stop requested. monerod is shutting down gracefully - you'll be notified when it has exited.".into());
        }
        let s = self.settings();
        if !daemon::check_monerod(s.rpc_port).ok {
            return Ok("Nothing is syncing.".into());
        }
        let script = format!(
            ". (Join-Path {root} 'MoneroDaemon.ps1')\n\
             [void](Send-MonerodStop -RpcPort {port} -TimeoutSeconds 60 -MonerodPath {m} -DataDir {dd})",
            root = ps_quote(&self.paths.root.display().to_string()),
            port = s.rpc_port,
            m = ps_quote(&Self::monerod_arg(&s)),
            dd = ps_quote(s.data_dir.trim()),
        );
        let eng = Arc::clone(self);
        thread::spawn(move || {
            if let Err(e) = eng.powershell(&script, Duration::from_secs(90)) {
                eng.log("WARN", &format!("Stop request: {e}"));
            }
        });
        Ok("Stop signal sent to monerod. It will exit once the database is flushed.".into())
    }

    /// Force-kill, flagged first so the script records TERMINATED rather than
    /// an unexplained crash. Only after the user has confirmed.
    pub fn terminate(&self) -> String {
        let procs = winproc::find(&["monerod"]);
        if procs.is_empty() {
            return "Nothing to terminate - monerod is not running.".into();
        }
        let _ = fs::write(&self.paths.terminate_flag, Local::now().to_rfc3339());
        for p in &procs {
            winproc::kill(p.pid);
        }
        "monerod terminated. The database was NOT flushed - watch the next run for problems.".into()
    }

    // --- scheduler ----------------------------------------------------------

    /// Next scheduled run, computing it if needed. None while paused.
    pub fn next_run(&self) -> Option<DateTime<Local>> {
        let s = self.settings();
        let mut nr = self.next_run.lock().unwrap();
        if !s.automatic {
            *nr = None;
            return None;
        }
        match *nr {
            Some((t, iv)) if iv == s.interval_minutes => Some(t),
            _ => {
                let t = next_boundary(Local::now(), s.interval_minutes);
                *nr = Some((t, s.interval_minutes));
                Some(t)
            }
        }
    }

    pub fn spawn_scheduler(self: &Arc<Self>) {
        let eng = Arc::clone(self);
        let _ = thread::Builder::new().name("scheduler".into()).spawn(move || loop {
            if eng.quitting.load(Ordering::SeqCst) {
                return;
            }
            let Some(due) = eng.next_run() else {
                thread::sleep(Duration::from_secs(5));
                continue;
            };
            let now = Local::now();
            if now < due {
                // Wake on the boundary itself, re-checking at least every 15 s
                // so clock changes and settings edits are picked up.
                let wait = (due - now).to_std().unwrap_or_default().min(Duration::from_secs(15));
                thread::sleep(wait.max(Duration::from_millis(200)));
                continue;
            }

            let s = eng.settings();
            let next = next_boundary(now, s.interval_minutes);
            *eng.next_run.lock().unwrap() = Some((next, s.interval_minutes));
            let slot = due.format("%H:%M");

            let late = (now - due).to_std().unwrap_or_default();
            if late > LATE_GRACE {
                eng.log("INFO", &format!("Missed the {slot} run (PC asleep or app not running); next run {}.", next.format("%H:%M")));
            } else if eng.is_running() || eng.supervisor_running() {
                eng.log("INFO", &format!("Skipped the {slot} run: a sync is still running."));
            } else if s.skip_on_battery && winproc::on_battery() {
                eng.log("INFO", &format!("Skipped the {slot} run: on battery."));
            } else if let Err(e) = eng.start_run(false) {
                eng.log("WARN", &format!("The {slot} run could not start: {e}"));
            }
        });
    }
}

/// New text from sync.log for the live output pane.
pub fn read_log_from(path: &Path, pos: Option<u64>) -> (u64, String, bool) {
    let Ok(mut f) = File::open(path) else { return (0, String::new(), pos.unwrap_or(0) > 0) };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    let mut reset = false;
    // First open shows only the tail, so the pane starts on the current run.
    let mut start = match pos {
        None => {
            reset = true;
            len.saturating_sub(20_000)
        }
        Some(p) if p > len => {
            reset = true;
            0
        }
        Some(p) => p,
    };
    if len - start > 2_000_000 {
        start = len - 20_000;
        reset = true;
    }
    if f.seek(SeekFrom::Start(start)).is_err() {
        return (start, String::new(), reset);
    }
    let mut buf = Vec::new();
    let _ = f.take(len - start).read_to_end(&mut buf);
    (start + buf.len() as u64, String::from_utf8_lossy(&buf).into_owned(), reset)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(h: u32, m: u32, s: u32) -> DateTime<Local> {
        Local.with_ymd_and_hms(2026, 11, 8, h, m, s).unwrap()
    }

    #[test]
    fn hourly_runs_land_on_the_hour() {
        assert_eq!(next_boundary(at(13, 0, 0), 60), at(14, 0, 0));
        assert_eq!(next_boundary(at(13, 0, 1), 60), at(14, 0, 0));
        assert_eq!(next_boundary(at(13, 37, 12), 60), at(14, 0, 0));
        assert_eq!(next_boundary(at(12, 59, 59), 60), at(13, 0, 0));
    }

    #[test]
    fn other_intervals_use_the_midnight_grid() {
        assert_eq!(next_boundary(at(13, 10, 0), 30), at(13, 30, 0));
        assert_eq!(next_boundary(at(13, 10, 0), 180), at(15, 0, 0));
        assert_eq!(next_boundary(at(23, 30, 0), 120), Local.with_ymd_and_hms(2026, 11, 9, 0, 0, 0).unwrap());
        assert_eq!(next_boundary(at(9, 0, 0), 1440), Local.with_ymd_and_hms(2026, 11, 9, 0, 0, 0).unwrap());
    }

    #[test]
    fn base64_matches_reference() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
    }

    /// Runs the real embedded Sync-Monero.ps1 against a folder with no
    /// blockchain: preflight refuses at step 1, so monerod is never touched.
    /// `cargo test -- --ignored`
    #[test]
    #[ignore]
    fn launches_the_script_and_reads_its_history() {
        let root = std::env::temp_dir().join(format!("monero-sync-test-{}", std::process::id()));
        let (eng, first) = Engine::new(root.clone());
        assert!(first);
        assert!(root.join("Sync-Monero.ps1").is_file());
        eng.update_settings(|s| s.data_dir = root.join("no chain here").display().to_string()).unwrap();

        // Scheduled path: the manual path refuses while any monerod runs. With
        // no blockchain the script exits at preflight, before Stop-AllMonerod.
        eng.start_run(false).unwrap();
        let t = Instant::now();
        while eng.is_running() && t.elapsed() < Duration::from_secs(90) {
            thread::sleep(Duration::from_millis(200));
        }
        assert!(!eng.is_running(), "script did not finish");
        let e = eng.last_entry().expect("script wrote a history row");
        assert_eq!(e.status, "SKIP-NOTMOUNTED");

        let checks = eng.run_checks().unwrap();
        assert_eq!(checks["blockchainOk"], false);
        assert!(checks["vmDetail"].is_string());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn ps_quote_escapes_single_quotes() {
        assert_eq!(ps_quote(r"E:\Bob's Chain"), r"'E:\Bob''s Chain'");
    }
}

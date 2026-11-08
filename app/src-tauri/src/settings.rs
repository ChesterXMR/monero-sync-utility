//! User settings, stored as JSON in the app data folder. Anything missing
//! falls back to its default, so a partial or hand-edited file cannot break
//! a run.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    /// Folder passed to `monerod --data-dir`; holds `lmdb\data.mdb`.
    /// Empty until the user picks one.
    pub data_dir: String,
    /// Empty = auto-detect.
    pub monerod_path: String,

    /// Automatic (scheduled) syncing armed.
    pub automatic: bool,
    pub interval_minutes: u32,
    /// Passed to Sync-Monero.ps1 as -MaxSyncMinutes.
    pub max_sync_minutes: u32,

    pub start_at_login: bool,
    /// Like the old task's "don't start on battery".
    pub skip_on_battery: bool,
    pub rpc_port: u16,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            data_dir: String::new(),
            monerod_path: String::new(),
            automatic: true,
            interval_minutes: 60,
            max_sync_minutes: 120,
            start_at_login: true,
            skip_on_battery: true,
            rpc_port: 18081,
        }
    }
}

pub const INTERVAL_CHOICES: &[u32] = &[30, 60, 120, 180, 240, 360, 480, 720, 1440];
pub const SYNC_CAP_CHOICES: &[u32] = &[30, 60, 120, 180, 240, 360, 720];

pub fn format_minutes(m: u32) -> String {
    match m {
        60 => "1 hour".into(),
        m if m >= 60 && m % 60 == 0 => format!("{} hours", m / 60),
        m => format!("{m} minutes"),
    }
}

impl Settings {
    /// Returns the settings and whether this is a first run (no file yet).
    pub fn load(path: &Path) -> (Settings, bool) {
        match fs::read_to_string(path) {
            Ok(text) => {
                let mut s: Settings =
                    serde_json::from_str(text.trim_start_matches('\u{feff}')).unwrap_or_default();
                s.sanitize();
                (s, false)
            }
            Err(_) => (Settings::default(), true),
        }
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        // Write-then-rename so a crash mid-save cannot leave a torn file.
        let tmp = path.with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_string_pretty(self).unwrap_or_default())?;
        fs::rename(&tmp, path)
    }

    pub fn sanitize(&mut self) {
        self.interval_minutes = self.interval_minutes.clamp(15, 1440);
        self.max_sync_minutes = self.max_sync_minutes.clamp(10, 24 * 60);
        if self.rpc_port == 0 {
            self.rpc_port = 18081;
        }
    }
}

fn name_is(p: &Path, want: &str) -> bool {
    p.file_name().map(|n| n.to_string_lossy().eq_ignore_ascii_case(want)).unwrap_or(false)
}

pub fn data_mdb(data_dir: &Path) -> PathBuf {
    data_dir.join("lmdb").join("data.mdb")
}

/// Turns whatever the user pointed at -- the data dir, the `lmdb` folder, or
/// `data.mdb` itself -- into the folder monerod wants as `--data-dir`.
///
/// Returns the folder plus an optional warning. A folder that does not
/// (yet) contain the database is accepted with a warning, because a
/// VeraCrypt volume may simply not be mounted right now; runs refuse to start
/// until data.mdb is really there.
pub fn normalize_data_dir(input: &str) -> Result<(PathBuf, Option<String>), String> {
    let raw = input.trim().trim_matches('"').trim();
    if raw.is_empty() {
        return Err("Choose the folder that holds the blockchain.".into());
    }
    let mut p = PathBuf::from(raw);
    if !p.is_absolute() {
        return Err("Use a full path, e.g. D:\\Monero or C:\\ProgramData\\bitmonero.".into());
    }

    if name_is(&p, "data.mdb") {
        p.pop();
    }

    if data_mdb(&p).is_file() {
        return Ok((p, None));
    }

    if p.join("data.mdb").is_file() {
        if name_is(&p, "lmdb") {
            let parent = p.parent().map(Path::to_path_buf).unwrap_or(p);
            return Ok((parent, None));
        }
        return Err(format!(
            "data.mdb is in \"{}\", but monerod expects it inside a folder named \"lmdb\". \
             Rename that folder to lmdb (or move it into one) and pick its parent.",
            p.display()
        ));
    }

    if name_is(&p, "lmdb") {
        if let Some(parent) = p.parent() {
            p = parent.to_path_buf();
        }
    }

    let warn = if p.exists() {
        "No lmdb\\data.mdb in this folder. Syncs will be skipped until it exists: monerod is never \
         started against an empty folder, because that would begin a fresh download."
    } else {
        "This folder can't be reached right now (drive not mounted?). Syncs will be skipped until \
         lmdb\\data.mdb is found there."
    };
    Ok((p, Some(warn.into())))
}

/// Finds monerod.exe: the configured path if valid, else the usual install
/// locations, next to this program, or on PATH.
pub fn resolve_monerod(configured: &str) -> Option<PathBuf> {
    let configured = configured.trim().trim_matches('"');
    if !configured.is_empty() {
        let p = PathBuf::from(configured);
        return if p.is_file() { Some(p) } else { None };
    }

    let mut candidates: Vec<PathBuf> = Vec::new();
    for var in ["ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"] {
        if let Ok(pf) = std::env::var(var) {
            candidates.push(Path::new(&pf).join("Monero GUI Wallet").join("monerod.exe"));
        }
    }
    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        candidates.push(Path::new(&local).join("Programs").join("Monero GUI Wallet").join("monerod.exe"));
    }
    if let Some(dir) = std::env::current_exe().ok().and_then(|e| e.parent().map(Path::to_path_buf)) {
        candidates.push(dir.join("monerod.exe"));
    }
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            candidates.push(dir.join("monerod.exe"));
        }
    }
    candidates.into_iter().find(|c| c.is_file())
}

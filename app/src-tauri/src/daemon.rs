//! Fast status probes for the window and tray, which poll every few seconds
//! (too often to start PowerShell each time). They mirror
//! Test-BlockchainMounted and Test-MonerodRunning in MoneroChecks.ps1 and are
//! display-only: every decision about running, stopping and preflight is made
//! by the PowerShell scripts.

use std::path::Path;

use crate::settings::data_mdb;
use crate::winproc;

pub struct Check {
    pub ok: bool,
    pub detail: String,
}

pub fn check_blockchain(data_dir: &str) -> Check {
    if data_dir.trim().is_empty() {
        return Check { ok: false, detail: "no blockchain folder chosen".into() };
    }
    let dir = Path::new(data_dir);
    if let Ok(meta) = std::fs::metadata(data_mdb(dir)) {
        if meta.is_file() {
            let gb = meta.len() as f64 / (1u64 << 30) as f64;
            return Check { ok: true, detail: format!("data.mdb present, {gb:.1} GB map") };
        }
    }
    let root_ok = dir.ancestors().last().map(|r| r.exists()).unwrap_or(false);
    let detail = if dir.exists() {
        "folder present but lmdb\\data.mdb MISSING".to_string()
    } else if root_ok {
        format!("'{}' MISSING", dir.display())
    } else {
        "drive not mounted".to_string()
    };
    Check { ok: false, detail }
}

/// `ok` = monerod is running (process present, or something on the RPC port).
pub fn check_monerod(rpc_port: u16) -> Check {
    let procs = winproc::find(&["monerod"]);
    let port = winproc::port_listening(rpc_port);
    let detail = match (procs.first(), port) {
        (Some(p), true) => format!("PID {}, listening on {rpc_port}", p.pid),
        (Some(p), false) => format!("PID {}, RPC port not yet open", p.pid),
        (None, true) => format!("port {rpc_port} in use"),
        (None, false) => format!("no process, port {rpc_port} free"),
    };
    Check { ok: !procs.is_empty() || port, detail }
}

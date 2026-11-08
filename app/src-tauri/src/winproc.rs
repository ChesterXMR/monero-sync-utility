//! Thin wrappers over the Win32 calls the app needs: process listing and
//! kill, the named mutex Sync-Monero.ps1 holds while it runs, and power
//! status.

use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, HANDLE, INVALID_HANDLE_VALUE, WAIT_OBJECT_0};
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
};
use windows_sys::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
use windows_sys::Win32::System::Threading::{
    CreateMutexW, OpenProcess, ReleaseMutex, TerminateProcess, WaitForSingleObject, PROCESS_TERMINATE,
};

/// `CREATE_NO_WINDOW`: a console child gets no visible console window.
pub const CREATE_NO_WINDOW: u32 = 0x0800_0000;
pub const NORMAL_PRIORITY_CLASS: u32 = 0x0000_0020;

const WAIT_ABANDONED: u32 = 0x80;
const ERROR_ACCESS_DENIED: u32 = 5;

#[derive(Clone, Debug)]
pub struct ProcInfo {
    pub pid: u32,
    pub name: String,
}

pub fn processes() -> Vec<ProcInfo> {
    let mut out = Vec::new();
    unsafe {
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snap.is_null() || snap == INVALID_HANDLE_VALUE {
            return out;
        }
        let mut e: PROCESSENTRY32W = std::mem::zeroed();
        e.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        if Process32FirstW(snap, &mut e) != 0 {
            loop {
                let len = e.szExeFile.iter().position(|&c| c == 0).unwrap_or(e.szExeFile.len());
                out.push(ProcInfo {
                    pid: e.th32ProcessID,
                    name: String::from_utf16_lossy(&e.szExeFile[..len]),
                });
                if Process32NextW(snap, &mut e) == 0 {
                    break;
                }
            }
        }
        CloseHandle(snap);
    }
    out
}

/// Processes whose image name matches any of `names` (case-insensitive,
/// with or without ".exe").
pub fn find(names: &[&str]) -> Vec<ProcInfo> {
    let wanted: Vec<String> = names.iter().map(|n| n.to_ascii_lowercase()).collect();
    processes()
        .into_iter()
        .filter(|p| {
            let n = p.name.to_ascii_lowercase();
            let n = n.strip_suffix(".exe").unwrap_or(&n);
            wanted.iter().any(|w| w == n)
        })
        .collect()
}

/// Force-kill. Used ONLY by the explicit, confirmed Terminate action.
pub fn kill(pid: u32) -> bool {
    unsafe {
        let h = OpenProcess(PROCESS_TERMINATE, 0, pid);
        if h.is_null() {
            return false;
        }
        let ok = TerminateProcess(h, 1) != 0;
        CloseHandle(h);
        ok
    }
}

/// True if another thread or process holds the named mutex right now.
/// Sync-Monero.ps1 holds `Global\MoneroSyncUtility` for its whole run, so
/// this is the reliable "is a sync in progress" signal.
pub fn mutex_held(name: &str) -> bool {
    let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        let h: HANDLE = CreateMutexW(std::ptr::null(), 0, wide.as_ptr());
        if h.is_null() {
            // Access denied means an elevated process owns it.
            return GetLastError() == ERROR_ACCESS_DENIED;
        }
        let r = WaitForSingleObject(h, 0);
        let got = r == WAIT_OBJECT_0 || r == WAIT_ABANDONED;
        if got {
            ReleaseMutex(h);
        }
        CloseHandle(h);
        !got
    }
}

pub fn on_battery() -> bool {
    unsafe {
        let mut s: SYSTEM_POWER_STATUS = std::mem::zeroed();
        GetSystemPowerStatus(&mut s) != 0 && s.ACLineStatus == 0
    }
}

/// Is anything accepting connections on the local RPC port?
pub fn port_listening(port: u16) -> bool {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    TcpStream::connect_timeout(&addr, Duration::from_millis(300)).is_ok()
}

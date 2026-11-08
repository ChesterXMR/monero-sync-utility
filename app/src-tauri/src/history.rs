//! Reads the run history Sync-Monero.ps1 writes (logs\history.jsonl, JSON
//! Lines via MoneroHistory.ps1). A torn line is skipped, never fatal.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "PascalCase")]
pub struct Entry {
    pub started_at: String,
    pub finished_at: String,
    pub status: String,
    pub detail: String,
    pub minutes: f64,
    pub start_height: i64,
    pub end_height: i64,
    pub blocks: i64,
    pub flush_seconds: f64,
    pub markers_seen: u32,
    pub markers_total: u32,
}

/// Newest first, at most `last` entries.
pub fn read(path: &Path, last: usize) -> Vec<Entry> {
    let Ok(bytes) = fs::read(path) else { return Vec::new() };
    let text = String::from_utf8_lossy(&bytes);
    let mut out: Vec<Entry> = text
        .lines()
        .map(|l| l.trim_start_matches('\u{feff}').trim())
        .filter(|l| !l.is_empty())
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect();
    if out.len() > last {
        out.drain(..out.len() - last);
    }
    out.reverse();
    out
}

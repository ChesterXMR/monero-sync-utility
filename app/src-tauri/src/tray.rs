//! Tray icon and menu. Left-click opens the window; right-click shows the
//! menu. The icon is colour while automatic syncing is armed or a sync is
//! running, grey while paused.

use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use tauri::image::Image;
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, Wry};

use crate::engine::{result_label, Engine};
use crate::settings::{format_minutes, INTERVAL_CHOICES};

pub struct Tray {
    icon: TrayIcon<Wry>,
    status: MenuItem<Wry>,
    sync_now: MenuItem<Wry>,
    toggle: MenuItem<Wry>,
    freq: Vec<(u32, CheckMenuItem<Wry>)>,
    color: Image<'static>,
    grey: Image<'static>,
    shown: Mutex<Option<(bool, String)>>,
    pub override_tip: Mutex<Option<String>>,
}

fn greyscale(img: &Image<'_>) -> Image<'static> {
    let mut px = img.rgba().to_vec();
    for p in px.chunks_exact_mut(4) {
        // Luminance, darkened slightly so "paused" reads as dimmed.
        let l = (0.30 * p[0] as f32 + 0.59 * p[1] as f32 + 0.11 * p[2] as f32) * 0.75;
        let l = l as u8;
        p[0] = l;
        p[1] = l;
        p[2] = l;
    }
    Image::new_owned(px, img.width(), img.height())
}

pub fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
    }
}

pub fn build(app: &AppHandle, eng: &Arc<Engine>) -> tauri::Result<Arc<Tray>> {
    let color = Image::from_bytes(include_bytes!("../icons/tray.png"))?.to_owned();
    let grey = greyscale(&color);

    let status = MenuItem::with_id(app, "status", "Monero Sync", false, None::<&str>)?;
    let open = MenuItem::with_id(app, "open", "Open Monero Sync", true, None::<&str>)?;
    let sync_now = MenuItem::with_id(app, "sync_now", "Sync now", true, None::<&str>)?;
    let toggle = MenuItem::with_id(app, "toggle", "Pause automatic syncing", true, None::<&str>)?;
    let checks = MenuItem::with_id(app, "checks", "Run checks now", true, None::<&str>)?;
    let logs = MenuItem::with_id(app, "logs", "Open logs folder", true, None::<&str>)?;
    let exit = MenuItem::with_id(app, "exit", "Exit", true, None::<&str>)?;

    let interval = eng.settings().interval_minutes;
    let mut freq = Vec::new();
    for &m in INTERVAL_CHOICES {
        let item = CheckMenuItem::with_id(app, format!("freq_{m}"), format_minutes(m), true, m == interval, None::<&str>)?;
        freq.push((m, item));
    }
    let freq_refs: Vec<&dyn tauri::menu::IsMenuItem<Wry>> = freq.iter().map(|(_, i)| i as &dyn tauri::menu::IsMenuItem<Wry>).collect();
    let freq_menu = Submenu::with_items(app, "Run every", true, &freq_refs)?;

    let sep = || PredefinedMenuItem::separator(app);
    let menu = Menu::with_items(
        app,
        &[&status, &sep()?, &open, &sync_now, &sep()?, &toggle, &freq_menu, &sep()?, &checks, &logs, &sep()?, &exit],
    )?;

    let icon = TrayIconBuilder::with_id("main")
        .icon(color.clone())
        .tooltip("Monero Sync")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                show_main(tray.app_handle());
            }
        })
        .on_menu_event(|app, event| crate::on_menu(app, event.id().as_ref()))
        .build(app)?;

    Ok(Arc::new(Tray {
        icon,
        status,
        sync_now,
        toggle,
        freq,
        color,
        grey,
        shown: Mutex::new(None),
        override_tip: Mutex::new(None),
    }))
}

impl Tray {
    pub fn refresh(&self, eng: &Engine) {
        let s = eng.settings();
        let syncing = eng.syncing();
        let colored = s.automatic || syncing;

        let activity = if syncing { "SYNCING NOW" } else { "idle" };
        let state = if s.automatic {
            format!("Automatic syncing ON, every {}", format_minutes(s.interval_minutes))
        } else {
            "Automatic syncing PAUSED".to_string()
        };
        let tip = self
            .override_tip
            .lock()
            .unwrap()
            .clone()
            .unwrap_or_else(|| format!("Monero Sync - {activity}\n{state}"));

        let mut shown = self.shown.lock().unwrap();
        if shown.as_ref() != Some(&(colored, tip.clone())) {
            let _ = self.icon.set_icon(Some(if colored { self.color.clone() } else { self.grey.clone() }));
            let _ = self.icon.set_tooltip(Some(&tip));
            *shown = Some((colored, tip));
        }
        drop(shown);

        let last = eng
            .last_entry()
            .map(|e| {
                let when = chrono::DateTime::parse_from_rfc3339(&e.finished_at)
                    .map(|d| d.with_timezone(&chrono::Local).format("%b %-d %H:%M").to_string())
                    .unwrap_or_default();
                format!("{} at {when}", result_label(&e.status))
            })
            .unwrap_or_else(|| "no runs yet".into());
        let _ = self.status.set_text(format!("{activity}  |  last: {last}"));
        let _ = self.sync_now.set_enabled(!syncing);
        let _ = self.toggle.set_text(if s.automatic { "Pause automatic syncing" } else { "Resume automatic syncing" });
        for (m, item) in &self.freq {
            let _ = item.set_checked(*m == s.interval_minutes);
        }
    }

    /// Keeps the icon current for runs started by the scheduler or by hand.
    pub fn spawn_updater(self: &Arc<Self>, eng: Arc<Engine>) {
        let tray = Arc::clone(self);
        let _ = thread::Builder::new().name("tray".into()).spawn(move || loop {
            tray.refresh(&eng);
            thread::sleep(Duration::from_secs(4));
        });
    }
}

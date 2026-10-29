//! TorVPN system-tray app.
//!
//! - Runs as the logged-in user (NOT elevated). Launched via the user's
//!   Run key after install, or manually.
//! - Talks to the elevated `torvpn-svc` service over `127.0.0.1:<port>`
//!   using the bearer token at `%PROGRAMDATA%\torvpn\api_token`.
//! - Left-click  → toggle engagement (the headline UX).
//! - Right-click → menu (Status, NEWNYM, Exit country, Quit).
//!
//! Architecture: tao event loop on the main thread (required for COM
//! pumping that tray-icon needs on Windows). Background thread runs a
//! tokio runtime polling /status every 1.5s and posting `UserEvent`s
//! into the loop. Click/menu events are also marshalled through user
//! events so we have one code path for state updates.

#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;

use tao::event::Event;
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tray_icon::menu::{Menu, MenuEvent, MenuId, MenuItem, PredefinedMenuItem, Submenu};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder, TrayIconEvent};

use torvpn_core::api::{Client, StatusResp};
use torvpn_core::config;
use torvpn_core::paths;
use torvpn_core::state::Phase;

#[derive(Debug)]
enum UserEvent {
    Tick(Result<StatusResp, String>),
    ActionDone(Result<(), String>),
    LeftClick,
    Menu(MenuId),
}

fn main() -> anyhow::Result<()> {
    init_logging();
    log::info!("torvpn-tray {} starting", env!("CARGO_PKG_VERSION"));

    let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();

    // --- Build menu ---
    let menu = Menu::new();
    let mi_status = MenuItem::new("Status / details...", true, None);
    let mi_svc_log = MenuItem::new("Open service log", true, None);
    let mi_tray_log = MenuItem::new("Open tray log", true, None);
    let mi_profile = MenuItem::new("Edit profile (admin required to save)", true, None);
    let mi_toggle = MenuItem::new("Connect", true, None);
    let mi_newnym = MenuItem::new("New circuits (NEWNYM)", true, None);

    // Exit-country submenu
    let exits_menu = Submenu::new("Exit country", true);
    let mi_exit_auto = MenuItem::new("Auto (clear)", true, None);
    let mi_exit_us = MenuItem::new("US", true, None);
    let mi_exit_gb = MenuItem::new("GB", true, None);
    let mi_exit_de = MenuItem::new("DE", true, None);
    let mi_exit_nl = MenuItem::new("NL", true, None);
    let mi_exit_ch = MenuItem::new("CH", true, None);
    let mi_exit_se = MenuItem::new("SE", true, None);
    let mi_exit_jp = MenuItem::new("JP", true, None);
    exits_menu.append(&mi_exit_auto)?;
    exits_menu.append(&PredefinedMenuItem::separator())?;
    exits_menu.append(&mi_exit_us)?;
    exits_menu.append(&mi_exit_gb)?;
    exits_menu.append(&mi_exit_de)?;
    exits_menu.append(&mi_exit_nl)?;
    exits_menu.append(&mi_exit_ch)?;
    exits_menu.append(&mi_exit_se)?;
    exits_menu.append(&mi_exit_jp)?;

    let mi_quit = MenuItem::new("Quit tray (tunnel stays connected)", true, None);

    menu.append(&mi_status)?;
    menu.append(&PredefinedMenuItem::separator())?;
    menu.append(&mi_toggle)?;
    menu.append(&mi_newnym)?;
    menu.append(&exits_menu)?;
    menu.append(&PredefinedMenuItem::separator())?;
    menu.append(&mi_svc_log)?;
    menu.append(&mi_tray_log)?;
    menu.append(&mi_profile)?;
    menu.append(&mi_quit)?;

    // Stash menu IDs for the event loop dispatch.
    let ids = MenuIds {
        toggle: mi_toggle.id().clone(),
        newnym: mi_newnym.id().clone(),
        quit: mi_quit.id().clone(),
        exit_auto: mi_exit_auto.id().clone(),
        exit_us: mi_exit_us.id().clone(),
        exit_gb: mi_exit_gb.id().clone(),
        exit_de: mi_exit_de.id().clone(),
        exit_nl: mi_exit_nl.id().clone(),
        exit_ch: mi_exit_ch.id().clone(),
        exit_se: mi_exit_se.id().clone(),
        exit_jp: mi_exit_jp.id().clone(),
    };

    // --- Build tray icon (starts as disconnected/red) ---
    let icon_disengaged = make_solid_icon(0xB0, 0x30, 0x30); // dim red
    let icon_engaging = make_solid_icon(0xC8, 0xA0, 0x10); // amber
    let icon_engaged = make_solid_icon(0x30, 0xA0, 0x40); // green
    let icon_error = make_solid_icon(0xFF, 0x00, 0x00); // bright red

    let tray: Rc<RefCell<Option<TrayIcon>>> = Rc::new(RefCell::new(None));
    {
        let tray_built = TrayIconBuilder::new()
            .with_tooltip("TorVPN — contacting service")
            .with_menu_on_left_click(false)
            .with_menu(Box::new(menu))
            .with_icon(icon_disengaged.clone())
            .build()?;
        *tray.borrow_mut() = Some(tray_built);
    }

    // --- Marshal tray + menu events into our UserEvents ---
    {
        let proxy = proxy.clone();
        TrayIconEvent::set_event_handler(Some(move |evt: TrayIconEvent| {
            // Only react to the primary click release; ignore drags etc.
            if let TrayIconEvent::Click {
                button,
                button_state,
                ..
            } = evt
            {
                if button == tray_icon::MouseButton::Left
                    && button_state == tray_icon::MouseButtonState::Up
                {
                    let _ = proxy.send_event(UserEvent::LeftClick);
                }
            }
        }));
    }
    {
        let proxy = proxy.clone();
        MenuEvent::set_event_handler(Some(move |evt: MenuEvent| {
            let _ = proxy.send_event(UserEvent::Menu(evt.id));
        }));
    }

    // --- Background polling thread ---
    {
        let proxy = proxy.clone();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("tokio runtime");
            rt.block_on(async move {
                loop {
                    let snapshot = poll_status().await.map_err(|e| format!("{e:#}"));
                    let _ = proxy.send_event(UserEvent::Tick(snapshot));
                    tokio::time::sleep(Duration::from_millis(1500)).await;
                }
            });
        });
    }

    // --- Event loop ---
    let icons = Icons {
        disengaged: icon_disengaged,
        engaging: icon_engaging,
        engaged: icon_engaged,
        error: icon_error,
    };
    let tray_for_loop = tray.clone();
    let mut last_phase: Option<Phase> = None;
    let mut details = String::from("Contacting TorVPN service...");
    let mut first_tick = true;

    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;
        match event {
            Event::UserEvent(UserEvent::Tick(snap)) => {
                match snap {
                    Ok(s) => {
                        details = format!("TorVPN {}\n\nState: {:?}\nMode: {}\n{}\n\nExit IP (last connection check): {}\n\nLeft-click the tray dot to connect/disconnect.\nRight-click for exit-country choices and logs.\nExit choice applies to new streams; existing streams keep their circuits.\nEntry guards are managed by Tor.\n\nService log: {}\nTray log: {}", env!("CARGO_PKG_VERSION"), s.phase,
                            if s.full_tunnel { "Windows TCP tunnel" } else { "SOCKS proxy only; Windows traffic is not redirected" }, s.message,
                            s.exit_ip.as_deref().unwrap_or("not verified"), paths::state_dir().join("svc.log").display(), tray_log_dir().join("tray.log").display());
                        apply_status(&tray_for_loop, &icons, &mi_status, &mi_toggle, &s, &mut last_phase);
                        mi_newnym.set_enabled(s.phase == Phase::Engaged);
                        exits_menu.set_enabled(!matches!(s.phase, Phase::Engaging | Phase::Disengaging));
                    }
                    Err(e) => {
                        details = format!("Cannot contact TorVPN service:\n\n{e}\n\nRun Repair.ps1 as Administrator, then relaunch the tray.\nService log: {}", paths::state_dir().join("svc.log").display());
                        log::warn!("status: {e}");
                        mi_newnym.set_enabled(false);
                        apply_offline(&tray_for_loop, &icons, &mi_status, &mi_toggle, &mut last_phase);
                    }
                }
                if first_tick {
                    first_tick = false;
                    show_details(&details);
                }
            }
            Event::UserEvent(UserEvent::ActionDone(Err(e))) => {
                show_details(&format!("TorVPN action failed:\n\n{e}\n\nOpen the service log from the tray menu for details."));
            }
            Event::UserEvent(UserEvent::LeftClick) => {
                spawn_action(if last_phase == Some(Phase::Engaging) { Action::Disconnect } else { Action::Toggle }, proxy.clone());
            }
            Event::UserEvent(UserEvent::Menu(id)) => {
                if id == *mi_status.id() { show_details(&details); }
                else if id == *mi_svc_log.id() { open_text(paths::state_dir().join("svc.log")); }
                else if id == *mi_tray_log.id() { open_text(tray_log_dir().join("tray.log")); }
                else if id == *mi_profile.id() { open_text(paths::config_path()); }
                else if id == ids.toggle  { spawn_action(if last_phase == Some(Phase::Engaging) { Action::Disconnect } else { Action::Toggle }, proxy.clone()); }
                else if id == ids.newnym { spawn_action(Action::Newnym, proxy.clone()); }
                else if id == ids.quit   { *control_flow = ControlFlow::Exit; }
                else if id == ids.exit_auto { spawn_action(Action::ExitSet(String::new()), proxy.clone()); }
                else if id == ids.exit_us   { spawn_action(Action::ExitSet("us".into()), proxy.clone()); }
                else if id == ids.exit_gb   { spawn_action(Action::ExitSet("gb".into()), proxy.clone()); }
                else if id == ids.exit_de   { spawn_action(Action::ExitSet("de".into()), proxy.clone()); }
                else if id == ids.exit_nl   { spawn_action(Action::ExitSet("nl".into()), proxy.clone()); }
                else if id == ids.exit_ch   { spawn_action(Action::ExitSet("ch".into()), proxy.clone()); }
                else if id == ids.exit_se   { spawn_action(Action::ExitSet("se".into()), proxy.clone()); }
                else if id == ids.exit_jp   { spawn_action(Action::ExitSet("jp".into()), proxy.clone()); }
            }
            _ => {}
        }
    });
}

#[derive(Clone)]
struct Icons {
    disengaged: Icon,
    engaging: Icon,
    engaged: Icon,
    error: Icon,
}

struct MenuIds {
    toggle: MenuId,
    newnym: MenuId,
    quit: MenuId,
    exit_auto: MenuId,
    exit_us: MenuId,
    exit_gb: MenuId,
    exit_de: MenuId,
    exit_nl: MenuId,
    exit_ch: MenuId,
    exit_se: MenuId,
    exit_jp: MenuId,
}

fn apply_status(
    tray: &Rc<RefCell<Option<TrayIcon>>>,
    icons: &Icons,
    mi_status: &MenuItem,
    mi_toggle: &MenuItem,
    s: &StatusResp,
    last_phase: &mut Option<Phase>,
) {
    let (icon, tip, status_label, toggle_label) = match s.phase {
        Phase::Engaged => (
            if s.full_tunnel {
                &icons.engaged
            } else {
                &icons.engaging
            },
            format!(
                "TorVPN — engaged ({})",
                s.exit_ip.clone().unwrap_or_else(|| "?".into())
            ),
            format!("Status: Engaged  {}", s.exit_ip.clone().unwrap_or_default()),
            "Disconnect".to_string(),
        ),
        Phase::Engaging | Phase::Disengaging => (
            &icons.engaging,
            format!("TorVPN — {}", s.message),
            format!("Status: {} ({})", phase_word(s.phase), s.message),
            if s.phase == Phase::Engaging {
                "Cancel connection".to_string()
            } else {
                "Disconnecting…".to_string()
            },
        ),
        Phase::Disengaged => (
            &icons.disengaged,
            "TorVPN — disengaged".to_string(),
            "Status: Disengaged".to_string(),
            "Connect".to_string(),
        ),
        Phase::Error => (
            &icons.error,
            format!("TorVPN — error: {}", s.message),
            format!("Status: Error ({})", s.message),
            "Retry connect".to_string(),
        ),
    };
    if let Some(t) = tray.borrow().as_ref() {
        let _ = t.set_icon(Some(icon.clone()));
        let _ = t.set_tooltip(Some(&tip));
    }
    mi_status.set_text(&status_label);
    mi_toggle.set_text(&toggle_label);
    *last_phase = Some(s.phase);
}

fn apply_offline(
    tray: &Rc<RefCell<Option<TrayIcon>>>,
    icons: &Icons,
    mi_status: &MenuItem,
    mi_toggle: &MenuItem,
    last_phase: &mut Option<Phase>,
) {
    if let Some(t) = tray.borrow().as_ref() {
        let _ = t.set_icon(Some(icons.error.clone()));
        let _ = t.set_tooltip(Some("TorVPN — service unreachable"));
    }
    mi_status.set_text("Status: service unreachable");
    mi_toggle.set_text("Connect");
    *last_phase = None;
}

fn phase_word(p: Phase) -> &'static str {
    match p {
        Phase::Disengaged => "Disengaged",
        Phase::Engaging => "Engaging",
        Phase::Engaged => "Engaged",
        Phase::Disengaging => "Disengaging",
        Phase::Error => "Error",
    }
}

// ------------- Action plumbing -------------

#[derive(Debug)]
enum Action {
    Toggle,
    Disconnect,
    Newnym,
    ExitSet(String),
}

fn spawn_action(a: Action, proxy: tao::event_loop::EventLoopProxy<UserEvent>) {
    // Ignore double-click reentry while the previous operation is pending.
    static BUSY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    let owns_busy = !matches!(a, Action::Disconnect);
    if owns_busy && BUSY.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(move || {
        let result = (|| -> anyhow::Result<()> {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()?;
            rt.block_on(async move {
                let client = load_client().await?;
                match a {
                    Action::Toggle => client.toggle().await.map(|_| ()),
                    Action::Disconnect => client.disconnect().await,
                    Action::Newnym => client.newnym().await,
                    Action::ExitSet(cc) if cc.is_empty() => client.exit_clear().await,
                    Action::ExitSet(cc) => client.exit_set(&cc).await,
                }
            })
        })()
        .map_err(|e| format!("{e:#}"));
        if let Err(e) = &result {
            log::error!("action: {e}");
        }
        if owns_busy {
            BUSY.store(false, std::sync::atomic::Ordering::SeqCst);
        }
        let _ = proxy.send_event(UserEvent::ActionDone(result));
    });
}

fn open_text(path: PathBuf) {
    if let Err(e) = std::process::Command::new("notepad.exe").arg(path).spawn() {
        show_details(&format!("Could not open text file: {e}"));
    }
}
fn show_details(message: &str) {
    let message = message.to_string();
    std::thread::spawn(move || {
        #[cfg(windows)]
        {
            let text: Vec<u16> = message.encode_utf16().chain(Some(0)).collect();
            let title: Vec<u16> = "TorVPN — status".encode_utf16().chain(Some(0)).collect();
            unsafe {
                windows_sys::Win32::UI::WindowsAndMessaging::MessageBoxW(
                    std::ptr::null_mut(),
                    text.as_ptr(),
                    title.as_ptr(),
                    windows_sys::Win32::UI::WindowsAndMessaging::MB_OK
                        | windows_sys::Win32::UI::WindowsAndMessaging::MB_ICONINFORMATION,
                );
            }
        }
        #[cfg(not(windows))]
        log::info!("{message}");
    });
}

async fn poll_status() -> anyhow::Result<StatusResp> {
    let client = load_client().await?;
    client.status().await
}

async fn load_client() -> anyhow::Result<Client> {
    let cfg = config::load_or_default(profile_or_none().as_deref()).await?;
    Client::from_token_file(cfg.status.listen, &paths::api_token_path()).await
}

fn profile_or_none() -> Option<PathBuf> {
    let p = paths::config_path();
    if p.exists() {
        Some(p)
    } else {
        None
    }
}

/// Per-user log directory for the tray: `%LOCALAPPDATA%\torvpn`.
///
/// NOT `%ProgramData%\torvpn` — the installer grants Users only read/execute
/// there (it's where the LocalSystem service writes the token for us to read),
/// so a user-mode write would be denied. LOCALAPPDATA is the tray's own,
/// always-writable home.
fn tray_log_dir() -> PathBuf {
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("torvpn")
}

/// Send logs to a file the user can actually read.
///
/// This binary is compiled with the Windows GUI subsystem (no console), so
/// every `log::warn!`/`log::error!` — "service unreachable", "toggle failed",
/// "client: reading token …" — otherwise goes to a stderr that doesn't exist.
/// That silent-swallowing is a big part of why a misconfigured service felt
/// like the tray "did nothing". Now those lines land in
/// `%LOCALAPPDATA%\torvpn\tray.log`. Falls back to stderr if the file can't
/// be opened.
fn init_logging() {
    let mut builder =
        env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"));
    let dir = tray_log_dir();
    let _ = std::fs::create_dir_all(&dir);
    if let Ok(file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("tray.log"))
    {
        builder.target(env_logger::Target::Pipe(Box::new(file)));
    }
    builder.init();
}

/// 32x32 solid-colour RGBA icon with a soft circular highlight, so it
/// reads as a status dot in the tray.
fn make_solid_icon(r: u8, g: u8, b: u8) -> Icon {
    const SIZE: u32 = 32;
    let mut rgba = Vec::with_capacity((SIZE * SIZE * 4) as usize);
    let cx = SIZE as f32 / 2.0 - 0.5;
    let cy = cx;
    let radius = SIZE as f32 * 0.46;
    let radius_sq = radius * radius;
    for y in 0..SIZE {
        for x in 0..SIZE {
            let dx = x as f32 - cx;
            let dy = y as f32 - cy;
            let d2 = dx * dx + dy * dy;
            if d2 <= radius_sq {
                // Subtle radial highlight: brighten toward the top-left.
                let highlight = (1.0 - (d2 / radius_sq)).powi(2) * 0.35;
                let hr = (r as f32 + (255.0 - r as f32) * highlight).min(255.0) as u8;
                let hg = (g as f32 + (255.0 - g as f32) * highlight).min(255.0) as u8;
                let hb = (b as f32 + (255.0 - b as f32) * highlight).min(255.0) as u8;
                rgba.extend_from_slice(&[hr, hg, hb, 0xFF]);
            } else {
                rgba.extend_from_slice(&[0, 0, 0, 0]);
            }
        }
    }
    Icon::from_rgba(rgba, SIZE, SIZE).expect("icon")
}

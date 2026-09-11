//! torvpn-core: shared library for the TorVPN service, CLI, and tray.
//!
//! Splits cleanly into:
//!   - `config`         — TOML profile loader & types
//!   - `tor_manager`    — spawns and supervises `tor.exe` (speed-tuned torrc)
//!   - `tun2socks_mgr`  — spawns `tun2socks.exe` with Wintun
//!   - `firewall`       — applies/teardown of Windows Firewall kill-switch
//!   - `nrpt`           — DNS lock via NRPT
//!   - `tor_control`    — Tor ControlPort client (NEWNYM, GETINFO, SETCONF)
//!   - `proxy_manager`  — upstream-proxy rotation persistence
//!   - `hop_plan`       — country/proxy rotation scheduler
//!   - `state`          — engagement state machine (Disengaged ↔ Engaging ↔ Engaged ↔ Disengaging)
//!   - `control_server` — local HTTP API the tray talks to
//!   - `auth`           — bearer-token + optional HMAC for the control server
//!   - `paths`          — canonical install/state paths (ProgramData-rooted, service-friendly)
//!   - `api`            — typed HTTP client used by tray and CLI

pub mod api;
pub mod auth;
pub mod config;
pub mod control_server;
pub mod firewall;
pub mod hop_plan;
pub mod nrpt;
pub mod paths;
pub mod proxy_manager;
pub mod state;
pub mod tor_control;
pub mod tor_manager;
pub mod tun2socks_mgr;

#[cfg(feature = "pqc")]
pub mod pqc;

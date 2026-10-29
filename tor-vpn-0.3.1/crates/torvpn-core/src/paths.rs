//! Canonical paths. The service runs as LocalSystem, so we cannot use
//! `%LOCALAPPDATA%` (that would resolve under `C:\Windows\System32\config\systemprofile\…`,
//! which the user-mode tray cannot read).
//!
//! Everything that needs to be shared between the elevated service and the
//! user-mode tray lives under `%PROGRAMDATA%\torvpn` (default `C:\ProgramData\torvpn`),
//! which is world-readable by default. Files we want to keep secret (api_token,
//! hmac secret) get an explicit ACL set by the installer / first-run code.

use std::path::PathBuf;

/// Where the service stores its persistent state (PIDs, hop state, tokens, tor data).
pub fn state_dir() -> PathBuf {
    if let Ok(programdata) = std::env::var("ProgramData") {
        return PathBuf::from(programdata).join("torvpn");
    }
    // Fallback for non-Windows test builds.
    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("torvpn")
}

/// Where the installer drops binaries (Tor, tun2socks, wintun.dll, our exes).
pub fn install_dir() -> PathBuf {
    if let Ok(programfiles) = std::env::var("ProgramFiles") {
        return PathBuf::from(programfiles).join("TorVPN");
    }
    PathBuf::from(".")
}

pub fn config_path() -> PathBuf {
    state_dir().join("profile.toml")
}

pub fn api_token_path() -> PathBuf {
    state_dir().join("api_token")
}

pub fn api_hmac_secret_path() -> PathBuf {
    state_dir().join("api_hmac_secret")
}

pub fn pid_path() -> PathBuf {
    state_dir().join("pids.json")
}

pub fn tor_data_dir() -> PathBuf {
    state_dir().join("tor-data")
}

pub fn torrc_path() -> PathBuf {
    state_dir().join("torrc.generated")
}

pub fn state_file() -> PathBuf {
    state_dir().join("state.json")
}

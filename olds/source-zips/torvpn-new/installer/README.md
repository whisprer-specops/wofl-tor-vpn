# Building TorVPN-Setup.exe

This directory produces a single redistributable installer that contains
everything an end-user needs: the service, the tray app, the bundled Tor
daemon, tun2socks, the Wintun driver, the kill-switch scripts, and the
default profile. After running the installer, users just click the tray
icon to engage.

## Prerequisites (build machine, Windows 10/11 x64)

1. **Rust toolchain** with the `x86_64-pc-windows-msvc` target (default on
   Windows). `rustup show` should print 1.75+.
2. **Visual Studio 2019/2022 Build Tools** — needed for the MSVC linker.
3. **Inno Setup 6.x** — https://jrsoftware.org/isdl.php
4. **Internet access** for the staging step (one-time per version bump).

## Build steps

From the repo root, in an **elevated PowerShell** (so Inno's signing
post-build steps can run if you add code-signing later):

```powershell
# 1. Download and stage Tor, tun2socks, Wintun
cd installer
.\stage.ps1
cd ..

# 2. Build the Rust binaries in release mode
cargo build --release -p torvpn-svc
cargo build --release -p torvpn-tray

# 3. Compile the installer
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\installer.iss
```

Output: `installer\Output\TorVPN-Setup-<version>.exe`

## What the installer does

| Phase           | Action                                                   |
|-----------------|----------------------------------------------------------|
| Pre-install     | Kills any running `torvpn-tray.exe` so files are unlocked |
| Files           | Drops binaries to `C:\Program Files\TorVPN\`              |
| Service install | Runs `torvpn-svc.exe service-install` (`sc create` + `sc start`) |
| Autostart       | Adds tray to `HKCU\...\Run` (optional, default on)        |
| Launch          | Starts the tray icon immediately                          |
| Uninstall       | Runs `torvpn-svc.exe service-uninstall`, tears down firewall + DNS, wipes `%ProgramData%\torvpn` |

## Code signing (recommended for redistribution)

SmartScreen will complain on the first hundred or so downloads of an
unsigned installer. To sign:

1. Acquire an Authenticode certificate (DigiCert, Sectigo, or a cheap
   reseller; ~£70-£150/yr).
2. Sign each Rust binary post-build:
   ```powershell
   signtool sign /tr http://timestamp.digicert.com /td sha256 /fd sha256 `
     /a target\release\torvpn-svc.exe target\release\torvpn-tray.exe
   ```
3. Sign the resulting `TorVPN-Setup-*.exe`.

For best UX you want an EV cert, which removes SmartScreen warnings
immediately rather than after a download-count reputation builds up.

## Customising version numbers

Edit `installer.iss` (`MyAppVersion`) and the Rust crate `Cargo.toml`
files in lockstep, then bump `TorVersion` / `Tun2SocksVersion` /
`WintunVersion` in `stage.ps1` when those upstreams release.

# whispr Hybrid VPN tray 0.1.0

This is an additive control panel for the working **0.4.0-fix5** installation. Windows 11 x64 and PowerShell 7.6.x. No extra runtimes or downloads. The existing Start.ps1, Session.ps1, Recover.ps1, config generator, Tor, sing-box and WFP guard are not replaced or edited. There is no boot task, Explorer hook, system file edit, automatic reconnect or automatic server provisioning.

## Install with the current VPN still connected

Extract the add-on ZIP to a new folder. In elevated PowerShell 7, run `./Install-Tray.ps1`. Installation validates the working base, adds six files and their separate add-on checksum file, creates a Start menu shortcut and opens the tray. It never calls recovery or restarts the current session. The core SHA256SUMS.json is unchanged. Existing keys, active peer, routes and server configuration are untouched. `-NoLaunch` installs without opening the UI. No sudo password is involved in tray installation.

The tray may be under Windows' **^** notification overflow. You can drag it into the visible notification area. Start it later using **whispr Hybrid VPN Tray** in Start, or:

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Open-Tray.ps1"
```

The launcher requests Windows UAC elevation if required. Cancelling UAC cancels the tray launch. It does not change the VPN. The tray runs in a separate PowerShell STA process and attaches to an existing session through status records and the guard's read-only status command.

## Menu

- **Connect:** launches the installed, unchanged Start.ps1 in a minimized console. The existing supervisor keeps its own console/input, process job and failure behavior. You can restore that console from the taskbar. An already running console session does not move into the tray or restart.
- **Disconnect / Recover:** asynchronously runs the installed Recover.ps1. It stops the recorded dedicated session and removes only its owned TUN and guard. Errors remain visible, with output saved to the protected `tray-recovery.log` file.
- **UDP / VPS exit:** NYC1, LON1, SGP1 and SYD1. Changing exits requires a fully disconnected/recovered state. The active profile is copied into the protected profiles folder on first launch, without changing peer.json. Selecting a ready profile backs up peer.json and replaces only that selected public peer configuration. Click Connect afterwards. Device keys and Tor selection do not change.
- **Prepare (sudo):** an unprepared exit opens a visible terminal explaining the server-side change and asking for that VPS's wofl sudo password. It uses the existing validated server setup and device public key. It saves a profile only after successful provisioning and validation. It does not select or connect it. Add **inbound UDP 51832**, not TCP, to any DigitalOcean firewall attached to that VPS. Existing sites, mail and unrelated VPNs retain the same treatment as the working fix5 server installer.
- **Connection information / double-click:** current state, guard status, selected endpoint, last verified TCP and UDP IPs, verification timestamp and any recorded session failure.
- **Open routing log:** opens only engine-stderr.log in Notepad. It does not open the private-key or engine configuration files.
- **About:** version, behavior and privacy model.
- **Close tray only — keep VPN running:** removes the tray UI. The independent VPN session and persistent protection continue unchanged.
- **Disconnect and Exit:** runs recovery, checks that the guard is DISARMED and the owned TUN is gone, then closes the tray. A recovery error leaves the tray open.

Tor's TCP exit remains automatic; this version's selector controls your **UDP/VPS exit**, not the Tor country. UDP is protected by WireGuard to your VPS; it is not sent through Tor. LAN/private-network exceptions remain direct.

## Status

Green requires all of: the guard recently reported ARMED; the recorded supervisor PID, process path and start time still match a running process; the recorded TUN GUID is Up; session state is verified-session; verification is no more than 150 seconds old; and the verified UDP address matches the selected profile. Orange is connecting, an operation in progress or stale verification. Red means protection/recovery or status trouble. Gray means disconnected. An old verification record or ARMED by itself never produces green. These are live supervisor checks, not a full leak or kernel/crash certification.

The guard is queried asynchronously every two seconds, with a four-second query timeout. There is no polling thread running PowerShell callbacks without a runspace. UI events and a WinForms timer run on one STA message loop. The tray's cleanup disposes its handles/icons but does not kill transports or remove guard policy. A tray crash therefore does not create an intentional disconnect.

## Rollback: remove only the tray

Choose **Close tray only — keep VPN running**, then in elevated PowerShell:

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Remove-Tray.ps1"
```

This backs up and removes only the add-on files, their separate checksum file and the matching Start menu shortcut. The current selected exit, saved profiles, device keys, running session and working fix5 core remain. Installer/removal backups live under the existing administrator-only state folder's tray-backups directory. Selecting a different exit is an explicit later action, so removing the UI does not undo a user's endpoint selection.

If the VPN itself fails, the existing recovery command remains unchanged:

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Recover.ps1"
```

## Validation and limits

PowerShell parsing and actual PowerShell model/file-transaction tests are run locally. The tray status tests reject stale/future timestamps, dead supervisors, absent TUNs and unknown/disarmed guards. Profile tests reject invalid identities/keys and unsafe switching; installation tests check that the original core stays byte-for-byte identical, downloaded hashes are retained, active peer/private state are not modified and removal deletes only add-on files. The installer checks core hashes before writing. Full Windows WinForms/UAC/Explorer integration cannot be executed in the Linux build environment; the first Windows tray launch still needs verification. The working networking code is deliberately preserved so UI validation does not require replacing it.

Source references: Microsoft's NotifyIcon, ApplicationContext and PowerShell -STA documentation; the existing fix5 scripts and server setup. No new networking engine or GUI dependency is installed.

Copyright © 2026 whispr.dev. MIT license; see LICENSE in the download.

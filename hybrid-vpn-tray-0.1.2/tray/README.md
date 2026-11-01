# whispr Hybrid VPN tray 0.1.2

This is an additive control panel for the working **0.4.0-fix5** installation. Windows 11 x64 and PowerShell 7.6.x. No extra runtimes or downloads. The existing Start.ps1, Session.ps1, Recover.ps1, config generator, Tor, sing-box and WFP guard are not replaced or edited. There is no boot task, Explorer hook, system file edit, automatic reconnect or automatic server provisioning.

## Install with the current VPN still connected

Extract the add-on ZIP to a new folder. In elevated PowerShell 7, close the old tray with **Close tray only — keep VPN running**, then run `./Install-Tray.ps1`. Installation validates the working base, adds thirteen files and their separate add-on checksum file, creates a Start menu shortcut and opens the tray. It never calls recovery or restarts the current session. The core SHA256SUMS.json is unchanged. Existing keys, active peer, routes and server configuration are untouched. `-NoLaunch` installs without opening the UI. No sudo password is involved in tray installation.

The tray may be under Windows' **^** notification overflow. You can drag it into the visible notification area. Start it later using **whispr Hybrid VPN Tray** in Start, or:

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Open-Tray.ps1"
```

The launcher requests Windows UAC elevation if required. Cancelling UAC cancels the tray launch. It does not change the VPN. The tray runs in a separate PowerShell STA process and attaches to an existing session through status records and the guard's read-only status command.

## Menu

- **Connect:** launches a separate console-free background host. That host runs the installed, unchanged Session.ps1 with a private input pipe held open, and drains its output into protected log files. Closing a terminal, launcher or tray does not close that input pipe. An existing console session cannot be transferred live; disconnect/recover it once, then Connect from this tray to start in background mode.
- **Disconnect / Recover:** asynchronously runs the installed Recover.ps1. It stops the recorded dedicated session and removes only its owned TUN and guard. Errors remain visible, with output saved to the protected `tray-recovery.log` file.
- **UDP / VPS exit:** NYC1, LON1, SGP1 and SYD1. Changing exits requires a fully disconnected/recovered state. The active profile is copied into the protected profiles folder on first launch, without changing peer.json. Selecting a ready profile backs up peer.json and replaces only that selected public peer configuration. Click Connect afterwards. Device keys and Tor selection do not change.
- **Prepare (sudo):** an unprepared exit opens a visible terminal explaining the server-side change and asking for that VPS's wofl sudo password. It uses the existing validated server setup and device public key. It saves a profile only after successful provisioning and validation. It does not select or connect it. Add **inbound UDP 51832**, not TCP, to any DigitalOcean firewall attached to that VPS. Existing sites, mail and unrelated VPNs retain the same treatment as the working fix5 server installer.
- **Connection information / double-click:** current state, guard status, selected endpoint, last verified TCP and UDP IPs, verification timestamp and any recorded session failure.
- **Open background session log:** opens the current background session stdout log in Notepad, including startup and verification messages.
- **Open background error log:** opens the most recent detached host stderr log, including early host startup errors.
- **Open routing log:** opens only engine-stderr.log in Notepad. It does not open the private-key or engine configuration files.
- **About:** version, behavior and privacy model.
- **Close tray only — keep VPN running:** removes the tray UI. The independent VPN session and persistent protection continue unchanged.
- **Disconnect and Exit:** runs recovery, checks that the guard is DISARMED and the owned TUN is gone, then closes the tray. A recovery error leaves the tray open.

Tor's TCP exit remains automatic; this version's selector controls your **UDP/VPS exit**, not the Tor country. UDP is protected by WireGuard to your VPS; it is not sent through Tor. LAN/private-network exceptions remain direct.

## Status

Green requires all of: the guard recently reported ARMED; the recorded supervisor PID, process path and start time still match a running process; the recorded TUN GUID is Up; session state is verified-session; verification is no more than 150 seconds old; and the verified UDP address matches the selected profile. Orange is connecting, an operation in progress or stale verification. Red means protection/recovery or status trouble. Gray means disconnected. An old verification record or ARMED by itself never produces green. These are live supervisor checks, not a full leak or kernel/crash certification.

The guard is queried asynchronously every two seconds. UI events use one STA message loop. Closing the tray disposes UI/process handles, not the independent VPN. The background owner is launched by Windows Task Scheduler rather than inheriting the terminal's process/job lifetime. A scheduler bootstrap runs the actual host with no console, captures its logs, and keeps its own kill-on-close job alive. The existing Session.ps1 still gets a held input pipe and retains its original transport job and verification checks. No direct process-breakaway API is used in this version. The historical DetachedLauncher.cs filename now contains only the tested argument-quoting helper.

The on-demand task is named **whispr-HybridVPN-Background-<your Windows SID>** in Task Scheduler's root folder. It uses the current logged-in user with highest privileges and stores no password. It has **no triggers, automatic restart or startup/logon schedule**. The task starts only after Connect (or Start-Background.ps1). It allows battery operation, will not stop when switching to battery, has no execution time limit, and ignores duplicate starts. SYSTEM and elevated Administrators alone may edit/run it. Existing tasks with a conflicting name/action/account/automatic trigger are rejected rather than overwritten. No new service is installed.

## First move from a console session to background

1. Keep the old VPN console open while installing. Close only the old tray UI before updating.
2. The installer runs a temporary on-demand scheduler self-check before copying add-on files. It verifies a console-free worker, held input and nested-job cleanup with disposable dummy processes. It deletes the probe task and files afterwards. It does not connect, recover, change firewall settings or touch the existing VPN.
3. In the new tray, choose Disconnect / Recover once. Wait for Disconnected.
4. Click Connect. This time no VPN terminal is created. Wait for green / Verified, then close the old terminal.

You can start a background session without the tray using elevated PowerShell:

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Start-Background.ps1" -WaitForVerification
```

Once verified, the launcher terminal can be closed. `Start.ps1` remains the original console fallback. Closing the tray alone does not disconnect a background session. Sign-out, shutdown and reboot still end user processes; this adds no service, automatic boot/logon trigger or automatic reconnection. Persistent protection may require Recover.ps1 after a crash/reboot, as before.

The host keeps a kernel kill-on-close job for its Session child; Session retains its original separate job for Tor/engine. If the background host or supervisor fails, owned processes stop and persistent guard protection remains for explicit recovery. Host lifecycle metadata is in background-host.json. Each launch has uniquely named background-<id>-host and background-<id>-session stdout/stderr logs in the existing protected state directory. No private key or engine configuration is displayed by the new log menu.

## Rollback: remove only the tray

Choose **Close tray only — keep VPN running**, then in elevated PowerShell:

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Remove-Tray.ps1"
```

If the scheduled background task is still running, removal refuses and asks you to Disconnect / Recover first. Closing just the tray can always leave the VPN running. Once disconnected, removal deletes the owned on-demand task, add-on files, separate checksum file and matching Start menu shortcut. Remove the add-on before using the original core Uninstall.ps1 so its manual task entry is cleaned up too. The selected exit, saved profiles, keys and working fix5 core remain. Installer/removal backups live under the existing administrator-only state folder's tray-backups directory. Selecting a different exit is an explicit later action, so removing the UI does not undo a user's endpoint selection.

If the VPN itself fails, the existing recovery command remains unchanged:

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Recover.ps1"
```

## Validation and limits

PowerShell parsing and actual PowerShell model/file-transaction tests are run locally. The tray status tests reject stale/future timestamps, dead supervisors, absent TUNs and unknown/disarmed guards. Profile tests reject invalid identities/keys and unsafe switching; installation tests check that the original core stays byte-for-byte identical, downloaded hashes are retained, active peer/private state are not modified and removal deletes only add-on files. The installer checks core hashes before writing. The new managed helpers compile locally, and a real PowerShell input fixture verifies that the original Console.ReadLine stays pending while its independent host keeps the writer open, then receives stop correctly. Native process creation, Windows job containment and full Windows WinForms/UAC/Explorer integration cannot be executed in the Linux build environment; the first Windows tray launch still needs verification. The working networking code is deliberately preserved so UI validation does not require replacing it.

Source references: Microsoft's NotifyIcon, ApplicationContext, process creation flags, handle-list inheritance and nested jobs documentation; the existing fix5 scripts and server setup. No new networking engine or GUI dependency is installed.

Copyright © 2026 whispr.dev. MIT license; see LICENSE in the download.

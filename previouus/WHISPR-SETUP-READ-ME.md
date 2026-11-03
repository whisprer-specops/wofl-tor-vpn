# whispr VPN setup 1.0.2 — Windows 11 x64

**Double-click `whispr-vpn-1.0.2-setup.exe`. Use this setup EXE for installation, upgrade and repair.** It contains the MSI and performs automatic whispr shutdown **before** Windows Installer checks locked files. There is no terminal command to paste and no need to identify or stop processes in Task Manager.

Approve Windows UAC and the clearly described VPN disconnection. Read/accept the supplied licence in the MSI, then Install. If this version is already installed, choose Repair. Leave setup open until its final result. It does not force a reboot. Both the setup EXE and MSI are unsigned.

## Automatic shutdown

Setup verifies the exact whispr task names, source, principal, script and working folder. It records their enabled settings, pauses/stops them, and stops only the application's own executable paths or PowerShell processes whose parsed `-File` argument names a known whispr script. It rechecks process creation time and executable path through a held process handle before termination. It does not kill every PowerShell/Tor process, Windows Explorer, Terminal, system processes or the separate official WireGuard tunnel.

It removes only the positively identified `whispr-hybrid` tunnel device when needed, using its GUID/dedicated address and PnP identity; it does not remove a driver package. The embedded original guard recovers only whispr's fixed WFP provider/filter set. Setup confirms DISARMED and marks the stored session disconnected before opening the MSI. Private keys and exit profiles are retained unchanged. No Winsock, firewall-profile, DNS, system-file or general network reset is used.

A genuine retired **TorVPN** service is stopped/disabled only if its SCM name, own-process service type, protected installation folder and exact `Program Files\TorVPN\torvpn-svc.exe` path match. On success it stays disabled to avoid reintroducing the old conflict. Its prior start mode is recorded. Unknown service identities are left untouched.

The existing whispr task enabled settings and actions are preserved, including auto-connect at sign-in. Setup restores enabled settings after success, cancellation or installation failure. The connection stays disconnected; open **whispr VPN** from Start and use the tray to reconnect after installation. Setup holds the application's session/tray/background mutexes while replacing desktop files. It also checks for verified whispr processes that restart during the MSI.

## Old/partial installs

The MSI still inventories registered products, known folders, state and tasks. Missing registered desktop files can be repaired/upgraded. The launcher closes the owned running components automatically; an old window or surviving background session is no longer homework for the user.

Missing older Windows Installer cache, unknown linked folders, missing identity alongside saved exits, or damage to the separate connection client can still need recovery. The launcher does not invent a new identity, delete Installer registration, overwrite an unknown client or kill an unverified process to conceal such damage. Its exact failure and retained startup journal are recorded automatically.

The setup launcher uses **Windows' own x64 PowerShell 5.1**, independent of the installed app's portable/Store PowerShell. It keeps its verified resources in an administrator/SYSTEM-only directory under `%ProgramData%\whispr-vpn-setup\packages\1.0.2`. Per-attempt logs and task/startup journals are in `%ProgramData%\whispr-vpn-setup\transactions`. A subsequent setup attempt restores pending startup settings from an interrupted setup journal before proceeding. This is a recovery-on-next-setup mechanism; it does not install a boot task.

The bare MSI is retained inside setup for Windows Installer registration, repair and uninstall; **use the setup EXE for install/upgrade/repair**, since it must stop whispr before the MSI's locked-file check. A direct MSI install/repair gives this instruction before file replacement. The MSI's embedded uninstall/dependency check remains independent of deleted installed scripts.

## Existing client versus new PC

- Existing PC: keys, selected exit, profiles, map, flags and group catalogue remain outside the desktop MSI. The original task host is reused; verified Microsoft Store PowerShell hosts are supported. Open the tray and connect after setup finishes.
- New PC: choose **Set up this PC** in the control centre. It downloads the pinned original Tor/sing-box releases with SHA-256 checks, creates this PC's own key, and exports `friend-request.json`. Send only that public request to the group owner. Import their returned `group.json` or legacy `friend-access.json`, then connect in the tray. No VPS credentials are needed by a new member.
- Each VPS owner must publish/sync approvals to their own endpoints before a new member can use them. Group tools retain the original visible SSH/sudo flow. Group membership and VPS ownership are not changed by desktop installation.

## Removal

For a client created through the desktop, use Disconnect / Recover, close its tray and choose **Remove VPN client**, which retains local keys/settings. Then uninstall the desktop through Windows Settings. Removing a runtime while a client/task still depends on it remains blocked. This release's setup launcher automates installation/upgrade/repair shutdown; it is not an automatic full-client uninstaller. Server approvals must be revoked separately by their owners.

## Verification

The delivered build includes PowerShell parsing, C# adapter compilation, ownership tests, success/cancel/MSI-failure/cleanup-failure workflow tests with real filesystem journals and unchanged key/profile bytes, interrupted-settings recovery, native x64 compilation, MSI database/action-order/licence tests, every-file cabinet extraction, and PE resource checks on the actual setup EXE. Windows process/SCM/task/MSI/device calls in the workflow tests are mocked. **The installer has not been executed on native Windows in this build environment.** This is a release candidate until the Windows acceptance checks in BUILD.md pass. No new claim of Windows kernel stability or leak validation is made.

The supplied licence is unchanged. Third-party notices remain with their components; source, build steps and validation are in the source ZIP.

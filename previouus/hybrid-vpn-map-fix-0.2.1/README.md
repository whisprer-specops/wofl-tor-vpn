# whispr Hybrid VPN tray 0.2.1

For the working Windows 11 x64 / PowerShell 7 **0.4.0-fix5** installation. Adds independent background sessions, an offline exit map, Frankfurt support, and optional automatic connection **at this user's Windows sign-in** after reboot. It does not preserve a network connection through shutdown and is not a pre-login Windows service.

## Map repair for an already working 0.2.0 installation

All five exits can remain configured exactly as they are. Close the old tray using **Close tray only — keep VPN running**. Extract this ZIP, then run `./Install-MapFix.ps1` in elevated PowerShell 7. This updates only Tray.ps1, tray/Map.ps1, tray/MapModel.ps1 and their add-on checksum entries, with backup and rollback. It does not call recovery, change a task, reprovision a server, or write keys, profiles, routing settings or the core manifest. No sudo password or VPN disconnect is needed. It opens the updated tray automatically. The ordinary full add-on installer remains included for installation on the working fix5 core.

The world is painted directly into the live client area using explicit pixel rectangles, so it fills the available space at first display and after resizing. The map has an enlarged, clickable Europe inset with separately labelled London and **Frankfurt (fkt1)**, and both also appear on the world view. The same coordinate model handles drawing and clicks. Drawing errors are displayed instead of silently leaving an old miniature bitmap. The map remains read-only while connected; disconnect normally only when you want to select another exit.

## Install

Close the old tray using **Close tray only — keep VPN running**. Extract this ZIP into a fresh folder. In elevated PowerShell 7 in that folder:

```powershell
.\Install-Tray.ps1 -EnableAutoConnect
```

No server sudo password is involved in tray installation. Windows UAC may appear. The installer first runs a harmless Task Scheduler background self-check using dummy processes. It stops before installing if Windows cannot keep that worker independent of the launching terminal. This is the replacement for the failed 0.1.1 breakaway launcher; its unsafe-launch check has not been bypassed.

A current verified console session may keep running while installing. Enabling sign-in startup validates and records its public endpoint/key/binary binding. If that step fails, the tray remains installed, the existing VPN remains untouched, and auto-connect is not reported as enabled. Disconnect / Recover normally, then enable **Auto-connect at Windows sign-in** in the tray. Installation without `-EnableAutoConnect` preserves an existing setting; a first installation leaves it off. `-NoLaunch` suppresses opening the tray.

The installer patches only `client/Session.ps1` and its integrity manifest to add protected startup resume, and installs its checked helper. The original supervisor is bundled for removal/rollback. The working configuration generator, TCP/UDP verification, recovery script, guard executable, Tor, sing-box, server scripts, device key and selected exit are preserved. Existing running scripts are not restarted. File-installation failures restore the previous supervisor, manifest, add-on and shortcut. Enabling auto-connect happens after that transaction; an auto-connect error leaves the installed tray available for diagnosis.

Start menu: **whispr Hybrid VPN Tray**. Check the **^** notification overflow if necessary. Later manual launch:

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Open-Tray.ps1"
```

## Prepare Frankfurt

First choose **Disconnect / Recover** and wait for **Disconnected**. This setup command uses your existing `fkt1` alias and existing client key. **It asks for the remote SSH account's sudo password unless that alias logs in as root.**

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Prepare-Exit.ps1" -Server fkt1 -SelectAfter -Pause
```

The alias must resolve to a numeric public IPv4 address and already have a trusted host key / working key-based SSH login. The VPS must support the existing Debian/Ubuntu WireGuard/iptables installer. Setup uploads and verifies the existing server scripts, provisions the dedicated UDP exit, validates the public report, saves a Frankfurt profile and selects it. It does not start a client connection. Existing NYC and other saved profiles remain available. It does not open cloud firewall rules for you.

**Allow inbound UDP 51832 on the firewall attached to FKT1. A TCP 51832 rule does not allow WireGuard.** Then click **Connect** and wait for **Verified / green**. Server setup completion alone does not verify the tunnel. This package supports Frankfurt; the author has not accessed or provisioned your new VPS remotely.

## Map and exits

**Choose exit on map…** opens a bundled offline world map. Click a dot for New York, London, Frankfurt, Singapore or Sydney. Gold = selected profile; cyan = saved/prepared profile; gray = not prepared. These colours do not claim a live connection. When connected the map is read-only; disconnect before changing exits. The text selector remains available.

Selecting an unprepared region offers a visible SSH/sudo preparation terminal. After successful preparation click its dot again to select it, then Connect. Prepared profiles must match this device's public key. Selection backs up and atomically changes only the selected public peer profile. An absent profile is not silently invented or provisioned.

The selector controls **UDP through your WireGuard VPS**. TCP and DNS retain the working Tor path and automatic Tor exit selection. LAN/private-network exceptions remain direct. Map dots are approximate city centres, not exact physical server positions. Natural Earth public-domain map attribution is in `tray/MAP-SOURCE.txt`.

## Sign-in startup and recovery

The checkbox **Auto-connect at Windows sign-in** is persistent. With it enabled, Task Scheduler opens the hidden tray ten seconds after this account signs in and the tray launches an independent background VPN session. No password is stored. Your last selected exit is reused; startup does not select a different region or provision a server. The account must be the same administrator account used to install; this is an interactive-user task, not SYSTEM.

Startup makes up to three attempts, spaced by at least thirty seconds after a failed launch; a running session gets time to bootstrap and verify. Once verified, startup retries stop. An intentional Disconnect / Recover cancels that sign-in's pending attempts. Disable the checkbox to stop future automatic sign-in launches. Later runtime transport failures retain protection and require attention; this is not an endless reconnect watchdog. Sleep/network changes do not create new logon-trigger events.

If the persistent guard is still armed after restart, resume validates the prior session identity, selected public endpoint, port, client/server public keys, install path and pinned engine/Tor/guard hashes. It refuses to replace a live supervisor. A leftover owned adapter is removed only when its recorded GUID and one device identity match. The guard remains armed while Tor and WireGuard restart; only the owned tunnel permit is updated through the existing guard command. Missing/mismatched state requires explicit recovery rather than automatic disarming. Logs: `autostart-error.log` and the background session/error logs in the existing protected state folder.

This is **sign-in auto-connect**, not a guarantee that traffic is blocked from the earliest stage of Windows boot. Pre-login protection, Windows reboot/crash behavior and full leak resistance require live Windows validation. Reboot ends user processes; the next session is newly established. A previously armed guard is deliberately not automatically recovered to regain ordinary Internet access.

Manual recovery remains:

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Recover.ps1"
```

## Background operation and tray controls

An existing console session cannot be transferred live. Disconnect / Recover it once, then click **Connect** in this tray. After Verified, close terminals freely. **Close tray only — keep VPN running** closes only the UI. **Disconnect and Exit** runs recovery, checks that protection is disarmed and the owned adapter is gone, then exits. A failure leaves the UI open.

The independent host is owned by Task Scheduler, keeps the supervisor's input pipe open, drains stdout/stderr to protected files and owns a kill-on-close job. The supervisor retains its existing separate transport job. A host crash stops its children and retains persistent protection. The original `Start.ps1` is still the console fallback and requires its terminal to remain open. CLI background launch:

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Start-Background.ps1" -WaitForVerification
```

The task names are `whispr-HybridVPN-Background-<Windows SID>` (on-demand session, no triggers) and `whispr-HybridVPN-Autostart-<Windows SID>` (the optional sign-in tray). Both use the current user at highest privilege, allow battery operation, have unlimited duration, ignore duplicate launches, and restrict task access to SYSTEM/elevated Administrators. Foreign task collisions are refused. No extra service, engine or runtime is installed.

**Connection information**, **About**, and session/error/routing log actions are available. Green requires a matching live supervisor, a recorded Up TUN, recent ARMED guard status, a verified session less than 150 seconds old, and UDP verification matching the selected exit. An old result alone never grants green. Orange is connecting/stale; red needs attention; gray is disconnected. A successful live status is not comprehensive crash/leak certification.

## Remove / rollback

Disconnect first, close the tray, then in elevated PowerShell:

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Remove-Tray.ps1"
```

Removal refuses an active scheduled session/tray, validates ownership, removes its two tasks, restores the original console supervisor, removes the resume manifest entry and add-on files/shortcut. Keys, selected profile and saved profiles remain. Backups are under the protected state folder's `tray-backups`. Remove this add-on before the original core uninstall so its tasks are cleaned up too.

## Validation

See `TEST-RESULTS.txt`: actual PowerShell parsing, status/selection tests, resume binding/mismatch/live-owner/TUN refusal tests, map hit testing, scheduler/logon definition and ownership checks, C# compilation/held-input tests, and a file transaction fixture covering rollback, reinstall, old-tray upgrade and removal. Windows ACL/COM boundaries are explicitly mocked in Linux tests. Actual WinForms rendering, task lifetime, reboot/startup and the new Frankfurt endpoint still require live verification. The installer runs its Windows background self-check before changing installed files.

Copyright © 2026 whispr.dev. MIT license; see LICENSE. Map data public domain.

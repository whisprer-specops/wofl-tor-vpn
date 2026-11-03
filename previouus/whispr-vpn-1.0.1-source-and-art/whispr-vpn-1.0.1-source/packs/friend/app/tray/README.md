# whispr VPN — friend pack 1.0.0

For the invited friend's **Windows 11 x64 PC**, using **PowerShell 7.2+ x64 as Administrator (7.6.x recommended)**. No Python, Rust, SSH account, VPS password or separate WireGuard application is required on this PC. The installer downloads the same pinned sing-box 1.14.4 and Tor Expert Bundle 15.0.26 used by the working fix5 client, checking their SHA-256 archive hashes. Initial downloads total about 56 MB. PowerShell 7 is a prerequisite: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows

This package is for the friend's PC. It deliberately refuses to overwrite the owner's existing installation. Each PC gets its own private WireGuard key. An additional PC requires a separate request/enrolment; copying an installed state folder is not device setup.

## 1. Install and create the request

Disconnect other full-tunnel VPNs and release their kill switch using their own app before installation. This installer will report detected conflicts rather than removing another product's policy. Do not close a currently working whispr console session merely to install over it: this is a separate friend installation.

Save the ZIP in Downloads, then open **PowerShell 7 as Administrator**:

```powershell
Set-Location "$env:USERPROFILE\Downloads"
Unblock-File .\whispr-vpn-friend-1.0.0.zip
Expand-Archive .\whispr-vpn-friend-1.0.0.zip -DestinationPath .\whispr-vpn-friend-1.0.0 -Force
Set-Location .\whispr-vpn-friend-1.0.0
.\Install-Friend.ps1 -DeviceName Friend-PC
```

You can replace `Friend-PC` with a short ASCII device label, for example `Alex-Laptop`. Spaces require quotes. The installer creates protected application/state directories, installs the existing client/guard, generates a private key locally and tests independent background process lifetime with disposable dummy processes. It starts **no VPN, protection guard or auto-connect schedule**. No sudo prompt is involved; Windows UAC/admin access is required.

At completion, **friend-request.json** appears in the extracted pack folder. Send **only that JSON file** to the VPN owner. It contains your device label, public key, request ID and public-key fingerprint. The private key remains in the administrator-only local state folder. Never send `device-key.json`, `engine.json`, your entire ProgramData folder or an installed-state ZIP.

Use a direct, trusted conversation with the owner for both exchanged JSON files. Request/device matching prevents importing another device's approval; it is not a cryptographic signature proving who sent the file. Compare the printed public-key fingerprint with the owner if there is doubt about the request's origin.

## 2. Import the returned access file

The owner registers your public key on the exits they approve and sends back **friend-access.json**. Save it in Downloads. In the same elevated PowerShell, still in the extracted friend pack folder:

```powershell
.\Import-Access.ps1 -AccessFile "$env:USERPROFILE\Downloads\friend-access.json" -EnableAutoConnect
```

This verifies that the approval matches your locally saved public key and request ID, validates the exit data, saves the approved profiles and opens the tray. It does not start a connection. Click **Connect**, then wait for **Verified / green** before relying on it. The map shows New York, London, Frankfurt, Singapore and Sydney; unapproved exits remain unavailable and ask for owner approval. The friend client cannot administer or provision servers.

`-EnableAutoConnect` enables automatic connection/tray launch when **this same administrator account signs into Windows after a restart**. Omit the switch to leave that option unchanged/off, or change it later in the tray. It is not a pre-login service or a guarantee of earliest-boot traffic protection. Reboot ends the old session and a fresh session is established at sign-in. Crash/runtime failures retain the existing guard and may require explicit recovery.

For later approval changes: disconnect normally, use **Close tray only**, then import the new access file. Imports replace the local set of available profiles with the exits in that returned file; they preserve your private key. Removing a local profile does not revoke server access; only the owner can revoke it on the VPS.

## Everyday operation

- Start menu: **whispr Hybrid VPN Tray**; it may be under the notification-area `^` overflow.
- **Choose exit on map**: select an approved UDP/WireGuard exit while disconnected. Frankfurt and London also appear in a Europe inset.
- **Close tray only — keep VPN running** leaves the independent background connection running. Closing the installer or another terminal does not stop a tray-launched background session.
- **Disconnect / Recover** disconnects and removes the owned guard policy. **Disconnect and Exit** also closes the tray.
- **Auto-connect at Windows sign-in** is the persistent startup toggle.
- TCP and DNS use Tor; Tor selects its own exit. UDP uses the chosen VPS. LAN/private-network exceptions remain direct. Server bandwidth is shared; latency depends on each person's route.
- Orange/red is not a verified connection. Inspect Connection information and the background/routing logs.

Manual recovery from another elevated PowerShell:

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Recover.ps1"
```

Manual tray launch:

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Open-Tray.ps1"
```

To re-export the same public request if the original file was lost:

```powershell
.\New-Request.ps1
```

Reinstalling a recognized friend installation preserves the key and request. Disconnect and close the tray first. Do not generate a new key just to retry a failed import. There is no auto key-rotation or silent regeneration of an existing identity.

## Remove

Disconnect and close the tray. In elevated PowerShell:

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Uninstall.ps1"
```

This removes the local friend client and its owned scheduled tasks, retaining protected local identity by default. Add `-DeleteLocalKeys` only when intentionally deleting the local identity; reinstallation would then require a new enrolment. Ask the owner to revoke the old device on all exits as well. Friend clients do not have permission to revoke themselves remotely through this package.

## Validation and limits

The packet routing, WFP guard binary, Tor/UDP verification and background host use the existing fix5/0.2.1 implementation. Peer-only owner enrolment never invokes firewall, service or sysctl changes. See TEST-RESULTS.txt for actual tests and their platform boundaries. Linux tests cannot establish Windows WFP, Task Scheduler, WinForms, crash/boot or leak behavior; the Windows installer runs its dummy-process background self-check, and the first real connection must pass both transport verification checks. No live connection from a friend's PC has been claimed tested here.

Copyright © 2026 whispr.dev. MIT for whispr code; third-party notices/source are included. The bundled map uses public-domain Natural Earth data. Retain the guard Rust source, its pinned toolchain/Cargo.lock and third-party notices when redistributing this pack. Fetched Tor/sing-box distributions include their own license files.

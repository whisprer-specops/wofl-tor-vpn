# TorVPN 0.3.0 + Local/Dynamic firewall hotfix 2

A Windows tray controller and privileged service that route IPv4 TCP connections
through Tor using Wintun and tun2socks. Tor does not carry arbitrary UDP: native
IPv6 and non-DNS UDP are blocked while connected. This is not Tor Browser and
does not provide Tor Browser's browser fingerprint protection.

## Already installed 0.3.0 or hotfix1?

Run this from the newly extracted hotfix2 directory in **Administrator PowerShell**:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Apply-Hotfix.ps1
```

It backs up and replaces both firewall apply/teardown scripts, installs the
updated diagnostic collector, restarts the existing service and waits for the
connection result. No binary rebuild, Tor download, profile reset or driver
reinstall is needed. A failed attempt automatically saves torvpn-diagnostic.txt
in this hotfix directory.

Hotfix1 exposed the precise blocker: Internet Connection Sharing's
SharedAccess-Out rule, a Dynamic rule in ActiveStore, alongside 187 Local rules.
Hotfix2 supports suspending Dynamic rules via the actual live CIM rule object
(-InputObject), as Microsoft documents. It does not treat a runtime rule as a
PersistentStore rule and does not stop the SharedAccess Windows service.

It saves the names and traced source types of originally enabled rules before
mutation. Disconnect/error recovery finds the live Dynamic objects and restores
their enabled state. Originally disabled rules stay disabled. Expired runtime
rules are not recreated as permanent rules, and a replacement from another
source is not enabled accidentally. Earlier 0.3.0/hotfix1 backups still work.

An effective-policy query checks that all non-TorVPN outbound allows were really
suspended. If Windows refuses or ignores a suspension, the connection fails and
recovery restores the saved state. GroupPolicy, Generated, Hardcoded and unknown
origins remain unsupported. The tests cover suspension, restoration, provider
failure, ignored restoration, expired rules and legacy backup recovery; they
mock the Windows cmdlets and do not replace an on-PC test.

Microsoft's Dynamic examples:
https://learn.microsoft.com/en-us/powershell/module/netsecurity/disable-netfirewallrule
https://learn.microsoft.com/en-us/powershell/module/netsecurity/enable-netfirewallrule

## Install / repair

Windows 10/11 **x64**. Open PowerShell **as Administrator**, change into this
extracted directory, and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Repair.ps1
```

Prebuilt service and tray executables are in `bin/`; Rust is not required for
installation. Wintun 0.14.1 and tun2socks 2.6.0 x64 are included. Before changing
anything, the script downloads Tor Expert Bundle **15.0.26 / Tor 0.4.9.14**
(about 21 MB) and verifies its pinned SHA-256 against Tor Project's published
checksum. The outdated Tor 0.4.8.10 from the uploaded archive is not included.
If that download fails, your running installation and networking are untouched.

Then Repair.ps1:

1. Exports Windows Firewall and backs up the old install/profile/logs to
   `%ProgramData%\torvpn\backups\<timestamp>`.
2. Stops the old service, installs the complete files to `%ProgramFiles%\TorVPN`,
   and restores any recorded pending route/DNS/firewall changes.
3. Installs a clean default profile. Your prior profile stays in the backup.
4. Registers or updates the TorVPN service, starts it, and shows connection
   progress. The service connects automatically.
5. Starts the tray and registers it for the current account's future logins.

Connecting intentionally blocks direct outbound traffic. Run this locally,
not through an SSH/RDP session whose connection you need to keep alive.
Policy-managed outbound allow rules are rejected because a local service cannot
safely override domain policy. Other VPNs or firewall software can prevent Tor
from working; such failures now appear in status and the log.

Options:

```powershell
.\Repair.ps1 -NoConnect        # install/start service, leave it disconnected
.\Repair.ps1 -PreserveProfile  # keep your previous configuration; validated at startup
```

The old Inno setup EXE has been removed from this repair release to prevent
accidentally reinstalling 0.2.0. Use Repair.ps1.

## Tray controls

A status dialog opens at tray launch. Reopen it with right-click → Status/details.
There is no full settings-window UI in this project.

- Red: disconnected, service unavailable, or error. Open status for the reason.
- Amber: connecting/disconnecting; also used for diagnostic SOCKS-only mode.
- Green: the TCP tunnel connected and an ordinary Windows HTTPS request was
  confirmed by `check.torproject.org/api/ip` as a Tor exit. This is a check at
  connection time, not a continuous proof of every application's traffic.
- Left-click: connect/disconnect; click while connecting to cancel.
- Right-click: exit country, new circuits, logs, profile, and quit tray.
- Quit tray leaves the service/tunnel running. Use Disconnect to end the tunnel.

Exit choices last for the current service session, including disconnect/reconnect.
Restarting the service reloads `[exit].countries` from profile.toml. Existing
connections keep their existing circuits; a country change affects new streams.
The displayed IP is from the last connection-time check, so a NEWNYM/country
change need not immediately match it.

Entry guards are chosen by Tor. There is no manual entry-relay selector, bridge
wizard or stealth-mode UI. Bridge transport processes require extra routing and
firewall allowances and are rejected in full-tunnel mode. Upstream proxy startup,
automatic hop plans and experimental PQC settings are rejected rather than
silently providing a different connection from the one requested.

## Verify on your PC

```powershell
& "$env:ProgramFiles\TorVPN\torvpn-svc.exe" status
curl.exe -q --noproxy "*" --fail --max-time 40 https://check.torproject.org/api/ip
Get-NetAdapter -Name torvpn
Get-NetRoute -DestinationPrefix '0.0.0.0/1','128.0.0.0/1'
```

Expect status `engaged` and `full_tunnel: true`, `IsTor: true`, an up tunnel,
and both /1 routes on that tunnel. DNS is redirected to Tor on 127.0.0.1:53.
Port 53 must be free before Tor starts; a local DNS service can conflict.
`full_tunnel = false` enables diagnostic SOCKS mode and does not redirect any
ordinary application traffic or change the firewall/route/DNS settings for that
session. Its HTTPS check explicitly uses the SOCKS proxy, and the tray stays amber.

## Disconnect / recover

Use the tray's Disconnect menu item or:

```powershell
& "$env:ProgramFiles\TorVPN\torvpn-svc.exe" disconnect
```

If the service is broken, run **as Administrator**:

```powershell
& "$env:ProgramFiles\TorVPN\Recover-Network.ps1"
```

That stops the service and restores the saved policy and owned routes. Recovery
metadata is retained on cleanup failure. No global `taskkill /IM tor.exe` is used
by the new service: it stops only its own child processes.

Versions before 0.3 did not record original firewall defaults. If a pre-0.3
failure left default-deny behind and no saved backup exists, explicit opt-in to
resetting outbound defaults to the Windows factory Allow setting is available:

```powershell
.\Recover-Network.ps1 -LegacyReset
```

This option cannot reconstruct an unknown previous policy. Prefer the saved
firewall export if you had custom firewall defaults. Reboot alone does not clear
persistent NRPT/firewall rules.

## Diagnostics

```powershell
.\Get-Diagnostics.ps1
```

Creates `torvpn-diagnostic.txt` in the current directory with service state and
log tails. It does not print authentication tokens or profile credentials.
Review it before sharing: it includes local paths and network diagnostics.
Service/Tor output: `%ProgramData%\torvpn\svc.log`; bridge output:
`%ProgramData%\torvpn\tun2socks.log`; tray: `%LOCALAPPDATA%\torvpn\tray.log`.

## Build / tests

Source is complete, including Cargo.lock and Rust 1.99.1 toolchain pin. For a
native build install that Rust MSVC toolchain plus Visual Studio C++ Build Tools:

```powershell
.\Build.ps1
cargo test --locked -p torvpn-core -p torvpn-svc
pwsh -NoProfile -File .\tests\network-scripts.ps1
.\Repair.ps1
```

The bundled EXEs were cross-compiled for x86_64-pc-windows-gnu. They depend on
Windows system DLLs; they do not require a separate MinGW runtime installation.
The native Build.ps1 produces MSVC binaries and updates their release hashes.

Validation performed for this release is recorded in `VALIDATION.md`. Windows
SCM/Wintun/WFP end-to-end execution has not been performed in the build container.

## Protection boundaries

The firewall temporarily disables pre-existing Local/Dynamic outbound allow rules,
saves and restores each profile's actual default policy, allows Tor TCP,
loopback and the named tunnel, and blocks native IPv6 and direct remote DNS.
Those changes can affect unrelated applications while connected. Processes
exiting are checked every two seconds; a dead child sets Error and retains the
firewall until Disconnect/Retry. A process alive with a broken circuit may remain
green until an operation or a reconnect detects failure.

This is not a vetted anonymity product. Connection failures, explicit Disconnect,
Repair and service startup recovery restore ordinary connectivity. There is no
persistent always-on protection across boot, service crash/restart or repair;
use a separate vetted solution if that is a requirement. Local administrators
can change rules/routes, and Windows policy or other firewall products can
interfere. The HTTPS acceptance check is not a comprehensive leak audit.

Tor's current direct peers are pinned to physical-gateway /32 routes and that
session's ReachableAddresses is restricted to those peers to avoid a routing
loop. If the uplink changes or those peers become unavailable, reconnect. The
TUN subnet is 10.86.1.0/24; it must not overlap your existing LAN/VPN routing.

Sources for dependency versions, checksums and Windows rule precedence appear
in `DEPENDENCIES.md`. Third-party components retain their own licenses.

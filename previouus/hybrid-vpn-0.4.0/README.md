# whispr Hybrid VPN 0.4.0 — release candidate

A replacement for the retired TorVPN client: ordinary internet TCP through a local Tor client, UDP through a dedicated WireGuard exit on an existing VPS, system DNS over TCP through Tor. Windows 11 x64; PowerShell 7.6.x. Console client, manual start/stop, no tray or automatic boot connection.

**Build status:** source and a compiled Windows x64 firewall guard are included. PowerShell/C# compilation and backend configuration validation have been checked. The Windows WFP/TUN lifecycle, live VPS exchange, crash containment and coexistence have **not** been exercised on Windows here. Treat this as a staging build; use a Windows test VM before activating it on the repaired workstation. It is not a certified production-safe VPN or an anonymity guarantee.

## Install

The install step downloads the maintained routing engine and Tor from their upstream release sites, rejects checksum mismatches, prepares protected local files, and configures a dedicated server interface. About 56 MB of upstream archives are downloaded. It does not start the client tunnel or arm its guard.

Use your working key-authenticated SSH alias. Default: **nyc1**, provisionally chosen from your reported good performance and its already-enabled IPv4 forwarding. No latency ranking was obtained from the earlier probes. `-Server lon1`, `-Server sgp1`, and `-Server syd1` are supported alternatives.

In **PowerShell 7 as Administrator**:

```powershell
Set-Location "$env:USERPROFILE\Downloads"
Unblock-File -LiteralPath .\hybrid-vpn-0.4.0.zip
Expand-Archive -LiteralPath .\hybrid-vpn-0.4.0.zip -DestinationPath .\hybrid-vpn-0.4.0
Set-Location .\hybrid-vpn-0.4.0
.\Install.ps1 -Server nyc1
```

**The server step asks for the selected VPS account's sudo password.** Entry is hidden. The installer may install Ubuntu/Debian `wireguard-tools` and `iptables`, enables the new server tunnel at boot, and enables IP forwarding if needed. It does not reboot the server. The server needs outbound internet and public inbound **UDP 51832**. A DigitalOcean Cloud Firewall must allow that port if one is attached; local host rules cannot open the provider firewall.

The server owns `wg-whispr`, `/etc/whispr-hybrid`, `/etc/wireguard/wg-whispr.conf`, `/etc/sysctl.d/80-whispr-hybrid.conf`, and `WHISPR_H_*` iptables chains. Existing websites, Docker settings, SSH configuration, other WireGuard interfaces and global firewall policies are not rewritten. Native nftables policies or a subsequent firewall reload may still block these new rules; traffic checks must detect that rather than treating installation as connectivity proof.

Installer refuses an active Proton adapter, active old TorVPN service, a remaining root NRPT policy, ambiguous old full-tunnel WireGuard routing, or a conflicting owned interface. It does not remove another product's kill switch. Proton must release its own protection through its app before this client can function.

## Start and stop

After staging validation, start from an elevated PowerShell:

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Start.ps1"
```

The session arms a separate persistent WFP guard, starts owned Tor and routing-engine processes inside a kill-on-close job, waits for Tor bootstrap and the exact new TUN, then tests TCP/Tor and the observed UDP exit. Only then is the session marked verified. Every minute it repeats the TCP/UDP checks. A failure tears down its processes and retains protection.

**Type `stop` then Enter** for an intentional disconnect. To recover after a crash, failed start, closed window, or unexpected loss of internet, run in elevated PowerShell:

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Recover.ps1"
```

This command stops only the recorded dedicated supervisor, removes only its recorded TUN device if still present, then transactionally removes only its guard provider/filter keys. It does not reset firewall profiles, flush unrelated rules, delete another VPN adapter, run Windows repairs or request a reboot. It refuses to delete a TUN when its identity is unproved.

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Status.ps1"
```

`ARMED` means protection policy exists, not that both transports work. Stored verification timestamps are historical. Persistent guard filters can remain after a reboot; use Recover if no session is running. **No pre-BFE/early-boot protection or always-on protection is claimed.** There is no automatic client startup in this version.

## Existing tunnels and local networks

Activate existing Ollama/game WireGuard tunnels **before starting this client** so their current transport endpoints can be collected and excluded. This build reads only `wg show ... endpoints` and `allowed-ips`, not private keys or configuration files. Exact current endpoint exceptions and the official WireGuard transport executable are used. Another active full-tunnel WG configuration is refused. Endpoint changes/new tunnels during a session can require stopping and restarting Hybrid VPN to refresh the exceptions.

Private IPv4, ULA IPv6 and local-link destinations are exceptions and remain direct or on their existing more-specific private tunnels. They are **not Tor-protected**. DNS port 53 is blocked outside the protected path, including LAN DNS, so internal DNS-dependent services may need a separate reviewed policy. This package does not silently change them.

## Traffic and privacy limits

- TCP is routed through Tor; UDP is routed through your VPS. Tor relay/transport connections themselves necessarily use the physical connection.
- The VPS can associate its WireGuard peer with your source IP, and destinations see its UDP egress IP. Apps/accounts that use TCP and UDP can correlate the paths. Browser HTTP/3/QUIC uses the UDP path. Ordinary apps do not gain Tor Browser fingerprinting or per-application circuit isolation.
- System DNS uses Cloudflare's TCP resolver through Tor. Applications using their own encrypted DNS follow their TCP/UDP transport path. Tor `SafeSocks 0` is explicit because a transparent IP tunnel and this resolver make numeric-address SOCKS requests. The guard/engine, rather than SafeSocks, are responsible for preventing physical DNS fallback.
- UDP IPv6 is enabled only when the server has an IPv6 uplink and ip6tables. Otherwise IPv6 UDP is rejected, with no direct fallback. Unsupported internet protocols are rejected. Private-network exceptions remain deliberate exceptions.
- A successful STUN test checks IPv4 UDP egress and NAT, not every protocol, IPv6 egress or all leak conditions. Windows staging capture is still required. Some services block Tor or do not work through Tor exits.
- No automatic endpoint failover is implemented. Do not switch endpoints beneath a running session.
- Admin/SYSTEM are trusted. This is not intended to defend against a hostile local administrator, a compromised Tor/routing binary, or all traffic correlation. No claims of stealth based on geography.

## Files, privileges and dependencies

Program files: `%ProgramFiles%\whispr Hybrid VPN`. Only elevated execution is supported; normal users cannot execute the exempted transport binaries from this directory. Private state, generated configuration and logs: `%ProgramData%\whispr-hybrid`, administrators/SYSTEM only. Client private keys stay on the client. Server private keys stay root-only on the VPS. Each installation retains its device key on reinstall; different devices generate different peers.

Tor and sing-box are fetched directly from upstream by the installer with fixed SHA256 checks. A content-filter error page is rejected. This source package does not embed old TorVPN executables, Tor 0.4.8.10, tun2socks, or scripts that suspend unrelated firewall rules. The maintained backend still creates a Windows virtual adapter using its upstream Wintun implementation; normal OS driver installation may touch the driver store. No custom kernel driver, protected-DLL patch or Explorer hook is supplied.

No Rust compiler is needed to install. `Build-Guard.ps1` provides an optional source rebuild with Rust 1.99.1, the locked dependencies, Windows MSVC target and Visual Studio C++ tools. Source and test details are in `guard/`, `tests/`, and `docs/VALIDATION.md`.

## Removal

```powershell
& "$env:ProgramFiles\whispr Hybrid VPN\Uninstall.ps1"
```

Private local state is retained by default. Add `-DeleteLocalKeys` only if you want to discard this device key. The VPS peer is separately managed; uninstalling one client must not disconnect other devices.

On the selected server, to revoke one public key:

```bash
sudo python3 -I /etc/whispr-hybrid/manage.py --revoke-public-key 'THE_REGISTERED_PUBLIC_KEY'
```

To remove the dedicated server exit:

```bash
sudo python3 -I /etc/whispr-hybrid/manage.py --remove-server
```

With multiple registered devices, server removal requires `--all-clients`. Root-only state/backups are retained. Forwarding remains enabled on server removal to avoid disabling another project that may now depend on it; no global firewall or network reset is performed.

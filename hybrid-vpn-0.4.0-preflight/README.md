# Hybrid VPN 0.4.0 — preflight

This is the first preparation stage for TCP over Tor plus UDP over a dedicated WireGuard VPS exit. It is **not a completed VPN release**. No automatic upgrade from the old TorVPN is performed.

## Run

Requires Windows 11, PowerShell 7, the existing OpenSSH client/known-host entries and working aliases nyc1/lon1/sgp1/syd1. Python 3 and ordinary Linux networking tools are expected on the VPSs. Run on the Windows machine that will use the VPN, in an ordinary PowerShell window:

```powershell
Set-Location "$env:USERPROFILE\Downloads"
Expand-Archive -LiteralPath .\hybrid-vpn-0.4.0-preflight.zip -DestinationPath .\hybrid-vpn-0.4.0-preflight
Set-Location .\hybrid-vpn-0.4.0-preflight
.\Preflight.ps1
```

Send back the `HybridVPN-Preflight-*.zip` printed at the end. No administrator or sudo password is requested. Passwordless SSH means key authentication already works; this script does not alter SSH configuration or load/remove keys. Locked keys requiring interactive prompts may result in an unresolved endpoint; other endpoint checks continue.

The report contains routes, addresses, adapter metadata, DNS settings and readable firewall configuration. It does not read WireGuard private keys or configuration files. Review the report before sharing if network addressing is sensitive.

## What it does

- Reads current Windows networking, relevant service/process metadata, effective firewall profile defaults and NRPT policy.
- Connects to each requested VPS using your existing aliases.
- Briefly runs an unprivileged UDP echo listener with a random per-server token on port 51831. Replies are bounded and no larger than requests. A listener exits after a maximum 20-second receive window, even if the Windows process disappears.
- Takes eight small UDP RTT/loss samples per reachable server. This is a short path check, not a statistically robust throughput benchmark or a WireGuard handshake.
- Reads Linux routes, addresses, listeners, forwarding flags and whatever firewall configuration is readable with `sudo -n`. Lack of permission is reported without prompting. No need to change sudo policy.
- Writes a ZIP in Downloads. No firewall openings, forwarding changes, package installation, network reset, SFC, DISM or CHKDSK operation.

Do not disable a firewall to get a successful probe. A blocked probe means that firewall/path needs inspection; it is not evidence that a region is unsuitable. ProxyJump and existing VPNs can change which path/address is measured. No endpoint is automatically selected or installed.

## Replacement contract

1. Ordinary internet TCP uses Tor; ordinary internet UDP uses a dedicated WireGuard exit. DNS must have an explicit protected path. ICMP/unsupported protocols need an explicit policy rather than implicit direct fallback.
2. The two transports can be correlated when an application uses both. UDP leaving a VPS is not Tor-anonymous. A remote country or an otherwise quiet server is not proof of stealth. These four servers share a provider/account trust boundary.
3. Exact adapter ownership; no first-Wintun selection. Existing Ollama and game tunnels must retain their intended routes. LAN/private-route exceptions must be documented, not silently advertised as Tor-protected.
4. No disabling unrelated firewall rules or rewriting all firewall profile defaults. A machine-wide fail-closed policy still needs deliberately owned enforcement; a routing rule or DNS-only filter is not a crash-proof kill switch.
5. Bootstrap/handshake verification before connected status. Separate TCP exit verification, WireGuard handshake/UDP verification and DNS/leak tests. Crash tests must show ordinary traffic cannot fall back directly while protection is armed.
6. Explicit disconnect restores normal networking. Failure of a component while connected must retain protection. Recovery removes only app-owned changes, with checked restoration and retained failure evidence.
7. No automatic start at boot until staging checks pass. No claims that Linux/static checks prove Windows safety.

A maintained routing backend is under evaluation. Its Windows behavior, kill-switch implementation, license, pinned binaries and preservation of existing routes must be verified before committing to a deployable build. This package does not silently substitute an untested routing engine for the old service.

## Endpoint decision

NYC is a candidate, not a predetermined winner. Compare actual UDP loss/RTT, available resources, existing firewall/service compatibility and the intended privacy boundary. London may be fastest; Singapore/Sydney may be preferred for location at the cost of latency. None is automatically more anonymous because it is farther away. No live server measurements have been made from the affected Windows machine until this script runs.

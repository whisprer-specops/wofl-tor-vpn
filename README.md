# TorVPN

A Windows-native, ProtonVPN-style one-click VPN that routes all traffic
through Tor. Click the tray icon → green, click again → off. Tor is bundled,
the kill-switch is automatic, the DNS lock is automatic, and the profile is
tuned for **speed** under the assumption that Tor's own anonymity baseline is
sufficient for most users.

## At a glance

```
┌─────────────────────────────────────────────────────────────────┐
│  System tray                                                    │
│    ┌─────────┐                                                  │
│    │  ●  Tor │ ←──── click to toggle (red⇄green)                 │
│    └─────────┘                                                  │
│         │ HTTP 127.0.0.1:8787 (bearer-token auth)                │
│         ▼                                                       │
│  torvpn-svc.exe  (Windows service, LocalSystem, idle by default) │
│         │                                                       │
│         ├─► tor.exe              (SOCKS + DNSPort + ControlPort) │
│         ├─► tun2socks.exe        (Wintun ↔ SOCKS bridge)         │
│         ├─► Windows Firewall     (kill-switch — block all except Tor + Wintun) │
│         └─► NRPT + DNS rules     (every lookup → 127.0.0.1:5353) │
└─────────────────────────────────────────────────────────────────┘
```

## Project layout

```
torvpn-new/
├─ Cargo.toml                  workspace root, release-tuned profile
├─ crates/
│  ├─ torvpn-core/             shared library
│  │  └─ src/
│  │     ├─ config.rs          TOML profile loader (incl. [perf] section)
│  │     ├─ tor_manager.rs     speed-tuned torrc + tor.exe supervisor
│  │     ├─ tun2socks_mgr.rs   Wintun bridge
│  │     ├─ firewall.rs        kill-switch (calls PowerShell)
│  │     ├─ nrpt.rs            DNS lock
│  │     ├─ tor_control.rs     Tor ControlPort client (NEWNYM, SETCONF, GETINFO)
│  │     ├─ state.rs           Engagement state machine + JSON snapshot
│  │     ├─ control_server.rs  HTTP API (tray + CLI talk to this)
│  │     ├─ api.rs             typed HTTP client (no reqwest dep)
│  │     ├─ auth.rs            bearer-token + optional HMAC
│  │     ├─ paths.rs           canonical %ProgramData%-rooted paths
│  │     ├─ hop_plan.rs        country/proxy rotation scheduler
│  │     ├─ proxy_manager.rs   upstream proxy chain persistence
│  │     └─ pqc.rs             post-quantum signing (feature-gated)
│  │
│  ├─ torvpn-svc/              service binary + CLI
│  │  └─ src/
│  │     ├─ main.rs            clap CLI; subcommands: connect, disconnect,
│  │     │                     toggle, status, newnym, exit-set, exit-clear,
│  │     │                     service-install, service-uninstall, service-run
│  │     └─ service.rs         Windows SCM dispatcher
│  │
│  └─ torvpn-tray/             user-mode tray icon
│     └─ src/main.rs           tao + tray-icon; menu, status polling, icons
│
├─ profiles/
│  ├─ default_win.toml         speed-first defaults
│  └─ obfs4_win.toml           bridge mode example
│
├─ scripts/
│  ├─ fw-apply.ps1             firewall kill-switch
│  ├─ fw-teardown.ps1
│  ├─ dns-apply.ps1            NRPT + 53/UDP block
│  └─ dns-teardown.ps1
│
├─ installer/
│  ├─ installer.iss            Inno Setup script
│  ├─ stage.ps1                downloads Tor + tun2socks + Wintun
│  └─ README.md                build instructions
│
└─ assets/
   ├─ icons/                   tray icons (generated at build time too)
   └─ tor/torrc.template       reference torrc
```

## Speed-first design choices

The default profile leans into Tor's speed knobs:

| Knob                          | Default | Effect                          |
|-------------------------------|---------|---------------------------------|
| `parallel_socks_ports`        | 4       | 4 isolated circuit pools per session, rotated by tun2socks |
| `circuit_build_timeout_secs`  | 10      | Drop slow circuits aggressively |
| `num_entry_guards`            | 3       | Wider fast-path pool            |
| `ipv4_only`                   | true    | Skip slow IPv6 happy-eyeballs   |
| `disable_padding`             | true    | Latency win                     |
| `MaxCircuitDirtiness`         | 600s    | Reuse hot circuits longer       |

This is the difference between "Tor is slow" (vanilla defaults) and "Tor is
fine for everyday browsing" (these defaults). Real-world feel is close to a
mid-tier commercial VPN once a circuit warms up.

## State machine

`state.rs` exposes `Engagement` with phases:

```
Disengaged ──connect()──► Engaging ──ok──► Engaged
     ▲                       │                │
     │                       err              │
     │                       ▼                │
     │                    Error               │
     │                                        │
     └─────────disconnect()◄──── Disengaging──┘
```

Every transition is mirrored to `%ProgramData%\torvpn\state.json` so the tray
can recover after a service restart. `connect()` and `disconnect()` are
idempotent — clicking the tray twice during boot won't double-spawn tor.

The connect order is firewall → DNS lock → tor → tun2socks, with full
rollback if any step fails. Disconnect tears down in reverse, plus a
belt-and-braces `taskkill` so a wedged child process can't leave the
firewall locked.

## Building (developer install, no installer)

```powershell
# from a Visual Studio "x64 Native Tools Command Prompt"
cargo build --release -p torvpn-svc
cargo build --release -p torvpn-tray

# Install the service (admin)
target\release\torvpn-svc.exe service-install

# Launch the tray
start target\release\torvpn-tray.exe
```

For the redistributable installer, see [`installer/README.md`](installer/README.md).

## Tray behaviour

* **Left-click** the icon — toggle engagement.
* **Right-click** — menu with NEWNYM, exit country, quit.
* **Icon colour** — red (off), amber (engaging / disengaging),
  green (engaged), bright red flashing (error / service unreachable).
* **Tooltip** — current phase + exit IP if available.

The tray uses no reqwest, no system webview, no electron. ~2 MB compiled.

## Configuration

The bundled default profile is enough for most users. To override, drop a
file at `%ProgramData%\torvpn\profile.toml` and restart the service. See
[`profiles/default_win.toml`](profiles/default_win.toml) for the full schema.

## Security stance

Threat model: defeat passive ISP-level surveillance and reach blocked
content. **Not** designed to defeat targeted state-level adversaries — that's
Tor Browser's job (browser-level fingerprinting matters more than the
transport at that threat level). The speed-first profile turns off circuit
padding; raise it if your threat model includes traffic-analysis attackers.

Auth token at `%ProgramData%\torvpn\api_token` is world-readable so the
user-mode tray can read what the LocalSystem service writes. This is fine on
single-user machines; on shared hosts, lock it down or run the service as
the same user as the tray.

## Licence

GPLv3 (matches Tor's licence — bundling Tor under any more permissive
licence isn't an option).

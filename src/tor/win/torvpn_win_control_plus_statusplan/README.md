# torvpn-win (MVP)
Windows skeleton for a Tor-routed VPN using an external `tun2socks.exe` that supports Wintun.

## Requirements
- Windows 10/11
- Rust stable
- `tor.exe` installed (Tor Browser or Tor Expert Bundle), available in PATH or specify `tor_path_hint` in profile
- `tun2socks.exe` (go-tun2socks build for Windows) in PATH, with `wintun.dll` present

## Build
```
cargo build --release
```

## Run
```
# Default profile
.\target\release\torvpn-win.exe start

# With obfs4 profile
.\target\release\torvpn-win.exe --profile .\profiles\obfs4_win.toml start

# Status / Stop
.\target\release\torvpn-win.exe status
.\target\release\torvpn-win.exe stop
```

## What it does
- Generates `torrc` from profile and starts Tor; waits until Tor reports Bootstrap 100%.
- Starts `tun2socks.exe` with `-device wintun://torvpn -proxy socks5://127.0.0.1:9050 -mtu 1400`.
- Applies Windows Firewall rules to block outbound traffic except:
  - Tor program
  - Wintun adapter
- On `stop`: kills processes and removes firewall rules.

## Notes
- Adapter naming: set `[tun].interface` in the profile to your preferred Wintun adapter name (e.g., "torvpn").
- If your `tun2socks.exe` requires a different flag syntax, adjust `src/tun2socks_manager.rs` accordingly.
- DNS: Tor’s DNSPort (127.0.0.1:5353) is used by applications that resolve via the tunnel. For system-wide DNS enforcement, we can add NRPT rules or block port 53 except via Tor; that’s slated as a follow-up.

## Legitimate use only
This is privacy software intended for lawful purposes (censorship resistance, personal privacy). No illegal use.


## Windows Service
You can run torvpn-win as a native Windows service.

### Quick install (PowerShell, Admin)
```
# From project root after `cargo build --release`
.\scripts\install-service.ps1 -Binary .\target\release\torvpn-win.exe -Profile .\profiles\default_win.toml
# or use obfs4 profile:
# .\scripts\install-service.ps1 -Binary .\target\release\torvpn-win.exe -Profile .\profiles\obfs4_win.toml

# Check:
sc.exe query TorVPN
Get-Service TorVPN
```

### Manual install via CLI
```
.\target\release\torvpn-win.exe ServiceInstall
# To run under SCM, the service dispatcher calls:
# torvpn-win.exe ServiceRun
# (ServiceInstall configures this automatically via sc.exe)
```

### Uninstall
```
.\scripts\uninstall-service.ps1
# or
.\target\release\torvpn-win.exe ServiceUninstall
```


## Tor control (CLI)
These commands work even when running as a service (they talk to the ControlPort).

```
.\target\release\torvpn-win.exe newnym
.\target\release\torvpn-win.exe circuits
.\target\release\torvpn-win.exe health
```


## Local HTTP control
When `[status].enabled = true`, a tiny HTTP server runs on `listen` (default `127.0.0.1:8787`).

- `GET /status` → JSON snapshot
- `POST /control/newnym` → rotate Tor circuits

Auth: token stored at `%LOCALAPPDATA%\torvpn\api_token` (created on first start).

PowerShell:
```
$tok = Get-Content "$env:LOCALAPPDATA\torvpn\api_token"
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8787/control/newnym -Headers @{ "X-TorVPN-Token" = $tok }
```


### Control API
PowerShell examples:

```
$tok = Get-Content "$env:LOCALAPPDATA\torvpn\api_token"

# NEWNYM
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8787/control/newnym -Headers @{ "X-TorVPN-Token" = $tok }

# Proxy rotate
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8787/control/proxynext -Headers @{ "X-TorVPN-Token" = $tok }

# Set exits (comma-separated cc) or clear with cc=
Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8787/control/exitset?cc=us,de" -Headers @{ "X-TorVPN-Token" = $tok }
```


### Extra control endpoints
- `POST /control/proxynext` — rotate to next upstream proxy + NEWNYM
- `POST /control/exitset?cc=us,de` — set ExitNodes and StrictNodes=1 + NEWNYM
- `POST /control/exitclear` — clear ExitNodes/StrictNodes + NEWNYM

### Status endpoints
- `GET /status` — live exit IP, current hop, seconds remaining
- `GET /status/plan` — hop plan state (current index, randomized order, next hops)

### Auth and security
- All control endpoints require the token header: `X-TorVPN-Token: <token>` (or `Authorization: Bearer <token>`).
- Optional HMAC header for remote binds: `X-TorVPN-HMAC: <ts>:<hex(hmac_sha256(secret, ts||method||path))>`
  - Secret is stored next to the token as `api_hmac_secret` (auto-generated on first run).
  - `ts` is a UNIX epoch seconds; we accept ±300s clock skew.
- If you bind `listen` to anything other than `127.0.0.1`, a simple rate limiter kicks in (per-IP): 5 req/sec and 120 req/min, returning HTTP 429 on overflow.

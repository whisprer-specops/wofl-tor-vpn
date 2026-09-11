ok fren - everybody's fav time - yet again it's NEW PROJECT OOOOOOOCOOOOOCKKKL!!!! \\o/

so, this time we're building an ultra stealth tor routed vpn! :O \[ooooh! wowwwww! etc.] and i've gotten you p much all the necessary ingreients to not jsut get you going but provide dman fine solutions ot complex issues fsancy bit sand much much more besides:

\- there's a few lil odds'n'sods from our very ghostmdoe vanisher;

\- an actual TOR based vpn but somewhat differnet to our sestinaton but we can lift heavily froom it \[inviZible]

\- quantuum encryption program code jus tto really let us have the best going

\- and finally but not least, my own early foray into tor tunnelling etc. the sneaksy emails softwares.

so, without furher ado lets have a look though our materials and see quite what we've got eh?









Heh. Alright, Captain OOOOCOOOOCKKKL, I pulled the four payloads apart and built you a clean inventory so we can see what’s actually in the crates before we start bolting on stealth fins and Tor turbines.



I’ve extracted and indexed everything, and dropped three handy views for you:



“Uploaded Archives Overview” — hashes, sizes, and where each archive was unpacked



“Repo Inventory Summary” — file/dir counts, language mix by extension, and notable build/config files auto-detected



“Notable README/Notes Snippets” — quick skim of any READMEs/NOTES I found



I also generated a concise markdown report with compact trees (depth ≤ 2) for each bundle so you can eyeball structure fast:

Download the audit report



If you want me to dive deeper next (e.g., enumerate Tor configs, service launchers, network/crypto primitives, or threat-model hotspots), say the word and I’ll produce a targeted breakdown with a proposed architecture. High-level plan I’m aiming for (privacy-friendly, legit use only):



Clean split: transport (Tor), VPN layer (TUN/TAP), controller/daemon, UI/CLI.



Single-hop and “bridged” modes with pluggable transports (obfs4/meek where lawful).



Strict DNS and route leak prevention.



Minimal on-disk footprint + reproducible builds.



Configurable identities/profiles, but no “bypass monitoring” nonsense. This is for privacy, not crime.



Your move, fren: pick what you want me to analyze first—GhostMode carry-overs, InviZible bits to lift, the “quantum” code for where it actually makes sense (or doesn’t), or the sneaky mailer’s tunneling pieces. I’ll slice it accordingly and return a concrete, production-ready module map.







Concrete implementation plan (1–2 day sprint to MVP)

tor\_manager

Ship platform Tor binaries; generate torrc from profile; bring up Tor; poll ControlPort until BOOTSTRAP 100.

Export SocksPort, DNSPort, TransPort (optional) to other modules.

tun2socks

Use a Rust tun driver (Linux tun, Windows Wintun).

Bind tun2socks to Tor’s SocksPort for TCP+UDP.

IP address: assign a private /30 to TUN (e.g., 10.111.0.1/30).

route\_guard + leak\_killswitch

Linux: apply nftables rules; Windows: firewall rules tied to adapter/Tor process.

Verify with connectivity probes; fail-closed if Tor dies.

dns\_guard

Set OS resolv (Linux) to 127.0.0.1:5353 during session; Windows use NRPT or block port 53 except TUN/Tor.

Optional: run dnscrypt-proxy behind Tor’s SOCKS (advanced profile).

profile\_manager + CLI

profiles/default.toml (baseline), profiles/obfs4.toml (stealth), profiles/transproxy.toml (Linux).

CLI: torvpn start --profile obfs4, torvpn stop, torvpn status, torvpn leaktest.

How I’ll use the InviZible code specifically

Extract exact torrc options and pluggable transport declarations from the configs you saw in “Config Excerpts” and turn them into our templated profiles.

Port any iptables scripts you spotted (see “Keyword Hits”) to nftables rules (Linux) and produce equivalent Windows firewall rules.

Reuse bridge management UX/logic (file formats, rotation cadence).

Mirror bootstrap status parsing and connection retry backoff patterns.

If there’s a VpnService-style tun code path, treat it as a conceptual reference for how they handle MTU, MSS clamping, and per-app include/exclude; implement equivalent in our Rust tun2socks.





Nice. I’ve shipped you a runnable Linux MVP skeleton in Rust that wires up:



tor\_manager: generates torrc from a profile, launches Tor, watches bootstrap progress



tun2socks\_manager: launches an external tun2socks binary bound to Tor’s SOCKS



nftables: fail-closed rules to stop leaks while the VPN is active



CLI: start | stop | status with profile selection



Grab it here:

Download torvpn\_skeleton\_linux\_rust.zip



What’s inside (top bits)



src/tor\_manager.rs — Tor lifecycle; torrc generated from TOML profile



src/tun2socks\_manager.rs — runs tun2socks -device tun://tun0 -proxy socks5://127.0.0.1:9050 -mtu 1400



src/nftables.rs — tight allowlist: allow loopback, TUN, and localhost access to Tor ports; drop DNS leaks



src/config.rs — profiles loader (TOML)



profiles/default.toml and profiles/obfs4.toml



scripts/\*.sh — manual helpers for TUN + nftables if you want to poke around by hand



Requirements (Linux)



tor in PATH



tun2socks binary in PATH (e.g. go-tun2socks)



iproute2 + nftables



TUN support (/dev/net/tun)



Build

cd torvpn

cargo build --release



Run (baseline)

sudo ./target/release/torvpn start

\# or with a profile

sudo ./target/release/torvpn --profile profiles/obfs4.toml start



./target/release/torvpn status

sudo ./target/release/torvpn stop



How it behaves



On start:



Applies nftables rules (fail-closed)



Creates tun0 and assigns 10.111.0.1/30



Starts Tor with a generated torrc (SOCKS 9050, DNS 5353, Control 9051)



Starts tun2socks pointing at Tor’s SOCKS



Stores PIDs under ~/.local/share/torvpn/pids.json



On stop: kills tun2socks + Tor, removes tun0, flushes nftables



Notes



This MVP keeps it simple and safe. DNS goes through Tor’s DNSPort; UDP is handled via tun2socks.



Transparent mode (Tor TransPort) can be added later; for now we’re using the clean tun2socks path.



Bridges/obfs4: enable in profiles/obfs4.toml and add your bridge lines; tor\_manager will honor them.



Next upgrades I can add on your cue



ControlPort cookie auth + circuit/guard policy controls via Tor’s control protocol



nftables “owner” matching (dedicated tor user) and per-UID isolation



Windows Wintun support with equivalent firewall rules



Health probes + leak tests + structured logs



Systemd unit with sandboxing







cargo build --release



Always show details



\## Run



Default profile



.\\target\\release\\torvpn-win.exe start



With obfs4 profile



.\\target\\release\\torvpn-win.exe --profile .\\profiles\\obfs4\_win.toml start



Status / Stop



.\\target\\release\\torvpn-win.exe status

.\\target\\release\\torvpn-win.exe stop



Always show details



\## What it does

\- Generates `torrc` from profile and starts Tor; waits until Tor reports Bootstrap 100%.

\- Starts `tun2socks.exe` with `-device wintun://torvpn -proxy socks5://127.0.0.1:9050 -mtu 1400`.

\- Applies Windows Firewall rules to block outbound traffic except:

&nbsp; - Tor program

&nbsp; - Wintun adapter

\- On `stop`: kills processes and removes firewall rules.



\## Notes

\- Adapter naming: set `\[tun].interface` in the profile to your preferred Wintun adapter name (e.g., "torvpn").

\- If your `tun2socks.exe` requires a different flag syntax, adjust `src/tun2socks\_manager.rs` accordingly.

\- DNS: Tor’s DNSPort (127.0.0.1:5353) is used by applications that resolve via the tunnel. For system-wide DNS enforcement, we can add NRPT rules or block port 53 except via Tor; that’s slated as a follow-up.



\## Legitimate use only

This is privacy software intended for lawful purposes (censorship resistance, personal privacy). No illegal use.

'''



\# Write files

(root / "Cargo.toml").write\_text(cargo\_toml)

(root / "src" / "main.rs").write\_text(main\_rs)

(root / "src" / "tor\_manager.rs").write\_text(tor\_manager\_rs)

(root / "src" / "tun2socks\_manager.rs").write\_text(tun2socks\_rs)

(root / "src" / "firewall.rs").write\_text(firewall\_rs)

(root / "src" / "config.rs").write\_text(config\_rs)

(root / "profiles" / "default\_win.toml").write\_text(profile\_default)

(root / "profiles" / "obfs4\_win.toml").write\_text(profile\_obfs4)

(root / "assets" / "tor" / "torrc.template").write\_text(tor\_template)

(root / "scripts" / "fw-apply.ps1").write\_text(fw\_apply\_ps1)

(root / "scripts" / "fw-teardown.ps1").write\_text(fw\_teardown\_ps1)

(root / "README.md").write\_text(readme)



\# Zip it

zip\_path = Path("/mnt/data/torvpn\_win\_skeleton\_rust.zip")

if zip\_path.exists():

&nbsp;   zip\_path.unlink()

with zipfile.ZipFile(zip\_path, "w", zipfile.ZIP\_DEFLATED) as zf:

&nbsp;   for path in root.rglob("\*"):

&nbsp;       zf.write(path, path.relative\_to(root))



zip\_path.as\_posix()



Result

'/mnt/data/torvpn\_win\_skeleton\_rust.zip'



Windows skeleton locked and loaded, fren. This mirrors the Linux MVP but with a clean Windows pathway:



tor\_manager: launches tor.exe, generates torrc, waits for Bootstrap 100%



tun2socks\_manager: launches a Windows tun2socks.exe that uses Wintun (-device wintun://torvpn)



firewall: applies/tears down strict Windows Firewall rules (allow Tor + the Wintun adapter, block everything else)



CLI: start | stop | status with profile selection



Download:

torvpn\_win\_skeleton\_rust.zip



What you need on Windows



Tor (Tor Browser or Expert Bundle) on PATH (or set tor\_path\_hint in the profile)



A tun2socks.exe build that supports Wintun (and wintun.dll alongside it)



PowerShell available (default on Win10/11)



Build

cd torvpn\_win

cargo build --release



Run

.\\target\\release\\torvpn-win.exe start

\# or

.\\target\\release\\torvpn-win.exe --profile .\\profiles\\obfs4\_win.toml start



.\\target\\release\\torvpn-win.exe status

.\\target\\release\\torvpn-win.exe stop



Profiles



profiles/default\_win.toml — baseline



profiles/obfs4\_win.toml — flip use\_bridges=true, set client\_transport\_plugin path if you’re using obfs4proxy, paste bridge lines.



What it does (at a glance)



Applies a fail-closed firewall group (“TORVPN”): Block All outbound, then Allow only tor.exe and traffic bound to the Wintun adapter whose name matches your profile’s \[tun].interface (default: torvpn).



Starts Tor with a generated torrc: SOCKSPort 9050, DNSPort 5353, ControlPort 9051.



Starts tun2socks: tun2socks.exe -device wintun://torvpn -proxy socks5://127.0.0.1:9050 -mtu 1400.



Writes PIDs to %LOCALAPPDATA%\\torvpn\\pids.json.



stop kills the PIDs and removes firewall rules.



Next upgrades I can wire in



NRPT rules / DNS lock so Windows can’t leak DNS over port 53



Tor control-protocol options (circuit policies, newnym, health probes)



System tray + auto-elevated start/stop



Installer that bundles a known-good tun2socks.exe + wintun.dll



Call the shot: want DNS enforcement on Windows next, or do we hop back to Linux to add TransPort transparent mode and owner-matched nftables?







Done. I bolted on a real DNS leak clamp for Windows using NRPT + firewall:



NRPT: system-level rule for “.” → 127.0.0.1, so Windows prefers loopback for all DNS lookups.



Adapter DNS: sets your Wintun adapter’s DNS server to 127.0.0.1 as a belt-and-suspenders.



Firewall: blocks outbound UDP/TCP 53 globally, then allows only loopback 127.0.0.1:53 and Tor’s DNSPort (default 127.0.0.1:5353).



Download the updated project:

torvpn\_win\_skeleton\_rust\_with\_dnslock.zip



What changed



src/nrpt.rs — applies/tears down NRPT + DNS firewall via PowerShell



src/main.rs — calls nrpt::apply\_dns\_lock() before Tor starts, and tears it down on stop



scripts/dns-apply.ps1 — adds NRPT rule “TORVPN Default” for namespace “.”, sets Wintun DNS to 127.0.0.1, and adds DNS block/allow rules



scripts/dns-teardown.ps1 — removes the NRPT rule and DNS firewall rules



How it behaves now (Windows)



start:



Apply NRPT + DNS lock (routes all DNS to 127.0.0.1, blocks port 53 except loopback)



Apply firewall fail-closed rules (Block All except Tor + Wintun)



Start Tor (SOCKS 9050 / DNS 5353 / Control 9051)



Start tun2socks (Wintun adapter)



stop:



Kill tun2socks + Tor



Remove NRPT + DNS rules



Remove firewall rules



Notes and pitfalls



NRPT requires admin. Your start run should be elevated for rules to apply.



NRPT is per-host, so if you’re running other VPNs concurrently, expect conflicts.



Some corp policies (GP) can override NRPT; the script won’t fight GPO, it’ll log success if local rules applied.



Apps hardcoding remote DNS servers will be blocked by the firewall rules; they’ll need to use system resolution (which now loops back to Tor’s DNSPort).



If you want, I can add:



NRPT “exclusions” (e.g., allow local LAN domains to bypass Tor DNS, still no leakage off-LAN)



A dns status subcommand that prints current NRPT + firewall DNS rules



Unit tests for the Rust wrapper modules







Pulled back, zoomed out, and wired in Transparent Mode on Linux using Tor’s TransPort + nftables redirect. This gives you two switchable architectures:



tun2socks mode (default): TUN adapter → tun2socks → Tor SOCKS



transparent mode: system traffic transparently redirected via nftables to Tor TransPort and DNSPort (no TUN, no tun2socks)



Download the updated Linux project:

torvpn\_linux\_with\_transparent\_mode.zip



What changed

Config (new \[net] block + trans\_port)



profiles/default.toml now starts with:



\[net]

mode = "tun2socks"



\[tor]

trans\_port = 9040





New profile: profiles/transparent.toml



\[net]

mode = "transparent"



\[tor]

socks\_port = 9050

trans\_port = 9040

dns\_port = 5353

control\_port = 9051





(We keep \[tun] for symmetry; it’s unused in transparent mode.)



tor\_manager.rs



Emits TransPort 127.0.0.1:<trans\_port> when \[net].mode == "transparent".



nftables.rs



If transparent:



prerouting (nat): redirect incoming TCP to :TransPort



output\_nat (nat): redirect locally-originated TCP to :TransPort



Redirect UDP:53 to :DNSPort



Filter output stays fail-closed, allowing loopback and Tor ports



If tun2socks (unchanged): only allow loopback, TUN, and Tor localhost ports; drop UDP/53 to prevent DNS leaks.



main.rs



Branches by mode:



tun2socks: create TUN, start Tor, start tun2socks, save TUN/t2s PIDs.



transparent: skip TUN and tun2socks; start Tor + nftables redirect only; save PIDs (tun2socks PID set to 0).



How to run transparent mode



Build as before:



cd torvpn

cargo build --release





Start with the new profile:



sudo ./target/release/torvpn --profile profiles/transparent.toml start

./target/release/torvpn status

sudo ./target/release/torvpn stop



Notes, tradeoffs, and next steps



Transparent mode relies on nftables NAT redirect; it will catch most TCP and system DNS and funnel them into Tor (TransPort, DNSPort). That’s cleaner for whole-box routing with minimal moving parts.



UDP beyond DNS is not proxied by Tor; that’s expected. If you need UDP apps, use tun2socks mode instead (it can translate UDP to SOCKS UDP).



If you want per-UID or per-cgroup isolation (e.g., only some processes forced through Tor), we can extend nft rules to match by owner/cgroup2.



We can add bridge/obfs4 profiles to transparent mode too; it already honors use\_bridges.



Pick your poison for the next big chunk:



Harden transparent mode with owner matching (tor user only) + LAN exceptions



Add a systemd unit with sandboxing and automatic recovery



Implement Tor control protocol (signal NEWNYM, circuit policies, health) across both modes







Alright, big-boy blocks delivered:



Tor Control Protocol wired in (NEWNYM, circuits, health) across both modes



Long-running daemon mode that auto-recovers if Tor/control becomes unhealthy



Hardened systemd unit with sandboxing and restart-on-failure



Simple installer script to drop the binary, profile, and unit in the right places



Download:

torvpn\_linux\_with\_control\_and\_systemd.zip



What’s new

Tor control (cookie auth via ControlPort)



New module: src/tor\_control.rs



connect(127.0.0.1:<control\_port>, control\_auth\_cookie)



signal\_newnym()



circuits() (GETINFO circuit-status)



health\_summary() (bootstrap, listeners, circuit-established, traffic stats)



set\_conf(key=value) and get\_info(key) helpers



CLI additions (work in both transparent + tun2socks modes):



./torvpn newnym

./torvpn circuits

./torvpn health



Long-running daemon with auto-recovery



New subcommand: daemon



Starts with your profile, then loops: every 10s checks Tor control health; if it fails, it tears down and restarts cleanly.



This is what the systemd unit runs.



systemd unit + installer



systemd/torvpn.service (Type=simple, Restart=always)



Sandboxing: NoNewPrivileges, ProtectSystem=strict, PrivateTmp, ProtectKernel\*, RestrictNamespaces, MemoryDenyWriteExecute, minimal caps (CAP\_NET\_ADMIN, CAP\_NET\_RAW, CAP\_SYS\_ADMIN for nft/TUN work).



install-systemd.sh



Installs /usr/local/bin/torvpn



Installs profile to /etc/torvpn/profile.toml



Installs unit to /etc/systemd/system/torvpn.service



Enables + starts service



Config + state



Control cookie read from: ~/.local/share/torvpn/tor-data/control\_auth\_cookie



Control port: from your profile (\[tor].control\_port, default 9051)



Works regardless of \[net].mode: transparent or tun2socks



How to use it



Build:



cd torvpn

cargo build --release





Install as a service (uses the current profile; swap in profiles/transparent.toml to run transparent mode under systemd):



sudo ./install-systemd.sh ./target/release/torvpn profiles/transparent.toml

\# or

sudo ./install-systemd.sh ./target/release/torvpn profiles/default.toml





Check status / logs:



systemctl status torvpn

journalctl -u torvpn -e





Manual control (without systemd):



sudo ./target/release/torvpn --profile profiles/transparent.toml daemon

\# and in another terminal:

./target/release/torvpn health

./target/release/torvpn circuits

./target/release/torvpn newnym



Notes / caveats



The unit currently runs as root to manage nftables/TUN. Next step is splitting privileges:



Pre-create TUN + nft rules with a helper (root) and run the main daemon as a dedicated user (torvpn) with CAP\_NET\_ADMIN only.



The control module uses cookie auth (safe default); if you later enable HashedControlPassword, we can support that too.



The daemon’s health loop is intentionally simple. We can extend to:



Verify TransPort/DNSPort sockets are up



Check status/circuit-established=1



Run a Tor .onion reachability probe before declaring healthy



Want me to:



Split privileges and drop CAP\_SYS\_ADMIN, or



Add a Windows service next that mirrors daemon + control features, or



Bake in a leaktest command that tries a couple endpoints and confirms no clearnet egress?





From project root after cargo build --release

.\scripts\install-service.ps1 -Binary .\target\release\torvpn-win.exe -Profile .\profiles\default_win.toml

or use obfs4 profile:
.\scripts\install-service.ps1 -Binary .\target\release\torvpn-win.exe -Profile .\profiles\obfs4_win.toml
Check:

sc.exe query TorVPN
Get-Service TorVPN

Always show details

### Manual install via CLI


.\target\release\torvpn-win.exe ServiceInstall

To run under SCM, the service dispatcher calls:
torvpn-win.exe ServiceRun
(ServiceInstall configures this automatically via sc.exe)
Always show details

### Uninstall


.\scripts\uninstall-service.ps1

or

.\target\release\torvpn-win.exe ServiceUninstall

Always show details
'''
readme_path.write_text(readme)

# 7) Zip updated project
zip_path = Path("/mnt/data/torvpn_win_with_service.zip")
if zip_path.exists():
    zip_path.unlink()
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
    for path in root.rglob("*"):
        zf.write(path, path.relative_to(root))

zip_path.as_posix()

Result
'/mnt/data/torvpn_win_with_service.zip'

Service mode delivered for Windows—native, clean, and mirrors the daemon + Tor control flow.

Download:
torvpn_win_with_service.zip

What you’ve got now
Native Windows Service

Module: src/service.rs using windows-service

Service name: TorVPN

Runs our same daemon loop under the SCM (Service Control Manager)

Listens for Stop and shuts down cleanly

Tor control on Windows

src/tor_control.rs (NEWNYM, circuits, get_info, set_conf, health_summary)

Same API surface as Linux version

CLI additions

ServiceInstall — creates the Windows service via sc.exe with binPath= "<exe> ServiceRun"

ServiceUninstall — stops and deletes the service

ServiceRun — entry point invoked by SCM (do not run manually; SCM calls it)

Scripts for easy setup

scripts\install-service.ps1 — copies binary + profile to C:\ProgramData\torvpn, installs service, sets auto-start, adds restart-on-failure, starts it

scripts\uninstall-service.ps1 — stops/deletes service and removes C:\ProgramData\torvpn

How it behaves (service loop)

Applies DNS lock (NRPT + firewall DNS rules)

Applies outbound fail-closed rules (allow Tor + Wintun only)

Starts Tor (torrc from profile)

Starts tun2socks.exe (Wintun), if configured

Every 10s checks Tor control (cookie auth at 127.0.0.1:<control_port>); on failure, restarts stack

On Stop: kills tor/tun2socks, tears down DNS lock + firewall rules

Quick start

Build:

cargo build --release


Install service (Admin PowerShell):

.\scripts\install-service.ps1 -Binary .\target\release\torvpn-win.exe -Profile .\profiles\default_win.toml
# or obfs4 profile:
# .\scripts\install-service.ps1 -Binary .\target\release\torvpn-win.exe -Profile .\profiles\obfs4_win.toml


Check:

sc.exe query TorVPN
Get-Service TorVPN


Manual path (also Admin PowerShell):

.\target\release\torvpn-win.exe ServiceInstall
# Later:
.\target\release\torvpn-win.exe ServiceUninstall

Notes / next hardening

Service currently runs as LocalSystem; we can switch to a dedicated service user with only the rights needed.

If your tun2socks.exe needs a custom flag set, tweak src/tun2socks_manager.rs.

We can add a “status” endpoint (named pipe) to introspect health and current circuits without touching SCM.

Want me to port the Linux Tor control CLI commands (newnym, circuits, health) into the Windows binary as well? They’ll work side-by-side with the service for quick ops.

Pick your next chunk: privilege drop on both OSes, circuit policy tuning via ControlPort, or a leaktest that programmatically verifies traffic paths.





Done—Windows binary now has the same Tor control CLI as Linux.

Download:
torvpn_win_with_service_and_control_cli.zip

New commands (work whether or not the service is running)
# Change circuits now
.\target\release\torvpn-win.exe newnym

# Inspect circuits
.\target\release\torvpn-win.exe circuits

# Quick health snapshot
.\target\release\torvpn-win.exe health


They connect to 127.0.0.1:<control_port> and authenticate via the Tor cookie at:

%LOCALAPPDATA%\torvpn\tor-data\control_auth_cookie


(same state dir the service uses).

If you want a one-liner to sanity-check all the plumbing: install service, start it, wait ~20–30s, then run health and circuits. If that’s green, we’re golden.

Next big-ticket item you want: privilege drop and service hardening on Windows, or do we swing back to Linux for per-UID nftables and a built-in leaktest command?




Locked in. I added two chunky upgrades to the Linux build:

Per-UID nftables enforcement

Built-in leaktest command (DNS leak probe + Tor SOCKS connectivity)

Download:
torvpn_linux_uid_and_leaktest.zip

What changed
Config: new [security] block

Both profiles/default.toml and profiles/transparent.toml now include:

[security]
allow_uids = []      # numeric UIDs allowed to egress directly
tor_user   = "tor"   # resolved to UID and auto-added to allowlist if present


If the tor account exists, its UID is granted direct egress so Tor can reach the network while everyone else is forced through TUN/TransPort.

nftables (per-UID)

src/nftables.rs now:

Resolves tor_user → UID (via id -u) and merges with allow_uids

Creates an nftables set: allowed_uids

In output (filter) chain, accepts if meta skuid @allowed_uids

Keeps leak clamps:

In tun2socks mode: only oifname "tun0", loopback, Tor localhost ports are allowed for non-allowed UIDs; UDP/53 dropped

In transparent mode: default-drop; allow loopback + Tor localhost ports; UDP/53 redirected to Tor’s DNSPort in NAT; only allowed_uids can egress clearnet directly

This means: only the Tor daemon (and any UIDs you explicitly list) can talk directly to the network. Everyone else is either forced through TUN (tun2socks) or caught by NAT redirects (transparent). Default is fail-closed.

leaktest command

New module: src/leaktest.rs. New CLI subcommand:

./torvpn leaktest


What it does:

DNS leak probe: sends a minimal UDP DNS query to 1.1.1.1:53 and waits up to ~900 ms for a reply. Getting a reply = likely DNS leak (FAIL). No reply = blocked/redirected (PASS).

Tor connectivity: performs a raw SOCKS5 handshake to 127.0.0.1:<SOCKS> and issues an HTTP HEAD / to example.com:80. Success = Tor path is alive (PASS).

Outputs a compact PASS/FAIL summary with notes.

Usage refresher

Build:

cd torvpn
cargo build --release


Run (transparent example):

sudo ./target/release/torvpn --profile profiles/transparent.toml start
./target/release/torvpn health
./target/release/torvpn leaktest
sudo ./target/release/torvpn stop

Notes and next steps

For best isolation, actually run Tor under the tor user so the UID match is meaningful (or set allow_uids=[<tor uid>] if you run a different account). We can also refactor the daemon to setuid to a restricted user post-setup.

Owner matching is applied in the filter/output chain (correct place for meta skuid). NAT redirection is still used for transparent mode, and filter rules allow loopback/Tor localhost ports so redirection can happen while clearnet egress stays limited to the allowed UID set.

The tun2socks mode in the MVP assumes you route traffic into the TUN device. If you want full-box routing in that mode, I can add ip rule/route setup to push default via tun0 and keep clearnet blocked for non-allowed UIDs.

Pick your next bite:

Add route setup for tun2socks mode (policy routing + MSS clamping)

Privilege split: run Tor as tor, daemon as torvpn, drop caps after setup

Expand leaktest with .onion reachability and SOCKS UDP checks



Done. I added a proper policy routing + MSS clamping path for the Linux tun2socks mode so traffic is cleanly steered into the TUN and behaves under tight MTUs.

Download the updated build:
torvpn_linux_tun2socks_routing_mss.zip

What’s new
Routing module (policy + MSS)

New: src/routing.rs

Policy routing:

Creates a dedicated route table 100 with default via 10.111.0.2 dev tun0

Adds ip rule add fwmark 0x1 lookup 100 priority 100

Packet marking + MSS clamp (nft mangle table torvpn_mangle):

m_out (route/output):

Skip loopback

Allow unmarked egress for allowed_uids (e.g., tor user)

Mark everything else meta mark set 0x1 → hits table 100

m_post (route/postrouting):

tcp flags syn tcp option maxseg size set clamp to pmtu
to avoid MTU blackholes through the tunnel

Teardown: removes the ip rule, flushes table 100, deletes torvpn_mangle

Main flow wiring

On start when [net].mode == "tun2socks":

nftables leak-guard (existing)

TUN create (existing)

Apply routing policy + MSS clamp (new)

Start Tor (existing)

Start tun2socks (existing)

On stop: calls routing::teardown_for_tun2socks() before TUN teardown and nft flush (safe if already gone)

How it fits with per-UID rules

The filter table (from earlier) still:

Allows loopback and Tor localhost ports

Allows oifname "tun0"

Accepts meta skuid @allowed_uids (e.g., Tor’s UID) for direct clearnet egress

Drops stray DNS

The new mangle table:

Marks non-allowed UIDs so policy routes push them into table 100 → default via tun0

Clamps MSS to PMTU for SYNs

Quick run (tun2socks mode)
sudo ./target/release/torvpn --profile profiles/default.toml start
./target/release/torvpn leaktest
./target/release/torvpn health
sudo ./target/release/torvpn stop

Notes

peer_ip for the TUN is 10.111.0.2, matching the earlier profile. If you customize [tun].cidr, keep it a /30 and ensure tun2socks uses the opposite end.

If you run Tor under a dedicated tor user (recommended), it’s automatically allowed for direct egress. Otherwise, add your chosen UID under [security].allow_uids.

The marking path intentionally exempts loopback traffic and allowed UIDs; everything else gets steered into the tunnel and passes filter because oifname "tun0" is permitted.

Want me to add a LAN bypass option (e.g., allow 192.168.0.0/16 to route locally), or do we go for privilege split (dedicated service user with limited caps) next?





Alright, two birds, one precision-guided stone:

“Around-the-world” routing via a proxy list + controllable Tor exits

Sensible, real-world “quantum encryption” = post-quantum (PQC) integration where it actually helps

I’ve shipped cross-platform upgrades (Linux + Windows) that do exactly that.

Downloads:

Linux (proxy rotation + exit policy + PQC):
torvpn_linux_proxy_exit_pqc.zip

Windows (proxy rotation + exit policy + PQC):
torvpn_win_proxy_exit_pqc.zip

a) Proxy list “world hop” + double-bounce realities
What’s implemented (safe + effective)

Pre-Tor upstream proxy support with rotation:

You can feed a list of SOCKS5/HTTPS proxies.

We set Tor’s Socks5Proxy/HTTPSProxy via the ControlPort and send NEWNYM.

Rotation modes: sequential or random.

Exit country preferences:

We set Tor’s ExitNodes={us},{de},... and StrictNodes=1 if you want to prefer/hard-pin exits to specific countries.

You can change this at runtime.

Tor only supports one upstream proxy at a time, not a true multi-hop pre-chain. So I built rotation (hop to the next proxy + new identity) rather than faking an unsafe post-Tor chain. Post-Tor proxies defeat Tor’s anonymity guarantees; I’m not building that in by default. If you insist, I can gate it behind a “you accept the risk” profile flag.

How to use it
1) Put proxies in your profile

Linux: profiles/default.toml (or any profile) now includes:

[proxy]
enabled = true
rotation = "sequential"   # or "random" or "off"
proxies = [
  { typ = "socks5", addr = "1.2.3.4:1080" },
  { typ = "https",  addr = "5.6.7.8:8080", username = "alice", password = "secret" }
]

[exit]
countries = ["us","de"]   # optional; e.g., ["se","nl"]
strict = true


Windows has the same blocks in profiles/default_win.toml.

2) Apply policy / hop proxies at runtime

Linux:

./torvpn applypolicy         # apply the profile's proxy + exit settings
./torvpn proxynext           # rotate to next proxy and NEWNYM
./torvpn exitset --countries us,de
./torvpn exitclear


Windows:

.\torvpn-win.exe applypolicy
.\torvpn-win.exe proxynext
.\torvpn-win.exe exitset --countries us,de
.\torvpn-win.exe exitclear

3) “Around the world” workflow

Keep a decent list of trusted upstreams (SOCKS5 > HTTPS if you can).

Set rotation="sequential" or random.

Optionally set [exit].countries to bias where your apparent egress is.

Use proxynext whenever you want to hop. NEWNYM fires automatically.

Notes: site geofencing is a legal/ToS gray area. Use responsibly. Exit-pinning can hurt connectivity; StrictNodes=1 may fail in some regions.

b) “Quantum encryption” the right way (PQC, not sci-fi)

You can’t “make Tor quantum” without rewriting Tor. What we can do (and I built):

PQC signatures (Dilithium2) to sign and verify artifacts/config:

Sign your profile.toml, bridge lists, binaries, or updates.

Verify before applying. Prevents tampering and supply-chain surprises.

PQC KEM (Kyber1024) for secret exchange at rest/out-of-band:

E.g., encrypt a private bridges file to a recipient’s PQ public key.

Both projects now include a pqc module and CLI helpers.

PQC CLI

Linux:

# Generate signing keys into ./keys/
./torvpn pqckeygen --out-dir ./keys

# Sign a file
./torvpn pqcsign --sk ./keys/pqc_dilithium2.sk --input profiles/transparent.toml --sig-out transparent.toml.sig

# Verify a file+sig
./torvpn pqcverify --pk ./keys/pqc_dilithium2.pk --input profiles/transparent.toml --sig transparent.toml.sig

# Kyber KEM demo (writes ciphertext + shared secrets)
./torvpn pqckemdemo --out-dir ./kem_out


Windows:

.\torvpn-win.exe pqckeygen --out-dir .\keys
.\torvpn-win.exe pqcsign --sk .\keys\pqc_dilithium2.sk --input .\profiles\default_win.toml --sig-out .\default_win.toml.sig
.\torvpn-win.exe pqcverify --pk .\keys\pqc_dilithium2.pk --input .\profiles\default_win.toml --sig .\default_win.toml.sig
.\torvpn-win.exe pqckemdemo --out-dir .\kem_out


Where we use PQC in the stack:

Profile integrity: refuse to apply a profile unless signature verifies (optional policy we can flip on).

Bridge lists / sensitive config: store only as PQC-signed, optionally Kyber-wrapped blobs.

Future: if we add a remote controller/UI, we’ll do hybrid TLS (X25519+Kyber) at that layer.

I also pulled a file inventory for your quantum_encryption bundle so you can eyeball what’s inside. If you want me to wire that exact code in (license permitting), point me to the algorithm you intended; otherwise I’ll stick with standardized PQC (Dilithium/Kyber) we’re already using.

Reality check on “double bounce”

Pre-Tor proxy chain: Tor supports one upstream proxy. We rotate cleanly; multiple chained upstreams are brittle and add little safety.

Post-Tor proxy: bad idea; it turns Tor into “just a fancy middle hop” and hands your traffic to a third party exit you chose. Not enabled by default. If you want it anyway for a controlled lab scenario, I’ll gate it behind an explicit, off-by-default profile flag with warnings.

Recap of what you’ve now got

Linux:

Proxy rotation + ExitNodes control (CLI + profile)

PQC keygen/sign/verify/KEM utilities

All the previous: transparent mode, tun2socks policy routing + MSS clamp, per-UID nftables, leaktest, Tor control, systemd daemon

Windows:

Proxy rotation + ExitNodes control (CLI + profile)

PQC utilities

All the previous: NRPT DNS lock, firewall kill-switch, Tor control CLI, native Windows Service with auto-recovery

If you want, next I can:

Enforce “profile must verify” policy and embed the verifier into startup, with a trust-on-first-use store.

Add an optional bridge vault (Kyber-wrapped, Dilithium-signed) with CLI to add/remove bridges safely.

Add a hop plan: scheduled country/proxy hops on a cadence.

Tell me where you want the next bolt tightened.



Hop plan: done and wired into both platforms. You can now schedule country + proxy hops on a cadence; the daemon/service applies them automatically and rotates circuits.

Downloads:

Linux: torvpn_linux_with_hop_plan.zip

Windows: torvpn_win_with_hop_plan.zip

How it works
New config section

In both Linux and Windows profiles you’ll see:

[hop]
enabled = false          # flip to true to start hopping
randomize = false        # (placeholder for future shuffle)
loop_forever = true      # cycle continuously
jitter = "0s"            # optional max random jitter per hop (e.g., "30s")

[[hop.sequence]]
duration = "20m"
exit_countries = ["us"]
proxy = "next"           # use the next proxy from your [proxy] list

[[hop.sequence]]
duration = "15m"
exit_countries = ["de"]
proxy = "socks5://203.0.113.42:1080"  # explicitly set a proxy for this hop


duration: parsed with humantime (“15m”, “1h”, etc.).

exit_countries: Tor ExitNodes gets set to {us}, {de}, etc., and StrictNodes=1 for the hop.

proxy:

"next" → rotates to the next entry in your [proxy].proxies list, then sends NEWNYM.

"socks5://host:port" or "https://host:port" → sets that directly for the hop.

null/omitted → leave current proxy as-is.

Optional jitter adds up to that much random delay on top of each hop duration to avoid clock-like patterns.

Scheduler behavior

State is kept in hop_state.json under the app’s state dir, so it survives restarts.

On each health tick (every ~10s), the daemon/service checks if the hop’s next_epoch_ms has passed; if so, it:

Applies ExitNodes/StrictNodes

Applies the proxy change (rotate or explicit)

Signals NEWNYM

Schedules the next hop (duration + optional jitter)

Where it runs

Linux: in our daemon mode (torvpn daemon) and the systemd unit you already have installed.

Windows: in the native service loop (Service name: TorVPN).

Quick start

Edit your profile:

Linux: profiles/transparent.toml or profiles/default.toml

Windows: profiles/default_win.toml or profiles/obfs4_win.toml
Set:

[hop]
enabled = true
loop_forever = true
jitter = "20s"


and define your [[hop.sequence]] entries.

Start the long-runner:

Linux (systemd): sudo systemctl restart torvpn

Linux (manual): sudo ./torvpn --profile profiles/transparent.toml daemon

Windows (service): sc.exe stop TorVPN && sc.exe start TorVPN

Windows (manual): .\torvpn-win.exe ServiceInstall (once), then sc.exe start TorVPN

Watch it work:

Linux: journalctl -fu torvpn

Windows: Event Viewer -> Windows Logs -> Application, or Get-Service TorVPN

Notes / guardrails

Tor only supports one upstream proxy at a time. The hop plan respects that, changing the upstream per hop and rotating circuits.

Exit pinning (StrictNodes=1 with tight country sets) can reduce path availability. If a hop fails to build circuits, the daemon will detect control health degradation and recycle components like before.

If you’re using obfs4/bridges, the hop plan still applies to ExitNodes/proxy settings; just make sure your obfs4 bridge transport is configured in the profile.

Extras you might want next

Shuffle the hop order per cycle (randomize=true + Fisher–Yates on sequence).

Calendar windows (e.g., “weekdays: us->de rotation; weekends: se->ch”).

Per-hop DNS exceptions for local LAN domains in transparent mode.

Export a JSON status endpoint with current hop, time remaining, and resolved exit IP.

Call the shot and I’ll wire it in. 



Cranked it up a notch. You’ve now got:

Shuffle per cycle: set randomize = true and the hop sequence is Fisher–Yates shuffled at the start of each cycle. Persisted in state so it stays stable until the next cycle.

JSON status endpoint: a tiny local HTTP server that reports current hop, time remaining, and the live Tor exit IP.

Downloads:

Linux: torvpn_linux_hop_random_status.zip

Windows: torvpn_win_hop_random_status.zip

How to use it
1) Shuffle hop order

In your profile ([hop] block):

[hop]
enabled = true
randomize = true        # shuffle order once per cycle
loop_forever = true
jitter = "30s"


The scheduler stores an order vector in hop_state.json.

It regenerates a new order when a new cycle starts, or if you toggle randomize or change sequence length.

2) JSON status endpoint

New profile block:

[status]
enabled = true
listen = "127.0.0.1:8787"


Serves GET /status (local only) with a JSON snapshot:

{
  "current_index": 1,
  "total": 4,
  "seconds_remaining": 732,
  "next_epoch_ms": 1726234567890,
  "current_hop": {
    "duration": "20m",
    "exit_countries": ["de"],
    "proxy": "next"
  },
  "tor": {"socks_port":9050,"dns_port":5353,"control_port":9051},
  "exit_ip": "185.220.101.7",
  "mode": "transparent" // Linux only field
}


Exit IP is resolved by making an HTTP request to api.ipify.org through Tor’s SOCKS (raw SOCKS5 connect + GET). If it can’t fetch, exit_ip is null.

Where it runs

Linux: started automatically in daemon mode (and by the systemd unit).

Windows: started inside the Windows Service loop.

It’s light: single-threaded tokio listener, local-only by default.

Notes, gotchas, knobs

The “current hop” in /status reflects the hop at idx from the persisted order. If you change the [[hop.sequence]] in the profile while running, the next cycle rebuilds the order; until then, it continues with the existing order.

If randomize=false, the order is the identity [0..n-1] every cycle.

jitter adds up to that much random time to each hop; keep it within sensible ranges so your cadence doesn’t look robotic.

If you’re in transparent mode, the exit IP fetch still goes via Tor (system traffic is forced through Tor). If you’re in tun2socks mode, the fetch goes via SOCKS explicitly.

Quick test checklist

Linux:

sudo systemctl restart torvpn
curl -s http://127.0.0.1:8787/status | jq
./torvpn proxynext
./torvpn health


Windows (Admin PowerShell):

sc.exe stop TorVPN; sc.exe start TorVPN
Invoke-RestMethod http://127.0.0.1:8787/status | ConvertTo-Json
.\torvpn-win.exe proxynext
.\torvpn-win.exe health

Want more?

Add /status/metrics with rolling hop history, avg hop duration, last few exit IPs.

Add /control/newnym endpoint (CSRF-protected token) for quick hops without the CLI.

Prometheus scrape output if you’re feeling opsy.

Your move, captain.



Hotkey hop is live.

I added a local HTTP control endpoint to both builds, with a CSRF-style token check and a cooldown so you can pop a NEWNYM without touching the CLI.

Downloads:

Linux: torvpn_linux_control_endpoint.zip

Windows: torvpn_win_control_endpoint.zip

What you get

POST /control/newnym — rotates circuits via Tor ControlPort

Protected by a per-host token (generated on first run and stored in the app state dir)

10-second cooldown enforced to respect Tor’s NEWNYM pacing

Still serves GET /status with the live exit IP, current hop, and time remaining

Where the token lives

Linux: ~/.local/share/torvpn/api_token

Windows: %LOCALAPPDATA%\torvpn\api_token

Example calls

Linux:

TOK=$(cat ~/.local/share/torvpn/api_token)
curl -s -X POST http://127.0.0.1:8787/control/newnym \
  -H "X-TorVPN-Token: $TOK"


Windows (PowerShell):

$tok = Get-Content "$env:LOCALAPPDATA\torvpn\api_token"
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8787/control/newnym `
  -Headers @{ "X-TorVPN-Token" = $tok }


Response:

{"ok":true,"newnym_sent":true,"cooldown_remaining":0}


If you spam it inside 10 seconds:

{"ok":true,"newnym_sent":false,"cooldown_remaining":7}

Notes

Endpoint is local-only by default (listen = "127.0.0.1:8787"). Don’t bind it to 0.0.0.0 unless you really mean it.

You can also send the token in Authorization: Bearer <token> if that’s handier for your tooling.

Hook this into your hop automations, keyboards, or a status bar and punch it on demand.

Want me to add /control/exitset?cc=us,de and /control/proxynext with the same token guard, or should we layer in a /metrics scrape for Prometheus next?




$tok = Get-Content "$env:LOCALAPPDATA\torvpn\api_token"

NEWNYM

Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8787/control/newnym
 -Headers @{ "X-TorVPN-Token" = $tok }

Proxy rotate

Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8787/control/proxynext
 -Headers @{ "X-TorVPN-Token" = $tok }

Set exits (comma-separated cc) or clear with cc=

Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8787/control/exitset?cc=us,de
" -Headers @{ "X-TorVPN-Token" = $tok }

Always show details
'''
        (root / "README.md").write_text(readme)

    # Zip
    zip_path = Path("/mnt/data/torvpn_win_control_extras.zip")
    if zip_path.exists(): zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in root.rglob("*"):
            zf.write(path, path.relative_to(root))
    return zip_path.as_posix()

linux_zip = patch_status_server_linux()
win_zip = patch_status_server_windows()
(linux_zip, win_zip)

Result
('/mnt/data/torvpn_linux_control_extras.zip',
 '/mnt/data/torvpn_win_control_extras.zip')

Buttoned up.

I added two token-guarded control endpoints to both builds:

POST /control/proxynext — rotate to the next upstream proxy (from your [proxy].proxies), persist index, then send NEWNYM.

POST /control/exitset?cc=us,de — set Tor ExitNodes={us},{de} and StrictNodes=1 (or clear with cc=), then send NEWNYM.

Downloads:

Linux: torvpn_linux_control_extras.zip

Windows: torvpn_win_control_extras.zip

How to use
Token

Linux: ~/.local/share/torvpn/api_token

Windows: %LOCALAPPDATA%\torvpn\api_token

Examples

Linux:

TOK=$(cat ~/.local/share/torvpn/api_token)

# Rotate proxy + NEWNYM
curl -s -X POST "http://127.0.0.1:8787/control/proxynext" \
  -H "X-TorVPN-Token: $TOK"

# Set exits (US, DE) + NEWNYM
curl -s -X POST "http://127.0.0.1:8787/control/exitset?cc=us,de" \
  -H "X-TorVPN-Token: $TOK"

# Clear exits (back to default)
curl -s -X POST "http://127.0.0.1:8787/control/exitset?cc=" \
  -H "X-TorVPN-Token: $TOK"


Windows (PowerShell):

$tok = Get-Content "$env:LOCALAPPDATA\torvpn\api_token"

# Rotate proxy + NEWNYM
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8787/control/proxynext -Headers @{ "X-TorVPN-Token" = $tok }

# Set exits (US, DE) + NEWNYM
Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8787/control/exitset?cc=us,de" -Headers @{ "X-TorVPN-Token" = $tok }

# Clear
Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8787/control/exitset?cc=" -Headers @{ "X-TorVPN-Token" = $tok }

Under the hood

Same token guard as /control/newnym (accepts X-TorVPN-Token or Authorization: Bearer).

Same 10s NEWNYM cooldown applies only to /control/newnym; proxynext and exitset send NEWNYM immediately after applying settings.

proxynext persists rotation index in proxy_idx.json under the state dir.

exitset accepts comma-separated ISO 2-letter country codes; it wraps each as {cc} and flips StrictNodes on. Empty cc clears.

Nice-to-haves we can add

/control/exitclear as a shortcut alias

/status/plan showing the randomized hop order and next hop ETA

Rate limiting (per-IP / per-token) and HMAC’d tokens if you ever bind the status server beyond loopback

What’s next, captain?



Absolutely minted.

I added the “nice-to-haves” across both builds:

POST /control/exitclear — clears ExitNodes/StrictNodes and sends NEWNYM

GET /status/plan — shows hop plan state (randomized order, current index, ETA, upcoming hops)

Basic rate limiting when bound beyond loopback (5 req/sec, 120/min per IP → 429)

Optional HMAC auth header for remote binds

Downloads:

Linux: torvpn_linux_control_plus_statusplan.zip

Windows: torvpn_win_control_plus_statusplan.zip

New endpoints
Control (token or Bearer auth required)

POST /control/proxynext — rotate upstream proxy + NEWNYM

POST /control/exitset?cc=us,de — set ExitNodes ({us},{de}) + StrictNodes=1 + NEWNYM

POST /control/exitclear — clear exit prefs + NEWNYM

Status

GET /status — current hop snapshot + resolved exit IP (via Tor SOCKS)

GET /status/plan — hop plan internals:

{
  "randomized": true,
  "order_indices": [2,0,1,3],
  "current_index_in_order": 1,
  "seconds_remaining": 713,
  "total": 4,
  "upcoming": [
    {"index":0,"duration":"20m","exit_countries":["us"],"proxy":"next"},
    {"index":1,"duration":"15m","exit_countries":["de"],"proxy":"socks5://203.0.113.42:1080"},
    {"index":3,"duration":"10m","exit_countries":["se"],"proxy":null}
  ]
}

Auth

Token (always accepted):

Linux: ~/.local/share/torvpn/api_token

Windows: %LOCALAPPDATA%\torvpn\api_token

curl -s -X POST http://127.0.0.1:8787/control/exitclear \
  -H "X-TorVPN-Token: $(cat ~/.local/share/torvpn/api_token)"


Optional HMAC (recommended if you bind beyond loopback):

Header: X-TorVPN-HMAC: <ts>:<hex(hmac_sha256(secret, ts|method|path))>

Secret file (auto-generated): api_hmac_secret in the same state dir.

Accepts ±300s clock skew.

Example (bash/openssl):

TS=$(date +%s)
MSG="$TS|POST|/control/proxynext"
HEX=$(printf "%s" "$MSG" | openssl dgst -sha256 -mac HMAC -macopt hexkey:$(xxd -p -c 256 ~/.local/share/torvpn/api_hmac_secret | tr -d '\n') | awk '{print $2}')
curl -s -X POST http://0.0.0.0:8787/control/proxynext \
  -H "X-TorVPN-HMAC: $TS:$HEX"

Rate limiting

If listen ≠ 127.0.0.1:*, a simple per-IP limiter kicks in:

Burst: 5 req/sec

Rolling window: 120 req/min

On overflow: HTTP 429

Quick checks

Linux:

# Plan view
curl -s http://127.0.0.1:8787/status/plan | jq

# Exit clear
TOK=$(cat ~/.local/share/torvpn/api_token)
curl -s -X POST http://127.0.0.1:8787/control/exitclear -H "X-TorVPN-Token: $TOK"


Windows (PowerShell):

Invoke-RestMethod http://127.0.0.1:8787/status/plan | ConvertTo-Json
$tok = Get-Content "$env:LOCALAPPDATA\torvpn\api_token"
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8787/control/exitclear -Headers @{ "X-TorVPN-Token" = $tok }


Alright, fren—let’s zoom out for a sanity sweep next like you suggested. I’ll lay out an aerial map: threat model, traffic flows (transparent vs tun2socks), privilege boundaries, cap sets, fail-closed guarantees, control/telemetry surfaces, and where PQC actually hardens things. Then we can spot any gaps or “this is clever but unnecessary” bits to trim. Sound good?




##############
#
##############


Thought for 31s

Got it. Here’s the straight-up status report you asked for.

i) Not yet included (or only partially done)
Security / hardening

Privilege split + least-priv on Linux: create a dedicated torvpn user, do setup as root, then drop caps (keep only NET_ADMIN) and chroot/seccomp where possible. We called this out as a next step but didn’t wire it yet. 
Privilege split on Windows: service currently runs as LocalSystem; move to a restricted service account and tighten WFP rules to that SID. 


Enforce PQC signature checks at startup (TOFU store): we added Dilithium/Kyber tools but enforcement is optional; make “profile must verify” a hard gate. 
TLS for the local HTTP status/control server (it’s HTTP with Token/HMAC today). Option: loopback-only default (keep), plus opt-in TLS for remote binds. (

Rate limit exists; add per-token quotas and structured audit logs for control calls. 

Network coverage / leaks
IPv6: explicitly route/deny IPv6 in nftables + Windows Firewall/NRPT. We talked IPv4 paths; v6 rules are not spelled out yet. 

Transparent mode UDP: Tor can’t carry general UDP; we document “use tun2socks for UDP,” but no auto-fallback from transparent→tun2socks for UDP-heavy apps yet. 
WebRTC STUN/ICE hardening: add default denies for common STUN ports to avoid browser side-steps (Windows + Linux). 

LAN bypass knobs (CIDR allowlist) were proposed but not implemented; add per-profile LAN exceptions safely. 

Bridges / transports
Bridges/obfs4 supported via profiles, but no bridge vault (Kyber-wrapped, Dilithium-signed) and no auto-fetch/rotation UX yet. 


Routing / policy
Windows: no MSS clamp or policy-routing equivalent (Linux has MSS clamp + fwmark table). Add PMTU-safe config for Wintun. 
Per-app include/exclude on Windows via WFP filters/AppContainer rules isn’t in yet. 


Ops / UX
Prometheus /metrics endpoint and hop history were suggested but not shipped. 

Installer packaging (MSI, DEB/RPM) and bundling known-good tun2socks/wintun; we noted it as a follow-up. 
Reproducible builds, SBOM, CI, and code-signing (Authenticode on Win) not set up yet. PQC covers config, not( binaries. 

MacOS support not tackled. 

Docs: a formal threat model and “what this does/doesn’t protect” page would help new users. 


###############
#
###############


ii) What’s in place now (with quick details)

Cross-platform core

Tor control: NEWNYM, circuit list, health, and SETCONF helpers, exposed via CLI. Works in both tun2socks and transparent modes. 

petey

Profiles & templated torrc with SOCKS/DNS/Control (and TransPort on Linux transparent). 

petey

Pre-Tor proxy list & rotation: SOCKS5/HTTPS upstreams, sequential/random rotation, plus proxynext route + NEWNYM. 

petey

Exit policy control: exitset/exitclear, country pinning via ExitNodes + StrictNodes. 

petey

Hop plan scheduler: timed hops with per-hop proxy and exit sets, optional jitter, and cycle randomize (Fisher–Yates). State persists across restarts. 

petey

Local HTTP API:

GET /status (live exit IP via Tor SOCKS, current hop, ETA)

GET /status/plan (order, upcoming hops)

POST /control/newnym (cooldown-guarded), POST /control/proxynext, POST /control/exitset, POST /control/exitclear

Auth: per-host token, optional HMAC for remote binds, plus rate limiting for non-loopback binds. 

petey

PQC utilities: Dilithium2 signing (keygen/sign/verify) and Kyber1024 KEM demo; intended for profile/bridge-list integrity and future update channels. 

petey

Linux

Two modes:

tun2socks: TUN → tun2socks → Tor SOCKS (TCP+UDP via SOCKS)

transparent: nft redirection to Tor TransPort/DNSPort, no TUN/tun2socks. 

petey

Fail-closed nftables: leak guard (drop DNS leaks, allow loopback and Tor ports), plus per-UID allowlist so only Tor’s UID can egress clearnet directly. 

petey

Policy routing + MSS clamp for tun2socks: fwmark → table 100, PMTU clamp for SYN to avoid blackholes. 

petey

Leaktest CLI: DNS leak probe + Tor SOCKS handshake/HTTP test with PASS/FAIL output. 

petey

Systemd unit: sandboxing, auto-restart, and long-running daemon with control-health watchdog + automatic recovery. 

petey

Windows

Wintun + tun2socks start/stop with generated torrc; status/stop via CLI. 

petey

Firewall kill-switch: allow Tor + Wintun adapter, block everything else. 

petey

DNS lock: NRPT rule for “.” to 127.0.0.1, adapter DNS set to loopback, and firewall blocks on TCP/UDP 53 except loopback/Tor DNSPort. 

petey

Native Windows Service: auto-recovery, mirrors daemon logic; Tor control CLI available even alongside the service. 

petey

Same HTTP status/control API (token/HMAC/rate limit) as Linux. 

petey

If you want me to start knocking down the “missing” list, I’d hit these in order:

Linux/Windows privilege split + cap drop/service user

IPv6 handling end-to-end (nftables + WFP/NRPT)

Enforce PQC-signed profiles at startup (with TOFU)

Bridge vault + simple CLI UX

/metrics and structured logs (Prometheus-friendly)

Say the word and I’ll ship those next.



###############
#
###############




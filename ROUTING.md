# TorVPN — the routing layer (read before you flip it on)

Cold-start: this is the layer that turns "tor engages and I can see a Tor exit
IP" into "my whole machine's traffic actually goes through Tor". It's the part
with teeth — done wrong, split-tunnel routing can knock your box off the network
— so it's built to **fail safe** and it's **gated behind a flag**. Read the
escape hatch at the bottom before you test.

---

## What it does, and the one hard problem

Full-device VPN means: point the default route at the Wintun adapter so every
packet flows into tun2socks → tor. Simple, except for one trap — the **routing
loop**:

Tor itself makes ordinary outbound TCP connections to its entry guards. If the
default route points at the tunnel, *tor's own guard traffic* also gets shoved
into the tunnel → tun2socks → tor's SOCKS port → tor tries to reach the guard
again → into the tunnel again → 🌀. The tunnel eats the very transport it's
standing on, and nothing works.

The fix (standard tun2socks practice) is a split: pin a `/32` host route for each
guard IP to your **real** gateway, then point the default at the tunnel. Because
a `/32` is more specific than the `/0` default, tor's guard packets take the
physical door while everything else goes through Tor. It's like posting a single
"staff only, use the side entrance" sign for the couriers (tor↔guards) while the
public all funnel through the front lobby (the tunnel).

We learn the guard IPs live from tor's ControlPort right after it bootstraps
(`orconn-status` → `ns/id`). **If we can't find any guards, we refuse to touch
the route table** — a dead tunnel is annoying; a looped default route is a tow
truck. That refusal shows up as a normal `Error` state ("routing: no tor guard
IPs discovered…").

---

## Two modes (the `full_tunnel` flag)

In `profiles/default_win.toml`, `[tun] full_tunnel`:

- **`false` — proxy-only / safe mode.** tor + tun2socks come up, but **nothing**
  on your system is touched: no kill-switch, no DNS lock, no route changes. tor
  is usable as a local SOCKS proxy (`127.0.0.1:9050`) and DNS resolver, and the
  tray/`status` shows a real Tor exit IP. This is how you confirm the engagement
  half works with zero risk.
- **`true` — full VPN (default).** Kill-switch + DNS lock applied fail-closed
  before tor starts, then split-tunnel routing after tun2socks. This is the real
  thing.

The service writes a per-user override at `%ProgramData%\torvpn\profile.toml`
that you can edit; the bundled default is `true`.

---

## Recommended test procedure (do it in this order)

**Step 1 — prove engagement in safe mode.** Set `full_tunnel = false` in
`%ProgramData%\torvpn\profile.toml`, restart the service, then:

```powershell
target\release\torvpn-svc.exe connect
target\release\torvpn-svc.exe status      # expect phase "engaged (proxy only)" + a Tor exit_ip
# sanity-check the SOCKS proxy directly:
curl.exe --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip
target\release\torvpn-svc.exe disconnect
```

If `status` shows a Tor exit IP, the whole tor/tun2socks/control path is good.

**Step 2 — flip the tunnel on.** Set `full_tunnel = true`, restart the service,
and **have a way back** (see escape hatch). Then:

```powershell
target\release\torvpn-svc.exe connect
# From a NORMAL browser / curl (NOT through the SOCKS proxy):
curl.exe https://check.torproject.org/api/ip     # should now say IsTor: true
nslookup example.com                              # should resolve (via tor DNS)
```

If your ordinary, un-proxied traffic reports `IsTor: true`, the tunnel is live.
DNS leak check: run a leak test in a browser; you should see Tor exit resolvers,
not your ISP's.

**Step 3 — disconnect and confirm you're fully back:**

```powershell
target\release\torvpn-svc.exe disconnect
curl.exe https://check.torproject.org/api/ip     # back to your real IP
```

---

## Escape hatch (if the tunnel wedges your network)

Everything here is designed so you can always get back:

1. **Routes are non-persistent.** Nothing is added with `route -p`, so a
   **reboot** wipes every route change. Internet returns on restart.
2. **The kill-switch and DNS lock DO survive a reboot** (firewall default-action
   and NRPT rules persist). But the **service clears all of it on start-up** —
   it always boots Disengaged and runs a full teardown first. So after a reboot,
   the service starting is enough to restore firewall + DNS. If the service is
   set to auto-start (it is), this is automatic.
3. **Manual, right now**, from an admin prompt:
   ```powershell
   # lift the kill-switch:
   Set-NetFirewallProfile -All -DefaultOutboundAction Allow
   Get-NetFirewallRule -Group TORVPN | Remove-NetFirewallRule
   # drop the DNS lock:
   Get-DnsClientNrptRule | ? { $_.DisplayName -eq "TORVPN Default" } | Remove-DnsClientNrptRule -Force
   # restore the default route (kill tun2socks; its adapter + tunnel route vanish):
   taskkill /IM tun2socks.exe /F
   ```
   Or just: `sc stop TorVPN` — the service's stop handler disengages cleanly, and
   next start scrubs anything left.
4. **Auto-recovery is mostly free anyway:** Wintun adapters are process-scoped,
   so if tun2socks dies (or the service crashes), the adapter disappears and
   Windows automatically removes the tunnel default route — the physical default
   takes back over on its own. The leftover guard `/32`s point at your real
   gateway and are harmless.

---

## Known limits (honest list)

- **Guard rotation mid-session.** We pin the guards discovered right after
  bootstrap. Tor keeps the same entry guards for weeks, so within a session this
  is stable — but if tor *did* rotate to a brand-new guard during a very long
  session, that new guard's traffic would loop and the tunnel could stall. Fix
  if it ever happens: disconnect/reconnect (re-discovers guards). A periodic
  guard-route refresh in the service watchdog is the obvious next hardening if
  you want it.
- **IPv6.** The tunnel is IPv4. IPv6 isn't routed into it; the kill-switch
  blocks outbound v6 so it can't leak. Net effect: v6-only destinations won't
  work while engaged. Acceptable for a Tor VPN (Tor is v4-centric here); shout if
  you want a v6 null-route instead.
- **DNS needs tor on port 53.** Windows NRPT can only forward to a nameserver on
  :53, so `dns_port = 53` is required for system DNS to resolve through tor. If
  something else already owns `127.0.0.1:53`, tor won't start — free the port.
- **Tunnel subnet.** Hardcoded `10.86.1.0/24` in `route-apply.ps1` /
  `route-teardown.ps1`. If that clashes with your LAN, change it in both.
- **Not tested on Windows by me.** I built and unit-tested the discovery/parsing
  logic and compiled the whole workspace, but I couldn't run the Windows-only
  routing on a real box from here. Treat Step 1→2→3 above as the acceptance test.

# whispr VPN — owner enrolment pack 1.0.0

Keep this pack on **your** PC. Send the separate **whispr-vpn-friend-1.0.0.zip** to the friend. This pack administers only friend peers on your five already working exits: `nyc1`, `lon1`, `fkt1`, `sgp1`, `syd1`. It does not install another VPN server, reset firewall policy, restart WireGuard, change keys or modify your local VPN client/state. It uses your existing Windows OpenSSH aliases and key-based login. PowerShell 7.2+ is required (7.6.x recommended); local Windows elevation is not required. VPS actions require **sudo** or a root SSH login.

## The whole exchange

1. Friend runs their pack's `Install-Friend.ps1` on their Windows 11 x64 PC.
2. Friend sends you the generated **friend-request.json**; their private key stays on their PC.
3. You run **Register-Friend.ps1** below; it adds a separate peer to each exit you select.
4. You send the generated **friend-access.json** back to that same friend.
5. Friend imports it, clicks Connect in the tray and waits for Verified / green.

No SSH keys or sudo passwords are sent to the friend. The exchanged JSON files are public configuration, not executable scripts. Exchange them directly with the intended person. Compare the request's printed public-key fingerprint if you need to establish that it really came from that friend; matching a request ID is not an owner signature.

## Extract your pack

In PowerShell 7:

```powershell
Set-Location "$env:USERPROFILE\Downloads"
Unblock-File .\whispr-vpn-owner-1.0.0.zip
Expand-Archive .\whispr-vpn-owner-1.0.0.zip -DestinationPath .\whispr-vpn-owner-1.0.0 -Force
Set-Location .\whispr-vpn-owner-1.0.0
```

**Before running owner operations, use Disconnect / Recover in your whispr tray.** SSH to the currently selected exit can otherwise be blocked by the client protection/routing rules. Reconnect after the owner operation completes. These scripts never disable your protection or change local routing themselves. Your existing VPN does not need reinstalling.

Save the received friend-request.json in Downloads. Register all five exits:

```powershell
.\Register-Friend.ps1 -Request "$env:USERPROFILE\Downloads\friend-request.json"
```

**You will be asked for each VPS account's sudo password in turn. Input is hidden.** An alias that logs in as root does not need a sudo password. Stay at the terminal until all five results are printed. The scripts will not store those passwords. Each VPS must already have the working managed `wg-whispr` interface and root-owned `/etc/whispr-hybrid` files. The tool refuses to configure a missing server or overwrite manual/unknown peers.

To approve only selected locations:

```powershell
.\Register-Friend.ps1 -Request "$env:USERPROFILE\Downloads\friend-request.json" -Servers nyc1,fkt1
```

The script prints a full path under `out\<request-id>-<run-id>\friend-access.json`. **Send exactly that friend-access.json back to the friend.** It contains only exits verified during that run and only public key/address/port information for their device. Do not send this whole owner pack, your SSH folder, protected server backups or your own installed client state. The separate generic friend ZIP is the software they install.

Keep the request and owner-receipt.json in the output folder. They identify that friend's key and record which exits succeeded. Every run uses a new output directory; different friends' receipts do not overwrite one another.

If an exit fails, the script ends with an unresolved list. Successfully registered exits remain registered; a returned access file contains only verified exits. Retry with the **same request** and desired `-Servers` list. Repeating registration is idempotent and does not allocate another address for that same request/key. To generate one complete access file after a partial run, retry all the desired exits or run Check-Friend.ps1 over all of them. The friend import treats that returned file as the complete local set of available exits.

Existing inbound **UDP 51832** rules are reused; no new per-friend port is opened. A source-restricted rule must permit the friend's Internet address. PTR, Cloudflare and DNS changes are not involved.

## Check or revoke

Check current registration and re-export verified profiles:

```powershell
.\Check-Friend.ps1 -Request "$env:USERPROFILE\Downloads\friend-request.json"
```

Revoke the friend's key from all five exits:

```powershell
.\Revoke-Friend.ps1 -Request "$env:USERPROFILE\Downloads\friend-request.json"
```

Use the retained per-friend request file if Downloads now contains another person's request. `-Servers nyc1,fkt1` works for check/revoke too. Revocation removes only that friend's peer and persistent ownership entry. It does not rotate the server key or remove your peer. A key not explicitly tagged to this tool's friend request is rejected, protecting the owner's existing registration. An already absent key is reported as absent. Read the results: an unreachable exit has not been confirmed revoked and must be retried.

Revocation controls that device's WireGuard/UDP access. Tor is a separate public network, so revoking a peer is not remote control of the friend's entire computer or Tor software.

## Interrupted enrolment / recovery

Each peer change records a private root-owned backup and a durable pending journal before changing persistent files or the live peer. Verified completion clears the pending journal. A normal failure attempts to restore the previous state/configuration and only the affected peer. Other peers' live endpoint/handshake state is not replaced.

If power/network loss interrupts a run, retry the same Register/Revoke command to recover the prior transaction and finish the requested action. For a standalone recovery/consistency check:

```powershell
.\Repair-Enrollment.ps1 -Servers nyc1,lon1,fkt1,sgp1,syd1
```

Recovery restores the pre-transaction peer/configuration, then verifies consistency. After an interrupted revocation, run **Revoke-Friend.ps1** again to complete the revocation. Recovery refuses to overwrite independent changes to other peers/files and reports owner attention required. Do not run the old full server setup while a peer transaction needs recovery. Check-Friend also resolves a valid pending journal before verifying the requested peer.

Private backups remain on each server under `/var/backups/whispr-friend-peers/` (root access only); the working setup state/configuration remain in their existing locations. These backup files include server configuration and must not be sent to the friend. No server secret is included in the returned public access file.

## What the tool actually changes

For the selected friend's public key only:

- Acquires the existing managed server administration lock.
- Validates server identity/port, managed config hash, address allocations and the complete live peer set.
- Allocates a free `10.88.70.x` address and, when enabled, the matching IPv6 address; records request ownership in `state.json`.
- Updates the persistent `wg-whispr.conf` and its recorded checksum, retaining all other managed peer entries and the existing server private key.
- Uses `wg set wg-whispr peer ...` to add/remove that peer live and checks the result.

It never invokes iptables, nft, UFW, sysctl, systemctl, package installation, a global WireGuard sync/setconf, interface deletion or server-key generation. Existing interface-scoped forwarding/NAT rules cover the allocated managed subnet. A new friend does not require changes to the owner's client or a shared private key.

## Validation

Python peer transaction tests cover multiple peers, idempotence, owner-key rejection, revocation, config/live mismatch refusal, write/kernel-command rollback, crash-journal recovery and conflicting-change refusal. Actual PowerShell orchestration tests cover all five exits, root/sudo invocation, partial failure and public response construction with OpenSSH boundaries mocked. The friend pack has independent request/import/installer tests. See TEST-RESULTS.txt for what was and was not executed. No real VPS or friend's Windows session was accessed by the author during this build.

Toolchain for owner: PowerShell 7 + Windows OpenSSH; remote Python 3.10+ and already installed WireGuard tools. Python peer unit tests run under Linux/WSL and use only the standard library; orchestration tests additionally need PowerShell 7. The server helper is uploaded to a unique temporary directory, hash-checked and run with Python isolated mode, then removed; it is not installed as a service. The owner pack needs no new Python installation locally unless you want to run its Python tests.

Copyright © 2026 whispr.dev. MIT; see LICENSE. WireGuard command reference: https://git.zx2c4.com/wireguard-tools/about/src/man/wg.8

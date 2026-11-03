# whispr VPN shared exits — group add-on 1.0.1

**The same add-on for every member. One public `group.json` to exchange.** A VPS owner lists their own SSH aliases, publishes those exits for the group's device public keys, and sends the updated file to the others. Importing the file adds approved profiles/menu entries/map dots on that PC. No shared SSH credentials, private keys, new control server or per-recipient response files.

This is an add-on for the existing **working whispr fix5 + tray 0.2.0/0.2.1** owner installation or **friend pack 1.0.0** on Windows 11 x64. It is not a fresh VPN client installer. PowerShell **7.2+ x64** is required; 7.6.x is recommended. New friends first run the existing friend pack's Install-Friend.ps1 to create their local key and public request. They can then use this group workflow instead of the old individual access-file registration.


## Country flags in 1.0.1

The five original exits now display proper image flags: nyc1 United States, lon1 United Kingdom, fkt1 Germany, sgp1 Singapore, syd1 Australia. The selected-exit checkmark has its own margin. Icons are embedded and cached locally; no emoji-font dependency or network lookup. Other shared exits display a neutral globe because group protocol v1 does not declare their countries. Their names and map dots still work as before.

For an existing working installation, right-click the VPN tray and choose **Close tray only — keep VPN running**. In Administrator PowerShell run **Add-ExitFlags.ps1** from this folder. It patches only Tray.ps1 and its integrity hashes, backs them up, and reopens the tray. It does not disconnect the background VPN or touch keys, profiles, server rules or sign-in settings. It also works on the original five-location tray before the group add-on is installed. There are no SSH or sudo prompts.

Use **Add-ExitFlags.ps1 -Restore** to restore its previous UI files, or add **-NoLaunch** to leave the tray closed after installation/restoration. Close the tray first in each case. Restoration refuses to overwrite a later unrelated update. The normal Install-Group.ps1 route includes the same flags automatically; its existing disconnected-install requirement still applies.

You do not need to recreate, republish or exchange group.json for this appearance update. Keep using your existing management folder and local my-vps.json; the standalone flag patch is sufficient. When moving all management work into this new version folder, retain your existing group.json and my-vps.json rather than replacing them with the supplied empty template.

## Quick start — you and one friend

### Once on BOTH PCs

Use **Disconnect / Recover**, then **Close tray only**. Group operations need the VPN disconnected for safe profile changes and to avoid the client's protection blocking SSH to the selected exit. The tools never disarm protection automatically.

Extract the add-on, then double-click **OPEN-GROUP.cmd** and accept Windows UAC. Use menu **1 — Install/update this add-on**. This updates the catalogue/map/menu support, with backup/rollback, and keeps the existing transport configuration, guard binary, verification, private key, selected exit and sign-in setting. It does not reinstall the VPN or configure a server.

If Windows blocked the download, use PowerShell 7 to unblock the ZIP before extraction:

```powershell
Set-Location "$env:USERPROFILE\Downloads"
Unblock-File .\whispr-vpn-group-1.0.1.zip
Expand-Archive .\whispr-vpn-group-1.0.1.zip -DestinationPath .\whispr-vpn-group-1.0.1 -Force
Set-Location .\whispr-vpn-group-1.0.1
.\OPEN-GROUP.cmd
```

### First owner — create the initial file

Create the group on the original owner PC only. A friend client is directed to import the existing group; creating an intentionally independent group from a friend client requires the explicit `-StartIndependentGroup` command switch.

You already have your friend's **friend-request.json**, or they generate it using the friend pack. In the group menu:

1. **2 — Create the group:** give it the path to that request. Your own public identity is added automatically.
2. **4 — Publish / sync MY VPSs:** read the displayed member list and type **YES** to approve it.

On the original owner installation the five known aliases/profiles and their city coordinates are copied into your local `my-vps.json` automatically. Existing managed servers keep their server identity and firewall; this run only registers/syncs group peers. **Stay at the terminal for the VPS sudo password prompts.** Root SSH logins do not need sudo. Your public-key request is not sent back to the friend separately: the group file already contains the required public membership data.

The updated **group.json** is in the extracted add-on folder. **Send that one file to your friend.** The published exits are also imported on your own PC. Open the normal VPN tray afterwards and reconnect when ready.

### Friend — import, then contribute a VPS

In the same add-on menu:

1. **5 — Import a received group.json:** choose/paste the path to the file you received. It is saved as the tool's current group.json too. Approved exits appear in the VPN client.
2. To contribute a VPS, disconnect and close the tray, then use **3 — Add one of MY VPSs**. Supply its existing SSH alias (or `user@IPv4` on SSH port 22), a useful display name, a city and UDP port (normally **51832**). A city chooser provides common locations; custom latitude/longitude is supported.
3. **4 — Publish / sync MY VPSs:** approve the displayed group members, then answer the server's **sudo password** prompt if required.
4. **Allow inbound UDP 51832 in that VPS's provider firewall**, if attached, from the group members' Internet addresses (or All IPv4 if not restricting sources). TCP 51832 does not allow WireGuard.
5. Send the updated **same group.json** back. The first owner chooses **5 — Import**. Both now have the contributed exit; each can choose it independently.

That is the whole extra-VPS exchange: one publication, one returned JSON, one import. There is no request/response exchange for each individual member. Each VPS owner must already have working key-based SSH and a trusted host key for their own server; use a configured alias for custom SSH ports/users, or `user@IPv4` for port 22; nobody needs SSH access to somebody else's VPS.

The old five profiles are retained. A published exit already matching an existing five-location profile reuses its alias instead of creating a duplicate. Other nodes get a stable ID derived from their server public key, so two owners can both call an SSH alias `nyc1` without colliding. Identical/nearby map dots offer a chooser; colocated dots have a count badge. The world map and Europe inset include contributed locations.

## What happens on a server

For a **new** exit, the owner-run tool reuses the guarded fix5 server installer: Ubuntu/Debian WireGuard/iptables tools if needed, dedicated `wg-whispr`, its dedicated subnet, scoped UDP forwarding/NAT and its reboot service. Existing websites/mail and unrelated services are not reconfigured. It refuses unmanaged interface/configuration, subnet, chain or port collisions. A kernel/cloud firewall problem is reported, not bypassed.

For an **already configured managed** exit, it preserves its key, listener and firewall. The publishing device must already be registered on that exit; the tool refuses to take over a managed server set up for another device. It uses the existing administration lock, validates the live/persistent peer state, adds/removes only group-managed peers and records ownership. The server's own publishing-device key and unrelated native peers are protected.

The whole group is not one cross-connected LAN. Each device chooses a VPS for UDP egress as before; TCP/DNS keep the automatic Tor path and existing private/LAN exceptions. Sharing another VPS adds capacity/location choices, not guaranteed identical ping or unlimited bandwidth.

## Adding or removing a device later

Use menu **6** with another public friend-request.json. This increments the member-list revision in group.json. Share that same updated file. **Each VPS owner must run menu 4** to approve/sync the membership on their own listed servers. Import alone never grants access on a remote server. A new member may initially have no approved shared profile until the relevant owners sync.

For a guest-device removal, menu **8** removes it from the public roster. **Every VPS owner must sync menu 4 before remote access is confirmed revoked.** Existing unrelated/native peers are never silently revoked. Existing friend-pack peer registrations may be adopted as group-managed when explicitly included in a publishing owner's approved roster. Once using group membership, update/remove devices through this workflow; re-publishing an old roster after using an old individual revocation tool could re-authorise that device.

Publishing owners cannot remove themselves or another contributing VPS owner using the guest-removal shortcut. One group per client installation and one publishing group per VPS are supported in this release. This is an additive exit catalogue; automated contributing-owner retirement/server-key rotation is not part of this version. Removing a server from my-vps.json merely stops this tool syncing it; it does not delete the running service, revoke peers or silently remove published choices.

## Files you actually handle

- **group.json:** the only file exchanged for ongoing group/endpoint updates. Public device keys, names, server public keys/IPs/ports, assigned tunnel addresses and map metadata. No private key or password.
- **my-vps.json:** only your own local SSH-alias/metadata list. The wizard writes it; manual editing is optional. Do not put passwords or SSH private keys in it.
- **results/**: local operation receipts for troubleshooting; no need to exchange these.

Use a direct trusted conversation for the group file. It is validated data, not executable code, but it is **not cryptographically signed**: exchanging it does not independently prove the sender's identity. Accept it from the people whose exit infrastructure you trust. Import never runs SSH or setup commands; only an explicit local publish/sync operation can configure that owner's own aliases.

Start with the latest shared group file. Node revisions merge independently, preserving another owner's newer node record even when absent from an older copy. Older membership revisions and conflicting same-revision records are refused. Share the completed file after publishing before the other owner makes changes; there is no always-on central synchronisation service.

If you lose the folder's group.json, menu **9** recovers the last imported/publication catalogue from protected local state. Do not create a second group identity to repair a missing file.

## Terminal equivalents

Run from the extracted folder using Administrator PowerShell 7:

```powershell
.\Install-Group.ps1 -NoLaunch
.\New-Group.ps1 -MemberRequests "$env:USERPROFILE\Downloads\friend-request.json"
.\Publish-MyVPS.ps1
```

On the other PC:

```powershell
.\Import-Group.ps1 -File "$env:USERPROFILE\Downloads\group.json" -NoLaunch
.\Add-MyVPS.ps1
.\Publish-MyVPS.ps1
```

Then import its returned file on the first PC. These commands are alternatives to the menu, not extra steps.

If you prefer the details file, its exact shape is:

```json
{
  "Schema": 1,
  "Servers": [
    {
      "SSH": "fkt1",
      "Name": "My Frankfurt",
      "Latitude": 50.1109,
      "Longitude": 8.6821,
      "Port": 51832
    }
  ]
}
```

That row uses the existing `fkt1` alias as an example; list only aliases you personally own/administer. The supplied file is an empty valid list and the wizard avoids hand editing. Port and coordinates must be JSON numbers. `-ApproveMembers` on Publish-MyVPS.ps1 skips the interactive YES only when intentionally approving the displayed roster for an unattended command.

## Failure and recovery

Successful server updates are saved to group.json immediately; failures leave a clear unresolved list and local receipts. Repeat the same publish with the same current group file after fixing the reported problem. Peer writes are journalled individually and interrupted peer operations are recovered before retry. A group batch is not all-or-nothing: completed members/nodes remain registered. Do not rerun the old full exit installer while a journal needs recovery.

Do not change group.json manually to force past a stale/conflicting revision. Import the latest file from the group, then publish your own nodes. On a key/ownership/config mismatch the tool refuses rather than replacing another owner's identity. If a server no longer exists, it cannot be verified; the tool does not claim that its peers have been revoked.

A shared exit is usable only after a real client connection verifies TCP/Tor and UDP through that exit. Server configuration success alone does not prove the cloud firewall or full path is working. Open the tray, select the new exit while disconnected and Connect. Wait for **Verified / green**. Closing this group-tool window does not stop an already running independent VPN session.

## Client rollback

Install/import failures automatically restore changed client files/profiles. Completed client-update backups are under the existing administrator-only state folder's group-backups directory. To restore the pre-add-on UI, select an original five-location exit while disconnected, close the tray, then run:

```powershell
.\Restore-PreviousClient.ps1
```

It checks backup/current hashes before restoring. Private keys, profiles, group catalogue, remote peers and sign-in setting are retained. It refuses to overwrite later independent updates. Restore/remove this add-on before using the old tray-only removal script. The friend full Uninstall.ps1 can still remove its entire client; server revocation remains an owner operation.

## Verification and supported environments

See TEST-RESULTS.txt. Actual PowerShell schema/merge/map/installer/import/publication/rollback tests run on Linux with explicitly mocked Windows ACL/guard/SSH boundaries. Python peer/group tests use temporary state and a mock kernel command layer, including initial bootstrap, existing-server no-reprovisioning, multi-member sync, protected peers, revocation, failures and interrupted recovery. The packet engine, WFP guard, session supervisor, verification and background host are not replaced by this add-on.

Real Windows WinForms/UAC/WFP/Task Scheduler, a newly contributed VPS and end-to-end handshake remain live validation work; these tests are not a leak/crash certification. No live VPS was accessed during this build. Server prerequisites are the same as the working Debian/Ubuntu fix5 setup; other distributions are not advertised. IPv4 SSH endpoints are required. Provider firewall configuration is deliberately not automated with a shared cloud token.

Runtime: Windows 11 x64, PowerShell 7.2+ and Windows OpenSSH on contributing PCs; remote Python 3.10+ and WireGuard/systemd/iptables support. No Python installation is required locally to use the tools. Tests: Python 3.10+ and PowerShell 7; Linux/WSL peer tests require a root test process, use temporary paths and mock wg (no real network changes). Example: `python3 -m unittest discover -s tests -p 'test_*.py'` and `pwsh -NoProfile -File tests/Test-Group.ps1`. See tests/README.md for the platform-boundary notes.

Copyright © 2026 whispr.dev. MIT for whispr code; see LICENSE. Natural Earth world-map attribution is retained in payload/tray/MAP-SOURCE.txt. Legacy test baselines retain their third-party notices. WireGuard command reference: https://git.zx2c4.com/wireguard-tools/about/src/man/wg.8

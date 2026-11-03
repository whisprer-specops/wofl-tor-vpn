# whispr VPN — engineering handover

**Prepared:** 2 November 2026, Europe/London (GMT).  
**Purpose:** transfer the project without requiring the next engineer to reconstruct this conversation.  
**Current instruction:** handover only. Do not interpret this document as permission to run another installer, remove software, reconfigure a VPS, or ask the user to repeat the failed procedure.

## 1. Start here: the actual position

The underlying hybrid VPN reached a working state before the desktop/MSI packaging work. The user reported fast browsing, Discord voice/video and working exit selection, including Frankfurt eventually showing green. Those are historical user observations, not a fresh connectivity test of today's installation.

The current unresolved work is reliable Windows installation, upgrade, recovery and removal in the presence of older versions, partly deleted application folders and surviving background components. Several assistant-produced fixes failed on the user's actual Windows machine. The user explicitly refuses further manual identification or termination of processes after reporting a severe shutdown/lockup incident. Installer-owned cleanup is required.

The latest published **setup launcher is 1.0.3**. It contains the **unchanged desktop MSI 1.0.2**. This version difference is intentional: 1.0.3 fixes the bootstrap helper, not the desktop MSI. Its source and binaries are included in the handover kit.

**There is no user-reported result from running setup 1.0.3 in the visible record.** Do not state that it succeeded or failed on Windows. The latest concrete screenshot is from the prior setup 1.0.2 failure:

```text
Warning as Error: Invalid search path 'C:\tools\npcap-sdk\Lib\x64'
specified in 'LIB environment variable' -- The system cannot find the path specified.
(1): using System;
```

Setup 1.0.2 used `Add-Type -TypeDefinition` in Windows PowerShell 5.1 to compile a C# helper at installation time. That exposed setup to the inherited compiler environment. Setup 1.0.3 removes that runtime compilation, embeds a precompiled .NET Framework helper, checks its SHA-256 and loads it with `Assembly.LoadFrom`.

**Build checks passed; native Windows end-to-end installation remains unverified.** Neither successful Linux tests nor a built MSI/EXE establish Windows process/SCM/task/device/installer correctness. Do not describe this as a production-certified release or repeat earlier confidence scores as evidence.

## 2. Evidence labels and limits

| Label | Meaning in this handover |
|---|---|
| User-confirmed, historical | The user supplied output or an observation in this conversation. It may no longer describe the live machine. |
| Source-confirmed | The current source was inspected while preparing this handover. This describes implemented code, not proven Windows execution. |
| Build-verified | A concrete artifact/database/resource/test was inspected or executed on the Linux build host. |
| Unverified | No corresponding live result is available. |
| Review concern | A specific code path or design limitation requires engineering review; it is not being asserted as a newly observed Windows failure. |

The current active MSI registration, application-file completeness, task enabled states, armed/disarmed guard state and live VPN connectivity on the user's PC are **unknown**. There is no current read-only inventory from that PC after the latest exchanges. This assistant did not have direct execution access to it. Do not invent one.

## 3. What the product is meant to do

The user wants to replace a paid Proton subscription using VPSs already paid for as part of other projects. These VPSs also host websites/mail and must retain those services. This is a Windows hybrid client, not a promise of identical anonymity or privacy characteristics to Proton or Tor Browser.

Current source routing (`packs/friend/app/client/Common.ps1`, `Get-HybridConfig`):

| Traffic/component | Intended path |
|---|---|
| TCP captured by the TUN | sing-box → local Tor SOCKS at `127.0.0.1:19050` → Tor exit |
| DNS hijacked by the engine | DNS-over-TCP to `1.1.1.1:53`, detoured through Tor |
| UDP captured by the TUN | sing-box userspace WireGuard endpoint → selected managed VPS → Internet |
| Tor bootstrap transport | Direct transport exception, necessary to build Tor circuits |
| WireGuard outer transport | Direct IPv4 transport to the selected VPS; fix5 explicitly binds IPv4 |
| Listed LAN/private/link-local ranges and explicit exclusions | Excluded from the TUN route; not automatically sent through Tor |
| IPv6 UDP when the profile disables IPv6 | Rejected by the engine rules |

The source uses `system=false` for the sing-box WireGuard endpoint. The Windows interface is the engine's `whispr-hybrid` TUN. Do not confuse this with the separate official WireGuard installation.

Different sites can show a Tor exit and the selected VPS address: HTTP/3/QUIC uses UDP, whereas a TCP request follows Tor. This is consistent with the configured split, not proof that either IP locator is lying. Country labels are not a complete verification of routing or leaks. Signing into the same application/account can also correlate traffic taking different paths; no anonymity guarantee has been established.

The reviewed project code is not intended to replace Windows system files. It does perform privileged networking operations, uses a TUN/driver stack and manages WFP filters. The user's reported instability is real as a report, but **the cause of the Windows/kernel/filesystem problems was not independently established**. Do not claim that either Chronomancer or the VPN was proven to have corrupted the kernel.

## 4. Historical transport and UI work

### 4.1 Earlier TorVPN and the replacement

- TorVPN 0.3.x caused substantial reported operational trouble and was to be retired. The user had already run DISM/CHKDSK for approximately two hours to rescue the machine; they rejected repeating that work without a concrete reason.
- Chronomancer is an active desktop wallpaper using an always-on-bottom window. The user reported it had worked for a substantial period before the VPN experiments. A causal conflict between the two was not demonstrated.
- A new hybrid client was developed around the existing Tor + sing-box + WFP guard design, with a dedicated VPS UDP exit. The visible replacement-package line starts at hybrid VPN 0.4.0 and several fixes.
- Proton being closed did not initially mean its route was gone. The user showed a ProtonVPN adapter and a `0.0.0.0/0` route. Later output indicated the conflict was cleared. This assistant did not turn Proton on; the observed leftover route was an existing state.

### 4.2 Specific early failures that must not be rediscovered blindly

| Stage | Observed problem | Correction/important interpretation |
|---|---|---|
| 0.4.0 / fix1 preflight | Initially treated adapter Up state as decisive; later found an actual Proton default route | Presence/Up alone is insufficient. Route conflicts were subsequently checked. Do not disable unrelated adapters on speculation. |
| First server setup | `WHISPR_H_IN` absent caused `iptables -C` error handling to abort startup | The firewall helper was corrected to handle missing owned chains during its own setup/removal. This is not a justification for ignoring arbitrary iptables errors. |
| Fix2 installation | ProgramData `install-owner.txt` access denied | App-owned permission handling was corrected. Do not broaden ACL resets to Windows, user profiles or other VPNs. |
| Fix3 connection test | Tor HTTPS Schannel/SSL failure | Verification handling was revised; later TCP/Tor checks passed. Do not disable certificate verification as a shortcut. |
| Fix4 UDP | `listen udp6 [::]... invalid argument`, handshake address-family errors | Fix5 added the explicit IPv4 `wg-transport` detour/bind. |
| NYC UDP path | No captured UDP, no handshake; provider-firewall screenshot showed **TCP** 51832 | WireGuard here uses **UDP 51832**. A TCP rule does not permit it. User subsequently reported successful fast VPN use; the exact intervening firewall-edit command is not in the visible transcript. |
| First detached tray launch | `Background host still belongs to a parent job; refusing unsafe launch` | Background launch moved toward an independent Task Scheduler host instead of relying on unsafe process detachment. |

Do not reuse an old fix1/fix2 installer as the current baseline. It can reintroduce already repaired permission, firewall or transport errors.

### 4.3 Independent lifetime, map, flags, groups

The user requested an independent background connection, tray status/info/exit selection, and sign-in auto-connect. Closing the tray/control window should not kill an established background session. Startup here is a **user sign-in mechanism**, not a proven before-login Windows VPN service, and an established connection does not literally survive an OS restart.

The map initially rendered far too small and omitted Frankfurt; later map/group code supports world and Europe views and contributed endpoints. Group 1.0.1 adds actual flag images for NYC/USA, London/UK, Frankfurt/Germany, Singapore and Sydney/Australia. Other contributed endpoints use a neutral globe because group protocol v1 does not declare countries. Existing core/UI files are outside the desktop MSI and are not automatically replaced merely by installing the desktop.

## 5. VPS exits and the unrelated tunnel to protect

These are historical addresses from user-provided output, not a fresh DNS/control-plane audit:

| SSH alias | Location | Public IPv4 | Hybrid listener |
|---|---|---|---|
| `nyc1` | New York area | `137.184.105.114` | UDP `51832` |
| `lon1` | London | `138.68.142.181` | UDP `51832` |
| `sgp1` | Singapore | `68.183.227.135` | UDP `51832` |
| `syd1` | Sydney | `134.199.170.197` | UDP `51832` |
| `fkt1` | Frankfurt | `209.38.240.191` | UDP `51832` |

UDP 51832 is the project default, explicitly shown in the NYC/Frankfurt logs; the current peer/profile is authoritative for each endpoint, and contributed nodes can choose another port. Do not overwrite a working endpoint port to match this historical table.

Use the existing SSH alias instead of guessing SSH ports. The record shows NYC SSH on 2357, Frankfurt on 22 in the later diagnostic, and SGP's established alias on 2357. Do not assume all hosts share one SSH port or overwrite the user's SSH configuration.

The server interface is `wg-whispr`; the original subnet is `10.88.70.0/24`. Original owner peer addresses shown were `10.88.70.2/32` and, when enabled, `fd89:77:70::2/128`. Shared-group tooling allocates member addresses; never assign the original owner's address/key to every friend. Server helpers live under `/etc/whispr-hybrid` in the visible server setup.

**Separate service:** official WireGuard `sgp1-ollama`, Windows `10.203.77.2/30` ↔ SGP `10.203.77.1/30`, UDP **51820**, supports another project. It is not the hybrid's UDP 51832 exit. Do not remove that adapter/tunnel, its routing, its service or its port. The user's other pfSense/Empyrion networking is also outside this cleanup scope.

### Frankfurt diagnostic history

The user showed matching configured public keys and endpoint/port. The server had no latest-handshake/transfer details at that point. One counter comparison rose from 28 to 31 packets but did not prove a valid handshake. A later systemd-backed capture finally recorded the baseline probe and repeated inbound 148-byte packets, consistent with WireGuard handshake initiations, without showing responses in that excerpt. Earlier zero-packet captures were not reliable evidence of a permanently blocked path because capture lifetime/overlap was itself problematic.

The user later explicitly reported **Frankfurt green**. The exact final repair command is not visible in the transcript. Do not invent it, regenerate keys based on this stale diagnostic, or infer that Frankfurt is broken now. A missing PTR record was discussed, but no PTR dependency was identified in this implementation.

## 6. Membership and contributed VPS model

Each PC generates and retains its **own private device key**. The original owner's package/configuration must not be copied as a shared private identity. SSH authentication keys and WireGuard device keys are different credentials and must not be conflated.

- A new friend exports `friend-request.json` with public information.
- Legacy owner tooling can return `friend-access.json`.
- Group tooling uses one ongoing public `group.json` containing membership, public device keys, published endpoints, assigned addresses and map metadata.
- Each contributing owner keeps their local `my-vps.json` containing SSH aliases and endpoint metadata. It is not a shared password/key file.
- Each VPS owner must explicitly publish/sync membership to their own VPSs. Importing `group.json` alone does not create a remote WireGuard peer.
- Each owner needs their own working SSH trust/authentication and may be prompted for that server's **sudo password**. Warn before those prompts; they are not the Windows password. Desktop installation itself performs no VPS login.
- Revocation is not complete until the relevant VPS owners sync the removal. An old roster can otherwise reauthorise a device through the publication workflow.
- `group.json` is validated data but is not cryptographically signed. Exchange it through a trusted channel. Do not describe it as a signed identity/approval certificate.
- This is a shared exit catalogue, not a new all-members LAN or automatic mesh. Bandwidth/capacity can be shared; ping and throughput are not guaranteed to be identical.

Group protocol v1 has limits: one group per client installation and one publishing group per managed VPS; automatic contributing-owner retirement/server-key rotation is not implemented. Removing a node from a local list is not equivalent to shutting down the service or revoking remote peers.

## 7. Installer history and known regressions

| Release/attempt | What was added or observed | Status/limitation |
|---|---|---|
| Desktop MSI 1.0.0 | Branded MSI, supplied licence agreement, portable PowerShell, desktop launcher and existing friend/group/owner tools | Actual user encountered existing-host/removal/partial-install trouble. Do not treat initial packaging as accepted. |
| Host fix v1 | Attempt to accept the genuine task-recorded PowerShell host | Failed: property `ProductCode` missing. A registry-key writer using `New-Item -Force` could clear existing metadata values. |
| Host fix v2 | Safer registry metadata handling; existing Store host verification | User output confirmed Store host verification succeeded. Then failed with `Invalid parameter "/setowner"`; owner/DACL icacls operations were combined incorrectly. |
| Host fix v3 | Backup no longer depended on that failing ACL invocation; metadata handling corrected; host preserved | Build/filesystem tests passed. No user success report for applying this script is present. Fixes were carried into newer MSI source. |
| Desktop MSI 1.0.1 | Native read-only inventory and embedded elevated enforcement before file changes; no uninstall dependence on an installed script | Still required the user to close runtime users. User reports led to unsafe manual process termination and a severe shutdown/lockup incident. This operational requirement was unacceptable. |
| Setup EXE 1.0.2 + desktop MSI 1.0.2 | Automatic owned shutdown before msiexec's first locked-file check; startup journalling/restoration | Actual screenshot shows runtime C# compilation failing because inherited `LIB` contained a missing Npcap SDK directory. |
| **Setup EXE 1.0.3 + unchanged MSI 1.0.2** | **Precompiled .NET Framework helper embedded as resource 204; no setup runtime Add-Type compilation** | Regression/build tests pass. **No user/native Windows end-to-end result is available. This is the current unaccepted candidate.** |

The specific genuine Store host verified in the user's v2 output was:

```text
C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.9.0_x64__8wekyb3d8bbwe\pwsh.exe
```

This is a historical task-recorded path, not a constant to hard-code. Store updates can change package paths. The current host chooser preserves an existing valid recorded host, checks an unfamiliar location for x64 PE/Microsoft Authenticode/PowerShell Core version and matching PSHOME, and refuses missing or mixed task hosts. It does not silently migrate tasks to a new host.

### An older recovery pack must not be recommended blindly

`whispr-vpn-reset-1.0.0.zip` is scoped to the **MSI 1.0.0 ProductCode and exact original MSI hash**. It is not a general reset for 1.0.1/1.0.2. Source inspection during handover also confirms its `Secure-Directory` still combines `/setowner` with `/inheritance:r /grant:r` in one icacls call—the same class of command that already failed in the host patch. Its backup/state tests mocked that boundary.

**Treat that archived reset pack as requiring repair/review before use.** Do not hand it back to the user as a proven universal recovery tool. Its design includes original-MSI repair, owned task/process/tunnel/guard cleanup, quarantine, preserving/reseeding identity, and real MSI uninstall. Its retry with `UPGRADINGPRODUCTCODE` is a special 1.0.0 recovery path after independent checks; it is not a generic flag to bypass uninstall safety.

## 8. Latest artifact identities

The handover kit contains the current setup and source in `artifacts/`. The MSI is already embedded in the setup EXE; it is not duplicated in this kit. The source ZIP includes the existing project source and build instructions, not the downloaded portable-runtime archive.

| Artifact | Bytes | SHA-256 | Status |
|---|---:|---|---|
| [whispr-vpn-1.0.3-setup.exe](https://chatgpt.com/library?file_id=libfile_6fde9b7c71208191b738385e6d67c6f2&account_id=personal) | 116,188,134 | `76d62fb2f38297c806c0be5a1379dfe78487fd775c42b4d9b2e478afec98cd67` | Current setup candidate; no reported Windows result |
| [whispr-vpn-1.0.3-source-and-art.zip](https://chatgpt.com/library?file_id=libfile_1e8545b7f7a88191ac1c174c52ca82cd&account_id=personal) | 4,890,356 | `f9d28624a41973a1ed530f3ff3de32d9bf0cc469a4df442dfd25232af47bbee5` | Authoritative current source archive |
| [whispr-vpn-1.0.2-x64.msi](https://chatgpt.com/library?file_id=libfile_905857e5eea0819193ac19c924cdef63&account_id=personal) | 115,538,944 | `e07fabe80035363ecfc221ee3ccd751a8fe9ef6a5e43605038d829340e5b51c8` | Frozen desktop MSI embedded in setup; do not run as the auto-cleanup entry point |
| [WHISPR-SETUP-READ-ME.md](https://chatgpt.com/library?file_id=libfile_7bbb7983644c8191a93c8214b8b56609&account_id=personal) | 7,651 | `5b6eaea560f13a32602b05295cd6f5beec06b8619f8666eaaad1b3a11da5f2dd` | Current release notes; read with verification limits in this handover |
| [WHISPR-SETUP-SHA256SUMS.txt](https://chatgpt.com/library?file_id=libfile_13b6595cc2ec8191a45476694d9815db&account_id=personal) | 376 | `a5c2178de186031c29373a5b92a305bc00fc1cc00eeb008a0297ab08a86040a1` | Current release checksums |

Library links require access to the same account. The portable kit includes the setup/source files themselves; sending the kit does not grant account access. Older artifacts are catalogued for engineering reference in RELEASE-MANIFEST.json, not endorsed for reuse.

Additional pinned components:

- Precompiled helper SHA-256: `7edb72ffa83233e1272b02bb8c89f0ae261a622764c72d0fcc95608be57951c0`.
- Original guard SHA-256: `44863a7faf76f8877681283f6a16e4cb02a3c051117439345c469364a4306ea6`.
- Portable Windows PowerShell archive SHA-256: `ce7484804c0f0ad4dda10c958e71acdaf7eebfb22505c1b480f89e0e9f1da94d`.
- Build-only net48 reference NuGet SHA-256: `8a7e348538e7eb91351696911689f49e3d4f63f8bab517432bbe159b8b1104a2`.

## 9. Filesystem, ownership and installer identifiers

| Location | Role / retention rule |
|---|---|
| `%ProgramFiles%\whispr VPN` | Desktop/MSI-owned controls, assets, packaged tools, portable PowerShell. |
| `%ProgramFiles%\whispr Hybrid VPN` | Actual connection client, transports, tray and background scripts. Outside the desktop MSI. |
| `%ProgramData%\whispr-hybrid` | Protected live/private state: device identity, peer/profiles, generated engine configuration, session/history and group catalogue. Preserve. |
| `%ProgramData%\whispr-vpn-desktop` | Group workspace, exports and desktop operation receipts. Preserve user `group.json` / `my-vps.json`. |
| `%ProgramData%\whispr-vpn-setup\packages\1.0.3` | Protected persistent extraction of current setup's MSI, script, original guard and precompiled helper. |
| `%ProgramData%\whispr-vpn-setup\transactions\<32-hex-id>` | Per-attempt setup logs/journal and session backup. |
| `%ProgramData%\whispr-vpn-reset-backups` | Older reset-pack quarantine/backups/pending journal, if that separate tool was run. Existence on the user's PC is unconfirmed. |

Important files in connection state include `device-key.json`, `peer.json`, `profiles/*.json`, `group-catalog.json`, `friend-install.json`, `session.json`, `resume-binding.json` and generated `engine.json`. **`device-key.json` and `engine.json` can contain private key material. Do not paste or distribute them.** Inspect selected logs for local paths/SIDs/IPs before sharing. The group exchange is public configuration; a full ProgramData copy is not.

Ownership marker text is `whispr-hybrid-schema-1`. Setup uses Windows known folders in production. Its directory checks accept SYSTEM or Builtin Administrators owners and reject reparse points. The MSI's discovery checks are principally structural/file-presence/marker checks; they are not a complete authenticated forensic inventory of every arbitrary ZIP extraction on disk.

| MSI identity | Value |
|---|---|
| Product name / publisher | `whispr VPN` / `whispr.dev` |
| Stable UpgradeCode | `{260C4308-9E2C-4C71-B65B-05199CB8262E}` |
| Desktop 1.0.0 ProductCode | `{8EECFA30-9E1C-439B-AC91-C6AA86359808}` |
| Desktop 1.0.1 ProductCode | `{B3CB5E52-AFB6-455A-B2DF-869111A0D101}` |
| Desktop 1.0.2 ProductCode | `{D8720DE2-B1A9-46C3-BF9F-F43314B37A02}` |
| Component GUID namespace | `36ef75da-3f15-4d88-8a83-13b2d38d6c10` |
| HKLM app metadata (64-bit view) | `Software\whispr.dev\VPN Desktop` |
| App metadata values | `ProductCode`, `InstallDir`, `StartMenuInstalled`, `CoreRuntimeLease` |

`CoreRuntimeLease` is an app dependency signal, not proof of a live healthy VPN. The fixed Model writer opens/creates that key through .NET `RegistryKey.CreateSubKey` and updates just its lease value. Do not reintroduce `New-Item -Force` on an existing registry key as a harmless way to open it.

The supplied **Hybrid License (MIT + CC0)** is preserved in the MSI agreement. Its copyright line is **2025 whisprer & Claude**. Do not silently rewrite the year/names. The acceptance box is not preselected, and quiet installation requires explicit acceptance. Third-party components retain their own notices. Neither the MSI nor setup EXE is Authenticode-signed; bundled-hash checks provide build-relative integrity, not publisher authentication.

## 10. Runtime objects whose identities matter

### Task Scheduler

The application is principally task-backed, not a new `whispr` Windows service.

| Kind | Name pattern | Registration source | Script / working folder |
|---|---|---|---|
| Background | `whispr-HybridVPN-Background-<SID>` | `whispr-hybrid-on-demand-v1` | `background\Scheduled-Host.ps1` / client `background` folder |
| Sign-in | `whispr-HybridVPN-Autostart-<SID>` | `whispr-hybrid-autostart-v1` | `Tray.ps1` / client root |

Setup requires the SID embedded in the name to match the task principal, exactly one Exec action, a `pwsh.exe` leaf, the expected working directory and a parsed `-File` argument for the expected script. Unknown tasks using the desktop's bundled PowerShell are treated as a dependency conflict rather than silently stopped.

Task fingerprints normalise away the task Settings/Enabled value and RegistrationInfo/Date; other definition changes make restoration refuse. Original enabled settings are recorded, not blindly set to true. Host path/action text is not migrated by setup.

### Named mutexes

- `Global\whisprVpnSetupLauncher` — native setup instance exclusion.
- `Global\whisprVpnSetup` — setup helper exclusion.
- `Global\whisprHybridVpn040` — connection session.
- `Global\whisprHybridTray010` — tray.
- `Global\whisprHybridBackground011` — background host.

Do not delete or force-release arbitrary global mutexes. The helper obtains the application session/tray/background locks after stopping the owned processes and retains them during the MSI phase.

### WFP and network objects

- Dedicated TUN alias: `whispr-hybrid`.
- TUN addresses in the source: `172.31.249.1/30`, `fd89:77:71::1/126`.
- Owned guard provider GUID: `d78d8eb9-b7c0-4e90-9eb4-0d2ec6760400`.
- Guard commands used by setup: `recover`, then `status`; required result is `DISARMED` before proceeding.
- Guard recovery is scoped to the fixed owned provider/filter set. No general firewall reset is used.
- Device removal identifies the one matching network-adapter GUID/PnP device after the dedicated alias and recorded GUID/dedicated address check. It calls `pnputil /remove-device`, not driver-package deletion. A reboot-required response is a stopped setup result, not permission to force a reboot.

### Exact process scope in setup 1.0.3

Direct executable-path matches are limited to:

- Client `bin\sing-box.exe`.
- Client `bin\tor\tor.exe`.
- Client `bin\whispr-vpn-guard.exe`.
- Desktop `runtime\powershell\pwsh.exe`.

Other `pwsh.exe` / `powershell.exe` processes require a parsed `-File` target in the known script set: client `Tray.ps1`, `Open-Tray.ps1`, `Start.ps1`, `Start-Background.ps1`, `background\Scheduled-Host.ps1`, `background\Host.ps1`, `client\Session.ps1`, `core\Session.ps1`, `core\Session-console.ps1`, or desktop `Desktop.ps1` / `Worker.ps1`. `-Command` / `-EncodedCommand` is not accepted as an owned script invocation. Directory-prefix collisions and linked owned executable paths are rejected.

`setup/Native.cs` opens a process handle, rechecks the full executable path and creation time (allowing the CIM timestamp's microsecond precision), and terminates through that held handle. PID alone is insufficient. A hard exclusion list includes Explorer, Terminal, conhost, cmd, svchost, lsass, csrss, services and other Windows processes. This is **path/argument/creation-time ownership checking**, not cryptographic authentication of every running binary.

The service query names TorVPN/whisprHybridVPN/whispr-HybridVPN, but the current implementation only positively accepts the genuine **TorVPN** own-process service at `%ProgramFiles%\TorVPN\torvpn-svc.exe` with protected parent/normal file checks. It does **not** automatically stop every similarly named service. A verified retired TorVPN is disabled on success; its prior start mode is recorded. On failure, service start modes are restored if that restoration path completes; previously running services are not automatically restarted.

## 11. What setup 1.0.3 actually executes

### Native launcher (`setup/launcher.c`)

1. Requests administrator elevation through its manifest and asks consent for VPN disconnection.
2. Creates/checks administrator/SYSTEM-only setup directories, refusing links or unexpected ACL/owner structure.
3. Extracts its embedded resources, compares file bytes/hashes to its own embedded copies, and locks them against modification during the operation.
4. Starts **Windows' own x64 PowerShell 5.1** from System32 with `-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ...`. The execution-policy option is child-process scoped; no machine/user execution-policy setting is written.
5. Supplies pinned MSI/helper hashes, redirects output to the transaction log, and displays progress from `status.txt`.
6. Leaves the failed/complete setup window open for the user to close. A completed failed window can still hold the launcher singleton mutex until closed. This explains why the previous response told the user to dismiss/close only that failed setup window before retrying.

| PE resource | Contents |
|---|---|
| 201 / RCDATA | Unchanged desktop MSI 1.0.2 |
| 202 / RCDATA | Setup.ps1 |
| 203 / RCDATA | Original whispr guard |
| 204 / RCDATA | Precompiled `Whispr.Setup.Native.dll` |
| 101 / icon group | Existing branding |
| Type 24 / ID 1 | `requireAdministrator` manifest |

### PowerShell orchestration (`setup/Setup.ps1`, `Invoke-Setup`)

1. Checks Windows build ≥22000, administrator context, x64 process and expected directory structure.
2. Verifies MSI/guard hashes; verifies and loads the precompiled helper. **This precedes task/service/process mutation.** Thus the shown 1.0.2 compiler failure occurred before its shutdown stage.
3. Acquires setup exclusion, connects to Task Scheduler, and restores recognisable pending startup settings from an interrupted setup journal.
4. Captures owned tasks/services and writes a schema-1 startup journal **before** disabling/stopping anything.
5. Disables/stops the verified tasks, stops verified service/process targets, removes the owned TUN if present, recovers the guard, confirms DISARMED and updates the stored session to disconnected.
6. Holds the application locks, repeats process cleanup, then starts msiexec with the existing MSI, `REBOOT=ReallySuppress`, `/norestart`, `LAUNCH_APP=0`, `WHISPR_SETUP_MANAGED=1` and verbose logging. Licence acceptance remains in the MSI UI.
7. Approximately every five seconds during MSI execution, attempts to stop verified whispr restarts. It does not terminate msiexec or unrelated processes.
8. Treats MSI 0 and 3010 as success, 1602 as cancellation, and other codes as failure; extracts selected MSI error text.
9. In `finally`, attempts to restore task enabled settings and service start modes, writes the final journal phase and releases held locks. It **does not reconnect the VPN**. Sign-in preference restoration is distinct from restoring the interrupted live connection.

The current code writes session history and setup records. The desktop MSI itself writes its own files/registration. This is not a literally read-only operation. Device identity and exit profiles are intended to remain byte-identical.

### Desktop MSI (`build_msi.py`, `native/inventory.c`, `native/policy.h`)

The MSI owns desktop files only. It discovers related products/folders/markers/task/runtime dependencies before file changes and repeats the gate in elevated execution. The inventory/enforcement DLL lives in the MSI Binary table; removing installed scripts does not remove this check.

Actual authored order includes: CostFinalize 1000, inventory 1010, execute LaunchConditions 1100, InstallValidate 1400, CustomActionData setter 1490, InstallInitialize 1500, deferred enforcement 1510, ProcessComponents 1600, RemoveFiles 3500, InstallFiles 4000, InstallExecute 6500, RemoveExistingProducts 6550, InstallFinalize 6600. This is why shutdown was moved **outside/before msiexec**: InstallValidate can reach locked-file handling before a deferred action is eligible to perform cleanup.

`REINSTALLMODE=amus` is authored so MSI-owned modified/unversioned desktop files are refreshed. It does not make client/state files MSI-owned. `MSIRESTARTMANAGERCONTROL=Disable` avoids generic Restart Manager shutdown. A leftover unexpected file lock remains an error/retry/cancel condition, not authority to kill an unrelated holder.

The launcher passes `WHISPR_SETUP_MANAGED=1`. The MSI's direct install/repair condition routes callers to the setup EXE. This property is a routing flag, **not authentication or proof that cleanup happened**. Standalone removal/real major-upgrade removal has different dependency logic. Optional desktop auto-launch is suppressed for managed setup so startup restoration can finish first.

## 12. What is tested, and what is not

| Check | Recorded result | Important boundary |
|---|---|---|
| 78 packaged PowerShell files parse | PASS | PowerShell 7.6.9 Linux parser; not execution in Windows PowerShell 5.1. |
| Host choice, signed-host acceptance/rejection decisions, workspace permission-call separation, setup-plan decisions | PASS | Native Windows signature/ACL/task boundaries are mocked as documented. |
| Automatic setup success, cancellation, MSI failure, process-stop failure | PASS | Orchestration executes; Windows task/process/SCM/MSI/device APIs are mocked. |
| Real journal/session backup writes and device-key/profile byte-preservation fixtures | PASS | Real temporary filesystem operations; fixture keys are not the user's keys. |
| Task fingerprinting, own/foreign process decisions, critical-process rejection, interrupted-settings recovery | PASS | Does not prove actual Windows termination or recovery behaviour. |
| Exact bad `LIB` + invalid `LIBPATH`, with Add-Type forbidden | PASS | The actual precompiled helper loads; the full mocked workflow runs; variables stay unchanged. This tests elimination of setup compilation, not the whole Windows environment. |
| Helper target/runtime | PASS | Loaded DLL declares CLR `v4.0.30319` and references only `mscorlib 4.0.0.0`. Actual Windows PowerShell 5.1 load is still a required acceptance test. |
| Native x64 launcher/preflight compile | PASS | MinGW compilation, not executing their Win32 calls. |
| Actual MSI tables, licence text/acceptance, UI references and action ordering | PASS | Database/structural checks; no live Windows MSI transaction. |
| Independent cabinet extraction | PASS, 823 files | Every extracted payload byte compared to staged payload. |
| Actual setup PE resource tree | PASS | Entire embedded MSI/script/guard/helper compared; GUI/x64/elevation manifest checked. |
| Current 1.0.3 user-PC installation, rollback and connection | **UNVERIFIED** | No user result after the 1.0.3 download response. |
| Windows stability, leak protection, long-running coexistence and restart/sign-in behaviour after latest installation | **UNVERIFIED** | Historical user success and mocked tests are not certification. |

The native setup/guard are privileged code. No successful native Windows acceptance run was performed by this assistant. Older `TEST-RESULTS` files inside legacy packs describe their own scope; do not transfer their PASS labels to the current installer.

## 13. Outstanding engineering work and concrete review concerns

### Release blockers / unmet goals

1. **Native Windows acceptance testing is missing.** Obtain a disposable Windows 11 x64 VM/snapshot before another release claim. Do not continue using the user's working PC as the whole test matrix.
2. **No complete automatic partial-client repair/uninstaller exists.** The wrapper automates install/upgrade/repair shutdown. It does not automatically quarantine/reseed/reinstall every damaged external client. Missing older MSI cache, missing identity, unrecognised folders/tasks/services and incomplete external client state can still stop it.
3. **Uninstall remains split.** A desktop-owned connection client that depends on the bundled runtime still needs the connection client removed before desktop removal. Current instructions include recovery/closing its tray. This does not yet satisfy a universal one-click full-client uninstall requirement. The native launcher ignores its command-line selection and the helper always starts msiexec `/i`; do not advertise setup EXE `/uninstall` or unattended/quiet switches as implemented.
4. **The old reset pack is not a fallback ready for use.** It has the 1.0.0-only scope and the combined-icacls defect noted above.
5. **Current machine state is unknown.** The user manually removed files and stopped processes across earlier attempts. Neither product registration nor task/runtime state can be inferred solely from which files were downloaded.

### Source-confirmed paths needing failure-injection review

These are not asserted as new observed Windows failures:

- Bootstrap mutations are **outside the MSI transaction**. MSI rollback does not itself restore all process/network/service state. The helper's compensation is separate and primarily restores startup settings, not the prior connection.
- `Remove-OwnTunnel` is inside a `try/finally` that invokes guard recovery even if tunnel removal throws. If tunnel removal fails, the later DISARMED check/Mark-Disconnected step may not execute. Review the resulting network/guard/session state rather than promising every failed attempt restores Internet access.
- In the restoration block, `Restore-Tasks` precedes `Restore-Services`. A thrown task-restoration exception prevents the subsequent service-restoration call. Make restoration attempts independent/aggregated in a future reviewed fix.
- Interrupted setup recovery is on **the next setup run**, not an installed boot recovery task. Power loss can leave paused settings until that recovery path runs. Do not advertise automatic crash-to-boot restoration.
- The MSI-monitor loop catches process-stop errors, logs them and continues waiting for Windows Installer. It is not a guarantee that every restart/file lock is eliminated.
- Service recognition is intentionally narrower than the names queried. Similar names alone do not authorise shutdown. Retired TorVPN handling changes its start mode deliberately; validate this behaviour on Windows.
- Directory-owner assumptions, task-principal translation, COM action collections, task XML normalisation and enabled-state restoration need actual Windows tests. Mock fixtures cannot validate these representations.
- Process handle/creation-time/path checks, Unicode P/Invoke, CIM timestamp comparison and parent/job cascades need real Windows tests. Do not replace them with name-only termination to get past a failure.
- Source includes conservative refusal for missing/mixed recorded PowerShell task hosts. A Store package removed by an update is not automatically migrated; that remains a distinct recovery case.
- The direct-MSI gate can instruct callers to use `whispr-vpn-1.0.2-setup.exe` because the embedded MSI was intentionally not rebuilt for setup 1.0.3. The intended current entry point is the 1.0.3 EXE. Treat this as a version/UI consistency issue for the next desktop MSI release.

## 14. How the next engineer should proceed

**Do not run anything as a consequence of receiving this handover.** The user's current request is to transfer the work. If they later authorise continuation:

1. Read this summary and current source before proposing another package. Acknowledge that no successful 1.0.3 Windows result has been reported.
2. Start with existing setup logs rather than another mutating install attempt. Distinguish launcher failure, helper load/compile failure, shutdown failure, MSI failure and actual VPN connection failure. They need different fixes.
3. If live information is necessary, propose one narrowly scoped read-only collection. Do not ask the user to discover random processes or reproduce a destructive shutdown. Never request device-key.json, generated engine.json or SSH private keys.
4. Reproduce Windows-only paths in a snapshotted Windows 11 x64 test environment, including Windows PowerShell 5.1. Validate the exact delivered helper/EXE, not only newly compiled test source in PowerShell 7.
5. Keep transport changes separate from packaging changes. Preserve a known working endpoint/profile/key set; do not rekey or reprovision VPSs to debug a local installer.
6. Define the missing full uninstall/partial-client recovery transaction explicitly: inventory, verified ownership, protected backup, exact scoped shutdown, MSI registration recovery using matching sources, rollback/compensation, private identity retention and a clear final receipt. Do not invent a new identity or erase Installer registrations to simulate a fresh install.
7. Ship only after testing actual upgrade/cancel/rollback/removal/restore paths and comparing protected state. Record concrete before/after evidence and any remaining limitation. Signing/release distribution is separate work; no signing certificate was supplied.

### Required Windows acceptance cases

| Case | Required observable result |
|---|---|
| Clean Windows 11 x64, no whispr | Installer opens, licence acceptance is required, desktop installs, no automatic key/connection before explicit client setup. |
| Working client with tray + active independent background + desktop using bundled runtime | Setup stops only whispr before the first locked-file check; no Task Manager instructions; MSI succeeds; reconnect works afterward. |
| Valid Store/global PowerShell task host | Path/action preserved; current host actually loads; no silent task migration. |
| Disabled versus enabled sign-in task | Each original enabled setting restored accurately. |
| MSI user cancellation and injected MSI failure | Startup settings restored; keys/profiles unchanged; resulting disconnected/guard/TUN state is explicit. |
| Failure during task/service/tunnel/guard operations | Each compensation attempt runs; no broad process/device reset; failure receipt identifies exactly what remains. |
| Partial desktop files / missing portable host | Setup uses OS PowerShell, restores MSI-owned files from valid source and preserves external client/state. |
| Damaged external client / missing old MSI cache | Inventory identifies the category; use an engineered, matching recovery path rather than deleting registry state or retrying blindly. |
| Inherited bad LIB/LIBPATH and no development SDK | No runtime compiler invocation; delivered precompiled helper loads in Windows PowerShell 5.1. |
| Concurrent or interrupted setup | Single-instance controls work; pending settings restoration is safe/idempotent; reboot behaviour is accurately described. |
| Unrelated PowerShell/Tor Browser/Explorer/Terminal/official WireGuard | Not terminated, disabled or reconfigured. |
| Signed/unsigned/untrusted/linked path cases | Refusal or supported handling is consistent; no recommendation to disable security controls. |
| Post-install VPN session | Actual TCP/Tor and UDP exit checks pass before green; current profile matches selected endpoint. |
| Full uninstall and retained-key reinstall | Must be implemented/tested; not claimed complete by current wrapper. |

## 15. Logs, status and evidence collection

The current package's transaction files are:

- `setup.log`: helper phase/progress and scoped stop messages.
- `powershell.log`: redirected host/compiler/PowerShell output.
- `error.txt`: the displayed helper exception if written.
- `journal.json`: product `whispr-vpn-setup`, schema 1, launcher version, phase, original task/service startup settings and MSI result.
- `status.txt`: current display text.
- `msi-install.log`: verbose Windows Installer log, only if execution reached msiexec.
- `session-before.json`: historical session backup, only if that step ran.

Pending phases are `prepared`, `stopping`, `installing`, `restoring`. Completion/compensation phases include `complete`, `failed-settings-restored`, `interrupted-settings-restored`. A phase name is a journal observation, not an independent guard/network health check.

The original hybrid client also writes status/session and `engine-stderr.log` under `%ProgramData%\whispr-hybrid`. A historical stored verification is not a live verification, and ARMED alone is not a connected/healthy result. Guard status, owner process identity, TUN identity and current transport checks must agree.

For a future engineer, the following optional command only lists existing setup attempts. **It is not a request for the user to run it now.** It does not read key/configuration contents or change processes/settings:

```powershell
$root = Join-Path $env:ProgramData 'whispr-vpn-setup\transactions'
if (Test-Path -LiteralPath $root) {
    Get-ChildItem -LiteralPath $root -Directory |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 5 Name, LastWriteTimeUtc
}
```

If the relevant attempt has only the compiler error and no journal/MSI log, that is consistent with failing before shutdown/installer execution. Do not interpret absent downstream files as a second failure. If a failure occurred after startup changes, inspect the journal before another operation. Logs may contain local paths, SIDs and addresses; share selected/redacted files, not the full private connection-state folder.

## 16. Source map and rebuild discipline

Current source archive root: `whispr-vpn-1.0.3-source/`.

| Area | Files / responsibility |
|---|---|
| Native setup | `setup/launcher.c`, `launcher.manifest`, `build_setup.py`, generated `package_hash.h` |
| Setup workflow | `setup/Setup.ps1` |
| Precompiled interop | `setup/Native.cs`, `build_native.ps1`, `bin/Whispr.Setup.Native.dll`, `fetch_reference.py` |
| Desktop controls and compatibility | `src/Desktop.ps1`, `src/Model.ps1`, `src/Worker.ps1` |
| MSI construction | `prepare.py`, `build_msi.py`, `native/inventory.c`, `native/policy.h`, `native/build.py` |
| Existing friend/client/guard | `packs/friend`, including `app/client`, `app/core`, `app/background`, `app/guard` |
| Shared groups / peers / map / flags | `packs/group` and its payload/server/client helpers |
| Legacy owner tools | `packs/owner` |
| Tests | `tests/Test-*.ps1`, `tests/verify_msi.py`, `tests/verify_setup.py`, `native/policy_test.c` plus pack-specific tests |
| Release evidence | Archive `validation/SOURCE-VALIDATION.txt`, `VERIFICATION.json`, `SETUP-VERIFICATION.json`, `build-metadata.json` |
| Licence/branding | `LICENSE.md`, `THIRD-PARTY.md`, `art/` and retained notices |

Working scratch path used in this session was `/workspace/scratch/ecf5194253cb/auto-maintenance-work/whispr-vpn-1.0.3-source`. It is temporary and may disappear. **The source ZIP and this handover kit are the durable baseline.** No external Git remote/commit has been established in this record. Do not invent a repository URL or commit.

### Build environment actually used

Ubuntu 24.04, Python 3.12, Pillow, msitools/wixl 0.103 + Libmsi GI, MinGW-w64 GCC 13 posix (Ubuntu package 13.2.0-6ubuntu1+26.1) and windres. Build PowerShell was **7.6.9**, running **.NET 10.0.14** on Linux. That build-host .NET version is **not** the target helper requirement: the helper references .NET Framework mscorlib 4.0.0.0 and declares runtime v4.0.30319 for the Windows PowerShell 5.1 host.

Pinned runtime inputs include portable Windows PowerShell 7.6.9, sing-box 1.14.4 and Tor Expert Bundle 15.0.26. Portable PowerShell is embedded in the desktop MSI. The transport downloads occur during explicit first-time client setup. The build-only Microsoft.NETFramework.ReferenceAssemblies.net48 1.0.3 package supplies reference metadata; its reference DLL/package are excluded from the shipped setup and source ZIP and are reproduced by the pinned fetch script. It is not a new runtime installation on the user's PC.

### Critical rebuild caveat: setup 1.0.3 reuses frozen MSI 1.0.2

The shipped launcher was built against the existing verified MSI whose hash appears in section 8. **Do not rebuild and redistribute a materially changed desktop MSI under the old 1.0.2 ProductCode/version.** The 1.0.3 source tree contains updated launcher README/build documentation, and `prepare.py` stages the root README into the MSI. A naive full rebuild from that tree can therefore create a different MSI with the same authored product identity. This is a release/reproducibility issue to resolve explicitly.

For a launcher-only fix, reuse the exact frozen MSI 1.0.2 from the current setup's protected package cache or the preserved Library artifact, verify its known hash, and retain its validation record. The source ZIP does not carry the large MSI/runtime archive. Do not assume an artifact can be rebuilt byte-identically merely because source and version numbers look similar.

For actual desktop changes, issue a new MSI ProductVersion and ProductCode, keep the UpgradeCode/component UUID policy stable, update all bounds/labels together, and test the real major upgrade. Alternatively separate immutable desktop-release inputs from launcher-release documentation before claiming reproducible builds.

### Launcher-only build after the frozen MSI and payload/icon are available

Run on the build host, from the extracted source root. These are engineering build steps, not user-PC recovery commands:

```bash
python3 setup/fetch_reference.py
pwsh -NoLogo -NoProfile -File setup/build_native.ps1
python3 setup/build_setup.py
python3 tests/verify_setup.py
pwsh -NoLogo -NoProfile -File tests/Test-AutomaticSetup.ps1
```

`build_setup.py` expects the verified `dist/whispr-vpn-1.0.2-x64.msi`, matching `dist/VERIFICATION.json`, original guard, compiled helper and staged `payload/assets/whispr-vpn.ico`. Restore these from verified release material or stage them without silently changing/reissuing the MSI. Full MSI-building instructions in BUILD.md need the version discipline above.

A separate generated `SOURCE-INDEX.json` in this kit records exact current source hashes and function line locations to help the next engineer navigate. It does not change product source. The kit's `validation/` is copied from the latest `dist` reports. Older reports in legacy pack folders are not the current setup's acceptance evidence.

## 17. Non-negotiable operating constraints

- No blanket `Stop-Process -Name pwsh`, Tor, Explorer, service-name guessing or user-led Task Manager hunt.
- No Windows/network/firewall/Winsock/DNS reset to hide an installer bug; no arbitrary adapter/driver removal; no deletion of Windows Installer cache/registry branches.
- No repeated DISM/CHKDSK merely because earlier troubleshooting was unsuccessful.
- No shared private device key, no SSH private key collection, no dumping generated engine configuration into a public log/handover.
- No changing active VPS keys/peer registrations or flushing host/cloud firewall rules to debug local setup. Keep hosted sites/mail and the unrelated WireGuard tunnel intact.
- Keep user's valid current task host and preferences unless a separately justified, tested migration is explicitly agreed.
- Make cleanup/recovery an engineer-owned, reviewable product action, with exact scoped ownership, logs and tested compensation. Do not move the burden back to the user.
- No automatic forced reboot. Explain any real Windows reboot requirement accurately.
- No “all fixed”, “kernel safe”, “leak-proof” or “green” statement based solely on a built artifact, historical screenshot, ARMED label or mocked tests.
- The current user instruction is to hand over. Do not resume patching/installing until continuation is requested.

## 18. Copyable brief for the next engineer / assistant

> This is whispr's Windows hybrid VPN and installer project. The transport previously worked, including Frankfurt; current live PC state is unknown. The problem is installation/upgrade/removal after old/partial installs and surviving tasks/processes. Do not make the user identify or kill processes, run generic OS/network resets, or recreate their device identity. Latest launcher is 1.0.3 and embeds frozen desktop MSI 1.0.2. Prior setup 1.0.2 failed before shutdown because Windows PowerShell runtime Add-Type compilation inherited an invalid Npcap LIB path. Version 1.0.3 bundles a hash-verified precompiled .NET Framework helper and passes invalid-LIB/LIBPATH/no-Add-Type regression tests, but no native Windows end-to-end success is recorded. Read the supplied source and validation limits, inspect existing logs if continuation is authorised, then reproduce actual Windows process/task/SCM/TUN/MSI paths in a disposable VM. Review compensation gaps, old reset-pack scope/icacls defect, and the frozen-MSI rebuild/version trap. Full automatic partial-client recovery/uninstall is unfinished. Preserve private state and existing endpoints. The current task was handover only.

---

**Record boundary:** This document records the visible conversation, current saved release metadata and inspected source/build reports as of 2 November 2026. It intentionally does not assert a fresh Windows/VPS inventory or a successful execution that was never reported. No installer, live process shutdown or server change was performed to produce this handover.

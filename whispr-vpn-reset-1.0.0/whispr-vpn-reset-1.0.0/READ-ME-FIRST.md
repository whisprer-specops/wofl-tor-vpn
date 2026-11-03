# whispr VPN broken-install reset 1.0.0

For the mixed/partly deleted **Hybrid VPN 0.4.x + tray/map/group addons + desktop MSI 1.0.0** installation built in this conversation. Windows 11 x64. This is a local reset; no VPS login or sudo password is needed.

## Run it

1. **Extract this entire ZIP into Downloads.** Do not run it from inside the ZIP or an installed Program Files directory.
2. Double-click **START-RESET.cmd** and approve Windows UAC. It uses Windows' own PowerShell, so a missing bundled PowerShell does not prevent recovery. Leave its window open.
3. Wait for **RESET COMPLETE**. If it says a restart is required, restart Windows first. If it says **STOPPED**, do not reinstall yet; its displayed backup folder contains the logs. Rerun the same pack to resume after addressing that error.
4. Double-click the included **whispr-vpn-1.0.0-x64.msi**. Accept the licence and install. It should now be a fresh installation rather than the old maintenance/uninstall flow.
5. Start **whispr VPN** from the Start menu and choose **SET UP THIS PC once**. This restores the actual client files and downloads its original verified Tor/sing-box packages; it reuses the preserved device key and exit profiles. Open the tray, select an exit and connect; wait for verified green. Auto-connect is off after reset; re-enable it only after verifying the new connection.

Installing the MSI alone installs the desktop/setup tools, not the connection engines. **Set up this PC is necessary after this reset**, even when the control centre sees the preserved key/exits.

Optional direct command from **Administrator PowerShell**, in the extracted folder:

```powershell
.\Reset-WhisprVpn.ps1
```

Inspection without changes:

```powershell
.\Reset-WhisprVpn.ps1 -InspectOnly
```

The double-click launcher requests elevation and permits the script for that child PowerShell process only; it does not write execution-policy settings. Do not disable Windows security controls if the unsigned package is blocked. Both this recovery pack and the MSI are unsigned.

## What it does

- Validates the exact included MSI and recovery guard using pinned SHA-256 values before making changes.
- Identifies our single desktop MSI ProductCode/UpgradeCode through Windows Installer APIs. It does **not** query Win32_Product, delete Windows Installer registry branches, erase C:\Windows\Installer, or edit a cached MSI.
- Backs up and disables/removes only recognised whispr background/sign-in tasks, then stops whispr processes by executable/script path and rechecks their creation time. Other PowerShell sessions, Tor Browser, Proton and the separate official WireGuard tunnels are outside its scope.
- Removes only the recorded/dedicated **whispr-hybrid** TUN device. It does not uninstall a driver package. If the adapter's ownership cannot be established, it stops rather than guessing.
- Uses the included original guard to remove only whispr Hybrid VPN's fixed WFP provider/filter set and confirms **DISARMED**. There is no firewall/Winsock/network reset.
- If the desktop MSI is registered, repairs its files from the original verified MSI, including the runtime/scripts needed by uninstall. It then quarantines the old client and unregisters the desktop through its real MSI uninstall. The app-owned runtime lease is cleared only after its consumers have been stopped/removed.
- If normal removal returns MSI 1603, independently rechecks the removed core/tasks and disarmed guard, then retries the exact pinned package with its own upgrade-removal condition. That skips its redundant script preflight without changing execution policy or editing a cached MSI. A second failure stops and retains both logs.
- Checks that Windows Installer no longer recognises the product before declaring the fresh-install state ready.
- Quarantines old client/state/desktop leftovers in an administrator/SYSTEM-only backup. It copies back only the device key, approved profiles, public request/group catalogue and group/my-vps JSON needed for reuse. Old executable files, engine config, live session records and startup tasks are not restored.
- Records an interruption journal so a retry continues from the same original backup. A retry never overwrites that first backup. Keys already missing before recovery cannot be reconstructed; the script tells you if a new device approval will be needed.

## Backups and retained identity

Backups live under:

```
C:\ProgramData\whispr-vpn-reset-backups\<timestamp-id>\
```

The actual path is printed. It may contain **private keys**, old configuration, task XML and MSI logs. **Do not share or upload the whole backup.** The original key/profile files are retained there even after successful re-seeding. This pack does not change/revoke any VPS server peer; a preserved key continues to represent the same device.

Only supported Hybrid/MSI paths and the exact 1.0.0 MSI family are handled. Unrelated or earlier distinct TorVPN software is not broadly removed by name. Downloaded source ZIPs/folders are left alone; do not run their old installers after recovery.

## Verification and limit

Automated checks cover PowerShell parsing, key/profile preservation, stale-session exclusion, process/task ownership boundaries, repeat-backup protection, and acceptance of the reset-seeded state by the original friend installer with its Windows/download boundaries mocked. Original MSI/guard bytes are pinned and verified.

**Actual Windows MSI repair/uninstall, COM task removal, adapter removal and WFP recovery could not be executed on this Linux build host.** The script stops on an unconfirmed operation and keeps its backup/log. It does not promise success for arbitrary unrelated installer-registry damage. Native failure codes and MSI logs are retained for that case. It performs no DISM, SFC or CHKDSK scan.

Licence: the supplied Hybrid License is in LICENSE.md. The embedded original MSI retains its dependency notices; the recovery guard's source and third-party notices are in tools/source and tools/licenses.

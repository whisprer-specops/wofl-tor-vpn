# Build and review

This source kit creates a real Windows Installer MSI with an embedded cabinet. It is not a renamed ZIP. Version: desktop 1.0.1; friend base 1.0.0; group/flag addon 1.0.1.

Build environment used: Ubuntu 24.04, Python 3.12, Pillow, GNOME msitools/wixl **0.103+repack-1build3**, Libmsi 1.0 via GObject introspection. Portable PowerShell **7.6.9 Windows x64** is fetched from its official GitHub release and SHA-256 pinned in dependencies.lock.json. No downloaded executable is run on the Linux build host. The bundled Rust guard and original group/core sources are retained from the supplied packs.

## Rebuild on Ubuntu / WSL

Install distribution packages (this command prompts for your local sudo password):

```bash
sudo apt-get install wixl msitools python3-gi gir1.2-libmsi-1.0 python3-pil gcc gcc-mingw-w64-x86-64
python3 fetch_dependencies.py
python3 prepare.py
python3 native/build.py
gcc -std=c11 -Wall -Wextra -Werror native/policy_test.c -o /tmp/whispr-policy-test
/tmp/whispr-policy-test
/usr/bin/python3 build_msi.py
/usr/bin/python3 tests/verify_msi.py
```

If PowerShell 7 is available on the build host, also run:

```bash
pwsh -NoLogo -NoProfile -File tests/Test-Source.ps1
```

The MSI sets REINSTALLMODE=amus so modified unversioned desktop scripts are refreshed by an upgrade/repair. This applies only to the desktop components owned by this MSI; the external VPN client/state are not in its File/Component tables.

The native custom action is built with MinGW-w64 for x64, linked to Windows system DLLs only. `Inventory` is read-only and populates the UI. `Enforce` is a deferred, non-impersonated action after InstallInitialize and before ProcessComponents/RemoveFiles/InstallFiles. Its operation/path data use CustomActionData, and it independently repeats discovery instead of trusting the UI result. The former installed-script uninstall action is not scheduled. Neither native action changes registry, files, tasks, network protection or keys.

The output is `dist/whispr-vpn-1.0.1-x64.msi`. The generated Product.wxs is rebuilt with local source paths. The build caches a base MSI only while every payload file hash and the generated WiX XML match. Native MSI UI tables are then added using Libmsi. `tests/verify_msi.py` reads the **actual MSI**, extracts the embedded cabinet using a separate reader, compares every file, checks UI references/tab cycles and verifies the supplied licence text and gating conditions.

When building a future release: keep UpgradeCode and the component UUID namespace stable; increment MSI ProductVersion and issue a **new ProductCode**. Update UpgradeVersion bounds, desktop version labels, output names and release docs together. The current ProductCode is for 1.0.1 only. Never ship a materially changed MSI with the same version/code after distribution. The unsigned build is not Authenticode-authenticated.

## Packaging boundaries

- MSI owns only `%ProgramFiles%\whispr VPN`, its HKLM product registration, and the Start menu shortcut.
- Install/repair never invoke VPN setup, server scripts, recovery or connection. Existing client files/state remain outside this MSI.
- Setup/import/update/recovery/removal are explicit user actions in the control centre. They run the original client/group code under the existing task host. Mixed or unverifiable hosts are refused; no task is silently rewritten.
- The friend installer has one additive parameter/sidecar change: DesktopSuiteRoot records desktop ownership only when a new core directory is created. Original transport configuration and guard logic are unchanged. Prior MIT notices are retained; project licence copies and manifests are updated in staging.
- Removal preflight is read-only. A runtime lease / owned-client marker prevents stripping the runtime from a configured client. The original client uninstaller runs explicitly as the interactive user before MSI removal, preserving local keys by default.
- Group JSON/configuration live in a secured writable workspace outside Program Files, separate from MSI files and private device state.
- Main transport dependencies are fetched by the original checksum-verifying installers. They are not embedded or repackaged as different binaries.

## Required Windows acceptance before general release

The build host cannot run Windows Installer / WinForms. The automated build checks are **not** native execution, visual testing, kernel validation or a leak test. Keep this as a release candidate until the following pass on a disposable Windows 11 x64 VM and an existing-client test machine.

1. Double-click MSI. Confirm artwork, readable licence, keyboard access/scrolling, disabled Next before acceptance, Back retaining state, and cancellation without installing. Verify 100%, 150%, 200% display scaling. Check the supplied licence text against LICENSE.md.
2. Complete install with UAC. Check Add/Remove Programs icon and Start menu shortcut. Open control centre, inspect the splash and layout. Do not grant an untrusted publisher any security exception; the release is unsigned.
3. On a fresh VM, attempt a quiet install **without** ACCEPT_LICENSE=1; expect launch-condition failure and no files installed. An authorised quiet install requires `msiexec /i whispr-vpn-1.0.1-x64.msi /qn ACCEPT_LICENSE=1 /L*v install.log`. The acceptance property does not bypass Windows/UAC or endpoint approval.
4. Existing-client machine: snapshot its keys, peer/profiles, core static hashes and task actions locally (never distribute secrets). Install/open desktop and confirm they are unchanged. Open original tray, verify a connection and close the control centre; the background session must stay running. Verify its existing sign-in preference remains unchanged.
5. Fresh VM: Set up this PC with Internet. Confirm unique local key creation, no copied owner identity, pinned downloads, public request export, and no automatic VPN connection. Approve it on a test VPS using the documented group flow, import group.json, test Tor + UDP verification and the map/flags.
6. Group & endpoint tools must open a **visible** console for user input and SSH/sudo. Confirm user-edited my-vps.json/group.json survive opening the desktop, MSI repair and a versioned upgrade. Test importing malformed or unrelated JSON fails clearly.
7. While the desktop/bundled runtime is in use, verify Retry/Cancel behaviour on repair/upgrade and no forced task termination. Cancelled/failed MSI transactions must roll back desktop file changes.
8. Confirm removal through Settings is blocked while its client/runtime is leased. Disconnect/recover, close tray and use Remove VPN client; confirm guard off, own tasks removed, keys retained, then remove desktop. Pre-existing system-PowerShell clients must remain installed when removing only desktop. Server peers must be revoked separately when appropriate.
9. Versioned upgrade test: build a higher version with new ProductCode and the same UpgradeCode/component namespace. Confirm only one installed product remains and original core/state/group files remain intact. Downgrade must be blocked.

Sign the final MSI with your own Authenticode certificate if you have one; this kit contains no signing credential or certificate claim.

## Added Windows acceptance cases for 1.0.1

Snapshot a disposable machine before each damaged-install case. Test quiet and full UI paths: healthy 1.0.0 upgrade; 1.0.0 desktop with Model.ps1/Desktop.ps1 or portable pwsh deleted; missing client Common.ps1; missing older cached MSI; retained friend identity after normal uninstall; interrupted installing phase; saved peer without device key; stale runtime lease without actual client/task/protection; active bundled-runtime session; remaining whispr task or persistent protection; reparse point at install/state root. Confirm the expected category and no file/state changes when blocked. Confirm managed desktop repair restores missing files and a successful major upgrade leaves one product registration. Native adapter/API execution remains untested in this build environment; pure policy and static MSI sequencing checks do not replace these Windows tests.

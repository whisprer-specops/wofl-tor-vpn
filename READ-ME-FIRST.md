# whispr VPN Desktop 1.0.0 — Windows 11 x64

Double-click **whispr-vpn-1.0.0-x64.msi**. Read the supplied Hybrid License, tick **I accept**, then install. Windows asks for administrator approval. The package is unsigned; it has no publisher certificate. Do not disable Windows security controls to install it.

Open **whispr VPN** from the Start menu. The artwork appears briefly, followed by the control centre. Installing or opening this package does not connect, recover, replace keys, or alter VPSs.

## Your already-working PC

Choose **Open VPN tray**. This uses the existing client and the PowerShell host recorded by its owned background/sign-in tasks. Your current endpoints, private identity, map, country flags, background session and sign-in preference are retained. The control centre shows setup/configuration state; only the original tray's verified green status confirms a connection.

To apply the packaged group support and country flags, disconnect/recover and close the original tray, then choose **Update group support / flags**. This explicit operation runs the existing group 1.0.1 installer. It refuses a running connection or tray. Installing the MSI alone does not apply it.

## A friend's new PC

1. Install the same MSI and open **whispr VPN** under the Windows account that will use the VPN. It needs an administrator account/UAC. PowerShell is bundled.
2. Choose **Set up this PC**. Internet access is needed to download the original pinned Tor and sing-box distributions; their SHA-256 checks remain enforced. Allow several minutes. No SSH/sudo login or server setup is performed here.
3. Choose **Exports**, then send **friend-request.json** to the group owner. Each PC generates its own private key; never copy ProgramData or device-key.json to another person.
4. The group owner uses **Group & endpoint tools** to add the request and **Publish / sync MY VPSs**. Every VPS owner must publish/sync their own endpoints to register the new member. Those operations open visible SSH prompts and require that VPS's sudo password.
5. Send the updated **group.json** back to members. On the new PC, choose **Import group / access file**, then open the tray, select an exit and connect. Wait for verified green. Legacy **friend-access.json** files are also supported on a friend client.

For a new independent group, use **Create my own group**, then Group tools to add VPS details and publish them. The original JSON exchange and per-owner SSH/sudo permissions remain unchanged. A group file is public configuration, not a signature proving its sender: exchange it directly with the intended people. Adding a member on paper does not register them on a VPS until its owner publishes/syncs.

## Closing windows and startup

Closing this control centre never stops the independent VPN background session. Use the original tray to connect, disconnect, select the map/exit and set its existing **auto-connect at sign-in** option. MSI installation does not enable auto-connect. This is sign-in startup, not a before-login Windows service.

## Paths and removal

- Desktop suite: `%ProgramFiles%\whispr VPN` (owned by MSI).
- Existing connection client: `%ProgramFiles%\whispr Hybrid VPN`.
- Private connection state: `%ProgramData%\whispr-hybrid`.
- Group workspace, exports and redacted setup logs: `%ProgramData%\whispr-vpn-desktop` (administrator-only).

A desktop-package upgrade preserves the external client, keys and group workspace. Close the control centre before upgrading. If its bundled PowerShell runtime is currently running the VPN/tray, disconnect and close those first; the MSI refuses files-in-use rather than forcibly terminating them. Restarting the MSI alone is not VPN recovery.

For a fresh client created through this MSI, first Disconnect / Recover and close its tray, then select **Remove VPN client** in the control centre. That runs its original uninstaller, retains private keys/settings, removes its own user tasks and releases this runtime. Then uninstall **whispr VPN** through Windows Settings or **Uninstall desktop**. Removing only the desktop is blocked while an owned client/task needs its runtime. If first-time setup was interrupted, retry Set up this PC to finish, then remove it. Server registrations are not revoked by local uninstall; their owners must revoke the device separately.

For your pre-existing client using system PowerShell, removing the desktop package leaves that client and its settings in place. Its original tray shortcut remains available. Local keys and group files are never deleted by this MSI. Clearing those is a separate deliberate action.

## Verification boundary

The build includes PowerShell parse checks, pure host-selection tests, MSI database/reference and licence-gate checks, plus cabinet extraction with byte-for-byte payload verification. The underlying supplied VPN/group packages are included with their prior tests. This release has **not been executed through Windows Installer or visually tested on Windows** in the build environment. Use the documented Windows acceptance check before wider distribution. No claim of leak/crash validation or a newly verified VPN connection is made by this packaging build.

The supplied licence text is unchanged. See THIRD-PARTY.md for the runtime and other dependency notices. Build sources, original artwork and validation scripts are in the separate source kit.

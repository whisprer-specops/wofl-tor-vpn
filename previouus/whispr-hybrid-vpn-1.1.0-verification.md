# whispr.dev Hybrid VPN 1.1.0 — maintenance fix2

Built 2026-11-03. Replaces the UI-fix1 MSI involved in the supplied SHARE-THIS report.

## What the captured failure proves

The attempt at 2026-11-03T06:11:12.9054215Z returned 1603. The input MSI SHA-256
was `89635f4ea5cd120b247003af356e15ec80eba89afbb04081064331300f5a439b`.

`new-msi.log`, line 2820:

> whispr MSI Prepare failed: Exception calling "GetFullPath" with "1" argument(s): "Illegal characters in path."

Line 2825 also reports error 2867 because the ErrorDialog property was missing.
These are installer defects; the supplied report does not establish a dirty-PC or
shared-driver problem. No additional cleanup is prescribed for this failure.

## Repair

The pre-journal scheduled-task scan passed raw commands from unrelated tasks into
.NET Framework's strict path parser. A matching source defect is repaired: task
commands are normalized for balanced quotes and environment references, then
validated before path comparison. Malformed unrelated commands no longer abort
setup. Genuine dependencies on the private whispr runtime still block cleanup;
unverified whispr-named tasks still fail ownership checks. The original exception
has no stack/task name, so the exact offending task is not identified by the log.

The MSI now includes a standard error dialog with all seven response events. The
verbose log remains the source of detailed maintenance exceptions. The existing
fix for error 2810/tab order is retained.

## Executed verification

- MinGW-w64 GCC 13.2.0 native build completed with `-Wall -Wextra -Werror`.
- PowerShell 7.6.9 path regression tests passed: plain/quoted/environment-referenced
  runtime dependencies, malformed/control-character commands, prefix boundaries,
  unrelated tasks, and unverified ownership rejection.
- Existing lifecycle rollback tests passed: original identity/client restoration,
  independent service restoration, partial snapshot rejection, symlink rejection.
- Both changed PowerShell files parsed without errors.
- All 11 UI unit tests passed. All 11 authored dialogs pass focus-cycle validation.
- Actual MSI verification passed: product/upgrade identity, x64 ownership,
  transaction sequence, deferred elevation/rollback/commit flags, maintenance UI,
  error-dialog response events, native exports and embedded resource identity.
- Extracted and checked SHA-256 for all 726 installed files against the manifest.
- Compared old and new packages: all other tables and streams match. Client CAB
  is byte-identical (142,802,713 bytes), SHA-256
  `a381bae336809fc14371410cc33274500233cd378af36dd4b24bd205231cca8d`.
- The precompiled helper, Rust guard and client launcher remain unchanged.

## Package identity

ProductCode: `{21A8F5D7-2682-45C8-B2DE-92C9D8699A11}`

UpgradeCode: `{260C4308-9E2C-4C71-B65B-05199CB8262E}`

ProductVersion: `1.1.0` (small maintenance update; PackageCode is new).

PackageCode: `{55FFAB44-91DE-4272-BA15-2249824BA888}`

MSI SHA-256: `0e5df73a896fe073e086b56afac5d9a5aee58f6b32306bc2895700593e4ee12a`

## Install this revision

Download the MSI again; an older copy with the same filename is a different package.
Double-click the new MSI and approve Windows elevation. If it offers maintenance,
choose Repair. Fresh installs proceed through the license/install screens.
No reset or driver removal is needed to try this revision.

For an installation with a verbose log, open PowerShell in the download folder:

```powershell
$msi = Join-Path $PWD 'whispr-hybrid-vpn-1.1.0-x64.msi'
$log = Join-Path $env:TEMP 'whispr-hybrid-vpn-maintenance-fix2.log'
& "$env:SystemRoot\System32\msiexec.exe" /i $msi /L*v $log
```

After installation, open whispr from Start, select an endpoint and Connect. Only
live transport verification constitutes a working green VPN. A fresh installation
still requires Internet access for the existing pinned Tor download.

## Validation boundary and confidence

No native Windows host is available here. Windows PowerShell 5.1/Task Scheduler
COM, native install/repair/uninstall and live VPN connection acceptance were not
run. The delivered package is a tested repair candidate for the captured failure,
not proof of completed Windows acceptance. It remains unsigned.

Confidence (judgment, not a statistical measurement): error-free 0.85;
suitability 0.95; effectiveness 0.85; efficiency 0.95; completeness 0.90.
The lower scores reflect missing native Windows acceptance and the missing original
exception stack. Static checks cannot remove that uncertainty.

Full source, exact build commands and test evidence accompany this MSI. The source
archive deliberately excludes the large MSI and downloaded dependencies; fetch and
stage pinned dependencies as described in BUILD.md for a full rebuild. The bounded
update command instead accepts the exact hash-checked prior package.

Primary MSI error UI reference:
https://learn.microsoft.com/en-us/windows/win32/msi/error-dialog-style-bit

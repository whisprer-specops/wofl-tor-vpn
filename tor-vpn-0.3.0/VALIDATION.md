# Validation — TorVPN 0.3.0

Build host: Linux x86_64; Rust 1.99.1; MinGW x86_64 GCC 13-posix.
Target: x86_64-pc-windows-gnu.

- Both final Windows release executables compile and link.
- Windows-target workspace Clippy passes with warnings treated as errors.
- 17 Rust tests pass (13 unit tests + 4 real TCP integration tests).
- A generated torrc, including paths with spaces, passes an actual Tor
  0.4.9.11 `--verify-config` invocation. This test does not join the Tor network.
- PowerShell 7.6.9 parses all 13 included PowerShell scripts without errors.
- Mocked Windows-networking contract tests pass for firewall policy preservation,
  existing outbound allow suspension/restoration, exact adapter selection, DNS
  block scope, two /1 tunnel routes, physical-default preservation, and recovery
  after partial route creation failure. They do not call real Windows cmdlets.
- PE headers confirm amd64 Windows exes and Wintun DLL. Import inspection finds
  Windows system DLLs, not separate MinGW runtime DLL requirements.
- The obsolete 0.2.0 installer, Tor 0.4.8.10 cache and loose firewall patch ZIP
  are excluded. Repair downloads a pinned current Tor bundle and rejects bytes
  that do not match Tor Project's published SHA-256.

Actual Windows SCM/Wintun/Windows Firewall execution, real DNS resolution through
Tor, the target-PC Tor download, and end-to-end full-tunnel/leak testing remain
unverified. The repair's acceptance check executes on Windows and requires an
ordinary system-routed HTTPS connection to return IsTor=true before marking the
full tunnel engaged. Read README.md for recovery and protection boundaries.

The repair is a complete source/binary package, not a claim that an unexecuted
Windows networking path has been proven correct. If an on-PC operation fails,
use Get-Diagnostics.ps1; status and logs now preserve the failure reason.

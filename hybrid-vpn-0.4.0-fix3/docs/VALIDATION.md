# Validation record — 1 November 2026

## Completed here

- Guard type-checked and compiled for `x86_64-pc-windows-gnu` with Rust 1.99.1 and locked windows-sys 0.61.2/windows-link 0.2.1 dependencies.
- The shipped Windows PE import table was inspected. The linked guard depends on Windows system DLLs; it does not require a separately installed Rust runtime or libunwind DLL.
- PowerShell source parsed with the actual PowerShell 7.6.9 parser.
- Managed C# process-job helper compiled with PowerShell's C# compiler. Native Windows job calls were not executed here.
- Configuration produced by the actual PowerShell generator accepted by sing-box 1.14.4, for IPv4-only and dual-stack WireGuard peers.
- The shipped PowerShell SOCKS/STUN verifier exercised against a loopback fixture: expected IPv4 exit accepted; a different exit rejected. A real output-contamination defect found by this test was fixed before packaging.
- Python server sources syntax checked; further test output is included in TEST-RESULTS.txt.
- Pinned sing-box Linux and Windows release archives downloaded here and SHA256-verified against upstream GitHub release digests.
- Tor archive pin independently checked against Tor Project's published checksum list. This build environment returned an HTML block page for Tor binary downloads; the hash check rejected it. The installer fetches the genuine archive directly on the user's machine and rejects mismatches before server/client activation.

## Blocked / not established

This host denies netlink initialization even for the backend's userspace-only loopback test. The attempted real WireGuard transport integration test is therefore **skipped with that reason**, not counted as a passing exchange. No elevated Windows runtime is available here. No test connected to the user's VPSs from this environment.

Unverified: actual WireGuard handshake/NAT on the chosen VPS; Windows WFP enforcement; TUN DNS/route behavior; abrupt process termination/reboot recovery; coexistence with the real Ollama/game tunnels; IPv6 egress and leak behavior; stable CPU/RAM consumption on the target PC. These are release gates, not claims inferred from successful compilation.

## Windows staging gates

Use a Windows test VM with console access first. Snapshot it. Keep Recover.ps1's full command available offline. Installation alone does not arm the guard or start the client.

1. Run Install.ps1, then `tests/Test-Release.ps1` with the installed engine path. Confirm the expected server and client key report, with no secrets exported.
2. Start a session. Verify Tor bootstrap and the initial TCP/UDP results. Check physical-interface packet capture: ordinary app TCP must reach Tor transport only; ordinary UDP must reach the selected WG endpoint only. Verify DNS has no physical UDP/TCP 53 fallback. Check IPv6 separately.
3. Confirm existing private tunnels, Ollama listener and game access. Activate those tunnels before Hybrid so their endpoint exceptions can be recorded. Verify website/SSH services on the server independently.
4. Terminate only the recorded routing process. Confirm the owned child job stops, protection remains ARMED, and fresh ordinary TCP/UDP attempts cannot escape through physical interfaces. Repeat for Tor and the dedicated supervisor. A process-alive check alone is insufficient.
5. Run Recover.ps1. Confirm the exact owned TUN and provider are gone, unrelated adapters/rules/profiles match the baseline, and normal networking returns. Repeat normal `stop`, failed bootstrap, failed UDP verification, and restart/recovery paths.
6. Test firewall reload and changes of physical network. Failure must remain blocked, not silently choose another exit. Inspect resources for a sustained session.

Do not call the release production-ready until these gates pass. No numeric confidence score can substitute for these missing Windows/network observations.

## Reproducing nonprivileged checks

PowerShell 7.6.x and pinned sing-box 1.14.4:

```powershell
.\tests\Test-Release.ps1 -Engine 'C:\Program Files\whispr Hybrid VPN\bin\sing-box.exe'
```

Python 3.10+ plus PowerShell 7 and the appropriate sing-box executable:

```text
python tests/test_transport.py --engine PATH_TO_SING_BOX --pwsh PATH_TO_PWSH
```

The integration fixture removes the privileged TUN only for its test setup and uses loopback peers. It is deliberately not a Windows kill-switch test. The parser/STUN tests use local fixtures and do not contact a third-party STUN service.

## Fix 3 permissions regression

The compound recursive icacls DACL edit was replaced with complete explicit .NET DACL persistence, repairing directories before enumerating their descendants. Test-Permissions.ps1 exercises an inaccessible owned child and repeated repair with retained fixture contents on Windows. It is supplied but has not been run in this Linux environment. PowerShell 7.6.9 parsing and existing server/configuration tests passed after the change. This does not establish Windows ACL runtime success before the corrected installer is exercised there.

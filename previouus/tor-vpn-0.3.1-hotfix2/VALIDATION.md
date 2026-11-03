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

## Firewall-origin hotfix 1

PowerShell-only changes; the previously built EXEs are unchanged. All 14
PowerShell files parse. Regression tests now simulate Windows origin metadata
being None unless -TracePolicyStore is supplied, so the old false rejection
would fail the test. Traced Local rules succeed and restore; GroupPolicy,
Dynamic, Generated, Hardcoded and unclassified origins are rejected before
mutation with exact identifiers. An ignored disable operation is detected by
an effective-policy reread. Earlier route/DNS/restoration tests still pass.

The actual rule origins on the user's PC are not present in the uploaded
report. This corrects the metadata-query defect; it does not prove that no real
non-local rule or later Windows networking issue exists on that PC.

## Local/Dynamic firewall hotfix 2

PowerShell-only changes; service/tray EXEs remain the validated 0.3.0 builds.
All 14 PowerShell scripts parse. Eight mocked networking contract groups pass:

1. Firewall/DNS/routes and restoration.
2. Partial route failure rollback.
3. Traced Local origin, unsupported origin reporting and effective suspension.
4. SharedAccess-style Dynamic suspension/restoration, preserving disabled rules.
5. Local restoration after a Dynamic provider refuses suspension.
6. Ignored Dynamic restoration detected, backup retained and retry completed.
7. Expired Dynamic identity not recreated or mistaken for a Local replacement.
8. Legacy 0.3.0/hotfix1 string-array backup recovery.

Microsoft's Disable-NetFirewallRule and Enable-NetFirewallRule documentation
explicitly shows Dynamic ActiveStore objects used with -InputObject. This path
has not been executed against the target Windows SharedAccess rule here. The
on-PC effective-policy check and restored-state check remain authoritative.

## 0.3.1

- Windows x64 service and tray release binaries rebuilt from 0.3.1 source.
- Windows-target Clippy with warnings denied.
- Rust tests include preserved child output on timeout, real nonzero-exit error
  output, and Windows UTF-8 BOM checkpoint parsing, in addition to prior tests.
- All 14 PowerShell scripts parse.
- Nine networking contract groups pass. The new fixture uses 187 Local rules
  plus 1 Dynamic rule, asserts exactly two suspension and two restoration
  command invocations, verifies restoration, and checks persisted checkpoints.
- Windows Firewall provider speed has not been measured here. A batch fixture
  demonstrates call reduction and state semantics, not native timing.
- Actual Wintun/WFP/SCM end-to-end operation remains a target-PC check. The
  submitted log establishes a firewall-script timeout; it does not identify the
  individual stalled cmdlet because 0.3.0 did not retain checkpoint output.

## 0.3.1 hotfix1

No Rust code or EXE changes. All 14 PowerShell scripts parse. Eleven mocked
networking contract groups pass. The mock now emits the exact observed
CmdletizationQuery_NotFound,Get-NetFirewallRule error when a filtered rule set is
empty; the zero-remaining-allows success path therefore exercises native-style
error handling. Four injected non-empty-query failures (access denial, provider
failure, unrelated ObjectNotFound and wrong-category lookalike) remain fatal.
An initially empty rule set also applies and recovers without inventing rules.

The uploaded diagnostic(3) attachment contains the older 21:47 run; the pasted
22:04–22:05 output is the current evidence for this exact failure. It proves
both suspension batches returned and verification failed on no matching rules.
It does not contain the subsequent full recovery trace or any Tor bootstrap.

## 0.3.1 hotfix2

No Rust code or EXE changes. All 14 PowerShell scripts parse. Twelve mocked
networking contract groups pass, including rejection of the observed IPv6
loopback filter. The revised apply path creates exactly three IPv4-scoped allow
exceptions, preserves the Tor executable/TCP and named-adapter constraints,
and verifies Block defaults across all profiles. Existing restoration,
187-Local/1-Dynamic batching, empty-query and real-query-error contracts pass.
Running the revised mock against the previous hotfix's fw-apply.ps1 fails at
the observed IPv6 loopback rule with 0x80070057; the revised script passes.

The uploaded diagnostic(4) is current: the zero-remaining-allows check succeeded,
Windows rejected ::1, Tor had not started, and recovery completed with the
original 187 Local plus one Dynamic allow rule restored. The revised native
Windows firewall rules and full Tor/Wintun connection have not been executed
in this Linux test environment. These mocks do not establish leak protection.

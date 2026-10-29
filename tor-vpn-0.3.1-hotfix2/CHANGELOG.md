# 0.3.1 hotfix2 — 2026-10-25

- Remove the IPv6 loopback address filter rejected by Windows and the adjacent
  broad IPv6 block range. Restrict Tor TCP and tunnel allows to 0.0.0.0/0;
  retain the IPv4 loopback allow. Native IPv6 falls under default outbound Block.
- Retain typed rule backups, effective-policy verification and restoration.
- Make the firewall mock reject the observed ::1 failure. Check that all allows
  are IPv4-only and preserve the Tor executable/TCP and exact tunnel constraints.
- Preserve 0.3.1 binaries and support the existing -ScriptsOnly update path.

# 0.3.1 hotfix1 — 2026-10-25

- Normalize only NetSecurity's native CmdletizationQuery_NotFound ObjectNotFound
  result into an empty set. Keep other query failures fatal.
- Use the helper consistently for firewall apply/recovery, DNS cleanup and
  diagnostic collection, including the successful zero-remaining-allows check.
- Make networking mocks emit the real empty-query error. Add checks that real
  access/provider/unrelated errors propagate, and an empty initial ruleset can
  apply/recover correctly.
- Add -ScriptsOnly updater mode for installed 0.3.1; binaries are unchanged.

# 0.3.1 — 2026-10-25

- Replace per-rule firewall suspension/restoration calls with Local and Dynamic
  batches; retain typed backups and effective-policy verification.
- Add persistent timestamped administrative checkpoints to console and status.
- Persist child-script stdout/stderr even when a script times out.
- Include the last checkpoint and log path in timeout errors.
- Terminate/reap the exact child process before starting timeout recovery.
- Allow firewall operations up to 300 seconds and report waiting progress;
  other scripts retain 75-second limits.
- Change tray left-click to status; keep connection controls in explicit menu.
- Update both Windows binaries while preserving Tor, driver and profile.
- Add the 187-Local/1-Dynamic batch contract and script-output/timeout tests.

# 0.3.0 hotfix 2 — 2026-10-25

- Support Dynamic outbound allow rules via live ActiveStore -InputObject,
  including the reported Internet Connection Sharing SharedAccess-Out rule.
- Save source-aware recovery records before suspending any rules.
- Restore Dynamic rules through live objects; preserve originally disabled
  state; do not recreate expired runtime rules or confuse different origins.
- Verify restored enabled state; retain recovery metadata if restoration fails.
- Preserve recovery compatibility with 0.3.0 and hotfix1 backups.
- Update Apply-Hotfix.ps1 to back up and replace both firewall scripts.
- Add Dynamic lifecycle, partial failure, ignored restoration, expiry/name reuse
  and legacy-backup regression tests.

# 0.3.0 hotfix 1 — 2026-10-25

- Request ActiveStore rule-origin metadata with -TracePolicyStore.
- Stop labelling every non-Local/unknown origin as Group Policy.
- Preserve exact non-local/unknown rule names, types and sources in diagnostics.
- Verify effective allow rules are gone after local suspension before proceeding.
- Add Apply-Hotfix.ps1 for existing 0.3.0 installations: no binary rebuild,
  Tor download, profile reset or driver reinstall.
- Regression tests reproduce None when origins are not traced, accept traced
  Local rules, reject unsupported origins with actionable diagnostics, and
  detect an ignored disable operation.

# 0.3.0 — 2026-10-25

- Add automatic connection, defaulting on, at service startup.
- Separate observable status from the network-transition lock.
- Add status dialogs, visible action errors and log/profile menu access.
- Bound HTTP/control/script waits and read complete HTTP headers.
- Cache connection-time verified IP instead of making a network request per poll.
- Verify ordinary Windows HTTPS routing before marking full tunnel green.
- Mark diagnostic SOCKS-only mode amber and label it explicitly.
- Drain Tor stderr, retain startup errors, quote Tor configuration paths.
- Replace unchecked route/netsh commands with checked NetTCPIP cmdlets.
- Preserve the physical default, install two /1 tunnel routes, pin direct peers.
- Add firewall tunnel permission after the named Wintun adapter exists.
- Save/restore real firewall settings and suspend pre-existing outbound allows.
- Exclude loopback from explicit remote DNS blocks; block native IPv6.
- Check child process exit and retain protection on runtime failure.
- Remove generic image-name process kills and obsolete installer EXE/cache.
- Add backed-up repair, recovery, diagnostic and native rebuild scripts.
- Pin the Rust toolchain/dependencies; include x64 Windows binaries.
- Fetch current Tor with a published pinned SHA-256 before installation changes.
- Reject unsupported proxy/hopping/PQC protection claims before network changes.

Earlier investigation notes are preserved in docs/HISTORICAL_FIXES.md and do
not describe the current installation workflow or validation status.

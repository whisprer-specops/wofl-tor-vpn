# Security boundaries

This is experimental local software, not a certified or audited anonymity VPN.
See README.md for explicit fail-open recovery/restart boundaries, unsupported
traffic and the difference between SOCKS-only and Windows TCP tunnel modes.

The control API is bearer authenticated and constrained to numeric loopback
bindings. Its token is readable by local Users so the unelevated tray can
control the service; therefore any local user with token access can change the
connection state. It is not a security boundary between users on a shared PC.
Unprivileged users must not be able to write the install directory or service
state/configuration. Do not expose the API over the network.

Scripts are fixed files installed under Program Files. Parameters are JSON
encoded as base64 arguments rather than embedded shell code. Commands and
network reads have bounded waits; failure errors include captured output.

The administrative repair script backs up firewall/installation settings and
resets the application profile to a known default unless PreserveProfile is
requested. Automatic startup failures restore normal networking; this is not
an always-on fail-closed policy. Do not use the green indicator as a substitute
for an independent traffic/leak audit. Normal browsers retain their existing
fingerprints, cookies and account identities.

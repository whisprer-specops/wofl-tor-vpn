# Routing in 0.3.3

Read README.md for installation, verification and protection boundaries.

The sequence is: validate configuration and binaries; save and apply firewall;
bootstrap Tor; create the exact named tunnel; allow tunnel traffic; apply NRPT
DNS; discover Tor's direct peers; constrain ReachableAddresses to those peers;
pin their /32 routes through the current physical default gateway; add
0.0.0.0/1 and 128.0.0.0/1 as on-link routes on the tunnel; check an ordinary
HTTPS request using the system route. Green requires IsTor=true.
The HTTPS verifier retries selected temporary errors with finite bounds. If
system verification fails, a SOCKS-only diagnostic cannot make the tunnel green.

The physical /0 is preserved. Route choice does not depend on outranking that
/0's metric. Existing more-specific physical routes are not deleted; direct
application traffic on those routes is restricted by the firewall. Native IPv6
is blocked, not tunneled. Tor's UDP DNS listener is on loopback port 53; Tor
carries DNS resolution through its TCP circuits. Arbitrary UDP is unsupported.
Explicit non-loopback IPv4 UDP blocks drop such packets before tun2socks; they
exclude Tor's local DNS address. The verified route snapshot is retained after
recovery as route-applied.json for diagnosis.

Owned route details are written before mutation. Teardown removes those exact
prefix/interface/next-hop tuples. Firewall policy is separately saved before
mutation and restored rather than reset globally to Allow. The previous
session's owned settings are recovered before a new service accepts connections.
Temporary connection-failure audit settings are backed up and restored as well.
On connection failure, evidence is captured before rule removal. This capture
is bounded and does not change firewall policy or bypass an existing block.

Changing uplinks or requiring a new direct Tor peer requires reconnecting.
Transport bridges and upstream proxies require additional routing/bypass
logic and are rejected in full-tunnel mode in this repair.

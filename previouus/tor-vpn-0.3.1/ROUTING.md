# Routing in 0.3.0

Read README.md for installation, verification and protection boundaries.

The sequence is: validate configuration and binaries; save and apply firewall;
bootstrap Tor; create the exact named tunnel; allow tunnel traffic; apply NRPT
DNS; discover Tor's direct peers; constrain ReachableAddresses to those peers;
pin their /32 routes through the current physical default gateway; add
0.0.0.0/1 and 128.0.0.0/1 as on-link routes on the tunnel; check an ordinary
HTTPS request using the system route. Green requires IsTor=true.

The physical /0 is preserved. Route choice does not depend on outranking that
/0's metric. Existing more-specific physical routes are not deleted; direct
application traffic on those routes is restricted by the firewall. Native IPv6
is blocked, not tunneled. Tor's UDP DNS listener is on loopback port 53; Tor
carries DNS resolution through its TCP circuits. Arbitrary UDP is unsupported.

Owned route details are written before mutation. Teardown removes those exact
prefix/interface/next-hop tuples. Firewall policy is separately saved before
mutation and restored rather than reset globally to Allow. The previous
session's owned settings are recovered before a new service accepts connections.

Changing uplinks or requiring a new direct Tor peer requires reconnecting.
Transport bridges and upstream proxies require additional routing/bypass
logic and are rejected in full-tunnel mode in this repair.

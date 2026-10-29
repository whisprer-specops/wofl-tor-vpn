# Dependency provenance

Verified release inputs for this repair, 2026-10-25:

| Component | Version | Source |
| --- | --- | --- |
| Rust | 1.99.1 | https://static.rust-lang.org/dist/channel-rust-stable.toml |
| Tor Expert Bundle | 15.0.26, Tor 0.4.9.14 | https://download.torproject.org/tor/ |
| tun2socks | 2.6.0 Windows amd64 | https://github.com/xjasonlyu/tun2socks/releases/tag/v2.6.0 |
| Wintun | 0.14.1 amd64 | https://www.wintun.net/ |

Tor is downloaded by installer/stage.ps1, not bundled. Pinned archive SHA-256:
`c1988c701de2f24f7d098d1d6d7f507b58f27740d097f29c246e0524d639b252`

Official checksum listing:
https://dist.torproject.org/torbrowser/15.0.26/sha256sums-signed-build.txt

This release uses the published SHA-256; it does not claim an independently
completed OpenPGP signature verification. Its archive download was blocked in
the build environment, so stage.ps1 fetches and verifies it on the target PC.

All Rust dependency versions are locked in Cargo.lock. Optional PQC crates are
not included in the default build. Payload-file hashes are in SHA256SUMS.txt.
Those hashes detect changed/corrupt files; the release itself is not code signed.

Windows Firewall precedence: explicit allows override default Block, and
explicit blocks override conflicting allows. This requires temporarily
suspending existing local outbound allow rules and excluding loopback from
remote-DNS blocks:
https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/rules

Tun2socks Windows route setup:
https://github.com/xjasonlyu/tun2socks/wiki/Examples

Tor and tun2socks are separate programs with their own upstream licenses.
Tun2socks source: https://github.com/xjasonlyu/tun2socks/tree/v2.6.0
Wintun source: https://git.zx2c4.com/wintun/tag/?h=0.14.1

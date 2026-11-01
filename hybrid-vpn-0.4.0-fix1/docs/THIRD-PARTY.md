# Dependencies and release provenance

Own controller, installer, server helpers and Rust guard: MIT, copyright 2026 whispr.dev.

Shipped guard compiled from the supplied source using Rust 1.99.1, windows-sys 0.61.2 and windows-link 0.2.1 (MIT OR Apache-2.0). Their license texts are included in docs/licenses. The cross-build used LLVM-MinGW 20261020 MSVCRT; its notice/license is included. Unwind/builtins are statically linked; no third-party runtime DLL is required by the guard. Windows-native MSVC rebuild is supported by Build-Guard.ps1.

Downloaded on installation, not embedded in this ZIP:

- sing-box **1.14.4**, official SagerNet release. Source: https://github.com/SagerNet/sing-box/tree/v1.14.4 ; GPL-3.0-or-later upstream licensing applies to that component. The installer retains its LICENSE alongside the binary. Windows archive SHA256: `99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df`. Release includes libcronet.dll, copied from the same verified archive. The backend's upstream Wintun implementation supplies the Windows TUN device; no custom kernel driver is authored here.
- Tor Expert Bundle **15.0.26**, official Tor Project distribution. Windows x86_64 archive SHA256: `c1988c701de2f24f7d098d1d6d7f507b58f27740d097f29c246e0524d639b252`. The installer copies the distribution's Tor payload/data without modifying the executables. License and component details remain governed by the upstream bundle.
- Server: distribution-managed `wireguard-tools`, `iptables`, Python 3 and systemd. Apt verifies its repository packages. Versions follow the supported server distribution; no untrusted PPA or third-party install script is used.

Primary references checked during development:

https://sing-box.sagernet.org/configuration/endpoint/wireguard/
https://sing-box.sagernet.org/configuration/inbound/tun/
https://sing-box.sagernet.org/configuration/dns/server/tcp/
https://dist.torproject.org/torbrowser/15.0.26/sha256sums-signed-build.txt
https://support.torproject.org/little-t-tor/troubleshooting/check-for-leaks/
https://learn.microsoft.com/en-us/windows/win32/api/fwpmtypes/ns-fwpmtypes-fwpm_filter0
https://learn.microsoft.com/en-us/windows/win32/api/fwpmu/nf-fwpmu-fwpmprovideradd0
https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax

A locally generated SHA256 manifest detects changes relative to this delivered package. It is not a code-signing certificate or independent publisher authentication. The custom guard is unsigned. This package does not instruct Windows to disable its security controls.

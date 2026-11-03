# Third-party components and notices

The project is distributed with the user's supplied **Hybrid License (MIT + CC0)** in LICENSE.md, copied verbatim into the installer agreement. It does not replace third-party licences.

- **PowerShell 7.6.9 Windows x64**, unmodified official portable release, is embedded under runtime/powershell. Its MIT LICENSE.txt and ThirdPartyNotices.txt, including .NET/component notices, remain alongside the executable. Official source/release: https://github.com/PowerShell/PowerShell/tree/v7.6.9 and https://github.com/PowerShell/PowerShell/releases/tag/v7.6.9. The archive is pinned in dependencies.lock.json; SHA-256 was checked against the official GitHub release asset digest.
- The supplied friend/group/owner packages retain the prior project MIT notice in docs/licenses/legacy-project-MIT.txt. The friend guard's Rust/windows-sys/windows-link and LLVM-MinGW notices remain in packs/friend/app/docs/licenses. Guard source and build instructions remain included.
- **sing-box 1.14.4** and **Tor Expert Bundle 15.0.26** are **downloaded by explicit first-time client setup**, not embedded in the MSI. Their original installer SHA-256 checks, upstream component licences and downloaded notices remain in place. See packs/friend/app/docs/THIRD-PARTY.md. Existing working client binaries are not replaced by the MSI.
- Country-flag SVG/PNG assets and the original map are supplied with group 1.0.1; see that pack's asset documentation. Desktop logo and splash were generated for this release; originals are in the source kit's art folder.
- The embedded native inventory DLL is built with MinGW-w64/GCC. Runtime/header notices and the GCC runtime exception are retained under notices/native-preflight in the installed desktop, and under native/notices in the source kit. It imports Windows system DLLs and does not bundle a third-party runtime DLL.
- The MSI is built using GNOME msitools/wixl. Those build tools are not embedded in the Windows payload. Build-tool provenance is recorded in BUILD.md.

SHA-256 manifests detect changes relative to this build; they are not Authenticode signatures or independent publisher authentication. This distribution is unsigned.

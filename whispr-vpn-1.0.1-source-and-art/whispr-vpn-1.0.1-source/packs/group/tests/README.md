Tests are self-contained; client-baselines.zip contains the previous public client sources, guard binary and retained license notices, not an installed user identity.

PowerShell contract/map tests:
  pwsh -NoLogo -NoProfile -File tests/Test-Group.ps1

Linux/WSL Python tests (Python 3.10+, PowerShell 7.2+):
  python3 -m unittest discover -s tests -p 'test_*.py'

Peer/kernel tests require a root test process because the production ownership checks intentionally require UID 0. They use temporary directories and a mocked wg command, never a real interface. Use a disposable root container/WSL test environment if desired; no live VPS credentials are needed. Source/client tests explicitly replace only Windows ACL/guard/SSH boundaries in copied fixtures and run actual PowerShell file operations/validation. The original shipped source is not altered by those tests. PowerShell may be supplied with tests/test_client.py --pwsh /path/to/pwsh.

New-server bootstrap invocation and subsequent group registration are tested with the legacy installer boundary mocked. The legacy installer is shipped unchanged. Existing-server tests explicitly reject a call to the initial setup path. This does not prove Windows native UI, provider cloud firewall, Linux kernel/network or a real new endpoint works. End-to-end connection still requires live TCP/Tor and UDP verification.

Flag UI contract tests: pwsh -NoProfile -File tests/Test-Flags.ps1. The client-flow suite includes the standalone active-session-safe UI patch and restoration. Native Windows Forms display is not executed by the Linux tests.

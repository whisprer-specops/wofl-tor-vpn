"""Updater file transaction fixture on Linux; Windows ACL/WFP are not exercised."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PWSH = '/tmp/hybrid-build/pwsh/pwsh'


class UpdateTests(unittest.TestCase):
    def test_update_idempotence_and_armed_refusal(self):
        with tempfile.TemporaryDirectory() as folder:
            work = Path(folder)
            source = work / 'source'
            installed = work / 'programs/whispr Hybrid VPN'
            state = work / 'data/whispr-hybrid'
            shutil.copytree(ROOT, source, ignore=shutil.ignore_patterns('__pycache__', 'target'))
            shutil.copytree(source, installed)
            state.mkdir(parents=True)
            secret = state / 'device-key.json'
            secret.write_text('PRIVATE FIXTURE SENTINEL')
            # A harmless status-only executable stands in for the Windows guard.
            guard = '#!/bin/sh\nprintf "%s\\n" "${GUARD_STATUS:-DISARMED}"\n'
            for directory in (source, installed):
                file = directory / 'bin/whispr-vpn-guard.exe'
                file.write_text(guard)
                file.chmod(0o700)
                manifest = json.loads((directory / 'SHA256SUMS.json').read_text())
                manifest['bin/whispr-vpn-guard.exe'] = hashlib.sha256(file.read_bytes()).hexdigest()
                (directory / 'SHA256SUMS.json').write_text(json.dumps(manifest))
            # Synthesize exactly the previous Common.ps1 from this patch's small change.
            common = installed / 'client/Common.ps1'
            common.write_text(common.read_text().replace(";detour='wg-transport'", '').replace(
                ",@{type='direct';tag='wg-transport';inet4_bind_address='0.0.0.0'}", ''))
            self.assertEqual(hashlib.sha256(common.read_bytes()).hexdigest(),
                             'a1e84f9fa04067eff0d3eca34c846c6979147e9889b4d23064aca9302ac09b67')
            binary = installed / 'bin/sing-box.exe'
            binary.write_bytes(b'DOWNLOADED ENGINE FIXTURE')
            manifest = json.loads((installed / 'SHA256SUMS.json').read_text())
            for relative in ('client/Common.ps1', 'bin/sing-box.exe'):
                manifest[relative] = hashlib.sha256((installed / relative).read_bytes()).hexdigest()
            (installed / 'SHA256SUMS.json').write_text(json.dumps(manifest))
            updater = source / 'Update-Client.ps1'
            updater.write_text(updater.read_text().replace('#requires -RunAsAdministrator', ''))
            environment = dict(os.environ, ProgramFiles=str(work / 'programs'), ProgramData=str(work / 'data'))
            command = "function Get-NetAdapter { }; & '" + str(updater) + "'"

            def run(status):
                return subprocess.run([PWSH, '-NoLogo', '-NoProfile', '-Command', command],
                                      env=dict(environment, GUARD_STATUS=status), capture_output=True,
                                      text=True, timeout=20)

            before = (installed / 'SHA256SUMS.json').read_bytes()
            result = run('ARMED')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Protection is still armed', result.stderr)
            self.assertEqual((installed / 'SHA256SUMS.json').read_bytes(), before)
            for _ in range(2):
                result = run('DISARMED')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(common.read_bytes(), (source / 'client/Common.ps1').read_bytes())
                self.assertEqual(binary.read_bytes(), b'DOWNLOADED ENGINE FIXTURE')
                self.assertEqual(secret.read_text(), 'PRIVATE FIXTURE SENTINEL')
                current = json.loads((installed / 'SHA256SUMS.json').read_text())
                for relative, digest in current.items():
                    self.assertEqual(hashlib.sha256((installed / relative).read_bytes()).hexdigest(), digest)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--pwsh', default=PWSH)
    args, remaining = parser.parse_known_args()
    PWSH = args.pwsh
    unittest.main(argv=[__file__] + remaining)

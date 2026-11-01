"""Real PowerShell file transaction fixture; Windows ACL/COM/UI are explicitly stubbed.
Requires sibling working fix5 source, or --base /path/to/fix5.
"""
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
BASE = ROOT.parent / 'hybrid-vpn-0.4.0-fix5'
PWSH = '/tmp/hybrid-build/pwsh/pwsh'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class InstallTests(unittest.TestCase):
    def test_add_install_remove_preserves_live_core_and_state(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            package = work / 'package'
            installed = work / 'programs/whispr Hybrid VPN'
            state = work / 'data/whispr-hybrid'
            programs = work / 'shortcuts'
            shutil.copytree(ROOT, package, ignore=shutil.ignore_patterns('__pycache__'))
            shutil.copytree(BASE, installed, ignore=shutil.ignore_patterns('__pycache__', 'target'))
            state.mkdir(parents=True)
            programs.mkdir()
            for root in (installed, state):
                (root / 'install-owner.txt').write_text('whispr-hybrid-schema-1')
            for filename in ('device-key.json', 'peer.json', 'session.json'):
                (state / filename).write_text('UNTOUCHED LIVE STATE ' + filename)
            original_manifest = json.loads((installed / 'SHA256SUMS.json').read_text())
            core_before = {relative: digest(installed / relative) for relative in original_manifest}
            state_before = {file.name: file.read_bytes() for file in state.iterdir()}
            binary = installed / 'bin/sing-box.exe'
            binary.write_bytes(b'UNCHANGED DOWNLOADED ENGINE')
            original_manifest['bin/sing-box.exe'] = digest(binary)
            (installed / 'SHA256SUMS.json').write_text(json.dumps(original_manifest))
            manifest_bytes = (installed / 'SHA256SUMS.json').read_bytes()

            # Substitute only platform boundary calls in the copied fixture, never shipped source.
            for name in ('Install-Tray.ps1', 'Remove-Tray.ps1'):
                file = package / name
                text = file.read_text().replace('#requires -RunAsAdministrator', '')
                text = text.replace("if(-not $IsWindows){throw 'Install this add-on in Windows PowerShell 7.'}", '')
                text = text.replace("([Environment]::GetFolderPath('CommonPrograms'))", '$env:TRAY_TEST_PROGRAMS')
                text = text.replace('[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)', '$null=$shell')
                file.write_text(text)
            sums = json.loads((package / 'TRAY-SHA256SUMS.json').read_text())
            for relative in sums:
                sums[relative] = digest(package / relative)
            (package / 'TRAY-SHA256SUMS.json').write_text(json.dumps(sums))
            boundary = work / 'boundary.ps1'
            boundary.write_text(r'''
function Get-Acl {
    param($LiteralPath)
    $acl=[pscustomobject]@{}
    $acl|Add-Member ScriptMethod GetOwner {param($ignored);[pscustomobject]@{Value='S-1-5-32-544'}}
    return $acl
}
function New-Object {
    param($ComObject)
    if($ComObject -ne 'WScript.Shell'){throw 'Unexpected COM request'}
    $shell=[pscustomobject]@{}
    $shell|Add-Member ScriptMethod CreateShortcut {
        param($Path)
        $link=[pscustomobject]@{Path=$Path;TargetPath='';Arguments='';WorkingDirectory='';Description='';IconLocation=''}
        if(Test-Path -LiteralPath $Path){$saved=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json;$link.Arguments=$saved.Arguments}
        $link|Add-Member ScriptMethod Save {if($env:TRAY_TEST_FAIL_SHORTCUT -eq '1'){throw 'Fixture shortcut failure'};$this|ConvertTo-Json|Set-Content -LiteralPath $this.Path}
        return $link
    }
    return $shell
}
''')
            environment = dict(os.environ, ProgramFiles=str(work / 'programs'),
                               ProgramData=str(work / 'data'), SystemRoot=str(work / 'windows'), TRAY_TEST_PROGRAMS=str(programs))

            def run(script, extra='', success=True):
                command = ". '" + str(boundary) + "'; & '" + str(script) + "' " + extra
                result = subprocess.run([PWSH, '-NoLogo', '-NoProfile', '-Command', command],
                                        env=environment, capture_output=True, text=True, timeout=30)
                if success:
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('Fixture shortcut failure', result.stderr)

            environment['TRAY_TEST_FAIL_SHORTCUT'] = '1'
            run(package / 'Install-Tray.ps1', '-NoLaunch', success=False)
            self.assertFalse((installed / 'Tray.ps1').exists())
            self.assertFalse((installed / 'tray/ADDON-SHA256SUMS.json').exists())
            self.assertEqual((installed / 'SHA256SUMS.json').read_bytes(), manifest_bytes)
            environment.pop('TRAY_TEST_FAIL_SHORTCUT')
            run(package / 'Install-Tray.ps1', '-NoLaunch')
            for relative, before in core_before.items():
                self.assertEqual(digest(installed / relative), before, relative)
            for filename, before in state_before.items():
                self.assertEqual((state / filename).read_bytes(), before, filename)
            self.assertEqual(binary.read_bytes(), b'UNCHANGED DOWNLOADED ENGINE')
            manifest = json.loads((installed / 'SHA256SUMS.json').read_text())
            self.assertEqual(manifest, original_manifest)
            addon = json.loads((installed / 'tray/ADDON-SHA256SUMS.json').read_text())
            self.assertIn('Tray.ps1', addon)
            for relative, sha in addon.items():
                self.assertEqual(digest(installed / relative), sha, relative)
            for relative, sha in manifest.items():
                self.assertEqual(digest(installed / relative), sha, relative)
            # Repeat installation, then remove only add-on entries/files.
            run(package / 'Install-Tray.ps1', '-NoLaunch')
            run(installed / 'Remove-Tray.ps1')
            # Exercise the actual previous six-file add-on -> new eleven-file upgrade.
            previous = ROOT.parent / 'hybrid-vpn-tray-0.1.0'
            if previous.exists():
                old_files = ('Open-Tray.ps1', 'Tray.ps1', 'Prepare-Exit.ps1', 'Remove-Tray.ps1', 'tray/Model.ps1', 'tray/README.md')
                old_manifest = {}
                for relative in old_files:
                    target = installed / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(previous / relative, target)
                    old_manifest[relative] = digest(target)
                (installed / 'tray/ADDON-SHA256SUMS.json').write_text(json.dumps(old_manifest))
                run(package / 'Install-Tray.ps1', '-NoLaunch')
                upgraded = json.loads((installed / 'tray/ADDON-SHA256SUMS.json').read_text())
                self.assertEqual(len(upgraded), 11)
                self.assertIn('background/Host.ps1', upgraded)
                self.assertEqual((installed / 'SHA256SUMS.json').read_bytes(), manifest_bytes)
                for filename, before in state_before.items():
                    self.assertEqual((state / filename).read_bytes(), before, filename)
                run(installed / 'Remove-Tray.ps1')
            after = json.loads((installed / 'SHA256SUMS.json').read_text())
            self.assertEqual(after, original_manifest)
            self.assertEqual((installed / 'SHA256SUMS.json').read_bytes(), manifest_bytes)
            self.assertFalse((installed / 'Tray.ps1').exists())
            self.assertFalse((installed / 'tray/ADDON-SHA256SUMS.json').exists())
            self.assertFalse((programs / 'whispr Hybrid VPN Tray.lnk').exists())
            for relative, before in core_before.items():
                self.assertEqual(digest(installed / relative), before, relative)
            for filename, before in state_before.items():
                self.assertEqual((state / filename).read_bytes(), before, filename)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', type=Path, default=BASE)
    parser.add_argument('--pwsh', default=PWSH)
    args, remaining = parser.parse_known_args()
    BASE, PWSH = args.base, args.pwsh
    unittest.main(argv=[__file__] + remaining)

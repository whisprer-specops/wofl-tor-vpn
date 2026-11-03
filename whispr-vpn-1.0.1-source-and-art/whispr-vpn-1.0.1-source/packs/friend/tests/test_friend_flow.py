"""Real PowerShell file-flow tests. Only Windows/ACL/COM/download boundaries are mocked.
Run with Python 3.10+ and PowerShell 7 on PATH, or --pwsh /path/to/pwsh.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
PWSH=str(ROOT.parent/'tools/pwsh/pwsh')
PUBLIC=base64.b64encode(hashlib.sha256(b'friend-public').digest()).decode()
PRIVATE=base64.b64encode(hashlib.sha256(b'friend-private').digest()).decode()
SERVER=base64.b64encode(hashlib.sha256(b'server-public').digest()).decode()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest().upper()
def refresh(package):
 app=package/'app'
 import re
 files=re.findall("'([^']+)'",re.search(r'\$files=@\((.*?)\)',(app/'tray/Model.ps1').read_text(),re.S).group(1))
 (app/'tray/ADDON-SHA256SUMS.json').write_text(json.dumps({n:sha(app/n) for n in files}))
 (app/'SHA256SUMS.json').write_text(json.dumps({str(p.relative_to(app)):sha(p) for p in app.rglob('*') if p.is_file() and p.name not in ('SHA256SUMS.json','ADDON-SHA256SUMS.json') and '__pycache__' not in p.parts}))
 (package/'PACKAGE-SHA256SUMS.json').write_text(json.dumps({str(p.relative_to(package)):sha(p) for p in package.rglob('*') if p.is_file() and p.name!='PACKAGE-SHA256SUMS.json' and '__pycache__' not in p.parts}))

class FriendFlow(unittest.TestCase):
 def fixture(self,t):
  pkg=t/'package';shutil.copytree(ROOT,pkg,ignore=shutil.ignore_patterns('__pycache__'))
  p=pkg/'Install-Friend.ps1';s=p.read_text().replace('#requires -RunAsAdministrator','')
  s=s.replace("if(-not $IsWindows){throw 'Use Administrator PowerShell 7 x64 on Windows 11.'}",'')
  s=s.replace('Assert-HybridBaseline','Test-BaselineBoundary').replace('Repair-HybridTreePermissions -Root','Test-PermissionsBoundary -Root').replace('Install-HybridEngine $homeDir','Test-EngineBoundary $homeDir').replace('Install-HybridTor $homeDir','Test-TorBoundary $homeDir')
  s=s.replace("$status=(& $guard status|Out-String).Trim()","$status=Test-GuardStatus")
  s=s.replace("([Environment]::GetFolderPath('CommonPrograms'))",'$env:TEST_SHORTCUTS').replace('[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)','$null=$shell');p.write_text(s)
  # Only script entry-point boundaries are rewritten; core validators/protocol stay real.
  for name in ('New-Request.ps1','Import-Access.ps1'):
   p=pkg/'app'/name;s=p.read_text().replace('#requires -RunAsAdministrator','')
   if name=='Import-Access.ps1':s=s.replace('Assert-TrayDisconnected $homeDir','Test-DisconnectedBoundary $homeDir').replace('Write-FriendJson $selected','Write-InjectedFriendJson $selected')
   p.write_text(s)
  refresh(pkg)
  shortcuts=t/'shortcuts';shortcuts.mkdir()
  env=dict(os.environ,ProgramFiles=str(t/'programs'),ProgramData=str(t/'data'),SystemRoot=str(t/'windows'),TEST_SHORTCUTS=str(shortcuts),TEST_PUBLIC=PUBLIC,TEST_PRIVATE=PRIVATE)
  boundary=t/'boundary.ps1'
  boundary.write_text(r'''
function Get-Acl {param($LiteralPath);$a=[pscustomobject]@{};$a|Add-Member ScriptMethod GetOwner {param($ignored);[pscustomobject]@{Value='S-1-5-32-544'}};return $a}
function icacls.exe {$global:LASTEXITCODE=0}
function Test-BaselineBoundary {}
function Test-PermissionsBoundary {param($Root,$AllowUsersRead);if(-not (Test-Path $Root)){throw 'Expected application directory'}}
function Test-GuardStatus {$global:LASTEXITCODE=0;return 'DISARMED'}
function Test-DisconnectedBoundary {param($HomeDir);if($env:TEST_CONNECTED -eq '1'){throw 'Fixture active session'}}
function Add-TestHash($HomeDir,$Name){$p=Join-Path $HomeDir 'SHA256SUMS.json';$m=Get-Content $p -Raw|ConvertFrom-Json -AsHashtable;$m[$Name]=(Get-FileHash (Join-Path $HomeDir $Name)).Hash;Write-HybridJson $m $p}
function Test-EngineBoundary {param($HomeDir,$StateDir)
 if($env:TEST_ENGINE_FAIL -eq '1'){throw 'Injected download failure'}
 $p=Join-Path $HomeDir 'bin/sing-box.exe'
 $text=@('#!/bin/sh',"printf 'PrivateKey: %s\nPublicKey: %s\n' '$env:TEST_PRIVATE' '$env:TEST_PUBLIC'") -join "`n"
 [IO.File]::WriteAllText($p,$text+"`n");& chmod +x $p;Add-TestHash $HomeDir 'bin/sing-box.exe'
}
function Test-TorBoundary {param($HomeDir,$StateDir);$p=Join-Path $HomeDir 'bin/tor';[void](New-Item -ItemType Directory -Path $p -Force);[IO.File]::WriteAllText((Join-Path $p 'tor.exe'),'fixture');Add-TestHash $HomeDir 'bin/tor/tor.exe'}
function New-Object {param($ComObject)
 if($ComObject -ne 'WScript.Shell'){throw 'Unexpected COM request'}
 $s=[pscustomobject]@{}
 $s|Add-Member ScriptMethod CreateShortcut {param($Path);$x=[pscustomobject]@{Path=$Path;TargetPath='';Arguments='';WorkingDirectory='';Description='';IconLocation=''};$x|Add-Member ScriptMethod Save {$this|ConvertTo-Json|Set-Content -LiteralPath $this.Path};return $x}
 return $s
}
function Write-InjectedFriendJson {param($Value,$Path);if($env:TEST_IMPORT_FAIL -eq '1'){throw 'Injected peer write failure'};Write-FriendJson $Value $Path}
''')
  return pkg,env,boundary
 def run_ps(self,script,arguments,env,boundary,success=True,contains=None):
  text=f". '{boundary}'; & '{script}' {arguments}"
  r=subprocess.run([PWSH,'-NoLogo','-NoProfile','-Command',text],env=env,capture_output=True,text=True,timeout=40)
  if success:self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  else:self.assertNotEqual(r.returncode,0,r.stdout+r.stderr)
  if contains:self.assertIn(contains,r.stdout+r.stderr)
  self.assertNotIn(PRIVATE,r.stdout+r.stderr,'Private key must not be logged')
  return r
 def test_install_request_import_repeat_and_rejections(self):
  with tempfile.TemporaryDirectory() as td:
   t=Path(td);pkg,env,boundary=self.fixture(t)
   request_dir=t/'exchange'
   self.run_ps(pkg/'Install-Friend.ps1',f"-DeviceName Friend-PC -OutputDirectory '{request_dir}'",env,boundary)
   app=t/'programs/whispr Hybrid VPN';state=t/'data/whispr-hybrid'
   req=json.loads((request_dir/'friend-request.json').read_text())
   self.assertEqual(set(req),{'Schema','Kind','RequestId','PublicKey','Fingerprint','DeviceName','CreatedUtc'})
   self.assertEqual(req['PublicKey'],PUBLIC);self.assertNotIn(PRIVATE,(request_dir/'friend-request.json').read_text())
   self.assertFalse((state/'peer.json').exists());self.assertFalse((state/'session.json').exists())
   original_key=(state/'device-key.json').read_bytes()
   self.run_ps(pkg/'Install-Friend.ps1',f"-DeviceName Other-Label -OutputDirectory '{request_dir}'",env,boundary)
   self.assertEqual((state/'device-key.json').read_bytes(),original_key)
   self.assertEqual(json.loads((request_dir/'friend-request.json').read_text())['RequestId'],req['RequestId'])
   def profile(alias,ip):return dict(schema=1,ssh_alias=alias,endpoint=ip,port=51832,server_public_key=SERVER,client_public_key=PUBLIC,client_ipv4='10.88.70.3/32',client_ipv6=None,ipv6=False,interface='wg-whispr')
   access={**req,'Kind':'whispr-friend-access','Exits':[profile('nyc1','137.184.105.114'),profile('fkt1','203.0.113.8')]}
   path=t/'friend-access.json';path.write_text(json.dumps(access))
   env['TEST_IMPORT_FAIL']='1'
   self.run_ps(app/'Import-Access.ps1',f"-AccessFile '{path}' -NoLaunch",env,boundary,False,'Injected peer write failure')
   self.assertFalse((state/'peer.json').exists());self.assertFalse((state/'profiles/nyc1.json').exists())
   env.pop('TEST_IMPORT_FAIL')
   self.run_ps(app/'Import-Access.ps1',f"-AccessFile '{path}' -NoLaunch",env,boundary)
   self.assertEqual(json.loads((state/'peer.json').read_text())['ssh_alias'],'nyc1')
   self.assertEqual(json.loads((state/'profiles/fkt1.json').read_text())['client_public_key'],PUBLIC)
   self.assertEqual((state/'device-key.json').read_bytes(),original_key)
   baseline={str(p.relative_to(state)):p.read_bytes() for p in state.rglob('*') if p.is_file()}
   bad={**access,'RequestId':'b'*32};path.write_text(json.dumps(bad))
   self.run_ps(app/'Import-Access.ps1',f"-AccessFile '{path}' -NoLaunch",env,boundary,False,'different device/request')
   for n,b in baseline.items():self.assertEqual((state/n).read_bytes(),b,n)
   path.write_text(json.dumps(access));env['TEST_CONNECTED']='1'
   self.run_ps(app/'Import-Access.ps1',f"-AccessFile '{path}' -NoLaunch",env,boundary,False,'Fixture active session')
   for n,b in baseline.items():self.assertEqual((state/n).read_bytes(),b,n)
   env.pop('TEST_CONNECTED');access['Exits']=[profile('fkt1','203.0.113.8')];path.write_text(json.dumps(access))
   self.run_ps(app/'Import-Access.ps1',f"-AccessFile '{path}' -NoLaunch",env,boundary)
   self.assertFalse((state/'profiles/nyc1.json').exists());self.assertEqual(json.loads((state/'peer.json').read_text())['ssh_alias'],'fkt1')
   self.assertEqual((state/'device-key.json').read_bytes(),original_key)
 def test_interrupted_initial_download_is_retryable(self):
  with tempfile.TemporaryDirectory() as td:
   t=Path(td);pkg,env,boundary=self.fixture(t)
   env['TEST_ENGINE_FAIL']='1'
   self.run_ps(pkg/'Install-Friend.ps1','',env,boundary,False,'Injected download failure')
   state=t/'data/whispr-hybrid';app=t/'programs/whispr Hybrid VPN'
   self.assertEqual(json.loads((state/'friend-install.json').read_text())['phase'],'installing')
   self.assertFalse((state/'device-key.json').exists());self.assertFalse((state/'peer.json').exists())
   env.pop('TEST_ENGINE_FAIL')
   self.run_ps(pkg/'Install-Friend.ps1',f"-OutputDirectory '{t/'exchange'}'",env,boundary)
   self.assertEqual(json.loads((state/'friend-install.json').read_text())['phase'],'ready')
   self.assertTrue((t/'exchange/friend-request.json').exists())
 def test_existing_owner_install_is_refused_without_writes(self):
  with tempfile.TemporaryDirectory() as td:
   t=Path(td);pkg,env,boundary=self.fixture(t)
   app=t/'programs/whispr Hybrid VPN';app.mkdir(parents=True);(app/'install-owner.txt').write_text('whispr-hybrid-schema-1')
   (app/'friend-mode.json').write_text(json.dumps({'product':'owner'}));(app/'owner-private-sentinel').write_text('retain')
   before={p.name:p.read_bytes() for p in app.iterdir()}
   self.run_ps(pkg/'Install-Friend.ps1','',env,boundary,False,'owner/another VPN installation')
   self.assertFalse((t/'data').exists())
   self.assertEqual({p.name:p.read_bytes() for p in app.iterdir()},before)

if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--pwsh',default=PWSH);args,rest=parser.parse_known_args();PWSH=args.pwsh
 unittest.main(argv=[__file__]+rest,verbosity=2)

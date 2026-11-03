"""PowerShell owner orchestration tests; OpenSSH is mocked, no VPS is contacted."""
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
SERVER=base64.b64encode(hashlib.sha256(b'server-public').digest()).decode()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest().upper()
class OwnerFlow(unittest.TestCase):
 def test_full_and_partial_registration_and_revoke(self):
  with tempfile.TemporaryDirectory() as td:
   t=Path(td);pkg=t/'owner package';shutil.copytree(ROOT,pkg,ignore=shutil.ignore_patterns('__pycache__'))
   p=pkg/'Owner-Operations.ps1';s=p.read_text().replace("if(-not $IsWindows){throw 'Run owner operations in Windows PowerShell 7 with your existing OpenSSH aliases.'}",'');p.write_text(s)
   (pkg/'PACKAGE-SHA256SUMS.json').write_text(json.dumps({str(p.relative_to(pkg)):sha(p) for p in pkg.rglob('*') if p.is_file() and p.name!='PACKAGE-SHA256SUMS.json' and '__pycache__' not in p.parts}))
   request=dict(Schema=1,Kind='whispr-friend-request',RequestId='a'*32,PublicKey=PUBLIC,Fingerprint=hashlib.sha256(base64.b64decode(PUBLIC)).hexdigest(),DeviceName='Friend test-PC',CreatedUtc='2026-11-01T00:00:00Z')
   req=t/'friend-request.json';req.write_text(json.dumps(request))
   boundary=t/'boundary.ps1';boundary.write_text(r'''
function Get-Command {param($Name);if($Name -in @('ssh.exe','scp.exe')){return [pscustomobject]@{Source=$Name}};Microsoft.PowerShell.Core\Get-Command $Name}
function ssh.exe {
 $native=@($args);$global:LASTEXITCODE=0
 if($native[0] -eq '-G'){
  $alias=$native[1];$ip=@{nyc1='137.184.105.114';lon1='138.68.142.181';fkt1='203.0.113.8';sgp1='68.183.227.135';syd1='134.199.170.197'}[$alias]
  "hostname $ip";if($alias -eq 'fkt1'){'user root'}else{'user wofl'};return
 }
 $remote=$native[-1]
 if($remote -eq 'mktemp -d /tmp/whispr-enrol-XXXXXXXX'){'/tmp/whispr-enrol-ABCDE123';return}
 if($remote -like 'rm -f*'){return}
 $script:lastServer=$native[-2]
 if($script:lastServer -eq $env:FAIL_SERVER){$global:LASTEXITCODE=1;return}
 if($remote -match 'iptables|systemctl|setup[.]py'){throw 'A peer operation must not call firewall/service/server setup'}
 if($remote -notmatch "sha256sum -c - && (sudo python3|env SUDO_USER=root python3) -I"){throw 'Verified isolated peer invocation missing'}
 if($remote -notmatch "--label 'Friend test-PC'"){throw 'Device label quoting differs'}
 $script:lastAction=[regex]::Match($remote,"--action '([^']+)'").Groups[1].Value
 if($script:lastAction -notin @('register','revoke','check','recover')){throw 'Unexpected peer action'}
}
function scp.exe {
 $native=@($args);$global:LASTEXITCODE=0
 if($native[-2] -like '*:/tmp/*/report.json'){
  $report=@{schema=1;action=$script:lastAction;status=$(if($script:lastAction -eq 'revoke'){'revoked'}else{'verified'});request_id='a'*32;client_public_key=$env:TEST_PUBLIC;server_public_key=$env:TEST_SERVER;port=51832;client_ipv4='10.88.70.3/32';client_ipv6=$null;ipv6=$false;interface='wg-whispr'}
  $report|ConvertTo-Json|Set-Content -LiteralPath $native[-1]
 }
}
''')
   env=dict(os.environ,TEST_PUBLIC=PUBLIC,TEST_SERVER=SERVER)
   def run(name,out,success=True,contains=None):
    cmd=f". '{boundary}'; & '{pkg/name}' -Request '{req}' -OutputDirectory '{out}'"
    r=subprocess.run([PWSH,'-NoLogo','-NoProfile','-Command',cmd],env=env,capture_output=True,text=True,timeout=25)
    self.assertEqual(r.returncode==0,success,r.stdout+r.stderr)
    if contains:self.assertIn(contains,r.stdout+r.stderr)
    return r
   full=t/'full';r=run('Register-Friend.ps1',full,contains='sudo password')
   access=json.loads(next(full.rglob('friend-access.json')).read_text())
   self.assertEqual({e['ssh_alias'] for e in access['Exits']},{'nyc1','lon1','fkt1','sgp1','syd1'})
   self.assertEqual(access['PublicKey'],PUBLIC);self.assertNotIn('PrivateKey',json.dumps(access))
   self.assertIn('logs in as root',r.stdout)
   env['FAIL_SERVER']='lon1';partial=t/'partial';run('Register-Friend.ps1',partial,False,'Unresolved exits: lon1')
   reduced=json.loads(next(partial.rglob('friend-access.json')).read_text());self.assertEqual(len(reduced['Exits']),4);self.assertNotIn('lon1',{e['ssh_alias'] for e in reduced['Exits']})
   env.pop('FAIL_SERVER');revoked=t/'revoked';run('Revoke-Friend.ps1',revoked)
   self.assertFalse(list(revoked.rglob('friend-access.json')))
   results=json.loads(next(revoked.rglob('owner-receipt.json')).read_text())['Results'];self.assertTrue(all(r['Status']=='revoked' for r in results))
if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--pwsh',default=PWSH);args,rest=parser.parse_known_args();PWSH=args.pwsh
 unittest.main(argv=[__file__]+rest,verbosity=2)

"""Real PowerShell client-update/import tests; Windows ACL and guard status boundaries are mocked."""
import argparse,base64,hashlib,json,os,re,shutil,subprocess,tempfile,unittest,zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
PWSH=shutil.which('pwsh') or str(ROOT.parent/'tools/pwsh/pwsh')
_BASELINES=tempfile.TemporaryDirectory(prefix='whispr-group-baselines-')
with zipfile.ZipFile(ROOT/'tests/fixtures/client-baselines.zip') as archive:archive.extractall(_BASELINES.name)
BASE=Path(_BASELINES.name)/'base'
FRIEND=Path(_BASELINES.name)/'friend'
OWNER=Path(_BASELINES.name)/'owner-map'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest().upper()
def key(s):return base64.b64encode(hashlib.sha256(s.encode()).digest()).decode()
def kid(k):return hashlib.sha256(base64.b64decode(k)).hexdigest()
def manifests(app):
 files=re.findall("'([^']+)'",re.search(r'\$files=@\((.*?)\)',(app/'tray/Model.ps1').read_text(),re.S).group(1))
 (app/'tray/ADDON-SHA256SUMS.json').write_text(json.dumps({n:sha(app/n) for n in files}))
 core=json.loads((app/'SHA256SUMS.json').read_text())
 for n in core:core[n]=sha(app/n)
 (app/'SHA256SUMS.json').write_text(json.dumps(core))
def request(public):return dict(Schema=1,Kind='whispr-friend-request',RequestId='a'*32,PublicKey=public,Fingerprint=kid(public),DeviceName='Friend',CreatedUtc='2026-11-01T00:00:00Z')
class Flow(unittest.TestCase):
 def test_flag_patch_keeps_active_vpn_files_and_restores(self):
  for owner in [False,True]:
   with self.subTest(owner=owner),tempfile.TemporaryDirectory() as td:
    t=Path(td);pkg,app,state,boundary,env,public=self.fixture(t,owner)
    patcher=pkg/'Add-ExitFlags.ps1';patcher.write_text(patcher.read_text().replace('#requires -RunAsAdministrator',''))
    before={str(p.relative_to(app)):p.read_bytes() for p in app.rglob('*') if p.is_file()}
    private_before={p.name:p.read_bytes() for p in state.iterdir() if p.is_file()}
    env['GROUP_CONNECTED']='1' # Any accidental disconnect assertion must fail this test.
    self.runps(patcher,'-NoLaunch',env,boundary)
    self.runps(patcher,'-NoLaunch',env,boundary,contains='already installed')
    mutable={'Tray.ps1','SHA256SUMS.json','tray/ADDON-SHA256SUMS.json'}
    for n,b in before.items():
     if n not in mutable:self.assertEqual((app/n).read_bytes(),b,n)
    for n,b in private_before.items():self.assertEqual((state/n).read_bytes(),b,n)
    source=(app/'Tray.ps1').read_text()
    self.assertEqual(source.count('# BEGIN whispr exit flags v1'),1)
    self.assertIn('$entry.Image=Get-HybridExitFlagImage $alias',source)
    self.assertIn('$script:exitMenu.DropDown.ShowCheckMargin=$true',source)
    self.assertEqual(len(list((state/'flag-backups').glob('flags-*'))),1)
    self.runps(patcher,'-Restore -NoLaunch',env,boundary)
    for n,b in before.items():self.assertEqual((app/n).read_bytes(),b,n)

 def fixture(self,t,owner=False):
  pkg=t/'package';shutil.copytree(ROOT,pkg,ignore=shutil.ignore_patterns('__pycache__','results','group.json'))
  app=t/'programs/whispr Hybrid VPN';shutil.copytree(FRIEND,app)
  if owner:shutil.copytree(BASE/'server',app/'server')
  if owner:
   # Exercise the actual owner tray, including its different preparation handler and narrower core manifest.
   for n in ['Tray.ps1','Prepare-Exit.ps1','Remove-Tray.ps1','tray/Model.ps1']:
    shutil.copyfile(OWNER/n,app/n)
   (app/'friend-mode.json').unlink()
   core=json.loads((BASE/'SHA256SUMS.json').read_text())
   core['client/Session.ps1']=sha(app/'client/Session.ps1');core['background/Resume.ps1']=sha(app/'background/Resume.ps1')
   (app/'SHA256SUMS.json').write_text(json.dumps(core))
  manifests(app)
  state=t/'data/whispr-hybrid';state.mkdir(parents=True)
  for p in [app,state]:(p/'install-owner.txt').write_text('whispr-hybrid-schema-1')
  public=key('local');(state/'device-key.json').write_text(json.dumps(dict(PublicKey=public,PrivateKey='PRIVATE SENTINEL')))
  (state/'profiles').mkdir()
  old=dict(schema=1,ssh_alias='nyc1',endpoint='137.184.105.114',port=51832,server_public_key=key('nyc'),client_public_key=public,client_ipv4='10.88.70.2/32',client_ipv6=None,ipv6=False,interface='wg-whispr')
  for p in [state/'peer.json',state/'profiles/nyc1.json']:p.write_text(json.dumps(old))
  for n in ['session.json','resume-binding.json','startup-setting-sentinel']:(state/n).write_text('RETAIN '+n)
  # Rewrite platform boundaries only in test copies; application validators and file operations remain real.
  for name in ['Install-Group.ps1','Import-Group.ps1','New-Group.ps1','Add-Member.ps1','Remove-Member.ps1','Publish-MyVPS.ps1','Restore-PreviousClient.ps1']:
   p=pkg/name;s=p.read_text().replace('#requires -RunAsAdministrator','')
   if name in ['Install-Group.ps1','Restore-PreviousClient.ps1']:s=s.replace('Assert-TrayDisconnected $identity.Home','Test-GuardBoundary $identity.Home')
   p.write_text(s)
  p=pkg/'payload/group/Client.ps1';s=p.read_text().replace('Assert-TrayDisconnected $InstallRoot','Test-GuardBoundary $InstallRoot').replace('Write-GroupJson $profiles[$alias]','Write-InjectedGroupJson $profiles[$alias]');p.write_text(s)
  local=pkg/'group/Local.ps1';local.write_text(local.read_text().replace('Assert-TrayDisconnected $Identity.Home','Test-GuardBoundary $Identity.Home'))
  sums={str(p.relative_to(pkg)):sha(p) for p in pkg.rglob('*') if p.is_file() and p.name not in ['PACKAGE-SHA256SUMS.json','my-vps.json','group.json'] and '__pycache__' not in p.parts}
  (pkg/'PACKAGE-SHA256SUMS.json').write_text(json.dumps(sums))
  boundary=t/'boundary.ps1';boundary.write_text(r'''
function Get-Acl {param($LiteralPath);$a=[pscustomobject]@{};$a|Add-Member ScriptMethod GetOwner {param($ignored);[pscustomobject]@{Value='S-1-5-32-544'}};return $a}
function Test-GuardBoundary {param($Root);if($env:GROUP_CONNECTED -eq '1'){throw 'Fixture connected'}}
function Copy-Item {param($LiteralPath,$Destination,[switch]$Force)
 if($env:GROUP_FAIL -eq 'copy' -and $LiteralPath -like '*payload/tray/Map.ps1'){throw 'Injected copy failure'}
 Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
}
function Write-InjectedGroupJson {param($Value,$Path);if($env:GROUP_FAIL -eq 'import'){throw 'Injected import failure'};Write-GroupJson $Value $Path}

function Get-Command {param($Name);if($Name -in @('ssh.exe','scp.exe')){return [pscustomobject]@{Source=$Name}};Microsoft.PowerShell.Core\Get-Command $Name}
function ssh.exe {
 $native=@($args);$global:LASTEXITCODE=0
 if($native[0] -eq '-G'){'hostname 203.0.113.77';'user root';return}
 $text=$native[-1]
 if($text -eq 'mktemp -d /tmp/whispr-hybrid-XXXXXXXX'){'/tmp/whispr-hybrid-ABCDE123';return}
 if($text -like 'rm -f*'){return}
 if($text -notmatch 'sha256sum -c - && mv' -or $text -notmatch 'env SUDO_USER=root python3 -I'){throw 'Verified isolated bootstrap invocation missing'}
}
function scp.exe {
 $native=@($args);$global:LASTEXITCODE=0
 if($native[-1] -like '*:/tmp/*/'){$script:groupInput=Read-GroupJson $native[-2];return}
 if($native[-2] -like '*:/tmp/*/report.json'){
  $input=$script:groupInput;$assign=@{};$slot=2
  foreach($m in $input.Members){$assign[$m.Id]=@{IPv4="10.88.70.$slot/32";IPv6=$null};$slot++}
  $k=[Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('published-node')))
  Write-GroupJson @{Schema=1;GroupId=$input.GroupId;OwnerId=$input.OwnerId;ServerPublicKey=$k;Port=$input.Node.Port;IPv6=$false;Assignments=$assign;Revision=1;MembersRevision=$input.MembershipRevision;CreatedServer=$true} $native[-1]
 }
}
''')
  env=dict(os.environ,ProgramFiles=str(t/'programs'),ProgramData=str(t/'data'))
  return pkg,app,state,boundary,env,public
 def runps(self,script,args,env,boundary,ok=True,contains=None):
  r=subprocess.run([PWSH,'-NoLogo','-NoProfile','-Command',f". '{boundary}'; & '{script}' {args}"],env=env,capture_output=True,text=True,timeout=30)
  self.assertEqual(r.returncode==0,ok,r.stdout+r.stderr)
  if contains:self.assertIn(contains,r.stdout+r.stderr)
  self.assertNotIn('PRIVATE SENTINEL',r.stdout+r.stderr);return r
 def test_install_import_and_rollback_on_owner_and_friend(self):
  for owner in [False,True]:
   with self.subTest(owner=owner),tempfile.TemporaryDirectory() as td:
    t=Path(td);pkg,app,state,boundary,env,public=self.fixture(t,owner)
    before={str(p.relative_to(app)):p.read_bytes() for p in app.rglob('*') if p.is_file()};private_before={p.name:p.read_bytes() for p in state.iterdir() if p.is_file()}
    env['GROUP_FAIL']='copy';self.runps(pkg/'Install-Group.ps1','-NoLaunch',env,boundary,False,'Injected copy failure')
    for n,b in before.items():self.assertEqual((app/n).read_bytes(),b,n)
    self.assertFalse((app/'group-addon.json').exists());env.pop('GROUP_FAIL')
    self.runps(pkg/'Install-Group.ps1','-NoLaunch',env,boundary);self.runps(pkg/'Install-Group.ps1','-NoLaunch',env,boundary)
    for n in ['client/Common.ps1','client/Session.ps1','bin/whispr-vpn-guard.exe','Recover.ps1','background/Resume.ps1']:
     self.assertEqual((app/n).read_bytes(),before[n],n)
    for n,b in private_before.items():self.assertEqual((state/n).read_bytes(),b,n)
    self.assertIn('Get-HybridExitAliases',(app/'Tray.ps1').read_text());self.assertIn('Group exit has no approved profile',(app/'Tray.ps1').read_text())
    self.assertIn('$entry.Image=Get-HybridExitFlagImage $alias',(app/'Tray.ps1').read_text())
    other=key('buddy');member=dict(Id=kid(other),PublicKey=other,Name='Friend');req=t/'request.json';req.write_text(json.dumps(request(other)))
    self.runps(pkg/'New-Group.ps1',f"-MemberRequests '{req}' "+("-StartIndependentGroup" if not owner else ""),env,boundary)
    doc=json.loads((pkg/'group.json').read_text());self.assertEqual(len(doc['Members']),2)
    if owner:self.assertEqual(len(json.loads((pkg/'my-vps.json').read_text())['Servers']),1)
    mid=kid(public);server=key('extra');nid='exit-'+kid(server)[:24]
    doc['Nodes']=[dict(Id=nid,OwnerId=mid,Name='Extra Frankfurt',Latitude=50.11,Longitude=8.68,Endpoint='203.0.113.8',Port=51832,ServerPublicKey=server,IPv6=False,Assignments={mid:dict(IPv4='10.88.70.2/32',IPv6=None),kid(other):dict(IPv4='10.88.70.3/32',IPv6=None)},Revision=1,MembersRevision=1)]
    incoming=t/'received.json';incoming.write_text(json.dumps(doc))
    env['GROUP_FAIL']='import';self.runps(pkg/'Import-Group.ps1',f"-File '{incoming}' -NoLaunch",env,boundary,False,'Injected import failure')
    self.assertFalse((state/'profiles'/f'{nid}.json').exists());env.pop('GROUP_FAIL')
    self.runps(pkg/'Import-Group.ps1',f"-File '{incoming}' -NoLaunch",env,boundary)
    self.assertEqual(json.loads((state/'peer.json').read_text())['ssh_alias'],'nyc1')
    self.assertEqual(json.loads((state/'profiles'/f'{nid}.json').read_text())['client_public_key'],public)
    for n in ['device-key.json','session.json','resume-binding.json','startup-setting-sentinel']:self.assertEqual((state/n).read_bytes(),private_before[n],n)
    # End-to-end publisher orchestration with mocked SSH/SCP; metadata remains data, never shell text.
    config=dict(Schema=1,Servers=[dict(SSH='my-fra',Name='Friend Frankfurt',Latitude=50.11,Longitude=8.68,Port=51832)])
    (pkg/'my-vps.json').write_text(json.dumps(config))
    self.runps(pkg/'Publish-MyVPS.ps1','-ApproveMembers',env,boundary)
    published=json.loads((pkg/'group.json').read_text());self.assertEqual(len(published['Nodes']),2)
    extra='exit-'+kid(key('published-node'))[:24]
    self.assertTrue((state/'profiles'/f'{extra}.json').exists())
    catalog=(state/'group-catalog.json').read_bytes();doc['Members']=[member];doc['Nodes']=[];incoming.write_text(json.dumps(doc))
    self.runps(pkg/'Import-Group.ps1',f"-File '{incoming}' -NoLaunch",env,boundary,False)
    self.assertEqual((state/'group-catalog.json').read_bytes(),catalog)
    first=sorted((p for p in (state/'group-backups').glob('install-*') if (p/'restore.json').exists()),key=lambda p:p.stat().st_ctime)[0]
    self.runps(pkg/'Restore-PreviousClient.ps1',f"-Backup '{first}' -NoLaunch",env,boundary)
    for n,b in before.items():self.assertEqual((app/n).read_bytes(),b,n)
    self.assertFalse((app/'group-addon.json').exists())
    self.assertEqual((state/'device-key.json').read_bytes(),private_before['device-key.json'])

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--pwsh',default=PWSH);args,rest=p.parse_known_args();PWSH=args.pwsh
 unittest.main(argv=[__file__]+rest,verbosity=2)

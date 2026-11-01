import hashlib,json,os,re,shutil,subprocess,tempfile,unittest,zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];PKG=Path(__file__).resolve().parents[1];PW=ROOT/'tools/pwsh/pwsh'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest().upper()
class MapUpdate(unittest.TestCase):
 def test_live_state_retained_and_copy_failure_rolled_back(self):
  with tempfile.TemporaryDirectory() as td:
   t=Path(td);app=t/'programs/whispr Hybrid VPN';state=t/'data/whispr-hybrid';package=t/'package'
   shutil.copytree(ROOT/'hybrid-vpn-0.4.0-fix5',app)
   old=t/'old'
   with zipfile.ZipFile(ROOT/'map-layout-source/hybrid-vpn-tray-0.2.0.zip') as z:z.extractall(old)
   txt=(old/'tray/Model.ps1').read_text();files=re.search(r'\$files=@\((.*?)\)',txt,re.S).group(1);files=re.findall("'([^']+)'",files)
   addon={}
   for name in files:
    dest=app/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(old/name,dest);addon[name]=sha(dest)
   (app/'tray/ADDON-SHA256SUMS.json').write_text(json.dumps(addon))
   shutil.copyfile(old/'core/Session.ps1',app/'client/Session.ps1')
   core=json.loads((app/'SHA256SUMS.json').read_text());core['client/Session.ps1']=sha(app/'client/Session.ps1');core['background/Resume.ps1']=sha(app/'background/Resume.ps1');(app/'SHA256SUMS.json').write_text(json.dumps(core))
   state.mkdir(parents=True)
   for p in [app,state]:(p/'install-owner.txt').write_text('whispr-hybrid-schema-1')
   for n in ['device-key.json','peer.json','session.json','resume-binding.json','autostart-setting-sentinel']:(state/n).write_text('ACTIVE STATE '+n)
   baseline={str(p.relative_to(app)):p.read_bytes() for p in app.rglob('*') if p.is_file()}
   state_before={p.name:p.read_bytes() for p in state.iterdir() if p.is_file()}
   shutil.copytree(PKG,package)
   f=package/'Install-MapFix.ps1';s=f.read_text().replace('#requires -RunAsAdministrator','').replace("if(-not $IsWindows){throw 'Install this map fix in Windows PowerShell 7.'}",'');f.write_text(s)
   boundary=t/'boundary.ps1';boundary.write_text('''
function Get-Acl {param($LiteralPath);$a=[pscustomobject]@{};$a|Add-Member ScriptMethod GetOwner {param($ignored);[pscustomobject]@{Value='S-1-5-32-544'}};return $a}
function Copy-Item {param($LiteralPath,$Destination,[switch]$Force)
 if($env:MAP_FAIL -eq '1' -and $LiteralPath -like '*package/tray/Map.ps1'){throw 'Injected map-copy failure'}
 Microsoft.PowerShell.Management\\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
}
''')
   env=dict(os.environ,ProgramFiles=str(t/'programs'),ProgramData=str(t/'data'))
   cmd=f". '{boundary}'; & '{f}' -NoLaunch"
   env['MAP_FAIL']='1';result=subprocess.run([str(PW),'-NoLogo','-NoProfile','-Command',cmd],env=env,capture_output=True,text=True)
   self.assertNotEqual(result.returncode,0,result.stdout+result.stderr);self.assertIn('Injected map-copy failure',result.stderr)
   for n,b in baseline.items():self.assertEqual((app/n).read_bytes(),b,n)
   env.pop('MAP_FAIL')
   for repeat in range(2):
    result=subprocess.run([str(PW),'-NoLogo','-NoProfile','-Command',cmd],env=env,capture_output=True,text=True)
    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
   allowed={'Tray.ps1','tray/Map.ps1','tray/MapModel.ps1','tray/ADDON-SHA256SUMS.json'}
   for n,b in baseline.items():
    if n not in allowed:self.assertEqual((app/n).read_bytes(),b,n)
   for n,b in state_before.items():self.assertEqual((state/n).read_bytes(),b,n)
   for n in allowed-{'tray/ADDON-SHA256SUMS.json'}:self.assertEqual((app/n).read_bytes(),(PKG/n).read_bytes(),n)
   updated=json.loads((app/'tray/ADDON-SHA256SUMS.json').read_text())
   for n,h in updated.items():self.assertEqual(sha(app/n),h.upper(),n)
if __name__=='__main__':unittest.main()

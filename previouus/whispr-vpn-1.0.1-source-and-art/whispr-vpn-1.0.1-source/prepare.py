#!/usr/bin/env python3
"""Stage only distributable code, original artwork, and a verified portable runtime."""
import hashlib,json,shutil,zipfile
from pathlib import Path
from PIL import Image
ROOT=Path(__file__).resolve().parent
P=ROOT/'payload'
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest().upper()
def refresh(path):
 old=json.loads(path.read_text())
 legacy=path.parent/'docs/licenses/legacy-project-MIT.txt'
 if legacy.exists():old['docs/licenses/legacy-project-MIT.txt']=''
 path.write_text(json.dumps({k:sha(path.parent/k) for k in old},indent=2)+'\n')
def rtf(text):
 escaped=text.replace('\\','\\\\').replace('{','\\{').replace('}','\\}').replace('\r\n','\n').replace('\r','\n')
 return r'{\rtf1\ansi\deff0{\fonttbl{\f0 Segoe UI;}}\viewkind4\uc1\pard\f0\fs18 '+escaped.replace('\n',r'\par '+'\n')+'}'
def prepare():
 if P.exists():shutil.rmtree(P)
 P.mkdir()
 for name in ['Desktop.ps1','Model.ps1','Worker.ps1','Prepare-Uninstall.ps1']:
  shutil.copy2(ROOT/'src'/name,P/name)
 shutil.copytree(ROOT/'packs',P/'packs')
 shutil.copytree(ROOT/'native/notices',P/'notices/native-preflight')
 license_bytes=(ROOT/'LICENSE.md').read_bytes()
 (P/'LICENSE.md').write_bytes(license_bytes)
 (P/'LICENSE.rtf').write_text(rtf(license_bytes.decode('utf-8')),encoding='ascii')
 for name in ['friend','group','owner']:
  pack=P/'packs'/name
  old=pack/'LICENSE';lic=pack/'docs/licenses/legacy-project-MIT.txt';lic.parent.mkdir(parents=True,exist_ok=True)
  if old.exists():shutil.copy2(old,lic);old.write_bytes(license_bytes)
 # The app keeps its own exact-text licence, with the prior permissive notice retained.
 app=P/'packs/friend/app'
 shutil.copy2(app/'LICENSE',app/'docs/licenses/legacy-project-MIT.txt')
 (app/'LICENSE').write_bytes(license_bytes)
 third=app/'docs/THIRD-PARTY.md'
 txt=third.read_text().replace('Own controller, installer, server helpers and Rust guard: MIT, copyright 2026 whispr.dev.','Project code in this desktop distribution uses the supplied Hybrid License (MIT + CC0), preserved verbatim in LICENSE. The previous project MIT notice is retained in docs/licenses/legacy-project-MIT.txt. Third-party code keeps its own licences.')
 third.write_text(txt)
 # Metadata is set only when this installer actually creates a new core directory.
 f=P/'packs/friend/Install-Friend.ps1';txt=f.read_text()
 txt=txt.replace("param([string]$DeviceName='Friend-PC',[string]$OutputDirectory=$PSScriptRoot)","param([string]$DeviceName='Friend-PC',[string]$OutputDirectory=$PSScriptRoot,[string]$DesktopSuiteRoot='')")
 txt=txt.replace('    foreach($root in @($homeDir,$stateDir)){\n        if(-not', '    $freshCoreCreated=$false\n    foreach($root in @($homeDir,$stateDir)){\n        if(-not')
 txt=txt.replace('            [void](New-Item -ItemType Directory -Path $root)\n', '            [void](New-Item -ItemType Directory -Path $root)\n            if($root -eq $homeDir){$freshCoreCreated=$true}\n')
 marker='''    if($freshCoreCreated -and $DesktopSuiteRoot){
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        try{$sid=$identity.User.Value}finally{$identity.Dispose()}
        Write-FriendJson @{Product='whispr-vpn-desktop-1';SuiteRoot=[IO.Path]::GetFullPath($DesktopSuiteRoot);OwnerSid=$sid;CreatedUtc=[DateTime]::UtcNow.ToString('o')} (Join-Path $homeDir 'desktop-owned.json')
    }
'''
 txt=txt.replace("    Write-FriendJson @{schema=1;product='whispr-hybrid-friend';version='1.0.0';phase='installing'}", marker+"    Write-FriendJson @{schema=1;product='whispr-hybrid-friend';version='1.0.0';phase='installing'}")
 assert '$freshCoreCreated=$false' in txt and 'DesktopSuiteRoot=' in txt
 f.write_text(txt)
 refresh(app/'SHA256SUMS.json')
 for name in ['friend','group','owner']:refresh(P/'packs'/name/'PACKAGE-SHA256SUMS.json')
 assets=P/'assets';assets.mkdir()
 for name in ['logo.png','splash.png']:shutil.copy2(ROOT/'art'/name,assets/name)
 logo=Image.open(assets/'logo.png').convert('RGBA');bbox=logo.getbbox();logo=logo.crop(bbox)
 icon=Image.new('RGBA',(512,512));logo.thumbnail((440,440),Image.Resampling.LANCZOS);icon.alpha_composite(logo,((512-logo.width)//2,(512-logo.height)//2))
 icon.save(assets/'whispr-vpn.ico',sizes=[(n,n) for n in (16,24,32,48,64,128,256)])
 splash=Image.open(assets/'splash.png').convert('RGB');splash.resize((500,281),Image.Resampling.LANCZOS).save(assets/'welcome.bmp')
 header=Image.new('RGB',(500,58),(12,20,32));sm=Image.open(assets/'logo.png').convert('RGBA');sm=sm.crop(sm.getbbox());sm.thumbnail((70,48),Image.Resampling.LANCZOS);header.paste(sm,(418+(70-sm.width)//2,(58-sm.height)//2),sm);header.save(assets/'header.bmp')
 lock=json.loads((ROOT/'dependencies.lock.json').read_text());row=next(r for r in lock if r['name'].startswith('PowerShell-'))
 archive=ROOT/'downloads'/row['name']
 assert sha(archive).lower()==row['sha256']
 runtime=P/'runtime/powershell';runtime.mkdir(parents=True)
 with zipfile.ZipFile(archive) as z:
  for n in z.namelist():
   if n.startswith(('/', '\\')) or '..' in Path(n).parts:raise ValueError('Unsafe upstream archive path')
  z.extractall(runtime)
 shutil.copy2(ROOT/'README.md',P/'README.md')
 shutil.copy2(ROOT/'THIRD-PARTY.md',P/'THIRD-PARTY.md')
 (P/'dependencies.lock.json').write_text(json.dumps([row],indent=2)+'\n')
 static={p.relative_to(P).as_posix():sha(p) for p in sorted(P.rglob('*')) if p.is_file() and ('runtime' not in p.relative_to(P).parts or p.name=='pwsh.exe')}
 (P/'suite-manifest.json').write_text(json.dumps(static,indent=2)+'\n')
 print(f'Staged {sum(p.is_file() for p in P.rglob("*"))} files; licence preserved verbatim; portable PowerShell SHA-256 verified.')
if __name__=='__main__':prepare()

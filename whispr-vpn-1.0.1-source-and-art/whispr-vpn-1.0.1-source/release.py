#!/usr/bin/env python3
"""Package the verified MSI plus reproducible sources and original branding."""
from pathlib import Path
import json,hashlib,shutil,zipfile
R=Path(__file__).resolve().parent;D=R.parent/'installer-deliverables';D.mkdir(exist_ok=True)
metadata=json.loads((R/'dist/build-metadata.json').read_text());report=json.loads((R/'dist/VERIFICATION.json').read_text())
msi=R/'dist/whispr-vpn-1.0.1-x64.msi'
assert hashlib.sha256(msi.read_bytes()).hexdigest()==metadata['sha256']==report['msi_sha256']
shutil.copy2(msi,D/msi.name)
kit=D/'whispr-vpn-1.0.1-source-and-art.zip'
with zipfile.ZipFile(kit,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
 for name in ['README.md','BUILD.md','THIRD-PARTY.md','LICENSE.md','dependencies.lock.json','fetch_dependencies.py','prepare.py','build_msi.py','release.py']:
  z.write(R/name,'whispr-vpn-1.0.1-source/'+name)
 for folder in ['src','art','packs','tests','native']:
  for p in sorted((R/folder).rglob('*')):
   if p.name == 'policy_test':continue
   if p.is_file() and '__pycache__' not in p.parts and not any(part.startswith('.') for part in p.relative_to(R).parts):z.write(p,'whispr-vpn-1.0.1-source/'+p.relative_to(R).as_posix())
 for name in ['VERIFICATION.json','build-metadata.json','SOURCE-VALIDATION.txt']:
  z.write(R/'dist'/name,'whispr-vpn-1.0.1-source/validation/'+name)
 for name in ['LICENSE.txt','ThirdPartyNotices.txt']:
  z.write(R/'payload/runtime/powershell'/name,'whispr-vpn-1.0.1-source/runtime-notices/powershell/'+name)
with zipfile.ZipFile(kit) as z:assert z.testzip() is None
shutil.copy2(R/'README.md',D/'READ-ME-FIRST.md')
checks=[]
for p in sorted(D.iterdir()):
 if p.is_file() and p.name!='SHA256SUMS.txt':checks.append(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name)
(D/'SHA256SUMS.txt').write_text('\n'.join(checks)+'\n')
print('\n'.join(f'{p.name}: {p.stat().st_size:,} bytes' for p in sorted(D.iterdir())))

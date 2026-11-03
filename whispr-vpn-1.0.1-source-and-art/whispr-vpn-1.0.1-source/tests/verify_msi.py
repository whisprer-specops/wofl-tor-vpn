#!/usr/bin/env python3
"""Read the actual MSI database and extracted embedded cabinet, never just XML."""
import hashlib,json,os,subprocess,sys,zipfile
from pathlib import Path
import gi
gi.require_version('Libmsi','1.0')
from gi.repository import Libmsi
R=Path(__file__).resolve().parents[1];M=R/'dist/whispr-vpn-1.0.1-x64.msi';P=R/'payload'
db=Libmsi.Database.new(str(M),int(Libmsi.DbFlags.READONLY),None)
def rows(table):
 q=Libmsi.Query.new(db,'SELECT * FROM `'+table+'`');q.execute(None);data=[]
 while True:
  r=q.fetch()
  if not r:break
  data.append([r.get_string(i) for i in range(1,r.get_field_count()+1)])
 q.close();return data
def keyed(table):return {r[0]:r for r in rows(table)}
file=keyed('File');components=keyed('Component');dirs=keyed('Directory');dialogs=keyed('Dialog');controls={(r[0],r[1]):r for r in rows('Control')};props={r[0]:r[1] for r in rows('Property')}
assert props['ProductName']=='whispr VPN' and props['ProductVersion']=='1.0.1'
assert props['REINSTALLMODE']=='amus', 'Modified unversioned desktop scripts must be replaced during upgrade/repair'
assert props['ALLUSERS']=='1' and props['MSIRESTARTMANAGERCONTROL']=='Disable'
assert 'ACCEPT_LICENSE' not in props,'Acceptance must never be pre-checked.'
assert 'ACCEPT_LICENSE' in props['SecureCustomProperties'].split(';')
assert 'OLDERVERSIONS' in props['SecureCustomProperties'].split(';')
static=json.loads((P/'suite-manifest.json').read_text())
with zipfile.ZipFile(R/'downloads/PowerShell-7.6.9-win-x64.zip') as z:
 runtime=['runtime/powershell/'+i.filename for i in z.infolist() if not i.is_dir()]
 for rel in runtime:assert (P/rel).read_bytes()==z.read(rel.removeprefix('runtime/powershell/')),'Runtime differs from verified archive: '+rel
expected=set(static)|set(runtime)|{'suite-manifest.json'}
assert len(file)==len(expected)
assert all(int(c[3])&256 for c in components.values()),'All components must use 64-bit registry/filesystem view.'
checks=rows('CheckBox');assert ['ACCEPT_LICENSE','1'] in checks
conditions=rows('LaunchCondition');assert any(r[0]=='Installed OR ACCEPT_LICENSE = "1"' for r in conditions)
assert not any('CORE_RUNTIME_LEASE' in r[0] for r in conditions), 'Stale lease alone must not block removal'
assert props['ProductCode']=='{B3CB5E52-AFB6-455A-B2DF-869111A0D101}'
assert props['UpgradeCode']=='{260C4308-9E2C-4C71-B65B-05199CB8262E}'
license_text=controls['LicenseDlg','License'][9]
assert license_text==(P/'LICENSE.rtf').read_text()
# Recover the plain text from this controlled RTF encoding and compare all supplied paragraphs.
prefix=r'{\rtf1\ansi\deff0{\fonttbl{\f0 Segoe UI;}}\viewkind4\uc1\pard\f0\fs18 '
assert license_text.startswith(prefix)
plain=license_text[len(prefix):-1].replace('\\par \n','\n').replace('\\{','{').replace('\\}','}').replace('\\\\','\\')
assert plain==(R/'LICENSE.md').read_text()
assert (P/'LICENSE.md').read_bytes()==(R/'LICENSE.md').read_bytes()
ce=rows('ControlEvent');assert any(r[:4]==['LicenseDlg','Next','NewDialog','InventoryDlg'] and r[4]=='ACCEPT_LICENSE = "1"' for r in ce)
assert any(r[:4]==['ReadyDlg','Next','EndDialog','Return'] and r[4]=='ACCEPT_LICENSE = "1"' for r in ce)
for d,c,e,a,cond,ordering in ce:
 assert (d,c) in controls
 if e in ['NewDialog','SpawnDialog']:assert a in dialogs
for d in dialogs.values():
 for name in d[7:10]:
  if name:assert (d[0],name) in controls
 for (dn,n),c in controls.items():
  if dn==d[0] and c[10]:assert (dn,c[10]) in controls
 # Every tabstop in each specified chain belongs to a closed cycle.
 first=d[7];seen=[];current=first
 while current and current not in seen:
  seen.append(current);current=controls[d[0],current][10]
 assert current==first,(d[0],seen,current)
assert controls['LicenseDlg','Cancel'][10]=='License'
assert set(['License','Agree','Back','Next','Cancel']).issubset({n for (d,n),c in controls.items() if d=='LicenseDlg' and c[10]})
cc=rows('ControlCondition')
assert ['LicenseDlg','Next','Disable','ACCEPT_LICENSE <> "1"'] in cc
assert ['LicenseDlg','Next','Enable','ACCEPT_LICENSE = "1"'] in cc
ui=keyed('InstallUISequence');exe=keyed('InstallExecuteSequence');ca=keyed('CustomAction')
assert int(ui['LaunchConditions'][2])>int(ui['WelcomeDlg'][2])
assert int(exe['LaunchConditions'][2])<int(exe['InstallInitialize'][2])
assert int(exe['CostFinalize'][2])<int(exe['WhisprInventory'][2])<int(exe['LaunchConditions'][2])<int(exe['InstallInitialize'][2])
assert int(exe['SetWhisprEnforce'][2])<int(exe['InstallInitialize'][2])<int(exe['WhisprEnforce'][2])<min(int(exe[x][2]) for x in ['ProcessComponents','RemoveFiles','InstallFiles'])
assert int(ui['CostFinalize'][2])<int(ui['WhisprInventory'][2])<int(ui['WelcomeDlg'][2])
assert int(exe['InstallExecute'][2])<int(exe['RemoveExistingProducts'][2])<int(exe['InstallFinalize'][2])
assert 'PrepareDesktopRemoval' not in exe and 'PrepareDesktopRemoval' not in ca
assert ca['WhisprInventory'][1:4]==['1','WhisprPreflight','Inventory']
assert ca['WhisprEnforce'][1:4]==['3073','WhisprPreflight','Enforce']
assert ca['SetWhisprEnforce'][1:4]==['51','WhisprEnforce','[REMOVE]|[UPGRADINGPRODUCTCODE]|[INSTALLFOLDER]']
assert exe['WhisprEnforce'][1] in ['',None], 'Every install, repair and removal must pass enforcement'
assert ['InventoryDlg','Next','Disable','WHISPR_PREFLIGHT_BLOCK = "1"'] in cc
assert any(r[:4]==['InventoryDlg','Next','NewDialog','ReadyDlg'] and r[4]=='WHISPR_PREFLIGHT_BLOCK <> "1"' for r in ce)
assert not any(x in exe for x in ['LaunchDesktop','SetupClient','StartVPN','RecoverVPN'])
assert ca['LaunchDesktop'][2] in file
assert len(rows('Shortcut'))==1
for action in ca.values():
 if int(action[1])&63==18:assert action[2] in file
# The installer artwork/icon streams must match the original embedded asset bytes too.
info=os.environ.get('MSIINFO','msiinfo')
for stream,rel in [('Binary.WelcomeArt','assets/welcome.bmp'),('Binary.HeaderArt','assets/header.bmp'),('Icon.ProductIcon','assets/whispr-vpn.ico'),('Binary.WhisprPreflight','@native')]:
 data=subprocess.run([info,'extract',str(M),stream],check=True,capture_output=True).stdout
 assert data==((R/'native/whispr-preflight.dll') if rel=='@native' else (P/rel)).read_bytes(),stream
# Ensure source/code hashes, including every original package manifest, agree after licence staging.
for manifest in [P/'suite-manifest.json',P/'packs/friend/PACKAGE-SHA256SUMS.json',P/'packs/friend/app/SHA256SUMS.json',P/'packs/group/PACKAGE-SHA256SUMS.json',P/'packs/owner/PACKAGE-SHA256SUMS.json']:
 for rel,wanted in json.loads(manifest.read_text()).items():assert hashlib.sha256((manifest.parent/rel).read_bytes()).hexdigest().upper()==wanted.upper(),str(manifest)+': '+rel
# Extract the cabinet using a separate msitools reader, then compare every payload byte.
extract=R/'extracted';extract.mkdir(exist_ok=True)
subprocess.run([os.environ.get('MSIEXTRACT','msiextract'),'-C',str(extract),str(M)],check=True,stdout=subprocess.DEVNULL)
roots=list(extract.rglob('suite-manifest.json'));assert len(roots)==1
actual=roots[0].parent
for rel in sorted(expected):
 p=P/rel
 dest=actual/p.relative_to(P)
 assert dest.is_file(),str(dest)
 assert hashlib.sha256(dest.read_bytes()).digest()==hashlib.sha256(p.read_bytes()).digest(),str(dest)
assert (actual/'runtime/powershell/pwsh.exe').read_bytes()[:2]==b'MZ'
report={'result':'PASS','msi_sha256':hashlib.sha256(M.read_bytes()).hexdigest(),'payload_files_verified':len(file),'dialogs_checked':len(dialogs),'licence_exact_text':True,'acceptance_prechecked':False,'quiet_install_acceptance_required':True,'existing_vpn_auto_modified':False,'windows_native_ui_tested':False,'windows_native_preflight_tested':False,'embedded_inventory_and_uninstall':True,'checks':['actual MSI tables/references and tab cycles','licence acceptance conditions in UI and execution','embedded native inventory in UI and execution; elevated enforcement before all file/component changes; independent of installed scripts; upgrade sequence','all static/package SHA-256 manifests','independent cabinet extraction: every payload file byte-for-byte']}
(R/'dist/VERIFICATION.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))

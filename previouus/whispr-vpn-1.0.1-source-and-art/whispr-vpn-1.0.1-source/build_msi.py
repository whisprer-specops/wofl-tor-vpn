#!/usr/bin/env python3
"""Build a native x64 MSI with an embedded cabinet and explicit licence-gated UI.
Run under /usr/bin/python3 with Libmsi 1.0 GI available (see BUILD.md).
"""
import hashlib,json,os,shutil,subprocess,uuid,zipfile,xml.etree.ElementTree as ET
from pathlib import Path
import gi
gi.require_version('Libmsi','1.0')
from gi.repository import Libmsi
ROOT=Path(__file__).resolve().parent
PAYLOAD=ROOT/'payload';OUT=ROOT/'dist';OUT.mkdir(exist_ok=True)
MSI=OUT/'whispr-vpn-1.0.1-x64.msi'
NS='http://schemas.microsoft.com/wix/2006/wi';ET.register_namespace('',NS)
UPGRADE='{260C4308-9E2C-4C71-B65B-05199CB8262E}'
PRODUCT='{B3CB5E52-AFB6-455A-B2DF-869111A0D101}'
COMP_NS=uuid.UUID('36ef75da-3f15-4d88-8a83-13b2d38d6c10')
def el(parent,tag,**attrs):return ET.SubElement(parent,'{'+NS+'}'+tag,{k:str(v) for k,v in attrs.items()})
def idof(prefix,path):return prefix+hashlib.sha256(path.encode()).hexdigest()[:28]
def fileid(path):return idof('F_',path)
def componentid(path):return idof('C_',path)
# Harvest authoritative staged paths, not temporary files made by file-sync services.
static=json.loads((PAYLOAD/'suite-manifest.json').read_text())
archive=ROOT/'downloads/PowerShell-7.6.9-win-x64.zip'
with zipfile.ZipFile(archive) as z:runtime=['runtime/powershell/'+i.filename for i in z.infolist() if not i.is_dir()]
files=[PAYLOAD/rel for rel in sorted(set(static)|set(runtime)|{'suite-manifest.json'})]
assert files and (PAYLOAD/'runtime/powershell/pwsh.exe').exists()
wix=ET.Element('{'+NS+'}Wix')
product=el(wix,'Product',Id=PRODUCT,Name='whispr VPN',Language='1033',Version='1.0.1',Manufacturer='whispr.dev',UpgradeCode=UPGRADE)
el(product,'Package',Id='*',InstallerVersion='500',Compressed='yes',InstallScope='perMachine',Description='whispr VPN desktop and shared-exit setup',Comments='Windows 11 x64; supplied Hybrid License acceptance required.')
el(product,'Media',Id='1',Cabinet='whispr.cab',EmbedCab='yes')
for name,value in {'ARPPRODUCTICON':'ProductIcon','ARPHELPLINK':'https://whispr.dev/','ARPNOMODIFY':'1','MSIRESTARTMANAGERCONTROL':'Disable','DefaultUIFont':'Normal','REINSTALLMODE':'amus','LAUNCH_APP':'1','ARPINSTALLLOCATION':'[INSTALLFOLDER]' }.items():el(product,'Property',Id=name,Value=value)
lease=el(product,'Property',Id='CORE_RUNTIME_LEASE');el(lease,'RegistrySearch',Id='FindRuntimeLease',Root='HKLM',Key=r'Software\whispr.dev\VPN Desktop',Name='CoreRuntimeLease',Type='raw',Win64='yes')
# BuildNumber is a registry string, used to block older Windows before files change.
build=el(product,'Property',Id='WINDOWS_BUILD');el(build,'RegistrySearch',Id='FindWindowsBuild',Root='HKLM',Key=r'SOFTWARE\Microsoft\Windows NT\CurrentVersion',Name='CurrentBuildNumber',Type='raw',Win64='yes')
up=el(product,'Upgrade',Id=UPGRADE)
el(up,'UpgradeVersion',Minimum='1.0.1',IncludeMinimum='no',OnlyDetect='yes',Property='NEWERPRODUCTFOUND')
el(up,'UpgradeVersion',Maximum='1.0.1',IncludeMaximum='no',Property='OLDERVERSIONS',MigrateFeatures='yes')
# Conditions are inserted below together with native UI/execute sequences.
el(product,'Icon',Id='ProductIcon',SourceFile=str(PAYLOAD/'assets/whispr-vpn.ico'))
root=el(product,'Directory',Id='TARGETDIR',Name='SourceDir')
pf=el(root,'Directory',Id='ProgramFiles64Folder');install=el(pf,'Directory',Id='INSTALLFOLDER',Name='whispr VPN')
dirs={'':install}
for p in files:
 relative=p.relative_to(PAYLOAD).as_posix();parent=p.relative_to(PAYLOAD).parent.as_posix();parent='' if parent=='.' else parent
 if parent not in dirs:
  current=''
  for part in parent.split('/'):
   previous=current;current='/'.join(filter(None,[current,part]))
   if current not in dirs:dirs[current]=el(dirs[previous],'Directory',Id=idof('D_',current),Name=part)
 comp=el(dirs[parent],'Component',Id=componentid(relative),Guid='{'+str(uuid.uuid5(COMP_NS,relative)).upper()+'}',Win64='yes')
 el(comp,'File',Id=fileid(relative),Name=p.name,Source=str(p),KeyPath='yes',DiskId='1')
regcomp=el(install,'Component',Id='DesktopRegistry',Guid='{F186EC11-D492-4B9C-A991-DFF9C8327299}',Win64='yes')
el(regcomp,'RegistryValue',Root='HKLM',Key=r'Software\whispr.dev\VPN Desktop',Name='InstallDir',Type='string',Value='[INSTALLFOLDER]',KeyPath='yes')
el(regcomp,'RegistryValue',Root='HKLM',Key=r'Software\whispr.dev\VPN Desktop',Name='ProductCode',Type='string',Value='[ProductCode]')
programs=el(root,'Directory',Id='ProgramMenuFolder');menu=el(programs,'Directory',Id='DesktopMenuFolder',Name='whispr VPN')
sc=el(menu,'Component',Id='DesktopShortcut',Guid='{A54D5CED-A63C-4CA0-A222-43AEC2695C28}',Win64='yes')
el(sc,'Shortcut',Id='OpenDesktop',Name='whispr VPN',Description='VPN control centre, shared exits and setup',Target='[#'+fileid('runtime/powershell/pwsh.exe')+']',Arguments='-NoLogo -NoProfile -STA -WindowStyle Hidden -File "[#'+fileid('Desktop.ps1')+']"',WorkingDirectory='INSTALLFOLDER',Icon='ProductIcon',IconIndex='0')
el(sc,'RegistryValue',Root='HKLM',Key=r'Software\whispr.dev\VPN Desktop',Name='StartMenuInstalled',Type='integer',Value='1',KeyPath='yes')
el(sc,'RemoveFolder',Id='RemoveDesktopMenuFolder',On='uninstall')
feature=el(product,'Feature',Id='Complete',Title='whispr VPN',Level='1',Absent='disallow')
for p in files:el(feature,'ComponentRef',Id=componentid(p.relative_to(PAYLOAD).as_posix()))
for c in ['DesktopRegistry','DesktopShortcut']:el(feature,'ComponentRef',Id=c)
wxs=ROOT/'Product.wxs';ET.ElementTree(wix).write(wxs,encoding='utf-8',xml_declaration=True)
wixl=os.environ.get('WIXL','wixl')
base=ROOT/'base.msi';stamp=ROOT/'base.sha256'
h=hashlib.sha256(wxs.read_bytes())
for f in files:h.update(f.relative_to(PAYLOAD).as_posix().encode());h.update(hashlib.sha256(f.read_bytes()).digest())
fingerprint=h.hexdigest()
if not base.exists() or not stamp.exists() or stamp.read_text()!=fingerprint:
 subprocess.run([wixl,'--arch','x64','-o',str(base),str(wxs)],check=True);stamp.write_text(fingerprint)
shutil.copyfile(base,MSI)
db=Libmsi.Database.new(str(MSI),int(Libmsi.DbFlags.TRANSACT),None)
def query(sql,record=None):
 q=Libmsi.Query.new(db,sql);q.execute(record);return q

def table(name,columns,key):
 # (name, SQL type, nullable) -- tables omitted by wixl are added explicitly.
 q=query("SELECT `Name` FROM `_Tables` WHERE `Name` = '"+name+"'");present=q.fetch() is not None;q.close()
 if not present:
  pieces=[f'`{n}` '+t.replace(' LOCALIZABLE','')+('' if nullable else ' NOT NULL')+(' LOCALIZABLE' if 'LOCALIZABLE' in t else '') for n,t,nullable in columns]
  query('CREATE TABLE `'+name+'` ('+', '.join(pieces)+' PRIMARY KEY '+', '.join('`'+k+'`' for k in key)+')').close()
 return [c[0] for c in columns]
def rows(name,columns,data):
 for values in data:
  assert len(columns)==len(values),(name,len(columns),values)
  rec=Libmsi.Record.new(len(values))
  for i,v in enumerate(values,1):
   if v is None:continue
   if isinstance(v,int):rec.set_int(i,v)
   else:rec.set_string(i,str(v))
  
  try:query('INSERT INTO `'+name+'` ('+', '.join('`'+c+'`' for c in columns)+') VALUES ('+','.join('?' for _ in columns)+')',rec).close()
  except Exception:
   print('INSERT FAILED',name,values,flush=True);raise
def schema(name,spec,key):return table(name,[(n,t,z) for n,t,z in spec],key)
q=query("SELECT `Value` FROM `Property` WHERE `Property` = 'SecureCustomProperties'")
r=q.fetch();secure=r.get_string(1).split(';') if r else [];q.close()
secure=';'.join(sorted(set(secure+['ACCEPT_LICENSE','CORE_RUNTIME_LEASE','WINDOWS_BUILD','OLDERVERSIONS','NEWERPRODUCTFOUND'])))
query("DELETE FROM `Property` WHERE `Property` = 'SecureCustomProperties'").close()
rows('Property',['Property','Value'],[['SecureCustomProperties',secure]])
# Native MSI UI: no HTML, custom EXE bootstrapper or remote licence page.
dcols=schema('Dialog',[('Dialog','CHAR(72)',False),('HCentering','SHORT',False),('VCentering','SHORT',False),('Width','SHORT',False),('Height','SHORT',False),('Attributes','LONG',True),('Title','CHAR(128) LOCALIZABLE',True),('Control_First','CHAR(50)',True),('Control_Default','CHAR(50)',True),('Control_Cancel','CHAR(50)',True)],['Dialog'])
ccols=schema('Control',[('Dialog_','CHAR(72)',False),('Control','CHAR(50)',False),('Type','CHAR(20)',False),('X','SHORT',False),('Y','SHORT',False),('Width','SHORT',False),('Height','SHORT',False),('Attributes','LONG',True),('Property','CHAR(72)',True),('Text','CHAR(0) LOCALIZABLE',True),('Control_Next','CHAR(50)',True),('Help','CHAR(50) LOCALIZABLE',True)],['Dialog_','Control'])
ecols=schema('ControlEvent',[('Dialog_','CHAR(72)',False),('Control_','CHAR(50)',False),('Event','CHAR(50)',False),('Argument','CHAR(0)',False),('Condition','CHAR(255)',True),('Ordering','SHORT',True)],['Dialog_','Control_','Event','Argument','Condition'])
conditions=schema('ControlCondition',[('Dialog_','CHAR(72)',False),('Control_','CHAR(50)',False),('Action','CHAR(50)',False),('Condition','CHAR(255)',False)],['Dialog_','Control_','Action','Condition'])
checks=schema('CheckBox',[('Property','CHAR(72)',False),('Value','CHAR(64)',True)],['Property'])
fonts=schema('TextStyle',[('TextStyle','CHAR(72)',False),('FaceName','CHAR(32) LOCALIZABLE',False),('Size','SHORT',False),('Color','LONG',True),('StyleBits','SHORT',True)],['TextStyle'])
rows('TextStyle',fonts,[['Normal','Segoe UI',9,None,0],['Title','Segoe UI',16,None,1],['Header','Segoe UI',13,16777215,1]])
rows('CheckBox',checks,[['ACCEPT_LICENSE','1'],['LAUNCH_APP','1']])
# Insert artwork streams in Binary.
bcols=schema('Binary',[('Name','CHAR(72)',False),('Data','OBJECT',False)],['Name'])
for name,path in [('WelcomeArt',PAYLOAD/'assets/welcome.bmp'),('HeaderArt',PAYLOAD/'assets/header.bmp'),('WhisprPreflight',ROOT/'native/whispr-preflight.dll')]:
 r=Libmsi.Record.new(2);r.set_string(1,name);r.load_stream(2,str(path));query('INSERT INTO `Binary` (`Name`,`Data`) VALUES (?,?)',r).close()
D=[];C=[];E=[]
def dialog(name,first,default,cancel,attrs=3):D.append([name,50,50,500,360,attrs,'whispr VPN Setup',first,default,cancel])
def ctl(d,n,t,x,y,w,h,text=None,prop=None,next=None,attrs=3):
 if t in ('Text','Bitmap'):attrs|=2
 C.append([d,n,t,x,y,w,h,attrs,prop,text,next,None])
def event(d,c,e,a,cond='1',order=1):E.append([d,c,e,a,cond,order])
def cancel(d,c='Cancel'):event(d,c,'EndDialog','Exit')
def header(d,title):
 ctl(d,'HeaderImage','Bitmap',0,0,500,58,'HeaderArt',attrs=1)
 ctl(d,'HeaderTitle','Text',20,19,390,24,'{\\Header}'+title,attrs=196609) # transparent + no-prefix, visible

def standardbuttons(d,back=None,nextdialog=None,label='Next >'):
 ctl(d,'Cancel','PushButton',420,331,65,20,'Cancel',next='Back' if back else 'Next');cancel(d)
 if back:
  ctl(d,'Back','PushButton',270,331,65,20,'< Back',next='Next');event(d,'Back','NewDialog',back)
 ctl(d,'Next','PushButton',345,331,65,20,label,next='Cancel')
 if nextdialog:event(d,'Next','NewDialog',nextdialog)

dialog('WelcomeDlg','Next','Next','Cancel')
ctl('WelcomeDlg','Art','Bitmap',0,0,500,281,'WelcomeArt',attrs=1)
ctl('WelcomeDlg','Intro','Text',20,289,460,31,'Install the whispr VPN control centre, shared-exit tools and portable PowerShell. Your existing VPN configuration is retained.',attrs=1)
standardbuttons('WelcomeDlg',nextdialog='LicenseDlg')
dialog('LicenseDlg','License','Next','Cancel');header('LicenseDlg','Your licence agreement')
ctl('LicenseDlg','Description','Text',20,66,460,18,'Read the supplied licence before continuing.',attrs=1)
ctl('LicenseDlg','License','ScrollableText',20,87,460,188,(PAYLOAD/'LICENSE.rtf').read_text(),next='Agree',attrs=3)
ctl('LicenseDlg','Agree','CheckBox',20,284,460,25,'I accept the terms of the licence agreement','ACCEPT_LICENSE','Back')
standardbuttons('LicenseDlg',back='WelcomeDlg')
event('LicenseDlg','Next','NewDialog','InventoryDlg','ACCEPT_LICENSE = "1"')
rows('ControlCondition',conditions,[['LicenseDlg','Next','Enable','ACCEPT_LICENSE = "1"'],['LicenseDlg','Next','Disable','ACCEPT_LICENSE <> "1"']])
dialog('InventoryDlg','Back','Next','Cancel');header('InventoryDlg','Check existing installations')
ctl('InventoryDlg','Summary','Text',20,72,460,242,'[WHISPR_PREFLIGHT_SUMMARY]',attrs=1)
standardbuttons('InventoryDlg',back='LicenseDlg')
event('InventoryDlg','Next','NewDialog','ReadyDlg','WHISPR_PREFLIGHT_BLOCK <> "1"')
rows('ControlCondition',conditions,[['InventoryDlg','Next','Enable','WHISPR_PREFLIGHT_BLOCK <> "1"'],['InventoryDlg','Next','Disable','WHISPR_PREFLIGHT_BLOCK = "1"']])
dialog('ReadyDlg','Back','Next','Cancel');header('ReadyDlg','Ready when you are')
ctl('ReadyDlg','Body','Text',20,83,460,205,'The desktop suite will be installed to:\n[INSTALLFOLDER]\n\nInstalling does not connect or replace your working VPN.\n\nOn a new PC, open the control centre and choose Set up this PC. That explicit step downloads the verified routing engines, creates this device\'s own key and prepares the public request for your group.\n\nWindows will ask for administrator approval.',attrs=1)
standardbuttons('ReadyDlg',back='InventoryDlg',label='Install')
event('ReadyDlg','Next','EndDialog','Return','ACCEPT_LICENSE = "1"')
dialog('MaintenanceDlg','Repair','Repair','Cancel');header('MaintenanceDlg','Maintain whispr VPN')
ctl('MaintenanceDlg','Body','Text',20,72,460,62,'Repair the installed desktop files or remove this desktop package. Saved client keys and exit settings stay outside the MSI. Checks are repeated after elevation before files change.',attrs=1)
ctl('MaintenanceDlg','Inventory','Text',20,142,460,121,'[WHISPR_PREFLIGHT_SUMMARY]',attrs=1)
ctl('MaintenanceDlg','Repair','PushButton',20,273,145,24,'Repair desktop',next='Remove')
ctl('MaintenanceDlg','Remove','PushButton',177,273,145,24,'Remove desktop',next='Cancel')
ctl('MaintenanceDlg','Cancel','PushButton',420,331,65,20,'Cancel',next='Repair');cancel('MaintenanceDlg')
event('MaintenanceDlg','Repair','[REINSTALL]','ALL',order=1);event('MaintenanceDlg','Repair','[REINSTALLMODE]','amus',order=2);event('MaintenanceDlg','Repair','EndDialog','Return',order=3)
event('MaintenanceDlg','Remove','[REMOVE]','ALL',order=1);event('MaintenanceDlg','Remove','EndDialog','Return',order=2)
dialog('ProgressDlg','Cancel','Cancel','Cancel',attrs=1);header('ProgressDlg','Working on your installation')
ctl('ProgressDlg','ActionText','Text',20,95,460,26,'Please wait while Windows Installer updates the desktop package.',attrs=1)
ctl('ProgressDlg','ActionData','Text',20,126,460,36,'',attrs=1)
ctl('ProgressDlg','Progress','ProgressBar',20,178,460,18,attrs=65537)
ctl('ProgressDlg','Note','Text',20,218,460,52,'Your VPN keys and group workspace are outside this MSI. No server setup, connection or guard recovery is run by installation.',attrs=1)
ctl('ProgressDlg','Cancel','PushButton',420,331,65,20,'Cancel',next='Cancel');event('ProgressDlg','Cancel','SpawnDialog','CancelDlg')
dialog('CancelDlg','No','No','No');header('CancelDlg','Cancel this installation?')
ctl('CancelDlg','Question','Text',20,90,460,100,'Cancel the current desktop installation? Windows Installer will roll back this transaction. VPN keys and group settings are retained.',attrs=1)
ctl('CancelDlg','Yes','PushButton',345,331,65,20,'Yes',next='No');event('CancelDlg','Yes','EndDialog','Exit')
ctl('CancelDlg','No','PushButton',420,331,65,20,'No',next='Yes');event('CancelDlg','No','EndDialog','Return')
mcols=schema('EventMapping',[('Dialog_','CHAR(72)',False),('Control_','CHAR(50)',False),('Event','CHAR(50)',False),('Attribute','CHAR(50)',False)],['Dialog_','Control_','Event'])
rows('EventMapping',mcols,[['ProgressDlg','ActionText','ActionText','Text'],['ProgressDlg','ActionData','ActionData','Text'],['ProgressDlg','Progress','SetProgress','Progress']])
dialog('FinishDlg','Launch','Finish','Finish');header('FinishDlg','All set')
ctl('FinishDlg','Body','Text',20,87,460,100,'Windows Installer has finished.\n\nOpen whispr VPN from the Start menu for the control centre. Existing users can open their original tray. New users choose Set up this PC.\n\nA green connection status comes from the VPN tray after its live transport checks.',attrs=1)
ctl('FinishDlg','Launch','CheckBox',20,226,460,26,'Open the whispr VPN control centre','LAUNCH_APP','Finish')
ctl('FinishDlg','Finish','PushButton',410,331,75,20,'Finish',next='Launch')
event('FinishDlg','Finish','DoAction','LaunchDesktop','LAUNCH_APP = "1" AND NOT (REMOVE = "ALL")',1)
event('FinishDlg','Finish','EndDialog','Return',order=2)
rows('ControlCondition',conditions,[['FinishDlg','Launch','Hide','REMOVE = "ALL"'],['FinishDlg','Launch','Disable','REMOVE = "ALL"']])
# Terminal dialogs use MSI's documented negative sequence numbers.
for name,title,body in [('UserExitDlg','Setup cancelled','The installation was cancelled. Any changes in the MSI transaction were rolled back.'),('FatalDlg','Setup could not finish','Windows Installer could not finish. Installed VPN keys/settings were retained. If files were in use, disconnect and close the client/tray before retrying.')]:
 dialog(name,'Close','Close','Close');header(name,title);ctl(name,'Body','Text',20,90,460,150,body,attrs=1)
 ctl(name,'Close','PushButton',410,331,75,20,'Close',next='Close');event(name,'Close','EndDialog','Return')
dialog('FilesInUse','List','Retry','Cancel');header('FilesInUse','Close the listed applications')
ctl('FilesInUse','Body','Text',20,82,460,68,'Some desktop/runtime files are in use. Disconnect / Recover and close the VPN tray if it uses this runtime, then close the control centre. This installer will not force-close them. Retry when ready, or cancel.',attrs=1)
ctl('FilesInUse','List','ListBox',20,157,460,130,prop='FileInUseProcess',next='Retry',attrs=65539)
ctl('FilesInUse','Retry','PushButton',345,331,65,20,'Retry',next='Cancel');event('FilesInUse','Retry','EndDialog','Retry')
ctl('FilesInUse','Cancel','PushButton',420,331,65,20,'Cancel',next='List');event('FilesInUse','Cancel','EndDialog','Exit')
for control in C:
 if control[0]=='LicenseDlg' and control[1]=='Cancel':control[10]='License'
rows('Dialog',dcols,D);rows('Control',ccols,C);rows('ControlEvent',ecols,E)
# Install gate applies to quiet installs too; maintenance does not re-ask an accepted licence.
lcols=schema('LaunchCondition',[('Condition','CHAR(255)',False),('Description','CHAR(255) LOCALIZABLE',False)],['Condition'])
rows('LaunchCondition',lcols,[['Installed OR (VersionNT64 AND WINDOWS_BUILD >= 22000)','whispr VPN requires Windows 11 x64.'],['Installed OR ACCEPT_LICENSE = "1"','Read and accept the licence before installing. For an authorised quiet install, pass ACCEPT_LICENSE=1.'],['NOT NEWERPRODUCTFOUND','A newer version of whispr VPN is already installed.'],['Installed OR WHISPR_PREFLIGHT_BLOCK <> "1"','An existing installation needs recovery: [WHISPR_PREFLIGHT_SUMMARY]']])
acols=schema('CustomAction',[('Action','CHAR(72)',False),('Type','SHORT',False),('Source','CHAR(72)',True),('Target','CHAR(255)',True)],['Action'])
rows('CustomAction',acols,[['LaunchDesktop',210,fileid('runtime/powershell/pwsh.exe'),'-NoLogo -NoProfile -STA -WindowStyle Hidden -File "[#'+fileid('Desktop.ps1')+']"'],['WhisprInventory',1,'WhisprPreflight','Inventory'],['SetWhisprEnforce',51,'WhisprEnforce','[REMOVE]|[UPGRADINGPRODUCTCODE]|[INSTALLFOLDER]'],['WhisprEnforce',3073,'WhisprPreflight','Enforce']])
seqcols=[('Action','CHAR(72)',False),('Condition','CHAR(255)',True),('Sequence','SHORT',True)]
scols=schema('InstallUISequence',seqcols,['Action'])
q=query('SELECT `Action` FROM `InstallUISequence`');actions=[]
while True:
 r=q.fetch()
 if not r:break
 actions.append(r.get_string(1))
q.close()
for action in actions:query("DELETE FROM `InstallUISequence` WHERE `Action` = '"+action+"'").close()
rows('InstallUISequence',scols,[['FindRelatedProducts',None,25],['AppSearch',None,50],['CostInitialize',None,800],['FileCost',None,900],['CostFinalize',None,1000],['WhisprInventory',None,1010],['WelcomeDlg','NOT Installed',1100],['MaintenanceDlg','Installed',1101],['LaunchConditions',None,1200],['ProgressDlg',None,1250],['ExecuteAction',None,1300],['FinishDlg',None,-1],['UserExitDlg',None,-2],['FatalDlg',None,-3]])
escols=schema('InstallExecuteSequence',seqcols,['Action'])
# Replace only the scheduled upgrade actions with explicit predictable positions.
for action in ['RemoveExistingProducts','InstallExecute','LaunchConditions']:
 query("DELETE FROM `InstallExecuteSequence` WHERE `Action` = '"+action+"'").close()
rows('InstallExecuteSequence',escols,[['WhisprInventory',None,1010],['LaunchConditions',None,1100],['SetWhisprEnforce',None,1490],['WhisprEnforce',None,1510],['InstallExecute',None,6500],['RemoveExistingProducts','OLDERVERSIONS',6550]])
# AppSearch / LaunchConditions are not necessarily emitted without WiX Condition elements.
existing=set();q=query('SELECT `Action` FROM `InstallExecuteSequence`')
while True:
 r=q.fetch()
 if not r:break
 existing.add(r.get_string(1))
q.close()
for a,c,s in [('FindRelatedProducts',None,25),('AppSearch',None,50),('LaunchConditions',None,100)]:
 if a not in existing:rows('InstallExecuteSequence',escols,[[a,c,s]])
db.commit()
metadata={'name':'whispr VPN','version':'1.0.1','product_code':PRODUCT,'upgrade_code':UPGRADE,'files':len(files),'sha256':hashlib.sha256(MSI.read_bytes()).hexdigest(),'bytes':MSI.stat().st_size,'windows_native_install_tested':False}
(OUT/'build-metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
print(json.dumps(metadata,indent=2))

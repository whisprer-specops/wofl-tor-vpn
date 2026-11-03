#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <msi.h>
#include <msiquery.h>
#include <shlobj.h>
#include <strsafe.h>
#include <tlhelp32.h>
#include <fwpmu.h>
#include <bcrypt.h>
#include <stdlib.h>
#include <wchar.h>
#include <stdio.h>
#include "policy.h"
#define CAP 4096
#define PRODUCT L"{B3CB5E52-AFB6-455A-B2DF-869111A0D101}"
#define UPGRADE L"{260C4308-9E2C-4C71-B65B-05199CB8262E}"
static GUID provider={0xd78d8eb9,0xb7c0,0x4e90,{0x9e,0xb4,0x0d,0x2e,0xc6,0x76,0x04,0x00}};
static void path(wchar_t *out,const wchar_t *root,const wchar_t *leaf){StringCchCopyW(out,CAP,root);StringCchCatW(out,CAP,L"\\");StringCchCatW(out,CAP,leaf);}
static void widen(const char *s,wchar_t *out,size_t cap){MultiByteToWideChar(CP_UTF8,0,s,-1,out,(int)cap);}
static int contains(const wchar_t *s,const wchar_t *part){size_t n=wcslen(part);for(;*s;s++){if(!_wcsnicmp(s,part,n))return 1;}return 0;}
static int presence(const wchar_t *p,Snapshot *s){DWORD a=GetFileAttributesW(p);if(a!=INVALID_FILE_ATTRIBUTES){if(a&FILE_ATTRIBUTE_REPARSE_POINT){s->links=1;}return 1;}DWORD e=GetLastError();if(e!=ERROR_FILE_NOT_FOUND&&e!=ERROR_PATH_NOT_FOUND){s->uncertain=1;return 2;}return 0;}
static int file(const wchar_t *root,const wchar_t *leaf,Snapshot *s){
 wchar_t p[CAP];path(p,root,leaf);size_t start=wcslen(root)+1;
 for(size_t i=start;p[i];i++)if(p[i]==L'\\'||p[i]==L'/'){wchar_t c=p[i];p[i]=0;int found=presence(p,s);p[i]=c;if(!found||s->links)return 0;}
 return presence(p,s);
}
static int all_files(const wchar_t *root,const wchar_t **names,Snapshot *s){for(int i=0;names[i];i++)if(!file(root,names[i],s))return 0;return 1;}
static wchar_t *read_small(const wchar_t *p,DWORD limit,Snapshot *s){
 if(!presence(p,s)||s->links)return NULL;
 HANDLE h=CreateFileW(p,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,0,NULL);
 if(h==INVALID_HANDLE_VALUE){if(GetLastError()!=ERROR_FILE_NOT_FOUND&&GetLastError()!=ERROR_PATH_NOT_FOUND)s->uncertain=1;return NULL;}
 DWORD n=GetFileSize(h,NULL);if(n==INVALID_FILE_SIZE||n>limit){CloseHandle(h);s->uncertain=1;return NULL;}
 BYTE *b=(BYTE*)calloc(n+4,1);DWORD got=0;if(!b||!ReadFile(h,b,n,&got,NULL)){free(b);CloseHandle(h);s->uncertain=1;return NULL;}CloseHandle(h);
 wchar_t *w=(wchar_t*)calloc(n+4,sizeof(wchar_t));if(!w){free(b);s->uncertain=1;return NULL;}
 if(got>=2&&b[0]==0xff&&b[1]==0xfe)memcpy(w,b+2,got-2);else{DWORD start=(got>=3&&b[0]==0xef&&b[1]==0xbb&&b[2]==0xbf)?3:0;MultiByteToWideChar(CP_UTF8,0,(char*)b+start,got-start,w,n+3);}
 SecureZeroMemory(b,n);free(b);return w;
}
static int marker(const wchar_t *root,Snapshot *s){
 wchar_t p[CAP];path(p,root,L"install-owner.txt");wchar_t *text=read_small(p,256,s);if(!text)return 0;
 size_t n=wcslen(text);while(n&&(text[n-1]==L'\r'||text[n-1]==L'\n'||text[n-1]==L' '))text[--n]=0;
 int ok=!wcscmp(text,L"whispr-hybrid-schema-1");free(text);return ok;
}
static int known_hash(const wchar_t *p){
 static const wchar_t *known[]={L"E685287C5F9FE8DDB9246FDA707649294768280888CFBF14C7CA8BB153E1D10F",L"6B72E649B1B4222B4EE9D653A66B6FCA2762CD76651AE1AEC3FFA5BCD2F73353",L"50051A0AF24D777FC4CD1FFAC68D9A07D6C6C3463AD2303391E78848DCD654A8",L"969EF0158DC47262A0980986DF24FAA84E2D1F495B8FCA0F6E86DCCF09ADE138",L"0EDC2988C37D20EF908680BD510EFC45C758CE1862ECEA57795739E02AA070F5",L"2A96ACF1191238EC02804392A028E6EA2CCC7E204A3B7355A8083194E22DC28D",L"8FF35ABD152D7C626B496F1958943DA3554961EA3FF971F221CEB1933BADB79E",L"DC2911ACCD7D400F33B4D7B74861717D8C8E76E65B99050B949FBCDF3E785749",L"EEA2ABEBA401DBD169F3D602C43C025A2791529637284E596FE8F00423D10089",L"58422B930C383E026C6B6028963AE00DEBECAE1288FFC8FDC2B103437A4A68E7",L"C5044094474790172C28EC99D288F608248794579C68B2DB3D451D37E0692CA5",NULL};
 HANDLE f=CreateFileW(p,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,0,NULL);if(f==INVALID_HANDLE_VALUE)return 0;
 BCRYPT_ALG_HANDLE a=NULL;BCRYPT_HASH_HANDLE h=NULL;BYTE digest[32],buf[16384];DWORD got;int ok=0;
 if(BCryptOpenAlgorithmProvider(&a,BCRYPT_SHA256_ALGORITHM,NULL,0)<0)goto done;
 if(BCryptCreateHash(a,&h,NULL,0,NULL,0,0)<0)goto done;
 while(ReadFile(f,buf,sizeof(buf),&got,NULL)&&got){if(BCryptHashData(h,buf,got,0)<0)goto done;}
 if(BCryptFinishHash(h,digest,32,0)<0)goto done;
 wchar_t hex[65];for(int i=0;i<32;i++)StringCchPrintfW(hex+i*2,3,L"%02X",digest[i]);hex[64]=0;
 for(int i=0;known[i];i++)if(!wcscmp(hex,known[i])){ok=1;break;}
 done:if(h)BCryptDestroyHash(h);if(a)BCryptCloseAlgorithmProvider(a,0);CloseHandle(f);return ok;
}
static void registrations(Snapshot *s){
 for(DWORD i=0;;i++){wchar_t id[39];UINT e=MsiEnumRelatedProductsW(UPGRADE,0,i,id);if(e==ERROR_NO_MORE_ITEMS)break;if(e!=ERROR_SUCCESS){s->uncertain=1;break;}
  wchar_t name[256],version[64],publisher[256],cache[CAP];DWORD n=256;
  if(MsiGetProductInfoW(id,INSTALLPROPERTY_INSTALLEDPRODUCTNAME,name,&n)!=ERROR_SUCCESS||wcscmp(name,L"whispr VPN")){s->unknown_registration=1;continue;}
  n=256;if(MsiGetProductInfoW(id,INSTALLPROPERTY_PUBLISHER,publisher,&n)!=ERROR_SUCCESS||wcscmp(publisher,L"whispr.dev")){s->unknown_registration=1;continue;}
  n=64;if(MsiGetProductInfoW(id,INSTALLPROPERTY_VERSIONSTRING,version,&n)!=ERROR_SUCCESS){s->uncertain=1;continue;}
  int major=0,minor=0,patch=0;if(swscanf(version,L"%d.%d.%d",&major,&minor,&patch)!=3){s->unknown_registration=1;continue;}
  if(major>1||(major==1&&(minor>0||patch>1))){s->newer=1;continue;}
  s->registered++;if(_wcsicmp(id,PRODUCT))s->older++;
  n=CAP;if(MsiGetProductInfoExW(id,NULL,MSIINSTALLCONTEXT_MACHINE,INSTALLPROPERTY_LOCALPACKAGE,cache,&n)!=ERROR_SUCCESS){if(_wcsicmp(id,PRODUCT))s->cache_missing=1;continue;}
  if(_wcsicmp(id,PRODUCT)&&!presence(cache,s))s->cache_missing=1;
 }
}
static void tasks(const wchar_t *root,const wchar_t *runtime,Snapshot *s,int depth){
 if(depth>24){s->uncertain=1;return;}
 wchar_t glob[CAP];path(glob,root,L"*");WIN32_FIND_DATAW d;HANDLE h=FindFirstFileW(glob,&d);
 if(h==INVALID_HANDLE_VALUE){DWORD e=GetLastError();if(depth==0&&e!=ERROR_FILE_NOT_FOUND&&e!=ERROR_PATH_NOT_FOUND)s->uncertain=1;return;}
 do{if(!wcscmp(d.cFileName,L".")||!wcscmp(d.cFileName,L".."))continue;wchar_t p[CAP];path(p,root,d.cFileName);
  if(d.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT){continue;}
  if(d.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY){tasks(p,runtime,s,depth+1);continue;}
  if(!_wcsnicmp(d.cFileName,L"whispr-HybridVPN-",wcslen(L"whispr-HybridVPN-")))s->tasks++;
  Snapshot read_status={0};wchar_t *xml=read_small(p,1048576,&read_status);if(read_status.uncertain&&!_wcsnicmp(d.cFileName,L"whispr-HybridVPN-",wcslen(L"whispr-HybridVPN-")))s->uncertain=1;if(xml){if(contains(xml,runtime))s->runtime_tasks++;free(xml);}
 }while(FindNextFileW(h,&d));FindClose(h);
}
static void processes(const wchar_t *suite,Snapshot *s){
 HANDLE snap=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);if(snap==INVALID_HANDLE_VALUE){s->uncertain=1;return;}PROCESSENTRY32W p={0};p.dwSize=sizeof(p);size_t n=wcslen(suite);
 if(Process32FirstW(snap,&p)){do{HANDLE h=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,p.th32ProcessID);if(!h)continue;wchar_t exe[CAP];DWORD len=CAP;if(QueryFullProcessImageNameW(h,0,exe,&len)&&!_wcsnicmp(exe,suite,n)&&exe[n]==L'\\')s->runtime_processes++;CloseHandle(h);}while(Process32NextW(snap,&p));}CloseHandle(snap);
}
static void gather(Snapshot *s){
 ZeroMemory(s,sizeof(*s));wchar_t pf[MAX_PATH],pd[MAX_PATH],suite[CAP],core[CAP],state[CAP],p[CAP],runtime[CAP];
 if(FAILED(SHGetFolderPathW(NULL,CSIDL_PROGRAM_FILES,NULL,SHGFP_TYPE_CURRENT,pf))||FAILED(SHGetFolderPathW(NULL,CSIDL_COMMON_APPDATA,NULL,SHGFP_TYPE_CURRENT,pd))){s->uncertain=1;return;}
 path(suite,pf,L"whispr VPN");path(core,pf,L"whispr Hybrid VPN");path(state,pd,L"whispr-hybrid");path(runtime,suite,L"runtime\\powershell\\pwsh.exe");
 int retained_friend=0;registrations(s);s->desktop_dir=presence(suite,s);s->core_dir=presence(core,s);s->state_dir=presence(state,s);if(s->links)return;
 const wchar_t *desktop[]={L"Desktop.ps1",L"Model.ps1",L"Worker.ps1",L"suite-manifest.json",L"runtime\\powershell\\pwsh.exe",L"runtime\\powershell\\System.Private.CoreLib.dll",L"assets\\splash.png",NULL};
 s->desktop_complete=all_files(suite,desktop,s);
 const wchar_t *proof[]={L"Model.ps1",L"Desktop.ps1",L"Worker.ps1",NULL};for(int i=0;proof[i];i++){path(p,suite,proof[i]);if(file(suite,proof[i],s)==1&&!s->links&&known_hash(p))s->desktop_known=1;}
 const wchar_t *client[]={L"install-owner.txt",L"SHA256SUMS.json",L"client\\Common.ps1",L"Recover.ps1",L"Tray.ps1",L"background\\Scheduler.ps1",L"bin\\whispr-vpn-guard.exe",L"bin\\sing-box.exe",L"bin\\tor\\tor.exe",NULL};
 s->core_marker=marker(core,s)&&marker(state,s);
 s->core_complete=all_files(core,client,s);
 s->key=file(state,L"device-key.json",s);s->profiles=file(state,L"peer.json",s)||file(state,L"profiles",s)||file(state,L"group-catalog.json",s);s->desktop_owned=file(core,L"desktop-owned.json",s);
 path(p,state,L"friend-install.json");wchar_t *meta=read_small(p,8192,s);if(meta){s->resumable=contains(meta,L"whispr-hybrid-friend")&&contains(meta,L"installing")&&marker(state,s);retained_friend=contains(meta,L"whispr-hybrid-friend")&&contains(meta,L"ready")&&marker(state,s)&&s->key&&!s->core_dir;free(meta);}
 HKEY k=NULL;if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"Software\\whispr.dev\\VPN Desktop",0,KEY_QUERY_VALUE|KEY_WOW64_64KEY,&k)==ERROR_SUCCESS){wchar_t val[16];DWORD n=sizeof(val),type=0;if(RegQueryValueExW(k,L"CoreRuntimeLease",NULL,&type,(BYTE*)val,&n)==ERROR_SUCCESS&&type==REG_SZ&&val[0]==L'1')s->lease=1;RegCloseKey(k);}
 wchar_t system[MAX_PATH];if(GetSystemDirectoryW(system,MAX_PATH)){path(p,system,L"Tasks");tasks(p,runtime,s,0);}processes(suite,s);
 SC_HANDLE scm=OpenSCManagerW(NULL,NULL,SC_MANAGER_CONNECT);if(scm){SC_HANDLE svc=OpenServiceW(scm,L"TorVPN",SERVICE_QUERY_STATUS);if(svc){SERVICE_STATUS st;if(QueryServiceStatus(svc,&st)&&st.dwCurrentState!=SERVICE_STOPPED)s->torvpn=1;CloseServiceHandle(svc);}CloseServiceHandle(scm);}
 HANDLE engine=NULL;DWORD e=FwpmEngineOpen0(NULL,RPC_C_AUTHN_DEFAULT,NULL,NULL,&engine);if(e==ERROR_SUCCESS){FWPM_PROVIDER0 *owned=NULL;e=FwpmProviderGetByKey0(engine,&provider,&owned);if(e==ERROR_SUCCESS){s->guard=1;FwpmFreeMemory0((void**)&owned);}else if(e!=0x80320005)s->uncertain=1;FwpmEngineClose0(engine);}else s->uncertain=1;
 if(retained_friend&&!s->tasks&&!s->guard)s->resumable=1;
}
static UINT error(MSIHANDLE session,const char *message){wchar_t text[2048];widen(message,text,2048);MSIHANDLE r=MsiCreateRecord(1);MsiRecordSetStringW(r,0,L"whispr VPN preflight: [1]");MsiRecordSetStringW(r,1,text);MsiProcessMessage(session,INSTALLMESSAGE_ERROR,r);MsiCloseHandle(r);return ERROR_INSTALL_FAILURE;}
__declspec(dllexport) UINT __stdcall Inventory(MSIHANDLE session){
 Snapshot s;gather(&s);Decision d=decide_install(&s);wchar_t state[128],action[2048],summary[3072];widen(d.state,state,128);widen(d.action,action,2048);
 StringCchPrintfW(summary,3072,L"Result: %s\n\n%s\n\nFound: %d registered MSI(s), %d older MSI(s), desktop folder %s, client folder %s, saved state %s, whispr task(s) %d.\n\nNo key contents were read. Inventory does not change files, tasks, network protection or installer registration.",state,action,s.registered,s.older,s.desktop_dir?L"present":L"absent",s.core_dir?L"present":L"absent",s.state_dir?L"present":L"absent",s.tasks);
 MsiSetPropertyW(session,L"WHISPR_PREFLIGHT_STATE",state);MsiSetPropertyW(session,L"WHISPR_PREFLIGHT_SUMMARY",summary);MsiSetPropertyW(session,L"WHISPR_PREFLIGHT_BLOCK",d.block?L"1":L"0");return ERROR_SUCCESS;
}
__declspec(dllexport) UINT __stdcall Enforce(MSIHANDLE session){
 wchar_t data[256];DWORD n=256;if(MsiGetPropertyW(session,L"CustomActionData",data,&n)!=ERROR_SUCCESS)return error(session,"Cannot read the preflight operation. No installation files were changed.");
 int removal=!wcsncmp(data,L"ALL|",4);wchar_t *separator=wcschr(data,L'|');wchar_t *root_sep=separator?wcschr(separator+1,L'|'):NULL;
 if(!root_sep)return error(session,"Incomplete preflight operation data.");
 wchar_t pf[MAX_PATH],expected[CAP];if(FAILED(SHGetFolderPathW(NULL,CSIDL_PROGRAM_FILES,NULL,SHGFP_TYPE_CURRENT,pf)))return error(session,"Cannot resolve the supported installation directory.");
 path(expected,pf,L"whispr VPN");wchar_t *chosen=root_sep+1;size_t len=wcslen(chosen);while(len&&chosen[len-1]==L'\\')chosen[--len]=0;
 if(_wcsicmp(chosen,expected))return error(session,"A custom install destination is not supported by this release. Use the default whispr VPN directory.");
 if(removal&&root_sep>separator+1)return ERROR_SUCCESS; /* Real major upgrade retains shared components. */
 Snapshot s;gather(&s);Decision d=removal?decide_remove(&s):decide_install(&s);
 if(!removal&&s.runtime_processes)return error(session,"Close the desktop and any session/tray using the bundled runtime before installing/repairing. Setup did not terminate them.");
 if(!removal&&s.uncertain)return error(session,"Some system state could not be inspected after elevation. Setup stopped before file changes; no saved identity was replaced.");
 if(d.block)return error(session,d.action);
 return ERROR_SUCCESS;
}
BOOL WINAPI DllMain(HINSTANCE instance,DWORD reason,LPVOID reserved){(void)instance;(void)reason;(void)reserved;return TRUE;}

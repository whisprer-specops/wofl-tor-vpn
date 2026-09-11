; =============================================================================
; TorVPN -- Inno Setup installer script
; =============================================================================
; This produces a single TorVPN-Setup.exe that:
;   * Installs to %ProgramFiles%\TorVPN
;   * Bundles torvpn-svc.exe, torvpn-tray.exe, scripts/, profiles/, the Tor
;     Expert Bundle, tun2socks.exe, and wintun.dll
;   * Registers and starts the Windows service post-install
;   * Adds the tray app to HKCU\...\Run for autostart at login
;   * Cleanly uninstalls the service and removes everything
;
; Before compiling: run installer\stage.ps1 to download Tor + tun2socks +
; wintun into installer\staging\. Then open this file in Inno Setup Compiler
; (ISCC) or run from CLI:
;
;     ISCC.exe installer\installer.iss
;
; Output appears in installer\Output\TorVPN-Setup.exe
; =============================================================================

#define MyAppName        "TorVPN"
#define MyAppVersion     "0.2.0"
#define MyAppPublisher   "whispr.dev"
#define MyAppURL         "https://whispr.dev/torvpn"
#define MyAppSvcExe      "torvpn-svc.exe"
#define MyAppTrayExe     "torvpn-tray.exe"
#define MyAppServiceName "TorVPN"

[Setup]
AppId={{F4B6A8C2-5E2D-4C9B-9C2A-8D6E1A0B3F47}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=TorVPN-Setup-{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64
ArchitecturesAllowed=x64
UninstallDisplayIcon={app}\{#MyAppTrayExe}
SetupIconFile=staging\icons\app.ico
DisableDirPage=auto
DisableReadyPage=no
ShowLanguageDialog=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "autostart"; \
    Description: "Start TorVPN tray icon at login (recommended)"; \
    GroupDescription: "Startup options:"

[Files]
; ---- Core binaries (built by `cargo build --release` per crate) -------------
Source: "..\target\release\{#MyAppSvcExe}";  DestDir: "{app}"; Flags: ignoreversion
Source: "..\target\release\{#MyAppTrayExe}"; DestDir: "{app}"; Flags: ignoreversion

; ---- Bundled PowerShell scripts ---------------------------------------------
Source: "..\scripts\fw-apply.ps1";    DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\scripts\fw-teardown.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\scripts\dns-apply.ps1";   DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\scripts\dns-teardown.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion

; ---- Default profile (installed read-only; user override goes in ProgramData)
Source: "..\profiles\default_win.toml"; DestDir: "{app}\profiles"; Flags: ignoreversion
Source: "..\profiles\obfs4_win.toml";   DestDir: "{app}\profiles"; Flags: ignoreversion

; ---- Tor expert bundle (staged by stage.ps1) --------------------------------
Source: "staging\tor\tor.exe";               DestDir: "{app}\tor";  Flags: ignoreversion
Source: "staging\tor\*.dll";                 DestDir: "{app}\tor";  Flags: ignoreversion recursesubdirs
Source: "staging\tor\data\*";                DestDir: "{app}\tor\data"; Flags: ignoreversion recursesubdirs createallsubdirs

; ---- tun2socks + Wintun driver ----------------------------------------------
Source: "staging\tun2socks\tun2socks.exe";   DestDir: "{app}";      Flags: ignoreversion
Source: "staging\wintun\wintun.dll";         DestDir: "{app}";      Flags: ignoreversion

; ---- Optional: icon for the uninstaller entry -------------------------------
Source: "staging\icons\app.ico"; DestDir: "{app}"; Flags: ignoreversion

[Dirs]
; ---- ProgramData state directory --------------------------------------------
; Created world-readable so the user-mode tray can read the auth token written
; by the LocalSystem service.
Name: "{commonappdata}\torvpn"; Permissions: users-readexec

[Icons]
Name: "{group}\{#MyAppName}";                Filename: "{app}\{#MyAppTrayExe}"
Name: "{group}\Uninstall {#MyAppName}";      Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}";          Filename: "{app}\{#MyAppTrayExe}"; Tasks: autostart

[Registry]
; Autostart the tray icon at login (current user only).
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
    ValueType: string; ValueName: "TorVPN"; ValueData: """{app}\{#MyAppTrayExe}"""; \
    Flags: uninsdeletevalue; Tasks: autostart

[Run]
; ---- Install + start the Windows service (service-install does both) -------
Filename: "{app}\{#MyAppSvcExe}"; Parameters: "service-install"; \
    StatusMsg: "Registering and starting TorVPN service..."; \
    Flags: runhidden waituntilterminated

; ---- Launch tray immediately ------------------------------------------------
Filename: "{app}\{#MyAppTrayExe}"; \
    Description: "Launch {#MyAppName} tray icon now"; \
    Flags: nowait postinstall skipifsilent

[UninstallRun]
; ---- Stop + unregister the service before file removal ---------------------
; service-uninstall internally calls `sc stop` then `sc delete`.
Filename: "{app}\{#MyAppSvcExe}"; Parameters: "service-uninstall"; \
    Flags: runhidden waituntilterminated; RunOnceId: "RemoveTorVPN"

; ---- Tear down any leftover firewall / DNS state ---------------------------
Filename: "powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\fw-teardown.ps1"""; \
    Flags: runhidden waituntilterminated; RunOnceId: "FwTeardown"

Filename: "powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\dns-teardown.ps1"""; \
    Flags: runhidden waituntilterminated; RunOnceId: "DnsTeardown"

[UninstallDelete]
; Wipe state directory on uninstall.
Type: filesandordirs; Name: "{commonappdata}\torvpn"

[Code]
// ---------- Kill any running tray instances before file replacement ----------
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{cmd}'), '/c taskkill /F /IM torvpn-tray.exe',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := '';
end;

// ---------- Same on uninstall (so we can delete the exe) ---------------------
function InitializeUninstall(): Boolean;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{cmd}'), '/c taskkill /F /IM torvpn-tray.exe',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := True;
end;

#requires -Version 5.1
[CmdletBinding()]
param([string]$MsiPath=(Join-Path $PSScriptRoot 'whispr-vpn-1.0.0-x64.msi'),[switch]$InspectOnly,[switch]$LibraryOnly,[switch]$PauseAtEnd)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$script:ProductCode='{8EECFA30-9E1C-439B-AC91-C6AA86359808}'
$script:UpgradeCode='{260C4308-9E2C-4C71-B65B-05199CB8262E}'
$script:MsiHash='C531DDDA17AD573C1E00A064EDCAF9E49919DB76BA8ACB9883B7691A1C9BB699'
$script:GuardHash='44863A7FAF76F8877681283F6A16E4CB02A3C051117439345C469364A4306EA6'
$script:Backup=$null;$script:NeedReboot=$false;$script:LastProgress=$null
function Value($Object,[string]$Name){if($null -eq $Object){return $null};$p=$Object.PSObject.Properties[$Name];if($p){return $p.Value};return $null}
function Say([string]$Text){Write-Host $Text;if($script:Backup){Add-Content -LiteralPath (Join-Path $script:Backup 'reset.log') -Value ((Get-Date -Format o)+' '+$Text) -Encoding UTF8}}
function Read-Json([string]$Path){
    $f=Get-Item -LiteralPath $Path -Force
    if($f -isnot [IO.FileInfo] -or $f.Length -gt 8388608 -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw ('Unexpected JSON file: '+[IO.Path]::GetFileName($Path))}
    try{return (Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json)}catch{throw ('Invalid JSON: '+[IO.Path]::GetFileName($Path)+'. Contents withheld.')}
}
function Write-Json($Object,[string]$Path){
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temp,($Object|ConvertTo-Json -Depth 50),[Text.UTF8Encoding]::new($false))
        if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temp,$Path,[NullString]::Value)}else{[IO.File]::Move($temp,$Path)}
    }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
}
function Is-Under([string]$Path,[string]$Root){if(-not $Path){return $false};return [IO.Path]::GetFullPath($Path).StartsWith(([IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)}
function Assert-Tree([string]$Path){
    if(-not (Test-Path -LiteralPath $Path)){return}
    $root=Get-Item -LiteralPath $Path -Force
    if($root -isnot [IO.DirectoryInfo] -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw ('Unexpected directory/link: '+$Path)}
    # Enumerate one level at a time, rejecting links BEFORE recursion (PS 5.1/7).
    $pending=New-Object 'Collections.Generic.Stack[string]';$pending.Push($Path)
    while($pending.Count){foreach($item in Get-ChildItem -LiteralPath $pending.Pop() -Force){
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Unexpected child link; nothing will be followed: '+$item.FullName)}
        if($item -is [IO.DirectoryInfo]){$pending.Push($item.FullName)}
    }}
}
function Secure-Directory([string]$Path){
    if(Test-Path -LiteralPath $Path){
        Assert-Tree $Path
        $owner=(Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if($owner -notin @('S-1-5-18','S-1-5-32-544')){throw ('Unexpected existing directory owner: '+$Path)}
    }else{[void](New-Item -ItemType Directory -Path $Path)}
    & (Join-Path ([Environment]::SystemDirectory) 'icacls.exe') $Path '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '/setowner' '*S-1-5-32-544' | Out-Null
    if($LASTEXITCODE -ne 0){throw ('Cannot secure backup/state directory: '+$Path)}
}
function Test-Key([string]$Key){
    if($Key -cnotmatch '^[A-Za-z0-9+/]{43}=$'){return $false}
    try{$bytes=[Convert]::FromBase64String($Key);return ($bytes.Length -eq 32 -and [Convert]::ToBase64String($bytes) -ceq $Key -and @($bytes|Where-Object {$_ -ne 0}).Count -gt 0)}catch{return $false}
}
function Get-SeedPlan([string]$State){
    $paths=New-Object 'Collections.Generic.List[string]';$keyPath=Join-Path $State 'device-key.json'
    if(-not (Test-Path -LiteralPath $keyPath)){return [pscustomobject]@{HasKey=$false;Files=@()}}
    $key=Read-Json $keyPath
    if(-not (Test-Key (Value $key 'PublicKey')) -or -not (Test-Key (Value $key 'PrivateKey'))){throw 'Device key is malformed. It was not changed. Reset stopped before removing files.'}
    $paths.Add('device-key.json');$pub=[string](Value $key 'PublicKey')
    foreach($relative in @('peer.json')+@(if(Test-Path -LiteralPath (Join-Path $State 'profiles')){Get-ChildItem -LiteralPath (Join-Path $State 'profiles') -File -Filter '*.json'|ForEach-Object {'profiles/'+$_.Name}})){
        $p=Join-Path $State $relative;if(-not (Test-Path -LiteralPath $p)){continue}
        $peer=Read-Json $p
        if((Value $peer 'client_public_key') -cne $pub -or (Value $peer 'interface') -cne 'wg-whispr' -or (Value $peer 'ssh_alias') -cnotmatch '^[a-z0-9][a-z0-9-]{0,79}$' -or -not (Test-Key (Value $peer 'server_public_key'))){throw ('Profile does not match this device: '+$relative+'. No reset was performed.')}
        $paths.Add($relative)
    }
    foreach($relative in @('friend-request.json','group-catalog.json')){
        $p=Join-Path $State $relative;if(-not (Test-Path -LiteralPath $p)){continue};$doc=Read-Json $p
        if($relative -eq 'friend-request.json' -and ((Value $doc 'Kind') -cne 'whispr-friend-request' -or (Value $doc 'PublicKey') -cne $pub)){throw 'Stored public request does not match the device key.'}
        $paths.Add($relative)
    }
    return [pscustomobject]@{HasKey=$true;Files=@($paths.ToArray())}
}
function Restore-Seed([string]$OldState,[string]$NewState,$Plan){
    if(-not $Plan.HasKey){return}
    Secure-Directory $NewState
    foreach($relative in $Plan.Files){
        $to=Join-Path $NewState $relative;$parent=Split-Path $to -Parent
        if(-not (Test-Path -LiteralPath $parent)){[void](New-Item -ItemType Directory -Path $parent)}
        Copy-Item -LiteralPath (Join-Path $OldState $relative) -Destination $to
        if((Get-FileHash -LiteralPath (Join-Path $OldState $relative) -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash){throw 'Preserved settings failed byte verification. Original backup remains intact.'}
    }
    # The new client installer accepts this incomplete friend bootstrap and reuses the key.
    [IO.File]::WriteAllText((Join-Path $NewState 'install-owner.txt'),'whispr-hybrid-schema-1',[Text.UTF8Encoding]::new($false))
    Write-Json @{schema=1;product='whispr-hybrid-friend';version='1.0.0';phase='installing'} (Join-Path $NewState 'friend-install.json')
}
function Test-OwnCommand([string]$Exe,[string]$Command,[string]$Core,[string]$Suite){
    if((Is-Under $Exe $Core) -or (Is-Under $Exe $Suite)){return $true}
    if([IO.Path]::GetFileName($Exe) -notin @('pwsh.exe','powershell.exe')){return $false}
    $scripts=@('Tray.ps1','Open-Tray.ps1','Start.ps1','Start-Background.ps1','background\Scheduled-Host.ps1','client\Session.ps1')|ForEach-Object {Join-Path $Core $_}
    $scripts+=@('Desktop.ps1','Worker.ps1')|ForEach-Object {Join-Path $Suite $_}
    foreach($path in $scripts){if($Command -match ('(?i)(?:^|\s)-File\s+"'+[regex]::Escape($path)+'"(?=\s|$)')){return $true}}
    return $false
}
function Test-TaskRecord([string]$Name,[string]$Source,[string]$Executable,[string]$Arguments,[string]$Working,[string]$Principal,[string]$Core,[string]$Suite){
    $refsSuite=Is-Under $Executable $Suite
    $owned=$Name -match '^whispr-HybridVPN-(Background|Autostart)-(S-1-5-[0-9-]+)$'
    if(-not $owned){if($refsSuite){throw ('Another task uses the bundled runtime: '+$Name+'. It was not removed.')};return $false}
    $kind=$Matches[1];$sid=$Matches[2]
    $sourceWanted=if($kind -eq 'Background'){'whispr-hybrid-on-demand-v1'}else{'whispr-hybrid-autostart-v1'}
    $scriptWanted=Join-Path $Core $(if($kind -eq 'Background'){'background\Scheduled-Host.ps1'}else{'Tray.ps1'})
    $workingWanted=if($kind -eq 'Background'){Join-Path $Core 'background'}else{$Core}
    if($Principal -notmatch '^S-1-'){$Principal=[Security.Principal.NTAccount]::new($Principal).Translate([Security.Principal.SecurityIdentifier]).Value}
    if($Source -cne $sourceWanted -or $Principal -ine $sid -or [IO.Path]::GetFileName($Executable) -ine 'pwsh.exe' -or $Working -ine $workingWanted -or $Arguments -notmatch ('(?i)(?:^|\s)-File\s+"'+[regex]::Escape($scriptWanted)+'"(?=\s|$)')){throw ('Task ownership differs: '+$Name+'. No task was removed.')}
    return $true
}
function Get-OwnTasks($Folder,[string]$Core,[string]$Suite){
    foreach($task in $Folder.GetTasks(1)){
        $d=$task.Definition
        foreach($a in $d.Actions){
            if($a.Type -ne 0){continue}
            if(Test-TaskRecord $task.Name $d.RegistrationInfo.Source ([string]$a.Path) ([string]$a.Arguments) ([string]$a.WorkingDirectory) ([string]$d.Principal.UserId) $Core $Suite){
                if($d.Actions.Count -ne 1){throw ('Unexpected task action count: '+$task.Path)}
                [pscustomobject]@{Task=$task;Folder=$Folder;Name=$task.Name;Xml=[string]$task.Xml}
            }
        }
    }
    foreach($sub in $Folder.GetFolders(0)){Get-OwnTasks $sub $Core $Suite}
}
function Stop-OwnProcesses([string]$Core,[string]$Suite){
    $deadline=[DateTime]::UtcNow.AddSeconds(25)
    do{
        $targets=@(Get-CimInstance Win32_Process|Where-Object {$_.ProcessId -ne $PID -and $_.ExecutablePath -and (Test-OwnCommand ([string]$_.ExecutablePath) ([string]$_.CommandLine) $Core $Suite)})
        if(-not $targets.Count){return}
        foreach($record in $targets){
            $again=Get-CimInstance Win32_Process -Filter ('ProcessId='+$record.ProcessId)
            if($again -and $again.CreationDate -eq $record.CreationDate -and $again.ExecutablePath -ieq $record.ExecutablePath -and (Test-OwnCommand ([string]$again.ExecutablePath) ([string]$again.CommandLine) $Core $Suite)){
                try{Stop-Process -Id $record.ProcessId -Force -ErrorAction Stop}catch{if(Get-Process -Id $record.ProcessId -ErrorAction SilentlyContinue){throw}}
            }
        }
        Start-Sleep -Milliseconds 300
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'An owned whispr process is still running. Files were retained.'
}
function Remove-OwnAdapter([string]$State){
    $adapters=@(Get-NetAdapter -Name 'whispr-hybrid' -IncludeHidden -ErrorAction SilentlyContinue)
    if(-not $adapters.Count){return};if($adapters.Count -ne 1){throw 'More than one whispr-hybrid adapter was found.'}
    $adapter=$adapters[0];$guid=([string]$adapter.InterfaceGuid).Trim('{}');$recorded=''
    if(Test-Path -LiteralPath (Join-Path $State 'session.json')){$session=Read-Json (Join-Path $State 'session.json');$recorded=([string](Value $session 'TunnelGuid')).Trim('{}')}
    $ips=@(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -ErrorAction Stop|Select-Object -ExpandProperty IPAddress)
    if($guid -ine $recorded -and '172.31.249.1' -notin $ips -and 'fd89:77:71::1' -notin $ips){throw 'The adapter ownership record and dedicated IPs are absent. No adapter was removed; backup/log identifies this stop.'}
    $devices=@(Get-CimInstance Win32_NetworkAdapter|Where-Object {$_.GUID -and ([string]$_.GUID).Trim('{}') -ieq $guid})
    if($devices.Count -ne 1 -or -not $devices[0].PNPDeviceID){throw 'Cannot map the whispr adapter to exactly one device.'}
    & (Join-Path ([Environment]::SystemDirectory) 'pnputil.exe') '/remove-device' ([string]$devices[0].PNPDeviceID) | Out-Host
    if($LASTEXITCODE -notin @(0,3010)){throw 'Exact whispr adapter removal failed.'}
    if($LASTEXITCODE -eq 3010){$script:NeedReboot=$true}
    Start-Sleep -Milliseconds 700
    if(Get-NetAdapter -Name 'whispr-hybrid' -IncludeHidden -ErrorAction SilentlyContinue){throw 'The owned adapter remains. Restart Windows, then rerun this pack. Protection was retained.'}
}
function Add-MsiApi {
    if('WhisprResetMsiApi' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class WhisprResetMsiApi {
 [DllImport("msi.dll",CharSet=CharSet.Unicode,ExactSpelling=true)] public static extern int MsiQueryProductStateW(string product);
 [DllImport("msi.dll",CharSet=CharSet.Unicode,ExactSpelling=true)] public static extern uint MsiEnumRelatedProductsW(string upgrade,uint reserved,uint index,StringBuilder product);
 [DllImport("msi.dll",CharSet=CharSet.Unicode,ExactSpelling=true)] public static extern uint MsiGetProductInfoW(string product,string property,StringBuilder value,ref uint length);
 public static string Info(string product,string property) { uint length=8191;var b=new StringBuilder(8192);uint e=MsiGetProductInfoW(product,property,b,ref length);if(e!=0)throw new InvalidOperationException("MSI metadata query failed: "+e);return b.ToString(); }
}
'@
}
function Get-RegisteredCodes {
    $found=New-Object 'Collections.Generic.List[string]'
    for([uint32]$index=0;;$index++){
        $b=New-Object Text.StringBuilder 39;$code=[WhisprResetMsiApi]::MsiEnumRelatedProductsW($script:UpgradeCode,0,$index,$b)
        if($code -eq 259){break};if($code -ne 0){throw ('Cannot enumerate owned MSI family: '+$code)};$found.Add($b.ToString())
    }
    if([WhisprResetMsiApi]::MsiQueryProductStateW($script:ProductCode) -ne -1 -and $script:ProductCode -notin $found){$found.Add($script:ProductCode)}
    foreach($product in $found){
        if($product -ine $script:ProductCode){throw ('A different desktop MSI version is registered: '+$product+'. This reset is scoped to 1.0.0; nothing was removed.')}
        if([WhisprResetMsiApi]::Info($product,'ProductName') -cne 'whispr VPN' -or [WhisprResetMsiApi]::Info($product,'Publisher') -cne 'whispr.dev' -or [WhisprResetMsiApi]::Info($product,'VersionString') -cne '1.0.0'){throw 'The registered product identity differs. No registry cleanup was attempted.'}
        $product
    }
}
function Run-Msi([string[]]$Arguments,[string]$Label){
    Say $Label
    $p=Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'msiexec.exe') -ArgumentList $Arguments -PassThru
    while(-not $p.WaitForExit(1000)){if(-not $script:LastProgress -or ((Get-Date)-$script:LastProgress).TotalSeconds -ge 15){Say 'Windows Installer is working; keep this window open.';$script:LastProgress=Get-Date}}
    $code=$p.ExitCode;$p.Dispose()
    if($code -eq 3010){$script:NeedReboot=$true;return}
    if($code -ne 0){$e=[InvalidOperationException]::new($Label+' failed (MSI '+$code+'). Backup retained: '+$script:Backup+'. Read the MSI log there; this script did not delete Windows Installer registration by hand.');$e.Data['MsiExitCode']=$code;throw $e}
}
function Secure-BackupTree([string]$Path){
    # Clear old explicit ACLs so moved key files cannot retain a broader read ACE.
    & (Join-Path ([Environment]::SystemDirectory) 'icacls.exe') $Path '/reset' '/T' '/Q' | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Backup ACL inheritance could not be secured. Original files are in the backup; reset stopped.'}
    & (Join-Path ([Environment]::SystemDirectory) 'icacls.exe') $Path '/setowner' '*S-1-5-32-544' '/T' '/Q' | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Backup ownership could not be secured. Reset stopped.'}
}
function Quarantine([string]$Path,[string]$Name){
    if(-not (Test-Path -LiteralPath $Path)){return}
    Assert-Tree $Path
    $destination=Join-Path $script:Backup $Name
    if(Test-Path -LiteralPath $destination){$destination+='-retry-'+[guid]::NewGuid().ToString('N')}
    Move-Item -LiteralPath $Path -Destination $destination -ErrorAction Stop
    if(Test-Path -LiteralPath $Path){throw ('The old directory could not be moved: '+$Path)}
    Secure-BackupTree $destination
    Say ('Preserved old files: '+$Name)
}
function Main {
    if($env:OS -ne 'Windows_NT'){throw 'Run this pack on Windows 11 x64.'}
    if(-not [Environment]::Is64BitProcess){throw 'Use 64-bit Windows PowerShell or PowerShell 7.'}
    $programs=[Environment]::GetFolderPath('ProgramFiles');$common=[Environment]::GetFolderPath('CommonApplicationData')
    $core=Join-Path $programs 'whispr Hybrid VPN';$suite=Join-Path $programs 'whispr VPN'
    $state=Join-Path $common 'whispr-hybrid';$workspace=Join-Path $common 'whispr-vpn-desktop'
    if((Is-Under $PSCommandPath $core) -or (Is-Under $PSCommandPath $suite)){throw 'Extract the reset pack to Downloads, outside the installed application.'}
    $runningHost=(Get-Process -Id $PID).Path
    if((Is-Under $runningHost $suite) -or (Is-Under $runningHost $core)){throw 'Use START-RESET.cmd so cleanup runs outside the runtime it must remove.'}
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{$admin=([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}finally{$identity.Dispose()}
    if(-not $admin){throw 'Open Administrator PowerShell and run this script again (or use START-RESET.cmd for UAC).'}
    foreach($root in @($core,$suite,$state,$workspace)){Assert-Tree $root}
    $msi=[IO.Path]::GetFullPath($MsiPath)
    if(-not (Test-Path -LiteralPath $msi) -or (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash -cne $script:MsiHash){throw 'The original verified 1.0.0 MSI is missing/changed. Extract the complete reset ZIP; no cleanup was started.'}
    $guard=Join-Path $PSScriptRoot 'tools\whispr-vpn-guard.exe'
    if(-not (Test-Path -LiteralPath $guard) -or (Get-FileHash -LiteralPath $guard -Algorithm SHA256).Hash -cne $script:GuardHash){throw 'The trusted recovery guard is missing/changed. Extract the complete reset ZIP.'}
    Add-MsiApi;$products=@(Get-RegisteredCodes)
    $service=New-Object -ComObject Schedule.Service
    try{
        $service.Connect();$tasks=@(Get-OwnTasks ($service.GetFolder('\')) $core $suite)
        $parent=Join-Path $common 'whispr-vpn-reset-backups'
        $pending=Join-Path $parent 'pending.json';$resume=$null
        if(Test-Path -LiteralPath $pending){
            Assert-Tree $parent
            if((Get-Acl -LiteralPath $parent).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){throw 'Unexpected backup folder owner.'}
            $resume=Read-Json $pending;$previous=[string](Value $resume 'Backup')
            if((Value $resume 'ProductCode') -ine $script:ProductCode -or -not (Is-Under $previous $parent) -or -not (Test-Path -LiteralPath $previous)){throw 'Pending recovery journal is not recognised. Original files were retained.'}
            Assert-Tree $previous
        }
        $seedSource=$state
        if($resume -and (Test-Path -LiteralPath (Join-Path $previous 'client-state'))){$seedSource=Join-Path $previous 'client-state'}
        $seed=Get-SeedPlan $seedSource
        Say ('Registered MSI packages: '+$products.Count+'; owned background/sign-in tasks: '+$tasks.Count)
        Say $(if($seed.HasKey){'Device key found. Its identity and approved profiles will be retained.'}else{'No device key was found. A fresh client will need new endpoint approval; recover the old key from your own backups if needed.'})
        if($InspectOnly){Say 'Inspection only: no files, tasks, network policy or MSI registration were changed.';return}
        Secure-Directory $parent
        if($resume){$script:Backup=$previous;Say 'Resuming the interrupted reset; its original backup is retained.'}
        else{$script:Backup=Join-Path $parent ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8));Secure-Directory $script:Backup}
        Write-Json @{ProductCode=$script:ProductCode;Backup=$script:Backup;StartedUtc=[DateTime]::UtcNow.ToString('o')} $pending
        Say ('Protected backup: '+$script:Backup)
        Say 'Reset is disconnecting whispr VPN. Normal Internet access will be restored when its own protection is removed.'
        if(-not (Test-Path -LiteralPath (Join-Path $script:Backup 'tasks'))){[void](New-Item -ItemType Directory -Path (Join-Path $script:Backup 'tasks'))}
        foreach($entry in $tasks){
            [IO.File]::WriteAllText((Join-Path $script:Backup ('tasks/'+$entry.Name+'-'+[guid]::NewGuid().ToString('N')+'.xml')),$entry.Xml,[Text.UTF8Encoding]::new($false))
            $entry.Task.Enabled=$false
            try{$entry.Task.Stop(0)}catch{if($entry.Task.State -eq 4){throw}}
        }
        Stop-OwnProcesses $core $suite
        foreach($entry in $tasks){$entry.Folder.DeleteTask($entry.Name,0);Say ('Removed owned task: '+$entry.Name)}
        Remove-OwnAdapter $seedSource
        & $guard recover | Out-Host;if($LASTEXITCODE -ne 0){throw 'Owned WFP recovery failed. No application/state directory was moved.'}
        $status=(& $guard status|Out-String).Trim();if($LASTEXITCODE -ne 0 -or $status -cne 'DISARMED'){throw 'Protection removal was not confirmed. Files retained.'}
        Say 'Confirmed DISARMED. Other VPN adapters and firewall policies were not reset.'
        if($products.Count){
            # Repair from the ORIGINAL MSI, recaching it and restoring the uninstaller runtime.
            # This MSI has no VPN setup/start/recover execution actions; full-UI launch is suppressed.
            Run-Msi @('/fvamus',('"'+$msi+'"'),'/qn','/norestart','REBOOT=ReallySuppress','LAUNCH_APP=0','/L*v',('"'+(Join-Path $script:Backup 'msi-repair.log')+'"')) 'Restoring missing MSI-owned files before uninstall'
        }
        # Stop a task/process that may have raced the earlier snapshot. Repair creates no tasks.
        if(@(Get-OwnTasks ($service.GetFolder('\')) $core $suite).Count){throw 'A whispr task reappeared. Stop its external launcher, then rerun.'}
        Stop-OwnProcesses $core $suite
        Quarantine $core 'client-files'
        if(Test-Path -LiteralPath $state){Quarantine $state 'client-state'}
        if(Test-Path -LiteralPath $workspace){Quarantine $workspace 'desktop-workspace'}
        if(Test-Path -LiteralPath 'HKLM:\Software\whispr.dev\VPN Desktop'){
            & (Join-Path ([Environment]::SystemDirectory) 'reg.exe') export 'HKLM\Software\whispr.dev\VPN Desktop' (Join-Path $script:Backup 'desktop-registration.reg') /y | Out-Null
            if($LASTEXITCODE -ne 0){throw 'Could not back up the app-owned runtime lease.'}
            [void](New-ItemProperty -LiteralPath 'HKLM:\Software\whispr.dev\VPN Desktop' -Name CoreRuntimeLease -PropertyType String -Value '0' -Force)
        }
        foreach($product in $products){
            try{Run-Msi @('/x',$product,'/qn','/norestart','REBOOT=ReallySuppress','LAUNCH_APP=0','/L*v',('"'+(Join-Path $script:Backup 'msi-uninstall.log')+'"')) 'Removing registered desktop MSI'}
            catch{
                if($_.Exception.Data['MsiExitCode'] -ne 1603){throw}
                # This pinned MSI's upgrade-removal condition skips only our redundant
                # read-only PrepareDesktopRemoval script. Its requirements are checked
                # independently here; no machine execution policy or cached MSI is edited.
                if(Test-Path -LiteralPath $core){throw 'Normal uninstall failed and the core path reappeared. No preflight bypass was attempted.'}
                if(@(Get-OwnTasks ($service.GetFolder('\')) $core $suite).Count){throw 'Normal uninstall failed and tasks remain. No preflight bypass was attempted.'}
                $guardState=(& $guard status|Out-String).Trim()
                if($LASTEXITCODE -ne 0 -or $guardState -cne 'DISARMED'){throw 'Normal uninstall failed; guard is not confirmed disarmed.'}
                Say 'Normal MSI removal failed. Retrying this exact package with its own script-preflight condition skipped, after independent checks passed.'
                Run-Msi @('/x',$product,('UPGRADINGPRODUCTCODE='+$script:ProductCode),'/qn','/norestart','REBOOT=ReallySuppress','LAUNCH_APP=0','/L*v',('"'+(Join-Path $script:Backup 'msi-uninstall-recovery.log')+'"')) 'Removing registered MSI with independently verified recovery preflight'
            }
        }
        if(@(Get-RegisteredCodes).Count -or [WhisprResetMsiApi]::MsiQueryProductStateW($script:ProductCode) -ne -1){throw 'Windows Installer still sees the package. Do not reinstall yet; the reset log and backup were retained.'}
        Quarantine $suite 'desktop-leftovers'
        $shortcuts=@((Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'whispr Hybrid VPN Tray.lnk'),(Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'whispr VPN\whispr VPN.lnk'))
        foreach($shortcut in $shortcuts){
            if(Test-Path -LiteralPath $shortcut){
                $shell=New-Object -ComObject WScript.Shell
                try{$link=$shell.CreateShortcut($shortcut);if((Is-Under $link.TargetPath $suite) -or (Test-OwnCommand $link.TargetPath $link.Arguments $core $suite)){Move-Item -LiteralPath $shortcut -Destination (Join-Path $script:Backup ([IO.Path]::GetFileName($shortcut)))}}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
            }
        }
        $oldState=Join-Path $script:Backup 'client-state'
        if(Test-Path -LiteralPath $oldState){Restore-Seed $oldState $state $seed}
        $oldGroup=Join-Path $script:Backup 'desktop-workspace\group'
        if(Test-Path -LiteralPath $oldGroup){
            Secure-Directory $workspace;[void](New-Item -ItemType Directory -Path (Join-Path $workspace 'group'))
            foreach($name in @('group.json','my-vps.json')){if(Test-Path -LiteralPath (Join-Path $oldGroup $name)){Copy-Item -LiteralPath (Join-Path $oldGroup $name) -Destination (Join-Path $workspace ('group/'+$name))}}
        }
        Say 'RESET COMPLETE: the desktop MSI is no longer registered. Old program files are quarantined; keys/settings are preserved.'
        if($script:NeedReboot){Say 'Windows requested a restart. Restart BEFORE reinstalling.'}
        Say ('Next: double-click '+$msi+'; accept the licence and install. Then open whispr VPN and choose SET UP THIS PC once, even though its key/exits were preserved.')
        Say 'Do not run an old Downloads copy or restore old executable/script files. Re-enable auto-connect only after the fresh client verifies green.'
        Write-Json @{Result='ReadyForFreshMsi';Backup=$script:Backup;KeyPreserved=[bool]$seed.HasKey;RebootRequired=[bool]$script:NeedReboot;Msi=$msi;CompletedUtc=[DateTime]::UtcNow.ToString('o')} (Join-Path $script:Backup 'result.json')
        Remove-Item -LiteralPath $pending -Force
    }finally{if([Runtime.InteropServices.Marshal]::IsComObject($service)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($service)}}
}
if(-not $LibraryOnly){
    $mutex=$null;$locked=$false;$exitCode=0;$script:LastProgress=$null
    try{
        $mutex=[Threading.Mutex]::new($false,'Global\whisprVpnReset100')
        try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw 'Another reset is already running.'}
        Main
    }catch{
        $exitCode=1;$failure=$_.Exception.Message;Write-Host ('STOPPED: '+$failure) -ForegroundColor Red
        if($script:Backup){
            try{Add-Content -LiteralPath (Join-Path $script:Backup 'reset.log') -Value ('STOPPED: '+$failure) -Encoding UTF8;Write-Json @{Result='Stopped';Message=$failure;Backup=$script:Backup} (Join-Path $script:Backup 'result.json')}catch{}
            Write-Host ('Backup/log: '+$script:Backup)
            try{
                $original=Join-Path $script:Backup 'client-state';$live=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'whispr-hybrid'
                if((Test-Path -LiteralPath $original) -and -not (Test-Path -LiteralPath $live)){Restore-Seed $original $live (Get-SeedPlan $original);Write-Host 'Preserved identity/settings re-seeded for retry. The original full backup is intact.'}
            }catch{Write-Host 'Could not re-seed identity automatically; the original protected backup remains. Do not set up a new identity yet.'}
        }
    }
    finally{if($locked){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}}
    if($PauseAtEnd){[void](Read-Host 'Press Enter to close')}
    exit $exitCode
}

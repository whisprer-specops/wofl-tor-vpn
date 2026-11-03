#requires -Version 7.2
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$DeviceName='Friend-PC',[string]$OutputDirectory=$PSScriptRoot)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/app/friend/Protocol.ps1"
Assert-FriendPackage $PSScriptRoot
if(-not $IsWindows){throw 'Use Administrator PowerShell 7 x64 on Windows 11.'}
if($DeviceName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$'){throw 'Use a device name of 1-64 letters, digits, spaces, dot, underscore or hyphen.'}
. "$PSScriptRoot/app/client/Common.ps1"
. "$PSScriptRoot/app/client/Permissions.ps1"
. "$PSScriptRoot/app/client/Fetch-Engine.ps1"
. "$PSScriptRoot/app/client/Fetch-Tor.ps1"
Assert-HybridBaseline
$homeDir=Get-HybridHome;$stateDir=Get-HybridState
# Reject the owner's existing installation before creating or changing anything.
foreach($root in @($homeDir,$stateDir)){
    if(Test-Path -LiteralPath $root){
        $item=Get-Item -LiteralPath $root -Force
        if($item -isnot [IO.DirectoryInfo] -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected installation/state directory.'}
        if((Get-Acl -LiteralPath $root).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){throw 'Existing directory ownership is unrecognized.'}
        if((Get-Content -LiteralPath (Join-Path $root 'install-owner.txt') -Raw).Trim() -ne 'whispr-hybrid-schema-1'){throw 'Existing installation marker differs.'}
        $mode=Read-FriendJson (Join-Path $root $(if($root -eq $homeDir){'friend-mode.json'}else{'friend-install.json'}))
        if($mode.product -cne 'whispr-hybrid-friend'){throw 'This PC has the owner/another VPN installation. Install the friend pack only on the friend PC.'}
    }
}
if(Test-Path -LiteralPath (Join-Path $homeDir 'SHA256SUMS.json')){
    $prior=Read-FriendJson (Join-Path $stateDir 'friend-install.json')
    if($prior.phase -eq 'ready'){Assert-HybridManifest $homeDir}
    elseif($prior.phase -ne 'installing'){throw 'Unrecognized friend installation phase.'}
    $guard=Join-Path $homeDir 'bin/whispr-vpn-guard.exe'
    if(Test-Path -LiteralPath $guard){
        if((Get-FileHash -LiteralPath $guard -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath "$PSScriptRoot/app/bin/whispr-vpn-guard.exe" -Algorithm SHA256).Hash){throw 'Installed guard is not the recognized friend guard; no repair was attempted.'}
        $status=(& $guard status|Out-String).Trim()
        if($LASTEXITCODE -ne 0 -or $status -ne 'DISARMED'){throw 'Disconnect / Recover the existing friend VPN before reinstalling.'}
    }elseif($prior.phase -ne 'installing'){throw 'The installed guard is missing. Existing installation was not changed.'}
}
$trayMutex=[Threading.Mutex]::new($false,'Global\whisprHybridTray010');$sessionMutex=[Threading.Mutex]::new($false,'Global\whisprHybridVpn040');$trayLocked=$false;$sessionLocked=$false
try{
    try{$trayLocked=$trayMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$trayLocked=$true}
    try{$sessionLocked=$sessionMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$sessionLocked=$true}
    if(-not $trayLocked -or -not $sessionLocked){throw 'Close the tray and stop the existing friend session before reinstalling.'}
    foreach($root in @($homeDir,$stateDir)){
        if(-not (Test-Path -LiteralPath $root)){
            [void](New-Item -ItemType Directory -Path $root)
            Invoke-HybridChecked icacls.exe @($root,'/setowner','*S-1-5-32-544')
        }
        Repair-HybridTreePermissions -Root $root -AllowUsersRead ($root -eq $homeDir)
        if(-not (Test-Path -LiteralPath (Join-Path $root 'install-owner.txt'))){'whispr-hybrid-schema-1'|Set-Content -LiteralPath (Join-Path $root 'install-owner.txt') -Encoding utf8NoBOM}
    }
    Write-FriendJson @{schema=1;product='whispr-hybrid-friend';version='1.0.0';phase='installing'} (Join-Path $stateDir 'friend-install.json')
    Copy-Item -LiteralPath "$PSScriptRoot/app/friend-mode.json" -Destination (Join-Path $homeDir 'friend-mode.json') -Force
    foreach($item in Get-ChildItem -LiteralPath "$PSScriptRoot/app" -Force){Copy-Item -LiteralPath $item.FullName -Destination $homeDir -Recurse -Force}
    $guard=Join-Path $homeDir 'bin/whispr-vpn-guard.exe'
    $status=(& $guard status|Out-String).Trim()
    if($LASTEXITCODE -ne 0 -or $status -ne 'DISARMED'){throw 'Existing persistent protection is armed/unknown. Use the installed Recover.ps1 explicitly before continuing.'}
    Install-HybridEngine $homeDir $stateDir
    Install-HybridTor $homeDir $stateDir
    $keyPath=Join-Path $stateDir 'device-key.json'
    if(Test-Path -LiteralPath $keyPath){$key=Read-FriendJson $keyPath}
    else{
        $pair=(& (Join-Path $homeDir 'bin/sing-box.exe') generate wg-keypair|Out-String)
        if($LASTEXITCODE -ne 0){throw 'Device key generation failed.'}
        $private=[regex]::Match($pair,'(?m)^PrivateKey:\s*(\S+)').Groups[1].Value
        $public=[regex]::Match($pair,'(?m)^PublicKey:\s*(\S+)').Groups[1].Value
        Assert-FriendKey $public;Assert-FriendKey $private
        $key=@{PrivateKey=$private;PublicKey=$public};Write-HybridJson $key $keyPath
        $pair=$null;$private=$null
    }
    Assert-FriendKey $key.PublicKey;Assert-FriendKey $key.PrivateKey
    Assert-HybridManifest $homeDir
    . "$homeDir/tray/Model.ps1";Assert-TrayAddon $homeDir
    Write-Host 'Checking independent background lifetime with disposable dummy processes; VPN stays off...'
    & "$PSScriptRoot/tests/Test-Windows-Scheduled.ps1" -StateRoot $stateDir
    $shortcut=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'whispr Hybrid VPN Tray.lnk'
    $shell=New-Object -ComObject WScript.Shell
    try{
        $link=$shell.CreateShortcut($shortcut);$link.TargetPath=Join-Path $PSHOME 'pwsh.exe'
        $link.Arguments='-NoLogo -NoProfile -WindowStyle Hidden -File "'+(Join-Path $homeDir 'Open-Tray.ps1')+'"'
        $link.WorkingDirectory=$homeDir;$link.Description='whispr VPN Friend — approved exits; UAC required';$link.IconLocation=(Join-Path $env:SystemRoot 'System32/shell32.dll')+',13';$link.Save()
    }finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
    Write-FriendJson @{schema=1;product='whispr-hybrid-friend';version='1.0.0';phase='ready'} (Join-Path $stateDir 'friend-install.json')
    & "$homeDir/New-Request.ps1" -OutputDirectory $OutputDirectory -DeviceName $DeviceName
    Write-Host 'Installed. No tunnel, guard, auto-connect task or server change has been activated.' -ForegroundColor Cyan
    Write-Host 'Send friend-request.json to the owner. When they return friend-access.json, run Import-Access.ps1 with that file.'
}finally{if($sessionLocked){$sessionMutex.ReleaseMutex()};$sessionMutex.Dispose();if($trayLocked){$trayMutex.ReleaseMutex()};$trayMutex.Dispose()}

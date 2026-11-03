#requires -Version 7.2
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$AccessFile,[switch]$EnableAutoConnect,[switch]$NoLaunch)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/client/Common.ps1"
. "$PSScriptRoot/tray/Model.ps1"
. "$PSScriptRoot/friend/Protocol.ps1"
. "$PSScriptRoot/friend/Local.ps1"
$homeDir=Get-HybridHome;$stateDir=Get-HybridState
if($PSScriptRoot -ne $homeDir){throw 'Use the installed Import-Access.ps1.'}
Assert-FriendInstallation $homeDir $stateDir
Assert-TrayAddon $homeDir
$request=Read-FriendJson (Join-Path $stateDir 'friend-request.json') 4096
$key=Read-FriendJson (Join-Path $stateDir 'device-key.json')
if($request.PublicKey -cne $key.PublicKey){throw 'Local request/key mismatch. No exit profile was changed.'}
$access=Read-FriendJson $AccessFile
Assert-FriendAccess $access $request
$trayMutex=[Threading.Mutex]::new($false,'Global\whisprHybridTray010');$trayLocked=$false;$sessionMutex=$null
try{
    try{$trayLocked=$trayMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$trayLocked=$true}
    if(-not $trayLocked){throw 'Disconnect normally, then choose Close tray only before importing updated exit profiles.'}
    $sessionMutex=Enter-TraySessionLock
    Assert-TrayDisconnected $homeDir
    $profiles=Join-Path $stateDir 'profiles'
    if(Test-Path -LiteralPath $profiles){if((Get-Item -LiteralPath $profiles -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected profile-directory reparse point.'}}
    [void](New-Item -ItemType Directory -Path $profiles -Force)
    $paths=@('peer.json','friend-access-receipt.json')+@('nyc1','lon1','fkt1','sgp1','syd1'|ForEach-Object {"profiles/$_.json"})
    $backup=Join-Path $stateDir ('friend-import-backups/'+[guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $backup -Force)
    $before=@{}
    foreach($relative in $paths){
        $path=Join-Path $stateDir $relative;$before[$relative]=Test-Path -LiteralPath $path
        if($before[$relative]){
            if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected profile-file reparse point.'}
            $dest=Join-Path $backup $relative;[void](New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force);Copy-Item -LiteralPath $path -Destination $dest
        }
    }
    $selected=$null
    if($before['peer.json']){
        $old=Read-FriendJson (Join-Path $stateDir 'peer.json')
        $selected=@($access.Exits|Where-Object {$_.ssh_alias -eq $old.ssh_alias})|Select-Object -First 1
    }
    if(-not $selected){$selected=@($access.Exits|Where-Object ssh_alias -eq 'nyc1')|Select-Object -First 1}
    if(-not $selected){$selected=$access.Exits[0]}
    try{
        foreach($peer in $access.Exits){Write-FriendJson $peer (Join-Path $profiles ($peer.ssh_alias+'.json'))}
        foreach($alias in @('nyc1','lon1','fkt1','sgp1','syd1')){
            $path=Join-Path $profiles "$alias.json"
            if($alias -notin @($access.Exits|ForEach-Object ssh_alias) -and (Test-Path -LiteralPath $path)){Remove-Item -LiteralPath $path -Force}
        }
        Write-FriendJson $selected (Join-Path $stateDir 'peer.json')
        Write-FriendJson @{Schema=1;RequestId=$request.RequestId;Fingerprint=$request.Fingerprint;ImportedUtc=[datetime]::UtcNow.ToString('o');ApprovedExits=@($access.Exits|ForEach-Object ssh_alias)} (Join-Path $stateDir 'friend-access-receipt.json')
    }catch{
        $failure=$_
        foreach($relative in $paths){$path=Join-Path $stateDir $relative;if($before[$relative]){Copy-Item -LiteralPath (Join-Path $backup $relative) -Destination $path -Force}elseif(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}}
        throw $failure
    }
}finally{if($sessionMutex){$sessionMutex.ReleaseMutex();$sessionMutex.Dispose()};if($trayLocked){$trayMutex.ReleaseMutex()};$trayMutex.Dispose()}
if($EnableAutoConnect){
    . "$homeDir/background/Scheduler.ps1";. "$homeDir/background/Resume.ps1";. "$homeDir/background/Autostart.ps1"
    Set-HybridAutoConnect $homeDir $stateDir $true
    if(-not (Get-HybridAutoEnabled $homeDir)){throw 'Profiles imported, but auto-connect could not be enabled. Use the tray checkbox.'}
}
Write-Host "Imported $($access.Exits.Count) approved exits. Selected: $($selected.ssh_alias). Click Connect and wait for green." -ForegroundColor Green
Write-Host 'No connection has been started by this import. Auto-connect, if enabled, runs at this user sign-in after restart.'
if(-not $NoLaunch){& "$homeDir/Open-Tray.ps1"}

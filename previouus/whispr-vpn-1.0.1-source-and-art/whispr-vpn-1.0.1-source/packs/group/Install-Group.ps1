#requires -Version 7.2
#requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$NoLaunch)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/group/Protocol.ps1";. "$PSScriptRoot/group/Local.ps1"
. "$PSScriptRoot/group/Flags.ps1"
Assert-GroupPackage $PSScriptRoot;$identity=Get-GroupLocalIdentity
. "$($identity.Home)/client/Common.ps1";. "$($identity.Home)/tray/Model.ps1"
Assert-TrayAddon $identity.Home
$trayMutex=[Threading.Mutex]::new($false,'Global\whisprHybridTray010');$locked=$false;$sessionMutex=$null
try{
    try{$locked=$trayMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Disconnect / Recover, then Close tray only before installing the group add-on.'}
    $sessionMutex=Enter-TraySessionLock;Assert-TrayDisconnected $identity.Home
    $markerPath=Join-Path $identity.Home 'group-addon.json'
    if(Test-Path -LiteralPath $markerPath){
        $marker=Read-GroupJson $markerPath;$same=$marker.Version -eq '1.0.1'
        foreach($relative in @('tray/Model.ps1','tray/MapModel.ps1','tray/Map.ps1','group/Protocol.ps1','group/Client.ps1')){
            if((Get-FileHash -LiteralPath (Join-Path $identity.Home $relative)).Hash -ne (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot "payload/$relative")).Hash){$same=$false}
        }
        if($same){Write-Host 'Group add-on 1.0.1 is already installed. No files changed; reopen the tray from Start when ready.' -ForegroundColor Green;return}
    }

    $backup=Join-Path $identity.State ('group-backups/install-'+[guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory -Path $backup -Force)
    $files=@('Tray.ps1','tray/Model.ps1','tray/MapModel.ps1','tray/Map.ps1','group/Protocol.ps1','group/Client.ps1','group-addon.json','SHA256SUMS.json','tray/ADDON-SHA256SUMS.json')
    $before=@{};$oldHashes=@{}
    foreach($relative in $files){
        $path=Join-Path $identity.Home $relative;$before[$relative]=Test-Path -LiteralPath $path
        $parent=Split-Path $path -Parent
        if(Test-Path -LiteralPath $parent){if((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected destination reparse point.'}}
        if($before[$relative]){$oldHashes[$relative]=(Get-FileHash -LiteralPath $path).Hash;if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected destination file reparse point.'};$dest=Join-Path $backup $relative;[void](New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force);Copy-Item -LiteralPath $path -Destination $dest}
    }
    $tray=Get-Content -LiteralPath "$($identity.Home)/Tray.ps1" -Raw
    if($tray -notmatch 'function Invoke-TrayExitSelection' -or $tray -notmatch 'Show-HybridExitMap'){throw 'This add-on needs tray 0.2.0/0.2.1 or friend 1.0.0. Install the existing tray first.'}
    $legacy="@('nyc1','lon1','fkt1','sgp1','syd1')"
    $tray=$tray.Replace($legacy,'@(Get-HybridExitAliases $script:stateDir)')
    $tray=$tray.Replace('$alias+$(if($saved)', '(Get-HybridExitName $alias $script:stateDir)+$(if($saved)')
    $needle='        $profile=Join-Path $script:stateDir "profiles/$Selected.json"'
    if($tray -notmatch 'Group exit has no approved profile'){
        if(-not $tray.Contains($needle)){throw 'Unrecognised tray selection handler; no code was changed.'}
        $tray=$tray.Replace($needle,$needle+"`n        if(`$Selected -like 'exit-*' -and -not (Test-Path -LiteralPath `$profile)){throw 'Group exit has no approved profile. Ask its owner to publish/sync the member list, then import the updated group.json.'}")
    }
    $tray=Add-HybridFlagsToTraySource $tray
    try{
        foreach($relative in @('tray/Model.ps1','tray/MapModel.ps1','tray/Map.ps1','group/Protocol.ps1','group/Client.ps1')){
            $dest=Join-Path $identity.Home $relative;[void](New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force);Copy-Item -LiteralPath (Join-Path $PSScriptRoot "payload/$relative") -Destination $dest -Force
        }
        [IO.File]::WriteAllText("$($identity.Home)/Tray.ps1",$tray,[Text.UTF8Encoding]::new($false))
        Write-GroupJson @{Schema=1;Version='1.0.1';Product='whispr-group-addon'} "$($identity.Home)/group-addon.json"
        $core=Read-GroupJson "$($identity.Home)/SHA256SUMS.json";$addon=Read-GroupJson "$($identity.Home)/tray/ADDON-SHA256SUMS.json"
        foreach($relative in @('Tray.ps1','tray/Model.ps1','tray/MapModel.ps1','tray/Map.ps1')){
            $hash=(Get-FileHash -LiteralPath (Join-Path $identity.Home $relative)).Hash
            $addon[$relative]=$hash;if($core.ContainsKey($relative)){$core[$relative]=$hash}
        }
        foreach($relative in @('group/Protocol.ps1','group/Client.ps1','group-addon.json')){$core[$relative]=(Get-FileHash -LiteralPath (Join-Path $identity.Home $relative)).Hash}
        Write-HybridJson $core "$($identity.Home)/SHA256SUMS.json";Write-HybridJson $addon "$($identity.Home)/tray/ADDON-SHA256SUMS.json"
        . "$($identity.Home)/tray/Model.ps1";Assert-TrayAddon $identity.Home;Assert-HybridManifest $identity.Home
        $installedHashes=@{};foreach($relative in $files){$installedHashes[$relative]=(Get-FileHash -LiteralPath (Join-Path $identity.Home $relative)).Hash}
        Write-GroupJson @{Schema=1;Files=$before;OldHashes=$oldHashes;InstalledHashes=$installedHashes} (Join-Path $backup 'restore.json')
    }catch{
        $failure=$_;foreach($relative in $files){$path=Join-Path $identity.Home $relative;if($before[$relative]){Copy-Item -LiteralPath (Join-Path $backup $relative) -Destination $path -Force}elseif(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}};throw $failure
    }
    Write-Host 'Group add-on installed. Transport, guard, private key, server setup, selected exit and sign-in setting retained.' -ForegroundColor Green
    Write-Host "Backup: $backup"
}finally{if($sessionMutex){$sessionMutex.ReleaseMutex();$sessionMutex.Dispose()};if($locked){$trayMutex.ReleaseMutex()};$trayMutex.Dispose()}
if(-not $NoLaunch -and (Test-Path -LiteralPath "$($identity.State)/peer.json")){& "$($identity.Home)/Open-Tray.ps1"}

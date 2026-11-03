#requires -Version 7.0
#requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$NoLaunch)
$ErrorActionPreference='Stop'
if(-not $IsWindows){throw 'Install this map fix in Windows PowerShell 7.'}
$installRoot=Join-Path $env:ProgramFiles 'whispr Hybrid VPN'
$stateRoot=Join-Path $env:ProgramData 'whispr-hybrid'
$source=Get-Content -LiteralPath "$PSScriptRoot/TRAY-SHA256SUMS.json" -Raw|ConvertFrom-Json -AsHashtable
$changes=@('Tray.ps1','tray/Map.ps1','tray/MapModel.ps1')
foreach($name in $changes){
    if(-not $source.ContainsKey($name) -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash -ne $source[$name]){throw "Map update checksum mismatch: $name"}
}
foreach($root in @($installRoot,$stateRoot)){
    $item=Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected root reparse point.'}
    if((Get-Acl -LiteralPath $root).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){throw 'Unrecognized installation ownership.'}
    if((Get-Content -LiteralPath (Join-Path $root 'install-owner.txt') -Raw).Trim() -ne 'whispr-hybrid-schema-1'){throw 'Installation marker does not match.'}
}
. "$installRoot/client/Common.ps1"
. "$installRoot/tray/Model.ps1"
Assert-HybridManifest $installRoot
Assert-TrayAddon $installRoot
if(-not (Test-Path -LiteralPath "$installRoot/core/Session.ps1")){throw 'Install tray 0.2.0 before applying this map update.'}
$mutex=[Threading.Mutex]::new($false,'Global\whisprHybridTray010');$locked=$false
try {
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Choose Close tray only — keep VPN running, then run this map update again.'}
    $manifestPath=Join-Path $installRoot 'tray/ADDON-SHA256SUMS.json'
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json -AsHashtable
    foreach($name in $changes){
        $path=Join-Path $installRoot $name
        if(-not $manifest.ContainsKey($name)){throw "Missing installed map file: $name"}
        foreach($part in @($path,(Split-Path $path -Parent))){if((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected map file/directory reparse point.'}}
    }
    $backup=Join-Path $stateRoot ('tray-backups/map-0.2.1-'+[guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $backup -Force)
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $backup 'ADDON-SHA256SUMS.json')
    foreach($name in $changes){$target=Join-Path $backup $name;[void](New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force);Copy-Item -LiteralPath (Join-Path $installRoot $name) -Destination $target}
    try {
        foreach($name in $changes){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $installRoot $name) -Force;$manifest[$name]=$source[$name]}
        Write-HybridJson $manifest $manifestPath
        Assert-TrayAddon $installRoot
        Assert-HybridManifest $installRoot
    }catch{
        $failure=$_
        foreach($name in $changes){Copy-Item -LiteralPath (Join-Path $backup $name) -Destination (Join-Path $installRoot $name) -Force}
        Copy-Item -LiteralPath (Join-Path $backup 'ADDON-SHA256SUMS.json') -Destination $manifestPath -Force
        throw $failure
    }
    Write-Host 'Map 0.2.1 installed: full-window world map, labelled Frankfurt and enlarged Europe inset.' -ForegroundColor Green
    Write-Host 'Current VPN session, server setup, keys, exit profile and auto-connect setting retained.'
    Write-Host "Map backup: $backup"
}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
if(-not $NoLaunch){& "$installRoot/Open-Tray.ps1"}

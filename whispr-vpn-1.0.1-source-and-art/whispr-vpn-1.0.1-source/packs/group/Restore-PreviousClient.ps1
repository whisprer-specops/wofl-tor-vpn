#requires -Version 7.2
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$Backup,[switch]$NoLaunch)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/group/Protocol.ps1";. "$PSScriptRoot/group/Local.ps1"
Assert-GroupPackage $PSScriptRoot;$identity=Get-GroupLocalIdentity
. "$($identity.Home)/client/Common.ps1";. "$($identity.Home)/tray/Model.ps1"
$trayMutex=[Threading.Mutex]::new($false,'Global\whisprHybridTray010');$locked=$false;$sessionMutex=$null
try{
    try{$locked=$trayMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Disconnect and close the tray first.'};$sessionMutex=Enter-TraySessionLock;Assert-TrayDisconnected $identity.Home
    $active=Read-GroupJson "$($identity.State)/peer.json"
    if($active.ssh_alias -notin @('nyc1','lon1','fkt1','sgp1','syd1')){throw 'Select an original five-location exit while disconnected, then close the tray before restoring the older client.'}
    $parent=Join-Path $identity.State 'group-backups'
    if(-not $Backup){$entry=Get-ChildItem -LiteralPath $parent -Directory -Filter 'install-*'|Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'restore.json')}|Sort-Object CreationTimeUtc -Descending|Select-Object -First 1;if(-not $entry){throw 'No completed group-install backup exists.'};$Backup=$entry.FullName}
    $Backup=[IO.Path]::GetFullPath($Backup)
    if((Split-Path $Backup -Parent) -ne $parent -or (Get-Item -LiteralPath $Backup -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Use a normal group-install backup under this installation private state folder.'}
    $meta=Read-GroupJson (Join-Path $Backup 'restore.json')
    $allowed=@('Tray.ps1','tray/Model.ps1','tray/MapModel.ps1','tray/Map.ps1','group/Protocol.ps1','group/Client.ps1','group-addon.json','SHA256SUMS.json','tray/ADDON-SHA256SUMS.json')
    if($meta.Schema -ne 1 -or $meta.Files.Count -ne $allowed.Count){throw 'Unexpected backup manifest.'}
    foreach($relative in $meta.Files.Keys){
        if($relative -notin $allowed -or (Get-FileHash -LiteralPath (Join-Path $identity.Home $relative)).Hash -ne $meta.InstalledHashes[$relative]){throw "Files changed since this backup ($relative); restore refused to avoid overwriting a later update."}
    }
    foreach($relative in $allowed){if($meta.Files[$relative]){if((Get-FileHash -LiteralPath (Join-Path $Backup $relative)).Hash -ne $meta.OldHashes[$relative]){throw 'Backup integrity failed; no files restored.'}}}
    foreach($relative in $allowed){$dest=Join-Path $identity.Home $relative;if($meta.Files[$relative]){Copy-Item -LiteralPath (Join-Path $Backup $relative) -Destination $dest -Force}else{Remove-Item -LiteralPath $dest -Force}}
    Assert-HybridManifest $identity.Home
    Write-Host 'Previous client UI restored. Keys, profiles, catalogue, server peers and sign-in setting retained.' -ForegroundColor Green
}finally{if($sessionMutex){$sessionMutex.ReleaseMutex();$sessionMutex.Dispose()};if($locked){$trayMutex.ReleaseMutex()};$trayMutex.Dispose()}
if(-not $NoLaunch){& "$($identity.Home)/Open-Tray.ps1"}

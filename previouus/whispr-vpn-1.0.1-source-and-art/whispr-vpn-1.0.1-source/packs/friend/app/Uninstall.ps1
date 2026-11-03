#requires -Version 7.2
#requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$DeleteLocalKeys)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/client/Common.ps1";. "$PSScriptRoot/friend/Protocol.ps1";. "$PSScriptRoot/friend/Local.ps1"
$homeDir=Get-HybridHome;$stateDir=Get-HybridState
if($PSScriptRoot -ne $homeDir){throw 'Use the installed friend Uninstall.ps1.'}
Assert-FriendInstallation $homeDir $stateDir
$mutex=[Threading.Mutex]::new($false,'Global\whisprHybridTray010');$locked=$false
try{
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Disconnect and close the tray before uninstalling.'}
    foreach($root in @($homeDir,$stateDir)){if(@(Get-ChildItem -LiteralPath $root -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Unexpected child reparse point; refusing uninstall.'}}
    & "$homeDir/Recover.ps1"
    $status=(& "$homeDir/bin/whispr-vpn-guard.exe" status|Out-String).Trim()
    if($LASTEXITCODE -ne 0 -or $status -ne 'DISARMED'){throw 'Recovery was not confirmed. Files retained.'}
    . "$homeDir/background/Scheduler.ps1";. "$homeDir/background/Autostart.ps1"
    Remove-HybridAutoConnect $homeDir;Remove-HybridDemandTask $homeDir
    $shortcut=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'whispr Hybrid VPN Tray.lnk'
    if(Test-Path -LiteralPath $shortcut){$shell=New-Object -ComObject WScript.Shell;try{$link=$shell.CreateShortcut($shortcut);if($link.Arguments -like "*$homeDir*Open-Tray.ps1*"){Remove-Item -LiteralPath $shortcut -Force}}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}}
    Remove-Item -LiteralPath $homeDir -Recurse -Force
    if($DeleteLocalKeys){Remove-Item -LiteralPath $stateDir -Recurse -Force}
    Write-Host 'Friend client removed. Ask the owner to revoke this device on the VPS exits as well.'
}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}

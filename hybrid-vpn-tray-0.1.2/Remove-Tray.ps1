#requires -Version 7.0
#requires -RunAsAdministrator
$ErrorActionPreference='Stop'
. "$PSScriptRoot/client/Common.ps1"
$installRoot=Get-HybridHome
if($PSScriptRoot -ne $installRoot){throw 'Use the installed Remove-Tray.ps1.'}
$mutex=[Threading.Mutex]::new($false,'Global\whisprHybridTray010');$locked=$false
try {
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Use Close tray only — keep VPN running, then retry. Do not disconnect merely to remove this add-on.'}
    Assert-HybridManifest $installRoot
    if($IsWindows -and (Test-Path -LiteralPath "$installRoot/background/Scheduler.ps1")){. "$installRoot/background/Scheduler.ps1";Remove-HybridDemandTask $installRoot}
    $path=Join-Path $installRoot 'tray/ADDON-SHA256SUMS.json'
    $manifest=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    $files=@('Open-Tray.ps1','Tray.ps1','Prepare-Exit.ps1','Remove-Tray.ps1','Start-Background.ps1','tray/Model.ps1','tray/README.md','background/DetachedLauncher.cs','background/SessionHost.cs','background/Host.ps1','background/Launch.ps1','background/Scheduler.ps1','background/Scheduled-Host.ps1')
    $backup=Join-Path (Get-HybridState) ('tray-backups/remove-'+[guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $backup -Force)
    Copy-Item -LiteralPath $path -Destination (Join-Path $backup 'ADDON-SHA256SUMS.json')
    $files=@($files | Where-Object {$manifest.ContainsKey($_)})
    foreach($relative in $files){
        $destination=Join-Path $backup $relative
        [void](New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force)
        Copy-Item -LiteralPath (Join-Path $installRoot $relative) -Destination $destination
    }
    # No core manifest is changed. The independent console client remains usable throughout.
    foreach($relative in $files){Remove-Item -LiteralPath (Join-Path $installRoot $relative) -Force}
    Remove-Item -LiteralPath $path -Force
    $shortcut=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'whispr Hybrid VPN Tray.lnk'
    if(Test-Path -LiteralPath $shortcut){
        $shell=New-Object -ComObject WScript.Shell
        try {$link=$shell.CreateShortcut($shortcut);if($link.Arguments -like "*$(Join-Path $installRoot 'Open-Tray.ps1')*"){Remove-Item -LiteralPath $shortcut -Force}}
        finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
    }
    Write-Host 'Tray removed. Existing VPN session/core, keys and selected exit retained.' -ForegroundColor Green
}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}

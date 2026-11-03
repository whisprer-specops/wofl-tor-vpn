#requires -Version 7.0
#requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$NoLaunch)
$ErrorActionPreference='Stop'
if(-not $IsWindows){throw 'Install this add-on in Windows PowerShell 7.'}
$installRoot=Join-Path $env:ProgramFiles 'whispr Hybrid VPN'
$stateRoot=Join-Path $env:ProgramData 'whispr-hybrid'
$manifestPath=Join-Path $installRoot 'SHA256SUMS.json'
$source=Get-Content -LiteralPath "$PSScriptRoot/TRAY-SHA256SUMS.json" -Raw | ConvertFrom-Json -AsHashtable
$expected=Get-Content -LiteralPath "$PSScriptRoot/BASE-FIX5.json" -Raw | ConvertFrom-Json -AsHashtable
foreach($relative in $source.Keys){
    if($relative -match '(^/|^[A-Za-z]:|(^|[/\\])[.][.]([/\\]|$))'){throw 'Invalid add-on file path.'}
    if((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $relative) -Algorithm SHA256).Hash -ne $source[$relative]){throw "Add-on file hash mismatch: $relative"}
}
foreach($root in @($installRoot,$stateRoot)){
    $item=Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected root reparse point.'}
    if((Get-Acl -LiteralPath $root).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){throw 'Unrecognized installation ownership.'}
    if((Get-Content -LiteralPath (Join-Path $root 'install-owner.txt') -Raw).Trim() -ne 'whispr-hybrid-schema-1'){throw 'Installation marker does not match.'}
}
foreach($relative in $expected.Keys){
    if((Get-FileHash -LiteralPath (Join-Path $installRoot $relative) -Algorithm SHA256).Hash -ne $expected[$relative]){throw "This add-on requires the working fix5 base. Mismatch: $relative"}
}
. "$installRoot/client/Common.ps1"
Assert-HybridManifest $installRoot
$mutex=[Threading.Mutex]::new($false,'Global\whisprHybridTray010');$locked=$false
try {
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Close the existing tray only before reinstalling this add-on. The VPN may stay running.'}
    Write-Host 'Checking scheduler-owned background process creation (no VPN changes)...'
    & "$PSScriptRoot/tests/Test-Windows-Scheduled.ps1" -StateRoot $stateRoot
    $addon=@('Open-Tray.ps1','Tray.ps1','Prepare-Exit.ps1','Remove-Tray.ps1','Start-Background.ps1','tray/Model.ps1','tray/README.md','background/DetachedLauncher.cs','background/SessionHost.cs','background/Host.ps1','background/Launch.ps1','background/Scheduler.ps1','background/Scheduled-Host.ps1')
    $addonManifest=Join-Path $installRoot 'tray/ADDON-SHA256SUMS.json'
    $installedAddon=if(Test-Path -LiteralPath $addonManifest){Get-Content -LiteralPath $addonManifest -Raw|ConvertFrom-Json -AsHashtable}else{@{}}
    foreach($relative in $installedAddon.Keys){
        if($relative -notin $addon){throw 'Unrecognized add-on manifest entry.'}
        if((Get-FileHash -LiteralPath (Join-Path $installRoot $relative) -Algorithm SHA256).Hash -ne $installedAddon[$relative]){throw "Existing add-on hash mismatch: $relative"}
    }
    # Every write is confined to new add-on paths. Working fix5 source/binaries are read-only here.
    foreach($relative in $addon){
        if($expected.ContainsKey($relative)){throw 'Add-on attempted to overwrite the working core.'}
        $destination=Join-Path $installRoot $relative
        if((Test-Path -LiteralPath $destination) -and -not $installedAddon.ContainsKey($relative)){throw "Unrecognized existing file: $relative"}
        $parent=Split-Path -Parent $destination
        if(Test-Path -LiteralPath $parent){if((Get-Item -LiteralPath $parent).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected destination reparse point.'}}
        if(Test-Path -LiteralPath $destination){if((Get-Item -LiteralPath $destination).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected file reparse point.'}}
    }
    $backup=Join-Path $stateRoot ('tray-backups/'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'-'+[guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $backup -Force)
    if(Test-Path -LiteralPath $addonManifest){Copy-Item -LiteralPath $addonManifest -Destination (Join-Path $backup 'ADDON-SHA256SUMS.json')}
    $existing=@{}
    foreach($relative in $addon){
        $destination=Join-Path $installRoot $relative
        $existing[$relative]=Test-Path -LiteralPath $destination
        if($existing[$relative]){
            $copy=Join-Path $backup $relative;[void](New-Item -ItemType Directory -Path (Split-Path $copy -Parent) -Force)
            Copy-Item -LiteralPath $destination -Destination $copy
        }
    }
    $shortcut=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'whispr Hybrid VPN Tray.lnk'
    if(Test-Path -LiteralPath $shortcut){Copy-Item -LiteralPath $shortcut -Destination (Join-Path $backup 'shortcut.lnk')}
    try {
        foreach($relative in $addon){
            $destination=Join-Path $installRoot $relative
            [void](New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force)
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $relative) -Destination $destination -Force
            $installedAddon[$relative]=$source[$relative]
        }
        Write-HybridJson $installedAddon $addonManifest
        foreach($relative in $installedAddon.Keys){if((Get-FileHash -LiteralPath (Join-Path $installRoot $relative) -Algorithm SHA256).Hash -ne $installedAddon[$relative]){throw "Installed add-on checksum mismatch: $relative"}}
        Assert-HybridManifest $installRoot
        $shell=New-Object -ComObject WScript.Shell
        try {
            $link=$shell.CreateShortcut($shortcut)
            $link.TargetPath=Join-Path $PSHOME 'pwsh.exe'
            $link.Arguments='-NoLogo -NoProfile -WindowStyle Hidden -File "'+(Join-Path $installRoot 'Open-Tray.ps1')+'"'
            $link.WorkingDirectory=$installRoot;$link.Description='whispr Hybrid VPN — tray controls (UAC required)'
            $link.IconLocation=(Join-Path $env:SystemRoot 'System32/shell32.dll')+',13'
            $link.Save()
        } finally {if($shell){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}}
    }catch{
        $failure=$_
        foreach($relative in $addon){
            $destination=Join-Path $installRoot $relative
            if($existing[$relative]){Copy-Item -LiteralPath (Join-Path $backup $relative) -Destination $destination -Force}
            elseif(Test-Path -LiteralPath $destination){Remove-Item -LiteralPath $destination -Force}
        }
        if(Test-Path -LiteralPath (Join-Path $backup 'ADDON-SHA256SUMS.json')){Copy-Item -LiteralPath (Join-Path $backup 'ADDON-SHA256SUMS.json') -Destination $addonManifest -Force}
        elseif(Test-Path -LiteralPath $addonManifest){Remove-Item -LiteralPath $addonManifest -Force}
        if(Test-Path -LiteralPath (Join-Path $backup 'shortcut.lnk')){Copy-Item -LiteralPath (Join-Path $backup 'shortcut.lnk') -Destination $shortcut -Force}
        elseif(Test-Path -LiteralPath $shortcut){Remove-Item -LiteralPath $shortcut -Force}
        throw $failure
    }
    Write-Host 'Tray add-on installed. Working tunnel scripts/binaries, current session, keys and active exit were not changed.' -ForegroundColor Green
    Write-Host "Add-on backup: $backup"
    Write-Host 'Start menu: whispr Hybrid VPN Tray. Tray icons may be in the ^ overflow.'
} finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
if(-not $NoLaunch){& "$installRoot/Open-Tray.ps1"}

#requires -Version 7.0
function Start-HybridBackground {
    [CmdletBinding()]
    param([string]$InstallRoot,[string]$StateRoot)
    Assert-HybridManifest $InstallRoot
    Assert-TrayAddon $InstallRoot
    Assert-TrayDisconnected $InstallRoot
    # Do not hold the session mutex while spawning; the original Session.ps1 must acquire it.
    $mutex=Enter-TraySessionLock
    try {Assert-TrayDisconnected $InstallRoot}finally{$mutex.ReleaseMutex();$mutex.Dispose()}
    if(-not ('HybridDetachedLauncher' -as [type])){Add-Type -Path (Join-Path $InstallRoot 'background/DetachedLauncher.cs')}
    $id=[guid]::NewGuid().ToString('N')
    $prefix=Join-Path $StateRoot "background-$id-host"
    $process=[HybridDetachedLauncher]::Start((Join-Path $PSHOME 'pwsh.exe'),[string[]]@('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $InstallRoot 'background/Host.ps1'),'-LaunchId',$id),$InstallRoot,$prefix)
    try{Write-HybridJson @{Schema=1;HostPid=$process.Id;HostStartedTicks=$process.StartTime.ToUniversalTime().Ticks;HostLogPrefix=$prefix;LaunchId=$id;StartedUtc=[DateTime]::UtcNow.ToString('o')} (Join-Path $StateRoot 'background-launch.json')}catch{Write-Warning 'Could not save background launch metadata; inspect background-*-host logs if startup fails.'}
    return $process
}

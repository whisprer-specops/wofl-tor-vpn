#requires -Version 7.0
#requires -RunAsAdministrator
$ErrorActionPreference='Stop'
. "$PSScriptRoot\client\Common.ps1"
Assert-HybridManifest $PSScriptRoot
$installRoot=Get-HybridHome;$stateRoot=Get-HybridState
if(-not (Test-Path -LiteralPath (Join-Path $installRoot 'SHA256SUMS.json'))){throw 'Existing installation missing. This updater requires the successful fix3 installation.'}
if([IO.Path]::GetFullPath($installRoot) -eq [IO.Path]::GetFullPath($PSScriptRoot)){throw 'Run this updater from the extracted download folder.'}
$mutex=[Threading.Mutex]::new($false,'Global\whisprHybridVpn040');$locked=$false
try {
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'A VPN session is still active. Stop it or run the installed Recover.ps1 first.'}
    $guard=Join-Path $installRoot 'bin\whispr-vpn-guard.exe'
    $status=(& $guard status | Out-String).Trim()
    if($LASTEXITCODE -ne 0 -or $status -ne 'DISARMED'){throw 'Protection is still armed. Run the installed Recover.ps1 before updating.'}
    if(Get-NetAdapter -Name 'whispr-hybrid' -ErrorAction SilentlyContinue){throw 'Owned TUN still present. Run Recover.ps1 first.'}
    Assert-HybridManifest $installRoot
    $source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'SHA256SUMS.json') -Raw | ConvertFrom-Json -AsHashtable
    $manifestPath=Join-Path $installRoot 'SHA256SUMS.json'
    $installed=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    # Unchanged core files identify the expected fix3/fix4 base.
    foreach($base in @('client/Common.ps1','Recover.ps1','bin/whispr-vpn-guard.exe')){
        if($installed[$base] -ne $source[$base]){throw "Different installed base: $base. No update applied."}
    }
    $files=@('client/Session.ps1','client/Verify-Tcp.ps1')
    $backup=Join-Path $stateRoot ('updates\tcp-fix4-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $existed=@{}
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $backup 'SHA256SUMS.json')
    foreach($relative in $files){
        $destination=Join-Path $installRoot $relative
        $existed[$relative]=Test-Path -LiteralPath $destination
        if($existed[$relative]){Copy-Item -LiteralPath $destination -Destination (Join-Path $backup ([IO.Path]::GetFileName($relative)))}
    }
    try {
        foreach($relative in $files){
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $relative) -Destination (Join-Path $installRoot $relative) -Force
            $installed[$relative]=$source[$relative]
        }
        Write-HybridJson $installed $manifestPath
        Assert-HybridManifest $installRoot
    } catch {
        $failure=$_
        foreach($relative in $files){
            $destination=Join-Path $installRoot $relative
            if($existed[$relative]){Copy-Item -LiteralPath (Join-Path $backup ([IO.Path]::GetFileName($relative))) -Destination $destination -Force}
            elseif(Test-Path -LiteralPath $destination){Remove-Item -LiteralPath $destination -Force}
        }
        Copy-Item -LiteralPath (Join-Path $backup 'SHA256SUMS.json') -Destination $manifestPath -Force
        throw $failure
    }
    Write-Host 'Client HTTPS verifier updated and file hashes checked. Server, keys and transport binaries retained.' -ForegroundColor Green
    Write-Host "Backup: $backup"
    Write-Host "Start the session: & '$installRoot\Start.ps1'"
} finally {
    if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()
}

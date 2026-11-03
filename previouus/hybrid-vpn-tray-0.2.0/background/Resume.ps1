#requires -Version 7.0
# This helper never disarms protection. It is checked by the core runtime manifest.
function Test-HybridRecordedOwner {
    param([hashtable]$Session)
    $p=$null
    try{
        if(-not $Session){return $false}
        $p=Get-Process -Id ([int]$Session.OwnerPid) -ErrorAction Stop
        return (-not $p.HasExited -and $p.StartTime.ToUniversalTime().Ticks -eq [long]$Session.OwnerStartedTicks -and $p.Path -eq $Session.OwnerPath)
    }catch{return $false}finally{if($p){$p.Dispose()}}
}
function New-HybridResumeBinding {
    param([hashtable]$Peer,[string]$PublicKey,[hashtable]$Session,[string]$InstallRoot)
    $manifest=Get-Content -LiteralPath (Join-Path $InstallRoot 'SHA256SUMS.json') -Raw|ConvertFrom-Json -AsHashtable
    return @{
        Schema=1;OwnerPid=$Session.OwnerPid;OwnerStartedTicks=$Session.OwnerStartedTicks
        Home=[IO.Path]::GetFullPath($InstallRoot);Endpoint=$Peer.endpoint;Port=[int]$Peer.port
        ServerKey=$Peer.server_public_key;ClientKey=$PublicKey
        EngineSha=$manifest['bin/sing-box.exe'];TorSha=$manifest['bin/tor/tor.exe'];GuardSha=$manifest['bin/whispr-vpn-guard.exe']
    }
}
function Assert-HybridBinding {
    param([hashtable]$Binding,[hashtable]$Previous,[hashtable]$Peer,[string]$PublicKey,[string]$InstallRoot)
    if(-not $Binding -or -not $Previous -or $Binding.Schema -ne 1){throw 'No owned protection binding is recorded. Use Recover.ps1 explicitly before reconnecting.'}
    $expected=New-HybridResumeBinding $Peer $PublicKey $Previous $InstallRoot
    foreach($field in $expected.Keys){
        if(-not $Binding.ContainsKey($field) -or -not $expected[$field] -or $Binding[$field] -ne $expected[$field]){throw "Protection binding differs ($field). Protection retained; explicit recovery is required."}
    }
}
function Assert-HybridResume {
    param([hashtable]$Peer,[string]$PublicKey,[string]$InstallRoot,[string]$StateRoot)
    $previous=Get-Content -LiteralPath (Join-Path $StateRoot 'session.json') -Raw|ConvertFrom-Json -AsHashtable
    if(Test-HybridRecordedOwner $previous){throw 'The recorded session is still running; automatic resume will not stop it.'}
    $binding=Get-Content -LiteralPath (Join-Path $StateRoot 'resume-binding.json') -Raw|ConvertFrom-Json -AsHashtable
    Assert-HybridBinding $binding $previous $Peer $PublicKey $InstallRoot
    return $previous
}
function Remove-HybridDeadTunnel {
    param([hashtable]$Previous)
    if(Test-HybridRecordedOwner $Previous){throw 'Cannot remove a tunnel belonging to a live session.'}
    $adapter=Get-NetAdapter -Name 'whispr-hybrid' -IncludeHidden -ErrorAction SilentlyContinue
    if(-not $adapter){return}
    if(-not $Previous.TunnelGuid -or [string]$adapter.InterfaceGuid -ne $Previous.TunnelGuid){throw 'Stale TUN ownership is not established. Protection retained.'}
    $guid=([string]$adapter.InterfaceGuid).Trim('{}')
    $device=@(Get-CimInstance Win32_NetworkAdapter | Where-Object {$_.GUID -and ([string]$_.GUID).Trim('{}') -eq $guid})
    if($device.Count -ne 1 -or -not $device[0].PNPDeviceID){throw 'Cannot map the old owned TUN to one device. Protection retained.'}
    Invoke-HybridChecked (Join-Path $env:SystemRoot 'System32/pnputil.exe') @('/remove-device',[string]$device[0].PNPDeviceID)
    Start-Sleep -Milliseconds 500
    if(Get-NetAdapter -Name 'whispr-hybrid' -IncludeHidden -ErrorAction SilentlyContinue){throw 'Old owned TUN remains. Protection retained.'}
}
function Save-HybridLiveResumeBinding {
    param([string]$InstallRoot,[string]$StateRoot)
    $guard=(& (Join-Path $InstallRoot 'bin/whispr-vpn-guard.exe') status|Out-String).Trim()
    if($LASTEXITCODE -ne 0 -or $guard -notin @('ARMED','DISARMED')){throw 'Cannot establish guard state for auto-connect.'}
    if($guard -eq 'DISARMED'){return}
    $session=Get-Content -LiteralPath (Join-Path $StateRoot 'session.json') -Raw|ConvertFrom-Json -AsHashtable
    $peer=Get-Content -LiteralPath (Join-Path $StateRoot 'peer.json') -Raw|ConvertFrom-Json -AsHashtable
    $key=Get-Content -LiteralPath (Join-Path $StateRoot 'device-key.json') -Raw|ConvertFrom-Json -AsHashtable
    if(-not (Test-HybridRecordedOwner $session)){throw 'Protection is armed without a live session. Recover explicitly once before enabling auto-connect.'}
    if($session.State -ne 'verified-session' -or $session.UdpExit -ne $peer.endpoint){throw 'Wait for a verified current session before enabling auto-connect, or disconnect normally first.'}
    $details=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$session.OwnerPid)"
    if(([string]$details.CommandLine).Replace('/','\') -notlike "*$InstallRoot\client\Session.ps1*"){throw 'Current supervisor identity is not recognized.'}
    try{
        $config=Get-Content -LiteralPath (Join-Path $StateRoot 'engine.json') -Raw|ConvertFrom-Json -AsHashtable
        $wg=@($config.endpoints|Where-Object tag -eq 'udp-exit')
        if($wg.Count -ne 1 -or $wg[0].peers.Count -ne 1){throw 'Endpoint shape mismatch.'}
        $p=$wg[0].peers[0]
        if($p.address -ne $peer.endpoint -or $p.port -ne $peer.port -or $p.public_key -ne $peer.server_public_key){throw 'Endpoint binding mismatch.'}
    }catch{throw 'Cannot validate the current transport binding. Active VPN was not changed.'}
    Write-HybridJson (New-HybridResumeBinding $peer $key.PublicKey $session $InstallRoot) (Join-Path $StateRoot 'resume-binding.json')
}

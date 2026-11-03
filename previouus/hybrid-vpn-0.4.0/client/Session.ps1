#requires -Version 7.0
#requires -RunAsAdministrator
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Verify-Udp.ps1"
$homeDir=Get-HybridHome;$stateDir=Get-HybridState
$guard=Join-Path $homeDir 'bin\whispr-vpn-guard.exe'
$engine=Join-Path $homeDir 'bin\sing-box.exe'
$torExe=Join-Path $homeDir 'bin\tor\tor.exe'
$mutex=[Threading.Mutex]::new($false,'Global\whisprHybridVpn040')
$locked=$false;$job=$null;$armed=$false;$normalStop=$false;$session=$null
try {
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Another Hybrid VPN session is already active.'}
    Assert-HybridBaseline
    Assert-HybridManifest $homeDir
    $guardStatus=(& $guard status | Out-String).Trim()
    if($LASTEXITCODE -ne 0 -or $guardStatus -ne 'DISARMED'){throw 'Existing protection/recovery is pending. Run Recover.ps1 first.'}
    if(Get-NetAdapter -Name 'whispr-hybrid' -ErrorAction SilentlyContinue){throw 'The TUN name already exists. Recover the prior owned session before retrying.'}
    if(@(Get-NetIPAddress -ErrorAction Stop | Where-Object {$_.IPAddress -like '172.31.249.*' -or $_.IPAddress -like 'fd89:77:71:*'}).Count){throw 'The dedicated TUN subnet conflicts with an existing local address.'}
    $peer=Get-Content -LiteralPath (Join-Path $stateDir 'peer.json') -Raw | ConvertFrom-Json -AsHashtable
    $key=Get-Content -LiteralPath (Join-Path $stateDir 'device-key.json') -Raw | ConvertFrom-Json -AsHashtable
    $existing=Get-HybridExistingWireGuard
    $cfg=Get-HybridConfig -Peer $peer -PrivateKey $key.PrivateKey -TorPath $torExe -Exceptions $existing.Exceptions -WireGuardPath $existing.Path
    $configPath=Join-Path $stateDir 'engine.json'
    Write-HybridJson $cfg $configPath
    Invoke-HybridChecked $engine @('check','-c',$configPath)
    Add-Type -Path "$homeDir\client\ProcessJob.cs"
    $job=[HybridProcessJob]::new()
    $session=@{Schema=1;OwnerPid=$PID;OwnerStartedTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks;OwnerPath=(Get-Process -Id $PID).Path;Home=$homeDir;TunnelGuid=$null;State='preparing';StartedUtc=[DateTime]::UtcNow.ToString('o')}
    Write-HybridJson $session (Join-Path $stateDir 'session.json')
    $wgPath=if($existing.Path){$existing.Path}else{'-'}
    Invoke-HybridChecked $guard @('arm',$engine,$torExe,$peer.endpoint,[string]$peer.port,$wgPath)
    $armed=$true
    $session.State='armed-bootstrap';Write-HybridJson $session (Join-Path $stateDir 'session.json')
    $torData=Join-Path $stateDir 'tor-data';New-Item -ItemType Directory -Path $torData -Force | Out-Null
    $torrc=@"
ClientOnly 1
SocksPort 127.0.0.1:19050 IsolateSOCKSAuth
SocksPolicy accept 127.0.0.1
SocksPolicy reject *
SafeSocks 0
ClientUseIPv6 0
AvoidDiskWrites 1
DataDirectory "$($torData.Replace('\','/'))"
GeoIPFile "$($homeDir.Replace('\','/'))/bin/tor/data/geoip"
GeoIPv6File "$($homeDir.Replace('\','/'))/bin/tor/data/geoip6"
Log notice stdout
"@
    $torrcPath=Join-Path $stateDir 'torrc'
    $torrc | Set-Content -LiteralPath $torrcPath -Encoding utf8NoBOM
    $tor=$job.Start($torExe,[string[]]@('-f',$torrcPath),$stateDir,(Join-Path $stateDir 'tor'))
    $deadline=[DateTime]::UtcNow.AddSeconds(180);$next=[DateTime]::MinValue
    while([DateTime]::UtcNow -lt $deadline){
        if($tor.HasExited){throw 'Tor exited; read tor-stderr.log and tor-stdout.log.'}
        $log=Get-Content -LiteralPath (Join-Path $stateDir 'tor-stdout.log') -Tail 35 -ErrorAction SilentlyContinue
        if(($log -join "`n") -match 'Bootstrapped 100%'){break}
        if([DateTime]::UtcNow -ge $next){Write-Host 'Tor bootstrap in progress; protection is armed.';$next=[DateTime]::UtcNow.AddSeconds(10)}
        Start-Sleep -Milliseconds 500
    }
    if([DateTime]::UtcNow -ge $deadline){throw 'Tor bootstrap exceeded 180 seconds. Protection retained.'}
    $router=$job.Start($engine,[string[]]@('run','-c',$configPath),$stateDir,(Join-Path $stateDir 'engine'))
    $deadline=[DateTime]::UtcNow.AddSeconds(20);$adapter=$null
    while([DateTime]::UtcNow -lt $deadline){
        if($router.HasExited){throw 'Routing engine exited; read engine-stderr.log.'}
        $adapter=Get-NetAdapter -Name 'whispr-hybrid' -ErrorAction SilentlyContinue
        if($adapter -and $adapter.Status -eq 'Up'){break}
        Start-Sleep -Milliseconds 250
    }
    if(-not $adapter -or $adapter.Status -ne 'Up'){throw 'Owned TUN adapter failed to become ready.'}
    $session.TunnelGuid=[string]$adapter.InterfaceGuid
    Write-HybridJson $session (Join-Path $stateDir 'session.json')
    Invoke-HybridChecked $guard @('allow-tunnel',$session.TunnelGuid)
    $readyDeadline=[DateTime]::UtcNow.AddSeconds(10)
    $ready=$false
    while([DateTime]::UtcNow -lt $readyDeadline){
        $probe=[Net.Sockets.TcpClient]::new()
        try{
            $task=$probe.ConnectAsync('127.0.0.1',17880)
            if($task.Wait(500)){[void]$task.GetAwaiter().GetResult();$ready=$true;break}
        }catch{}finally{$probe.Dispose()}
        if($router.HasExited){throw 'Routing engine exited before its local listener was ready.'}
        Start-Sleep -Milliseconds 150
    }
    if(-not $ready){throw 'Local verification listener did not become ready.'}
    Write-Host 'Checking TCP through Tor and actual UDP exit address...' -ForegroundColor Cyan
    $curl=Join-Path $env:SystemRoot 'System32\curl.exe'
    $torCheck=(& $curl --silent --show-error --fail --max-time 60 --socks5-hostname 127.0.0.1:17880 https://check.torproject.org/api/ip | Out-String)
    if($LASTEXITCODE -ne 0){throw 'Tor HTTPS verification failed.'}
    $tcpResult=$torCheck | ConvertFrom-Json
    if(-not $tcpResult.IsTor){throw 'TCP verification did not report a Tor exit.'}
    $udpResult=Test-HybridUdp -ExpectedAddress $peer.endpoint
    $session.State='verified-session';$session.TcpExit=$tcpResult.IP;$session.UdpExit=$udpResult.ObservedAddress;$session.LastVerifiedUtc=[DateTime]::UtcNow.ToString('o')
    Write-HybridJson $session (Join-Path $stateDir 'session.json')
    Write-Host "TCP verified through Tor ($($tcpResult.IP)); UDP verified through $($peer.ssh_alias) ($($udpResult.ObservedAddress))." -ForegroundColor Green
    Write-Host 'LAN/private-network exceptions remain direct. Windows crash/leak testing is still required.' -ForegroundColor Yellow
    Write-Host 'Type stop then Enter to disconnect. Closing/killing this window retains protection until Recover.ps1.'
    # A managed Console.ReadLine task avoids PowerShell callbacks on a thread without a runspace.
    Add-Type -TypeDefinition 'public static class HybridConsole { public static System.Threading.Tasks.Task<string> Read() { return System.Threading.Tasks.Task.Run(() => System.Console.ReadLine()); } }'
    $inputTask=[HybridConsole]::Read()
    $nextVerify=[DateTime]::UtcNow.AddSeconds(60)
    while($true){
        if($tor.HasExited -or $router.HasExited){throw 'A transport exited. Session stopped; protection retained.'}
        $current=Get-NetAdapter -Name 'whispr-hybrid' -ErrorAction SilentlyContinue
        if(-not $current -or [string]$current.InterfaceGuid -ne $session.TunnelGuid -or $current.Status -ne 'Up'){throw 'Owned TUN identity changed or disconnected. Protection retained.'}
        if($inputTask.IsCompleted){
            $line=$inputTask.GetAwaiter().GetResult()
            if($null -eq $line){throw 'Session console closed. Protection retained.'}
            if($line.Trim() -eq 'stop'){$normalStop=$true;break}
            Write-Host 'Type stop to disconnect.';$inputTask=[HybridConsole]::Read()
        }
        if([DateTime]::UtcNow -ge $nextVerify){
            $verification=Test-HybridUdp -ExpectedAddress $peer.endpoint
            $tcpAgain=(& $curl --silent --show-error --fail --max-time 30 --socks5-hostname 127.0.0.1:17880 https://check.torproject.org/api/ip | Out-String)
            if($LASTEXITCODE -ne 0){throw 'Periodic TCP/Tor verification failed. Protection retained.'}
            $currentTcp=$tcpAgain | ConvertFrom-Json
            if(-not $currentTcp.IsTor){throw 'Periodic TCP/Tor verification did not report a Tor exit. Protection retained.'}
            $session.TcpExit=$currentTcp.IP
            $session.LastVerifiedUtc=[DateTime]::UtcNow.ToString('o')
            Write-HybridJson $session (Join-Path $stateDir 'session.json')
            $nextVerify=[DateTime]::UtcNow.AddSeconds(60)
        }
        Start-Sleep -Seconds 2
    }
} catch {
    $failure=$_.Exception.Message
    if($session){
        $session.State=if($armed){'failed-protection-retained'}else{'failed-before-arm'}
        $session.Failure=$failure;$session.FailedUtc=[DateTime]::UtcNow.ToString('o')
        try{Write-HybridJson $session (Join-Path $stateDir 'session.json')}catch{Write-Warning 'Could not persist failure status; use guard status and current process state.'}
    }
    Write-Error -Message $failure -ErrorAction Continue
    if($armed){Write-Host "Protection remains armed. Recover: & '$homeDir\Recover.ps1'" -ForegroundColor Yellow}
    exit 1
} finally {
    if($job){$job.Dispose()}
    if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()
    if($normalStop){& "$homeDir\Recover.ps1" -OwnerAlreadyStopped}
}

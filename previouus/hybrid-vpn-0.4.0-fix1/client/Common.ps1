# PowerShell 7 shared functions. No actions run merely by loading this file.
Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
function Get-HybridHome { Join-Path $env:ProgramFiles 'whispr Hybrid VPN' }
function Get-HybridState { Join-Path $env:ProgramData 'whispr-hybrid' }
function Invoke-HybridChecked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable exited $LASTEXITCODE" }
}
function Write-HybridJson($Value,[string]$Path) {
    $temp=$Path+'.tmp'
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temp -Encoding utf8NoBOM
    Move-Item -LiteralPath $temp -Destination $Path -Force
}
function Get-HybridProtonRouteConflicts {
    param([object[]]$Adapters,[object[]]$Routes)
    $indexes=@($Adapters | ForEach-Object { [int]$_.ifIndex })
    $internet=@('0.0.0.0/0','0.0.0.0/1','128.0.0.0/1','::/0','::/1','8000::/1')
    $Routes | Where-Object { [int]$_.InterfaceIndex -in $indexes -and $_.DestinationPrefix -in $internet }
}
function Assert-HybridBaseline {
    if (-not $IsWindows -or -not [Environment]::Is64BitProcess) { throw 'Requires Windows 11 x64 and 64-bit PowerShell 7.' }
    $protonAdapters=@(Get-NetAdapter -IncludeHidden | Where-Object { ($_.Name+' '+$_.InterfaceDescription) -match '(?i)proton' })
    if($protonAdapters.Count){
        $protonRoutes=@(Get-HybridProtonRouteConflicts -Adapters $protonAdapters -Routes @(Get-NetRoute -PolicyStore ActiveStore))
        if($protonRoutes.Count){
            $summary=($protonRoutes | ForEach-Object { "$($_.InterfaceAlias): $($_.DestinationPrefix)" }) -join '; '
            throw "Proton still has Internet default/split-default routes: $summary. This is a routing conflict, even if its app is closed. No adapter was disabled and no policy was changed."
        }
        Write-Warning 'A Proton adapter remains present, but no Internet default/split-default route on it was found. Adapter presence/Up status alone does not establish an active Proton connection.'
    }
    if([int](Get-CimInstance Win32_OperatingSystem).BuildNumber -lt 22000){throw 'Windows 11 or later is required.'}
    $old=Get-Service -Name TorVPN -ErrorAction SilentlyContinue
    if ($old -and $old.Status -ne 'Stopped') { throw 'Old TorVPN is still running. Do not run both clients.' }
    $rootRules=@(Get-DnsClientNrptPolicy -Effective | Where-Object { @($_.Namespace) -contains '.' })
    if ($rootRules.Count) { throw 'An existing root-namespace NRPT rule remains active. Its owner must release it; this app will not delete it.' }
    $weak=@(Get-NetIPInterface | Where-Object { [string]$_.WeakHostSend -eq 'Enabled' -and $_.InterfaceAlias -ne 'whispr-hybrid' })
    if ($weak.Count) { throw 'An existing adapter enables WeakHostSend; coexistence needs review before the backend may enforce interface binding.' }
}
function Get-HybridConfig {
    param([hashtable]$Peer,[string]$PrivateKey,[string]$TorPath,[string[]]$Exceptions=@(),[string]$WireGuardPath='')
    $exclusions=@('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','169.254.0.0/16','fc00::/7','fe80::/10') + $Exceptions + @($Peer.endpoint+'/32')
    $rules=@(
        @{process_path=@($TorPath);action='route';outbound='transport'},
        @{port=53;action='hijack-dns'}
    )
    if ($WireGuardPath) { $rules=@(@{process_path=@($WireGuardPath);action='route';outbound='transport'})+$rules }
    if (-not $Peer.ipv6) { $rules+=@{ip_version=6;network='udp';action='reject'} }
    $rules+=@(@{network='tcp';action='route';outbound='tor'},@{network='udp';action='route';outbound='udp-exit'},@{action='reject'})
    $addresses=@($Peer.client_ipv4)
    $allowed=@('0.0.0.0/0')
    if ($Peer.ipv6) { $addresses+= $Peer.client_ipv6; $allowed+='::/0' }
    return @{
        log=@{level='info';timestamp=$true}
        dns=@{servers=@(@{type='tcp';tag='dns-tor';server='1.1.1.1';server_port=53;detour='tor'});final='dns-tor';strategy='prefer_ipv4'}
        inbounds=@(
            @{type='tun';tag='protected-tun';interface_name='whispr-hybrid';address=@('172.31.249.1/30','fd89:77:71::1/126');mtu=1280;auto_route=$true;strict_route=$false;dns_mode='hijack';route_exclude_address=@($exclusions | Select-Object -Unique)},
            @{type='mixed';tag='local-check';listen='127.0.0.1';listen_port=17880}
        )
        endpoints=@(@{type='wireguard';tag='udp-exit';system=$false;address=$addresses;private_key=$PrivateKey;mtu=1280;peers=@(@{address=$Peer.endpoint;port=[int]$Peer.port;public_key=$Peer.server_public_key;allowed_ips=$allowed;persistent_keepalive_interval=25})})
        outbounds=@(@{type='socks';tag='tor';server='127.0.0.1';server_port=19050;version='5'},@{type='direct';tag='transport'})
        route=@{rules=$rules;auto_detect_interface=$true;default_domain_resolver='dns-tor'}
    }
}
function Get-HybridExistingWireGuard {
    $exe=Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'
    $wg=Join-Path $env:ProgramFiles 'WireGuard\wg.exe'
    $exceptions=[Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $wg) {
        $endpoints=@(& $wg show all endpoints 2>$null)
        if ($LASTEXITCODE -ne 0) { throw 'Existing WireGuard endpoint inventory failed; refusing to guess.' }
        foreach ($line in $endpoints) {
            $endpoint=($line -split '\s+')[-1]
            if ($endpoint -eq '(none)') { continue }
            $m=[regex]::Match($endpoint,'^(?:\[([^\]]+)\]|([^:]+)):\d+$')
            if (-not $m.Success) { throw 'Could not parse an existing WireGuard endpoint.' }
            $ip=[Net.IPAddress]::Parse($(if($m.Groups[1].Success){$m.Groups[1].Value}else{$m.Groups[2].Value}))
            $exceptions.Add($ip.ToString()+$(if($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork){'/32'}else{'/128'}))
        }
        $allowed=@(& $wg show all allowed-ips 2>$null)
        if ($LASTEXITCODE -ne 0) { throw 'Existing WireGuard route inventory failed.' }
        if (($allowed -join "`n") -match '(?:^|\s|,)0\.0\.0\.0/0|::/0') { throw 'Another full-tunnel WireGuard configuration is active; review coexistence first.' }
    }
    return @{Path=$(if(Test-Path -LiteralPath $exe){$exe}else{''});Exceptions=@($exceptions.ToArray())}
}
function Assert-HybridManifest([string]$InstallRoot) {
    $manifest=Get-Content -LiteralPath (Join-Path $InstallRoot 'SHA256SUMS.json') -Raw | ConvertFrom-Json -AsHashtable
    foreach ($relative in $manifest.Keys) {
        $file=Join-Path $InstallRoot $relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Release file missing: $relative" }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $manifest[$relative]) { throw "Release hash mismatch: $relative" }
    }
}

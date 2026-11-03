#requires -Version 7.0
Set-StrictMode -Version 3
function Get-TrayPresentation {
    param([string]$Guard,[hashtable]$Session,[bool]$OwnerAlive,[bool]$TunnelUp,[datetime]$Now=[datetime]::UtcNow)
    $result=@{Label='Status unknown';Color='red';CanConnect=$false;CanSelect=$false;CanRecover=$true}
    if($Guard -eq 'DISARMED' -and -not $OwnerAlive -and -not $TunnelUp){
        $result.Label='Disconnected';$result.Color='gray';$result.CanConnect=$true;$result.CanSelect=$true
        return $result
    }
    if($Guard -eq 'ARMED' -and $OwnerAlive -and $Session){
        if($Session.State -eq 'verified-session' -and $TunnelUp -and $Session.ContainsKey('LastVerifiedUtc')){
            $stamp=[datetime]::MinValue
            $valid=$false
            if($Session.LastVerifiedUtc -is [datetime]){$stamp=$Session.LastVerifiedUtc;$valid=$true}
            else{$valid=[datetime]::TryParse([string]$Session.LastVerifiedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$stamp)}
            if($valid){
                $age=($Now.ToUniversalTime()-$stamp.ToUniversalTime()).TotalSeconds
                if($age -ge -5 -and $age -le 150){$result.Label='Verified';$result.Color='green';return $result}
            }
            $result.Label='Verification stale';$result.Color='orange';return $result
        }
        if($Session.State -in @('preparing','armed-bootstrap')){$result.Label='Connecting / checking';$result.Color='orange';return $result}
    }
    if($Guard -eq 'ARMED'){$result.Label='Protection armed — recovery needed'}
    elseif($Guard -eq 'DISARMED'){$result.Label='Session still stopping / inconsistent state'}
    return $result
}
function Assert-TrayPeer {
    param([hashtable]$Peer,[string]$ExpectedAlias)
    if($ExpectedAlias -notin @('nyc1','lon1','sgp1','syd1')){throw 'Unknown exit alias.'}
    foreach($field in @('schema','ssh_alias','endpoint','port','server_public_key','client_public_key','client_ipv4','ipv6')){
        if(-not $Peer.ContainsKey($field)){throw "Exit profile is missing $field."}
    }
    if($Peer.schema -ne 1 -or $Peer.ssh_alias -ne $ExpectedAlias){throw 'Exit profile identity does not match.'}
    $ip=$null
    if(-not [Net.IPAddress]::TryParse([string]$Peer.endpoint,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'Exit endpoint must be a literal IPv4 address.'}
    if([int]$Peer.port -lt 1024 -or [int]$Peer.port -gt 65535){throw 'Invalid exit port.'}
    foreach($field in @('server_public_key','client_public_key')){
        if($Peer[$field] -notmatch '^[A-Za-z0-9+/]{43}=$'){throw "Invalid $field."}
    }
    if($Peer.client_ipv4 -notmatch '^10[.]88[.]70[.](?:[0-9]{1,3})/32$'){throw 'Unexpected client subnet.'}
    [void][Net.IPAddress]::Parse(($Peer.client_ipv4 -split '/')[0])
    if($Peer.ipv6 -isnot [bool]){throw 'Invalid IPv6 setting.'}
    if($Peer.ipv6){
        if(-not $Peer.ContainsKey('client_ipv6') -or $Peer.client_ipv6 -notmatch '^fd89:77:70::[0-9a-fA-F]+/128$'){throw 'Invalid client IPv6 address.'}
        [void][Net.IPAddress]::Parse(($Peer.client_ipv6 -split '/')[0])
    }
}
function Enter-TraySessionLock {
    $mutex=[Threading.Mutex]::new($false,'Global\whisprHybridVpn040')
    $locked=$false
    try {try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true};if(-not $locked){throw 'Disconnect the current session first.'};return $mutex}
    catch {$mutex.Dispose();throw}
}
function Assert-TrayDisconnected {
    param([string]$InstallRoot)
    $status=(& (Join-Path $InstallRoot 'bin/whispr-vpn-guard.exe') status | Out-String).Trim()
    if($LASTEXITCODE -ne 0 -or $status -ne 'DISARMED'){throw 'Protection is armed or unknown. Use Disconnect / Recover first.'}
    if(Get-NetAdapter -Name 'whispr-hybrid' -IncludeHidden -ErrorAction SilentlyContinue){throw 'The owned tunnel still exists. Use Disconnect / Recover first.'}
}
function Select-TrayExit {
    param([string]$Alias,[string]$InstallRoot,[string]$StateRoot)
    $mutex=Enter-TraySessionLock
    try {
        Assert-TrayDisconnected $InstallRoot
        $path=Join-Path $StateRoot "profiles/$Alias.json"
        if($Alias -notin @('nyc1','lon1','sgp1','syd1')){throw 'Unknown exit alias.'}
        $peer=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        Assert-TrayPeer $peer $Alias
        $device=Get-Content -LiteralPath (Join-Path $StateRoot 'device-key.json') -Raw | ConvertFrom-Json -AsHashtable
        if($peer.client_public_key -ne $device.PublicKey){throw 'This exit was registered for a different device key.'}
        $active=Join-Path $StateRoot 'peer.json'
        Copy-Item -LiteralPath $active -Destination (Join-Path $StateRoot 'peer-before-tray-selection.json') -Force
        Write-HybridJson $peer $active
    } finally {$mutex.ReleaseMutex();$mutex.Dispose()}
}

function Assert-TrayAddon {
    param([string]$InstallRoot)
    $manifest=Get-Content -LiteralPath (Join-Path $InstallRoot 'tray/ADDON-SHA256SUMS.json') -Raw | ConvertFrom-Json -AsHashtable
    $files=@('Open-Tray.ps1','Tray.ps1','Prepare-Exit.ps1','Remove-Tray.ps1','tray/Model.ps1','tray/README.md')
    if($manifest.Count -ne $files.Count){throw 'Tray add-on manifest is incomplete.'}
    foreach($relative in $files){
        if(-not $manifest.ContainsKey($relative) -or (Get-FileHash -LiteralPath (Join-Path $InstallRoot $relative) -Algorithm SHA256).Hash -ne $manifest[$relative]){throw "Tray add-on checksum mismatch: $relative"}
    }
}

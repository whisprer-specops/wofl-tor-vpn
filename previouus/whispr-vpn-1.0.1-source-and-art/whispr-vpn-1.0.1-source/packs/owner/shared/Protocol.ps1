#requires -Version 7.2
Set-StrictMode -Version 3
function Assert-FriendKey([string]$Key){
    if($Key -notmatch '^[A-Za-z0-9+/]{43}=$'){throw 'Invalid WireGuard public key.'}
    $bytes=[Convert]::FromBase64String($Key)
    if($bytes.Length -ne 32 -or [Convert]::ToBase64String($bytes) -cne $Key -or @($bytes|Where-Object {$_ -ne 0}).Count -eq 0){throw 'Non-canonical or zero WireGuard public key.'}
}
function Get-FriendFingerprint([string]$PublicKey){
    Assert-FriendKey $PublicKey
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Convert]::FromBase64String($PublicKey))).ToLowerInvariant()
}
function Read-FriendJson([string]$Path,[long]$MaximumBytes=65536){
    $item=Get-Item -LiteralPath $Path -ErrorAction Stop
    if($item -isnot [IO.FileInfo] -or $item.Length -gt $MaximumBytes -or $item.Length -lt 2){throw 'Unexpected JSON file type/size.'}
    $value=Get-Content -LiteralPath $item.FullName -Raw|ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if($value -isnot [hashtable]){throw 'Expected a JSON object.'}
    return $value
}
function Assert-FriendFields([hashtable]$Value,[string[]]$Fields){
    if($Value.Count -ne $Fields.Count){throw 'Unexpected fields in transfer file.'}
    foreach($field in $Fields){if(-not $Value.ContainsKey($field)){throw "Transfer file is missing $field."}}
}
function Assert-FriendRequest([hashtable]$Request){
    Assert-FriendFields $Request @('Schema','Kind','RequestId','PublicKey','Fingerprint','DeviceName','CreatedUtc')
    if($Request.Schema -ne 1 -or $Request.Kind -cne 'whispr-friend-request' -or $Request.RequestId -cnotmatch '^[0-9a-f]{32}$'){throw 'Unrecognized device request.'}
    if($Request.DeviceName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$'){throw 'Use a device name of 1-64 ASCII letters, numbers, spaces, dot, underscore or hyphen.'}
    Assert-FriendKey $Request.PublicKey
    if($Request.Fingerprint -cne (Get-FriendFingerprint $Request.PublicKey)){throw 'Public-key fingerprint mismatch.'}
    $stamp=[datetime]::MinValue;if(-not [datetime]::TryParse([string]$Request.CreatedUtc,[ref]$stamp)){throw 'Invalid request timestamp.'}
}
function Assert-FriendEndpoint([string]$Endpoint){
    $ip=[Net.IPAddress]::Parse($Endpoint)
    if($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'Exit endpoint must be a literal public IPv4 address.'}
    $v=$ip.GetAddressBytes()
    if($v[0] -in @(0,10,127) -or $v[0] -ge 224 -or ($v[0] -eq 169 -and $v[1] -eq 254) -or ($v[0] -eq 172 -and $v[1] -ge 16 -and $v[1] -le 31) -or ($v[0] -eq 192 -and $v[1] -eq 168) -or ($v[0] -eq 100 -and $v[1] -ge 64 -and $v[1] -le 127)){throw 'Exit endpoint must be a public IPv4 address.'}
}
function Assert-FriendAccess([hashtable]$Access,[hashtable]$Request){
    Assert-FriendRequest $Request
    Assert-FriendFields $Access @('Schema','Kind','RequestId','PublicKey','Fingerprint','DeviceName','CreatedUtc','Exits')
    if($Access.Schema -ne 1 -or $Access.Kind -cne 'whispr-friend-access'){throw 'Unrecognized access file.'}
    foreach($field in @('RequestId','PublicKey','Fingerprint','DeviceName')){if($Access[$field] -cne $Request[$field]){throw "Access approval is for a different device/request ($field)."}}
    if($Access.Exits -isnot [System.Collections.IList] -or $Access.Exits.Count -lt 1 -or $Access.Exits.Count -gt 5){throw 'Access file must contain one to five approved exits.'}
    $seen=@{}
    foreach($peer in $Access.Exits){
        if($peer -isnot [hashtable]){throw 'Invalid exit profile.'}
        Assert-FriendFields $peer @('schema','ssh_alias','endpoint','port','server_public_key','client_public_key','client_ipv4','client_ipv6','ipv6','interface')
        if($peer.ssh_alias -cnotin @('nyc1','lon1','fkt1','sgp1','syd1') -or $seen.ContainsKey($peer.ssh_alias)){throw 'Unknown or duplicate exit alias.'}
        $seen[$peer.ssh_alias]=$true
        Assert-FriendKey $peer.server_public_key;Assert-FriendKey $peer.client_public_key
        if($peer.client_public_key -cne $Request.PublicKey -or $peer.interface -cne 'wg-whispr'){throw 'Exit device/interface binding differs.'}
        if($peer.port -isnot [long] -and $peer.port -isnot [int]){throw 'Exit port must be a JSON integer.'}
        Assert-TrayPeer $peer $peer.ssh_alias
        Assert-FriendEndpoint $peer.endpoint
    }
}
function Write-FriendJson($Value,[string]$Path){
    $parent=Split-Path $Path -Parent;if(-not $parent){$Path=[IO.Path]::GetFullPath($Path);$parent=Split-Path $Path -Parent}
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $temp=Join-Path $parent ('.friend-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{$Value|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $temp -Encoding utf8NoBOM;Move-Item -LiteralPath $temp -Destination $Path -Force}
    finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
}
function Assert-FriendPackage([string]$Root){
    $manifest=Read-FriendJson (Join-Path $Root 'PACKAGE-SHA256SUMS.json') 1048576
    foreach($name in $manifest.Keys){
        if($name -match '(^[/\\]|^[A-Za-z]:|(^|[/\\])[.][.]([/\\]|$))'){throw 'Unsafe package path.'}
        if((Get-FileHash -LiteralPath (Join-Path $Root $name) -Algorithm SHA256).Hash -ne $manifest[$name]){throw "Package integrity failure: $name"}
    }
}

#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Register','Revoke','Check','Recover')][string]$Action,
      [string]$Request,
      [ValidateSet('nyc1','lon1','fkt1','sgp1','syd1')][string[]]$Servers=@('nyc1','lon1','fkt1','sgp1','syd1'),
      [string]$OutputDirectory=(Join-Path $PSScriptRoot 'out'))
$ErrorActionPreference='Stop'
. "$PSScriptRoot/shared/Protocol.ps1"
. "$PSScriptRoot/shared/Model.ps1"
Assert-FriendPackage $PSScriptRoot
if(-not $IsWindows){throw 'Run owner operations in Windows PowerShell 7 with your existing OpenSSH aliases.'}
$ssh=(Get-Command ssh.exe -ErrorAction Stop).Source;$scp=(Get-Command scp.exe -ErrorAction Stop).Source
$req=$null
if($Action -ne 'Recover'){
    if(-not $Request){throw 'Supply -Request with the friend-request.json received from the friend.'}
    $req=Read-FriendJson $Request 4096;Assert-FriendRequest $req
    Write-Host "Device: $($req.DeviceName)" -ForegroundColor Cyan
    Write-Host "Public-key fingerprint: $($req.Fingerprint)"
    Write-Host 'Use the request received directly from your friend; no private key or server password is inside it.'
}
$tag=if($req){$req.RequestId}else{'recovery'}
$runDir=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ($tag+'-'+[datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void](New-Item -ItemType Directory -Path $runDir -Force)
$profiles=[Collections.Generic.List[object]]::new();$results=[Collections.Generic.List[object]]::new();$failed=[Collections.Generic.List[string]]::new()
$scriptPath=Join-Path $PSScriptRoot 'server/peer_admin.py';$sha=(Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
foreach($server in @($Servers|ForEach-Object {$_.ToLowerInvariant()}|Select-Object -Unique)){
    $stage=$null
    try{
        Write-Host "`n=== $server : $Action ===" -ForegroundColor Cyan
        $cfg=@(& $ssh -G $server);if($LASTEXITCODE -ne 0){throw 'Cannot read the SSH alias.'}
        $hostLines=@($cfg|Where-Object {$_ -match '^hostname '});$users=@($cfg|Where-Object {$_ -match '^user '})
        if($hostLines.Count -ne 1 -or $users.Count -ne 1){throw 'SSH hostname/account is ambiguous.'}
        $ip=[Net.IPAddress]::Parse(($hostLines[0] -split '\s+',2)[1]);$user=($users[0] -split '\s+',2)[1]
        if($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'SSH alias must resolve to a literal public IPv4 address.'}
        Assert-FriendEndpoint $ip.ToString()
        $stage=(& $ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=12 $server 'mktemp -d /tmp/whispr-enrol-XXXXXXXX'|Out-String).Trim()
        if($LASTEXITCODE -ne 0 -or $stage -notmatch '^/tmp/whispr-enrol-[A-Za-z0-9]+$'){throw 'Could not create a secure remote staging directory.'}
        & $scp -o BatchMode=yes -o StrictHostKeyChecking=yes $scriptPath "${server}:$stage/peer_admin.py"
        if($LASTEXITCODE -ne 0){throw 'Peer tool upload failed.'}
        $runner=if($user -eq 'root'){'env SUDO_USER=root python3'}else{'sudo python3'}
        if($user -eq 'root'){Write-Host 'This SSH alias logs in as root; no sudo password is needed.' -ForegroundColor Yellow}
        else{Write-Host "Enter the $server sudo password for '$user' when asked. Input is hidden." -ForegroundColor Yellow}
        $arguments="--action '$($Action.ToLowerInvariant())' --report '$stage/report.json'"
        if($req){$arguments+=" --public-key '$($req.PublicKey)' --request-id '$($req.RequestId)' --label '$($req.DeviceName)'"}
        $remote="printf '%s  %s\n' '$sha' '$stage/peer_admin.py' | sha256sum -c - && $runner -I '$stage/peer_admin.py' $arguments"
        & $ssh -t -o StrictHostKeyChecking=yes -o ConnectTimeout=12 $server $remote
        if($LASTEXITCODE -ne 0){throw 'Remote peer operation did not verify. Read the STOP line above; rerun to recover/retry if interrupted.'}
        $reportPath=Join-Path $runDir "$server-report.json"
        & $scp -o BatchMode=yes -o StrictHostKeyChecking=yes "${server}:$stage/report.json" $reportPath
        if($LASTEXITCODE -ne 0){throw 'Could not download the public result. Registration may have succeeded; retry safely with the same request.'}
        $report=Read-FriendJson $reportPath
        if($report.schema -ne 1 -or $report.action -cne $Action.ToLowerInvariant()){throw 'Unexpected server report identity.'}
        if($req -and ($report.request_id -cne $req.RequestId -or $report.client_public_key -cne $req.PublicKey)){throw 'Result is for a different friend request.'}
        if($Action -in @('Register','Check')){
            if($report.status -cne 'verified'){throw 'Peer was not verified.'}
            $peer=@{schema=1;ssh_alias=$server;endpoint=$ip.ToString();port=$report.port;server_public_key=$report.server_public_key;client_public_key=$report.client_public_key;client_ipv4=$report.client_ipv4;client_ipv6=$report.client_ipv6;ipv6=$report.ipv6;interface=$report.interface}
            Assert-TrayPeer $peer $server
            $profiles.Add($peer)
        }elseif($Action -eq 'Revoke' -and $report.status -notin @('revoked','already-absent')){throw 'Revocation was not verified.'}
        elseif($Action -eq 'Recover' -and $report.status -ne 'verified'){throw 'Recovery was not verified.'}
        $results.Add(@{Server=$server;Status=$report.status;Report=$reportPath})
        Write-Host "$server : $($report.status)" -ForegroundColor Green
    }catch{
        $failed.Add($server);$results.Add(@{Server=$server;Status='failed';Error=$_.Exception.Message})
        Write-Warning "$server : $($_.Exception.Message)"
    }finally{
        if($stage -match '^/tmp/whispr-enrol-[A-Za-z0-9]+$'){
            & $ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 $server "rm -f '$stage/peer_admin.py' '$stage/report.json'; rmdir '$stage'" | Out-Null
            if($LASTEXITCODE -ne 0){Write-Warning "Remote staging cleanup on $server was incomplete; no live peer was removed."}
        }
    }
}
Write-FriendJson @{Schema=1;Action=$Action;RequestId=$tag;Results=@($results.ToArray());CreatedUtc=[datetime]::UtcNow.ToString('o')} (Join-Path $runDir 'owner-receipt.json')
if($req){Write-FriendJson $req (Join-Path $runDir 'friend-request.json')}
if($Action -in @('Register','Check') -and $profiles.Count -gt 0){
    $access=@{Schema=1;Kind='whispr-friend-access';RequestId=$req.RequestId;PublicKey=$req.PublicKey;Fingerprint=$req.Fingerprint;DeviceName=$req.DeviceName;CreatedUtc=[datetime]::UtcNow.ToString('o');Exits=@($profiles.ToArray())}
    Assert-FriendAccess $access $req
    $accessPath=Join-Path $runDir 'friend-access.json';Write-FriendJson $access $accessPath
    Write-Host "`nSEND THIS FILE BACK TO YOUR FRIEND:`n$accessPath" -ForegroundColor Green
    Write-Host "Verified exits: $($profiles.Count). Keep friend-request.json and owner-receipt.json for check/revocation."
}
Write-Host "Owner reports: $runDir"
if($failed.Count){throw "Unresolved exits: $($failed -join ', '). Successful operations are retained; the access file, if written, contains only verified exits. Retry the same request for failed exits."}

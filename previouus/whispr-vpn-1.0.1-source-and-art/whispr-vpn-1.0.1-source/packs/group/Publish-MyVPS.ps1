#requires -Version 7.2
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$File=(Join-Path $PSScriptRoot 'group.json'),[string]$Config=(Join-Path $PSScriptRoot 'my-vps.json'),[switch]$ApproveMembers)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/group/Protocol.ps1";. "$PSScriptRoot/group/Local.ps1"
Assert-GroupPackage $PSScriptRoot;$identity=Get-GroupLocalIdentity
$g=Read-GroupWithLocalMerge $File $identity;Assert-GroupDisconnected $identity
if(-not (Test-Path -LiteralPath "$($identity.Home)/group-addon.json")){throw 'Run Install-Group.ps1 once before publishing.'}
$check=[Threading.Mutex]::new($false,'Global\whisprHybridTray010');$closed=$false
try{try{$closed=$check.WaitOne(0)}catch [Threading.AbandonedMutexException]{$closed=$true};if(-not $closed){throw 'Close the tray before publishing so the resulting profiles can be imported safely.'}}finally{if($closed){$check.ReleaseMutex()};$check.Dispose()}
$c=Read-GroupJson $Config;Assert-GroupFields $c @('Schema','Servers')
if($c.Schema -ne 1 -or $c.Servers -isnot [Collections.IList] -or $c.Servers.Count -lt 1 -or $c.Servers.Count -gt 64){throw 'Add your VPS first with Add-MyVPS.ps1, or enter it in my-vps.json (1-64 entries).'}
$seen=@{}
foreach($node in $c.Servers){
    Assert-GroupFields $node @('SSH','Name','Latitude','Longitude','Port');Assert-GroupName $node.Name
    if($node.SSH -cnotmatch '^(?:[A-Za-z0-9][A-Za-z0-9_.-]{0,63}|[A-Za-z0-9][A-Za-z0-9_.-]{0,31}@[0-9.]{7,15})$' -or $seen.ContainsKey($node.SSH)){throw 'Invalid or duplicate SSH alias.'};$seen[$node.SSH]=$true
    if(-not (Test-GroupNumber $node.Latitude) -or -not (Test-GroupNumber $node.Longitude)){throw 'Coordinates must be JSON numbers.'}
    if($node.Port -isnot [int] -and $node.Port -isnot [long] -or $node.Port -lt 1024 -or $node.Port -gt 65535 -or -not [double]::IsFinite([double]$node.Latitude) -or -not [double]::IsFinite([double]$node.Longitude) -or $node.Latitude -lt -90 -or $node.Latitude -gt 90 -or $node.Longitude -lt -180 -or $node.Longitude -gt 180){throw 'Invalid server port/coordinates.'}
}
Write-Host 'YOU ARE APPROVING THESE DEVICES ON YOUR LISTED VPSs:' -ForegroundColor Yellow
foreach($m in $g.Members){Write-Host "$($m.Name): $($m.Id)"}
Write-Host 'New VPSs: installs the dedicated WireGuard exit, UDP forwarding/NAT and its reboot service. Existing managed VPSs: only group peer registration changes; server identity and firewall are retained.'
if(-not $ApproveMembers -and (Read-Host 'Type YES to approve this member list and setup/sync your VPSs') -cne 'YES'){throw 'Cancelled; no server was changed.'}
$ssh=(Get-Command ssh.exe -ErrorAction Stop).Source;$scp=(Get-Command scp.exe -ErrorAction Stop).Source
$run=Join-Path $PSScriptRoot ('results/'+[datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8));[void](New-Item -ItemType Directory -Path $run -Force)
$failed=[Collections.Generic.List[string]]::new();$results=[Collections.Generic.List[object]]::new()
foreach($node in $c.Servers){
    $alias=$node.SSH;$stage=$null
    try{
        Write-Host "`n=== $alias / $($node.Name) ===" -ForegroundColor Cyan
        $cfg=@(& $ssh -G $alias);if($LASTEXITCODE -ne 0){throw 'Cannot read SSH alias.'}
        $hosts=@($cfg|Where-Object {$_ -match '^hostname '});$users=@($cfg|Where-Object {$_ -match '^user '})
        if($hosts.Count -ne 1 -or $users.Count -ne 1){throw 'SSH host/account is ambiguous.'}
        $endpoint=([Net.IPAddress]::Parse(($hosts[0] -split '\s+',2)[1])).ToString();Assert-GroupPublicIP $endpoint;$user=($users[0] -split '\s+',2)[1]
        $stage=(& $ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=12 $alias 'mktemp -d /tmp/whispr-hybrid-XXXXXXXX'|Out-String).Trim()
        if($LASTEXITCODE -ne 0 -or $stage -notmatch '^/tmp/whispr-hybrid-[A-Za-z0-9]+$'){throw 'Cannot create secure staging. Test this SSH alias and trust its host key normally first.'}
        $nodeInput=@{Schema=1;GroupId=$g.GroupId;MembershipRevision=$g.MembershipRevision;Members=$g.Members;OwnerId=$identity.Id;Node=@{Name=$node.Name;Latitude=$node.Latitude;Longitude=$node.Longitude;Port=$node.Port}}
        $inputPath=Join-Path $run ($alias+'-input.json');Write-GroupJson $nodeInput $inputPath
        $files=@('group_admin.py','peer_admin.py','setup.py','firewall.py','manage.py');$upload=@($files|ForEach-Object {Join-Path $PSScriptRoot "server/$_"})+@($inputPath)
        & $scp -o BatchMode=yes -o StrictHostKeyChecking=yes @upload "${alias}:$stage/"
        if($LASTEXITCODE -ne 0){throw 'Upload failed.'}
        # The input filename on disk is alias-prefixed; move it only inside the unique stage.
        $checks=[Collections.Generic.List[string]]::new()
        foreach($f in $files){$h=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot "server/$f")).Hash.ToLowerInvariant();$checks.Add("'$h  $stage/$f'")}
        $ih=(Get-FileHash -LiteralPath $inputPath).Hash.ToLowerInvariant();$checks.Add("'$ih  $stage/$alias-input.json'")
        $runner=if($user -eq 'root'){'env SUDO_USER=root python3'}else{'sudo python3'}
        if($user -eq 'root'){Write-Host 'SSH is root; no sudo password needed.' -ForegroundColor Yellow}else{Write-Host "Enter the $alias SUDO password for '$user' when prompted. Input is hidden. Stay at this terminal." -ForegroundColor Yellow}
        $remote="printf '%s\n' $($checks -join ' ') | sha256sum -c - && mv '$stage/$alias-input.json' '$stage/input.json' && $runner -I '$stage/group_admin.py' --input '$stage/input.json' --report '$stage/report.json'"
        & $ssh -t -o StrictHostKeyChecking=yes -o ConnectTimeout=12 $alias $remote
        if($LASTEXITCODE -ne 0){throw 'Server setup/sync did not verify. Completed peer changes may be retained; retry the same current group file.'}
        $reportPath=Join-Path $run ($alias+'-report.json');& $scp -o BatchMode=yes -o StrictHostKeyChecking=yes "${alias}:$stage/report.json" $reportPath
        if($LASTEXITCODE -ne 0){throw 'Public report download failed; retry safely.'}
        $r=Read-GroupJson $reportPath
        if($r.Schema -ne 1 -or $r.GroupId -cne $g.GroupId -or $r.OwnerId -cne $identity.Id -or $r.Port -ne $node.Port){throw 'Unexpected server response binding.'}
        $id='exit-'+(Get-GroupKeyId $r.ServerPublicKey).Substring(0,24)
        $knownNode=@($g.Nodes|Where-Object Id -eq $id)|Select-Object -First 1
        if($knownNode -and $knownNode.OwnerId -cne $identity.Id){throw 'This server public identity is already published by a different owner; it was not replaced.'}
        $record=@{Id=$id;OwnerId=$identity.Id;Name=$node.Name;Latitude=$node.Latitude;Longitude=$node.Longitude;Endpoint=$endpoint;Port=$r.Port;ServerPublicKey=$r.ServerPublicKey;IPv6=$r.IPv6;Assignments=$r.Assignments;Revision=$r.Revision;MembersRevision=$r.MembersRevision}
        $next=$g|ConvertTo-Json -Depth 50|ConvertFrom-Json -AsHashtable;$next.Nodes=@($g.Nodes|Where-Object Id -ne $id)+@($record);Assert-GroupDocument $next
        $g=$next;Write-GroupJson $g $File
        $results.Add(@{SSH=$alias;Status='verified';NodeId=$id;CreatedServer=$r.CreatedServer});Write-Host "VERIFIED: $($node.Name). Allow inbound UDP $($node.Port) in its provider firewall." -ForegroundColor Green
    }catch{$failed.Add($alias);$results.Add(@{SSH=$alias;Status='failed';Error=$_.Exception.Message});Write-Warning "$alias : $($_.Exception.Message)"}
    finally{
        if($stage -match '^/tmp/whispr-hybrid-[A-Za-z0-9]+$'){
            $names=@('group_admin.py','peer_admin.py','setup.py','firewall.py','manage.py','input.json','report.json','bootstrap-report.json',"$alias-input.json")
            $quoted=@($names|ForEach-Object {"'$stage/$_'"}) -join ' '
            & $ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 $alias "rm -f $quoted; rmdir '$stage'" | Out-Null
        }
    }
}
Write-GroupJson @{Schema=1;Results=@($results.ToArray())} (Join-Path $run 'receipt.json')
Write-Host "`nEXCHANGE THIS ONE FILE: $File" -ForegroundColor Green
if($g.Nodes.Count -gt 0){
    . "$($identity.Home)/client/Common.ps1";. "$($identity.Home)/tray/Model.ps1"
    $count=Import-HybridGroup $g $identity.Home $identity.State
    Write-Host "Imported $count shared exits on this PC too. Reopen the VPN tray from Start when ready."
}
Write-Host 'Everyone imports this updated group.json. Server setup success is not a client handshake test; Connect must still turn Verified/green.'
if($failed.Count){throw "Unresolved VPSs: $($failed -join ', '). Verified nodes were saved; retry to complete the rest. Reports: $run"}

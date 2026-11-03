#requires -Version 7.2
Set-StrictMode -Version 3
function Read-GroupJson([string]$Path,[long]$Maximum=8388608){
    $f=Get-Item -LiteralPath $Path -ErrorAction Stop
    if($f -isnot [IO.FileInfo] -or $f.Length -lt 2 -or $f.Length -gt $Maximum){throw 'Unexpected JSON file type/size.'}
    $v=Get-Content -LiteralPath $f.FullName -Raw|ConvertFrom-Json -AsHashtable
    if($v -isnot [hashtable]){throw 'Expected a JSON object.'};return $v
}
function Write-GroupJson($Value,[string]$Path){
    $Path=[IO.Path]::GetFullPath($Path);$dir=Split-Path $Path -Parent;[void](New-Item -ItemType Directory -Path $dir -Force)
    $tmp=Join-Path $dir ('.group-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{$Value|ConvertTo-Json -Depth 50|Set-Content -LiteralPath $tmp -Encoding utf8NoBOM;Move-Item -LiteralPath $tmp -Destination $Path -Force}
    finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force}}
}
function Assert-GroupFields([hashtable]$Value,[string[]]$Fields){
    if($Value.Count -ne $Fields.Count){throw 'Unexpected fields in group data.'}
    foreach($f in $Fields){if(-not $Value.ContainsKey($f)){throw "Group data is missing $f."}}
}
function Get-GroupKeyId([string]$Key){
    if($Key -cnotmatch '^[A-Za-z0-9+/]{43}=$'){throw 'Invalid WireGuard public key.'}
    $b=[Convert]::FromBase64String($Key)
    if($b.Length -ne 32 -or [Convert]::ToBase64String($b) -cne $Key -or @($b|Where-Object {$_ -ne 0}).Count -eq 0){throw 'Invalid canonical public key.'}
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($b)).ToLowerInvariant()
}
function Assert-GroupName([string]$Name){if($Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9 ._()-]{0,63}$'){throw 'Use a name of 1-64 ASCII letters, numbers, spaces, dot, underscore, parentheses or hyphen.'}}
function Assert-GroupPublicIP([string]$Text){
    $ip=$null;if(-not [Net.IPAddress]::TryParse($Text,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $ip.ToString() -cne $Text){throw 'Use a literal dotted public IPv4 address.'}
    $b=$ip.GetAddressBytes()
    if($b[0] -in @(0,10,127) -or $b[0] -ge 224 -or ($b[0] -eq 169 -and $b[1] -eq 254) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127)){throw 'Private/link-local/reserved endpoints cannot be published.'}
}
function Test-GroupNumber($Value){return ($Value -is [double] -or $Value -is [single] -or $Value -is [int] -or $Value -is [long] -or $Value -is [decimal])}
function Assert-GroupDocument([hashtable]$Group){
    Assert-GroupFields $Group @('Schema','Kind','GroupId','Name','MembershipRevision','Members','Nodes')
    if($Group.Schema -ne 1 -or $Group.Kind -cne 'whispr-exit-group' -or $Group.GroupId -cnotmatch '^[0-9a-f]{32}$' -or $Group.MembershipRevision -isnot [long] -and $Group.MembershipRevision -isnot [int] -or $Group.MembershipRevision -lt 1){throw 'Unrecognized group identity/revision.'}
    Assert-GroupName $Group.Name
    if($Group.Members -isnot [Collections.IList] -or $Group.Members.Count -lt 1 -or $Group.Members.Count -gt 64){throw 'A group supports 1-64 device identities.'}
    $members=@{}
    foreach($m in $Group.Members){
        Assert-GroupFields $m @('Id','PublicKey','Name');Assert-GroupName $m.Name
        if($m.Id -cne (Get-GroupKeyId $m.PublicKey) -or $members.ContainsKey($m.Id)){throw 'Invalid or duplicate member identity.'};$members[$m.Id]=$m
    }
    if($Group.Nodes -isnot [Collections.IList] -or $Group.Nodes.Count -gt 128){throw 'A group supports at most 128 exits.'}
    $nodes=@{};$endpoints=@{}
    foreach($n in $Group.Nodes){
        Assert-GroupFields $n @('Id','OwnerId','Name','Latitude','Longitude','Endpoint','Port','ServerPublicKey','IPv6','Assignments','Revision','MembersRevision')
        if($n.Id -cne ('exit-'+(Get-GroupKeyId $n.ServerPublicKey).Substring(0,24)) -or $nodes.ContainsKey($n.Id) -or -not $members.ContainsKey($n.OwnerId)){throw 'Invalid exit identity/owner.'}
        $nodes[$n.Id]=$true;Assert-GroupName $n.Name;Assert-GroupPublicIP $n.Endpoint
        if($n.Port -isnot [long] -and $n.Port -isnot [int] -or $n.Port -lt 1024 -or $n.Port -gt 65535 -or $n.IPv6 -isnot [bool]){throw 'Invalid exit port/address family.'}
        if(-not (Test-GroupNumber $n.Latitude) -or -not (Test-GroupNumber $n.Longitude) -or -not [double]::IsFinite([double]$n.Latitude) -or -not [double]::IsFinite([double]$n.Longitude) -or [double]$n.Latitude -lt -90 -or [double]$n.Latitude -gt 90 -or [double]$n.Longitude -lt -180 -or [double]$n.Longitude -gt 180){throw 'Invalid map coordinates.'}
        foreach($field in @('Revision','MembersRevision')){if($n[$field] -isnot [long] -and $n[$field] -isnot [int] -or $n[$field] -lt 1){throw 'Invalid node revision.'}}
        if($n.MembersRevision -gt $Group.MembershipRevision -or $n.Assignments -isnot [hashtable] -or $n.Assignments.Count -gt 64){throw 'Invalid node membership data.'}
        $addressSet=@{}
        foreach($id in $n.Assignments.Keys){
            if(-not $members.ContainsKey($id)){throw 'Exit assignment refers to an unknown member.'}
            $a=$n.Assignments[$id];Assert-GroupFields $a @('IPv4','IPv6')
            if($a.IPv4 -cnotmatch '^10[.]88[.]70[.](?:[0-9]{1,3})/32$'){throw 'Unexpected assigned subnet.'}
            $octet=[int](($a.IPv4 -split '[./]')[3]);if($octet -lt 2 -or $octet -gt 253 -or $addressSet.ContainsKey($a.IPv4)){throw 'Invalid or duplicate assigned address.'};$addressSet[$a.IPv4]=$true
            if($n.IPv6){if($a.IPv6 -cne ('fd89:77:70::'+$octet.ToString('x')+'/128')){throw 'IPv6 assignment differs from slot.'}}elseif($null -ne $a.IPv6){throw 'Unexpected IPv6 assignment.'}
        }
        if(-not $n.Assignments.ContainsKey($n.OwnerId)){throw 'Exit owner has no registered assignment.'}
        $binding=$n.Endpoint+':'+$n.Port;if($endpoints.ContainsKey($binding)){throw 'Two node identities use the same endpoint/port.'};$endpoints[$binding]=$true
    }
}
function Get-GroupMemberHash([hashtable]$Group){return ((@($Group.Members|Sort-Object Id|ForEach-Object {$_.Id}) -join ',')+'|'+$Group.MembershipRevision)}
function Merge-GroupDocuments([hashtable]$Old,[hashtable]$Incoming){
    Assert-GroupDocument $Old;Assert-GroupDocument $Incoming
    if($Old.GroupId -cne $Incoming.GroupId){throw 'This file belongs to another group.'}
    if($Incoming.MembershipRevision -lt $Old.MembershipRevision){throw 'This group file has an older member list. Obtain the latest group.json before publishing/importing.'}
    if($Incoming.MembershipRevision -eq $Old.MembershipRevision -and (Get-GroupMemberHash $Old) -cne (Get-GroupMemberHash $Incoming)){throw 'Conflicting member lists at the same revision; use one agreed latest group file.'}
    $merged=$Incoming|ConvertTo-Json -Depth 50|ConvertFrom-Json -AsHashtable
    $all=@{};foreach($n in $Old.Nodes){$all[$n.Id]=$n}
    foreach($n in $Incoming.Nodes){
        if($all.ContainsKey($n.Id)){
            $previous=$all[$n.Id]
            if($previous.OwnerId -cne $n.OwnerId -or $previous.ServerPublicKey -cne $n.ServerPublicKey){throw 'Existing exit ownership/key binding differs.'}
            if($n.Revision -lt $previous.Revision){continue}
            if($n.Revision -eq $previous.Revision){
                foreach($field in @('Name','Endpoint','Port','Latitude','Longitude','MembersRevision')){if($n[$field] -ne $previous[$field]){throw 'Conflicting exit records at the same revision.'}}
                $left=(@($n.Assignments.Keys|Where-Object {$_ -in @($Incoming.Members|ForEach-Object Id)}|Sort-Object|ForEach-Object {$_+'='+$n.Assignments[$_].IPv4+'|'+$n.Assignments[$_].IPv6}) -join ';')
                $right=(@($previous.Assignments.Keys|Where-Object {$_ -in @($Incoming.Members|ForEach-Object Id)}|Sort-Object|ForEach-Object {$_+'='+$previous.Assignments[$_].IPv4+'|'+$previous.Assignments[$_].IPv6}) -join ';')
                if($n.IPv6 -ne $previous.IPv6 -or $left -cne $right){throw 'Conflicting exit assignments at the same revision.'}
            }
        }
        $all[$n.Id]=$n
    }
    $ids=@($merged.Members|ForEach-Object Id)
    $nodes=[Collections.Generic.List[object]]::new()
    foreach($n in $all.Values){
        if($n.OwnerId -notin $ids){throw 'A VPS owner cannot be removed while their published exits remain in the group.'}
        $copy=$n|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable
        foreach($id in @($copy.Assignments.Keys)){if($id -notin $ids){[void]$copy.Assignments.Remove($id)}}
        $nodes.Add($copy)
    }
    $merged.Nodes=@($nodes.ToArray()|Sort-Object Id);Assert-GroupDocument $merged;return $merged
}
function Assert-GroupPackage([string]$Root){
    $m=Read-GroupJson (Join-Path $Root 'PACKAGE-SHA256SUMS.json')
    foreach($p in $m.Keys){if($p -match '(^[/\\]|^[A-Za-z]:|(^|[/\\])[.][.]([/\\]|$))'){throw 'Unsafe package path.'};if((Get-FileHash -LiteralPath (Join-Path $Root $p) -Algorithm SHA256).Hash -ne $m[$p]){throw "Package checksum mismatch: $p"}}
}

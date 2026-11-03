#requires -Version 7.2
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../group/Protocol.ps1"
. "$PSScriptRoot/../payload/tray/Model.ps1"
. "$PSScriptRoot/../payload/tray/MapModel.ps1"
function Check([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
function Key([string]$Text){return [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text)))}
$public=Key 'owner';$friend=Key 'friend';$server=Key 'node';$id=Get-GroupKeyId $public;$fid=Get-GroupKeyId $friend;$nid='exit-'+(Get-GroupKeyId $server).Substring(0,24)
$g=@{Schema=1;Kind='whispr-exit-group';GroupId='a'*32;Name='Friends';MembershipRevision=1;Members=@(@{Id=$id;PublicKey=$public;Name='Owner'},@{Id=$fid;PublicKey=$friend;Name='Friend'});Nodes=@()}
$n=@{Id=$nid;OwnerId=$id;Name='Extra Frankfurt';Latitude=50.11;Longitude=8.68;Endpoint='203.0.113.8';Port=51832;ServerPublicKey=$server;IPv6=$false;Assignments=@{($id)=@{IPv4='10.88.70.2/32';IPv6=$null};($fid)=@{IPv4='10.88.70.3/32';IPv6=$null}};Revision=1;MembersRevision=1}
$g.Nodes=@($n);Assert-GroupDocument $g
$copy=$g|ConvertTo-Json -Depth 30|ConvertFrom-Json -AsHashtable;Assert-GroupDocument $copy
$older=$g|ConvertTo-Json -Depth 30|ConvertFrom-Json -AsHashtable;$older.Nodes=@()
$merged=Merge-GroupDocuments $g $older;Check ($merged.Nodes.Count -eq 1) 'Importing a file without another owner recent exit must not delete it.'
$new=$g|ConvertTo-Json -Depth 30|ConvertFrom-Json -AsHashtable;$new.Nodes[0].Revision=2;$new.Nodes[0].Name='Renamed'
$merged=Merge-GroupDocuments $g $new;Check ($merged.Nodes[0].Name -eq 'Renamed') 'Newer node revision was not selected.'
$new.Nodes[0].Name='Conflict';$failed=$false;try{Merge-GroupDocuments $merged $new}catch{$failed=$true};Check $failed 'Equal revision conflicting nodes accepted.'
foreach($change in @('bad-key','private-endpoint','unknown-owner','same-address','outside-map','port-string')){
 $bad=$g|ConvertTo-Json -Depth 30|ConvertFrom-Json -AsHashtable
 switch($change){'bad-key' {$bad.Members[0].PublicKey='bad'};'private-endpoint' {$bad.Nodes[0].Endpoint='10.0.0.1'};'unknown-owner' {$bad.Nodes[0].OwnerId='b'*64};'same-address' {$bad.Nodes[0].Assignments[$fid].IPv4='10.88.70.2/32'};'outside-map' {$bad.Nodes[0].Latitude=91};'port-string' {$bad.Nodes[0].Port='51832'}}
 $failed=$false;try{Assert-GroupDocument $bad}catch{$failed=$true};Check $failed "Accepted $change"
}
$removed=$g|ConvertTo-Json -Depth 30|ConvertFrom-Json -AsHashtable
$removed.MembershipRevision=2;$removed.Members=@($removed.Members|Where-Object Id -eq $id);[void]$removed.Nodes[0].Assignments.Remove($fid)
$merged=Merge-GroupDocuments $g $removed
Check ($merged.Nodes[0].Assignments.Count -eq 1) 'Member removal must prune old assignments without a false same-node-revision conflict.'
$script:hybridDynamicRegions=@(@{Alias=$nid;Name='Extra Frankfurt';Lon=8.6821;Lat=50.1109;Dx=12;Dy=14})
Check (@(Get-HybridRegions).Count -eq 6) 'Dynamic exit missing from map.'
$markers=@(Get-HybridMapMarkers 1120 572);$target=@($markers|Where-Object {$_.Alias -eq $nid -and -not $_.Inset})[0]
$candidates=@(Find-HybridMapCandidates $target.X $target.Y 1120 572)
Check ($nid -in $candidates.Alias -and 'fkt1' -in $candidates.Alias) 'Overlapping Frankfurt dots must both be offered in the chooser.'
$profile=@{schema=1;ssh_alias=$nid;endpoint='203.0.113.8';port=51832;server_public_key=$server;client_public_key=$public;client_ipv4='10.88.70.2/32';client_ipv6=$null;ipv6=$false;interface='wg-whispr'}
Assert-TrayPeer $profile $nid
$failed=$false;try{Assert-TrayPeer $profile '../bad'}catch{$failed=$true};Check $failed 'Unsafe profile alias accepted.'
Write-Host 'Group contract, merge, key/address/revision validation, dynamic map and overlapping dot tests passed.'

#requires -Version 7.2
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$Name='Friends',[string]$MyName='My device',[string[]]$MemberRequests=@(),[string]$Output=(Join-Path $PSScriptRoot 'group.json'),[switch]$StartIndependentGroup)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/group/Protocol.ps1";. "$PSScriptRoot/group/Local.ps1"
Assert-GroupPackage $PSScriptRoot
if(Test-Path -LiteralPath $Output){throw 'group.json already exists. Use Add-Member.ps1 or continue with that file; it was not overwritten.'}
$identity=Get-GroupLocalIdentity
if((Test-Path -LiteralPath (Join-Path $identity.Home 'friend-mode.json')) -and -not $StartIndependentGroup){throw 'This is a friend client: import the existing group.json instead of creating a second group. An intentionally independent group requires -StartIndependentGroup.'}
if(Test-Path -LiteralPath (Join-Path $identity.State 'group-catalog.json')){throw 'This PC already has a group catalogue. Use Export-Group.ps1 to recover its group.json instead of creating a new identity.'}
Assert-GroupName $Name;Assert-GroupName $MyName
$members=@{($identity.Id)=@{Id=$identity.Id;PublicKey=$identity.PublicKey;Name=$MyName}}
foreach($path in $MemberRequests){
    $r=Read-GroupJson $path 4096
    Assert-GroupFields $r @('Schema','Kind','RequestId','PublicKey','Fingerprint','DeviceName','CreatedUtc')
    if($r.Schema -ne 1 -or $r.Kind -cne 'whispr-friend-request' -or $r.RequestId -cnotmatch '^[0-9a-f]{32}$'){throw 'Not a public friend request.'}
    $id=Get-GroupKeyId $r.PublicKey;if($id -cne $r.Fingerprint){throw 'Request fingerprint differs.'};Assert-GroupName $r.DeviceName
    $members[$id]=@{Id=$id;PublicKey=$r.PublicKey;Name=$r.DeviceName}
}
$g=@{Schema=1;Kind='whispr-exit-group';GroupId=[guid]::NewGuid().ToString('N');Name=$Name;MembershipRevision=1;Members=@($members.Values|Sort-Object Id);Nodes=@()}
Assert-GroupDocument $g;Write-GroupJson $g $Output
Write-Host "Created $Output with $($g.Members.Count) device(s). Publish your exits, then send this same group.json to your friend." -ForegroundColor Green

# On the original owner PC, reuse its known five aliases/coordinates automatically.
$configPath=Join-Path $PSScriptRoot 'my-vps.json'
if(-not (Test-Path -LiteralPath "$($identity.Home)/friend-mode.json")){
    $config=Read-GroupJson $configPath
    if($config.Servers.Count -eq 0){
        $known=@{nyc1=@('New York',40.7128,-74.006);lon1=@('London',51.5072,-0.1276);fkt1=@('Frankfurt',50.1109,8.6821);sgp1=@('Singapore',1.3521,103.8198);syd1=@('Sydney',-33.8688,151.2093)}
        $rows=[Collections.Generic.List[object]]::new()
        foreach($alias in @('nyc1','lon1','fkt1','sgp1','syd1')){
            $path=Join-Path $identity.State "profiles/$alias.json"
            if(Test-Path -LiteralPath $path){$existingPeer=Read-GroupJson $path;if($existingPeer.client_public_key -ceq $identity.PublicKey){$geo=$known[$alias];$rows.Add(@{SSH=$alias;Name=$geo[0];Latitude=$geo[1];Longitude=$geo[2];Port=$existingPeer.port})}}
        }
        $config.Servers=@($rows.ToArray());Write-GroupJson $config $configPath
        Write-Host "Your $($rows.Count) existing exit aliases were added to my-vps.json. Publish-MyVPS.ps1 can share them without entering server details again."
    }
}

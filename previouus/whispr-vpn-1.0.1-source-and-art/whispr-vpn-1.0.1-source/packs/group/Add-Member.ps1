#requires -Version 7.2
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Request,[string]$File=(Join-Path $PSScriptRoot 'group.json'))
$ErrorActionPreference='Stop'
. "$PSScriptRoot/group/Protocol.ps1";. "$PSScriptRoot/group/Local.ps1"
Assert-GroupPackage $PSScriptRoot;$identity=Get-GroupLocalIdentity;$g=Read-GroupWithLocalMerge $File $identity
$r=Read-GroupJson $Request 4096;Assert-GroupFields $r @('Schema','Kind','RequestId','PublicKey','Fingerprint','DeviceName','CreatedUtc')
if($r.Kind -cne 'whispr-friend-request' -or $r.Schema -ne 1){throw 'Not a public friend request.'}
$id=Get-GroupKeyId $r.PublicKey;if($id -cne $r.Fingerprint){throw 'Request fingerprint differs.'};Assert-GroupName $r.DeviceName
if($id -in @($g.Members|ForEach-Object Id)){Write-Host 'This device is already a member.';return}
$g.Members=@($g.Members)+@(@{Id=$id;PublicKey=$r.PublicKey;Name=$r.DeviceName});$g.MembershipRevision++
Assert-GroupDocument $g;Write-GroupJson $g $File
Write-Host 'Member added to the shared file. Each VPS owner must run Publish-MyVPS.ps1 with this file to approve/sync their own exits.' -ForegroundColor Green

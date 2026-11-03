#requires -Version 7.2
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$MemberId,[string]$File=(Join-Path $PSScriptRoot 'group.json'))
$ErrorActionPreference='Stop'
. "$PSScriptRoot/group/Protocol.ps1";. "$PSScriptRoot/group/Local.ps1"
Assert-GroupPackage $PSScriptRoot;$identity=Get-GroupLocalIdentity;$g=Read-GroupWithLocalMerge $File $identity
if($MemberId -cnotmatch '^[0-9a-f]{64}$' -or $MemberId -notin @($g.Members|ForEach-Object Id)){throw 'Use the exact member Id from group.json.'}
if($MemberId -eq $identity.Id -or $MemberId -in @($g.Nodes|ForEach-Object OwnerId)){throw 'A publishing VPS owner/current device cannot be removed through this command. Revoke guest devices only.'}
$g.Members=@($g.Members|Where-Object Id -ne $MemberId);$g.MembershipRevision++
foreach($n in $g.Nodes){[void]$n.Assignments.Remove($MemberId)}
Assert-GroupDocument $g;Write-GroupJson $g $File
Write-Host 'Member removed from the file. Access is revoked only after EACH VPS owner runs Publish-MyVPS.ps1 with this updated file. Existing unrelated/native peers are protected.' -ForegroundColor Yellow

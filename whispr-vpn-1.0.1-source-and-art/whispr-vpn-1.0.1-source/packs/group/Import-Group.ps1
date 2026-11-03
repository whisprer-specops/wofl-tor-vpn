#requires -Version 7.2
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$File=(Join-Path $PSScriptRoot 'group.json'),[switch]$NoLaunch)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/group/Protocol.ps1";. "$PSScriptRoot/group/Local.ps1"
Assert-GroupPackage $PSScriptRoot;$identity=Get-GroupLocalIdentity
if(-not (Test-Path -LiteralPath "$($identity.Home)/group-addon.json")){throw 'Run Install-Group.ps1 once before importing shared exits.'}
. "$($identity.Home)/client/Common.ps1";. "$($identity.Home)/tray/Model.ps1"
$g=Read-GroupWithLocalMerge $File $identity
$count=Import-HybridGroup $g $identity.Home $identity.State
Write-GroupJson $g (Join-Path $PSScriptRoot 'group.json')
Write-Host "Imported $count approved shared exits. Existing unshared profiles and private key retained. Open the map, choose an exit while disconnected, then Connect." -ForegroundColor Green
if($count -eq 0){Write-Warning 'No shared exit is approved for this PC yet. Its owner must Publish / Sync the current member list. The group file was saved for that exchange.'}
if(-not $NoLaunch -and (Test-Path -LiteralPath "$($identity.State)/peer.json")){& "$($identity.Home)/Open-Tray.ps1"}

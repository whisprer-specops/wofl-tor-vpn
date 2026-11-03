#requires -Version 7.2
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$Output=(Join-Path $PSScriptRoot 'group.json'))
$ErrorActionPreference='Stop'
. "$PSScriptRoot/group/Protocol.ps1";. "$PSScriptRoot/group/Local.ps1"
Assert-GroupPackage $PSScriptRoot;$identity=Get-GroupLocalIdentity
$c=Read-GroupJson (Join-Path $identity.State 'group-catalog.json');Assert-GroupDocument $c.Group
Write-GroupJson $c.Group $Output
Write-Host "Exported your locally stored public catalogue: $Output" -ForegroundColor Green

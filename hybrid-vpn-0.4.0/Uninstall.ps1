#requires -Version 7.0
#requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$DeleteLocalKeys)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\client\Common.ps1"
$homeDir=Get-HybridHome;$stateDir=Get-HybridState
if($PSScriptRoot -ne $homeDir){throw 'Run the installed uninstall script.'}
& "$homeDir\Recover.ps1"
foreach($dir in @($homeDir,$stateDir)){
    if(Test-Path -LiteralPath $dir){
        if((Get-Item -LiteralPath $dir).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected reparse point; refusing removal.'}
        if(@(Get-ChildItem -LiteralPath $dir -Recurse -Force | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Unexpected child reparse point; refusing removal.'}
    }
}
Remove-Item -LiteralPath $homeDir -Recurse -Force
if($DeleteLocalKeys){Remove-Item -LiteralPath $stateDir -Recurse -Force}
Write-Host 'Client removed. The VPS peer remains registered until explicitly revoked using server/manage.py.'
if(-not $DeleteLocalKeys){Write-Host "Private local state retained, administrators/SYSTEM only: $stateDir"}

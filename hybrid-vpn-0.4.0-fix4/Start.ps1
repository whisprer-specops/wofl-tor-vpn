#requires -Version 7.0
#requires -RunAsAdministrator
$ErrorActionPreference='Stop'
. "$PSScriptRoot\client\Common.ps1"
$homeDir=Get-HybridHome
if($PSScriptRoot -ne $homeDir){throw "Run the installed copy: & '$homeDir\Start.ps1'"}
Write-Host 'Protection will be armed for this session. Type stop to disconnect normally.' -ForegroundColor Yellow
Write-Host "Recovery from another elevated PowerShell: & '$homeDir\Recover.ps1'"
& (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -File "$homeDir\client\Session.ps1"
if($LASTEXITCODE -ne 0){throw 'Session failed. Protection may remain armed; use the printed Recover.ps1 command.'}

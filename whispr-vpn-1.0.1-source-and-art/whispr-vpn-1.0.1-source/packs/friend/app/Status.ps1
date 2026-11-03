#requires -Version 7.0
#requires -RunAsAdministrator
$ErrorActionPreference='Stop'
. "$PSScriptRoot\client\Common.ps1"
$stateDir=Get-HybridState
& (Join-Path (Get-HybridHome) 'bin\whispr-vpn-guard.exe') status
if($LASTEXITCODE -ne 0){throw 'Guard query failed.'}
$path=Join-Path $stateDir 'session.json'
if(Test-Path -LiteralPath $path){
    $s=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $s | Select-Object -Property @('State','StartedUtc','TcpExit','UdpExit','LastVerifiedUtc','TunnelGuid','Failure','FailedUtc') | Format-List
}
Write-Host 'A stored verification result is historical; ARMED alone does not mean both transports are working.'

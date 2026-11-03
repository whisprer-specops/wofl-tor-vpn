#requires -Version 7.2
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$OutputDirectory=(Get-Location).Path,[string]$DeviceName='Friend-PC')
$ErrorActionPreference='Stop'
. "$PSScriptRoot/client/Common.ps1"
. "$PSScriptRoot/friend/Protocol.ps1"
. "$PSScriptRoot/friend/Local.ps1"
$homeDir=Get-HybridHome;$stateDir=Get-HybridState
if($PSScriptRoot -ne $homeDir){throw 'Use the installed New-Request.ps1.'}
Assert-FriendInstallation $homeDir $stateDir
$key=Read-FriendJson (Join-Path $stateDir 'device-key.json')
Assert-FriendKey $key.PublicKey
$requestPath=Join-Path $stateDir 'friend-request.json'
if(Test-Path -LiteralPath $requestPath){
    $request=Read-FriendJson $requestPath 4096;Assert-FriendRequest $request
    if($request.PublicKey -cne $key.PublicKey){throw 'Saved request belongs to a different key. Private key was not changed.'}
}else{
    $request=@{Schema=1;Kind='whispr-friend-request';RequestId=[guid]::NewGuid().ToString('N');PublicKey=$key.PublicKey;Fingerprint=(Get-FriendFingerprint $key.PublicKey);DeviceName=$DeviceName;CreatedUtc=[datetime]::UtcNow.ToString('o')}
    Assert-FriendRequest $request;Write-FriendJson $request $requestPath
}
$out=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) 'friend-request.json'
Write-FriendJson $request $out
Write-Host "SEND THIS PUBLIC REQUEST TO THE VPN OWNER:`n$out" -ForegroundColor Green
Write-Host "Device: $($request.DeviceName)`nPublic-key fingerprint: $($request.Fingerprint)"
Write-Host 'The private key stays in the protected local state folder. Never send device-key.json or engine.json.'

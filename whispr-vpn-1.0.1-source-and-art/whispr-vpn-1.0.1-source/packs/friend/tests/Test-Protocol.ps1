#requires -Version 7.0
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../app/friend/Protocol.ps1"
. "$PSScriptRoot/../app/tray/Model.ps1"
function Check([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
$public=[Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('fixture-public')))
$server=[Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('fixture-server')))
$request=@{Schema=1;Kind='whispr-friend-request';RequestId='a'*32;PublicKey=$public;Fingerprint=(Get-FriendFingerprint $public);DeviceName='Friend-PC';CreatedUtc=[datetime]::UtcNow.ToString('o')}
Assert-FriendRequest $request
$peer=@{schema=1;ssh_alias='fkt1';endpoint='203.0.113.8';port=51832;server_public_key=$server;client_public_key=$public;client_ipv4='10.88.70.3/32';client_ipv6=$null;ipv6=$false;interface='wg-whispr'}
$access=@{Schema=1;Kind='whispr-friend-access';RequestId=$request.RequestId;PublicKey=$public;Fingerprint=$request.Fingerprint;DeviceName='Friend-PC';CreatedUtc=[datetime]::UtcNow.ToString('o');Exits=@($peer)}
Assert-FriendAccess $access $request
$roundtrip=$access|ConvertTo-Json -Depth 10|ConvertFrom-Json -AsHashtable
Assert-FriendAccess $roundtrip $request
foreach($field in @('RequestId','PublicKey','Fingerprint','DeviceName')){
 $bad=$access.Clone();$bad[$field]='changed';$rejected=$false
 try{Assert-FriendAccess $bad $request}catch{$rejected=$true}
 Check $rejected "Different $field was accepted."
}
foreach($change in @('extra-key','duplicate-exit','private-endpoint','wrong-device','string-port','bad-interface')){
 $bad=$access|ConvertTo-Json -Depth 10|ConvertFrom-Json -AsHashtable
 switch($change){
  'extra-key' {$bad['PrivateKey']='secret'}
  'duplicate-exit' {$bad.Exits=@($bad.Exits[0],$bad.Exits[0])}
  'private-endpoint' {$bad.Exits[0].endpoint='192.168.1.1'}
  'wrong-device' {$bad.Exits[0].client_public_key=$server}
  'string-port' {$bad.Exits[0].port='51832'}
  'bad-interface' {$bad.Exits[0].interface='eth0'}
 }
 $rejected=$false;try{Assert-FriendAccess $bad $request}catch{$rejected=$true};Check $rejected "Accepted $change"
}
$bad=$request.Clone();$bad['PrivateKey']='secret';$rejected=$false;try{Assert-FriendRequest $bad}catch{$rejected=$true};Check $rejected 'Request with extra/private fields accepted.'
$bad=$request.Clone();$bad.DeviceName="bad'; command";$rejected=$false;try{Assert-FriendRequest $bad}catch{$rejected=$true};Check $rejected 'Shell punctuation in device name accepted.'
$rejected=$false;try{Assert-FriendKey ([Convert]::ToBase64String([byte[]]::new(32)))}catch{$rejected=$true};Check $rejected 'Zero public key accepted.'
Write-Host 'Request/access protocol tests passed: exact device binding, five-exit contract, malformed/key/duplicate/private-endpoint/injection rejection.'

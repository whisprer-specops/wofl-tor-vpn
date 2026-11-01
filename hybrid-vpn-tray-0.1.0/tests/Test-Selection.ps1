#requires -Version 7.0
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../tray/Model.ps1"
function Write-HybridJson($Value,[string]$Path){$temp=$Path+'.tmp';$Value|ConvertTo-Json -Depth 20|Set-Content $temp -Encoding utf8NoBOM;Move-Item $temp $Path -Force}
$script:disconnected=$true
function Assert-TrayDisconnected {param([string]$InstallRoot);if(-not $script:disconnected){throw 'Still connected'}}
$dir=Join-Path ([IO.Path]::GetTempPath()) ('whispr-tray-selection-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path (Join-Path $dir 'profiles') -Force)
try {
    $peer=@{schema=1;ssh_alias='nyc1';endpoint='137.184.105.114';port=51832;server_public_key='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';client_public_key='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';client_ipv4='10.88.70.2/32';ipv6=$false}
    Write-HybridJson $peer (Join-Path $dir 'peer.json')
    Write-HybridJson @{PrivateKey='PRIVATE SENTINEL';PublicKey=$peer.client_public_key} (Join-Path $dir 'device-key.json')
    $original=Get-Content (Join-Path $dir 'peer.json') -Raw
    $peer.ssh_alias='lon1';$peer.endpoint='138.68.142.181'
    Write-HybridJson $peer (Join-Path $dir 'profiles/lon1.json')
    $script:disconnected=$false;$failed=$false
    try{Select-TrayExit 'lon1' 'unused' $dir}catch{$failed=$true}
    if(-not $failed -or (Get-Content (Join-Path $dir 'peer.json') -Raw) -ne $original){throw 'Connected selection must be rejected without changing active peer.'}
    $script:disconnected=$true
    Select-TrayExit 'lon1' 'unused' $dir
    $selected=Get-Content (Join-Path $dir 'peer.json') -Raw|ConvertFrom-Json
    if($selected.ssh_alias -ne 'lon1'){throw 'Disconnected selection did not activate the saved profile.'}
    if((Get-Content (Join-Path $dir 'peer-before-tray-selection.json') -Raw) -ne $original){throw 'Working profile backup missing.'}
    if((Get-Content (Join-Path $dir 'device-key.json') -Raw|ConvertFrom-Json).PrivateKey -ne 'PRIVATE SENTINEL'){throw 'Device key changed.'}
    $before=Get-Content (Join-Path $dir 'peer.json') -Raw
    $peer.client_public_key='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB='
    Write-HybridJson $peer (Join-Path $dir 'profiles/lon1.json')
    $failed=$false;try{Select-TrayExit 'lon1' 'unused' $dir}catch{$failed=$true}
    if(-not $failed -or (Get-Content (Join-Path $dir 'peer.json') -Raw) -ne $before){throw 'Wrong device profile was accepted or changed state.'}
    Write-Host 'Profile selection tests passed: connected refusal, disconnected selection, backup, device-key retention and wrong-device refusal.'
}finally{Remove-Item -LiteralPath $dir -Recurse -Force}

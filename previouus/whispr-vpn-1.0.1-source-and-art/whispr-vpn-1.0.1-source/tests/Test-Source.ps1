#requires -Version 7.2
param([string]$Payload=(Join-Path $PSScriptRoot '../payload'))
$ErrorActionPreference='Stop'
$Payload=[IO.Path]::GetFullPath($Payload)
$count=0
foreach($file in Get-ChildItem -LiteralPath $Payload -Recurse -File -Filter '*.ps1'){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($file.FullName+': '+($errors.Message -join '; '))}
    $count++
}
. "$Payload/Model.ps1"
# Existing task hosts take precedence over a newly bundled host. Mixed/custom hosts fail closed.
$folder=Join-Path ([IO.Path]::GetTempPath()) ('whispr-suite-test-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $folder)
try{
    $globalHost=Join-Path $folder 'global-pwsh.exe';$bundle=Join-Path $folder 'bundled-pwsh.exe'
    [IO.File]::WriteAllText($globalHost,'dummy')
    if((Get-SuiteHostChoice @($globalHost) $globalHost $bundle) -cne $globalHost){throw 'Existing host replaced.'}
    if((Get-SuiteHostChoice @($bundle) $globalHost $bundle) -cne $bundle){throw 'Bundled task host replaced by global host.'}
    if((Get-SuiteHostChoice @() $globalHost $bundle) -cne $globalHost){throw 'Fresh global host not preferred.'}
    foreach($hosts in @(@($globalHost,$bundle),@('/unexpected/pwsh.exe'))){
        $failed=$false;try{[void](Get-SuiteHostChoice $hosts $globalHost $bundle)}catch{$failed=$true}
        if(-not $failed){throw 'Unrecognised/mixed hosts accepted.'}
    }
    Remove-Item -LiteralPath $globalHost
    if((Get-SuiteHostChoice @() $globalHost $bundle) -cne $bundle){throw 'Portable fallback failed.'}
    # Atomic public JSON storage rejects oversize documents, without exposing their content.
    $path=Join-Path $folder 'public.json';Write-SuiteJson @{Kind='test';Name='New PC'} $path
    if((Read-SuiteJson $path).Name -cne 'New PC'){throw 'JSON round trip failed.'}
    [IO.File]::WriteAllText($path,('x'*8388609))
    $failed=$false;try{[void](Read-SuiteJson $path)}catch{$failed=$true;if($_.Exception.Message.Contains('xxxx')){throw 'Invalid JSON echoed.'}}
    if(-not $failed){throw 'Oversize JSON accepted.'}
    # Export only the public contract; reject a corrupted request with private/extra fields.
    $script:testState=Join-Path $folder 'state';$script:testCore=Join-Path $folder 'core'
    $exports=Join-Path $folder 'exports'
    foreach($dir in @($script:testState,$script:testCore,$exports)){[void](New-Item -ItemType Directory -Path $dir)}
    function Assert-SuiteCore {return $script:testCore}
    function Get-SuiteStateRoot {return $script:testState}
    $public=[Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('public-fixture')))
    Write-SuiteJson @{PublicKey=$public;PrivateKey='PRIVATE_SENTINEL'} (Join-Path $script:testState 'device-key.json')
    New-SuitePublicRequest 'Test-PC' $exports
    $output=Join-Path $exports 'friend-request.json'
    if((Get-Content -LiteralPath $output -Raw).Contains('PRIVATE_SENTINEL')){throw 'Private key exported.'}
    $stored=Join-Path $script:testState 'friend-request.json';$request=Read-SuiteJson $stored
    $request.PrivateKey='PRIVATE_SENTINEL';Write-SuiteJson $request $stored;Remove-Item -LiteralPath $output
    $failed=$false;try{New-SuitePublicRequest 'Test-PC' $exports}catch{$failed=$true}
    if(-not $failed -or (Test-Path -LiteralPath $output)){throw 'Corrupted/private request was exportable.'}
    Assert-SuiteManifest $Payload
    Write-Host "PASS: $count PowerShell sources parsed; six host-selection branches; JSON size/round-trip and private-field export rejection; installed static manifest."
}finally{Remove-Item -LiteralPath $folder -Recurse -Force}

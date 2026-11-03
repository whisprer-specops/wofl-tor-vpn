#requires -Version 7.2
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../src/Model.ps1"
$script:Fixture=Join-Path ([IO.Path]::GetTempPath()) ('whispr-setup-'+[guid]::NewGuid().ToString('N'))
function Get-SuiteCoreRoot {Join-Path $script:Fixture 'core'}
function Get-SuiteStateRoot {Join-Path $script:Fixture 'state'}
function Check($Want){if((Get-SuiteSetupPlan) -cne $Want){throw "Wrong setup plan: expected $Want"}}
function Reject {try{$null=Get-SuiteSetupPlan}catch{return};throw 'Unsafe state was accepted'}
try{
    New-Item -ItemType Directory $script:Fixture|Out-Null
    Check 'Fresh'
    New-Item -ItemType Directory (Get-SuiteStateRoot)|Out-Null
    Reject
    $state=Get-SuiteStateRoot
    Write-SuiteJson @{product='whispr-hybrid-friend';phase='installing'} (Join-Path $state 'friend-install.json')
    Check 'Resume'
    Write-SuiteJson @{Public='fixture'} (Join-Path $state 'peer.json')
    Reject
    [IO.File]::WriteAllText((Join-Path $state 'device-key.json'),'IDENTITY_SENTINEL')
    Check 'Resume'
    New-Item -ItemType Directory (Get-SuiteCoreRoot)|Out-Null
    Check 'Resume'
    Write-SuiteJson @{product='whispr-hybrid-friend';phase='ready'} (Join-Path $state 'friend-install.json')
    Check 'Existing'
    Remove-Item -LiteralPath (Get-SuiteCoreRoot) -Recurse -Force
    Check 'Resume'
    if([IO.File]::ReadAllText((Join-Path $state 'device-key.json')) -cne 'IDENTITY_SENTINEL'){throw 'Setup planning modified identity'}
    'PASS: setup planning detects fresh, orphaned, interrupted, missing-identity and existing-client states without writing device state.'
}finally{Remove-Item -LiteralPath $script:Fixture -Force -Recurse}

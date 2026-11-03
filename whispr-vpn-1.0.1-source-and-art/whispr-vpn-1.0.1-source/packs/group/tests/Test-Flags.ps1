#requires -Version 7.2
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../group/Flags.ps1"
Invoke-Expression $script:HybridFlagRuntime
$expected=@{nyc1='US';lon1='GB';fkt1='DE';sgp1='SG';syd1='AU';'exit-example'='XX'}
foreach($alias in $expected.Keys){if((Get-HybridExitFlagCountry $alias) -cne $expected[$alias]){throw "Country mismatch: $alias"}}
foreach($code in @('US','GB','DE','SG','AU','XX')){
    $b=[Convert]::FromBase64String($script:hybridExitFlagPngs[$code])
    if([Convert]::ToHexString($b[0..7]) -cne '89504E470D0A1A0A'){throw 'Invalid embedded PNG signature.'}
    if([Convert]::ToHexString($b[16..23]) -cne '0000006000000040'){throw 'Invalid embedded icon dimensions.'}
}
Clear-HybridExitFlagImages
Write-Host 'PASS: five known-country mappings, neutral fallback, embedded PNG signatures/dimensions and empty-cache disposal.'

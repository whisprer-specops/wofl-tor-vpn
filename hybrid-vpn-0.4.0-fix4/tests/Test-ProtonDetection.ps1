#requires -Version 7.0
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../client/Common.ps1"
$adapters=@([pscustomobject]@{ifIndex=41;Name='ProtonVPN';InterfaceDescription='Proton';Status='Up'})
$local=[pscustomobject]@{InterfaceIndex=41;InterfaceAlias='ProtonVPN';DestinationPrefix='10.2.0.2/32'}
$wifi=[pscustomobject]@{InterfaceIndex=11;InterfaceAlias='WiFi';DestinationPrefix='0.0.0.0/0'}
if(@(Get-HybridProtonRouteConflicts $adapters @($local,$wifi)).Count){throw 'Leftover Up adapter falsely classified as competing Internet route.'}
foreach($prefix in @('0.0.0.0/0','0.0.0.0/1','128.0.0.0/1','::/0','::/1','8000::/1')){
    $r=[pscustomobject]@{InterfaceIndex=41;InterfaceAlias='ProtonVPN';DestinationPrefix=$prefix}
    if(@(Get-HybridProtonRouteConflicts $adapters @($r)).Count -ne 1){throw "Missed Proton route $prefix"}
}
if(@(Get-HybridProtonRouteConflicts @() @($wifi)).Count){throw 'No Proton adapter should mean no Proton conflict.'}
Write-Host 'PASS: leftover Up adapter accepted; six Internet-route forms detected; other interfaces ignored.'

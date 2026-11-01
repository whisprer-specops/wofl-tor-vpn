#requires -Version 7.0
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../tray/MapModel.ps1"
function Check([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
foreach($dimensions in @(@(1000,450),@(1120,572),@(1680,858),@(2240,1144),@(3200,1800))){
    $w=$dimensions[0];$h=$dimensions[1];$layout=Get-HybridMapLayout $w $h
    $markers=@(Get-HybridMapMarkers $w $h)
    Check ($markers.Count -eq 7) 'Five world dots plus two inset dots required.'
    Check ((@($markers|Where-Object {-not $_.Inset -and $_.Alias -eq 'fkt1'})).Count -eq 1) 'Frankfurt missing from world map.'
    Check ((@($markers|Where-Object {$_.Inset -and $_.Alias -eq 'fkt1'})).Count -eq 1) 'Frankfurt missing from Europe inset.'
    foreach($marker in $markers){
        Check ($marker.X -gt 0 -and $marker.X -lt $w -and $marker.Y -gt 0 -and $marker.Y -lt $h) 'Marker lies outside the live canvas.'
        $hit=Find-HybridMapRegion $marker.X $marker.Y $w $h
        Check ($hit.Alias -eq $marker.Alias) ('Wrong click target at '+$marker.Alias)
    }
    $europe=@($markers|Where-Object Inset)
    $gap=[Math]::Sqrt([Math]::Pow($europe[0].X-$europe[1].X,2)+[Math]::Pow($europe[0].Y-$europe[1].Y,2))
    Check ($gap -gt 40*$layout.Scale) 'Europe inset dots are insufficiently separated.'
    $worldLondon=$markers|Where-Object {-not $_.Inset -and $_.Alias -eq 'lon1'}
    Check ($worldLondon.X -gt $w*0.49 -and $worldLondon.X -lt $w*0.51) 'World coordinates do not scale with width.'
    Check ($null -eq (Find-HybridMapRegion 0 0 $w $h)) 'Blank ocean must not select an endpoint.'
    $box=$layout.Inset
    Check ($null -eq (Find-HybridMapRegion ($box.X+2) ($box.Y+2) $w $h)) 'Inset border/title must not select a hidden world point.'
}
Write-Host 'Map tests passed: live-canvas scaling, five world/seven total markers, Frankfurt in both views, separate inset clicks and spacing at five sizes.'

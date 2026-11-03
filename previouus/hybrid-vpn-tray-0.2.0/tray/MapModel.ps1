#requires -Version 7.0
function Get-HybridRegions {
    return @(
        @{Alias='nyc1';Name='New York';Lon=-74.006;Lat=40.7128;Dx=-66;Dy=12},
        @{Alias='lon1';Name='London';Lon=-0.1276;Lat=51.5072;Dx=-52;Dy=-29},
        @{Alias='fkt1';Name='Frankfurt';Lon=8.6821;Lat=50.1109;Dx=10;Dy=12},
        @{Alias='sgp1';Name='Singapore';Lon=103.8198;Lat=1.3521;Dx=-72;Dy=12},
        @{Alias='syd1';Name='Sydney';Lon=151.2093;Lat=-33.8688;Dx=-56;Dy=12}
    )
}
function Get-HybridMapPoint {
    param([double]$Lon,[double]$Lat,[double]$Width,[double]$Height)
    if($Lon -lt -180 -or $Lon -gt 180 -or $Lat -lt -90 -or $Lat -gt 90 -or $Width -le 0 -or $Height -le 0){throw 'Invalid map projection input.'}
    return @{X=($Lon+180)*$Width/360;Y=(90-$Lat)*$Height/180}
}
function Find-HybridMapRegion {
    param([double]$X,[double]$Y,[double]$Width,[double]$Height,[double]$Radius=11)
    $nearest=$null;$distance=$Radius*$Radius
    foreach($region in Get-HybridRegions){
        $p=Get-HybridMapPoint $region.Lon $region.Lat $Width $Height
        $d=($X-$p.X)*($X-$p.X)+($Y-$p.Y)*($Y-$p.Y)
        if($d -le $distance){$nearest=$region;$distance=$d}
    }
    return $nearest
}

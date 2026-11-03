#requires -Version 7.0
function Get-HybridRegions {
    @(
        @{Alias='nyc1';Name='New York';Lon=-74.006;Lat=40.7128;Dx=-66;Dy=12},
        @{Alias='lon1';Name='London';Lon=-0.1276;Lat=51.5072;Dx=-100;Dy=-32},
        @{Alias='fkt1';Name='Frankfurt';Lon=8.6821;Lat=50.1109;Dx=14;Dy=12},
        @{Alias='sgp1';Name='Singapore';Lon=103.8198;Lat=1.3521;Dx=-90;Dy=16},
        @{Alias='syd1';Name='Sydney';Lon=151.2093;Lat=-33.8688;Dx=-115;Dy=16}
    )
}
function Get-HybridMapPoint {
    param([double]$Lon,[double]$Lat,[double]$Width,[double]$Height)
    if($Lon -lt -180 -or $Lon -gt 180 -or $Lat -lt -90 -or $Lat -gt 90 -or $Width -le 0 -or $Height -le 0){throw 'Invalid map projection input.'}
    @{X=($Lon+180)*$Width/360;Y=(90-$Lat)*$Height/180}
}
function Get-HybridMapLayout {
    param([double]$Width,[double]$Height)
    if($Width -le 0 -or $Height -le 0){throw 'Map dimensions must be positive.'}
    $scale=[Math]::Min(1.6,[Math]::Max(1.0,$Width/1100.0))
    # Fit the whole world exactly to the drawing surface. All coordinates are device pixels.
    $insetWidth=[Math]::Min($Width*0.34,390*$scale)
    $insetHeight=[Math]::Min($Height*0.46,260*$scale)
    $left=16*$scale;$top=$Height-$insetHeight-16*$scale
    $pad=12*$scale;$title=32*$scale
    @{
        Width=$Width;Height=$Height;Scale=$scale
        Inset=@{X=$left;Y=$top;Width=$insetWidth;Height=$insetHeight}
        Europe=@{X=$left+$pad;Y=$top+$title;Width=$insetWidth-2*$pad;Height=$insetHeight-$title-$pad;West=-15.0;East=25.0;North=62.0;South=38.0}
    }
}
function Get-HybridMapMarkers {
    param([double]$Width,[double]$Height)
    $layout=Get-HybridMapLayout $Width $Height
    foreach($region in Get-HybridRegions){
        $point=Get-HybridMapPoint $region.Lon $region.Lat $Width $Height
        @{Alias=$region.Alias;Name=$region.Name;X=$point.X;Y=$point.Y;Dx=$region.Dx*$layout.Scale;Dy=$region.Dy*$layout.Scale;Inset=$false}
    }
    $e=$layout.Europe
    foreach($region in Get-HybridRegions | Where-Object {$_.Alias -in @('lon1','fkt1')}){
        @{Alias=$region.Alias;Name=$region.Name;X=$e.X+($region.Lon-$e.West)*$e.Width/($e.East-$e.West);Y=$e.Y+($e.North-$region.Lat)*$e.Height/($e.North-$e.South);Dx=$(if($region.Alias -eq 'lon1'){-76*$layout.Scale}else{12*$layout.Scale});Dy=$(if($region.Alias -eq 'lon1'){-28*$layout.Scale}else{14*$layout.Scale});Inset=$true}
    }
}
function Find-HybridMapRegion {
    param([double]$X,[double]$Y,[double]$Width,[double]$Height,[double]$Radius=11)
    $layout=Get-HybridMapLayout $Width $Height;$box=$layout.Inset
    $inside=$X -ge $box.X -and $X -le ($box.X+$box.Width) -and $Y -ge $box.Y -and $Y -le ($box.Y+$box.Height)
    $nearest=$null;$distance=[Math]::Pow($Radius*$layout.Scale,2)
    foreach($marker in Get-HybridMapMarkers $Width $Height | Where-Object {$_.Inset -eq $inside}){
        $d=[Math]::Pow($X-$marker.X,2)+[Math]::Pow($Y-$marker.Y,2)
        if($d -le $distance){$nearest=$marker;$distance=$d}
    }
    $nearest
}

#requires -Version 7.2
[CmdletBinding()]
param([string]$Config=(Join-Path $PSScriptRoot 'my-vps.json'))
$ErrorActionPreference='Stop'
. "$PSScriptRoot/group/Protocol.ps1";Assert-GroupPackage $PSScriptRoot
$c=if(Test-Path -LiteralPath $Config){Read-GroupJson $Config}else{@{Schema=1;Servers=@()}}
$ssh=Read-Host 'SSH target for YOUR VPS (alias such as my-fra1, or user@IPv4 on port 22)'
if($ssh -cnotmatch '^(?:[A-Za-z0-9][A-Za-z0-9_.-]{0,63}|[A-Za-z0-9][A-Za-z0-9_.-]{0,31}@[0-9.]{7,15})$'){throw 'Use a configured SSH alias, or user@IPv4 with key-based SSH on port 22.'}
$name=Read-Host 'Map/menu name (for example Alex Frankfurt)';Assert-GroupName $name
$cities=@(
    @{Name='New York';Lat=40.7128;Lon=-74.006},@{Name='London';Lat=51.5072;Lon=-0.1276},@{Name='Frankfurt';Lat=50.1109;Lon=8.6821},
    @{Name='Singapore';Lat=1.3521;Lon=103.8198},@{Name='Sydney';Lat=-33.8688;Lon=151.2093},@{Name='Amsterdam';Lat=52.3676;Lon=4.9041},
    @{Name='Paris';Lat=48.8566;Lon=2.3522},@{Name='Toronto';Lat=43.6532;Lon=-79.3832},@{Name='San Francisco';Lat=37.7749;Lon=-122.4194},
    @{Name='Los Angeles';Lat=34.0522;Lon=-118.2437},@{Name='Tokyo';Lat=35.6762;Lon=139.6503},@{Name='Bangalore';Lat=12.9716;Lon=77.5946}
)
for($i=0;$i -lt $cities.Count;$i++){Write-Host "$($i+1). $($cities[$i].Name)"};Write-Host '0. Other city (enter coordinates)'
$choice=[int](Read-Host 'City number')
if($choice -eq 0){$lat=[double]::Parse((Read-Host 'Latitude (-90 to 90)'),[Globalization.CultureInfo]::InvariantCulture);$lon=[double]::Parse((Read-Host 'Longitude (-180 to 180)'),[Globalization.CultureInfo]::InvariantCulture)}
elseif($choice -ge 1 -and $choice -le $cities.Count){$lat=$cities[$choice-1].Lat;$lon=$cities[$choice-1].Lon}else{throw 'Unknown city choice.'}
if(-not [double]::IsFinite($lat) -or -not [double]::IsFinite($lon) -or $lat -lt -90 -or $lat -gt 90 -or $lon -lt -180 -or $lon -gt 180){throw 'Invalid map coordinates.'}
$p=Read-Host 'WireGuard UDP port [51832]';$port=if($p){[int]$p}else{51832};if($port -lt 1024 -or $port -gt 65535){throw 'Invalid UDP port.'}
$entry=@{SSH=$ssh;Name=$name;Latitude=$lat;Longitude=$lon;Port=$port}
$c.Servers=@($c.Servers|Where-Object SSH -ne $ssh)+@($entry);Write-GroupJson $c $Config
Write-Host "Saved $ssh in my-vps.json. No server was changed. Now run Publish-MyVPS.ps1." -ForegroundColor Green

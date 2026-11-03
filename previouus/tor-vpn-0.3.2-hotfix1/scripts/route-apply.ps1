param([string]$JsonBase64)
. "$PSScriptRoot\common.ps1"
$a = Read-TorArgs $JsonBase64
$state = Join-Path $a.StateDir 'routes.json'
if (Test-Path -LiteralPath $state) { throw 'Pending route recovery; disconnect before retrying' }
$guards = @($a.GuardIps | Where-Object { $_ })
if ($guards.Count -eq 0) { throw 'No Tor direct peers supplied; refusing a route loop' }
foreach ($g in $guards) {
    $ip = [Net.IPAddress]::Parse($g)
    if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Expected IPv4 direct peer' }
}
$adapter = Get-NetAdapter | Where-Object { $_.Name -eq $a.AdapterHint -and $_.Status -eq 'Up' } | Select-Object -First 1
if (-not $adapter) { throw "Tunnel '$($a.AdapterHint)' is not up" }
$tunIf = $adapter.ifIndex
# Windows route choice includes both route metric AND interface metric.
$choices = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore |
    Where-Object { $_.ifIndex -ne $tunIf -and $_.NextHop -ne '0.0.0.0' } |
    ForEach-Object {
        $iface = Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $_.ifIndex
        [pscustomobject]@{ Route=$_; Cost=([int]$_.RouteMetric + [int]$iface.InterfaceMetric) }
    } | Sort-Object Cost)
if ($choices.Count -eq 0) { throw 'No usable physical IPv4 default gateway found' }
$physical = $choices[0].Route
$planned = @()
foreach ($g in $guards) {
    $prefix = "$g/32"
    $exists = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $prefix -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceIndex -eq $physical.ifIndex -and $_.NextHop -eq $physical.NextHop })
    if ($exists.Count -eq 0) {
        $planned += @{ DestinationPrefix=$prefix; InterfaceIndex=$physical.ifIndex; NextHop=$physical.NextHop }
    }
}
# Two /1 routes beat all /0 routes, independent of uplink metrics. The
# physical default is preserved. We never delete someone else's host route.
foreach ($prefix in @('0.0.0.0/1','128.0.0.0/1')) {
    $planned += @{ DestinationPrefix=$prefix; InterfaceIndex=$tunIf; NextHop='0.0.0.0' }
}
Write-TorJson @{ AddedRoutes=$planned; Interface=$a.AdapterHint } $state
Set-NetIPInterface -InterfaceIndex $tunIf -AddressFamily IPv4 -Dhcp Disabled -AutomaticMetric Disabled -InterfaceMetric 1
$addr = @(Get-NetIPAddress -InterfaceIndex $tunIf -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq '10.86.1.2' })
if ($addr.Count -eq 0) { New-NetIPAddress -InterfaceIndex $tunIf -IPAddress '10.86.1.2' -PrefixLength 24 -PolicyStore ActiveStore | Out-Null }
foreach ($r in $planned) {
    New-NetRoute -DestinationPrefix $r.DestinationPrefix -InterfaceIndex $r.InterfaceIndex -NextHop $r.NextHop -RouteMetric 1 -PolicyStore ActiveStore | Out-Null
}
foreach ($r in $planned) {
    $check = @(Get-NetRoute -DestinationPrefix $r.DestinationPrefix -InterfaceIndex $r.InterfaceIndex -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $r.NextHop })
    if ($check.Count -eq 0) { throw "Route verification failed: $($r.DestinationPrefix)" }
}
Write-Host "Tunnel routes installed; $($guards.Count) Tor direct peers bypass the tunnel."

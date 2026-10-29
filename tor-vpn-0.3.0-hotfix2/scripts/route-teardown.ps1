param([string]$JsonBase64)
. "$PSScriptRoot\common.ps1"
$a = Read-TorArgs $JsonBase64
$state = Join-Path $a.StateDir 'routes.json'
if (-not (Test-Path -LiteralPath $state)) { return }
$saved = Get-Content -LiteralPath $state -Raw | ConvertFrom-Json
if ($saved.PSObject.Properties.Name -contains 'AddedRoutes') {
    foreach ($r in $saved.AddedRoutes) {
        Get-NetRoute -DestinationPrefix $r.DestinationPrefix -InterfaceIndex $r.InterfaceIndex -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -eq $r.NextHop } | Remove-NetRoute -Confirm:$false
    }
} else {
    # Migration: old versions recorded guard strings, and used 10.86.1.1
    # as the tunnel gateway. Remove only routes on the named old adapter.
    $adapter = Get-NetAdapter | Where-Object { $_.Name -eq $saved.interface } | Select-Object -First 1
    if ($adapter) {
        Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -eq '10.86.1.1' } | Remove-NetRoute -Confirm:$false
    }
    # Old guard routes lack ownership metadata: preserve them rather than
    # guessing which pre-existing administrator routes the old code replaced.
}
Remove-Item -LiteralPath $state

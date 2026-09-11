# =============================================================================
# TorVPN -- Split-tunnel routing apply
# =============================================================================
# Called by the service AFTER tun2socks has created the Wintun adapter.
# Receives JSON:
#   { "AdapterHint": "torvpn", "GuardIps": ["185.x.y.z", ...] }
#
# What it does, in order:
#   1. Wait for the Wintun adapter to appear (tun2socks may still be starting).
#   2. Find the current PHYSICAL default gateway (the real uplink).
#   3. Pin a /32 host route for each tor guard IP via that physical gateway, so
#      tor's own guard traffic never re-enters the tunnel (no routing loop).
#   4. Give the Wintun adapter an address + a low interface metric.
#   5. Point the default route at the tunnel gateway.
#
# Wintun is a layer-3 adapter (no Ethernet/ARP), so an on-link "gateway" address
# in the tunnel subnet is reached without ARP -- this is the standard tun2socks
# pattern. All routes are NON-persistent (no `route -p`), so a reboot wipes them:
# that's the emergency escape hatch if anything goes wrong.
# =============================================================================
param($jsonArgs)

$ErrorActionPreference = "Stop"

# ---- Tunnel address plan. If 10.86.1.0/24 clashes with your LAN, change these
#      three (and the matching /32 default in route-teardown.ps1). --------------
$TunIp     = "10.86.1.2"
$TunMask   = "255.255.255.0"
$TunGw     = "10.86.1.1"
$TunMetric = 1

if ($jsonArgs -is [string] -and $jsonArgs.Length -gt 0) {
    $argsObj = $jsonArgs | ConvertFrom-Json
} else {
    throw "route-apply: missing JSON args"
}
$AdapterHint = if ($argsObj.AdapterHint) { $argsObj.AdapterHint } else { "torvpn" }
# ConvertFrom-Json yields a scalar for a single-element array; normalise to array.
$GuardIps = @($argsObj.GuardIps | Where-Object { $_ })

if ($GuardIps.Count -eq 0) {
    throw "route-apply: no guard IPs supplied -- refusing to move the default route (would loop tor)"
}

# ----- 1. Wait for the Wintun adapter ----------------------------------------
$deadline = (Get-Date).AddSeconds(15)
$adapter = $null
do {
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Status -eq "Up" -and (
                $_.InterfaceDescription -like "*Wintun*" -or
                $_.Name                  -like "*$AdapterHint*"
            )
        } |
        Select-Object -First 1
    if ($adapter) { break }
    Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $deadline)

if (-not $adapter) {
    throw "route-apply: Wintun adapter not found (hint '$AdapterHint') after 15s"
}
$tunIf = $adapter.ifIndex

# ----- 2. Physical default gateway (anything that isn't our tunnel) ----------
$phys = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Where-Object { $_.ifIndex -ne $tunIf -and $_.NextHop -ne "0.0.0.0" } |
    Sort-Object RouteMetric |
    Select-Object -First 1

if (-not $phys) {
    throw "route-apply: no physical default gateway found -- cannot pin guard routes"
}
$gw     = $phys.NextHop
$physIf = $phys.ifIndex
Write-Host "[*] Physical uplink: gateway $gw via ifIndex $physIf"

# ----- 3. Pin guard /32s to the physical gateway (loop prevention) -----------
foreach ($g in $GuardIps) {
    # Idempotent: drop any stale copy first, then add.
    & route delete $g 2>$null | Out-Null
    & route add $g mask 255.255.255.255 $gw metric 1 if $physIf | Out-Null
    Write-Host "    guard $g -> $gw (physical)"
}

# ----- 4. Wintun address + low interface metric ------------------------------
& netsh interface ip set address name="$($adapter.Name)" static $TunIp $TunMask | Out-Null
& netsh interface ipv4 set interface interface="$($adapter.Name)" metric=$TunMetric | Out-Null

# ----- 5. Default route onto the tunnel --------------------------------------
& route delete 0.0.0.0 mask 0.0.0.0 $TunGw 2>$null | Out-Null
& route add 0.0.0.0 mask 0.0.0.0 $TunGw metric $TunMetric if $tunIf | Out-Null

Write-Host "[+] Split tunnel up: default -> Wintun ($($adapter.Name)), $($GuardIps.Count) guard(s) pinned to physical"

# =============================================================================
# TorVPN -- Split-tunnel routing teardown
# =============================================================================
# Called by the service on disengage, BEFORE tun2socks is stopped, and also
# defensively on service start-up (to clear a previous crash's routes).
# Receives JSON:
#   { "AdapterHint": "torvpn", "GuardIps": ["185.x.y.z", ...] }
#
# Removes the tunnel default route and the guard /32s. The PHYSICAL default
# route was never removed by apply (only out-prioritised), so deleting the
# tunnel default hands connectivity straight back to the real uplink.
#
# Safe to call repeatedly and safe to call when nothing is applied. Errors are
# swallowed on purpose -- this is cleanup, and a half-present state must still
# end clean.
# =============================================================================
param($jsonArgs)

$ErrorActionPreference = "SilentlyContinue"

# Must match route-apply.ps1.
$TunGw = "10.86.1.1"

$AdapterHint = "torvpn"
$GuardIps    = @()
if ($jsonArgs -is [string] -and $jsonArgs.Length -gt 0) {
    try {
        $argsObj = $jsonArgs | ConvertFrom-Json
        if ($argsObj.AdapterHint) { $AdapterHint = $argsObj.AdapterHint }
        $GuardIps = @($argsObj.GuardIps | Where-Object { $_ })
    } catch { }
}

# 1. Drop the tunnel default route (restores the physical default immediately).
& route delete 0.0.0.0 mask 0.0.0.0 $TunGw 2>$null | Out-Null

# 2. Belt-and-braces: remove ANY default route still sitting on the Wintun
#    adapter, in case the address plan was edited or a stale one lingers.
$adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object {
        $_.InterfaceDescription -like "*Wintun*" -or
        $_.Name                  -like "*$AdapterHint*"
    } |
    Select-Object -First 1
if ($adapter) {
    Remove-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" `
        -Confirm:$false -ErrorAction SilentlyContinue
}

# 3. Remove the guard /32 host routes we pinned to the physical gateway.
foreach ($g in $GuardIps) {
    & route delete $g 2>$null | Out-Null
}

Write-Host "[+] Split tunnel torn down (default route restored to physical uplink)"

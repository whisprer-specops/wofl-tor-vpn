# =============================================================================
# TorVPN -- Firewall apply (kill-switch)
# =============================================================================
# Called by the service when engaging. Receives a JSON arg with:
#   { "AdapterHint": "torvpn", "TorPath": "C:\Program Files\TorVPN\tor\tor.exe" }
#
# WHY THIS SCRIPT WAS REWRITTEN
# -----------------------------
# The previous version added an explicit "Block All Outbound" *rule* and then
# explicit Allow rules for tor.exe / Wintun. On Windows Filtering Platform,
# an explicit Block rule ALWAYS wins over an explicit Allow rule, so that
# design blocked tor.exe too -- tor could never reach the network, so it never
# bootstrapped, so "Connect" did nothing.
#
# The correct kill-switch pattern (what commercial VPNs use):
#   * Set the profile DefaultOutboundAction to Block. The default action is the
#     LOWEST-priority fallback -- it only applies when no explicit rule matches.
#   * Add explicit Allow rules for exactly what must escape: tor.exe (the only
#     process that legitimately talks to the public internet), loopback (the
#     tray <-> service and tun2socks <-> tor plumbing), and the Wintun adapter.
# Everything else falls through to the default -> blocked. Teardown restores
# DefaultOutboundAction = Allow.
# =============================================================================
param($jsonArgs)

$ErrorActionPreference = "Stop"

if ($jsonArgs -is [string] -and $jsonArgs.Length -gt 0) {
    $argsObj = $jsonArgs | ConvertFrom-Json
} else {
    $argsObj = $null
}

$AdapterHint = if ($argsObj) { $argsObj.AdapterHint } else { "torvpn" }
$TorPath     = if ($argsObj) { $argsObj.TorPath }     else { "" }
$group       = "TORVPN"

# ----- Clean any leftover rules from the group --------------------------------
Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue | Out-Null

# =============================================================================
# 1. ALLOW rules first, so there is never a window where tor is blocked once we
#    flip the default action.
# =============================================================================

# ----- Allow tor.exe (the only process that egresses to the real internet) ---
$torAllowed = $false
if (-not [string]::IsNullOrEmpty($TorPath) -and (Test-Path $TorPath)) {
    New-NetFirewallRule `
        -DisplayName "TORVPN Allow Tor" `
        -Group       $group `
        -Program     $TorPath `
        -Direction   Outbound `
        -Action      Allow `
        -Enabled     True | Out-Null
    $torAllowed = $true
} else {
    # Fall back to whatever's in PATH (bundled deployments should hit the branch above).
    $tor = Get-Command tor.exe -ErrorAction SilentlyContinue
    if ($tor) {
        New-NetFirewallRule `
            -DisplayName "TORVPN Allow Tor (PATH)" `
            -Group       $group `
            -Program     $tor.Path `
            -Direction   Outbound `
            -Action      Allow `
            -Enabled     True | Out-Null
        $torAllowed = $true
    }
}

if (-not $torAllowed) {
    # No tor allow rule == a kill-switch that blocks EVERYTHING including tor.
    # Refuse to flip the default action; that would just kill the user's
    # network for no benefit. Fail loud so the service reports an error.
    throw "[TORVPN] tor.exe not found (TorPath='$TorPath') -- refusing to enable kill-switch with no Tor allow rule"
}

# ----- Allow loopback (tray <-> svc, tun2socks <-> tor) ----------------------
# Windows normally exempts loopback from WFP, but make it explicit so the
# control plane is guaranteed to work under DefaultOutboundAction=Block.
New-NetFirewallRule `
    -DisplayName   "TORVPN Allow Loopback" `
    -Group         $group `
    -Direction     Outbound `
    -Action        Allow `
    -RemoteAddress "127.0.0.0/8" `
    -Enabled       True | Out-Null

# ----- Allow traffic bound to the Wintun adapter (belt-and-braces) -----------
$adapter = Get-NetAdapter |
    Where-Object {
        $_.InterfaceDescription -like "*Wintun*" -or
        $_.Name                  -like "*$AdapterHint*"
    } |
    Select-Object -First 1

if ($adapter) {
    New-NetFirewallRule `
        -DisplayName    "TORVPN Allow Wintun" `
        -Group          $group `
        -InterfaceAlias $adapter.Name `
        -Direction      Outbound `
        -Action         Allow `
        -Enabled        True | Out-Null
} else {
    Write-Warning "[!] Wintun adapter not found (hint='$AdapterHint') -- tunnel allow rule skipped"
}

# =============================================================================
# 2. Flip the kill-switch: default-deny outbound on all profiles. Explicit
#    Allow rules above are the only holes.
# =============================================================================
Set-NetFirewallProfile -All -DefaultOutboundAction Block | Out-Null

Write-Host "[+] Kill-switch active (default-deny outbound; tor + loopback + Wintun allowed) for group $group"

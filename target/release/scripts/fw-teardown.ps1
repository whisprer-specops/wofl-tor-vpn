# =============================================================================
# TorVPN -- Firewall teardown
# =============================================================================
# Called by the service on disengage. Reverses fw-apply.ps1:
#   1. Restore DefaultOutboundAction = Allow on all profiles (this is the
#      Windows factory default -- without it, disengaging would leave the
#      machine with NO internet).
#   2. Remove every rule tagged with our group.
# Safe to call repeatedly.
# =============================================================================
$ErrorActionPreference = "SilentlyContinue"
$group = "TORVPN"

# 1. Lift the kill-switch FIRST, so connectivity is restored even if rule
#    removal below hiccups.
Set-NetFirewallProfile -All -DefaultOutboundAction Allow | Out-Null

# 2. Remove our allow/loopback/wintun rules.
Get-NetFirewallRule -Group $group |
    Remove-NetFirewallRule | Out-Null

Write-Host "[+] Kill-switch lifted (default-allow restored) and group $group rules removed"

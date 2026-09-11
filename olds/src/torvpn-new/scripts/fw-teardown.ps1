# =============================================================================
# TorVPN -- Firewall teardown
# =============================================================================
# Called by the service on disengage. Removes every rule tagged with our group.
# Safe to call repeatedly.
# =============================================================================
$ErrorActionPreference = "SilentlyContinue"
$group = "TORVPN"

Get-NetFirewallRule -Group $group |
    Remove-NetFirewallRule | Out-Null

Write-Host "[+] Firewall rules removed for group $group"

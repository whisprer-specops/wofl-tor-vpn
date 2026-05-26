# =============================================================================
# TorVPN -- DNS teardown
# =============================================================================
# Called by the service on disengage. Removes NRPT rule and DNS firewall rules.
# Safe to call repeatedly.
# =============================================================================
$ErrorActionPreference = "SilentlyContinue"
$group = "TORVPN"

# Remove our NRPT rule
Get-DnsClientNrptRule |
    Where-Object { $_.DisplayName -eq "TORVPN Default" } |
    Remove-DnsClientNrptRule -Force | Out-Null

# Remove DNS-specific firewall rules
Get-NetFirewallRule -Group $group |
    Where-Object { $_.DisplayName -like "TORVPN DNS*" } |
    Remove-NetFirewallRule | Out-Null

Write-Host "[+] NRPT + DNS lock removed"

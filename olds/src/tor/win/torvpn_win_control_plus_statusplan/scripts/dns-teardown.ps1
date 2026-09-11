$group = "TORVPN"

# Remove NRPT rule
Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq "TORVPN Default" } | Remove-DnsClientNrptRule -Force -ErrorAction SilentlyContinue | Out-Null

# Remove DNS-specific firewall rules
Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "TORVPN DNS*" } | Remove-NetFirewallRule -ErrorAction SilentlyContinue | Out-Null

Write-Host "[+] NRPT + DNS lock removed"

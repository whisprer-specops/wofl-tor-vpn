$group = "TORVPN"
Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue | Out-Null
Write-Host "[+] Firewall rules removed for group $group"

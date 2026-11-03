param([string]$JsonBase64)
. "$PSScriptRoot\common.ps1"
Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'TORVPN Default' } | Remove-DnsClientNrptRule -Force
Get-TorFirewallRule -Group TORVPN | Where-Object { $_.DisplayName -like 'TORVPN DNS*' } | Remove-NetFirewallRule
Clear-DnsClientCache

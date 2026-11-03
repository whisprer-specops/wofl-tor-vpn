param([string]$JsonBase64)
. "$PSScriptRoot\common.ps1"
$a = Read-TorArgs $JsonBase64
if ($a.TorDnsPort -ne 53) { throw 'NRPT requires Tor DNSPort 53' }
$adapter = Get-NetAdapter | Where-Object { $_.Name -eq $a.AdapterHint } | Select-Object -First 1
if (-not $adapter) { throw "Tunnel adapter '$($a.AdapterHint)' not found" }
Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'TORVPN Default' } | Remove-DnsClientNrptRule -Force
Add-DnsClientNrptRule -Namespace '.' -NameServers '127.0.0.1' -DisplayName 'TORVPN Default' | Out-Null
# Only the ephemeral tunnel adapter is changed. Physical adapter DNS is intact.
Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses '127.0.0.1'
# Explicit blocks exclude loopback, because block beats allow on Windows.
# IPv6 DNS is already covered by the native-IPv6 block.
foreach ($proto in @('UDP', 'TCP')) {
    New-NetFirewallRule -DisplayName "TORVPN DNS Block Remote $proto" -Group TORVPN -Direction Outbound -Action Block -Protocol $proto -RemotePort 53 -RemoteAddress @('0.0.0.0-126.255.255.255','128.0.0.0-255.255.255.255') -Profile Any | Out-Null
}
Clear-DnsClientCache

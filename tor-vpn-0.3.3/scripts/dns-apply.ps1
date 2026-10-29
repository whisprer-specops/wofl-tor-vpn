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
# IPv6 DNS falls under default outbound Block; every TorVPN allow is IPv4-only.
$remote = @('0.0.0.0-126.255.255.255','128.0.0.0-255.255.255.255')
# Tor does not implement SOCKS UDP ASSOCIATE. Drop non-loopback UDP before
# tun2socks rather than repeatedly handing QUIC/WebRTC packets to that command.
# The display-name prefix retains compatibility with DNS teardown/recovery.
New-NetFirewallRule -DisplayName 'TORVPN DNS Block Remote UDP' -Group TORVPN -Direction Outbound -Action Block -Protocol UDP -RemotePort Any -RemoteAddress $remote -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'TORVPN DNS Block Remote TCP' -Group TORVPN -Direction Outbound -Action Block -Protocol TCP -RemotePort 53 -RemoteAddress $remote -Profile Any | Out-Null
Clear-DnsClientCache

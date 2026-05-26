# =============================================================================
# TorVPN -- DNS lock (NRPT + firewall)
# =============================================================================
# Called by the service when engaging. Receives JSON with:
#   { "AdapterHint": "torvpn", "DnsLoopback": "127.0.0.1", "TorDnsPort": 5353 }
#
# What it does:
#   1. Adds an NRPT rule routing ALL DNS lookups to the loopback resolver
#   2. Sets the Wintun adapter's DNS server explicitly to loopback (belt+braces)
#   3. Blocks outbound DNS (UDP/TCP 53) globally except to 127.0.0.1
#   4. Adds an explicit allow for Tor's DNSPort
# =============================================================================
param($jsonArgs)

$ErrorActionPreference = "Stop"

if ($jsonArgs -is [string] -and $jsonArgs.Length -gt 0) {
    $argsObj = $jsonArgs | ConvertFrom-Json
} else {
    $argsObj = $null
}

$AdapterHint = if ($argsObj) { $argsObj.AdapterHint } else { "torvpn" }
$DnsLoopback = if ($argsObj) { $argsObj.DnsLoopback } else { "127.0.0.1" }
$TorDnsPort  = if ($argsObj) { $argsObj.TorDnsPort  } else { 5353 }
$group       = "TORVPN"

# ----- NRPT: route every namespace ('.') to loopback -------------------------
Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -eq "TORVPN Default" } |
    Remove-DnsClientNrptRule -Force -ErrorAction SilentlyContinue | Out-Null

Add-DnsClientNrptRule `
    -Namespace   "." `
    -NameServers $DnsLoopback `
    -DisplayName "TORVPN Default" `
    -ErrorAction SilentlyContinue | Out-Null

# ----- Wintun adapter DNS = loopback (belt-and-braces) -----------------------
$adapter = Get-NetAdapter |
    Where-Object {
        $_.InterfaceDescription -like "*Wintun*" -or
        $_.Name                  -like "*$AdapterHint*"
    } |
    Select-Object -First 1

if ($adapter) {
    Set-DnsClientServerAddress `
        -InterfaceAlias  $adapter.Name `
        -ServerAddresses $DnsLoopback `
        -ErrorAction     SilentlyContinue | Out-Null
}

# ----- Firewall hardening: block 53 except to loopback ----------------------
Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like "TORVPN DNS*" } |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue | Out-Null

# Block all outbound :53
New-NetFirewallRule -DisplayName "TORVPN DNS Block UDP 53" -Group $group `
    -Direction Outbound -Action Block -Enabled True `
    -Protocol UDP -RemotePort 53 | Out-Null

New-NetFirewallRule -DisplayName "TORVPN DNS Block TCP 53" -Group $group `
    -Direction Outbound -Action Block -Enabled True `
    -Protocol TCP -RemotePort 53 | Out-Null

# Allow loopback :53 (some apps use the system resolver)
New-NetFirewallRule -DisplayName "TORVPN DNS Allow Loopback 53 UDP" -Group $group `
    -Direction Outbound -Action Allow -Enabled True `
    -Protocol UDP -RemoteAddress 127.0.0.1 -RemotePort 53 | Out-Null

New-NetFirewallRule -DisplayName "TORVPN DNS Allow Loopback 53 TCP" -Group $group `
    -Direction Outbound -Action Allow -Enabled True `
    -Protocol TCP -RemoteAddress 127.0.0.1 -RemotePort 53 | Out-Null

# Allow Tor's DNSPort (non-standard, usually 5353)
New-NetFirewallRule -DisplayName "TORVPN DNS Allow Tor DNSPort UDP" -Group $group `
    -Direction Outbound -Action Allow -Enabled True `
    -Protocol UDP -RemoteAddress 127.0.0.1 -RemotePort $TorDnsPort | Out-Null

New-NetFirewallRule -DisplayName "TORVPN DNS Allow Tor DNSPort TCP" -Group $group `
    -Direction Outbound -Action Allow -Enabled True `
    -Protocol TCP -RemoteAddress 127.0.0.1 -RemotePort $TorDnsPort | Out-Null

Write-Host "[+] NRPT + DNS lock applied"

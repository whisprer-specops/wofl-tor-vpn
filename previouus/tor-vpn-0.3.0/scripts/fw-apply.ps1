param([string]$JsonBase64)
. "$PSScriptRoot\common.ps1"
$a = Read-TorArgs $JsonBase64
$group = 'TORVPN'
$backup = Join-Path $a.StateDir 'firewall-backup.json'
if ($a.Mode -eq 'tunnel') {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $adapter = Get-NetAdapter | Where-Object { $_.Name -eq $a.AdapterHint -and $_.Status -eq 'Up' } | Select-Object -First 1
        if ($adapter) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $adapter) { throw "Tunnel adapter '$($a.AdapterHint)' not found" }
    New-NetFirewallRule -DisplayName 'TORVPN Allow Tunnel' -Group $group -Direction Outbound -Action Allow -InterfaceAlias $adapter.Name -Enabled True -Profile Any | Out-Null
    return
}
if (Test-Path -LiteralPath $backup) { throw 'Firewall recovery pending; run Recover-Network.ps1 first' }
$tor = Convert-Path -LiteralPath $a.TorPath
$effective = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
if (@($effective | Where-Object { $_.Enabled -ne 'True' }).Count -gt 0) {
    throw 'Windows Firewall must be enabled on all profiles before connecting'
}
# A local service cannot override domain policy. Refuse to claim protection
# while a policy-managed outbound allow rule can still bypass default-deny.
$allows = @(Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True -Direction Outbound -Action Allow |
    Where-Object { $_.Group -ne $group })
if (@($allows | Where-Object { $_.PolicyStoreSourceType -ne 'Local' }).Count -gt 0) {
    throw 'Policy-managed outbound allow rules detected; cannot safely arm this local firewall kill switch'
}
$profiles = @(Get-NetFirewallProfile | Select-Object Name, @{n='Outbound';e={[string]$_.DefaultOutboundAction}})
New-Item -ItemType Directory -Path $a.StateDir -Force | Out-Null
Write-TorJson @{ Profiles=$profiles; AllowRules=@($allows | ForEach-Object { $_.Name }) } $backup
# Persist restoration data BEFORE the first mutation.
Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule
foreach ($rule in $allows) { Disable-NetFirewallRule -Name $rule.Name | Out-Null }
New-NetFirewallRule -DisplayName 'TORVPN Allow Tor TCP' -Group $group -Program $tor -Protocol TCP -Direction Outbound -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'TORVPN Allow Loopback v4' -Group $group -RemoteAddress '127.0.0.0/8' -Direction Outbound -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'TORVPN Allow Loopback v6' -Group $group -RemoteAddress '::1' -Direction Outbound -Action Allow -Profile Any | Out-Null
# Tor carries TCP. Block native IPv6, including existing IPv6-specific routes.
New-NetFirewallRule -DisplayName 'TORVPN Block Native IPv6' -Group $group -RemoteAddress '::2-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff' -Direction Outbound -Action Block -Profile Any | Out-Null
Set-NetFirewallProfile -All -DefaultOutboundAction Block
$actual = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
if (@($actual | Where-Object { $_.DefaultOutboundAction -ne 'Block' }).Count -gt 0) {
    throw 'Effective firewall policy did not accept default-deny'
}
Write-Host 'Firewall armed; pre-existing local outbound allow rules temporarily disabled.'

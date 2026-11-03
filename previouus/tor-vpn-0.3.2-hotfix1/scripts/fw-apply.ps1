param([string]$JsonBase64)
. "$PSScriptRoot\common.ps1"
$a = Read-TorArgs $JsonBase64
$group = 'TORVPN'
$backup = Join-Path $a.StateDir 'firewall-backup.json'
# Equivalent to all IPv4 addresses, without relying on a zero-length prefix.
# Never use Any here: that would also permit native IPv6.
$ipv4 = @('0.0.0.0/1','128.0.0.0/1')
if ($a.Mode -eq 'tunnel') {
    Write-TorStep $a 'fw-apply.ps1' 'Waiting for the named tunnel adapter'
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $adapter = Get-NetAdapter | Where-Object { $_.Name -eq $a.AdapterHint -and $_.Status -eq 'Up' } | Select-Object -First 1
        if ($adapter) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $adapter) { throw "Tunnel adapter '$($a.AdapterHint)' not found" }
    Write-TorStep $a 'fw-apply.ps1' 'Adding the tunnel-interface allow rule'
    New-NetFirewallRule -DisplayName 'TORVPN Allow Tunnel' -Group $group -Direction Outbound -Action Allow -InterfaceAlias $adapter.Name -RemoteAddress $ipv4 -Enabled True -Profile Any | Out-Null
    return
}
if (Test-Path -LiteralPath $backup) { throw 'Firewall recovery pending; run Recover-Network.ps1 first' }
$tor = Convert-Path -LiteralPath $a.TorPath
Write-TorStep $a 'fw-apply.ps1' 'Reading effective firewall profiles'
$effective = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
if (@($effective | Where-Object { $_.Enabled -ne 'True' }).Count -gt 0) {
    throw 'Windows Firewall must be enabled on all profiles before connecting'
}
# A local service cannot override domain policy. Refuse to claim protection
# while a policy-managed outbound allow rule can still bypass default-deny.
Write-TorStep $a 'fw-apply.ps1' 'Reading traced outbound allow rules'
$allows = @(Get-TorFirewallRule -PolicyStore ActiveStore -TracePolicyStore -Enabled True -Direction Outbound -Action Allow |
    Where-Object { $_.Group -ne $group })
# Origin metadata is populated only when ActiveStore is queried with
# -TracePolicyStore. A missing/None origin is UNKNOWN, not proof of GPO policy.
# Keep unsupported origins explicit; never silently ignore an effective allow.
$unsupported = @($allows | Where-Object { [string]$_.PolicyStoreSourceType -notin @('Local','Dynamic') })
if ($unsupported.Count -gt 0) {
    $report = $unsupported | Select-Object Name,DisplayName,
        @{n='SourceType';e={[string]$_.PolicyStoreSourceType}},PolicyStoreSource
    Write-TorJson @($report) (Join-Path $a.StateDir 'firewall-origin-blockers.json')
    $summary = ($report | Select-Object -First 8 | ForEach-Object {
        "Name='$($_.Name)' Type='$($_.SourceType)' Store='$($_.PolicyStoreSource)'"
    }) -join '; '
    throw "Cannot safely suspend $($unsupported.Count) non-local or unclassified outbound allow rule(s). Traced origins: $summary. Full list: $($a.StateDir)\firewall-origin-blockers.json. No firewall policy has been changed."
}
Remove-Item -LiteralPath (Join-Path $a.StateDir 'firewall-origin-blockers.json') -Force -ErrorAction SilentlyContinue
Write-TorStep $a 'fw-apply.ps1' 'Saving original profiles and enabled rule identities'
$profiles = @(Get-NetFirewallProfile | Select-Object Name, @{n='Outbound';e={[string]$_.DefaultOutboundAction}})
New-Item -ItemType Directory -Path $a.StateDir -Force | Out-Null
# Live Dynamic rules must be restored through ActiveStore objects rather
# than by name in PersistentStore. Persist identity and source before mutation.
$savedRules = @($allows | Select-Object Name,
    @{n='SourceType';e={[string]$_.PolicyStoreSourceType}},PolicyStoreSource)
Write-TorJson @{ SchemaVersion=2; Profiles=$profiles; SavedRules=$savedRules;
    AllowRules=@($allows | Where-Object { [string]$_.PolicyStoreSourceType -eq 'Local' } | ForEach-Object { $_.Name }) } $backup
# Persist restoration data BEFORE the first mutation.
Write-TorStep $a 'fw-apply.ps1' 'Removing stale TorVPN rules'
Get-TorFirewallRule -Group $group | Remove-NetFirewallRule
$localNames = @($allows | Where-Object { [string]$_.PolicyStoreSourceType -eq 'Local' } | ForEach-Object { $_.Name })
$dynamicRules = @($allows | Where-Object { [string]$_.PolicyStoreSourceType -eq 'Dynamic' })
if ($localNames.Count) {
    Write-TorStep $a 'fw-apply.ps1' "Suspending $($localNames.Count) Local rules in one batch"
    Disable-NetFirewallRule -PolicyStore PersistentStore -Name $localNames | Out-Null
    Write-TorStep $a 'fw-apply.ps1' 'Local batch suspension returned'
}
if ($dynamicRules.Count) {
    Write-TorStep $a 'fw-apply.ps1' "Suspending $($dynamicRules.Count) Dynamic rules through live objects"
    Disable-NetFirewallRule -InputObject $dynamicRules | Out-Null
    Write-TorStep $a 'fw-apply.ps1' 'Dynamic suspension returned'
}
# Confirm that local disable operations actually affected the effective policy
# before permitting Tor to proceed. A silently ignored write is not protection.
Write-TorStep $a 'fw-apply.ps1' 'Verifying effective outbound allow rules after suspension'
$remaining = @(Get-TorFirewallRule -PolicyStore ActiveStore -TracePolicyStore -Enabled True -Direction Outbound -Action Allow |
    Where-Object { $_.Group -ne $group })
if ($remaining.Count -gt 0) {
    $names = ($remaining | Select-Object -First 8 -ExpandProperty Name) -join ', '
    throw "Outbound allow rules remain active after suspension: $names. Connection aborted; saved restoration data retained."
}
Write-TorStep $a 'fw-apply.ps1' 'Setting default outbound policy to Block'
Set-NetFirewallProfile -All -DefaultOutboundAction Block
Write-TorStep $a 'fw-apply.ps1' 'Verifying effective default outbound policy'
$actual = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
if (@($actual | Where-Object { $_.DefaultOutboundAction -ne 'Block' }).Count -gt 0) {
    throw 'Effective firewall policy did not accept default-deny'
}
Write-TorStep $a 'fw-apply.ps1' 'Adding IPv4-only exceptions after default-block activation'
# Create exceptions while default Block is already effective. Every allow is
# IPv4-only, including the tunnel rule. TorVPN listeners use 127.0.0.1.
New-NetFirewallRule -DisplayName 'TORVPN Allow Tor TCP' -Group $group -Program $tor -Protocol TCP -RemoteAddress $ipv4 -Direction Outbound -Action Allow -Enabled True -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'TORVPN Allow Loopback v4' -Group $group -RemoteAddress '127.0.0.0/8' -Direction Outbound -Action Allow -Enabled True -Profile Any | Out-Null
Write-TorStep $a 'fw-apply.ps1' "Verifying the effective Tor executable exception: $tor"
$torRules = @(Get-TorFirewallRule -PolicyStore ActiveStore -TracePolicyStore -Group $group -Enabled True -Direction Outbound -Action Allow |
    Where-Object { $_.DisplayName -eq 'TORVPN Allow Tor TCP' })
$applications = @($torRules | Get-NetFirewallApplicationFilter)
$armed = @{ ExpectedProgram=$tor; RequestedIPv4Scope=$ipv4; Profiles=@($actual | Select-Object Name,Enabled,DefaultOutboundAction,AllowLocalFirewallRules,AllowLocalIPsecRules,DisabledInterfaceAliases);
    TorRules=@($torRules | Select-Object Name,DisplayName,Enabled,Action,Direction,Profile,PrimaryStatus,Status,EnforcementStatus,PolicyStoreSourceType,PolicyStoreSource);
    ApplicationFilters=@($applications | Select-Object Program,Package) }
$armedPath=Join-Path $a.StateDir 'firewall-armed.json'
Write-TorJson $armed $armedPath
if ($torRules.Count -ne 1 -or $applications.Count -ne 1 -or
    -not [string]::Equals([string]$applications[0].Program, $tor, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Tor executable allow rule is missing or mismatched in ActiveStore. See firewall-armed.json; connection stopped before Tor retries.'
}
Write-TorStep $a 'fw-apply.ps1' 'Saving effective Tor address and TCP port filters'
$armed.AddressFilters=@($torRules | Get-NetFirewallAddressFilter | Select-Object LocalAddress,RemoteAddress)
Write-TorJson $armed $armedPath
$armed.PortFilters=@($torRules | Get-NetFirewallPortFilter | Select-Object Protocol,LocalPort,RemotePort)
Write-TorJson $armed $armedPath
if ($armed.PortFilters.Count -ne 1 -or [string]$armed.PortFilters[0].Protocol -notin @('TCP','6')) {
    throw 'The effective Tor exception is missing its TCP filter; see firewall-armed.json.'
}
Write-TorStep $a 'fw-apply.ps1' 'Firewall protection applied and verified'
Write-Host 'Firewall armed; pre-existing Local/Dynamic outbound allow rules temporarily disabled.'

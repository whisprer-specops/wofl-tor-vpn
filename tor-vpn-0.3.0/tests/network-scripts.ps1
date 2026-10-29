# Contract tests using mocked Windows networking cmdlets. Runs on pwsh/Linux
# without changing any real firewall, DNS, adapter, or route settings.
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSScriptRoot
$global:TestDir = Join-Path ([IO.Path]::GetTempPath()) ('torvpn-script-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $global:TestDir | Out-Null
$global:TestProfiles = @(
    [pscustomobject]@{Name='Domain'; Enabled='True'; DefaultOutboundAction='Block'},
    [pscustomobject]@{Name='Private'; Enabled='True'; DefaultOutboundAction='Allow'},
    [pscustomobject]@{Name='Public'; Enabled='True'; DefaultOutboundAction='Allow'}
)
$global:TestRules = @([pscustomobject]@{Name='preexisting-allow'; DisplayName='preexisting-allow'; Group='Other'; PolicyStoreSourceType='Local'; Enabled='True'; Direction='Outbound'; Action='Allow'})
$global:TestDnsBlocks = @()
$global:TestRouteFailure = $false
$global:TestRoutes = @([pscustomobject]@{DestinationPrefix='0.0.0.0/0'; InterfaceIndex=2; ifIndex=2; NextHop='192.0.2.1'; RouteMetric=20})
function Assert($Condition, $Message) { if (-not $Condition) { throw "FAIL: $Message" } }
function Get-NetFirewallProfile { [CmdletBinding()]param($PolicyStore) $global:TestProfiles }
function Set-NetFirewallProfile { [CmdletBinding()]param([switch]$All,$Name,$DefaultOutboundAction)
    foreach($p in $global:TestProfiles) { if ($All -or $p.Name -eq $Name) { $p.DefaultOutboundAction=$DefaultOutboundAction } }
}
function Get-NetFirewallRule { [CmdletBinding()]param($PolicyStore,$Enabled,$Direction,$Action,$Group,$Name)
    $global:TestRules | Where-Object { (-not $Group -or $_.Group -eq $Group) -and (-not $Name -or $_.Name -eq $Name) -and (-not $Enabled -or $_.Enabled -eq $Enabled) -and (-not $Direction -or $_.Direction -eq $Direction) -and (-not $Action -or $_.Action -eq $Action) }
}
function Disable-NetFirewallRule { [CmdletBinding()]param($Name) foreach($r in $global:TestRules) { if($r.Name -eq $Name) { $r.Enabled='False' } } }
function Enable-NetFirewallRule { [CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject) process { $InputObject.Enabled='True' } }
function Remove-NetFirewallRule { [CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject) process { $global:TestRules=@($global:TestRules | Where-Object { $_.Name -ne $InputObject.Name }) } }
function New-NetFirewallRule { [CmdletBinding()]param($DisplayName,$Group,$Direction,$Action,$InterfaceAlias,$Enabled='True',$Profile,$Program,$Protocol,$RemoteAddress,$RemotePort)
    $global:TestRules += [pscustomobject]@{Name=$DisplayName;DisplayName=$DisplayName;Group=$Group;Enabled=$Enabled;Direction=$Direction;Action=$Action;PolicyStoreSourceType='Local'}
    if($RemotePort -eq 53 -and $Action -eq 'Block') { $global:TestDnsBlocks += $RemoteAddress }
}
function Get-NetAdapter { [CmdletBinding()]param()
    [pscustomobject]@{Name='unrelated-wintun'; Status='Up'; ifIndex=99; InterfaceDescription='Wintun'}
    [pscustomobject]@{Name='torvpn'; Status='Up'; ifIndex=10; InterfaceDescription='tun2socks Tunnel'}
}
function Get-NetRoute { [CmdletBinding()]param($AddressFamily,$DestinationPrefix,$PolicyStore,$InterfaceIndex)
    $global:TestRoutes | Where-Object { (-not $DestinationPrefix -or $_.DestinationPrefix -eq $DestinationPrefix) -and (-not $InterfaceIndex -or $_.InterfaceIndex -eq $InterfaceIndex) }
}
function New-NetRoute { [CmdletBinding()]param($DestinationPrefix,$InterfaceIndex,$NextHop,$RouteMetric,$PolicyStore)
    if ($global:TestRouteFailure -and $DestinationPrefix -eq '128.0.0.0/1') { throw 'injected route creation failure' }
    $global:TestRoutes += [pscustomobject]@{DestinationPrefix=$DestinationPrefix;InterfaceIndex=$InterfaceIndex;ifIndex=$InterfaceIndex;NextHop=$NextHop;RouteMetric=$RouteMetric}
}
function Remove-NetRoute { [CmdletBinding(SupportsShouldProcess)]param([Parameter(ValueFromPipeline)]$InputObject) process {
    $global:TestRoutes=@($global:TestRoutes | Where-Object { -not ($_.DestinationPrefix -eq $InputObject.DestinationPrefix -and $_.InterfaceIndex -eq $InputObject.InterfaceIndex -and $_.NextHop -eq $InputObject.NextHop) })
} }
function Get-NetIPInterface { [CmdletBinding()]param($AddressFamily,$InterfaceIndex) [pscustomobject]@{InterfaceMetric=10} }
function Set-NetIPInterface { [CmdletBinding()]param($InterfaceIndex,$AddressFamily,$Dhcp,$AutomaticMetric,$InterfaceMetric) }
function Get-NetIPAddress { [CmdletBinding()]param($InterfaceIndex,$AddressFamily) }
function New-NetIPAddress { [CmdletBinding()]param($InterfaceIndex,$IPAddress,$PrefixLength,$PolicyStore) }
function Get-DnsClientNrptRule { [CmdletBinding()]param() }
function Add-DnsClientNrptRule { [CmdletBinding()]param($Namespace,$NameServers,$DisplayName) }
function Remove-DnsClientNrptRule { [CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject,[switch]$Force) process {} }
function Set-DnsClientServerAddress { [CmdletBinding()]param($InterfaceIndex,$ServerAddresses) Assert ($InterfaceIndex -eq 10) 'DNS must target exact adapter, not unrelated Wintun' }
function Clear-DnsClientCache { [CmdletBinding()]param() }
function Run-Script($Name,$ArgsObject) {
    $ArgsObject.StateDir=$global:TestDir
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($ArgsObject | ConvertTo-Json -Compress)))
    & "$root/scripts/$Name" -JsonBase64 $encoded
}
try {
    $exe=Join-Path $global:TestDir 'fake-tor.exe'; New-Item -ItemType File -Path $exe | Out-Null
    Run-Script 'fw-apply.ps1' @{Mode='arm'; AdapterHint='torvpn'; TorPath=$exe}
    Assert ($global:TestRules[0].Enabled -eq 'False') 'existing allow rules must not bypass default block'
    Assert (@($global:TestProfiles | Where-Object DefaultOutboundAction -ne Block).Count -eq 0) 'all profiles must be blocked'
    Run-Script 'fw-apply.ps1' @{Mode='tunnel';AdapterHint='torvpn'}
    Run-Script 'dns-apply.ps1' @{AdapterHint='torvpn';TorDnsPort=53}
    Assert ($global:TestDnsBlocks.Count -eq 4) 'DNS must block two non-loopback ranges for both protocols'
    Assert (-not ($global:TestDnsBlocks -contains 'Any')) 'DNS block must not include loopback'
    Run-Script 'route-apply.ps1' @{AdapterHint='torvpn';GuardIps=@('198.51.100.8')}
    Assert (@($global:TestRoutes | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/1','128.0.0.0/1') -and $_.InterfaceIndex -eq 10 }).Count -eq 2) 'both half-default routes must use exact tunnel'
    Assert (@($global:TestRoutes | Where-Object DestinationPrefix -eq '0.0.0.0/0').Count -eq 1) 'physical default route must survive'
    Run-Script 'route-teardown.ps1' @{}
    Assert ($global:TestRoutes.Count -eq 1) 'teardown must remove owned routes and preserve physical default'
    Run-Script 'dns-teardown.ps1' @{}
    Run-Script 'fw-teardown.ps1' @{}
    Assert ($global:TestRules.Count -eq 1 -and $global:TestRules[0].Enabled -eq 'True') 'existing rule must be restored'
    Assert ($global:TestProfiles[0].DefaultOutboundAction -eq 'Block') 'pre-existing Block policy must remain Block'
    Assert ($global:TestProfiles[1].DefaultOutboundAction -eq 'Allow') 'pre-existing Allow policy must be restored'
    Assert (-not (Test-Path "$global:TestDir/firewall-backup.json")) 'recovery metadata removed only after restoration'
    Write-Host 'PASS: firewall/DNS/route contracts and restoration'
    $global:TestRouteFailure = $true
    $failed = $false
    try { Run-Script 'route-apply.ps1' @{AdapterHint='torvpn';GuardIps=@('198.51.100.8')} } catch { $failed=$true }
    Assert $failed 'route command errors must fail connection setup'
    Assert (Test-Path "$global:TestDir/routes.json") 'partial mutation must retain recovery plan'
    Run-Script 'route-teardown.ps1' @{}
    Assert ($global:TestRoutes.Count -eq 1) 'partial route failure must be recoverable without deleting physical default'
    Write-Host 'PASS: partial route failure retains recovery state and restores owned routes' 
} finally { Remove-Item -LiteralPath $global:TestDir -Recurse -Force }

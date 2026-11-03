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
$global:TestIgnoreDisable = $false
$global:TestDenyDynamicDisable = $false
$global:TestIgnoreDynamicEnable = $false
$global:TestFirewallQueryFailure = $null
$global:TestRoutes = @([pscustomobject]@{DestinationPrefix='0.0.0.0/0'; InterfaceIndex=2; ifIndex=2; NextHop='192.0.2.1'; RouteMetric=20})
function Assert($Condition, $Message) { if (-not $Condition) { throw "FAIL: $Message" } }
function Get-NetFirewallProfile { [CmdletBinding()]param($PolicyStore) $global:TestProfiles }
function Set-NetFirewallProfile { [CmdletBinding()]param([switch]$All,$Name,$DefaultOutboundAction)
    foreach($p in $global:TestProfiles) { if ($All -or $p.Name -eq $Name) { $p.DefaultOutboundAction=$DefaultOutboundAction } }
}
function Get-NetFirewallRule { [CmdletBinding()]param($PolicyStore,[switch]$TracePolicyStore,$Enabled,$Direction,$Action,$Group,$Name)
    if ($global:TestFirewallQueryFailure) {
        $category=[System.Management.Automation.ErrorCategory]::PermissionDenied
        $id='InjectedAccessDenied'
        if ($global:TestFirewallQueryFailure -eq 'Provider') { $category=[System.Management.Automation.ErrorCategory]::ResourceUnavailable; $id='InjectedCimProviderFailure' }
        if ($global:TestFirewallQueryFailure -eq 'OtherNotFound') { $category=[System.Management.Automation.ErrorCategory]::ObjectNotFound; $id='DifferentObjectNotFound' }
        if ($global:TestFirewallQueryFailure -eq 'WrongCategory') { $id='CmdletizationQuery_NotFound' }
        $record=New-Object System.Management.Automation.ErrorRecord ([InvalidOperationException]::new('Injected real query failure')), $id, $category, $null
        $PSCmdlet.ThrowTerminatingError($record)
    }
    $matched = @($global:TestRules | Where-Object { ($PolicyStore -ne 'PersistentStore' -or $_.PolicyStoreSourceType -eq 'Local') -and (-not $Group -or $_.Group -eq $Group) -and (-not $Name -or $_.Name -eq $Name) -and (-not $Enabled -or $_.Enabled -eq $Enabled) -and (-not $Direction -or $_.Direction -eq $Direction) -and (-not $Action -or $_.Action -eq $Action) })
    if ($matched.Count -eq 0) {
        Write-Error -Message 'No matching MSFT_NetFirewallRule objects found by CIM query' -ErrorId 'CmdletizationQuery_NotFound' -Category ObjectNotFound
        return
    }
    $matched | ForEach-Object {
        $copy = $_ | Select-Object *
        if ($PolicyStore -eq 'ActiveStore' -and -not $TracePolicyStore) { $copy.PolicyStoreSourceType = 'None' }
        $origin = if ($_.PolicyStoreSourceType -eq 'Dynamic') { 'ActiveStore' } else { 'PersistentStore' }
        $copy | Add-Member -NotePropertyName PolicyStoreSource -NotePropertyValue $origin -Force
        $copy | Add-Member -NotePropertyName TestQueryStore -NotePropertyValue $PolicyStore -Force
        $copy
    }
}
$global:TestDisableCalls=0; $global:TestEnableCalls=0
function Disable-NetFirewallRule {
    [CmdletBinding()]param($PolicyStore,[string[]]$Name,[object[]]$InputObject)
    $global:TestDisableCalls++
    if ($global:TestIgnoreDisable) { return }
    if ($InputObject) {
        foreach ($obj in $InputObject) {
            Assert ($obj.PolicyStoreSourceType -eq 'Dynamic') 'dynamic suspension must use actual dynamic object'
            Assert ($obj.TestQueryStore -eq 'ActiveStore') 'dynamic suspension must originate from ActiveStore'
        }
        if ($global:TestDenyDynamicDisable) { throw 'Injected dynamic disable denial' }
        $Name=@($InputObject | ForEach-Object { $_.Name })
    } else { Assert ($PolicyStore -eq 'PersistentStore') 'local rule writes must target PersistentStore' }
    foreach ($r in $global:TestRules) { if ($Name -contains $r.Name) { $r.Enabled='False' } }
}
function Enable-NetFirewallRule {
    [CmdletBinding()]param([Parameter(ValueFromPipeline)][object[]]$InputObject)
    process {
        $global:TestEnableCalls++
        foreach ($obj in $InputObject) {
            if ($obj.PolicyStoreSourceType -eq 'Dynamic') {
                Assert ($obj.TestQueryStore -eq 'ActiveStore') 'dynamic restoration must use ActiveStore object'
                if ($global:TestIgnoreDynamicEnable) { continue }
            }
            foreach ($r in $global:TestRules) {
                if ($r.Name -eq $obj.Name -and $r.PolicyStoreSourceType -eq $obj.PolicyStoreSourceType) { $r.Enabled='True' }
            }
        }
    }
}
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
    Assert ((Get-NetFirewallRule -PolicyStore ActiveStore)[0].PolicyStoreSourceType -eq 'None') 'untraced origin must reproduce Windows default None'
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
    foreach ($kind in @('GroupPolicy','Generated','Hardcoded','None')) {
        $global:TestRules[0].PolicyStoreSourceType=$kind
        $failed=$false; $message=''
        try { Run-Script 'fw-apply.ps1' @{Mode='arm';AdapterHint='torvpn';TorPath=$exe} } catch { $failed=$true; $message=$_.Exception.Message }
        Assert $failed "unsupported origin $kind must not silently pass"
        Assert ($message.Contains("Type='$kind'")) 'error must identify traced source type'
        Assert ($global:TestRules[0].Enabled -eq 'True') 'unsupported origin must be rejected before changing rules'
        Assert ($global:TestProfiles[1].DefaultOutboundAction -eq 'Allow') 'unsupported origin must not change policy'
        Assert (-not (Test-Path "$global:TestDir/firewall-backup.json")) 'unsupported origin must not claim a mutation occurred'
        Assert (Test-Path "$global:TestDir/firewall-origin-blockers.json") 'unsupported origins must have an actionable diagnostic'
    }
    $global:TestRules[0].PolicyStoreSourceType='Local'
    $global:TestIgnoreDisable=$true
    $failed=$false
    try { Run-Script 'fw-apply.ps1' @{Mode='arm';AdapterHint='torvpn';TorPath=$exe} } catch { $failed=$true }
    Assert $failed 'ignored local suspension must be detected by effective-policy reread'
    Assert (Test-Path "$global:TestDir/firewall-backup.json") 'failed suspension must retain restoration metadata'
    Run-Script 'fw-teardown.ps1' @{}
    Write-Host 'PASS: traced Local accepted; unsupported origins diagnosed; ignored suspension rejected'
    $global:TestIgnoreDisable=$false
    $global:TestRules += [pscustomobject]@{Name='ics-dynamic';DisplayName='Internet Connection Sharing (SharedAccess-Out)';Group='';PolicyStoreSourceType='Dynamic';Enabled='True';Direction='Outbound';Action='Allow'}
    $global:TestRules += [pscustomobject]@{Name='already-disabled-dynamic';DisplayName='Disabled runtime rule';Group='';PolicyStoreSourceType='Dynamic';Enabled='False';Direction='Outbound';Action='Allow'}
    Run-Script 'fw-apply.ps1' @{Mode='arm';AdapterHint='torvpn';TorPath=$exe}
    Assert (($global:TestRules | Where-Object Name -eq 'ics-dynamic').Enabled -eq 'False') 'ICS runtime allow must be suspended'
    $saved = Get-Content "$global:TestDir/firewall-backup.json" -Raw | ConvertFrom-Json
    Assert (@($saved.SavedRules | Where-Object SourceType -eq 'Dynamic').Count -eq 1) 'backup must distinguish originally-enabled Dynamic identity'
    Run-Script 'fw-teardown.ps1' @{}
    Assert (($global:TestRules | Where-Object Name -eq 'ics-dynamic').Enabled -eq 'True') 'dynamic rule must be restored through live ActiveStore object'
    Assert (($global:TestRules | Where-Object Name -eq 'already-disabled-dynamic').Enabled -eq 'False') 'originally disabled rule must stay disabled'
    Write-Host 'PASS: ICS Dynamic rule suspends/restores; pre-existing disabled Dynamic rule stays disabled'

    $global:TestDenyDynamicDisable=$true
    $failed=$false
    try { Run-Script 'fw-apply.ps1' @{Mode='arm';AdapterHint='torvpn';TorPath=$exe} } catch { $failed=$true }
    Assert $failed 'provider refusal must abort setup'
    Assert (Test-Path "$global:TestDir/firewall-backup.json") 'provider failure must keep typed restoration data'
    $global:TestDenyDynamicDisable=$false
    Run-Script 'fw-teardown.ps1' @{}
    Assert ($global:TestRules[0].Enabled -eq 'True') 'local rule changed before dynamic refusal must be restored'
    Assert (($global:TestRules | Where-Object Name -eq 'ics-dynamic').Enabled -eq 'True') 'dynamic rule must remain enabled after rollback'
    Write-Host 'PASS: partial suspension failure restores local and dynamic state'

    Run-Script 'fw-apply.ps1' @{Mode='arm';AdapterHint='torvpn';TorPath=$exe}
    $global:TestIgnoreDynamicEnable=$true
    $failed=$false
    try { Run-Script 'fw-teardown.ps1' @{} } catch { $failed=$true }
    Assert $failed 'ignored Dynamic restoration must fail verification'
    Assert (Test-Path "$global:TestDir/firewall-backup.json") 'failed restoration must keep backup for retry'
    $global:TestIgnoreDynamicEnable=$false
    Run-Script 'fw-teardown.ps1' @{}
    Assert (-not (Test-Path "$global:TestDir/firewall-backup.json")) 'successful retry must finish restoration'
    Write-Host 'PASS: ignored Dynamic restoration retains backup and succeeds on retry'

    Run-Script 'fw-apply.ps1' @{Mode='arm';AdapterHint='torvpn';TorPath=$exe}
    # The runtime owner/session goes away. A different local rule then happens
    # to have the old name. Neither recreate nor enable it as the dynamic rule.
    $global:TestRules = @($global:TestRules | Where-Object Name -ne 'ics-dynamic')
    $global:TestRules += [pscustomobject]@{Name='ics-dynamic';DisplayName='New unrelated local rule';Group='';PolicyStoreSourceType='Local';Enabled='False';Direction='Outbound';Action='Allow'}
    Run-Script 'fw-teardown.ps1' @{}
    Assert (($global:TestRules | Where-Object Name -eq 'ics-dynamic').Enabled -eq 'False') 'expired dynamic identity must not enable unrelated replacement'
    Assert (@($global:TestRules | Where-Object PolicyStoreSourceType -eq 'Dynamic').Count -eq 1) 'expired dynamic rule must not be recreated'
    Write-Host 'PASS: expired Dynamic rule is not recreated or confused with a local replacement'

    # Recovery metadata from pre-hotfix2 must still be accepted.
    $global:TestRules[0].Enabled='False'
    @{Profiles=@(@{Name='Private';Outbound='Allow'});AllowRules=@('preexisting-allow')} | ConvertTo-Json -Depth 5 | Set-Content "$global:TestDir/firewall-backup.json" -Encoding UTF8
    Run-Script 'fw-teardown.ps1' @{}
    Assert ($global:TestRules[0].Enabled -eq 'True') 'legacy string-only backup must still restore local rule'
    Write-Host 'PASS: 0.3.0 and hotfix1 backups remain recoverable'
    $global:TestRules=@(0..186 | ForEach-Object {
        [pscustomobject]@{Name="bulk-$_";DisplayName="Local rule $_";Group='Other';PolicyStoreSourceType='Local';Enabled='True';Direction='Outbound';Action='Allow'}
    })
    $global:TestRules += [pscustomobject]@{Name='ics-bulk';DisplayName='SharedAccess-Out';Group='';PolicyStoreSourceType='Dynamic';Enabled='True';Direction='Outbound';Action='Allow'}
    $global:TestDisableCalls=0; $global:TestEnableCalls=0
    Run-Script 'fw-apply.ps1' @{Mode='arm';AdapterHint='torvpn';TorPath=$exe}
    Assert ($global:TestDisableCalls -eq 2) '187 Local plus 1 Dynamic rules must use two cmdlet invocations, not 188'
    Run-Script 'fw-teardown.ps1' @{}
    Assert ($global:TestEnableCalls -eq 2) 'restoration must use two batch calls, not 188'
    Assert (@($global:TestRules | Where-Object Enabled -ne 'True').Count -eq 0) 'every saved rule must be restored'
    $steps=Get-Content "$global:TestDir/admin-steps.log" -Raw
    Assert ($steps.Contains('Suspending 187 Local rules in one batch')) 'actual batch stage must be persisted'
    Assert ($steps.Contains('Firewall recovery completed and verified')) 'verified recovery checkpoint must be persisted'
    Write-Host 'PASS: 187 Local + 1 Dynamic rules use two suspension and two restoration calls with persistent checkpoints'
    . "$root/scripts/common.ps1"
    $rawNoMatchFailed=$false
    try { Get-NetFirewallRule -PolicyStore ActiveStore -Name 'absent-rule' -ErrorAction Stop | Out-Null }
    catch {
        $rawNoMatchFailed=$true
        Assert ($_.FullyQualifiedErrorId -eq 'CmdletizationQuery_NotFound,Get-NetFirewallRule') 'mock must emit the actual observed error ID'
    }
    Assert $rawNoMatchFailed 'raw native-style missing query must raise an error'
    $empty=@(Get-TorFirewallRule -PolicyStore ActiveStore -Name 'absent-rule')
    Assert ($empty.Count -eq 0) 'exact native missing-result condition must normalize to an empty set'
    foreach ($failureType in @('Access','Provider','OtherNotFound','WrongCategory')) {
        $global:TestFirewallQueryFailure=$failureType
        $failed=$false
        try { Get-TorFirewallRule -PolicyStore ActiveStore | Out-Null } catch { $failed=$true }
        Assert $failed "real query error $failureType must propagate"
    }
    $global:TestFirewallQueryFailure=$null
    Write-Host 'PASS: native empty-result error normalizes to zero; access/provider/unrelated errors propagate'

    $global:TestRules=@()
    Run-Script 'fw-apply.ps1' @{Mode='arm';AdapterHint='torvpn';TorPath=$exe}
    Run-Script 'fw-teardown.ps1' @{}
    Assert ($global:TestRules.Count -eq 0) 'initially empty firewall rule set must remain empty after recovery'
    Write-Host 'PASS: empty initial rule set applies and recovers without a false query failure'




} finally { Remove-Item -LiteralPath $global:TestDir -Recurse -Force }

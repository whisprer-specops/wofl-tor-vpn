# Portable contract tests: never call Windows auditpol, Security log or netsh.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. "$root/scripts/common.ps1"
. "$root/scripts/audit-common.ps1"
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
$dir=Join-Path ([IO.Path]::GetTempPath()) ('torvpn-audit-tests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
$context=[pscustomobject]@{StateDir=$dir}
$script:flags=0; $script:ignored=$false
function Get-TorAuditFlags { return $script:flags }
function Set-TorAuditFlags([uint32]$Flags) { if (-not $script:ignored) { $script:flags=$Flags } }
try {
    # Compile interop declarations without invoking platform DLLs.
    Initialize-TorAuditApi
    Assert ([Runtime.InteropServices.Marshal]::SizeOf([type][TorVpnAudit.Policy]) -eq 36) 'AUDIT_POLICY_INFORMATION ABI must be GUID/u32/GUID (36 bytes)'
    foreach ($original in 0..3) {
        $script:flags=$original
        Start-TorAudit $context 'C:\Program Files\TorVPN\tor\tor.exe'
        Assert ($script:flags -eq ($original -bor 2)) 'failure audit enabled without dropping success audit'
        Restore-TorAudit $context
        Assert ($script:flags -eq $original) 'exact original success/failure settings restored'
        Assert (-not (Test-Path "$dir/audit-backup.json")) 'remove audit backup only after verification'
    }
    Write-Host 'PASS: audit ABI compiles; all four audit modes enable and restore exactly'
    $script:flags=0
    Start-TorAudit $context 'C:\Tor\tor.exe'
    $script:flags=3
    $failed=$false
    try { Restore-TorAudit $context } catch { $failed=$true }
    Assert ($failed -and $script:flags -eq 3 -and (Test-Path "$dir/audit-backup.json")) 'external policy edit must not be overwritten'
    $script:flags=2
    Restore-TorAudit $context
    Assert ($script:flags -eq 0) 'retry restores once applied state is present again'
    Write-Host 'PASS: preserve external audit-policy edits and retained backup supports retry'
    $script:ignored=$true
    $failed=$false
    try { Start-TorAudit $context 'C:\Tor\tor.exe' } catch { $failed=$true }
    Assert ($failed -and (Test-Path "$dir/audit-backup.json")) 'ignored audit enable must retain recovery data'
    Restore-TorAudit $context
    $script:ignored=$false
    Start-TorAudit $context 'C:\Tor\tor.exe'
    $script:ignored=$true
    $failed=$false
    try { Restore-TorAudit $context } catch { $failed=$true }
    Assert ($failed -and (Test-Path "$dir/audit-backup.json")) 'ignored audit restore must retain backup'
    $script:ignored=$false
    Restore-TorAudit $context
    Write-Host 'PASS: audit provider refusal detected; original policy remains recoverable'
    function Event([string]$ProcessText,[string]$Application,[string]$Filter) {
        $object=[pscustomobject]@{Id=5157;TimeCreated=[DateTime]::UtcNow;EventText="<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><EventData><Data Name='ProcessID'>$ProcessText</Data><Data Name='Application'>$Application</Data><Data Name='FilterRTID'>$Filter</Data><Data Name='FilterOrigin'>test-block-rule</Data></EventData></Event>"}
        $object | Add-Member ScriptMethod ToXml { return $this.EventText }
        return $object
    }
    $events=@((Event '1234' '\device\harddiskvolume3\tor.exe' '55'),(Event '0x4d2' '\device\harddiskvolume3\tor.exe' '66'),(Event '1234' '\device\harddiskvolume3\other.exe' '77'),(Event '1235' '\device\harddiskvolume3\tor.exe' '88'))
    $selected=@(Convert-TorBlockEvents $events 1234)
    Assert ($selected.Count -eq 2) 'capture only the attempted Tor process; accept decimal and hex PID forms'
    Assert ($selected[0].Data['FilterOrigin'] -eq 'test-block-rule') 'preserve blocking origin from event XML'
    [xml]$dump='<wfp xmlns="urn:test"><filters><item><filterId> 55 </filterId><displayData><name>Rule block</name></displayData></item><item><FilterID>66</FilterID><displayData><name>Default block</name></displayData></item><item><filterId>99</filterId><displayData><name>Unrelated</name></displayData></item></filters></wfp>'
    $matched=@(Get-TorMatchingFilters $dump @('55','66','55',"' or 1=1"))
    Assert ($matched.Count -eq 2) 'exact numeric WFP filter IDs only, unique and injection-safe'
    Assert ($matched[0].Xml.Contains('Rule block')) 'retain complete matched filter evidence'
    Write-Host 'PASS: exact-process event selection and matching WFP filter IDs exclude unrelated activity'
    function Get-NetFirewallProfile { [CmdletBinding()]param($PolicyStore) [pscustomobject]@{Name='Public';DefaultOutboundAction='Block';AllowLocalFirewallRules='False'} }
    function Get-TorFirewallRule { [CmdletBinding()]param($PolicyStore,[switch]$TracePolicyStore,$Group,$Enabled,$Direction,$Action)
        if ($Group) { [pscustomobject]@{Name='tor-allow';DisplayName='TORVPN Allow Tor TCP';Action='Allow';EnforcementStatus='LocalFirewallRulesDisallowed'} }
        else { [pscustomobject]@{Name='existing-block';DisplayName='Example block';Action='Block'} }
    }
    foreach ($kind in @('Application','Address','Port','Service','Interface','Security')) {
        Set-Item -Path "Function:Get-NetFirewall${kind}Filter" -Value { [CmdletBinding()]param([Parameter(ValueFromPipeline)]$Rule) process { [pscustomobject]@{InstanceID=$Rule.Name;Program='C:\Tor\tor.exe';RemoteAddress='0.0.0.0/0'} } }
    }
    $script:fixtureEvents=$events
    $script:fixtureDump=$dump
    function Get-WinEvent { [CmdletBinding()]param($FilterHashtable,$MaxEvents) return $script:fixtureEvents }
    $script:dumpFails=$false
    function Export-TorWfpState([string]$Destination) {
        if ($script:dumpFails) { throw 'injected WFP dump refusal' }
        $script:fixtureDump.OuterXml | Set-Content -LiteralPath $Destination
    }
    Write-TorJson @{process_id=1234;path='C:\Tor\tor.exe';started_utc=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()} "$dir/tor-start.json"
    Save-TorFirewallEvidence $context
    $evidence=Get-Content "$dir/firewall-evidence.json" -Raw | ConvertFrom-Json
    Assert ($evidence.TorRules[0].EnforcementStatus -eq 'LocalFirewallRulesDisallowed') 'retain enforcement reason before rule teardown'
    Assert ($evidence.Profiles[0].AllowLocalFirewallRules -eq 'False') 'retain policy merge setting'
    Assert ($evidence.BlockEvents.Count -eq 2 -and $evidence.MatchedFilters.Count -eq 2) 'full evidence capture must correlate selected events and dump filters'
    $script:dumpFails=$true
    Save-TorFirewallEvidence $context
    $evidence=Get-Content "$dir/firewall-evidence.json" -Raw | ConvertFrom-Json
    Assert ($evidence.BlockEvents.Count -eq 2 -and $evidence.Errors[-1].Contains('injected WFP dump refusal')) 'save event/rule evidence even when WFP dump fails'
    Write-Host 'PASS: full evidence capture preserves enforcement, merge policy and blocking filters; survives WFP dump failure'
} finally { Remove-Item -LiteralPath $dir -Recurse -Force }

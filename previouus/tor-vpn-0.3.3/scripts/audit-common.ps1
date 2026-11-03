# Diagnostic helpers. No firewall rule or security product is disabled here.
function Initialize-TorAuditApi {
    if ('TorVpnAudit.PolicyApi' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace TorVpnAudit {
    [StructLayout(LayoutKind.Sequential)]
    public struct Policy {
        public Guid Subcategory;
        public uint Flags;
        public Guid Category;
    }
    public static class PolicyApi {
        [DllImport("advapi32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.U1)]
        private static extern bool AuditQuerySystemPolicy([In] Guid[] ids, uint count, out IntPtr result);
        [DllImport("advapi32.dll")]
        private static extern void AuditFree(IntPtr buffer);
        public static uint Read() {
            IntPtr buffer;
            var ids = new [] { new Guid("0CCE9226-69AE-11D9-BED3-505054503030") };
            if (!AuditQuerySystemPolicy(ids, 1, out buffer))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try { return ((Policy)Marshal.PtrToStructure(buffer, typeof(Policy))).Flags & 3u; }
            finally { AuditFree(buffer); }
        }
    }
}
'@
}
function Get-TorAuditFlags {
    Initialize-TorAuditApi
    return [TorVpnAudit.PolicyApi]::Read()
}
function Set-TorAuditFlags([uint32]$Flags) {
    $success = if ($Flags -band 1) { '/success:enable' } else { '/success:disable' }
    $failure = if ($Flags -band 2) { '/failure:enable' } else { '/failure:disable' }
    & "$env:SystemRoot\System32\auditpol.exe" /set '/subcategory:{0CCE9226-69AE-11D9-BED3-505054503030}' $success $failure | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "auditpol failed with exit code $LASTEXITCODE" }
}
function Start-TorAudit($Context, [string]$TorPath) {
    $backup = Join-Path $Context.StateDir 'audit-backup.json'
    if (Test-Path -LiteralPath $backup) { throw 'Pending audit-policy recovery; restore it before starting a new capture.' }
    # Start time is saved even when policy access is denied. Existing Security
    # events can still be useful; inability to audit must never bypass recovery.
    Write-TorJson @{ StartedUtc=[DateTime]::UtcNow.ToString('o'); TorPath=$TorPath } (Join-Path $Context.StateDir 'audit-session.json')
    Remove-Item -LiteralPath (Join-Path $Context.StateDir 'firewall-evidence.json') -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Context.StateDir 'tor-start.json') -ErrorAction SilentlyContinue
    foreach ($name in @('verification.json','firewall-events.json','route-applied.json')) {
        Remove-Item -LiteralPath (Join-Path $Context.StateDir $name) -ErrorAction SilentlyContinue
    }
    $before = Get-TorAuditFlags
    if ($before -band 2) { return }
    $applied = $before -bor 2
    Write-TorJson @{ OriginalFlags=$before; AppliedFlags=$applied } $backup
    Set-TorAuditFlags $applied
    if ((Get-TorAuditFlags) -ne $applied) { throw 'Windows did not enable WFP connection failure auditing.' }
}
function Restore-TorAudit($Context) {
    $backup = Join-Path $Context.StateDir 'audit-backup.json'
    if (-not (Test-Path -LiteralPath $backup)) { return }
    $saved = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
    $current = Get-TorAuditFlags
    if ($current -ne $saved.OriginalFlags) {
        if ($current -ne $saved.AppliedFlags) {
            throw 'Audit policy changed outside TorVPN; original audit backup retained rather than overwriting that change.'
        }
        Set-TorAuditFlags ([uint32]$saved.OriginalFlags)
        if ((Get-TorAuditFlags) -ne $saved.OriginalFlags) { throw 'Audit restoration not confirmed; backup retained.' }
    }
    Remove-Item -LiteralPath $backup
}
function Convert-TorBlockEvents($Events, [uint32]$ProcessNumber) {
    foreach ($event in $Events) {
        [xml]$xml = $event.ToXml()
        $data = @{}
        foreach ($field in $xml.Event.EventData.Data) { $data[[string]$field.Name] = [string]$field.InnerText }
        $number = 0
        $value = [string]$data['ProcessID']
        try {
            $number = if ($value.StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) { [Convert]::ToUInt32($value.Substring(2),16) } else { [Convert]::ToUInt32($value,10) }
        } catch { continue }
        if ($number -ne $ProcessNumber -or [string]$data['Application'] -notmatch '(?i)[\\/]tor\.exe$') { continue }
        [pscustomobject]@{ TimeCreated=$event.TimeCreated; EventId=$event.Id; Data=$data }
    }
}
function Get-TorMatchingFilters([xml]$Document, [string[]]$Identifiers) {
    foreach ($number in @($Identifiers | Select-Object -Unique)) {
        if ($number -notmatch '^\d+$') { continue }
        foreach ($node in $Document.SelectNodes("//*[translate(local-name(),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='filterid' and normalize-space(.)='$number']")) {
            [pscustomobject]@{ FilterId=$number; Xml=$node.ParentNode.OuterXml }
        }
    }
}
function Export-TorWfpState([string]$Destination) {
    Remove-Item -LiteralPath $Destination -ErrorAction SilentlyContinue
    & "$env:SystemRoot\System32\netsh.exe" wfp show state "file=$Destination" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "netsh wfp show state exited $LASTEXITCODE" }
}
function New-TorAuditQuery([uint32]$ProcessNumber, [long]$StartedSeconds) {
    $since = [DateTimeOffset]::FromUnixTimeSeconds($StartedSeconds).UtcDateTime
    $until = $since.AddMinutes(10)
    $startText = $since.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture)
    $endText = $until.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture)
    $forms = @($ProcessNumber.ToString(),('0x'+$ProcessNumber.ToString('x')),('0x'+$ProcessNumber.ToString('X')),('0x'+$ProcessNumber.ToString('x8')),('0x'+$ProcessNumber.ToString('X8'))) | Select-Object -Unique
    $pidFilter = ($forms | ForEach-Object { "Data[@Name='ProcessID']='$_'" }) -join ' or '
    return "*[System[(EventID=5157) and TimeCreated[@SystemTime >= '$startText' and @SystemTime <= '$endText']] and EventData[$pidFilter]]"
}
function Save-TorFirewallEvidence($Context) {
    $dest = Join-Path $Context.StateDir 'firewall-evidence.json'
    $report = [ordered]@{ CapturedUtc=[DateTime]::UtcNow.ToString('o'); Stage='Reading Tor block events first'; Profiles=@(); TorRules=@(); OutboundBlocks=@(); BlockApplications=@(); TorProcess=$null; BlockEvents=@(); MatchedFilters=@(); Errors=@() }
    # Persist a checkpoint before ANY potentially slow Windows read. A killed
    # capture must leave the newest complete result, not an absent report.
    Write-TorJson $report $dest
    Write-TorStep $Context 'fw-audit.ps1' $report.Stage
    try {
        $identity = Get-Content -LiteralPath (Join-Path $Context.StateDir 'tor-start.json') -Raw | ConvertFrom-Json
        $report.TorProcess = $identity
        $query = New-TorAuditQuery ([uint32]$identity.process_id) ([long]$identity.started_utc)
        $events = @()
        try { $events = @(Get-WinEvent -LogName Security -FilterXPath $query -MaxEvents 64 -ErrorAction Stop) }
        catch { if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw } }
        $report.BlockEvents = @(Convert-TorBlockEvents $events ([uint32]$identity.process_id))
        $report['EventQueryLimit'] = 64
        if (-not $report.BlockEvents.Count) { $report.Errors += 'No matching Tor 5157 events found. This does not establish that no block exists.' }
    } catch { $report.Errors += "Connection audit: $($_.Exception.Message)" }
    # Keep a compact event-only file. Matching WFP XML can make the complete
    # report large enough that the ordinary diagnostic deliberately omits it.
    Write-TorJson @{ CapturedUtc=$report.CapturedUtc; TorProcess=$report.TorProcess;
        BlockEvents=@($report.BlockEvents); Errors=@($report.Errors) } (Join-Path $Context.StateDir 'firewall-events.json')
    $report.Stage='Tor events saved; reading saved armed snapshot'
    Write-TorJson $report $dest
    $armed = Join-Path $Context.StateDir 'firewall-armed.json'
    if (Test-Path -LiteralPath $armed) {
        try { $report['ArmedSnapshot'] = Get-Content -LiteralPath $armed -Raw | ConvertFrom-Json }
        catch { $report.Errors += "Armed snapshot: $($_.Exception.Message)" }
    }
    $report.Stage='Reading effective profiles'
    Write-TorJson $report $dest
    Write-TorStep $Context 'fw-audit.ps1' $report.Stage
    try { $report.Profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore | Select-Object Name,Enabled,DefaultOutboundAction,DefaultInboundAction,AllowLocalFirewallRules,AllowLocalIPsecRules,AllowInboundRules,DisabledInterfaceAliases) }
    catch { $report.Errors += "Profiles: $($_.Exception.Message)" }
    $report.Stage='Reading TorVPN rules'
    Write-TorJson $report $dest
    Write-TorStep $Context 'fw-audit.ps1' $report.Stage
    try {
        $own = @(Get-TorFirewallRule -PolicyStore ActiveStore -TracePolicyStore -Group TORVPN)
        $report.TorRules = @($own | Select-Object Name,DisplayName,Enabled,Direction,Action,Profile,PrimaryStatus,Status,EnforcementStatus,PolicyStoreSourceType,PolicyStoreSource)
        Write-TorJson $report $dest
        foreach ($kind in @('Application','Address','Port')) {
            $report.Stage="Reading Tor $kind filters"
            Write-TorJson $report $dest
            Write-TorStep $Context 'fw-audit.ps1' $report.Stage
            $cmd = "Get-NetFirewall${kind}Filter"
            $report["Tor${kind}Filters"] = @($own | & $cmd -ErrorAction Stop | Select-Object InstanceID,Program,Package,LocalAddress,RemoteAddress,Protocol,LocalPort,RemotePort)
            Write-TorJson $report $dest
        }
    } catch { $report.Errors += "Tor rules/filters: $($_.Exception.Message)" }
    $report.Stage='Reading enabled outbound blocks'
    Write-TorJson $report $dest
    Write-TorStep $Context 'fw-audit.ps1' $report.Stage
    try {
        $report.OutboundBlocks = @(Get-TorFirewallRule -PolicyStore ActiveStore -TracePolicyStore -Enabled True -Direction Outbound -Action Block | Select-Object Name,DisplayName,Profile,PrimaryStatus,Status,EnforcementStatus,PolicyStoreSourceType,PolicyStoreSource)
    } catch { $report.Errors += "Block rules: $($_.Exception.Message)" }
    $report.Stage='Reading WFP dump; earlier evidence already saved'
    Write-TorJson $report $dest
    Write-TorStep $Context 'fw-audit.ps1' $report.Stage
    try {
        $dump = Join-Path $Context.StateDir 'wfp-failure-state.xml'
        Export-TorWfpState $dump
        [xml]$document = Get-Content -LiteralPath $dump -Raw
        $numbers = @($report.BlockEvents | ForEach-Object { $_.Data['FilterRTID'] })
        $report.MatchedFilters = @(Get-TorMatchingFilters $document $numbers)
        $report['WfpStatePath'] = $dump
    } catch { $report.Errors += "WFP state dump: $($_.Exception.Message)" }
    $report.Stage='Evidence collection completed'
    Write-TorJson $report $dest
}

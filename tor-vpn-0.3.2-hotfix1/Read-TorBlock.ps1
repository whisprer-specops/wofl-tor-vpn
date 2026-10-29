#Requires -Version 5.1
<#
Read existing TorVPN 0.3.2 failure evidence. Run in Administrator PowerShell.
Does not reconnect, restart services, change rules, or change audit settings.
Windows event/rule reads run in separate processes with 20-second deadlines.
https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/filter-origin-documentation
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'torvpn-blocker.txt'),
    [string]$StateDir = (Join-Path $env:ProgramData 'torvpn'),
    [ValidateSet('','events','rules')][string]$Worker = '',
    [string]$EncodedArgs
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
function Write-BlockJson($Value, [string]$Path) {
    $json = ConvertTo-Json -InputObject $Value -Depth 16
    [IO.File]::WriteAllText($Path+'.tmp', $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath ($Path+'.tmp') -Destination $Path -Force
}
function New-TorEventQuery([uint32]$ProcessNumber, [long]$StartedSeconds) {
    $since = [DateTimeOffset]::FromUnixTimeSeconds($StartedSeconds).UtcDateTime
    $until = $since.AddMinutes(10)
    $startText = $since.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture)
    $endText = $until.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture)
    $forms = @($ProcessNumber.ToString(),('0x'+$ProcessNumber.ToString('x')),('0x'+$ProcessNumber.ToString('X')),('0x'+$ProcessNumber.ToString('x8')),('0x'+$ProcessNumber.ToString('X8'))) | Select-Object -Unique
    $pidFilter = ($forms | ForEach-Object { "Data[@Name='ProcessID']='$_'" }) -join ' or '
    return "*[System[(EventID=5157) and TimeCreated[@SystemTime >= '$startText' and @SystemTime <= '$endText']] and EventData[$pidFilter]]"
}
function Select-TorEvents($Events, [uint32]$ProcessNumber) {
    foreach ($event in $Events) {
        [xml]$xml = $event.ToXml()
        $fields = [ordered]@{}
        foreach ($field in $xml.Event.EventData.Data) { $fields[[string]$field.Name] = [string]$field.InnerText }
        $text = [string]$fields['ProcessID']
        try { $number = if ($text -match '^0x') { [Convert]::ToUInt32($text.Substring(2),16) } else { [Convert]::ToUInt32($text,10) } }
        catch { continue }
        if ($number -eq $ProcessNumber -and [string]$fields['Application'] -match '(?i)[\\/]tor\.exe$') {
            [pscustomobject]@{TimeCreatedUtc=$event.TimeCreated.ToUniversalTime().ToString('o');RecordId=$event.RecordId;EventId=$event.Id;Data=$fields}
        }
    }
}
function Read-TorEvents($Settings) {
    $result = [ordered]@{Stage='Reading only this Tor PID and its ten-minute attempt window';Events=@();Errors=@()}
    Write-BlockJson $result $Settings.Destination
    try {
        $query = New-TorEventQuery ([uint32]$Settings.Identity.process_id) ([long]$Settings.Identity.started_utc)
        $found = @()
        try { $found = @(Get-WinEvent -LogName Security -FilterXPath $query -MaxEvents 64 -ErrorAction Stop) }
        catch { if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw } }
        $result.Events = @(Select-TorEvents $found ([uint32]$Settings.Identity.process_id))
        $result.Stage = 'Event query completed'
        if ($result.Events.Count -eq 0) { $result.Errors += 'No matching retained 5157 events. This does not prove there was no block; events may be absent, inaccessible or expired.' }
    } catch { $result.Errors += $_.Exception.Message; $result.Stage='Event query failed' }
    Write-BlockJson $result $Settings.Destination
}
function Read-TorOriginRules($Settings) {
    $result = [ordered]@{Stage='Reading only rule IDs reported by the Tor block events';Rules=@();Errors=@();Snapshot='After recovery; rule IDs from FilterOrigin are used, not potentially stale runtime filter IDs.'}
    Write-BlockJson $result $Settings.Destination
    foreach ($name in @($Settings.Origins)) {
        try {
            $found = @(Get-NetFirewallRule -PolicyStore ActiveStore -TracePolicyStore -Name $name -ErrorAction Stop)
            foreach ($rule in $found) {
                $record = [ordered]@{Name=$rule.Name;DisplayName=$rule.DisplayName;Enabled=[string]$rule.Enabled;Action=[string]$rule.Action;Direction=[string]$rule.Direction;Profile=[string]$rule.Profile;Status=[string]$rule.Status;SourceType=[string]$rule.PolicyStoreSourceType;Source=[string]$rule.PolicyStoreSource;Application=@();Address=@();Port=@();Service=@()}
                $result.Rules += $record
                Write-BlockJson $result $Settings.Destination
                foreach ($kind in @('Application','Address','Port','Service')) {
                    try {
                        $cmd="Get-NetFirewall${kind}Filter"
                        $record[$kind]=@($rule | & $cmd -ErrorAction Stop | Select-Object InstanceID,Program,Package,LocalAddress,RemoteAddress,Protocol,LocalPort,RemotePort,Service)
                    } catch { $result.Errors += "$name $kind : $($_.Exception.Message)" }
                    Write-BlockJson $result $Settings.Destination
                }
            }
        } catch { $result.Errors += "$name : $($_.Exception.Message)" }
        Write-BlockJson $result $Settings.Destination
    }
    $result.Stage='Origin rule reads completed'
    Write-BlockJson $result $Settings.Destination
}
function Invoke-BlockReadWorker([string]$ScriptPath,[string]$Phase,$Settings,[string]$Engine,[int]$LimitSeconds=20) {
    $payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Settings -Depth 8 -Compress)))
    $quoted=$ScriptPath.Replace("'","''")
    $command="& '$quoted' -Worker '$Phase' -EncodedArgs '$payload'"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Engine
    $info.Arguments="-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$info
    $launched=$false
    try {
        if (-not $process.Start()) { throw 'Could not start read-only worker.' }
        $launched=$true
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($LimitSeconds*1000)) {
            $process.Kill()
            $null=$process.WaitForExit(5000)
            return "The $Phase read exceeded ${LimitSeconds}s; partial results retained."
        }
        if ($process.ExitCode -ne 0) {
            $detail=$stderr.GetAwaiter().GetResult()
            if ($detail.Length -gt 2000) { $detail=$detail.Substring(0,2000) }
            return "The $Phase worker exited $($process.ExitCode): $detail"
        }
        $null=$stdout.GetAwaiter().GetResult()
        return $null
    } finally {
        if ($launched -and -not $process.HasExited) {
            try { $process.Kill(); $null=$process.WaitForExit(5000) } catch { }
        }
        $process.Dispose()
    }
}
if ($Worker) {
    $settings=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedArgs)) | ConvertFrom-Json
    if ($Worker -eq 'events') { Read-TorEvents $settings } else { Read-TorOriginRules $settings }
    return
}
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on the Windows computer with TorVPN installed.' }
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Open PowerShell as Administrator, then run this script again.' }
$identityPath=Join-Path $StateDir 'tor-start.json'
if (-not (Test-Path -LiteralPath $identityPath)) { throw "Missing $identityPath. This reader requires the process record from the TorVPN 0.3.2 attempt." }
$identity=Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
if ([uint32]$identity.process_id -eq 0 -or [long]$identity.started_utc -le 0) { throw 'Invalid Tor process record; no Security log query performed.' }
$report=[ordered]@{Report='TorVPN existing failure reader 1.0';CapturedUtc=[DateTime]::UtcNow.ToString('o');ReadOnly=$true;TorAttempt=$identity;ArmedSnapshot=$null;EventRead=$null;OriginRead=$null;Errors=@();Notes=@('No connection attempt, service restart, firewall edit or audit-policy change was performed.','Only matching Tor block events are included; local paths and network addresses may appear.','Absence of an event is not evidence of absence of a block.')}
$OutputPath=[IO.Path]::GetFullPath($OutputPath)
$armed=Join-Path $StateDir 'firewall-armed.json'
if (Test-Path -LiteralPath $armed) {
    try { $report.ArmedSnapshot=Get-Content -LiteralPath $armed -Raw | ConvertFrom-Json }
    catch { $report.Errors += "Saved armed snapshot: $($_.Exception.Message)" }
}
Write-BlockJson $report $OutputPath
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('torvpn-block-read-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$engine=if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
try {
    Write-Host "Reading existing Tor block events for PID $($identity.process_id) (20-second bound)..."
    $eventFile=Join-Path $scratch 'events.json'
    $failure=Invoke-BlockReadWorker $PSCommandPath 'events' @{Identity=$identity;Destination=$eventFile} $engine
    if ($failure) { $report.Errors += $failure }
    if (Test-Path -LiteralPath $eventFile) { $report.EventRead=Get-Content -LiteralPath $eventFile -Raw | ConvertFrom-Json }
    Write-BlockJson $report $OutputPath
    $origins=@()
    if ($report.EventRead) {
        $origins=@($report.EventRead.Events | ForEach-Object {
            foreach ($property in $_.Data.PSObject.Properties) {
                if ($property.Name -match '^FilterOrigin') {
                    $guid=[Guid]::Empty
                    if ([Guid]::TryParse([string]$property.Value,[ref]$guid)) { $guid.ToString('B') }
                }
            }
        } | Select-Object -Unique -First 4)
    }
    if ($origins.Count) {
        Write-Host "Reading $($origins.Count) reported origin rule(s) (20-second bound)..."
        $ruleFile=Join-Path $scratch 'rules.json'
        $failure=Invoke-BlockReadWorker $PSCommandPath 'rules' @{Origins=$origins;Destination=$ruleFile} $engine
        if ($failure) { $report.Errors += $failure }
        if (Test-Path -LiteralPath $ruleFile) { $report.OriginRead=Get-Content -LiteralPath $ruleFile -Raw | ConvertFrom-Json }
    }
} catch { $report.Errors += $_.Exception.Message }
finally {
    Write-BlockJson $report $OutputPath
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
$count=if ($report.EventRead) { @($report.EventRead.Events).Count } else { 0 }
Write-Host "Saved $OutputPath; matching Tor block events: $count. Review this report before sharing."
if ($report.Errors.Count) { Write-Warning ($report.Errors -join "`n") }

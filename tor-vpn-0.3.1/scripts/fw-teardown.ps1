param([string]$JsonBase64)
. "$PSScriptRoot\common.ps1"
$a = Read-TorArgs $JsonBase64
$backup = Join-Path $a.StateDir 'firewall-backup.json'
if (-not (Test-Path -LiteralPath $backup)) {
    Get-NetFirewallRule -Group TORVPN -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    return
}
Write-TorStep $a 'fw-teardown.ps1' 'Reading saved firewall recovery state'
$saved = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
$failures = New-Object 'System.Collections.Generic.List[string]'
# Restore each original profile, including any pre-existing Block setting.
Write-TorStep $a 'fw-teardown.ps1' 'Restoring original firewall profile defaults'
foreach ($p in $saved.Profiles) {
    try { Set-NetFirewallProfile -Name $p.Name -DefaultOutboundAction $p.Outbound }
    catch { $failures.Add("Profile $($p.Name): $($_.Exception.Message)") }
}
if ($saved.PSObject.Properties.Name -contains 'SavedRules') {
    $rules = @($saved.SavedRules)
} else {
    # Backward-compatible recovery of 0.3.0 / hotfix1 backups.
    $rules = @($saved.AllowRules | ForEach-Object {
        [pscustomobject]@{ Name=$_; SourceType='Local'; PolicyStoreSource='PersistentStore' }
    })
}
Write-TorStep $a 'fw-teardown.ps1' 'Reading current Local and Dynamic recovery rules'
$local = @()
$dynamic = @()
try { $local = @(Get-NetFirewallRule -PolicyStore PersistentStore -Direction Outbound -Action Allow) }
catch { $failures.Add("Read local recovery rules: $($_.Exception.Message)") }
if (@($rules | Where-Object SourceType -eq 'Dynamic').Count -gt 0) {
    try {
        $dynamic = @(Get-NetFirewallRule -PolicyStore ActiveStore -TracePolicyStore -Direction Outbound -Action Allow |
            Where-Object { [string]$_.PolicyStoreSourceType -eq 'Dynamic' })
    } catch { $failures.Add("Read dynamic recovery rules: $($_.Exception.Message)") }
}
$restoreLocal = @()
$restoreDynamic = @()
foreach ($record in $rules) {
    if ($record.SourceType -eq 'Local') {
        $restoreLocal += @($local | Where-Object { $_.Name -eq $record.Name -and [string]$_.Enabled -ne 'True' })
    } elseif ($record.SourceType -eq 'Dynamic') {
        # Expired runtime rules are not recreated. Match both identity/source.
        $restoreDynamic += @($dynamic | Where-Object {
            $_.Name -eq $record.Name -and [string]$_.PolicyStoreSource -eq [string]$record.PolicyStoreSource -and [string]$_.Enabled -ne 'True'
        })
    } else { $failures.Add("Unsupported saved source type '$($record.SourceType)'") }
}
if ($restoreLocal.Count) {
    try {
        Write-TorStep $a 'fw-teardown.ps1' "Restoring $($restoreLocal.Count) Local rules in one batch"
        Enable-NetFirewallRule -InputObject $restoreLocal | Out-Null
    } catch { $failures.Add("Restore Local batch: $($_.Exception.Message)") }
}
if ($restoreDynamic.Count) {
    try {
        Write-TorStep $a 'fw-teardown.ps1' "Restoring $($restoreDynamic.Count) Dynamic rules through live objects"
        Enable-NetFirewallRule -InputObject $restoreDynamic | Out-Null
    } catch { $failures.Add("Restore Dynamic batch: $($_.Exception.Message)") }
}
Write-TorStep $a 'fw-teardown.ps1' 'Verifying restored rule states'
# Verify enabled state by rereading stores; do not trust stale CIM snapshots.
try {
    $restoredLocal = @(Get-NetFirewallRule -PolicyStore PersistentStore -Direction Outbound -Action Allow)
    $restoredDynamic = @()
    if (@($rules | Where-Object SourceType -eq 'Dynamic').Count -gt 0) {
        $restoredDynamic = @(Get-NetFirewallRule -PolicyStore ActiveStore -TracePolicyStore -Direction Outbound -Action Allow |
            Where-Object { [string]$_.PolicyStoreSourceType -eq 'Dynamic' })
    }
    foreach ($record in $rules) {
        if ($record.SourceType -eq 'Local') {
            $found = @($restoredLocal | Where-Object { $_.Name -eq $record.Name })
        } else {
            $found = @($restoredDynamic | Where-Object {
                $_.Name -eq $record.Name -and [string]$_.PolicyStoreSource -eq [string]$record.PolicyStoreSource
            })
        }
        if (@($found | Where-Object { [string]$_.Enabled -ne 'True' }).Count -gt 0) {
            $failures.Add("Rule $($record.Name) is still disabled")
        }
    }
} catch { $failures.Add("Verify restored rules: $($_.Exception.Message)") }
try { Get-NetFirewallRule -Group TORVPN -ErrorAction SilentlyContinue | Remove-NetFirewallRule }
catch { $failures.Add("Remove TorVPN rules: $($_.Exception.Message)") }
if ($failures.Count -gt 0) { throw "Firewall restoration incomplete; backup retained. $($failures -join '; ')" }
Remove-Item -LiteralPath $backup
Write-TorStep $a 'fw-teardown.ps1' 'Firewall recovery completed and verified'
Write-Host 'Original firewall profiles and saved Local/Dynamic allow rules restored.'

# Read-only. Does not print API tokens or profile credentials.
[CmdletBinding()]
param([string]$OutputPath = (Join-Path (Get-Location) 'torvpn-diagnostic.txt'))
$ErrorActionPreference = 'Continue'
$state = Join-Path $env:ProgramData 'torvpn'
$lines = New-Object 'System.Collections.Generic.List[string]'
$lines.Add("TorVPN diagnostic - $([DateTime]::UtcNow.ToString('o'))")
$lines.Add((Get-CimInstance Win32_Service -Filter "Name='TorVPN'" | Select-Object Name,State,StartMode,ExitCode,PathName | Format-List | Out-String))
foreach ($name in @('state.json','svc.log','tun2socks.log','admin-progress.json','admin-steps.log','script-fw-apply.ps1.log','script-fw-teardown.ps1.log')) {
    $lines.Add("`n--- $name (last 100 lines) ---")
    $path = Join-Path $state $name
    if (Test-Path -LiteralPath $path) { $lines.Add((Get-Content -LiteralPath $path -Tail 100 | Out-String)) } else { $lines.Add('File absent') }
}
$tray = Join-Path $env:LOCALAPPDATA 'torvpn\tray.log'
$lines.Add("`n--- tray.log (last 50 lines) ---")
if (Test-Path -LiteralPath $tray) { $lines.Add((Get-Content -LiteralPath $tray -Tail 50 | Out-String)) }
$lines.Add("`n--- TorVPN adapter ---")
$lines.Add((Get-NetAdapter | Where-Object { $_.Name -eq 'torvpn' } | Format-List Name,Status,ifIndex,InterfaceDescription | Out-String))
$lines.Add("`n--- firewall profiles ---")
$lines.Add((Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultOutboundAction | Format-Table | Out-String))
$lines.Add("`n--- Traced outbound allow rule origins ---")
try {
    $rules = @(& {
        . (Join-Path $PSScriptRoot 'scripts\common.ps1')
        Get-TorFirewallRule -PolicyStore ActiveStore -TracePolicyStore -Enabled True -Direction Outbound -Action Allow
    })
    $lines.Add(($rules | Group-Object PolicyStoreSourceType | Select-Object Name,Count | Format-Table | Out-String))
    $nonLocal = @($rules | Where-Object { [string]$_.PolicyStoreSourceType -ne 'Local' })
    if ($nonLocal.Count) {
        $lines.Add(($nonLocal | Select-Object -First 50 Name,DisplayName,PolicyStoreSourceType,PolicyStoreSource | Format-List | Out-String))
    } elseif ($rules.Count -eq 0) { $lines.Add('No enabled outbound allow rules matched the query.') }
    else { $lines.Add('All enabled outbound allow rules have traced Local origin.') }
} catch { $lines.Add("Rule-origin query failed: $($_.Exception.Message)") }
$originReport = Join-Path $state 'firewall-origin-blockers.json'
if (Test-Path -LiteralPath $originReport) {
    $lines.Add("`n--- Last firewall-origin blocker report ---")
    $lines.Add((Get-Content -LiteralPath $originReport -Raw))
}
$lines | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Saved $OutputPath (contains local paths and network diagnostics; review before sharing)."

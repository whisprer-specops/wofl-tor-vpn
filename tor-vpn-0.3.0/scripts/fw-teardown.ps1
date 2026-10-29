param([string]$JsonBase64)
. "$PSScriptRoot\common.ps1"
$a = Read-TorArgs $JsonBase64
$backup = Join-Path $a.StateDir 'firewall-backup.json'
if (Test-Path -LiteralPath $backup) {
    $saved = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
    # Restore original policy, including pre-existing Block configurations.
    # Keep the recovery file if ANY restoration step fails.
    foreach ($p in $saved.Profiles) { Set-NetFirewallProfile -Name $p.Name -DefaultOutboundAction $p.Outbound }
    foreach ($name in $saved.AllowRules) {
        $r = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
        if ($r) { $r | Enable-NetFirewallRule | Out-Null }
    }
    Get-NetFirewallRule -Group TORVPN -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Remove-Item -LiteralPath $backup
} else {
    # No original-policy backup exists in pre-0.3 builds. Remove only our
    # rules; never rewrite the entire machine's policy to Allow on startup.
    Get-NetFirewallRule -Group TORVPN -ErrorAction SilentlyContinue | Remove-NetFirewallRule
}

param($jsonArgs)
if ($jsonArgs -is [string]) { $argsObj = $jsonArgs | ConvertFrom-Json } else { $argsObj = $null }
$AdapterHint = $argsObj.AdapterHint
$TorPath     = $argsObj.TorPath

# Create a policy group
$group = "TORVPN"
# Clean old rules from this group
Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue | Out-Null

# Global outbound block for group tag (we'll assign explicit allows)
# Win Firewall doesn't support true "default deny per group", so we add:
#  - A Block-All rule with EdgeTraversalPolicy set to Block
#  - Then explicit allow rules for Tor.exe and the Wintun adapter

New-NetFirewallRule -DisplayName "TORVPN Block All" -Group $group -Direction Outbound -Action Block -Enabled True | Out-Null

# Allow Tor
if (-not [string]::IsNullOrEmpty($TorPath) -and (Test-Path $TorPath)) {
    New-NetFirewallRule -DisplayName "TORVPN Allow Tor" -Group $group -Program $TorPath -Direction Outbound -Action Allow -Enabled True | Out-Null
} else {
    # try by name in PATH
    $tor = Get-Command tor.exe -ErrorAction SilentlyContinue
    if ($tor) {
        New-NetFirewallRule -DisplayName "TORVPN Allow Tor" -Group $group -Program $tor.Path -Direction Outbound -Action Allow -Enabled True | Out-Null
    }
}

# Allow traffic through the Wintun adapter
$adapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*Wintun*" -or $_.Name -like "*$AdapterHint*" } | Select-Object -First 1
if ($adapter) {
    New-NetFirewallRule -DisplayName "TORVPN Allow Wintun" -Group $group -InterfaceAlias $adapter.Name -Direction Outbound -Action Allow -Enabled True | Out-Null
}

Write-Host "[+] Firewall rules applied for group $group"

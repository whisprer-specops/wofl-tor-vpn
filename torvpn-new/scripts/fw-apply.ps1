# =============================================================================
# TorVPN -- Firewall apply (kill-switch)
# =============================================================================
# Called by the service when engaging. Receives a JSON arg with:
#   { "AdapterHint": "torvpn", "TorPath": "C:\Program Files\TorVPN\tor\tor.exe" }
#
# Strategy: Windows Firewall has no true "default-deny per rule-group", so we:
#   1. Wipe any existing TORVPN rules
#   2. Add an outbound Block-All rule tagged to our group
#   3. Add explicit Allow rules for tor.exe and the Wintun adapter
# Teardown removes everything tagged with the group.
# =============================================================================
param($jsonArgs)

$ErrorActionPreference = "Stop"

if ($jsonArgs -is [string] -and $jsonArgs.Length -gt 0) {
    $argsObj = $jsonArgs | ConvertFrom-Json
} else {
    $argsObj = $null
}

$AdapterHint = if ($argsObj) { $argsObj.AdapterHint } else { "torvpn" }
$TorPath     = if ($argsObj) { $argsObj.TorPath }     else { "" }
$group       = "TORVPN"

# ----- Clean any leftover rules from the group --------------------------------
Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue | Out-Null

# ----- Global outbound block (tagged) -----------------------------------------
New-NetFirewallRule `
    -DisplayName "TORVPN Block All Outbound" `
    -Group       $group `
    -Direction   Outbound `
    -Action      Block `
    -Enabled     True | Out-Null

# ----- Allow tor.exe ----------------------------------------------------------
if (-not [string]::IsNullOrEmpty($TorPath) -and (Test-Path $TorPath)) {
    New-NetFirewallRule `
        -DisplayName "TORVPN Allow Tor" `
        -Group       $group `
        -Program     $TorPath `
        -Direction   Outbound `
        -Action      Allow `
        -Enabled     True | Out-Null
} else {
    # Fall back to whatever's in PATH (unusual; bundled deployment should hit the branch above)
    $tor = Get-Command tor.exe -ErrorAction SilentlyContinue
    if ($tor) {
        New-NetFirewallRule `
            -DisplayName "TORVPN Allow Tor (PATH)" `
            -Group       $group `
            -Program     $tor.Path `
            -Direction   Outbound `
            -Action      Allow `
            -Enabled     True | Out-Null
    } else {
        Write-Warning "[!] tor.exe not found -- connection will fail closed"
    }
}

# ----- Allow traffic through the Wintun adapter -------------------------------
$adapter = Get-NetAdapter |
    Where-Object {
        $_.InterfaceDescription -like "*Wintun*" -or
        $_.Name                  -like "*$AdapterHint*"
    } |
    Select-Object -First 1

if ($adapter) {
    New-NetFirewallRule `
        -DisplayName    "TORVPN Allow Wintun" `
        -Group          $group `
        -InterfaceAlias $adapter.Name `
        -Direction      Outbound `
        -Action         Allow `
        -Enabled        True | Out-Null
} else {
    Write-Warning "[!] Wintun adapter not found (hint='$AdapterHint') -- kill-switch active but no tunnel allow rule"
}

Write-Host "[+] Firewall rules applied for group $group"

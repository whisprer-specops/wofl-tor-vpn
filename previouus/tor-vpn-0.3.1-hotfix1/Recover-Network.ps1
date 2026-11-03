#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$LegacyReset)
$ErrorActionPreference = 'Stop'
$service = Get-Service TorVPN -ErrorAction SilentlyContinue
if ($service -and $service.Status -ne 'Stopped') {
    Stop-Service TorVPN
    $service.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(240))
}
$state = Join-Path $env:ProgramData 'torvpn'
$hasBackup = Test-Path -LiteralPath (Join-Path $state 'firewall-backup.json')
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ StateDir=$state } | ConvertTo-Json -Compress)))
foreach ($name in @('route-teardown.ps1','dns-teardown.ps1','fw-teardown.ps1')) {
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PSScriptRoot\scripts\$name" -JsonBase64 $encoded
    if ($LASTEXITCODE -ne 0) { throw "$name failed; recovery metadata retained" }
}
if ($LegacyReset -and -not $hasBackup) {
    # Explicit opt-in for pre-0.3 residual default-deny, whose prior values
    # were never saved. This sets factory defaults rather than guessing them.
    Set-NetFirewallProfile -All -DefaultOutboundAction Allow
}
Write-Host 'TorVPN service stopped; saved routes, DNS and firewall changes restored.'
Write-Host 'Start-Service TorVPN will reconnect unless auto_connect is disabled in profile.toml.'

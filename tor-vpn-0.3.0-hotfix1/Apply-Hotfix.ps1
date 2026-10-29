#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param([string]$InstallDir = (Join-Path $env:ProgramFiles 'TorVPN'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$source = Join-Path $PSScriptRoot 'scripts\fw-apply.ps1'
$destination = Join-Path $InstallDir 'scripts\fw-apply.ps1'
$svcExe = Join-Path $InstallDir 'torvpn-svc.exe'
foreach ($path in @($source,$destination,$svcExe)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required file missing: $path. Install 0.3.0 using Repair.ps1 first." }
}
# Integrity-check the replacement and diagnostic script against this release.
$hashList = Join-Path $PSScriptRoot 'SHA256SUMS.txt'
foreach ($relative in @('scripts/fw-apply.ps1','Get-Diagnostics.ps1')) {
    $line = @(Get-Content -LiteralPath $hashList | Where-Object { $_.EndsWith('  ' + $relative) })
    if ($line.Count -ne 1) { throw "No unique release hash for $relative" }
    $expected = $line[0].Substring(0,64)
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $PSScriptRoot $relative)).Hash -ne $expected) { throw "Integrity check failed: $relative" }
}
$state = Join-Path $env:ProgramData 'torvpn'
$backup = Join-Path $state ('backups\hotfix1-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Copy-Item -LiteralPath $destination -Destination (Join-Path $backup 'fw-apply.ps1')
$oldDiagnostic = Join-Path $InstallDir 'Get-Diagnostics.ps1'
if (Test-Path -LiteralPath $oldDiagnostic) { Copy-Item -LiteralPath $oldDiagnostic -Destination $backup }
$service = Get-Service -Name TorVPN
$previouslyRunning = $service.Status -ne 'Stopped'
if ($previouslyRunning) {
    Stop-Service -Name TorVPN
    $service.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(240))
}
try {
    Copy-Item -LiteralPath $source -Destination $destination -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Get-Diagnostics.ps1') -Destination $oldDiagnostic -Force
} catch {
    Copy-Item -LiteralPath (Join-Path $backup 'fw-apply.ps1') -Destination $destination -Force
    if ($previouslyRunning) { Start-Service -Name TorVPN }
    throw
}
Write-Host "Firewall-origin hotfix installed. Original script saved to $backup"
# No changes to the profile, Tor, drivers, executable files, or service registration.
Start-Service -Name TorVPN
$profile = Get-Content -LiteralPath (Join-Path $state 'profile.toml') -Raw
$listen = '127.0.0.1:8787'
if ($profile -match '(?m)^listen\s*=\s*"([^"]+)"') { $listen=$Matches[1] }
$uri = [Uri]("http://$listen/status")
if (-not [Net.IPAddress]::IsLoopback([Net.IPAddress]::Parse($uri.Host.Trim('[',']')))) { throw 'Refusing non-loopback control endpoint' }
$noAutoConnect = $profile -match '(?m)^auto_connect\s*=\s*false'
$deadline = [DateTime]::UtcNow.AddSeconds(260)
$lastMessage = ''
$lastStatus = $null
$ready = $false
$failure = $null
Add-Type -AssemblyName System.Net.Http
$handler = New-Object Net.Http.HttpClientHandler
$handler.UseProxy = $false
$client = New-Object Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(5)
try {
    do {
        try {
            $token = (Get-Content -LiteralPath (Join-Path $state 'api_token') -Raw).Trim()
            $client.DefaultRequestHeaders.Remove('X-TorVPN-Token') | Out-Null
            $client.DefaultRequestHeaders.Add('X-TorVPN-Token',$token)
            $raw = $client.GetStringAsync($uri).GetAwaiter().GetResult()
            $lastStatus = $raw | ConvertFrom-Json
            if ($lastStatus.message -ne $lastMessage) {
                Write-Host "[$($lastStatus.phase)] $($lastStatus.message)"
                $lastMessage = $lastStatus.message
            }
            if ($lastStatus.phase -eq 'error') { $failure = $lastStatus.message; break }
            if ($lastStatus.phase -eq 'engaged') { $ready = $true; break }
            if ($noAutoConnect -and $lastStatus.phase -eq 'disengaged') {
                Write-Host 'Automatic connection is disabled in your profile. Connect using the tray when ready.'
                $ready = $true; break
            }
        } catch { $lastMessage=$_.Exception.Message }
        Start-Sleep -Milliseconds 750
    } while ([DateTime]::UtcNow -lt $deadline)
} finally { $client.Dispose(); $handler.Dispose() }
if (-not $ready) {
    $report = Join-Path $PSScriptRoot 'torvpn-diagnostic.txt'
    & (Join-Path $PSScriptRoot 'Get-Diagnostics.ps1') -OutputPath $report
    if ($failure) { throw "Connection stopped: $failure`nUpdated diagnostic saved to $report" }
    throw "No confirmed connection before timeout. Last status/error: $lastMessage`nDiagnostic saved to $report"
}
Write-Host 'Hotfix applied successfully.'

#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param([string]$InstallDir = (Join-Path $env:ProgramFiles 'TorVPN'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
function Copy-TorUpdateFile([string]$From, [string]$To) {
    # SCM may report Stopped just before the old EXE's image handle closes.
    for ($attempt=0; $attempt -lt 12; $attempt++) {
        try { Copy-Item -LiteralPath $From -Destination $To -Force; return }
        catch {
            if ($attempt -eq 11) { throw }
            Start-Sleep -Milliseconds 250
        }
    }
}
$state = Join-Path $env:ProgramData 'torvpn'
$svcExe = Join-Path $InstallDir 'torvpn-svc.exe'
if (-not (Test-Path -LiteralPath $svcExe)) { throw 'Install TorVPN using Repair.ps1 before applying this update.' }
$items = @(
    @{Source='bin/torvpn-svc.exe';Target='torvpn-svc.exe'},
    @{Source='bin/torvpn-tray.exe';Target='torvpn-tray.exe'},
    @{Source='scripts/common.ps1';Target='scripts/common.ps1'},
    @{Source='scripts/fw-apply.ps1';Target='scripts/fw-apply.ps1'},
    @{Source='scripts/fw-teardown.ps1';Target='scripts/fw-teardown.ps1'},
    @{Source='Get-Diagnostics.ps1';Target='Get-Diagnostics.ps1'}
)
$hashList = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'SHA256SUMS.txt'))
foreach ($item in $items) {
    $path = Join-Path $PSScriptRoot $item.Source
    $hash = @($hashList | Where-Object { $_.EndsWith('  ' + $item.Source) })
    if ($hash.Count -ne 1 -or -not (Test-Path -LiteralPath $path)) { throw "Release file or hash missing: $($item.Source)" }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -ne $hash[0].Substring(0,64)) { throw "Integrity check failed: $($item.Source)" }
}
$backup = Join-Path $state ('backups\update-0.3.1-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
foreach ($item in $items) {
    $old = Join-Path $InstallDir $item.Target
    $copy = Join-Path $backup $item.Target
    New-Item -ItemType Directory -Path (Split-Path -Parent $copy) -Force | Out-Null
    if (Test-Path -LiteralPath $old) { Copy-Item -LiteralPath $old -Destination $copy }
}
Write-Host "Existing files backed up to $backup"
# Remove the old toggle-on-left-click tray before it can enqueue another action.
Get-Process -Name torvpn-tray -ErrorAction SilentlyContinue | Stop-Process -Force
# Install batch recovery before asking the old service to disconnect. Its next
# cleanup invocation can then restore saved rules without a per-rule cmdlet loop.
foreach ($relative in @('scripts/common.ps1','scripts/fw-teardown.ps1')) {
    Copy-TorUpdateFile (Join-Path $PSScriptRoot $relative) (Join-Path $InstallDir $relative)
}
$service = Get-Service -Name TorVPN
Write-Host 'Stopping the current service and restoring any pending network changes...'
if ($service.Status -ne 'Stopped') {
    $service.Stop()
    $service.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(900))
}
try {
    foreach ($item in $items) {
        Copy-TorUpdateFile (Join-Path $PSScriptRoot $item.Source) (Join-Path $InstallDir $item.Target)
    }
} catch {
    foreach ($item in $items) {
        $copy = Join-Path $backup $item.Target
        if (Test-Path -LiteralPath $copy) { Copy-TorUpdateFile $copy (Join-Path $InstallDir $item.Target) }
    }
    throw
}
Write-Host 'TorVPN 0.3.1 installed. Existing Tor, driver, profile and service registration preserved.'
Add-Type -AssemblyName System.Net.Http
$handler = New-Object Net.Http.HttpClientHandler
$handler.UseProxy=$false
$client = New-Object Net.Http.HttpClient($handler)
$client.Timeout=[TimeSpan]::FromSeconds(5)
$profile = Get-Content -LiteralPath (Join-Path $state 'profile.toml') -Raw
$listen='127.0.0.1:8787'
if ($profile -match '(?m)^listen\s*=\s*"([^"]+)"') { $listen=$Matches[1] }
$uri=[Uri]("http://$listen/status")
if (-not [Net.IPAddress]::IsLoopback([Net.IPAddress]::Parse($uri.Host.Trim('[',']')))) { throw 'Refusing non-loopback control endpoint' }
$noAutoConnect=$profile -match '(?m)^auto_connect\s*=\s*false'
$started=[DateTimeOffset]::UtcNow
$deadline=[DateTime]::UtcNow.AddSeconds(900)
$ready=$false; $failure=$null; $lastMessage=''; $lastOutput=[DateTime]::UtcNow
$trayStarted=$false
$service.Refresh()
$service.Start()
try {
    do {
        try {
            $token=(Get-Content -LiteralPath (Join-Path $state 'api_token') -Raw).Trim()
            $client.DefaultRequestHeaders.Remove('X-TorVPN-Token') | Out-Null
            $client.DefaultRequestHeaders.Add('X-TorVPN-Token',$token)
            $snap=$client.GetStringAsync($uri).GetAwaiter().GetResult() | ConvertFrom-Json
            $message="[$($snap.phase)] $($snap.message)"
            if (-not $trayStarted) {
                Start-Process -FilePath (Join-Path $InstallDir 'torvpn-tray.exe')
                $trayStarted=$true
            }
            if ($snap.phase -eq 'error') { $failure=$snap.message; break }
            if ($snap.phase -eq 'engaged') { Write-Host $message; $ready=$true; break }
            if ($noAutoConnect -and $snap.phase -eq 'disengaged') {
                Write-Host 'Automatic connection is disabled. Use Connect in the right-click menu when ready.'
                $ready=$true; break
            }
        } catch {
            $message='Waiting for the control API during startup recovery'
            $progressPath=Join-Path $state 'admin-progress.json'
            if (Test-Path -LiteralPath $progressPath) {
                try {
                    $step=Get-Content -LiteralPath $progressPath -Raw | ConvertFrom-Json
                    if ($step.updated_ms -ge $started.ToUnixTimeMilliseconds()) { $message="[startup] $($step.script): $($step.message)" }
                } catch { }
            }
            $service.Refresh()
            if ($service.Status -eq 'Stopped' -and ([DateTimeOffset]::UtcNow-$started).TotalSeconds -gt 15) {
                $failure='Service stopped before its API became ready; see svc.log.'; break
            }
        }
        if ($message -ne $lastMessage -or ([DateTime]::UtcNow-$lastOutput).TotalSeconds -ge 10) {
            $elapsed=[int]([DateTimeOffset]::UtcNow-$started).TotalSeconds
            Write-Host "$message (elapsed ${elapsed}s)"
            $lastMessage=$message; $lastOutput=[DateTime]::UtcNow
        }
        Start-Sleep -Milliseconds 750
    } while ([DateTime]::UtcNow -lt $deadline)
} finally { $client.Dispose(); $handler.Dispose() }
if (-not $ready) {
    $report=Join-Path $PSScriptRoot 'torvpn-diagnostic.txt'
    & (Join-Path $PSScriptRoot 'Get-Diagnostics.ps1') -OutputPath $report
    if ($failure) { throw "Connection stopped: $failure`nDiagnostic saved to $report" }
    throw "No confirmed connection within 15 minutes. Last stage: $lastMessage`nDiagnostic saved to $report"
}
Write-Host 'Update completed. Left-click opens status; Connect/Disconnect are in the right-click menu.'

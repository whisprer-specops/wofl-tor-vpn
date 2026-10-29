#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'TorVPN'),
    [switch]$PreserveProfile,
    [switch]$NoConnect,
    [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$root = $PSScriptRoot
$state = Join-Path $env:ProgramData 'torvpn'
$backup = Join-Path $state ('backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe exited with code $LASTEXITCODE" }
}
# Locate ALL installation payloads before changing a running installation.
$bin = Join-Path $root 'bin'
if (-not ((Test-Path "$bin\torvpn-svc.exe") -and (Test-Path "$bin\torvpn-tray.exe"))) {
    if ($SkipBuild) { throw 'Prebuilt binaries missing and -SkipBuild was specified' }
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        throw 'Install Rust with the Windows MSVC toolchain and Visual Studio C++ Build Tools, then rerun Repair.ps1. Or use the archive containing bin\.'
    }
    Push-Location $root
    try { Invoke-Checked 'cargo' @('build','--release','--locked','--workspace') } finally { Pop-Location }
    $bin = Join-Path $root 'target\release'
}
# Validate release-file integrity before executing any packaged executable.
$hashList = Join-Path $root 'SHA256SUMS.txt'
if (Test-Path -LiteralPath $hashList) {
    foreach ($line in Get-Content -LiteralPath $hashList) {
        if ($line -match '^([A-Fa-f0-9]{64})  (.+)$') {
            $path = Join-Path $root $Matches[2]
            $want = $Matches[1]
            if (-not (Test-Path -LiteralPath $path)) { throw "Release file missing: $path" }
            if ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -ne $want) { throw "Release integrity check failed: $path" }
        }
    }
}
# Fetch and checksum-verify Tor BEFORE stopping any existing service. Older
# cached Tor 0.4.8.10 is deliberately not shipped in this release.
& (Join-Path $root 'installer\stage.ps1')
foreach ($file in @('tor\tor.exe','tor\data\geoip','tor\data\geoip6','tun2socks.exe','wintun.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root "payload\$file"))) {
        throw "Missing payload\$file. Use the complete release archive."
    }
}
Write-Host "Backing up existing files to $backup"
New-Item -ItemType Directory -Path $backup -Force | Out-Null
foreach ($name in @('profile.toml','firewall-backup.json','routes.json','state.json','svc.log','tun2socks.log')) {
    $src = Join-Path $state $name
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $backup }
}
& netsh.exe advfirewall export (Join-Path $backup 'firewall-before-repair.wfw') | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Could not back up Windows Firewall; no installation files changed' }
if (Test-Path -LiteralPath $InstallDir) {
    Copy-Item -LiteralPath $InstallDir -Destination (Join-Path $backup 'previous-install') -Recurse
}
$service = Get-Service -Name TorVPN -ErrorAction SilentlyContinue
if ($service) {
    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name TorVPN
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(900))
    }
}
# Kill only this app's tray. Tor/tun2socks children belonging to the old
# installation are selected by executable path, never by generic image name.
Get-Process -Name torvpn-tray -ErrorAction SilentlyContinue | Stop-Process -Force
if ($service) {
    $old = Get-CimInstance Win32_Service -Filter "Name='TorVPN'"
    if ($old.PathName -match '^"([^"\r\n]+)"') {
        $oldRoot = Split-Path -Parent $Matches[1]
        Get-CimInstance Win32_Process | Where-Object {
            $_.ExecutablePath -and ($_.Name -match '^(tor|tun2socks.*)\.exe$') -and
            $_.ExecutablePath.StartsWith($oldRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
        } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
# ProgramData must be writable only by administrators/SYSTEM. The tray reads
# the token; unprivileged users must never be able to replace service scripts.
Invoke-Checked 'icacls.exe' @($state,'/inheritance:r','/grant:r','*S-1-5-18:(OI)(CI)F','*S-1-5-32-544:(OI)(CI)F','*S-1-5-32-545:(OI)(CI)RX')
Copy-Item -Path "$bin\torvpn-*.exe" -Destination $InstallDir -Force
Copy-Item -Path "$root\payload\*" -Destination $InstallDir -Recurse -Force
foreach ($folder in @('scripts','profiles')) {
    Copy-Item -LiteralPath (Join-Path $root $folder) -Destination $InstallDir -Recurse -Force
}
Copy-Item -LiteralPath "$root\Recover-Network.ps1" -Destination $InstallDir -Force
# Recover state from v0.3 or earlier before the new service starts.
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{StateDir=$state} | ConvertTo-Json -Compress)))
foreach ($script in @('route-teardown.ps1','dns-teardown.ps1','fw-teardown.ps1')) {
    Invoke-Checked "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',"$InstallDir\scripts\$script",'-JsonBase64',$encoded)
}
$profile = Join-Path $state 'profile.toml'
if (-not $PreserveProfile -or -not (Test-Path -LiteralPath $profile)) {
    Copy-Item -LiteralPath "$root\profiles\default_win.toml" -Destination $profile -Force
}
if ($NoConnect) {
    $text = Get-Content -LiteralPath $profile -Raw
    if ($text -match '(?m)^auto_connect\s*=') {
        $text = $text -replace '(?m)^auto_connect\s*=\s*true', 'auto_connect = false'
    } else { $text = "[startup]`nauto_connect = false`n`n" + $text }
    [IO.File]::WriteAllText($profile, $text, (New-Object Text.UTF8Encoding($false)))
}
$svc = Join-Path $InstallDir 'torvpn-svc.exe'
if ($service) {
    # Direct registry storage preserves quotes around Program Files paths.
    Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\TorVPN' -Name ImagePath -Value ('"' + $svc + '" service-run')
    Set-Service -Name TorVPN -StartupType Automatic
    Start-Service -Name TorVPN
} else { Invoke-Checked $svc @('service-install') }
Invoke-Checked 'sc.exe' @('failure','TorVPN','reset=','60','actions=','restart/5000/restart/5000/restart/5000')
$deadline = [DateTime]::UtcNow.AddSeconds(900)
$lastMessage = ''
$connectError = $null
do {
    try {
        $token = (Get-Content -LiteralPath (Join-Path $state 'api_token') -Raw).Trim()
        # Profile listen is local-only. Read exactly the scalar TOML line.
        $profileText = Get-Content -LiteralPath $profile -Raw
        $listen = '127.0.0.1:8787'
        if ($profileText -match '(?m)^listen\s*=\s*"([^"]+)"') { $listen = $Matches[1] }
        $status = Invoke-RestMethod -Uri "http://$listen/status" -Headers @{'X-TorVPN-Token'=$token} -TimeoutSec 5 -Proxy $null
        if ($status.message -ne $lastMessage) { Write-Host "[$($status.phase)] $($status.message)"; $lastMessage = $status.message }
        if ($status.phase -eq 'error') { throw "TORVPN_CONNECT_ERROR: $($status.message)" }
        if ($status.phase -eq 'engaged' -or ($NoConnect -and $status.phase -eq 'disengaged')) { break }
    } catch {
        if ($_.Exception.Message -like '*TORVPN_CONNECT_ERROR:*') {
            $connectError = $_.Exception.Message
            Write-Host "`nConnection failed. Installation is complete; open the tray's status or service log." -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red
            break
        }
        if ($_.Exception.Message -ne $lastMessage) { Write-Host "Waiting for service: $($_.Exception.Message)"; $lastMessage=$_.Exception.Message }
    }
    Start-Sleep -Milliseconds 750
} while ([DateTime]::UtcNow -lt $deadline)
# Preserve existing user autostart and point it at the repaired binary.
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
New-Item -Path $run -Force | Out-Null
Set-ItemProperty -Path $run -Name TorVPN -Value ('"' + (Join-Path $InstallDir 'torvpn-tray.exe') + '"')
Start-Process -FilePath (Join-Path $InstallDir 'torvpn-tray.exe')
Write-Host "`nInstalled TorVPN 0.3.1. Backup: $backup"
Write-Host "Service log: $state\svc.log"
Write-Host "Emergency recovery (Administrator): & '$InstallDir\Recover-Network.ps1'"
if ([DateTime]::UtcNow -ge $deadline) { throw 'Connection did not complete within 900 seconds; read svc.log' }

if ($connectError) { throw $connectError }

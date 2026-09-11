# =============================================================================
# TorVPN -- Installer staging script
# =============================================================================
# Downloads the third-party binaries we bundle into the installer:
#   * Tor Expert Bundle (windows-x86_64) from torproject.org
#   * tun2socks (windows-amd64) from xjasonlyu/tun2socks releases
#   * Wintun driver (amd64) from wintun.net
#
# Run from PowerShell in the installer\ directory:
#
#     cd installer
#     .\stage.ps1
#
# After staging, build the release binaries:
#
#     cd ..
#     cargo build --release -p torvpn-svc
#     cargo build --release -p torvpn-tray
#
# Then compile the Inno Setup script:
#
#     & "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\installer.iss
#
# Output: installer\Output\TorVPN-Setup-<version>.exe
# =============================================================================

[CmdletBinding()]
param(
    [string]$TorVersion       = "13.0.13",
    [string]$Tun2SocksVersion = "v2.5.2",
    [string]$WintunVersion    = "0.14.1",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ----- Resolve paths ----------------------------------------------------------
$StageDir  = Join-Path $PSScriptRoot "staging"
$DownloadDir = Join-Path $StageDir   "_downloads"
$TorDir    = Join-Path $StageDir "tor"
$T2sDir    = Join-Path $StageDir "tun2socks"
$WtnDir    = Join-Path $StageDir "wintun"
$IconsDir  = Join-Path $StageDir "icons"

foreach ($d in @($StageDir, $DownloadDir, $TorDir, $T2sDir, $WtnDir, $IconsDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

function Get-File {
    param([string]$Url, [string]$Out)
    if ((Test-Path $Out) -and (-not $Force)) {
        Write-Host "  [cache] $Out"
        return
    }
    Write-Host "  [GET ] $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing
}

# =============================================================================
# 1. Tor Expert Bundle
# =============================================================================
Write-Host "[*] Staging Tor $TorVersion ..."
$torArchive = Join-Path $DownloadDir "tor-expert-bundle.tar.gz"
$torUrl = "https://archive.torproject.org/tor-package-archive/torbrowser/$TorVersion/tor-expert-bundle-windows-x86_64-$TorVersion.tar.gz"
Get-File -Url $torUrl -Out $torArchive

# Extract -- Windows 10+ ships with tar.exe
$torExtractDir = Join-Path $DownloadDir "tor-extract"
if (Test-Path $torExtractDir) { Remove-Item -Recurse -Force $torExtractDir }
New-Item -ItemType Directory -Path $torExtractDir | Out-Null
& tar.exe -xzf $torArchive -C $torExtractDir
if ($LASTEXITCODE -ne 0) { throw "tar.exe failed extracting Tor bundle" }

# Bundle layout:
#   tor\tor.exe
#   tor\libssl-3-x64.dll
#   tor\libcrypto-3-x64.dll
#   tor\zlib1.dll
#   ... pluggable-transports\obfs4proxy.exe, snowflake-client.exe
#   data\geoip, geoip6
$bundleTorDir = Join-Path $torExtractDir "tor"
$bundleDataDir = Join-Path $torExtractDir "data"

if (-not (Test-Path (Join-Path $bundleTorDir "tor.exe"))) {
    throw "tor.exe not found at $bundleTorDir -- bundle layout changed?"
}

# Copy tor.exe and its DLLs
Copy-Item -Path (Join-Path $bundleTorDir "tor.exe") -Destination $TorDir -Force
Copy-Item -Path (Join-Path $bundleTorDir "*.dll")   -Destination $TorDir -Force

# Copy geoip files (Tor needs these for ExitNodes country selection)
$torDataOut = Join-Path $TorDir "data"
New-Item -ItemType Directory -Force -Path $torDataOut | Out-Null
if (Test-Path $bundleDataDir) {
    Copy-Item -Path (Join-Path $bundleDataDir "*") -Destination $torDataOut -Recurse -Force
}

Write-Host "  [ok ] tor.exe + DLLs + geoip staged"

# =============================================================================
# 2. tun2socks (xjasonlyu/tun2socks -- Wintun-capable build)
# =============================================================================
Write-Host "[*] Staging tun2socks $Tun2SocksVersion ..."
$t2sZip = Join-Path $DownloadDir "tun2socks.zip"
$t2sUrl = "https://github.com/xjasonlyu/tun2socks/releases/download/$Tun2SocksVersion/tun2socks-windows-amd64.zip"
Get-File -Url $t2sUrl -Out $t2sZip

$t2sExtractDir = Join-Path $DownloadDir "tun2socks-extract"
if (Test-Path $t2sExtractDir) { Remove-Item -Recurse -Force $t2sExtractDir }
Expand-Archive -Path $t2sZip -DestinationPath $t2sExtractDir -Force

# Find tun2socks-windows-amd64.exe (release naming varies slightly)
$t2sExe = Get-ChildItem -Path $t2sExtractDir -Recurse -Filter "tun2socks*.exe" |
          Select-Object -First 1
if (-not $t2sExe) { throw "tun2socks*.exe not found in $t2sExtractDir" }

Copy-Item -Path $t2sExe.FullName -Destination (Join-Path $T2sDir "tun2socks.exe") -Force
Write-Host "  [ok ] tun2socks.exe staged"

# =============================================================================
# 3. Wintun driver
# =============================================================================
Write-Host "[*] Staging Wintun $WintunVersion ..."
$wtnZip = Join-Path $DownloadDir "wintun.zip"
$wtnUrl = "https://www.wintun.net/builds/wintun-$WintunVersion.zip"
Get-File -Url $wtnUrl -Out $wtnZip

$wtnExtractDir = Join-Path $DownloadDir "wintun-extract"
if (Test-Path $wtnExtractDir) { Remove-Item -Recurse -Force $wtnExtractDir }
Expand-Archive -Path $wtnZip -DestinationPath $wtnExtractDir -Force

# Layout: wintun\bin\amd64\wintun.dll
$wtnDll = Join-Path $wtnExtractDir "wintun\bin\amd64\wintun.dll"
if (-not (Test-Path $wtnDll)) {
    # Fallback search
    $wtnDll = (Get-ChildItem -Path $wtnExtractDir -Recurse -Filter "wintun.dll" |
               Where-Object { $_.FullName -like "*amd64*" } |
               Select-Object -First 1).FullName
}
if (-not $wtnDll -or -not (Test-Path $wtnDll)) {
    throw "wintun.dll (amd64) not found in $wtnExtractDir"
}
Copy-Item -Path $wtnDll -Destination (Join-Path $WtnDir "wintun.dll") -Force
Write-Host "  [ok ] wintun.dll staged"

# =============================================================================
# 4. App icon -- placeholder if user hasn't supplied one
# =============================================================================
$iconPath = Join-Path $IconsDir "app.ico"
if (-not (Test-Path $iconPath)) {
    Write-Host "[*] No app.ico found -- generating a 16x16 placeholder..."
    # Minimal 16x16 ICO with a single dark-red filled square. Real branding
    # should drop a proper multi-resolution .ico at staging\icons\app.ico
    # before running stage.ps1 again.
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.FillEllipse([System.Drawing.Brushes]::DarkRed, 2, 2, 28, 28)
    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $fs = [System.IO.File]::Create($iconPath)
    $icon.Save($fs)
    $fs.Close()
    $bmp.Dispose()
    Write-Host "  [ok ] placeholder icon at $iconPath"
}

Write-Host ""
Write-Host "[+] Staging complete."
Write-Host ""

# =============================================================================
# Inventory: print what actually landed in staging\ so the user can verify
# before invoking ISCC. Inno Setup's [Files] section references each of these
# paths; if anything's missing, that's where to look first.
# =============================================================================
Write-Host "    Staging inventory:"
$expected = @(
    @{Path = "staging\tor\tor.exe";          Required = $true;  Note = "Tor daemon (statically linked on modern bundles)"},
    @{Path = "staging\tor\*.dll";            Required = $false; Note = "Empty on Tor 0.4.7+ -- ok"},
    @{Path = "staging\tor\data\geoip";       Required = $true;  Note = "IPv4 geoip (for ExitNodes country selection)"},
    @{Path = "staging\tor\data\geoip6";      Required = $true;  Note = "IPv6 geoip"},
    @{Path = "staging\tun2socks\tun2socks.exe"; Required = $true; Note = "TUN-to-SOCKS bridge"},
    @{Path = "staging\wintun\wintun.dll";    Required = $true;  Note = "Wintun driver"},
    @{Path = "staging\icons\app.ico";        Required = $true;  Note = "App icon (placeholder if you didn't supply one)"}
)
foreach ($e in $expected) {
    $full = Join-Path $PSScriptRoot $e.Path
    $found = Get-Item $full -ErrorAction SilentlyContinue
    if ($found) {
        $size = if ($found -is [System.IO.FileInfo]) { "{0,8:N0} bytes" -f $found.Length } else { "(glob)" }
        Write-Host ("      [ok ] {0,-38} {1}  {2}" -f $e.Path, $size, $e.Note)
    } elseif ($e.Required) {
        Write-Warning ("      [MISS] {0}  -- REQUIRED, ISCC will fail" -f $e.Path)
    } else {
        Write-Host ("      [skip] {0,-38} (none)     {1}" -f $e.Path, $e.Note)
    }
}

Write-Host ""
Write-Host "    Next steps (from repo root):"
Write-Host "      cargo build --release -p torvpn-svc"
Write-Host "      cargo build --release -p torvpn-tray"
Write-Host "      & `"C:\Program Files (x86)\Inno Setup 6\ISCC.exe`" installer\installer.iss"

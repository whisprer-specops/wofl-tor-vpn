#Requires -Version 5.1
[CmdletBinding()]
param([string]$PayloadDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'payload'))
$ErrorActionPreference = 'Stop'
# Pinned from Tor Project's published 15.0.26 signed-build checksums.
# The archive is fetched only from the official distribution endpoint.
$version = '15.0.26'
$hash = 'c1988c701de2f24f7d098d1d6d7f507b58f27740d097f29c246e0524d639b252'
$name = "tor-expert-bundle-windows-x86_64-$version.tar.gz"
$url = "https://dist.torproject.org/torbrowser/$version/$name"
$cache = Join-Path $env:LOCALAPPDATA 'torvpn-downloads'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
$archive = Join-Path $cache $name
if (-not (Test-Path -LiteralPath $archive) -or (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash -ne $hash) {
    Write-Host "Downloading current pinned Tor Expert Bundle $version (about 21 MB)..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $partial = $archive + '.partial'
    try {
        Invoke-WebRequest -Uri $url -OutFile $partial -UseBasicParsing -TimeoutSec 180
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $partial).Hash -ne $hash) {
            throw 'Tor archive checksum mismatch. Download rejected; no installation/network changes made.'
        }
        Move-Item -LiteralPath $partial -Destination $archive -Force
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
}
$temp = Join-Path $cache ('extract-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    & tar.exe -xzf $archive -C $temp
    if ($LASTEXITCODE -ne 0) { throw 'Tor extraction failed' }
    foreach ($entry in @('tor\tor.exe','data\geoip','data\geoip6')) {
        if (-not (Test-Path -LiteralPath (Join-Path $temp $entry))) { throw "Tor bundle layout changed; missing $entry" }
    }
    $out = Join-Path $PayloadDir 'tor'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    Copy-Item -Path "$temp\tor\*" -Destination $out -Recurse -Force
    New-Item -ItemType Directory -Path "$out\data" -Force | Out-Null
    Copy-Item -Path "$temp\data\*" -Destination "$out\data" -Recurse -Force
    Write-Host "Tor $version staged after SHA-256 verification."
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }

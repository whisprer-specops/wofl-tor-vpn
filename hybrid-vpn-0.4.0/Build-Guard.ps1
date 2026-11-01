#requires -Version 7.0
$ErrorActionPreference='Stop'
Push-Location "$PSScriptRoot\guard"
try {
    & cargo build --release --locked --target x86_64-pc-windows-msvc
    if($LASTEXITCODE -ne 0){throw 'Guard build failed. Rust 1.99.1 and VS C++ Build Tools are required.'}
    Copy-Item -LiteralPath '.\target\x86_64-pc-windows-msvc\release\whispr-vpn-guard.exe' -Destination "$PSScriptRoot\bin\whispr-vpn-guard.exe" -Force
    $path=Join-Path $PSScriptRoot 'SHA256SUMS.json'
    $manifest=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    $manifest['bin/whispr-vpn-guard.exe']=(Get-FileHash -LiteralPath "$PSScriptRoot\bin\whispr-vpn-guard.exe" -Algorithm SHA256).Hash
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
}finally{Pop-Location}
Write-Host 'Guard rebuilt and its release manifest entry updated. Rebuilding is optional; a compiled Windows x64 guard is included.'

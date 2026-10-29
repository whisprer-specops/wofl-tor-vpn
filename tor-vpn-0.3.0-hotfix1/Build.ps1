#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    & cargo build --release --locked --workspace
    if ($LASTEXITCODE -ne 0) { throw 'Rust build failed' }
    New-Item -ItemType Directory -Path "$PSScriptRoot\bin" -Force | Out-Null
    Copy-Item -Path "$PSScriptRoot\target\release\torvpn-*.exe" -Destination "$PSScriptRoot\bin" -Force
    # Refresh only the two hashes whose locally built bytes changed.
    $hashFile = Join-Path $PSScriptRoot 'SHA256SUMS.txt'
    if (Test-Path -LiteralPath $hashFile) {
        $lines = @(Get-Content -LiteralPath $hashFile | Where-Object { $_ -notmatch '  bin/torvpn-(svc|tray)\.exe$' })
        foreach ($name in @('torvpn-svc.exe','torvpn-tray.exe')) {
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath "$PSScriptRoot\bin\$name").Hash.ToLowerInvariant()
            $lines += "$hash  bin/$name"
        }
        $lines | Set-Content -LiteralPath $hashFile -Encoding ASCII
    }
} finally { Pop-Location }
Write-Host 'Built binaries copied to bin\. Run Repair.ps1 as Administrator to install.'

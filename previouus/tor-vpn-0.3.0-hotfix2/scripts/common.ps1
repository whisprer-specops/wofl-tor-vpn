# Shared by the service's administrative scripts. Never accepts shell code.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
function Read-TorArgs([string]$Encoded) {
    if ($Encoded) {
        return ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Encoded)) | ConvertFrom-Json)
    }
    return [pscustomobject]@{ StateDir = (Join-Path $env:ProgramData 'torvpn') }
}
function Write-TorJson($Object, [string]$Path) {
    $temp = $Path + '.tmp'
    $Object | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

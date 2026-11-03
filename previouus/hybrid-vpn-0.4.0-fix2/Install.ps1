#requires -Version 7.0
#requires -RunAsAdministrator
[CmdletBinding()]
param([ValidateSet('nyc1','lon1','sgp1','syd1')][string]$Server='nyc1',[ValidateRange(1024,65535)][int]$Port=51832)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\client\Common.ps1"
. "$PSScriptRoot\client\Fetch-Tor.ps1"
. "$PSScriptRoot\client\Fetch-Engine.ps1"
Assert-HybridBaseline
Assert-HybridManifest $PSScriptRoot
$homeDir=Get-HybridHome
$stateDir=Get-HybridState
$ssh=(Get-Command ssh.exe -ErrorAction Stop).Source
$scp=(Get-Command scp.exe -ErrorAction Stop).Source
$guard=Join-Path $homeDir 'bin\whispr-vpn-guard.exe'
if (Test-Path -LiteralPath $guard) {
    $status=(& $guard status | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $status -ne 'DISARMED') { throw 'Run Recover.ps1 from the installed directory before updating.' }
}
foreach ($dir in @($homeDir,$stateDir)) {
    if(Test-Path -LiteralPath $dir){
        $owner=(Get-Acl -LiteralPath $dir).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if($owner -notin @('S-1-5-18','S-1-5-32-544')){throw 'An existing install/state directory is not owned by SYSTEM/Administrators. Refusing to trust its contents.'}
        $marker=Join-Path $dir 'install-owner.txt'
        if(@(Get-ChildItem -LiteralPath $dir -Force).Count -and (-not (Test-Path -LiteralPath $marker) -or (Get-Content -LiteralPath $marker -Raw).Trim() -ne 'whispr-hybrid-schema-1')){throw 'An existing directory contains unowned application data; refusing overwrite.'}
        if((Get-Item -LiteralPath $dir).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Install/state directory is a reparse point; refusing.'}
        if(@(Get-ChildItem -LiteralPath $dir -Recurse -Force | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'An install/state child is a reparse point; refusing.'}
    }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Invoke-HybridChecked icacls.exe @($dir,'/setowner','*S-1-5-32-544')
}
Invoke-HybridChecked icacls.exe @($homeDir,'/inheritance:r','/grant:r','*S-1-5-18:(OI)(CI)F','*S-1-5-32-544:(OI)(CI)F','*S-1-5-32-545:(OI)(CI)R')
# Keys, generated configurations and logs are administrators/SYSTEM only.
Invoke-HybridChecked icacls.exe @($stateDir,'/inheritance:r','/remove:g','*S-1-5-32-545','/grant:r','*S-1-5-18:(OI)(CI)F','*S-1-5-32-544:(OI)(CI)F','/T')
foreach($dir in @($homeDir,$stateDir)){'whispr-hybrid-schema-1' | Set-Content -LiteralPath (Join-Path $dir 'install-owner.txt') -Encoding utf8NoBOM}
foreach ($name in @('bin','client','server','docs','Start.ps1','Recover.ps1','Status.ps1','Uninstall.ps1','README.md','LICENSE','SHA256SUMS.json')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $homeDir -Recurse -Force
}
Install-HybridEngine $homeDir $stateDir
Install-HybridTor $homeDir $stateDir
# Preserve the same per-device private key on reinstallation. It never leaves this PC.
$keyPath=Join-Path $stateDir 'device-key.json'
if (Test-Path -LiteralPath $keyPath) { $key=Get-Content -LiteralPath $keyPath -Raw | ConvertFrom-Json -AsHashtable }
else {
    $pair=(& (Join-Path $homeDir 'bin\sing-box.exe') generate wg-keypair | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'WireGuard key generation failed.' }
    $private=[regex]::Match($pair,'(?m)^PrivateKey:\s*(\S+)').Groups[1].Value
    $public=[regex]::Match($pair,'(?m)^PublicKey:\s*(\S+)').Groups[1].Value
    if ($private -notmatch '^[A-Za-z0-9+/]{43}=$' -or $public -notmatch '^[A-Za-z0-9+/]{43}=$') { throw 'Unexpected key generator output.' }
    $key=@{PrivateKey=$private;PublicKey=$public}
    Write-HybridJson $key $keyPath
    $pair=$null;$private=$null
}
foreach($field in @('PrivateKey','PublicKey')){
    if($key[$field] -notmatch '^[A-Za-z0-9+/]{43}=$'){throw 'Stored device key has invalid encoding; no server command was sent.'}
}
$sshConfig=@(& $ssh -G $Server)
if ($LASTEXITCODE -ne 0) { throw 'Cannot read SSH alias.' }
$hostLine=@($sshConfig | Where-Object { $_ -match '^hostname ' })
if ($hostLine.Count -ne 1) { throw 'SSH hostname is ambiguous.' }
$endpoint=[Net.IPAddress]::Parse(($hostLine[0] -split '\s+',2)[1])
if ($endpoint.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'The transport endpoint must be a numeric public IPv4 address.' }
$stage=(& $ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=12 $Server 'mktemp -d /tmp/whispr-hybrid-XXXXXXXX' | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $stage -notmatch '^/tmp/whispr-hybrid-[A-Za-z0-9]+$') { throw 'Could not create secure server staging directory.' }
try {
    Invoke-HybridChecked $scp @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',"$PSScriptRoot\server\setup.py","$PSScriptRoot\server\firewall.py","$PSScriptRoot\server\manage.py","${Server}:$stage/")
    $a=(Get-FileHash -Algorithm SHA256 -LiteralPath "$PSScriptRoot\server\setup.py").Hash.ToLowerInvariant()
    $b=(Get-FileHash -Algorithm SHA256 -LiteralPath "$PSScriptRoot\server\firewall.py").Hash.ToLowerInvariant()
    $c=(Get-FileHash -Algorithm SHA256 -LiteralPath "$PSScriptRoot\server\manage.py").Hash.ToLowerInvariant()
    $remote="printf '%s  %s\n' '$a' '$stage/setup.py' '$b' '$stage/firewall.py' '$c' '$stage/manage.py' | sha256sum -c - && sudo python3 -I '$stage/setup.py' --public-key '$($key.PublicKey)' --port $Port --report '$stage/report.json'"
    Write-Host "`nEnter the $Server wofl SUDO password when asked. This step installs/configures the dedicated server exit." -ForegroundColor Yellow
    Invoke-HybridChecked $ssh @('-t','-o','StrictHostKeyChecking=yes',$Server,$remote)
    $report=Join-Path $stateDir 'server-report.json'
    Invoke-HybridChecked $scp @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',"${Server}:$stage/report.json",$report)
    $peer=Get-Content -LiteralPath $report -Raw | ConvertFrom-Json -AsHashtable
    if ($peer.client_public_key -ne $key.PublicKey -or $peer.schema -ne 1) { throw 'Server report does not match this device.' }
    $peer.endpoint=$endpoint.ToString();$peer.ssh_alias=$Server
    Write-HybridJson $peer (Join-Path $stateDir 'peer.json')
} finally {
    # Remove only the unique staging directory created above; server state stays root-protected.
    & $ssh -o BatchMode=yes -o ConnectTimeout=8 $Server "rm -f '$stage/setup.py' '$stage/firewall.py' '$stage/manage.py' '$stage/report.json'; rmdir '$stage'" | Out-Null
}
Write-Host "`nInstalled to $homeDir. No client tunnel, guard, service or boot task has been activated." -ForegroundColor Cyan
Write-Host "First session (same elevated PowerShell): & '$homeDir\Start.ps1'"
Write-Host "Explicit stop/recovery: & '$homeDir\Recover.ps1'"
Write-Host 'This is a release candidate. Windows crash/leak and coexistence validation is still required.' -ForegroundColor Yellow

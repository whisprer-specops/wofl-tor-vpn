#requires -Version 7.0
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('nyc1','lon1','sgp1','syd1')][string]$Server,
      [ValidateRange(1024,65535)][int]$Port=51832,[switch]$Pause)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/client/Common.ps1"
. "$PSScriptRoot/tray/Model.ps1"
$mutex=$null;$stage=$null;$report=$null;$ssh=$null
try {
    $homeDir=Get-HybridHome;$stateDir=Get-HybridState
    if($PSScriptRoot -ne $homeDir){throw 'Use the installed Prepare-Exit.ps1.'}
    Assert-HybridManifest $homeDir
    Assert-TrayAddon $homeDir
    $mutex=Enter-TraySessionLock
    Assert-TrayDisconnected $homeDir
    Assert-HybridBaseline
    $key=Get-Content -LiteralPath (Join-Path $stateDir 'device-key.json') -Raw | ConvertFrom-Json -AsHashtable
    if($key.PublicKey -notmatch '^[A-Za-z0-9+/]{43}=$'){throw 'Invalid device public key.'}
    $ssh=(Get-Command ssh.exe -ErrorAction Stop).Source;$scp=(Get-Command scp.exe -ErrorAction Stop).Source
    $sshConfig=@(& $ssh -G $Server)
    if($LASTEXITCODE -ne 0){throw 'Could not resolve the selected SSH alias.'}
    $hostLine=@($sshConfig | Where-Object {$_ -match '^hostname '})
    if($hostLine.Count -ne 1){throw 'SSH endpoint is ambiguous.'}
    $endpoint=[Net.IPAddress]::Parse(($hostLine[0] -split '\s+',2)[1])
    if($endpoint.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'A literal IPv4 SSH endpoint is required.'}
    $stage=(& $ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=12 $Server 'mktemp -d /tmp/whispr-hybrid-XXXXXXXX' | Out-String).Trim()
    if($LASTEXITCODE -ne 0 -or $stage -notmatch '^/tmp/whispr-hybrid-[A-Za-z0-9]+$'){throw 'Could not create server staging directory. Existing peer retained.'}
    Invoke-HybridChecked $scp @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',"$homeDir/server/setup.py","$homeDir/server/firewall.py","$homeDir/server/manage.py","${Server}:$stage/")
    $a=(Get-FileHash "$homeDir/server/setup.py" -Algorithm SHA256).Hash.ToLowerInvariant()
    $b=(Get-FileHash "$homeDir/server/firewall.py" -Algorithm SHA256).Hash.ToLowerInvariant()
    $c=(Get-FileHash "$homeDir/server/manage.py" -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "Enter the $Server wofl SUDO password when prompted. Input is hidden." -ForegroundColor Yellow
    $remote="printf '%s  %s\n' '$a' '$stage/setup.py' '$b' '$stage/firewall.py' '$c' '$stage/manage.py' | sha256sum -c - && sudo python3 -I '$stage/setup.py' --public-key '$($key.PublicKey)' --port $Port --report '$stage/report.json'"
    Invoke-HybridChecked $ssh @('-t','-o','StrictHostKeyChecking=yes',$Server,$remote)
    $report=Join-Path $stateDir ('tray-exit-report-'+[guid]::NewGuid().ToString('N')+'.json')
    Invoke-HybridChecked $scp @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',"${Server}:$stage/report.json",$report)
    $peer=Get-Content -LiteralPath $report -Raw | ConvertFrom-Json -AsHashtable
    $peer.endpoint=$endpoint.ToString();$peer.ssh_alias=$Server
    Assert-TrayPeer $peer $Server
    if($peer.client_public_key -ne $key.PublicKey -or [int]$peer.port -ne $Port){throw 'Server report does not match this request.'}
    $profiles=Join-Path $stateDir 'profiles';[void](New-Item -ItemType Directory -Path $profiles -Force)
    Write-HybridJson $peer (Join-Path $profiles "$Server.json")
    Write-Host "Prepared $Server. Active peer.json was not changed. Select this exit from the tray while disconnected." -ForegroundColor Green
    Write-Host "DigitalOcean inbound UDP $Port must be allowed on this VPS. A successful TCP-only rule is insufficient." -ForegroundColor Yellow
} catch {Write-Error $_ -ErrorAction Continue;exit 1}
finally {
    if($stage -match '^/tmp/whispr-hybrid-[A-Za-z0-9]+$' -and $ssh){& $ssh -o BatchMode=yes -o ConnectTimeout=8 $Server "rm -f '$stage/setup.py' '$stage/firewall.py' '$stage/manage.py' '$stage/report.json'; rmdir '$stage'" | Out-Null}
    if($report -and (Test-Path -LiteralPath $report)){Remove-Item -LiteralPath $report -Force}
    if($mutex){$mutex.ReleaseMutex();$mutex.Dispose()}
    if($Pause){[void](Read-Host 'Press Enter to close this preparation window')}
}

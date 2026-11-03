#requires -Version 7.0
#requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$OwnerAlreadyStopped)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\client\Common.ps1"
$homeDir=Get-HybridHome;$stateDir=Get-HybridState
if($PSScriptRoot -ne $homeDir){throw "Use the installed recovery script in $homeDir"}
$guard=Join-Path $homeDir 'bin\whispr-vpn-guard.exe'
$path=Join-Path $stateDir 'session.json'
$session=if(Test-Path -LiteralPath $path){Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable}else{$null}
if($session -and -not $OwnerAlreadyStopped){
    $p=Get-Process -Id $session.OwnerPid -ErrorAction SilentlyContinue
    if($p -and $p.StartTime.ToUniversalTime().Ticks -eq $session.OwnerStartedTicks -and $p.Path -eq $session.OwnerPath){
        $details=Get-CimInstance Win32_Process -Filter "ProcessId=$($session.OwnerPid)"
        if($details.CommandLine -notlike "*$homeDir\client\Session.ps1*"){throw 'Session process identity check failed. Protection retained.'}
        Write-Host 'Stopping the dedicated session process and its owned transport job...'
        $p.Kill();if(-not $p.WaitForExit(10000)){throw 'Owned session did not stop. Protection retained.'}
    }
}
$adapter=Get-NetAdapter -Name 'whispr-hybrid' -IncludeHidden -ErrorAction SilentlyContinue
if($adapter){
    if(-not $session -or -not $session.TunnelGuid -or [string]$adapter.InterfaceGuid -ne $session.TunnelGuid){throw 'TUN ownership is not established; no adapter or guard policy was removed.'}
    # Remove only the exact instance created in the recorded session, never a driver package or another VPN adapter.
    $guid=([string]$adapter.InterfaceGuid).Trim('{}')
    $device=@(Get-CimInstance Win32_NetworkAdapter | Where-Object {$_.GUID -and ([string]$_.GUID).Trim('{}') -eq $guid})
    if($device.Count -ne 1 -or -not $device[0].PNPDeviceID){throw 'Could not map the owned TUN GUID to one PnP device. Protection retained.'}
    Invoke-HybridChecked (Join-Path $env:SystemRoot 'System32\pnputil.exe') @('/remove-device',[string]$device[0].PNPDeviceID)
    Start-Sleep -Milliseconds 500
    if(Get-NetAdapter -Name 'whispr-hybrid' -ErrorAction SilentlyContinue){throw 'Owned TUN remains present after device removal. Protection retained.'}
}
# The transaction removes our fixed filter keys, sublayer and provider only.
Invoke-HybridChecked $guard @('recover')
if($session){$session.State='disconnected';Write-HybridJson $session $path}
Write-Host 'Disconnected. Owned TUN and guard policy removed; other firewall profiles, rules and VPN adapters retained.' -ForegroundColor Cyan

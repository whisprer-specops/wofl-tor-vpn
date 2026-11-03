#requires -Version 7.0
#requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$WaitForVerification)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/client/Common.ps1"
. "$PSScriptRoot/tray/Model.ps1"
. "$PSScriptRoot/background/Launch.ps1"
$homeDir=Get-HybridHome;$stateDir=Get-HybridState
if($PSScriptRoot -ne $homeDir){throw 'Use the installed Start-Background.ps1.'}
$hostProcess=Start-HybridBackground $homeDir $stateDir
try {
    Write-Host "Independent background host started (PID $($hostProcess.Id)). The VPN is not verified yet."
    Write-Host 'You may close this terminal. Use the tray for status and Disconnect / Recover.'
    Write-Host "Manual recovery: & '$homeDir\Recover.ps1'"
    if($WaitForVerification){
        $deadline=[datetime]::UtcNow.AddSeconds(300)
        while([datetime]::UtcNow -lt $deadline){
            if($hostProcess.HasExited){throw 'The background session ended. Read its background-*-session and background-*-host logs; protection may remain armed.'}
            $recordPath=Join-Path $stateDir 'background-host.json';$sessionPath=Join-Path $stateDir 'session.json'
            if((Test-Path -LiteralPath $recordPath) -and (Test-Path -LiteralPath $sessionPath)){
                $hostRecord=Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable
                $session=Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json -AsHashtable
                if($hostRecord.HostPid -eq $hostProcess.Id -and $session.OwnerPid -eq $hostRecord.SessionPid -and $session.OwnerStartedTicks -eq $hostRecord.SessionStartedTicks -and $session.State -eq 'verified-session'){
                    Write-Host "Verified background session: TCP/Tor $($session.TcpExit), UDP $($session.UdpExit). This terminal can now be closed." -ForegroundColor Green
                    return
                }
            }
            Start-Sleep -Seconds 1
        }
        throw 'Background startup has not verified within 300 seconds. It was not automatically disconnected; inspect the tray/status/logs or use Recover.ps1.'
    }
}finally{$hostProcess.Dispose()}

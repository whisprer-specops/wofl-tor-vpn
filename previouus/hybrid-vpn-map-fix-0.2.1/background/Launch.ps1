#requires -Version 7.0
. "$PSScriptRoot/Scheduler.ps1"
function Start-HybridBackground {
    [CmdletBinding()]
    param([string]$InstallRoot,[string]$StateRoot,[switch]$ResumeProtection)
    Assert-HybridManifest $InstallRoot;Assert-TrayAddon $InstallRoot
    $mutex=Enter-TraySessionLock
    try{
        if($ResumeProtection){
            . "$InstallRoot/background/Resume.ps1"
            $guard=(& (Join-Path $InstallRoot 'bin/whispr-vpn-guard.exe') status|Out-String).Trim()
            if($LASTEXITCODE -ne 0 -or $guard -notin @('ARMED','DISARMED')){throw 'Cannot establish protection state.'}
            if($guard -eq 'ARMED'){
                $peer=Get-Content -LiteralPath (Join-Path $StateRoot 'peer.json') -Raw|ConvertFrom-Json -AsHashtable
                $key=Get-Content -LiteralPath (Join-Path $StateRoot 'device-key.json') -Raw|ConvertFrom-Json -AsHashtable
                $null=Assert-HybridResume $peer $key.PublicKey $InstallRoot $StateRoot
            }else{Assert-TrayDisconnected $InstallRoot}
        }else{Assert-TrayDisconnected $InstallRoot}
    }finally{$mutex.ReleaseMutex();$mutex.Dispose()}
    $id=[guid]::NewGuid().ToString('N');$prefix=Join-Path $StateRoot "background-$id-host"
    $bootstrap=Join-Path $InstallRoot 'background/Scheduled-Host.ps1'
    $service=Get-HybridScheduler
    try {
        $name=Get-HybridTaskName
        $task=Register-HybridDemandTask $service $name $bootstrap $id
        Write-HybridJson @{Schema=1;LaunchId=$id;TaskName=$name;HostLogPrefix=$prefix;StartedUtc=[datetime]::UtcNow.ToString('o')} (Join-Path $StateRoot 'background-launch.json')
        [void]$task.Run($null)
        $started=[datetime]::UtcNow;$deadline=$started.AddSeconds(30)
        $recordPath=Join-Path $StateRoot 'background-host.json'
        while([datetime]::UtcNow -lt $deadline){
            if(Test-Path -LiteralPath $recordPath){
                $record=Get-Content -LiteralPath $recordPath -Raw|ConvertFrom-Json -AsHashtable
                if($record.LaunchId -eq $id){
                    $process=[Diagnostics.Process]::GetProcessById([int]$record.HostPid)
                    if($process.StartTime.ToUniversalTime().Ticks -ne [long]$record.HostStartedTicks -or $process.MainModule.FileName -ne (Join-Path $PSHOME 'pwsh.exe')){$process.Dispose();throw 'Background host process identity mismatch.'}
                    return $process
                }
            }
            if(([datetime]::UtcNow-$started).TotalSeconds -gt 3 -and $task.State -notin @(2,4)){
                throw "Background task ended before publishing its host identity (task result $($task.LastTaskResult)). Read Open background error log."
            }
            Start-Sleep -Milliseconds 100
        }
        throw 'Background task did not publish a host identity within 30 seconds. It was not automatically stopped; inspect the tray/logs or use Recover.ps1.'
    }finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($service)}
}

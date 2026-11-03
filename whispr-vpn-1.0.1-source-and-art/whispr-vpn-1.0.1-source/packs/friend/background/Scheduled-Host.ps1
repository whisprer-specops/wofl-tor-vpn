#requires -Version 7.0
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$LaunchId,[string]$ProbeScript='')
$ErrorActionPreference='Stop'
$installRoot=Join-Path $env:ProgramFiles 'whispr Hybrid VPN'
$stateRoot=Join-Path $env:ProgramData 'whispr-hybrid'
$job=$null;$result=1
try {
    $target=Join-Path $PSScriptRoot 'Host.ps1'
    $working=$installRoot
    if($ProbeScript){
        $target=[IO.Path]::GetFullPath($ProbeScript)
        $working=Join-Path $stateRoot "scheduled-selfcheck-$LaunchId"
        if($target -ne (Join-Path $working 'probe.ps1')){throw 'Invalid scheduler probe path.'}
    }
    Add-Type -Path (Join-Path $installRoot 'client/ProcessJob.cs')
    $job=[HybridProcessJob]::new()
    # Scheduler owns this bootstrap. Its worker has no console and independent file logs.
    $prefix=Join-Path $stateRoot "background-$LaunchId-host"
    $worker=$job.Start((Join-Path $PSHOME 'pwsh.exe'),[string[]]@('-NoLogo','-NoProfile','-NonInteractive','-File',$target,'-LaunchId',$LaunchId),$working,$prefix)
    [void]$worker.WaitForExit()
    $result=$worker.ExitCode
} catch {
    try{[IO.File]::AppendAllText((Join-Path $stateRoot "background-$LaunchId-host-stderr.log"),$_.Exception.ToString()+[Environment]::NewLine)}catch{}
    $result=1
}finally{if($job){$job.Dispose()}}
exit $result

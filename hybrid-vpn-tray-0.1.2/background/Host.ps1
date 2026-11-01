#requires -Version 7.0
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$LaunchId)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../client/Common.ps1"
. "$PSScriptRoot/../tray/Model.ps1"
$homeDir=Get-HybridHome;$stateDir=Get-HybridState
$mutex=[Threading.Mutex]::new($false,'Global\whisprHybridBackground011')
$locked=$false;$hostJob=$null;$record=$null;$result=1
try {
    if((Split-Path $PSScriptRoot -Parent) -ne $homeDir){throw 'Use the installed background host.'}
    try{$locked=$mutex.WaitOne(10000)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'A background host already owns a session.'}
    Assert-HybridManifest $homeDir;Assert-TrayAddon $homeDir
    Add-Type -Path "$PSScriptRoot/SessionHost.cs"
    $hostJob=[HybridBackgroundSessionHost]::new()
    $sessionLog=Join-Path $stateDir "background-$LaunchId-session"
    $session=$hostJob.Start((Join-Path $PSHOME 'pwsh.exe'),(Join-Path $homeDir 'client/Session.ps1'),$homeDir,$sessionLog)
    $record=@{Schema=1;LaunchId=$LaunchId;HostPid=$PID;HostStartedTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks;SessionPid=$session.Id;SessionStartedTicks=$session.StartTime.ToUniversalTime().Ticks;State='running';SessionLogPrefix=$sessionLog;StartedUtc=[DateTime]::UtcNow.ToString('o')}
    Write-HybridJson $record (Join-Path $stateDir 'background-host.json')
    # Keep the managed input writer and owning job alive, independently of any UI or terminal.
    while(-not $session.WaitForExit(1000)){}
    $result=$session.ExitCode;$record.State=if($result -eq 0){'session-ended'}else{'session-failed'}
    $record.ExitCode=$result;$record.EndedUtc=[DateTime]::UtcNow.ToString('o')
    Write-HybridJson $record (Join-Path $stateDir 'background-host.json')
} catch {
    Write-Error $_ -ErrorAction Continue
    if($record){$record.State='host-failed';$record.Error=$_.Exception.Message;try{Write-HybridJson $record (Join-Path $stateDir 'background-host.json')}catch{}}
    $result=1
} finally {
    if($hostJob){$hostJob.Dispose()}
    if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()
}
exit $result

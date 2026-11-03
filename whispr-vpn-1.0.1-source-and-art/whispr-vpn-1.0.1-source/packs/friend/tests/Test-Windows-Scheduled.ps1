#requires -Version 7.0
[CmdletBinding()]
param([string]$StateRoot)
$ErrorActionPreference='Stop'
if(-not $IsWindows){Write-Host 'SKIP: Windows Task Scheduler self-check requires Windows.';return}
$root=Split-Path $PSScriptRoot -Parent
. "$root/background/Scheduler.ps1"
if(-not $StateRoot){$StateRoot=Join-Path $env:ProgramData 'whispr-hybrid'}
$id=[guid]::NewGuid().ToString('N');$name='whispr-HybridVPN-Probe-'+$id
$directory=Join-Path $StateRoot "scheduled-selfcheck-$id"
[void](New-Item -ItemType Directory -Path $directory)
$service=$null;$task=$null
try {
    # Task actions point only into the existing protected state tree, never the downloads folder.
    Copy-Item -LiteralPath "$root/background/Scheduled-Host.ps1" -Destination (Join-Path $directory 'Scheduled-Host.ps1')
    Copy-Item -LiteralPath "$root/background/SessionHost.cs" -Destination (Join-Path $directory 'SessionHost.cs')
    $probe=Join-Path $directory 'probe.ps1'
    @'
param([string]$LaunchId)
$ErrorActionPreference='Stop'
$directory=$PSScriptRoot
$owner=$null;$watched=$null;$nested=$null
try {
    Add-Type -Path "$directory/SessionHost.cs"
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class ProbeConsole { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'
    if([ProbeConsole]::GetConsoleWindow() -ne [IntPtr]::Zero){throw 'The scheduler worker unexpectedly has a console.'}
    $fixture=Join-Path $directory 'input-probe.ps1'
    $fixtureText=@(
        '$ErrorActionPreference="Stop"',
        '$directory=$PSScriptRoot',
        'Add-Type -Path (Join-Path $env:ProgramFiles "whispr Hybrid VPN/client/ProcessJob.cs")',
        '$job=[HybridProcessJob]::new()',
        'try {',
        ' $child=$job.Start((Join-Path $PSHOME "pwsh.exe"),[string[]]@("-NoLogo","-NoProfile","-Command","Start-Sleep -Seconds 30"),$directory,(Join-Path $directory "dummy"))',
        ' $value=@{Pid=$PID;NestedPid=$child.Id;NestedTicks=$child.StartTime.ToUniversalTime().Ticks;InputRedirected=[Console]::IsInputRedirected}',
        ' $file=Join-Path $directory "input-ready.json"',
        ' [IO.File]::WriteAllText(($file+".tmp"),($value|ConvertTo-Json));[IO.File]::Move(($file+".tmp"),$file)',
        ' if($null -eq [Console]::ReadLine()){throw "Unexpected input EOF"}',
        '} finally {$job.Dispose()}'
    )
    $fixtureText | Set-Content -LiteralPath $fixture -Encoding utf8NoBOM
    $owner=[HybridBackgroundSessionHost]::new()
    $session=$owner.Start((Join-Path $PSHOME 'pwsh.exe'),$fixture,$directory,(Join-Path $directory 'session'))
    $file=Join-Path $directory 'input-ready.json';$deadline=[datetime]::UtcNow.AddSeconds(15)
    while(-not (Test-Path -LiteralPath $file)){
        if($session.HasExited){throw ('Scheduled input/job test failed: '+(Get-Content (Join-Path $directory 'session-stderr.log') -Raw))}
        if([datetime]::UtcNow -ge $deadline){throw 'Scheduled input/job test timed out.'}
        Start-Sleep -Milliseconds 100
    }
    $value=Get-Content -LiteralPath $file -Raw|ConvertFrom-Json
    if($value.Pid -ne $session.Id -or -not $value.InputRedirected){throw 'Input probe identity/pipe failed.'}
    $watched=[Diagnostics.Process]::GetProcessById($session.Id);[void]$watched.Handle
    $nested=[Diagnostics.Process]::GetProcessById([int]$value.NestedPid);[void]$nested.Handle
    if($nested.StartTime.ToUniversalTime().Ticks -ne $value.NestedTicks){throw 'Dummy child identity mismatch.'}
    if($session.WaitForExit(600)){throw 'Held session input unexpectedly closed.'}
    $owner.Dispose();$owner=$null
    if(-not $watched.WaitForExit(5000) -or -not $nested.WaitForExit(5000)){throw 'Nested job cleanup failed.'}
    $result=@{LaunchId=$LaunchId;WorkerPid=$PID;NoConsole=$true;InputHeld=$true;NestedCleanup=$true}
    $file=Join-Path $directory 'passed.json';[IO.File]::WriteAllText(($file+'.tmp'),($result|ConvertTo-Json));[IO.File]::Move(($file+'.tmp'),$file)
}finally{if($owner){$owner.Dispose()};if($watched){$watched.Dispose()};if($nested){$nested.Dispose()}}
'@ | Set-Content -LiteralPath $probe -Encoding utf8NoBOM
    $service=Get-HybridScheduler
    $task=Register-HybridDemandTask $service $name (Join-Path $directory 'Scheduled-Host.ps1') $id $probe
    if($task.Definition.Triggers.Count -ne 0){throw 'Probe unexpectedly has automatic triggers.'}
    [void]$task.Run($null)
    $started=[datetime]::UtcNow;$deadline=$started.AddSeconds(35)
    $passed=Join-Path $directory 'passed.json'
    while([datetime]::UtcNow -lt $deadline){
        if((Test-Path -LiteralPath $passed) -and $task.State -notin @(2,4)){break}
        if(([datetime]::UtcNow-$started).TotalSeconds -gt 3 -and $task.State -notin @(2,4)){
            $errorLog=Join-Path $StateRoot "background-$id-host-stderr.log"
            $errorText=if(Test-Path -LiteralPath $errorLog){Get-Content -LiteralPath $errorLog -Raw}else{'No worker error log was created.'}
            throw "Scheduled background self-check failed (task result $($task.LastTaskResult)): $errorText"
        }
        Start-Sleep -Milliseconds 100
    }
    if(-not (Test-Path -LiteralPath $passed) -or $task.State -in @(2,4) -or $task.LastTaskResult -ne 0){throw 'Scheduled background self-check did not finish successfully.'}
    $result=Get-Content -LiteralPath $passed -Raw|ConvertFrom-Json
    if($result.LaunchId -ne $id -or -not $result.NoConsole -or -not $result.InputHeld -or -not $result.NestedCleanup){throw 'Scheduled self-check result does not match.'}
    Write-Host 'Windows scheduler self-check passed: console-free worker, held input and nested-job cleanup. Existing VPN was not changed.' -ForegroundColor Green
} finally {
    if($task){
        try {if($task.State -in @(2,4)){$task.Stop(0)}}finally{$service.GetFolder('\').DeleteTask($name,0)}
    }
    if($service){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($service)}
    foreach($file in @((Join-Path $StateRoot "background-$id-host-stdout.log"),(Join-Path $StateRoot "background-$id-host-stderr.log"))){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue}}
    if(Test-Path -LiteralPath $directory){Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue}
}

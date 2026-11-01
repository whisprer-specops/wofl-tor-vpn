#requires -Version 7.0
[CmdletBinding()]
param([string]$StateRoot)
$ErrorActionPreference='Stop'
if(-not $IsWindows){Write-Host 'SKIP: native detached-process self-check requires Windows.';return}
$root=Split-Path $PSScriptRoot -Parent
if(-not ('HybridDetachedLauncher' -as [type])){Add-Type -Path "$root/background/DetachedLauncher.cs"}
if(-not $StateRoot){$StateRoot=Join-Path $env:ProgramData 'whispr-hybrid'}
$directory=Join-Path $StateRoot ('background-selfcheck-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $directory)
$process=$null;$owner=$null;$ownedSession=$null;$watchedSession=$null;$nestedChild=$null
try {
    $script=Join-Path $directory 'probe.ps1'
    @'
param([string]$Output)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class ProbeConsole { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'
$record=@{Pid=$PID;ConsoleHandle=[ProbeConsole]::GetConsoleWindow().ToInt64();OutputRedirected=[Console]::IsOutputRedirected;InputRedirected=[Console]::IsInputRedirected}
[IO.File]::WriteAllText($Output,($record|ConvertTo-Json))
[Console]::Out.WriteLine('DETACHED_STDOUT_OK')
[Console]::Error.WriteLine('DETACHED_STDERR_OK')
Start-Sleep -Milliseconds 200
'@ | Set-Content -LiteralPath $script -Encoding utf8NoBOM
    $output=Join-Path $directory 'result.json';$prefix=Join-Path $directory 'probe'
    $process=[HybridDetachedLauncher]::Start((Join-Path $PSHOME 'pwsh.exe'),[string[]]@('-NoLogo','-NoProfile','-NonInteractive','-File',$script,$output),$directory,$prefix)
    if(-not $process.WaitForExit(15000)){throw 'Detached-process self-check timed out.'}
    if($process.ExitCode -ne 0){throw ('Detached-process self-check failed: '+(Get-Content ($prefix+'-stderr.log') -Raw))}
    $record=Get-Content -LiteralPath $output -Raw|ConvertFrom-Json
    if($record.Pid -ne $process.Id -or $record.ConsoleHandle -ne 0 -or -not $record.OutputRedirected -or -not $record.InputRedirected){throw 'Native detached-process self-check did not prove a console-free process with independent I/O.'}
    if((Get-Content ($prefix+'-stdout.log') -Raw) -notmatch 'DETACHED_STDOUT_OK' -or (Get-Content ($prefix+'-stderr.log') -Raw) -notmatch 'DETACHED_STDERR_OK'){throw 'Detached log handles failed their self-check.'}
    if(-not ('HybridBackgroundSessionHost' -as [type])){Add-Type -Path "$root/background/SessionHost.cs"}
    $fixture=Join-Path $directory 'session-input-probe.ps1'
    @'
$ErrorActionPreference='Stop'
$directory=Split-Path $PSCommandPath -Parent
Add-Type -Path (Join-Path $env:ProgramFiles 'whispr Hybrid VPN/client/ProcessJob.cs')
$job=[HybridProcessJob]::new()
try {
    $nested=$job.Start((Join-Path $PSHOME 'pwsh.exe'),[string[]]@('-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 30'),$directory,(Join-Path $directory 'nested'))
    $record=@{Pid=$PID;NestedPid=$nested.Id;NestedStartedTicks=$nested.StartTime.ToUniversalTime().Ticks;InputRedirected=[Console]::IsInputRedirected}
    $ready=Join-Path $directory 'input-ready.json'
    [IO.File]::WriteAllText(($ready+'.tmp'),($record|ConvertTo-Json))
    [IO.File]::Move(($ready+'.tmp'),$ready)
    $line=[Console]::ReadLine()
    if($null -eq $line){throw 'Unexpected EOF: background input was not held open.'}
}finally{$job.Dispose()}
'@ | Set-Content -LiteralPath $fixture -Encoding utf8NoBOM
    $owner=[HybridBackgroundSessionHost]::new()
    $ownedSession=$owner.Start((Join-Path $PSHOME 'pwsh.exe'),$fixture,$directory,(Join-Path $directory 'owned-session'))
    $ready=Join-Path $directory 'input-ready.json';$deadline=[datetime]::UtcNow.AddSeconds(15)
    while(-not (Test-Path -LiteralPath $ready)){
        if($ownedSession.HasExited){throw ('Input/job self-check failed: '+(Get-Content (Join-Path $directory 'owned-session-stderr.log') -Raw))}
        if([datetime]::UtcNow -ge $deadline){throw 'Input/job self-check timed out.'}
        Start-Sleep -Milliseconds 100
    }
    $record=Get-Content -LiteralPath $ready -Raw|ConvertFrom-Json
    if($record.Pid -ne $ownedSession.Id -or -not $record.InputRedirected){throw 'Background input self-check identity failed.'}
    $watchedSession=[Diagnostics.Process]::GetProcessById($ownedSession.Id)
    [void]$watchedSession.Handle
    $nestedChild=[Diagnostics.Process]::GetProcessById([int]$record.NestedPid)
    [void]$nestedChild.Handle
    if($nestedChild.StartTime.ToUniversalTime().Ticks -ne $record.NestedStartedTicks){throw 'Nested dummy child identity changed.'}
    if($ownedSession.WaitForExit(600)){throw 'Background session input reached EOF unexpectedly.'}
    $owner.Dispose();$owner=$null
    if(-not $watchedSession.WaitForExit(5000)){throw 'Owned session survived its host job cleanup.'}
    if(-not $nestedChild.WaitForExit(5000)){throw 'Nested dummy child survived job cleanup.'}
    Write-Host 'Windows self-check passed: console-free launch, independent logs, held input and nested-job cleanup. VPN was not changed.' -ForegroundColor Green
}finally{
    if($owner){$owner.Dispose()}
    if($watchedSession){$watchedSession.Dispose()}
    if($nestedChild){$nestedChild.Dispose()}
    if($ownedSession){$ownedSession.Dispose()}
    if($process){if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(5000)};$process.Dispose()}
    if(Test-Path -LiteralPath $directory){Remove-Item -LiteralPath $directory -Recurse -Force}
}

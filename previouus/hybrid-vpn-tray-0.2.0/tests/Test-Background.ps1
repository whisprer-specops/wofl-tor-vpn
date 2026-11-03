#requires -Version 7.0
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Add-Type -Path "$root/background/DetachedLauncher.cs"
Add-Type -Path "$root/background/SessionHost.cs"
foreach($case in @(@('','""'),@('two words','"two words"'),@('x"y','"x\"y"'),@('C:\dir\','"C:\dir\\"'))){
    if([HybridDetachedLauncher]::Quote($case[0]) -ne $case[1]){throw "Windows argument quoting failed for $($case[0])"}
}
$failed=$false;try{[void][HybridDetachedLauncher]::Quote("bad`0argument")}catch{$failed=$true}
if(-not $failed){throw 'Argument NUL must be rejected.'}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('hybrid-background-input-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp)
$child=$null
try {
    $script=Join-Path $temp 'input-fixture.ps1'
    @'
$ErrorActionPreference='Stop'
# Same managed Console.ReadLine behavior used by the unchanged working Session.ps1.
Add-Type -TypeDefinition 'public static class InputFixture { public static System.Threading.Tasks.Task<string> Read() { return System.Threading.Tasks.Task.Run(() => System.Console.ReadLine()); } }'
$task=[InputFixture]::Read()
[Console]::Out.WriteLine('READY')
if($task.Wait(400)){throw 'Input unexpectedly reached EOF before its owner closed it.'}
$line=$task.GetAwaiter().GetResult()
if($line -ne 'stop'){throw 'The owned input channel failed.'}
[Console]::Out.WriteLine('STOPPED')
'@ | Set-Content -LiteralPath $script -Encoding utf8NoBOM
    $exe=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
    $start=[Diagnostics.ProcessStartInfo]::new($exe)
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($arg in @('-NoLogo','-NoProfile','-File',$script)){$start.ArgumentList.Add($arg)}
    $child=[Diagnostics.Process]::Start($start)
    $ready=$child.StandardOutput.ReadLineAsync()
    if(-not $ready.Wait(10000) -or $ready.GetAwaiter().GetResult() -ne 'READY'){throw 'Input fixture did not start.'}
    Start-Sleep -Milliseconds 650
    if($child.HasExited){throw 'A held input writer did not keep Console.ReadLine pending.'}
    $child.StandardInput.WriteLine('stop');$child.StandardInput.Flush()
    $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
    if(-not $child.WaitForExit(5000) -or $child.ExitCode -ne 0 -or $stdout.GetAwaiter().GetResult().Trim() -ne 'STOPPED'){throw ('Input fixture failed: '+$stderr.GetAwaiter().GetResult())}
    Write-Host 'Both C# helpers compile; Windows quoting and real PowerShell held-input/stop behavior passed.'
}finally{
    if($child){if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(5000)};$child.Dispose()}
    Remove-Item -LiteralPath $temp -Recurse -Force
}

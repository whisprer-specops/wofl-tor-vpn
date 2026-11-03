#requires -Version 5.1
$ErrorActionPreference='Stop'
try{
    $reset=Join-Path $PSScriptRoot 'Reset-WhisprVpn.ps1'
    $hostPath=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $p=[Diagnostics.ProcessStartInfo]::new($hostPath)
    $p.UseShellExecute=$true;$p.Verb='runas';$p.WindowStyle='Normal'
    # Execution policy is scoped to this one child process; no machine/user policy is written.
    $p.Arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+$reset+'" -PauseAtEnd'
    $child=[Diagnostics.Process]::Start($p);$child.WaitForExit();$code=$child.ExitCode;$child.Dispose();exit $code
}catch{Write-Host ('Could not start recovery (UAC may have been cancelled): '+$_.Exception.Message) -ForegroundColor Red;[void](Read-Host 'Press Enter to close');exit 1}

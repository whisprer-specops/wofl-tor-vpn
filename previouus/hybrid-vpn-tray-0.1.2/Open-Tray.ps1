#requires -Version 7.0
$ErrorActionPreference='Stop'
if(-not $IsWindows){throw 'Windows is required.'}
$target=Join-Path $PSScriptRoot 'Tray.ps1'
if(-not (Test-Path -LiteralPath $target)){throw 'Installed Tray.ps1 is missing.'}
$start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
$start.UseShellExecute=$true
$start.Arguments='-NoLogo -NoProfile -STA -WindowStyle Hidden -File "'+$target+'"'
$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
try {$admin=[Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}finally{$identity.Dispose()}
if(-not $admin){$start.Verb='runas'}
try {[void][Diagnostics.Process]::Start($start)}
catch {throw "Could not open the tray (UAC may have been cancelled): $($_.Exception.Message)"}

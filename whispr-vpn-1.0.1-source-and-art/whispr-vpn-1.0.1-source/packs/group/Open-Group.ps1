#requires -Version 7.2
$ErrorActionPreference='Stop'
$id=[Security.Principal.WindowsIdentity]::GetCurrent()
try{$admin=[Security.Principal.WindowsPrincipal]::new($id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}finally{$id.Dispose()}
if($admin){& "$PSScriptRoot/Group.ps1";return}
$p=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'));$p.UseShellExecute=$true;$p.Verb='runas';$p.WorkingDirectory=$PSScriptRoot
$p.Arguments='-NoLogo -NoProfile -STA -File "'+(Join-Path $PSScriptRoot 'Group.ps1')+'"'
[void][Diagnostics.Process]::Start($p)

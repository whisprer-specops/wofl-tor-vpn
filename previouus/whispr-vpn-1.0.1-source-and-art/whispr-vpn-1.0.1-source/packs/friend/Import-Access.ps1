#requires -Version 7.2
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$AccessFile,[switch]$EnableAutoConnect,[switch]$NoLaunch)
& (Join-Path $env:ProgramFiles 'whispr Hybrid VPN/Import-Access.ps1') -AccessFile $AccessFile -EnableAutoConnect:$EnableAutoConnect -NoLaunch:$NoLaunch

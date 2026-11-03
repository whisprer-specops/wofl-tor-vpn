#requires -Version 7.2
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$OutputDirectory=$PSScriptRoot)
& (Join-Path $env:ProgramFiles 'whispr Hybrid VPN/New-Request.ps1') -OutputDirectory $OutputDirectory

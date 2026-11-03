#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Request,[ValidateSet('nyc1','lon1','fkt1','sgp1','syd1')][string[]]$Servers=@('nyc1','lon1','fkt1','sgp1','syd1'),[string]$OutputDirectory=(Join-Path $PSScriptRoot 'out'))
& "$PSScriptRoot/Owner-Operations.ps1" -Action Register -Request $Request -Servers $Servers -OutputDirectory $OutputDirectory

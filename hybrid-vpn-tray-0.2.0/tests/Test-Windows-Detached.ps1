#requires -Version 7.0
param([string]$StateRoot)
# Compatibility entry point; direct parent-job breakaway is no longer used.
& "$PSScriptRoot/Test-Windows-Scheduled.ps1" -StateRoot $StateRoot

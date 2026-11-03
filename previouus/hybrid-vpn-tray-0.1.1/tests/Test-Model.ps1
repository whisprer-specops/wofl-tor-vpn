#requires -Version 7.0
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../tray/Model.ps1"
function Assert-That([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$now=[datetime]::UtcNow
$session=@{State='verified-session';LastVerifiedUtc=$now.ToString('o')}
$v=Get-TrayPresentation ARMED $session $true $true $now
Assert-That ($v.Color -eq 'green' -and -not $v.CanConnect -and -not $v.CanSelect) 'Verified live session must be green, with exit switching disabled.'
foreach($guard in @('DISARMED','UNKNOWN')){
    $v=Get-TrayPresentation $guard $session $true $true $now
    Assert-That ($v.Color -ne 'green') 'Guard must actually be ARMED.'
}
foreach($case in @(@($false,$true),@($true,$false),@($false,$false))){
    $v=Get-TrayPresentation ARMED $session $case[0] $case[1] $now
    Assert-That ($v.Color -ne 'green') 'Dead supervisor or absent TUN cannot be green.'
}
$session.LastVerifiedUtc=$now.AddSeconds(-151).ToString('o')
$v=Get-TrayPresentation ARMED $session $true $true $now
Assert-That ($v.Color -eq 'orange' -and -not $v.CanSelect) 'Stale verification cannot be green or switchable.'
$session.LastVerifiedUtc=$now.AddMinutes(10).ToString('o')
$v=Get-TrayPresentation ARMED $session $true $true $now
Assert-That ($v.Color -ne 'green') 'Future verification cannot be green.'
$session.LastVerifiedUtc='broken'
$v=Get-TrayPresentation ARMED $session $true $true $now
Assert-That ($v.Color -ne 'green') 'Invalid verification cannot be green.'
$v=Get-TrayPresentation DISARMED $session $false $false $now
Assert-That ($v.Color -eq 'gray' -and $v.CanConnect -and $v.CanSelect) 'Recovered idle state should allow connect and selection.'
$v=Get-TrayPresentation ARMED @{State='armed-bootstrap'} $true $false $now
Assert-That ($v.Color -eq 'orange') 'Bootstrap is pending, not verified.'
# ConvertFrom-Json can already return a UTC DateTime; retain its Kind even in summer/local time.
$summer=[datetime]::SpecifyKind([datetime]'2026-06-01T12:00:00',[DateTimeKind]::Utc)
$v=Get-TrayPresentation ARMED @{State='verified-session';LastVerifiedUtc=$summer} $true $true $summer
Assert-That ($v.Color -eq 'green') 'Parsed UTC DateTime must retain its timezone.'
$peer=@{schema=1;ssh_alias='nyc1';endpoint='137.184.105.114';port=51832;server_public_key='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';client_public_key='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';client_ipv4='10.88.70.2/32';ipv6=$false}
Assert-TrayPeer $peer 'nyc1'
$peer.endpoint='example.com';$failed=$false
try{Assert-TrayPeer $peer 'nyc1'}catch{$failed=$true}
Assert-That $failed 'Profile must not silently change to a hostname endpoint.'
$peer.endpoint='137.184.105.114';$peer.client_public_key='bad';$failed=$false
try{Assert-TrayPeer $peer 'nyc1'}catch{$failed=$true}
Assert-That $failed 'Invalid keys must be rejected.'
Write-Host 'Tray status freshness, liveness, guard, tunnel, disconnected state and profile validation tests passed.'

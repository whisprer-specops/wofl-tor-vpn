#requires -Version 7.0
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../background/Scheduler.ps1"
function Get-HybridTaskSid {'S-1-5-21-12345'}
function Assert-Check([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
function New-FakeDefinition {
    $actions=[pscustomobject]@{Count=0;Entries=[Collections.Generic.List[object]]::new()}
    $actions|Add-Member ScriptMethod Create {param($Type);$item=[pscustomobject]@{Type=$Type;Path='';Arguments='';WorkingDirectory=''};$this.Entries.Add($item);$this.Count++;return $item}
    $actions|Add-Member ScriptMethod Item {param($Index);return $this.Entries[$Index-1]}
    return [pscustomobject]@{
        RegistrationInfo=[pscustomobject]@{Source='';Description=''}
        Principal=[pscustomobject]@{UserId='';LogonType=0;RunLevel=0}
        Triggers=[pscustomobject]@{Count=0};Actions=$actions
        Settings=[pscustomobject]@{AllowDemandStart=$false;Enabled=$false;DisallowStartIfOnBatteries=$true;StopIfGoingOnBatteries=$true;RunOnlyIfIdle=$true;RunOnlyIfNetworkAvailable=$true;StartWhenAvailable=$true;RestartCount=9;ExecutionTimeLimit='PT72H';MultipleInstances=0;IdleSettings=[pscustomobject]@{StopOnIdleEnd=$true;RestartOnIdle=$true}}
    }
}
$folder=[pscustomobject]@{Tasks=@{};Writes=0;Sddl='';Password='not-null'}
$folder|Add-Member ScriptMethod GetTask {param($Name);return $this.Tasks[$Name]}
$folder|Add-Member ScriptMethod RegisterTaskDefinition {
    param($Name,$Definition,$Flags,$Sid,$Password,$Logon,$Sddl)
    $this.Writes++;$this.Sddl=$Sddl;$this.Password=$Password
    if($Sid -ne 'S-1-5-21-12345' -or $Logon -ne 3 -or $Flags -ne 22){throw 'Unexpected registration context.'}
    $task=[pscustomobject]@{Definition=$Definition;State=3;LastTaskResult=0}
    $this.Tasks[$Name]=$task;return $task
}
$service=[pscustomobject]@{Folder=$folder}
$service|Add-Member ScriptMethod GetFolder {param($Path);if($Path -ne '\'){throw 'Unexpected task folder.'};return $this.Folder}
$service|Add-Member ScriptMethod NewTask {param($Flags);return (New-FakeDefinition)}
$bootstrap=Join-Path ([IO.Path]::GetTempPath()) 'app/background/Scheduled-Host.ps1'
$id='a'*32;$name=Get-HybridTaskName
$task=Register-HybridDemandTask $service $name $bootstrap $id
$d=$task.Definition
Assert-Check ($d.Triggers.Count -eq 0 -and $d.Settings.RestartCount -eq 0 -and -not $d.Settings.StartWhenAvailable) 'No automatic trigger or restart is permitted.'
Assert-Check (-not $d.Settings.DisallowStartIfOnBatteries -and -not $d.Settings.StopIfGoingOnBatteries) 'Battery must not block/stop a session.'
Assert-Check ($d.Settings.ExecutionTimeLimit -eq 'PT0S' -and $d.Settings.MultipleInstances -eq 2) 'Session must have no three-day timeout or duplicate task instances.'
Assert-Check ($d.Principal.UserId -eq 'S-1-5-21-12345' -and $d.Principal.LogonType -eq 3 -and $d.Principal.RunLevel -eq 1) 'Use this logged-in elevated user, not SYSTEM/password logon.'
Assert-Check ($null -eq $folder.Password -and $folder.Sddl -eq 'O:BAG:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)') 'Do not store a password or allow task editing by unelevated users.'
Assert-HybridTaskOwnership $task $bootstrap 'S-1-5-21-12345'
$arguments=$d.Actions.Item(1).Arguments
$d.Actions.Item(1).Arguments='unrecognized action'
$failed=$false;try{[void](Register-HybridDemandTask $service $name $bootstrap $id)}catch{$failed=$true}
Assert-Check ($failed -and $folder.Writes -eq 1) 'An unrecognized existing task action must not be overwritten.'
$d.Actions.Item(1).Arguments=$arguments;$d.Triggers.Count=1
$failed=$false;try{Assert-HybridTaskOwnership $task $bootstrap 'S-1-5-21-12345'}catch{$failed=$true}
Assert-Check $failed 'A task with automatic triggers must not be treated as owned.'
Write-Host 'Scheduler definition/ownership tests passed: manual only, battery-safe, unlimited duration, current elevated account, protected task ACL and foreign-action rejection.'

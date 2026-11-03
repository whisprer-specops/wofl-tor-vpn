#requires -Version 7.0
function Get-HybridAutoTaskName {return 'whispr-HybridVPN-Autostart-'+(Get-HybridTaskSid)}
function Get-HybridAutoArguments {
    param([string]$InstallRoot)
    if(-not ('HybridDetachedLauncher' -as [type])){Add-Type -Path "$PSScriptRoot/DetachedLauncher.cs"}
    return ((@('-NoLogo','-NoProfile','-STA','-WindowStyle','Hidden','-File',(Join-Path $InstallRoot 'Tray.ps1'),'-AutoConnect') | ForEach-Object {[HybridDetachedLauncher]::Quote($_)}) -join ' ')
}
function Assert-HybridAutoTask {
    param($Task,[string]$InstallRoot)
    $d=$Task.Definition;$sid=Get-HybridTaskSid
    if($d.RegistrationInfo.Source -ne 'whispr-hybrid-autostart-v1' -or $d.Actions.Count -ne 1 -or $d.Triggers.Count -ne 1){throw 'Auto-connect task ownership does not match.'}
    $a=$d.Actions.Item(1);$trigger=$d.Triggers.Item(1)
    if($a.Type -ne 0 -or $a.Path -ne (Join-Path $PSHOME 'pwsh.exe') -or $a.WorkingDirectory -ne $InstallRoot -or $a.Arguments -ne (Get-HybridAutoArguments $InstallRoot)){throw 'Auto-connect task action does not match.'}
    $principalSid=[string]$d.Principal.UserId
    if($principalSid -notmatch '^S-1-'){$principalSid=[Security.Principal.NTAccount]::new($principalSid).Translate([Security.Principal.SecurityIdentifier]).Value}
    $triggerSid=[string]$trigger.UserId
    if($triggerSid -notmatch '^S-1-'){$triggerSid=[Security.Principal.NTAccount]::new($triggerSid).Translate([Security.Principal.SecurityIdentifier]).Value}
    if($principalSid -ne $sid -or $d.Principal.LogonType -ne 3 -or $d.Principal.RunLevel -ne 1 -or $trigger.Type -ne 9 -or $triggerSid -ne $sid){throw 'Auto-connect task user/logon trigger does not match.'}
}
function Get-HybridAutoEnabled {
    param([string]$InstallRoot)
    $service=Get-HybridScheduler
    try{$task=Get-HybridRegisteredTask ($service.GetFolder('\')) (Get-HybridAutoTaskName);if(-not $task){return $false};Assert-HybridAutoTask $task $InstallRoot;return [bool]$task.Enabled}
    finally{if([Runtime.InteropServices.Marshal]::IsComObject($service)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($service)}}
}
function Set-HybridAutoConnect {
    param([string]$InstallRoot,[string]$StateRoot,[bool]$Enabled)
    $service=Get-HybridScheduler
    try {
        $folder=$service.GetFolder('\');$name=Get-HybridAutoTaskName
        $old=Get-HybridRegisteredTask $folder $name
        if($old){Assert-HybridAutoTask $old $InstallRoot}
        if(-not $Enabled){if($old){$old.Enabled=$false};return}
        Save-HybridLiveResumeBinding $InstallRoot $StateRoot
        $sid=Get-HybridTaskSid;$d=$service.NewTask(0)
        $d.RegistrationInfo.Source='whispr-hybrid-autostart-v1'
        $d.RegistrationInfo.Description='whispr Hybrid VPN: show tray and auto-connect at this user sign-in; protected startup resume; no stored password.'
        $d.Principal.UserId=$sid;$d.Principal.LogonType=3;$d.Principal.RunLevel=1
        $s=$d.Settings;$s.AllowDemandStart=$true;$s.Enabled=$true
        $s.DisallowStartIfOnBatteries=$false;$s.StopIfGoingOnBatteries=$false
        $s.ExecutionTimeLimit='PT0S';$s.MultipleInstances=2;$s.RestartCount=0
        $s.RunOnlyIfIdle=$false;$s.RunOnlyIfNetworkAvailable=$false;$s.StartWhenAvailable=$false
        $s.IdleSettings.StopOnIdleEnd=$false;$s.IdleSettings.RestartOnIdle=$false
        $t=$d.Triggers.Create(9);$t.UserId=$sid;$t.Delay='PT10S';$t.Enabled=$true
        $a=$d.Actions.Create(0);$a.Path=Join-Path $PSHOME 'pwsh.exe';$a.WorkingDirectory=$InstallRoot;$a.Arguments=Get-HybridAutoArguments $InstallRoot
        [void]$folder.RegisterTaskDefinition($name,$d,22,$sid,$null,3,'O:BAG:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)')
    }finally{if([Runtime.InteropServices.Marshal]::IsComObject($service)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($service)}}
}
function Remove-HybridAutoConnect {
    param([string]$InstallRoot)
    $service=Get-HybridScheduler
    try{
        $folder=$service.GetFolder('\');$name=Get-HybridAutoTaskName;$task=Get-HybridRegisteredTask $folder $name
        if($task){Assert-HybridAutoTask $task $InstallRoot;if($task.State -eq 4){throw 'Close the tray before removing its sign-in task.'};$folder.DeleteTask($name,0)}
    }finally{if([Runtime.InteropServices.Marshal]::IsComObject($service)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($service)}}
}

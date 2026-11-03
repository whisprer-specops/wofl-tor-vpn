#requires -Version 7.0
function Get-HybridTaskSid {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{return $identity.User.Value}finally{$identity.Dispose()}
}
function Get-HybridTaskName {
    return 'whispr-HybridVPN-Background-'+(Get-HybridTaskSid)
}
function Get-HybridScheduler {
    $service=New-Object -ComObject Schedule.Service
    $service.Connect()
    return $service
}
function Get-HybridRegisteredTask {
    param($Folder,[string]$Name)
    try{return $Folder.GetTask($Name)}catch{
        $code=[uint32]([long]$_.Exception.GetBaseException().HResult -band 0xffffffffL)
        if($code -eq 0x80070002L){return $null}
        throw
    }
}
function Get-HybridTaskArguments {
    param([string]$Bootstrap,[string]$LaunchId,[string]$ProbeScript='')
    if($LaunchId -notmatch '^[0-9a-f]{32}$'){throw 'Invalid task launch identity.'}
    if(-not ('HybridDetachedLauncher' -as [type])){Add-Type -Path "$PSScriptRoot/DetachedLauncher.cs"}
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden','-File',$Bootstrap,'-LaunchId',$LaunchId)
    if($ProbeScript){$arguments+=@('-ProbeScript',$ProbeScript)}
    return (($arguments | ForEach-Object {[HybridDetachedLauncher]::Quote($_)}) -join ' ')
}
function Assert-HybridTaskOwnership {
    param($Task,[string]$Bootstrap,[string]$Sid)
    $definition=$Task.Definition
    if($definition.RegistrationInfo.Source -ne 'whispr-hybrid-on-demand-v1' -or $definition.Triggers.Count -ne 0 -or $definition.Actions.Count -ne 1){throw 'Task ownership/trigger configuration does not match this application.'}
    $action=$definition.Actions.Item(1)
    if($action.Type -ne 0 -or $action.Path -ne (Join-Path $PSHOME 'pwsh.exe') -or $action.WorkingDirectory -ne (Split-Path $Bootstrap -Parent)){
        throw 'Task action does not match the installed background launcher.'
    }
    $prefix=Get-HybridTaskArguments $Bootstrap ('0'*32)
    $prefix=$prefix.Substring(0,$prefix.Length-34)
    if($action.Arguments -notmatch ('^'+[regex]::Escape($prefix)+'"[0-9a-f]{32}"$')){throw 'Task arguments are not a recognized background action.'}
    $taskSid=[string]$definition.Principal.UserId
    if($taskSid -notmatch '^S-1-'){$taskSid=[Security.Principal.NTAccount]::new($taskSid).Translate([Security.Principal.SecurityIdentifier]).Value}
    if($taskSid -ne $Sid -or $definition.Principal.LogonType -ne 3 -or $definition.Principal.RunLevel -ne 1){throw 'Task account/elevation does not match this interactive user.'}
}
function Register-HybridDemandTask {
    param($Service,[string]$Name,[string]$Bootstrap,[string]$LaunchId,[string]$ProbeScript='')
    $sid=Get-HybridTaskSid
    $expectedName=if($ProbeScript){'whispr-HybridVPN-Probe-'+$LaunchId}else{'whispr-HybridVPN-Background-'+$sid}
    if($Name -ne $expectedName){throw 'Invalid application task name.'}
    $folder=$Service.GetFolder('\')
    $existing=Get-HybridRegisteredTask $folder $Name
    if($existing){
        if($ProbeScript){throw 'Probe task name collision.'}
        Assert-HybridTaskOwnership $existing $Bootstrap $sid
        $deadline=[datetime]::UtcNow.AddSeconds(10)
        while($existing.State -eq 4 -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 200}
        if($existing.State -eq 4){throw 'The previous background task is still running. Recover the current session and wait for its host to exit.'}
    }
    $definition=$Service.NewTask(0)
    $definition.RegistrationInfo.Source='whispr-hybrid-on-demand-v1'
    $definition.RegistrationInfo.Description='whispr Hybrid VPN: manual background launch only; no automatic trigger, restart, or stored password.'
    $definition.Principal.UserId=$sid;$definition.Principal.LogonType=3;$definition.Principal.RunLevel=1
    $settings=$definition.Settings
    $settings.AllowDemandStart=$true;$settings.Enabled=$true
    $settings.DisallowStartIfOnBatteries=$false;$settings.StopIfGoingOnBatteries=$false
    $settings.RunOnlyIfIdle=$false;$settings.RunOnlyIfNetworkAvailable=$false
    $settings.StartWhenAvailable=$false;$settings.RestartCount=0
    $settings.ExecutionTimeLimit='PT0S';$settings.MultipleInstances=2
    $settings.IdleSettings.StopOnIdleEnd=$false;$settings.IdleSettings.RestartOnIdle=$false
    $action=$definition.Actions.Create(0)
    $action.Path=Join-Path $PSHOME 'pwsh.exe'
    $action.Arguments=Get-HybridTaskArguments $Bootstrap $LaunchId $ProbeScript
    $action.WorkingDirectory=Split-Path $Bootstrap -Parent
    # CREATE_OR_UPDATE | DONT_ADD_PRINCIPAL_ACE. Admin-owned, with SYSTEM/Admin access only.
    return $folder.RegisterTaskDefinition($Name,$definition,22,$sid,$null,3,'O:BAG:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)')
}
function Remove-HybridDemandTask {
    param([string]$InstallRoot)
    $service=Get-HybridScheduler
    try{
        $folder=$service.GetFolder('\');$name=Get-HybridTaskName
        $task=Get-HybridRegisteredTask $folder $name
        if($task){
            Assert-HybridTaskOwnership $task (Join-Path $InstallRoot 'background/Scheduled-Host.ps1') (Get-HybridTaskSid)
            if($task.State -eq 4){throw 'Disconnect / Recover the background VPN before removing the add-on. Close tray only can leave it running.'}
            $folder.DeleteTask($name,0)
        }
    }finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($service)}
}

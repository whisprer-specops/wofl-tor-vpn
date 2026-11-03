#requires -Version 7.0
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../tray/MapModel.ps1"
. "$PSScriptRoot/../background/Resume.ps1"
function Check([bool]$v,[string]$m){if(-not $v){throw $m}}
$regions=@(Get-HybridRegions)
Check ($regions.Count -eq 5 -and 'fkt1' -in $regions.Alias) 'Five regions including Frankfurt required.'
foreach($region in $regions){$p=Get-HybridMapPoint $region.Lon $region.Lat 1100 528;$hit=Find-HybridMapRegion $p.X $p.Y 1100 528;Check ($hit.Alias -eq $region.Alias) ('Map hit differs: '+$region.Alias)}
Check ($null -eq (Find-HybridMapRegion 0 0 1100 528)) 'Empty ocean must not select an endpoint.'
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('hybrid-startup-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmp)
try{
 $manifest=@{'bin/sing-box.exe'='aaa';'bin/tor/tor.exe'='bbb';'bin/whispr-vpn-guard.exe'='ccc'}
 $manifest|ConvertTo-Json|Set-Content "$tmp/SHA256SUMS.json"
 $peer=@{endpoint='137.184.105.114';port=51832;server_public_key='server'}
 $old=@{OwnerPid=999999;OwnerStartedTicks=123;OwnerPath='pwsh';TunnelGuid='one'}
 $binding=New-HybridResumeBinding $peer 'device' $old $tmp
 Assert-HybridBinding $binding $old $peer 'device' $tmp
 foreach($field in @('Endpoint','Port','ServerKey','ClientKey','OwnerPid','OwnerStartedTicks','Home','EngineSha','TorSha','GuardSha')){
  $bad=$binding.Clone();$bad[$field]='CHANGED';$rejected=$false
  try{Assert-HybridBinding $bad $old $peer 'device' $tmp}catch{$rejected=$true}
  Check $rejected ('Changed binding accepted: '+$field)
 }
 $old|ConvertTo-Json|Set-Content "$tmp/session.json"
 $binding|ConvertTo-Json|Set-Content "$tmp/resume-binding.json"
 function Test-HybridRecordedOwner {$false}
 $previous=Assert-HybridResume $peer 'device' $tmp $tmp
 Check ($previous.OwnerPid -eq $old.OwnerPid) 'Recorded state not returned.'
 function Test-HybridRecordedOwner {$true}
 $rejected=$false;try{Assert-HybridResume $peer 'device' $tmp $tmp}catch{$rejected=$true}
 Check $rejected 'Live owner must never be replaced.'
 function Test-HybridRecordedOwner {$false}
 function Get-NetAdapter {[pscustomobject]@{InterfaceGuid='other'}}
 $rejected=$false;try{Remove-HybridDeadTunnel $old}catch{$rejected=$true}
 Check $rejected 'Different TUN GUID must never be removed.'
}finally{Remove-Item -LiteralPath $tmp -Recurse -Force}
# Exercise real logon-task definition with only COM/process boundaries faked.
. "$PSScriptRoot/Test-Scheduler.ps1"
. "$PSScriptRoot/../background/Autostart.ps1"
function Get-HybridScheduler {return $service}
function Save-HybridLiveResumeBinding {param($InstallRoot,$StateRoot);$script:snapshotCalled=$true}
$script:snapshotCalled=$false
$service|Add-Member ScriptMethod NewTask {
 param($Flags)
 $d=New-FakeDefinition
 $d.Triggers|Add-Member NoteProperty Entries ([Collections.Generic.List[object]]::new())
 $d.Triggers|Add-Member ScriptMethod Create {param($Type);$t=[pscustomobject]@{Type=$Type;UserId='';Delay='';Enabled=$false};$this.Entries.Add($t);$this.Count++;return $t}
 $d.Triggers|Add-Member ScriptMethod Item {param($Index);return $this.Entries[$Index-1]}
 return $d
} -Force
$folder|Add-Member ScriptMethod RegisterTaskDefinition {
 param($Name,$Definition,$Flags,$Sid,$Password,$Logon,$Sddl)
 Check ($Flags -eq 22 -and $Sid -eq 'S-1-5-21-12345' -and $Logon -eq 3 -and $null -eq $Password -and $Sddl -eq 'O:BAG:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)') 'Sign-in task security differs.'
 $task=[pscustomobject]@{Definition=$Definition;Enabled=$true;State=3};$this.Tasks[$Name]=$task;return $task
} -Force
$root=Join-Path ([IO.Path]::GetTempPath()) 'installed'
Set-HybridAutoConnect $root '/state' $true
$task=$folder.Tasks[(Get-HybridAutoTaskName)];$d=$task.Definition
Assert-HybridAutoTask $task $root
Check ($script:snapshotCalled -and (Get-HybridAutoEnabled $root)) 'Auto-connect not enabled/bound.'
Check ($d.Triggers.Item(1).Delay -eq 'PT10S' -and $d.Settings.ExecutionTimeLimit -eq 'PT0S' -and $d.Settings.MultipleInstances -eq 2) 'Sign-in launch settings differ.'
Check ($d.Actions.Item(1).Arguments -match '-AutoConnect' -and $d.Actions.Item(1).Arguments -match '-STA') 'Tray launch flags missing.'
Set-HybridAutoConnect $root '/state' $false
Check (-not (Get-HybridAutoEnabled $root)) 'Disable must persist without stopping a session.'
$d.Actions.Item(1).Arguments='foreign command'
$rejected=$false;try{Set-HybridAutoConnect $root '/state' $true}catch{$rejected=$true}
Check $rejected 'Foreign task must not be overwritten.'
Write-Host 'Startup tests passed: map hit testing, pinned resume validation, live-owner/TUN rejection, protected sign-in task and disable/foreign-task behavior.'

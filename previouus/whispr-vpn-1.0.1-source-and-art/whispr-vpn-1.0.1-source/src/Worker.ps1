#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Setup','InstallGroup','Import','Export','Recover','CreateGroup','RemoveClient')][string]$Operation,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$JobId,
    [string]$InputFile='',
    [string]$DeviceName='My-PC',
    [string]$GroupName='Friends'
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Model.ps1"
$resultPath=$null
try{
    Assert-SuiteManifest $PSScriptRoot
    $work=Initialize-SuiteWorkspace;$resultPath=Join-Path $work "jobs/$JobId.json"
    $core=Get-SuiteCoreRoot;$state=Get-SuiteStateRoot
    $group=Sync-SuiteGroupTools $PSScriptRoot
    $message='Completed.'
    switch($Operation){
        'Setup' {
            $ownedPath=Join-Path $core 'desktop-owned.json'
            $plan=Get-SuiteSetupPlan
            if(Test-Path -LiteralPath $ownedPath){
                $owned=Read-SuiteJson $ownedPath
                if($owned.Product -ne $script:SuiteProduct -or $owned.SuiteRoot -ine $PSScriptRoot){throw 'Existing desktop ownership differs.'}
            }
            if($plan -in @('Fresh','Resume')){
                & "$PSScriptRoot/packs/friend/Install-Friend.ps1" -DeviceName $DeviceName -OutputDirectory (Join-Path $work 'exports') -DesktopSuiteRoot $PSScriptRoot
                & "$group/Install-Group.ps1" -NoLaunch
                $message='Client installed. Send the public friend-request.json from the Exports folder to your friend, then import their group.json or access file. No VPN connection has been started.'
            }else{
                [void](Assert-SuiteCore)
                $message='Your existing client was detected and retained. Use Open VPN tray, or update group support while disconnected with the tray closed.'
            }
        }
        'InstallGroup' {
            [void](Assert-SuiteCore)
            & "$group/Install-Group.ps1" -NoLaunch
            $message='Group support and country flags are installed. Your private identity and existing exits were retained. Open the VPN tray when ready.'
        }
        'Import' {
            [void](Assert-SuiteCore)
            $data=Read-SuiteJson $InputFile
            if(-not $data.ContainsKey('Kind')){throw 'Choose a whispr group.json or friend-access.json.'}
            switch($data.Kind){
                'whispr-exit-group' {
                    & "$group/Install-Group.ps1" -NoLaunch
                    & "$group/Import-Group.ps1" -File $InputFile -NoLaunch
                }
                'whispr-friend-access' {
                    if(-not (Test-Path -LiteralPath "$core/friend-mode.json")){throw 'This legacy access file is for a friend client. Use group.json on this existing owner client.'}
                    & "$core/Import-Access.ps1" -AccessFile $InputFile -NoLaunch
                }
                default {throw 'This JSON is not a group or access approval. A friend-request.json is sent to the endpoint owner.'}
            }
            $message='Approved exits imported. Open the VPN tray and select Connect. Wait for its verified green status.'
        }
        'Export' {
            New-SuitePublicRequest $DeviceName (Join-Path $work 'exports')
            $message='Exported public friend-request.json. Send that file only; private keys remain in protected local state.'
        }
        'Recover' {
            [void](Assert-SuiteCore)
            & "$core/Recover.ps1"
            $guard=(& "$core/bin/whispr-vpn-guard.exe" status|Out-String).Trim()
            if($LASTEXITCODE -ne 0 -or $guard -ne 'DISARMED'){throw 'Recovery was not confirmed. Protection may remain armed.'}
            $message='Disconnected and recovered. VPN protection is now off.'
        }
        'CreateGroup' {
            [void](Assert-SuiteCore)
            & "$group/Install-Group.ps1" -NoLaunch
            & "$group/New-Group.ps1" -Name $GroupName -MyName $DeviceName -StartIndependentGroup
            $message='Group created with this device. Open Group tools to add your VPS, approve members and publish the shared group.json.'
        }
        'RemoveClient' {
            [void](Assert-SuiteCore)
            & "$core/Uninstall.ps1"
            $message='Connection client removed. Protected device keys/settings were retained. You can now uninstall the desktop package from Windows Settings.'
        }
    }
    [void](Update-SuiteRuntimeLease $PSScriptRoot)
    Write-SuiteJson @{Success=$true;Message=$message;Operation=$Operation;CompletedUtc=[DateTime]::UtcNow.ToString('o')} $resultPath
}catch{
    try{[void](Update-SuiteRuntimeLease $PSScriptRoot)}catch{}
    $message=$_.Exception.Message -replace '[A-Za-z0-9+/]{43}=','[key withheld]'
    if($resultPath){Write-SuiteJson @{Success=$false;Message=$message;Operation=$Operation;CompletedUtc=[DateTime]::UtcNow.ToString('o')} $resultPath}
    Write-Error $message
    exit 1
}

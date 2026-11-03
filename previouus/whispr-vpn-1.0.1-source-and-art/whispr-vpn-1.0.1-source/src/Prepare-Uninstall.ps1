#requires -Version 7.2
# Read-only MSI removal check. Never changes network policy, tasks or client files.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Model.ps1"
try{
    $core=Get-SuiteCoreRoot;$marker=Join-Path $core 'desktop-owned.json'
    if(Test-Path -LiteralPath $marker){
        $owned=Read-SuiteJson $marker
        if($owned.Product -eq $script:SuiteProduct -and $owned.SuiteRoot -ieq $PSScriptRoot){throw 'Use Remove VPN client in the control centre before uninstalling this runtime. Keys/settings will be retained.'}
    }
    $service=New-Object -ComObject Schedule.Service
    try{
        $service.Connect()
        foreach($task in $service.GetFolder('\').GetTasks(1)){
            foreach($a in $task.Definition.Actions){
                if($a.Type -eq 0 -and [string]$a.Path -ieq (Join-Path $PSScriptRoot 'runtime/powershell/pwsh.exe')){
                    throw 'A scheduled task still uses this runtime. Remove the configured client through the control centre first.'
                }
            }
        }
    }finally{if([Runtime.InteropServices.Marshal]::IsComObject($service)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($service)}}
    Write-Host 'Removal preflight passed; pre-existing VPN clients and all keys/settings will be retained.'
}catch{Write-Error ('UNINSTALL STOPPED: '+$_.Exception.Message);exit 1}

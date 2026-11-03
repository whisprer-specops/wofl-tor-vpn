#requires -Version 7.2
#requires -RunAsAdministrator
$ErrorActionPreference='Stop'
function Select-GroupJson([string]$Title){
    if($IsWindows -and [Threading.Thread]::CurrentThread.ApartmentState -eq [Threading.ApartmentState]::STA){
        Add-Type -AssemblyName System.Windows.Forms
        $dialog=[Windows.Forms.OpenFileDialog]::new();$dialog.Title=$Title;$dialog.Filter='JSON files (*.json)|*.json';$dialog.CheckFileExists=$true
        $dialog.InitialDirectory=Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
        try{if($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){return $dialog.FileName};return $null}finally{$dialog.Dispose()}
    }
    return (Read-Host $Title).Trim('"')
}
while($true){
    Write-Host "`nwhispr shared exits — one group.json to exchange" -ForegroundColor Cyan
    Write-Host '1. Install/update this add-on (once on each PC)'
    Write-Host '2. Create the group (once, by the first owner)'
    Write-Host '3. Add one of MY VPSs to my local list'
    Write-Host '4. Publish / sync MY VPSs and approve the listed members'
    Write-Host '5. Import a received group.json'
    Write-Host '6. Add a new friend request to the group'
    Write-Host '7. Open VPN tray'
    Write-Host '8. Remove a guest device (all VPS owners must sync afterwards)'
    Write-Host '9. Recover/export my stored group.json'
    Write-Host '0. Exit'
    try{
        switch(Read-Host 'Choose'){
            '1' {& "$PSScriptRoot/Install-Group.ps1" -NoLaunch}
            '2' {$request=Select-GroupJson 'Choose the received friend-request.json';if(-not $request){throw 'Cancelled.'};$name=Read-Host 'Group name [Friends]';if(-not $name){$name='Friends'};$requests=if($request){@($request.Trim('"'))}else{@()};& "$PSScriptRoot/New-Group.ps1" -Name $name -MemberRequests $requests}
            '3' {& "$PSScriptRoot/Add-MyVPS.ps1"}
            '4' {& "$PSScriptRoot/Publish-MyVPS.ps1"}
            '5' {$file=Select-GroupJson 'Choose the received group.json';if($file){& "$PSScriptRoot/Import-Group.ps1" -File $file}}
            '6' {$request=Select-GroupJson 'Choose the received friend-request.json';if(-not $request){throw 'Cancelled.'};& "$PSScriptRoot/Add-Member.ps1" -Request $request.Trim('"')}
            '7' {& (Join-Path $env:ProgramFiles 'whispr Hybrid VPN/Open-Tray.ps1')}
            '8' {
                . "$PSScriptRoot/group/Protocol.ps1"
                $g=Read-GroupJson (Join-Path $PSScriptRoot 'group.json');Assert-GroupDocument $g
                for($i=0;$i -lt $g.Members.Count;$i++){Write-Host "$($i+1). $($g.Members[$i].Name) / $($g.Members[$i].Id.Substring(0,12))"}
                $choice=[int](Read-Host 'Guest number to remove')
                if($choice -lt 1 -or $choice -gt $g.Members.Count){throw 'Unknown member.'}
                & "$PSScriptRoot/Remove-Member.ps1" -MemberId $g.Members[$choice-1].Id
            }
            '9' {& "$PSScriptRoot/Export-Group.ps1"}
            '0' {return}
            default {Write-Host 'Choose one of the listed numbers.'}
        }
    }catch{Write-Host $_.Exception.Message -ForegroundColor Red}
}

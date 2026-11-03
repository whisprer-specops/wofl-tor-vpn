#requires -Version 7.2
function Get-GroupLocalIdentity {
    $root=Join-Path $env:ProgramFiles 'whispr Hybrid VPN';$state=Join-Path $env:ProgramData 'whispr-hybrid'
    foreach($dir in @($root,$state)){
        $item=Get-Item -LiteralPath $dir -Force
        if($item -isnot [IO.DirectoryInfo] -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unrecognised installed application/state directory.'}
        if((Get-Acl -LiteralPath $dir).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){throw 'Application/state directory ownership differs.'}
        if((Get-Content -LiteralPath (Join-Path $dir 'install-owner.txt') -Raw).Trim() -ne 'whispr-hybrid-schema-1'){throw 'Application ownership marker differs.'}
    }
    . "$root/client/Common.ps1";Assert-HybridManifest $root
    $key=Read-GroupJson (Join-Path $state 'device-key.json')
    return @{Home=$root;State=$state;PublicKey=$key.PublicKey;Id=(Get-GroupKeyId $key.PublicKey)}
}
function Read-GroupWithLocalMerge([string]$Path,$Identity){
    $g=Read-GroupJson $Path;Assert-GroupDocument $g
    $catalog=Join-Path $Identity.State 'group-catalog.json'
    if(Test-Path -LiteralPath $catalog){$old=Read-GroupJson $catalog;$g=Merge-GroupDocuments $old.Group $g}
    if($Identity.Id -notin @($g.Members|ForEach-Object Id)){throw 'This device is not a member. Send its public friend-request.json to an existing member first.'}
    return $g
}
function Assert-GroupDisconnected($Identity){
    . "$($Identity.Home)/tray/Model.ps1"
    $mutex=Enter-TraySessionLock
    try{Assert-TrayDisconnected $Identity.Home}finally{$mutex.ReleaseMutex();$mutex.Dispose()}
}

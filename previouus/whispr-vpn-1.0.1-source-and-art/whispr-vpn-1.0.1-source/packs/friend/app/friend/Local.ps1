#requires -Version 7.2
function Assert-FriendInstallation {
    param([string]$InstallRoot,[string]$StateRoot)
    foreach($root in @($InstallRoot,$StateRoot)){
        $item=Get-Item -LiteralPath $root -Force -ErrorAction Stop
        if($item -isnot [IO.DirectoryInfo] -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unrecognized friend installation directory.'}
        if((Get-Acl -LiteralPath $root).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){throw 'Friend installation must be Administrators/SYSTEM owned.'}
        if((Get-Content -LiteralPath (Join-Path $root 'install-owner.txt') -Raw).Trim() -ne 'whispr-hybrid-schema-1'){throw 'Friend installation ownership marker differs.'}
    }
    $mode=Read-FriendJson (Join-Path $InstallRoot 'friend-mode.json')
    $state=Read-FriendJson (Join-Path $StateRoot 'friend-install.json')
    if($mode.product -cne 'whispr-hybrid-friend' -or $state.product -cne 'whispr-hybrid-friend'){throw 'This is not a friend installation. Do not run the friend installer on the owner PC.'}
    if($state.phase -cne 'ready'){throw 'Friend installation is incomplete. Rerun Install-Friend.ps1 before importing or exporting profiles.'}
    Assert-HybridManifest $InstallRoot
}

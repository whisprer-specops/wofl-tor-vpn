#requires -Version 7.2
. "$PSScriptRoot/Protocol.ps1"
$script:groupRegionCache=@{}
function Get-HybridGroupRegions([string]$StateRoot){
    $path=Join-Path $StateRoot 'group-catalog.json';if(-not (Test-Path -LiteralPath $path)){return @()}
    $stat=Get-Item -LiteralPath $path;$cacheKey=$path+'|'+$stat.LastWriteTimeUtc.Ticks+'|'+$stat.Length
    if($script:groupRegionCache.ContainsKey($cacheKey)){return $script:groupRegionCache[$cacheKey]}
    $rows=[Collections.Generic.List[object]]::new()
    $c=Read-GroupJson $path;Assert-GroupFields $c @('Schema','Group','Aliases');if($c.Schema -ne 1){throw 'Invalid local group catalogue.'};Assert-GroupDocument $c.Group
    foreach($n in $c.Group.Nodes){
        $alias=if($c.Aliases.ContainsKey($n.Id)){$c.Aliases[$n.Id]}else{$n.Id}
        $rows.Add(@{Alias=$alias;Name=$n.Name;Lon=[double]$n.Longitude;Lat=[double]$n.Latitude;Dx=12;Dy=14})
    }
    $script:groupRegionCache.Clear();$script:groupRegionCache[$cacheKey]=@($rows.ToArray());return $script:groupRegionCache[$cacheKey]
}
function Get-HybridExitAliases([string]$StateRoot){
    return @(@('nyc1','lon1','fkt1','sgp1','syd1')+@(Get-HybridGroupRegions $StateRoot|ForEach-Object Alias)|Select-Object -Unique)
}
function Get-HybridExitName([string]$Alias,[string]$StateRoot){
    $region=@(Get-HybridGroupRegions $StateRoot|Where-Object Alias -eq $Alias)|Select-Object -First 1
    if($region){return $region.Name};return $Alias
}
function Import-HybridGroup {
    param([hashtable]$Group,[string]$InstallRoot,[string]$StateRoot)
    Assert-GroupDocument $Group
    $key=Read-GroupJson (Join-Path $StateRoot 'device-key.json');$id=Get-GroupKeyId $key.PublicKey
    if($id -notin @($Group.Members|ForEach-Object Id)){throw 'This PC is not a member of the group. Ask for an updated group file containing this device public key.'}
    $catalogPath=Join-Path $StateRoot 'group-catalog.json';$aliases=@{}
    if(Test-Path -LiteralPath $catalogPath){$old=Read-GroupJson $catalogPath;$Group=Merge-GroupDocuments $old.Group $Group;foreach($n in $old.Aliases.Keys){$aliases[$n]=$old.Aliases[$n]}}
    $profiles=@{}
    foreach($n in $Group.Nodes){
        $alias=if($aliases.ContainsKey($n.Id)){$aliases[$n.Id]}else{$n.Id}
        # Reuse an existing legacy alias when the same public server is already configured.
        foreach($legacy in @('nyc1','lon1','fkt1','sgp1','syd1')){
            $path=Join-Path $StateRoot "profiles/$legacy.json"
            if(Test-Path -LiteralPath $path){$p=Read-GroupJson $path;if($p.server_public_key -ceq $n.ServerPublicKey -and $p.endpoint -ceq $n.Endpoint){$alias=$legacy;break}}
        }
        if($alias -cnotmatch '^(nyc1|lon1|fkt1|sgp1|syd1|exit-[0-9a-f]{24})$'){throw 'Invalid local node alias.'}
        $aliases[$n.Id]=$alias
        if($n.Assignments.ContainsKey($id)){
            $a=$n.Assignments[$id]
            $p=@{schema=1;ssh_alias=$alias;endpoint=$n.Endpoint;port=$n.Port;server_public_key=$n.ServerPublicKey;client_public_key=$key.PublicKey;client_ipv4=$a.IPv4;client_ipv6=$a.IPv6;ipv6=$n.IPv6;interface='wg-whispr'}
            Assert-TrayPeer $p $alias
            if($profiles.ContainsKey($alias)){throw 'Two shared nodes map to the same local profile.'};$profiles[$alias]=$p
        }
    }
    $trayMutex=[Threading.Mutex]::new($false,'Global\whisprHybridTray010');$locked=$false;$sessionMutex=$null
    try{
        try{$locked=$trayMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw 'Disconnect and choose Close tray only before importing group exits.'}
        $sessionMutex=Enter-TraySessionLock;Assert-TrayDisconnected $InstallRoot
        $profileRoot=Join-Path $StateRoot 'profiles';[void](New-Item -ItemType Directory -Path $profileRoot -Force)
        if((Get-Item -LiteralPath $profileRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected profile-directory reparse point.'}
        $paths=@('group-catalog.json','peer.json')+@($aliases.Values|Select-Object -Unique|ForEach-Object {"profiles/$_.json"})
        $backup=Join-Path $StateRoot ('group-backups/import-'+[guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory -Path $backup -Force);$before=@{}
        foreach($relative in $paths){
            $path=Join-Path $StateRoot $relative;$before[$relative]=Test-Path -LiteralPath $path
            if($before[$relative]){if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected profile-file reparse point.'};$dest=Join-Path $backup $relative;[void](New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force);Copy-Item -LiteralPath $path -Destination $dest}
        }
        try{
            foreach($alias in $profiles.Keys){Write-GroupJson $profiles[$alias] (Join-Path $profileRoot "$alias.json")}
            foreach($alias in @($aliases.Values|Select-Object -Unique)){
                if($alias -like 'exit-*' -and -not $profiles.ContainsKey($alias)){$path=Join-Path $profileRoot "$alias.json";if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}}
            }
            $activePath=Join-Path $StateRoot 'peer.json';$active=$null
            if(Test-Path -LiteralPath $activePath){$active=Read-GroupJson $activePath}
            if($active -and $profiles.ContainsKey($active.ssh_alias)){Write-GroupJson $profiles[$active.ssh_alias] $activePath}
            elseif(-not $active -or ($active.ssh_alias -like 'exit-*' -and $active.ssh_alias -in $aliases.Values -and -not $profiles.ContainsKey($active.ssh_alias))){
                if($profiles.Count -gt 0){$first=@($profiles.Keys|Sort-Object)[0];Write-GroupJson $profiles[$first] $activePath}
                elseif($active){throw 'No replacement for the currently selected shared exit is approved; existing profiles were retained.'}
            }
            Write-GroupJson @{Schema=1;Group=$Group;Aliases=$aliases} $catalogPath
        }catch{
            $failure=$_;foreach($relative in $paths){$path=Join-Path $StateRoot $relative;if($before[$relative]){Copy-Item -LiteralPath (Join-Path $backup $relative) -Destination $path -Force}elseif(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}};throw $failure
        }
    }finally{if($sessionMutex){$sessionMutex.ReleaseMutex();$sessionMutex.Dispose()};if($locked){$trayMutex.ReleaseMutex()};$trayMutex.Dispose()}
    return $profiles.Count
}

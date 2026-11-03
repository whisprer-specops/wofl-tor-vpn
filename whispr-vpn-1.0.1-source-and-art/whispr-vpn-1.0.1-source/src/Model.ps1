#requires -Version 7.2
Set-StrictMode -Version 3
$script:SuiteProduct='whispr-vpn-desktop-1'
function Get-SuiteCoreRoot {Join-Path $env:ProgramFiles 'whispr Hybrid VPN'}
function Get-SuiteStateRoot {Join-Path $env:ProgramData 'whispr-hybrid'}
function Get-SuiteWorkRoot {Join-Path $env:ProgramData 'whispr-vpn-desktop'}
function Read-SuiteJson([string]$Path){
    try{
        $file=Get-Item -LiteralPath $Path -Force
        if($file -isnot [IO.FileInfo] -or $file.Length -gt 8388608 -or $file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected JSON file.'}
        return (Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json -AsHashtable)
    }catch{throw "Cannot read the expected JSON document: $([IO.Path]::GetFileName($Path)). Contents withheld."}
}
function Write-SuiteJson($Value,[string]$Path){
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{[IO.File]::WriteAllText($temporary,($Value|ConvertTo-Json -Depth 50),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temporary -Destination $Path -Force}
    finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}
function Assert-SuiteDirectory([string]$Path){
    $item=Get-Item -LiteralPath $Path -Force
    if($item -isnot [IO.DirectoryInfo] -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected directory or link: '+$Path}
    if((Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){throw 'Unrecognised directory owner: '+$Path}
}
function Initialize-SuiteWorkspace {
    $root=Get-SuiteWorkRoot
    if(-not (Test-Path -LiteralPath $root)){
        [void](New-Item -ItemType Directory -Path $root)
        & icacls.exe $root '/setowner' '*S-1-5-32-544' | Out-Null
        if($LASTEXITCODE -ne 0){throw 'Could not set the local workspace owner.'}
        & icacls.exe $root '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
        if($LASTEXITCODE -ne 0){throw 'Could not secure the local workspace.'}
    }
    Assert-SuiteDirectory $root
    foreach($name in @('group','exports','jobs')){
        $path=Join-Path $root $name
        if(-not (Test-Path -LiteralPath $path)){[void](New-Item -ItemType Directory -Path $path)}
        $item=Get-Item -LiteralPath $path -Force
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected workspace link.'}
    }
    return $root
}
function Assert-SuiteManifest([string]$SuiteRoot){
    $manifest=Read-SuiteJson (Join-Path $SuiteRoot 'suite-manifest.json')
    foreach($relative in $manifest.Keys){
        if($relative -match '(^[/\\]|(^|[/\\])\.\.([/\\]|$)|:)'){throw 'Invalid suite manifest path.'}
        $path=Join-Path $SuiteRoot $relative
        $item=Get-Item -LiteralPath $path -Force
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $manifest[$relative]){throw 'Installed suite integrity check failed: '+$relative}
    }
}
# Existing task paths are identities, not locations to migrate implicitly.
function Get-SuiteRecordedHostProbe([string]$HostPath){
    $command=@'
$ErrorActionPreference='Stop'
[Console]::Out.Write((@{Edition=$PSVersionTable.PSEdition;Major=$PSVersionTable.PSVersion.Major;Minor=$PSVersionTable.PSVersion.Minor;Is64Bit=[Environment]::Is64BitProcess;Executable=(Join-Path $PSHOME 'pwsh.exe')}|ConvertTo-Json -Compress))
'@
    $p=[Diagnostics.ProcessStartInfo]::new($HostPath);$p.UseShellExecute=$false;$p.CreateNoWindow=$true
    $p.RedirectStandardOutput=$true;$p.RedirectStandardError=$true
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    foreach($a in @('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',$encoded)){$p.ArgumentList.Add($a)}
    $p.Environment['POWERSHELL_TELEMETRY_OPTOUT']='1'
    $child=[Diagnostics.Process]::Start($p)
    try{
        $out=$child.StandardOutput.ReadToEndAsync();$err=$child.StandardError.ReadToEndAsync()
        if(-not $child.WaitForExit(12000)){try{$child.Kill()}catch{};throw ('PowerShell host verification timed out: '+$HostPath)}
        if($child.ExitCode -ne 0){throw ('The recorded PowerShell host could not start: '+$HostPath+'. No task was changed.')}
        try{$probe=$out.GetAwaiter().GetResult()|ConvertFrom-Json -AsHashtable}catch{throw ('Unexpected host verification response: '+$HostPath)}
        return $probe
    }finally{$child.Dispose()}
}
function Test-SuiteHostPe64([string]$HostPath){
    $stream=[IO.File]::Open($HostPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader=[IO.BinaryReader]::new($stream)
    try{
        if($stream.Length -lt 128 -or $reader.ReadUInt16() -ne 0x5a4d){return $false}
        [void]$stream.Seek(0x3c,[IO.SeekOrigin]::Begin);$offset=$reader.ReadInt32()
        if($offset -lt 64 -or $offset -gt ($stream.Length-6)){return $false}
        [void]$stream.Seek($offset,[IO.SeekOrigin]::Begin)
        return ($reader.ReadUInt32() -eq 0x4550 -and $reader.ReadUInt16() -eq 0x8664)
    }finally{$reader.Dispose()}
}
function Assert-SuiteRecordedHost([string]$HostPath){
    if(-not [IO.Path]::IsPathFullyQualified($HostPath) -or [IO.Path]::GetFileName($HostPath) -ine 'pwsh.exe'){
        throw ('The recorded task does not name an absolute pwsh.exe path: '+$HostPath+'. No task was changed.')
    }
    if(-not (Test-Path -LiteralPath $HostPath -PathType Leaf)){
        throw ('The recorded PowerShell host is missing: '+$HostPath+'. An old Store/package version may have been removed. No task was changed.')
    }
    $file=Get-Item -LiteralPath $HostPath -Force
    if($file.Length -eq 0 -or -not (Test-SuiteHostPe64 $HostPath)){throw ('The recorded host is not an x64 executable: '+$HostPath)}
    $signature=Get-AuthenticodeSignature -LiteralPath $HostPath -ErrorAction Stop
    $microsoft=$signature.SignerCertificate -and $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -ceq 'Microsoft Corporation'
    if([string]$signature.Status -cne 'Valid' -or -not $microsoft){throw ('The recorded host does not have a valid Microsoft signature: '+$HostPath+' (status '+$signature.Status+'). No task was changed.')}
    $probe=Get-SuiteRecordedHostProbe $HostPath
    if($probe.Edition -cne 'Core' -or -not $probe.Is64Bit -or [int]$probe.Major -lt 7 -or ([int]$probe.Major -eq 7 -and [int]$probe.Minor -lt 2)){
        throw ('The recorded host must be 64-bit PowerShell 7.2 or newer: '+$HostPath)
    }
    if([IO.Path]::GetFullPath([string]$probe.Executable) -ine [IO.Path]::GetFullPath($HostPath)){
        throw ('The recorded host resolves to a different PSHOME: '+$HostPath+'. Task migration was not attempted.')
    }
}
function Get-SuiteHostChoice([string[]]$TaskHosts,[string]$GlobalHost,[string]$BundledHost){
    $hosts=@($TaskHosts|Where-Object {$_}|Sort-Object -Unique)
    if($hosts.Count -gt 1){throw ('Existing VPN tasks use different PowerShell hosts: '+($hosts -join '; ')+'. No task was changed.')}
    if($hosts.Count -eq 1){
        if($hosts[0] -ine $GlobalHost -and $hosts[0] -ine $BundledHost){Assert-SuiteRecordedHost $hosts[0]}
        # Preserve the recorded spelling/path: the existing task validator binds to PSHOME.
        return $hosts[0]
    }
    if(Test-Path -LiteralPath $GlobalHost){return $GlobalHost}
    return $BundledHost
}
function Open-SuiteMetadataRoot {
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
}
function Set-SuiteRuntimeLeaseRecord([bool]$Needed){
    $root=Open-SuiteMetadataRoot;$key=$null
    try{
        # CreateSubKey opens an existing key without clearing any values.
        $key=$root.CreateSubKey('Software\whispr.dev\VPN Desktop')
        $key.SetValue('CoreRuntimeLease',$(if($Needed){'1'}else{'0'}),[Microsoft.Win32.RegistryValueKind]::String)
    }finally{if($key){$key.Dispose()};$root.Dispose()}
}
function Update-SuiteRuntimeLease([string]$SuiteRoot){
    $needed=$false;$core=Get-SuiteCoreRoot
    $marker=Join-Path $core 'desktop-owned.json'
    if(Test-Path -LiteralPath $marker){
        $record=Read-SuiteJson $marker
        if($record.Product -eq $script:SuiteProduct -and $record.SuiteRoot -ieq $SuiteRoot){$needed=$true}
    }
    $service=New-Object -ComObject Schedule.Service
    try{
        $service.Connect()
        foreach($task in $service.GetFolder('\').GetTasks(1)){
            foreach($a in $task.Definition.Actions){
                if($a.Type -eq 0 -and [string]$a.Path -ieq (Join-Path $SuiteRoot 'runtime/powershell/pwsh.exe')){$needed=$true}
            }
        }
    }finally{if([Runtime.InteropServices.Marshal]::IsComObject($service)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($service)}}
    Set-SuiteRuntimeLeaseRecord $needed
    return $needed
}
function Get-SuiteCoreHost([string]$SuiteRoot){
    $globalHost=Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    $bundled=Join-Path $SuiteRoot 'runtime\powershell\pwsh.exe'
    $core=Get-SuiteCoreRoot;$hosts=[Collections.Generic.List[string]]::new()
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{$sid=$identity.User.Value}finally{$identity.Dispose()}
    $service=New-Object -ComObject Schedule.Service
    try{
        $service.Connect();$folder=$service.GetFolder('\')
        foreach($kind in @('Background','Autostart')){
            $name='whispr-HybridVPN-'+$kind+'-'+$sid
            $task=$null
            try{$task=$folder.GetTask($name)}catch{
                $code=[uint32]([long]$_.Exception.GetBaseException().HResult -band 0xffffffffL)
                if($code -ne 0x80070002L){throw}
            }
            if($task){
                $d=$task.Definition
                $source=if($kind -eq 'Background'){'whispr-hybrid-on-demand-v1'}else{'whispr-hybrid-autostart-v1'}
                $working=if($kind -eq 'Background'){Join-Path $core 'background'}else{$core}
                $scriptPath=if($kind -eq 'Background'){Join-Path $core 'background\Scheduled-Host.ps1'}else{Join-Path $core 'Tray.ps1'}
                if($d.RegistrationInfo.Source -ne $source -or $d.Actions.Count -ne 1){throw 'Existing VPN task ownership differs.'}
                $a=$d.Actions.Item(1)
                if($a.Type -ne 0 -or $a.WorkingDirectory -ine $working -or -not $a.Arguments.Contains($scriptPath)){throw 'Existing VPN task action differs.'}
                $hosts.Add([string]$a.Path)
            }
        }
    }finally{if([Runtime.InteropServices.Marshal]::IsComObject($service)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($service)}}
    $hostPath=Get-SuiteHostChoice @($hosts.ToArray()) $globalHost $bundled
    if(-not (Test-Path -LiteralPath $hostPath -PathType Leaf)){throw 'The PowerShell host recorded by the existing VPN is missing. No task was changed.'}
    return $hostPath
}
function Assert-SuiteCore {
    $core=Get-SuiteCoreRoot;$state=Get-SuiteStateRoot
    foreach($root in @($core,$state)){
        Assert-SuiteDirectory $root
        if((Get-Content -LiteralPath (Join-Path $root 'install-owner.txt') -Raw).Trim() -ne 'whispr-hybrid-schema-1'){throw 'Existing VPN ownership marker differs.'}
    }
    . "$core/client/Common.ps1";Assert-HybridManifest $core
    return $core
}
function Sync-SuiteGroupTools([string]$SuiteRoot){
    $workspace=Initialize-SuiteWorkspace;$dest=Join-Path $workspace 'group';$source=Join-Path $SuiteRoot 'packs/group'
    $manifest=Read-SuiteJson (Join-Path $source 'PACKAGE-SHA256SUMS.json')
    foreach($relative in @($manifest.Keys)+@('PACKAGE-SHA256SUMS.json')){
        if($relative -match '(^[/\\]|(^|[/\\])\.\.([/\\]|$)|:)'){throw 'Invalid group package path.'}
        $from=Join-Path $source $relative;$to=Join-Path $dest $relative
        $parent=Split-Path $to -Parent
        [void](New-Item -ItemType Directory -Path $parent -Force)
        if(@(Get-Item -LiteralPath $parent -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Unexpected group workspace directory link.'}
        if((Test-Path -LiteralPath $to) -and ((Get-Item -LiteralPath $to -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unexpected group workspace file link.'}
        if(-not (Test-Path -LiteralPath $to) -or (Get-FileHash -LiteralPath $from).Hash -ne (Get-FileHash -LiteralPath $to).Hash){Copy-Item -LiteralPath $from -Destination $to -Force}
    }
    $config=Join-Path $dest 'my-vps.json'
    if(-not (Test-Path -LiteralPath $config)){Copy-Item -LiteralPath (Join-Path $source 'my-vps.json') -Destination $config}
    $catalog=Join-Path (Get-SuiteStateRoot) 'group-catalog.json'
    if(-not (Test-Path -LiteralPath (Join-Path $dest 'group.json')) -and (Test-Path -LiteralPath $catalog)){
        $c=Read-SuiteJson $catalog
        . "$dest/group/Protocol.ps1";Assert-GroupDocument $c.Group
        Write-SuiteJson $c.Group (Join-Path $dest 'group.json')
    }
    return $dest
}
function New-SuitePublicRequest([string]$DeviceName,[string]$OutputDirectory){
    $core=Assert-SuiteCore;$state=Get-SuiteStateRoot
    if($DeviceName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$'){throw 'Use a short device name containing letters, numbers, spaces, dot, underscore or hyphen.'}
    $key=Read-SuiteJson (Join-Path $state 'device-key.json')
    $public=[string]$key.PublicKey
    $fingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Convert]::FromBase64String($public))).ToLowerInvariant()
    $stored=Join-Path $state 'friend-request.json'
    if(Test-Path -LiteralPath $stored){
        $request=Read-SuiteJson $stored
        if($request.PublicKey -cne $public -or $request.Fingerprint -cne $fingerprint){throw 'Stored public request does not match this device.'}
    }else{
        $request=@{Schema=1;Kind='whispr-friend-request';RequestId=[guid]::NewGuid().ToString('N');PublicKey=$public;Fingerprint=$fingerprint;DeviceName=$DeviceName;CreatedUtc=[DateTime]::UtcNow.ToString('o')}
        Write-SuiteJson $request $stored
    }
    $key=$null
    . "$PSScriptRoot/packs/friend/app/friend/Protocol.ps1"
    Assert-FriendRequest $request
    Write-SuiteJson $request (Join-Path $OutputDirectory 'friend-request.json')
}

function Get-SuiteSetupPlan {
    $core=Get-SuiteCoreRoot;$state=Get-SuiteStateRoot
    $hasCore=Test-Path -LiteralPath $core
    $hasState=Test-Path -LiteralPath $state
    $profiles=@('peer.json','profiles','group-catalog.json') | Where-Object {Test-Path -LiteralPath (Join-Path $state $_)}
    if(@($profiles).Count -and -not (Test-Path -LiteralPath (Join-Path $state 'device-key.json'))){throw 'Saved exits exist but the device identity is missing. Restore it before setup; no replacement key was created.'}
    $phasePath=Join-Path $state 'friend-install.json'
    if(Test-Path -LiteralPath $phasePath){
        $phase=Read-SuiteJson $phasePath
        if($phase.product -ceq 'whispr-hybrid-friend' -and ($phase.phase -ceq 'installing' -or (-not $hasCore -and $phase.phase -ceq 'ready' -and (Test-Path -LiteralPath (Join-Path $state 'device-key.json'))))){return 'Resume'}
    }
    if($hasCore){return 'Existing'}
    if($hasState){throw 'Saved state remains without a client. Use recovery to preserve and prepare the existing identity before setup.'}
    return 'Fresh'
}

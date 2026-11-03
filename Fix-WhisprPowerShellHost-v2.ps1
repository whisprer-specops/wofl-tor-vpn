#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$InspectOnly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$ExpectedOriginal='2A96ACF1191238EC02804392A028E6EA2CCC7E204A3B7355A8083194E22DC28D'
$ExpectedNew='DC2911ACCD7D400F33B4D7B74861717D8C8E76E65B99050B949FBCDF3E785749'
$PreviousHostFix='8FF35ABD152D7C626B496F1958943DA3554961EA3FF971F221CEB1933BADB79E'
$Payload='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'
function Get-Digest([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','')}finally{$sha.Dispose()}}
function Expand-Model([string]$Data){
    $stream=[IO.MemoryStream]::new([Convert]::FromBase64String($Data));$gzip=[IO.Compression.GZipStream]::new($stream,[IO.Compression.CompressionMode]::Decompress);$output=[IO.MemoryStream]::new()
    try{$gzip.CopyTo($output);return ,$output.ToArray()}finally{$output.Dispose();$gzip.Dispose();$stream.Dispose()}
}
function Assert-Plain([string]$Path,[switch]$Directory){
    $item=Get-Item -LiteralPath $Path -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Unexpected link at '+$Path)}
    if($Directory -and $item -isnot [IO.DirectoryInfo]){throw 'Expected a directory.'}
    if(-not $Directory -and $item -isnot [IO.FileInfo]){throw 'Expected a file.'}
}
function Save-Atomic([byte[]]$Bytes,[string]$Path){
    $tmp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllBytes($tmp,$Bytes)
        if(Test-Path -LiteralPath $Path){[IO.File]::Replace($tmp,$Path,[NullString]::Value)}else{[IO.File]::Move($tmp,$Path)}
    }finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force}}
}
function New-PrivateDirectory([string]$Path){
    if(Test-Path -LiteralPath $Path){Assert-Plain $Path -Directory;if((Get-Acl $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){throw 'Unexpected backup directory owner.'}}
    else{[void](New-Item -ItemType Directory -Path $Path)}
    & (Join-Path ([Environment]::SystemDirectory) 'icacls.exe') $Path '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '/setowner' '*S-1-5-32-544'|Out-Null
    if($LASTEXITCODE -ne 0){throw 'Could not secure the patch backup directory.'}
}
function Confirm-RecordedHost([string]$Root,[string]$HostExe){
    # The encoded command contains only this fixed, checksum-verified model and
    # the validated install directory; it never reads device-key.json.
    $literalRoot="'"+$Root.Replace("'","''")+"'"
    $command=@'
$ErrorActionPreference='Stop'
try{
 $inputStream=[IO.MemoryStream]::new([Convert]::FromBase64String('__PAYLOAD__'))
 $zip=[IO.Compression.GZipStream]::new($inputStream,[IO.Compression.CompressionMode]::Decompress)
 $out=[IO.MemoryStream]::new();$zip.CopyTo($out);$model=[Text.Encoding]::UTF8.GetString($out.ToArray());$zip.Dispose();$out.Dispose();$inputStream.Dispose()
 . ([scriptblock]::Create($model))
 $hostPath=Get-SuiteCoreHost __ROOT__
 [Console]::Out.Write((@{Ok=$true;HostPath=$hostPath}|ConvertTo-Json -Compress))
 exit 0
}catch{[Console]::Out.Write((@{Ok=$false;Message=$_.Exception.Message}|ConvertTo-Json -Compress));exit 1}
'@
    $command=$command.Replace('__PAYLOAD__',$Payload).Replace('__ROOT__',$literalRoot)
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    if($encoded.Length -gt 30000){throw 'Internal validation command is too long.'}
    $info=[Diagnostics.ProcessStartInfo]::new($HostExe);$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+$encoded
    $child=[Diagnostics.Process]::Start($info)
    try{
        $out=$child.StandardOutput.ReadToEndAsync();$err=$child.StandardError.ReadToEndAsync()
        if(-not $child.WaitForExit(45000)){try{$child.Kill()}catch{};throw 'Host verification timed out. No installed file was changed.'}
        $text=$out.GetAwaiter().GetResult()
        try{$result=$text|ConvertFrom-Json}catch{throw 'Could not validate the recorded host. No installed file was changed.'}
        if($child.ExitCode -ne 0 -or -not $result.Ok){throw ([string]$result.Message)}
        return [string]$result.HostPath
    }finally{$child.Dispose()}
}
function Assert-FixPlatform {
    if($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess){throw 'Use Administrator PowerShell x64 on Windows.'}
}
function Get-FixInstallRoot {return (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'whispr VPN')}
function Assert-FixRoot([string]$Root){
    Assert-Plain $Root -Directory
    if((Get-Acl $Root).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){throw 'The installed desktop directory owner differs.'}
}
function Assert-FixReleaseFiles([string]$Root){
    $known=@{
        'Desktop.ps1'='58422B930C383E026C6B6028963AE00DEBECAE1288FFC8FDC2B103437A4A68E7'
        'Worker.ps1'='C5044094474790172C28EC99D288F608248794579C68B2DB3D451D37E0692CA5'
    }
    foreach($name in $known.Keys){
        $path=Join-Path $Root $name;Assert-Plain $path
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $known[$name]){throw ('The installed '+$name+' is not the known desktop 1.0.0 release. No file was overwritten.')}
    }
}
function Read-RequiredValue($Object,[string]$Name){
    if($null -eq $Object -or -not $Object.PSObject.Properties[$Name]){throw ('The desktop integrity record is missing '+$Name+'. No patch was applied.')}
    return $Object.PSObject.Properties[$Name].Value
}
function Open-FixMetadataKey {
    $root=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    try{return $root.CreateSubKey('Software\whispr.dev\VPN Desktop')}finally{$root.Dispose()}
}
function Restore-FixMetadata([string]$Root){
    $key=Open-FixMetadataKey
    try{
        $product=[string]$key.GetValue('ProductCode','');$install=[string]$key.GetValue('InstallDir','')
        if($product -and $product -ine '{8EECFA30-9E1C-439B-AC91-C6AA86359808}'){throw 'Another app version owns the metadata key. It was not replaced.'}
        if($install -and [IO.Path]::GetFullPath($install).TrimEnd([char[]]@('\','/')) -ine $Root.TrimEnd([char[]]@('\','/'))){throw 'The metadata names a different install directory. It was not replaced.'}
        $key.SetValue('ProductCode','{8EECFA30-9E1C-439B-AC91-C6AA86359808}',[Microsoft.Win32.RegistryValueKind]::String)
        $key.SetValue('InstallDir',$Root+[IO.Path]::DirectorySeparatorChar,[Microsoft.Win32.RegistryValueKind]::String)
        # Never clear the key or alter the existing CoreRuntimeLease value.
    }finally{$key.Dispose()}
}
function Get-FixBackupParent {return (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'whispr-vpn-host-fixes')}
function Invoke-Fix {
    Assert-FixPlatform
    $root=Get-FixInstallRoot
    Assert-FixRoot $root
    Assert-FixReleaseFiles $root
    $modelPath=Join-Path $root 'Model.ps1';$manifestPath=Join-Path $root 'suite-manifest.json';$hostExe=Join-Path $root 'runtime\powershell\pwsh.exe'
    foreach($path in @($modelPath,$manifestPath,$hostExe)){Assert-Plain $path}
    $beforeModel=[IO.File]::ReadAllBytes($modelPath);$beforeManifest=[IO.File]::ReadAllBytes($manifestPath)
    $current=Get-Digest $beforeModel
    if($current -notin @($ExpectedOriginal,$PreviousHostFix,$ExpectedNew)){throw 'Model.ps1 is not the known original or this patch. It was not overwritten.'}
    $manifest=[Text.Encoding]::UTF8.GetString($beforeManifest)|ConvertFrom-Json
    if((Read-RequiredValue $manifest 'Model.ps1') -cne $current){throw 'The installed model and its integrity record differ. No patch was applied.'}
    if((Get-FileHash -LiteralPath $hostExe -Algorithm SHA256).Hash -cne (Read-RequiredValue $manifest 'runtime/powershell/pwsh.exe')){throw 'The bundled validation runtime does not match its integrity record.'}
    $newModel=Expand-Model $Payload
    if((Get-Digest $newModel) -cne $ExpectedNew){throw 'The embedded fix checksum is invalid.'}
    Write-Host 'Verifying the PowerShell host recorded by your existing tasks. No VPN/task changes...' -ForegroundColor Cyan
    $recorded=Confirm-RecordedHost $root $hostExe
    Write-Host ('Verified host: '+$recorded) -ForegroundColor Green
    if($InspectOnly){Write-Host 'Inspection passed. No installed files were changed.';return}
    if($current -ceq $ExpectedNew){Restore-FixMetadata $root;Write-Host 'This fix is already installed; app metadata checked/restored. Reopen whispr VPN from Start.';return}
    $parent=Get-FixBackupParent;New-PrivateDirectory $parent
    $backup=Join-Path $parent ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8));New-PrivateDirectory $backup
    [IO.File]::WriteAllBytes((Join-Path $backup 'Model.ps1'),$beforeModel)
    [IO.File]::WriteAllBytes((Join-Path $backup 'suite-manifest.json'),$beforeManifest)
    $manifest.'Model.ps1'=$ExpectedNew
    $newManifest=[Text.UTF8Encoding]::new($false).GetBytes(($manifest|ConvertTo-Json -Depth 20))
    try{
        Save-Atomic $newModel $modelPath;Save-Atomic $newManifest $manifestPath
        if((Get-FileHash -LiteralPath $modelPath -Algorithm SHA256).Hash -cne $ExpectedNew){throw 'The updated file did not verify.'}
        $check=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
        if((Read-RequiredValue $check 'Model.ps1') -cne $ExpectedNew){throw 'The updated integrity record did not verify.'}
        Restore-FixMetadata $root
    }catch{
        try{Save-Atomic $beforeModel $modelPath;Save-Atomic $beforeManifest $manifestPath}catch{throw ('Patch could not finish/roll back. Original files remain in '+$backup)}
        throw ('Patch did not finish; originals restored. Backup: '+$backup)
    }
    Write-Host 'FIX INSTALLED (revision 2). App metadata restored. Reopen whispr VPN from Start and retry the action.' -ForegroundColor Green
    Write-Host 'VPN processes, keys, profiles, task definitions and auto-connect settings were not changed.'
    Write-Host ('Original desktop files backed up: '+$backup)
    Write-Host 'A repair of the original 1.0.0 MSI can restore its old model; reapply this patch afterwards if needed.'
}
$mutex=[Threading.Mutex]::new($false,'Global\whisprVpnDesktop100');$locked=$false
try{
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Close the whispr VPN control-centre window first, then run this patch again. The running VPN tray may stay open.'}
    Invoke-Fix
}catch{Write-Host ('PATCH STOPPED: '+$_.Exception.Message) -ForegroundColor Red;exit 1}
finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}

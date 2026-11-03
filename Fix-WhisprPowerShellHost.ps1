#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$InspectOnly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$ExpectedOriginal='2A96ACF1191238EC02804392A028E6EA2CCC7E204A3B7355A8083194E22DC28D'
$ExpectedNew='8FF35ABD152D7C626B496F1958943DA3554961EA3FF971F221CEB1933BADB79E'
$Payload='H4sIAAAAAAACA9VbbXPbOJL+7l+BmlEdyYtJy4njZK1iVRTZTjzx21pysnuyJ0WTkMSYIjgEZVvr+L9fN15IUKJkz9RuXV0+ZBQCaHQ3up9+AebXnP4xi3PKifuV5jxmKXnnvd7o08LtF3kcFicsotXYm40WD/M4K/b6s7ig5zmLZmHhW/eTmGe5e5elbkT5bcEyd9vaGM3SsMBln5AcLuixnF4wVpDH31icuudBMSEtmt7tAaVxHkwP4wRYUeTI5/lNHkfk6/mp9dRArF8ExVpq+0ERaGLuRBBrJPSN5bcvpmPIaBK7oEEkqf3GWWoPOWgvHV+3kJjzuEHgT5HP5Q/80xqBqD6ycFTQKXGPYWUeJHJv8bd7yPKQlgvikS3WEDfmKfA6PDrzUF1H6YhdE5flkqR3TNMxrh4X5P2b9+932++NwW4BbN3MCjzvmyCNSirVwPXe3gXNgpzTc1BG4TwWk5zdE+sypQ8ZDQsakd/6Z6dE0AMNaP5yWszylNgoUo+lBU2LRqkugvufMH5H8+IwZ1MX1UXcLv8c8EkR3CTUESSfwqAIJ2rzX3pBijLnoGRSTCipsxKxcDaF/fZIy0aBcCMQAzhB0U6DKbXlOTgeUaxxch8XkwlNIu+Xpw3jHL/lwLJxkK2vQTKjm03n2YKDy1ge5HNffH5ledar4XgWR7D5Kb3/BL9sxxuwvlhrW6eWA3OKaWaV9qD1DyvEzt0kGdCHwq5obyoWtNIGTKlsn2agz7dtZ3OIS7zLweH7gzRkEfK5t5fSezCYIOHUcTon7I42GVq5C5LjRZwGQgmmAcoTHsFQkswfwQoHMFH6yApazuMFnT6/oaReU36Xc5BQan8fUCksWD5v9KUWzJi+1H3QdWIxrXKdkrzhPzjn3+QikSZPgHASp7d7xHolGHvSLAlP6YZJA/OOB2Nn9ynN7WGfhjOwjLl3DkoI4yxIPP3pKAJLjkcxza8dTxgJcUG+OCUfbKvvbrtv3e331qb6+ea1+3Znx3IMdoFHNk5jXmcY9zXYNc7nKI2LOEjif9EKOHkWhJSoU8kBRf0lXNUSI3Nkpf3gWsepEHJ4x8CTbHAkdcb492CeUVKeHXGNpeXC/yJxGIQJ9+gDlWPE2orTCQWdBWlI93ILPgCwA2Lgz//Wqtqzz44cu3fkHFZfpdZqI1ucFkJJi7Ms8pOczQr3dJYkNdw+7vYHB/84GvTO9g/giChpl4fQY7MkIqgYjqdKBbwlLAwScq+1q2FW/t3oJFJO6aoQY4NwYrdSAD4ijWGcs1kGlgD2yfKCw68f7IZbprpbGajSNwKgUJwgYsqy/gwzgbKPf+LoxIoqiqz162xFWPw3+m2pc+G0dcWrCCc1vQK1ToI0HoFyKtASn9ELNHJN1RS/njIQ29B9uYhYHH+6epH3A6ZaTv2gc5oAbt+Jwy7Je1/onBvni4oqJwI9iK7Esn8fbl1dXf+0f/8pfjhX3pVny28t5+eeY5VKOkrvwPMjIvgheheCZ2KmAUtmVIlSbv9/ctoC4gXm4jTMNhr36yZjBjgxmZL+5+7rt7uOJ6eG4LWlboelKNeGfngBIZJqDcGWdIwoTcIJDW/JKIBtI4GrerE2rqeNX8nBQ4zxd0yKgN8KrXISABzEAuOLmPJNgRIIDWh1nBSMTGNAMdxrmiVxGBfJ3GtIby8A5fOIRp8ZLyCjvaGVcYpPRlQN2RRkjPwP1kbrIM9Z3hW0znM6ojkF7PStPia+G0PIRjgTeQsgnidyF9v+8HgQxbgAEqK+qhkGmNN553010jkJfrC8YVz90xPjnZM4XT8LxztHfHfnY1z4w4P0Ls5ZikkgcKQ+g6wh5bxz8ADIKlJL3/Sx8/7ns5MDYmX3fIKhwnKelnKsHptmUBxxx9mwPkgVZf5wPw7GKWguDrmnNoFaJC9EKqEyr1KznVbmXXLah1wzkZxQX+ZlONIDFy7oKfsWpxG791tFPqNqH++CyqAMtNMoyCNQdDYr5JxOw7g4MJMExWyQRv5QiQW8DdjHgNPdHZWSyszRyBov0xjXYP7xcQ5OZGuTcBYwJ1CRxT1lx2zMIKLAL1AGlgXyH+lRit4VoqXjlwPJTU/SszY1exAvQJhuPhY5/DG4gdeNIthBhQUYNI53aJ2ffTu46H8+OD7+Pjg4Pjg5GFz88/vZ+eDscmBd+9a2pUx5EidR41mBmOK47FbmNBRmDHUsVnt1zXsI2AN2kEZdPk9DG46W5vniXHEKS1OXQqha9S2IC4A48P7C3n7dbrcxPQN21PCXOElsR9VCTx0JNbZ1zu5pLiyKTEA2AocLaaAEBlLEUwAhkEJgTWmHTzUQleRx254o8M2cxLYGkIPkCjXI4mZhlbGgFmu7QHlDTpnEsPuAA/QF6ZhGnmVsL8TLEId81DWaWvc+QCS2Rd57QfksKWxnfZVYqw9tM4QvawQ8OAO4oqsUogO7YEpisq53lKL2ofRnnMJRmIFfZEECYgVRcKvVyArfaTD1jXrvLKNphRObegQbLmq0/NYNld2iWW3a+nN/AhFCfRUIDLEQgtzi8D5NaEGVA7ewhqa5YOQjCJnPL8QHjVuSzwa/QKuRg2WLISnI9mvVXpBkhd1fguNv79qOtKqHt8FO5DxqHQvke1pI8jXhPqW3dvvhTSgkx3+d5fE4ToG5jxT+Cx7HRiNIv31zP9juzeu6i6lpgsXdHcmh/jSG/LUuibvr/BkGFaVVPC51RBZ1g8wSl/4Butl5+7ZNXMxfmhUoJr3f3d1xFsxSzW62SzMhNYP/SuvUoGQ0T444/jiESmb+9xkkflBlRkZUEypd1WsxZsVgAkaErcypEWoEbkQMkjrkRtQvQUqCG8g0IGwSTUekRy/EHSN/f7Z60dRkbSLqlWMajJzn2F5EyJhDZsY5aHqJyW5KGKAnJFE53YI64zYYUwQr0V2dBnMyCSA9v6EUUQubKNELBFvbS6yEqjdEas1CtDNxpIaCasBW0XFWhAktORKAQ3uANbRMvJqQt8XjcRqAi0jWuzOofCHVxZygr0dWymIkp6jMTJVWcZgzzkaADyVxD4nRvAceISMCVQ63ZgaGITRlTOiMDkwvn2cFdoSzydz7x9v234wlXHzARWg3mGJgUi4cYlO14aCIAD1bJ5pJ0mM5NsNQCEufS+miBnsF/JfLEsT6ikWYVZ1VJfO6cyl9SphXQGQpV3FSbrZgsMTmcnP4usjQK8tZH+xVkF9dh1QHWlqlWOKpWkGJjJcGpsRyjkryJRBBsXWtvov6QQD/O1nyNQzCMbyTVlAbxJpCrHz9rMsLrU5n8BeIsbvj3gAnBgy8815j4w8iqmqllbZfx6MFBAW0xX9VRqDUUfqRQtQVy0wffQH7kBax5I6KSjIgUTwSNR7IIQqjJega4DnLihPPBk9c+HqBPd3CxKSmOxak1JuwOCyrz+H1dQtp4givGuyfEnYTJPix+vZxlkaJNBydT6EE3P9gVyR+fpsA/+7ZzQ/IA8lj6/vTzz6DMKg+uFDa/DFTtwtoaoKC12OzVCYF25UDlcX41/NTYd+czDg1VVRHfI7KUhSJ+wNqTGJ1iOj2r/WQJTbAMLcXejZifNi+lidvqEfB2MJ4TVWrEoFqVZXo/Eqgyofpd7IFWZoKz0BK0MWWDLry9sXsVQgsCSCgkRsoYoU1SQvylhJsvWvdCVaF40rUKjurvtV7cobYpvldZsCZalZfgIahNIKIzuma9lxKKdbMukQHLRgQpu8vdScvv4VU2ugp4Gxi6StQbBJHsmP3nKySlNmOlQew2CRUExe6ejjTU5exwoiabmnLPFPMrtpybowLDD2UKsBOgtkAbaF5gAf72NjVbgX1vPrZDyc0mkFW0ZfTGmprRQDMPU1hiZG0l40FYVPYyNRzEeEgZ4Ly0LqyRIWILs/tbRPllnsTgpC3TyFlFsHEk9kCX1iklRh4It9TmZAIDdpEAk8eGOppRZM2l7a1lSEucMSFrSrpbdSo/lP966me4mN0UCbriU4Ky5ReOYQx2CRIRJpe6t/WGisb8C9Yf4i7XUCBCE7RQOlJR3Js6lqfvxyf7F31IWG4h8rySl6IexG9u0Kc3FeX4huNlzdLPV2naR6YagaINW9szWIuRYQHGp4MlNUacX6yr0VceRvWsvFopfKdR2vbeqLg1I9W23pyamxoGJFTGwMYblwvopagY1yCk7/2eUMVPa7eXZV2ImncSCDz19rZVWVni+ub8aqj4uWwx5KESkcAT4KsNw49bLlpoVQbQPUKVPN57jfdQsqWJT9Sc2Qu0pvlGCDtqoEAeSMYvqaErdBc3lVWxWw5aJSz/yG86bRGAkv8FfCyjEe3IKbqdX6Eeg1v0rB7aUG9wkQDzFrEIXFnVr6JkY9YwEFcyKeQ2CvLFdl0VF+EcOW3UvPqsFShHJOcawCU93u6N7iEaS2so/zhLMZ+w7U9TBia7HfIJUOaCTzEFi84UPnBdrzPsvemrlTaDyP159hpxMywbB0+vG+337Xb7dfHKolaBXJ6KUrUgMQtxMg6bi/P4WwGjusjGXE4iNnm2YCn1978uAxf7GDT2b0rIaA+I9CHKWYsb4nXguAe6/ZcygJuqlG5p/jeQFzGalz6F+lfaU+IXAQfL+NazKVFgzyYy/HGE428CzoGOJA5Ppa/Xl9oWxyz0rxsp0U6oOrcFSaUKfRyBi2fFfBJnKk0mntNig58gzBGBAjza+M1Wp9kKPC+yVMy7phFSqwOz6ggg/K6AblPiyBOuW2cg7NGjkDGhXVCyJQeLzEWcgjn/2Hon6gS0G8o5QAUlbAD1s3BtGzHMcNgGc5e1n+brOy/qdPAGnax2VYWKjfzenGCJ1Z14lYUYvUqQjOwqpmK4ZQ8rg+02DAxBspHigtX9hjORVQRhDblMjOSPPfMw3xF1Pjezl58y2HF8opa1CW5VzxA6BLv8RxvkMdT1bBfQEYO0DIN3G2r2SUqr5aFyaJfyL898osQcytMYuBzC+8AIQIBDv3SUXLKMKmfT0j11s5GfDDOpT9PQ6mdT/i4ZcBYwtfkZuXDDn/lI6ZOK6L11K16DaJe0HR08GlOz7Chy7fk1Jc/9lCoap13e1+6nw5c+fCgf3nSf/a1B5hP/b3HK0hTVtL5D7wGEbIS3cheegwyytnUXxa13LrTKpg5HomzX34nkgWYVfr9LIkVcsBChAn8/FdejEmCtRpAqeWDvfI9irFkqdn0F16kPDkydDa9Q5J6reyvep5nvkvSGLDySSZzZC1rrxIKtSh18FceUL2Ec/FmuYHp9aFAcP7Mgx00Lv08B4Br3VQgJyY6jz2WzZsUgcQWHsGWuqn1QEKWjuLxktFa07l7l/F6t2e9jJKSs5KnJowwd3EW+JX0NJsBQD0z+bSXY5KjcM1Vs/8E9/aSAgQljTTK7FaKLvervT8Ml3pdalY5BcMI7iURdguK6oKFLKnFEREM9tWDcCDhiQ8liYXn3eWEZ+RpeAWIk8x4hKgj222zmyQOL+gfs9o7wH2KaZW4Dyq/yXclJTg5ZmqxmHc8k1kgoFdb4M0JKxSs/z7suv8TuP9qu3+7rn4S77t7/dje3H3z1KpwHcpzEhA+YXlBIkFOXsOGMkvGsJ/QAk4Sn6PNpjfih3B0+G/Eik0CCR98FNUG+O9knk1oql2/dUvnayMhioT9U9zYhcmm+luZUKxfag/HpbIh9OmLUEjr8gzGi/qrp8/0QT95ar7Ok8ES5iJM4P/wYRvr8QlK7d2U4sVx8Hn/MWakGBDzOChbHyALqKDWx1HSjXLIgSI3lwbysvawJFZvD4vlSz4jZy7EeblTqSv1mlHKoJ9vyDmHlQLVLEOlpZWI6+uIKAJqbXXJKO2ugDxS2VCZDYqidFmID499kWb6250vUP2WvZO6qqyOcqqjyH/mf7PolLL6SsyOIZlvCtWpvMY3PKgjX+ZFlwVYHNgDHUA1hQ/kivCU3Ru7MfNt0xK8aN2Y52L4QtXvQWw77/dFCYpOvSVzSamBrSDL9M8a6pkPwg/F+IXeUO28sZYt0/kWwKjZUB2AvP8Feof8PzQ2AAA='
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
function Invoke-Fix {
    if($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess){throw 'Use Administrator PowerShell x64 on Windows.'}
    $root=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'whispr VPN'
    Assert-Plain $root -Directory
    if((Get-Acl $root).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){throw 'The installed desktop directory owner differs.'}
    $registered=Get-ItemProperty -LiteralPath 'HKLM:\Software\whispr.dev\VPN Desktop' -ErrorAction Stop
    if($registered.ProductCode -ine '{8EECFA30-9E1C-439B-AC91-C6AA86359808}' -or [IO.Path]::GetFullPath([string]$registered.InstallDir).TrimEnd('\') -ine $root){throw 'This patch is for whispr VPN desktop MSI 1.0.0.'}
    $modelPath=Join-Path $root 'Model.ps1';$manifestPath=Join-Path $root 'suite-manifest.json';$hostExe=Join-Path $root 'runtime\powershell\pwsh.exe'
    foreach($path in @($modelPath,$manifestPath,$hostExe)){Assert-Plain $path}
    $beforeModel=[IO.File]::ReadAllBytes($modelPath);$beforeManifest=[IO.File]::ReadAllBytes($manifestPath)
    $current=Get-Digest $beforeModel
    if($current -notin @($ExpectedOriginal,$ExpectedNew)){throw 'Model.ps1 is not the known original or this patch. It was not overwritten.'}
    $manifest=[Text.Encoding]::UTF8.GetString($beforeManifest)|ConvertFrom-Json
    if($manifest.'Model.ps1' -cne $current){throw 'The installed model and its integrity record differ. No patch was applied.'}
    if((Get-FileHash -LiteralPath $hostExe -Algorithm SHA256).Hash -cne $manifest.'runtime/powershell/pwsh.exe'){throw 'The bundled validation runtime does not match its integrity record.'}
    $newModel=Expand-Model $Payload
    if((Get-Digest $newModel) -cne $ExpectedNew){throw 'The embedded fix checksum is invalid.'}
    Write-Host 'Verifying the PowerShell host recorded by your existing tasks. No VPN/task changes...' -ForegroundColor Cyan
    $recorded=Confirm-RecordedHost $root $hostExe
    Write-Host ('Verified host: '+$recorded) -ForegroundColor Green
    if($InspectOnly){Write-Host 'Inspection passed. No installed files were changed.';return}
    if($current -ceq $ExpectedNew){Write-Host 'This fix is already installed. Reopen whispr VPN from Start.';return}
    $parent=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'whispr-vpn-host-fixes';New-PrivateDirectory $parent
    $backup=Join-Path $parent ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8));New-PrivateDirectory $backup
    [IO.File]::WriteAllBytes((Join-Path $backup 'Model.ps1'),$beforeModel)
    [IO.File]::WriteAllBytes((Join-Path $backup 'suite-manifest.json'),$beforeManifest)
    $manifest.'Model.ps1'=$ExpectedNew
    $newManifest=[Text.UTF8Encoding]::new($false).GetBytes(($manifest|ConvertTo-Json -Depth 20))
    try{
        Save-Atomic $newModel $modelPath;Save-Atomic $newManifest $manifestPath
        if((Get-FileHash -LiteralPath $modelPath -Algorithm SHA256).Hash -cne $ExpectedNew){throw 'The updated file did not verify.'}
        $check=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
        if($check.'Model.ps1' -cne $ExpectedNew){throw 'The updated integrity record did not verify.'}
    }catch{
        try{Save-Atomic $beforeModel $modelPath;Save-Atomic $beforeManifest $manifestPath}catch{throw ('Patch could not finish/roll back. Original files remain in '+$backup)}
        throw ('Patch did not finish; originals restored. Backup: '+$backup)
    }
    Write-Host 'FIX INSTALLED. Reopen whispr VPN from Start and retry the action.' -ForegroundColor Green
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

#requires -Version 7.0
[CmdletBinding()]
param([string]$Engine = (Join-Path (Join-Path $env:ProgramFiles 'whispr Hybrid VPN') 'bin\sing-box.exe'))
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. "$root/client/Common.ps1"
$bad=@()
Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse | ForEach-Object {
    $tokens=$null;$errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count){$bad+=@($errors)}
}
if($bad.Count){$bad | Format-List;throw 'PowerShell parser found errors.'}
Add-Type -Path "$root/client/ProcessJob.cs"
$pair=(& $Engine generate wg-keypair | Out-String)
if($LASTEXITCODE -ne 0){throw 'Engine key generation failed.'}
$private=[regex]::Match($pair,'(?m)^PrivateKey:\s*(\S+)').Groups[1].Value
$public=[regex]::Match($pair,'(?m)^PublicKey:\s*(\S+)').Groups[1].Value
$temp=Join-Path ([IO.Path]::GetTempPath()) ('whispr-config-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try{
    foreach($ipv6 in @($false,$true)){
        $peer=@{endpoint='203.0.113.1';port=51832;client_ipv4='10.88.70.2/32';client_ipv6='fd89:77:70::2/128';ipv6=$ipv6;server_public_key=$public}
        $cfg=Get-HybridConfig -Peer $peer -PrivateKey $private -TorPath 'C:\Program Files\whispr Hybrid VPN\bin\tor\tor.exe'
        $path=Join-Path $temp 'test.json';Write-HybridJson $cfg $path
        Invoke-HybridChecked $Engine @('check','-c',$path)
    }
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
Write-Host 'Parser, managed job-helper compilation and both configuration variants passed. No TUN or firewall policy was activated.'

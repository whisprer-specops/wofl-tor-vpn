#requires -Version 7.2
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../src/Model.ps1"
function Check([bool]$Test,[string]$Why){if(-not $Test){throw $Why}}
function Reject([scriptblock]$Action,[string]$Why){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed $Why}
# Only file/signature/process probe boundaries are mocked, never task mutation.
$folder=Join-Path ([IO.Path]::GetTempPath()) ('whispr-host-test-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $folder)
try{
    $global=Join-Path $folder 'PowerShell/7/pwsh.exe';$bundle=Join-Path $folder 'whispr/runtime/powershell/pwsh.exe'
    $custom=Join-Path $folder 'WindowsApps/Microsoft.PowerShell_7.6.9.0_x64__8wekyb3d8bbwe/pwsh.exe'
    foreach($path in @($global,$bundle,$custom)){[void](New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force);[IO.File]::WriteAllText($path,'fixture')}
    $script:pe=$true;$script:signed='Valid';$script:publisher='Microsoft Corporation';$script:major=7;$script:minor=6;$script:is64=$true;$script:otherHome=$false
    function Test-SuiteHostPe64([string]$HostPath){return $script:pe}
    function Get-AuthenticodeSignature {
        param($LiteralPath,$ErrorAction)
        $cert=[pscustomobject]@{};$cert|Add-Member ScriptMethod GetNameInfo {param($Type,$Issuer);return $script:publisher}
        return [pscustomobject]@{Status=$script:signed;SignerCertificate=$cert}
    }
    function Get-SuiteRecordedHostProbe([string]$HostPath){return @{Edition='Core';Major=$script:major;Minor=$script:minor;Is64Bit=$script:is64;Executable=$(if($script:otherHome){$global}else{$HostPath})}}
    Check ((Get-SuiteHostChoice @($custom) $global $bundle) -ceq $custom) 'Valid Store task host was not preserved.'
    $preview=Join-Path $folder 'PowerShell/7-preview/pwsh.exe';[void](New-Item -ItemType Directory -Path (Split-Path $preview -Parent));[IO.File]::WriteAllText($preview,'fixture')
    Check ((Get-SuiteHostChoice @($preview) $global $bundle) -ceq $preview) 'Valid preview/custom location was not preserved.'
    Check ((Get-SuiteHostChoice @($bundle) $global $bundle) -ceq $bundle) 'Bundled task host lost precedence.'
    Check ((Get-SuiteHostChoice @($global) $global $bundle) -ceq $global) 'System task host changed.'
    Check ((Get-SuiteHostChoice @() $global $bundle) -ceq $global) 'Fresh system fallback changed.'
    Remove-Item -LiteralPath $global
    Check ((Get-SuiteHostChoice @() $global $bundle) -ceq $bundle) 'Fresh portable fallback changed.'
    Reject {Get-SuiteHostChoice @($custom,$bundle) $global $bundle} 'Mixed hosts accepted.'
    $script:signed='HashMismatch';Reject {Get-SuiteHostChoice @($custom) $global $bundle} 'Invalid signature accepted.';$script:signed='Valid'
    $script:publisher='Another publisher';Reject {Get-SuiteHostChoice @($custom) $global $bundle} 'Non-Microsoft publisher accepted.';$script:publisher='Microsoft Corporation'
    $script:pe=$false;Reject {Get-SuiteHostChoice @($custom) $global $bundle} 'Non-x64 executable accepted.';$script:pe=$true
    $script:minor=1;Reject {Get-SuiteHostChoice @($custom) $global $bundle} 'Old PowerShell accepted.';$script:minor=6
    $script:is64=$false;Reject {Get-SuiteHostChoice @($custom) $global $bundle} '32-bit runtime accepted.';$script:is64=$true
    $script:otherHome=$true;Reject {Get-SuiteHostChoice @($custom) $global $bundle} 'Redirected PSHOME accepted.';$script:otherHome=$false
    Remove-Item -LiteralPath $custom;Reject {Get-SuiteHostChoice @($custom) $global $bundle} 'Missing Store version accepted.'
    Write-Host 'PASS: valid Store/preview host reuse; standard and fresh fallbacks; mixed, missing, invalid-signature, wrong-publisher, old, non-x64 and redirected-host rejection.'
}finally{Remove-Item -LiteralPath $folder -Recurse -Force}

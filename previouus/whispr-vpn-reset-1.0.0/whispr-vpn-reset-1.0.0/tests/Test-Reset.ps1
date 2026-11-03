#requires -Version 7.2
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($file in Get-ChildItem -LiteralPath $root -Filter '*.ps1'){
    $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($file.Name+': '+($errors.Message -join '; '))}
}
. "$root/Reset-WhisprVpn.ps1" -LibraryOnly
# Is-Under/Join-Path are Windows path operations. Supply portable equivalents only
# for Linux unit execution; no Windows/MSI/COM/adapter operation is called.
if(-not $IsWindows){
    function Is-Under([string]$Path,[string]$Root){return $Path.StartsWith($Root.TrimEnd('/')+'/',[StringComparison]::OrdinalIgnoreCase)}
}
function Check([bool]$Pass,[string]$Message){if(-not $Pass){throw $Message}}
$folder=Join-Path ([IO.Path]::GetTempPath()) ('whispr-reset-test-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $folder)
try{
    $state=Join-Path $folder 'state';[void](New-Item -ItemType Directory -Path $state)
    Check (-not (Get-SeedPlan $state).HasKey) 'Missing keys must not be invented by cleanup.'
    $pub=[Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('public')))
    $priv=[Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('private-fixture')))
    Write-Json @{PublicKey=$pub;PrivateKey=$priv} (Join-Path $state 'device-key.json')
    $peer=@{client_public_key=$pub;server_public_key=$pub;interface='wg-whispr';ssh_alias='fkt1'}
    Write-Json $peer (Join-Path $state 'peer.json')
    Write-Json @{TunnelGuid='old';State='armed'} (Join-Path $state 'session.json')
    Write-Json @{private_key='old'} (Join-Path $state 'engine.json')
    $plan=Get-SeedPlan $state
    Check ($plan.HasKey -and $plan.Files.Count -eq 2) 'Only identity and approved profiles should be re-seeded.'
    Check ('session.json' -notin $plan.Files -and 'engine.json' -notin $plan.Files) 'Stale session/runtime config must never be restored.'
    function Secure-Directory([string]$Path){[void](New-Item -ItemType Directory -Path $Path)}
    $fresh=Join-Path $folder 'fresh';Restore-Seed $state $fresh $plan
    Check ((Get-FileHash (Join-Path $state 'device-key.json')).Hash -ceq (Get-FileHash (Join-Path $fresh 'device-key.json')).Hash) 'Private identity bytes changed.'
    Check ((Read-Json (Join-Path $fresh 'friend-install.json')).phase -ceq 'installing') 'Fresh installer bootstrap phase differs.'
    Check (-not (Test-Path (Join-Path $fresh 'session.json'))) 'Live session was resurrected.'
    $peer.client_public_key=$priv;Write-Json $peer (Join-Path $state 'peer.json')
    $failed=$false;try{Get-SeedPlan $state|Out-Null}catch{$failed=$true};Check $failed 'Mismatched profile accepted.'
    $core=Join-Path $folder 'whispr Hybrid VPN';$suite=Join-Path $folder 'whispr VPN'
    Check (Test-OwnCommand (Join-Path $core 'bin/tor.exe') '' $core $suite) 'Owned Tor missed.'
    Check (-not (Test-OwnCommand '/other/Tor Browser/tor.exe' '' $core $suite)) 'Other Tor process selected.'
    Check (-not (Test-OwnCommand ($suite+'-other/pwsh.exe') '' $core $suite)) 'Prefix collision selected.'
    Check (Test-OwnCommand 'pwsh.exe' ('-NoProfile -File "'+(Join-Path $core 'Tray.ps1')+'"') $core $suite) 'Owned script missed.'
    Check (-not (Test-OwnCommand 'pwsh.exe' ('-File "unrelated.ps1" -Data "'+$core+'/Tray.ps1"') $core $suite)) 'Data argument falsely selected as script.'
    $sid='S-1-5-21-123-456-789-1001'
    $argsText='-NoLogo -File "'+(Join-Path $core 'Tray.ps1')+'" -AutoConnect'
    Check (Test-TaskRecord ('whispr-HybridVPN-Autostart-'+$sid) 'whispr-hybrid-autostart-v1' 'pwsh.exe' $argsText $core $sid $core $suite) 'Owned task missed.'
    $failed=$false;try{Test-TaskRecord ('whispr-HybridVPN-Autostart-'+$sid) 'unknown-source' 'pwsh.exe' $argsText $core $sid $core $suite|Out-Null}catch{$failed=$true};Check $failed 'Foreign task source accepted.'
    $failed=$false;try{Test-TaskRecord 'Other program' 'other' ($suite+'/runtime/powershell/pwsh.exe') '' '' $sid $core $suite|Out-Null}catch{$failed=$true};Check $failed 'Unrelated runtime consumer was ignored.'
    function Secure-BackupTree([string]$Path) {} # Native ACL boundary is Windows-only.
    # Quarantine retries must never overwrite the first backup.
    $script:Backup=Join-Path $folder 'backup';[void](New-Item -ItemType Directory -Path $script:Backup)
    $old=Join-Path $folder 'client';[void](New-Item -ItemType Directory -Path $old);[IO.File]::WriteAllText((Join-Path $old 'key'),'original')
    Quarantine $old 'client-state'
    [void](New-Item -ItemType Directory -Path $old);[IO.File]::WriteAllText((Join-Path $old 'key'),'retry')
    Quarantine $old 'client-state'
    Check ((Get-Content (Join-Path $script:Backup 'client-state/key')) -ceq 'original') 'Retry overwrote original backup.'
    Write-Host 'PASS: parsing, identity preservation, fresh bootstrap, stale-session exclusion, profile mismatch rejection, process/task scoping, runtime-consumer stop and retry backup preservation.'
}finally{Remove-Item -LiteralPath $folder -Recurse -Force}

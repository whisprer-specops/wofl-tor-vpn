#requires -Version 7.0
#requires -RunAsAdministrator
# Windows-only regression test. Uses disposable fixture files, no network policy.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../client/Permissions.ps1"
$root=Join-Path ([IO.Path]::GetTempPath()) ('whispr-acl-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/downloads" -Force | Out-Null
$key=Join-Path $root 'device-key.fixture'
$nested=Join-Path $root 'downloads/cache.fixture'
'not-a-real-key' | Set-Content -LiteralPath $key
'cached-payload-fixture' | Set-Content -LiteralPath $nested
$before=(Get-FileHash -LiteralPath $key).Hash
try{
    Repair-HybridTreePermissions -Root $root -AllowUsersRead $false
    # Simulate an owned child with no data-write/read grant for Administrators.
    $locked=[Security.AccessControl.FileSecurity]::new()
    $locked.SetAccessRuleProtection($true,$false)
    $locked.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'),
        [Security.AccessControl.FileSystemRights]::ReadPermissions,
        [Security.AccessControl.AccessControlType]::Allow))
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($key),$locked)
    Repair-HybridTreePermissions -Root $root -AllowUsersRead $false
    if((Get-FileHash -LiteralPath $key).Hash -ne $before){throw 'Fixture contents changed.'}
    foreach($path in @($root,"$root/downloads",$key,$nested)){
        $acl=Get-Acl -LiteralPath $path
        if(-not $acl.AreAccessRulesProtected){throw 'Expected protected explicit DACL.'}
        $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
        foreach($sid in @('S-1-5-18','S-1-5-32-544')){
            $full=@($rules | Where-Object {$_.IdentityReference.Value -eq $sid -and $_.AccessControlType -eq 'Allow' -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl})
            if(-not $full.Count){throw "Missing complete grant for $sid on fixture"}
        }
        if(@($rules | Where-Object {$_.IdentityReference.Value -eq 'S-1-5-32-545'}).Count){throw 'Users have a private-state ACE.'}
    }
    Add-Content -LiteralPath $key -Value 'write-test'
    Repair-HybridTreePermissions -Root $root -AllowUsersRead $false
    Write-Host 'PASS: private-state access repaired; original contents retained before write-test; repeat application succeeded.'
}finally{
    Repair-HybridTreePermissions -Root $root -AllowUsersRead $false
    Remove-Item -LiteralPath $root -Recurse -Force
}

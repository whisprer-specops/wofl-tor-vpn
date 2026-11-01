# ACL repair is limited to an explicitly supplied app root, traversed top down.
# No inherited permissions are removed until the replacement explicit DACL is ready.
function Set-HybridItemPermissions {
    param([System.IO.FileSystemInfo]$Item,[bool]$AllowUsersRead)
    if($Item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Refusing permissions changes through a reparse point: $($Item.FullName)"}
    $directory=$Item -is [IO.DirectoryInfo]
    $acl=if($directory){[Security.AccessControl.DirectorySecurity]::new()}else{[Security.AccessControl.FileSecurity]::new()}
    $acl.SetAccessRuleProtection($true,$false)
    foreach($sidText in @('S-1-5-18','S-1-5-32-544')){
        $sid=[Security.Principal.SecurityIdentifier]::new($sidText)
        if($directory){
            $rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,
                ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
                [Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        }else{
            $rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow)
        }
        [void]$acl.AddAccessRule($rule)
    }
    if($AllowUsersRead){
        $users=[Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
        if($directory){
            $rule=[Security.AccessControl.FileSystemAccessRule]::new($users,[Security.AccessControl.FileSystemRights]::Read,
                ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
                [Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        }else{$rule=[Security.AccessControl.FileSystemAccessRule]::new($users,[Security.AccessControl.FileSystemRights]::Read,[Security.AccessControl.AccessControlType]::Allow)}
        [void]$acl.AddAccessRule($rule)
    }
    # Persist the complete DACL in one call, preserving the existing owner.
    if($directory){[IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]$Item,$acl)}
    else{[IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]$Item,$acl)}
}
function Repair-HybridTreePermissions {
    param([string]$Root,[bool]$AllowUsersRead)
    $item=Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if($item -isnot [IO.DirectoryInfo]){throw 'Permission repair root must be a directory.'}
    Set-HybridItemPermissions $item $AllowUsersRead
    # Grant each directory its complete DACL BEFORE attempting to enumerate it.
    $pending=[Collections.Generic.Stack[string]]::new();$pending.Push($item.FullName)
    while($pending.Count){
        $parent=$pending.Pop()
        foreach($child in @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop)){
            Set-HybridItemPermissions $child $AllowUsersRead
            if($child -is [IO.DirectoryInfo]){$pending.Push($child.FullName)}
        }
    }
}

#requires -Version 7.2
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../src/Model.ps1"
$script:FixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('whispr-workspace-'+[guid]::NewGuid().ToString('N'))
$script:Calls=[Collections.Generic.List[object]]::new()
function Get-SuiteWorkRoot {return $script:FixtureRoot}
function Assert-SuiteDirectory([string]$Path){if(-not (Test-Path -LiteralPath $Path -PathType Container)){throw 'Missing workspace root.'}}
function icacls.exe {
    if('/setowner' -in $args -and ('/grant:r' -in $args -or '/inheritance:r' -in $args)){throw 'Regression: owner and DACL operations combined.'}
    $script:Calls.Add(@($args));$global:LASTEXITCODE=0
}
try{
    $root=Initialize-SuiteWorkspace
    if($root -cne $script:FixtureRoot -or $script:Calls.Count -ne 2){throw 'Workspace creation did not make the two separate permission operations.'}
    if('/setowner' -notin $script:Calls[0] -or '/setowner' -in $script:Calls[1]){throw 'Permission operation ordering differs.'}
    foreach($name in @('group','exports','jobs')){if(-not (Test-Path -LiteralPath (Join-Path $root $name) -PathType Container)){throw 'Missing workspace child.'}}
    [void](Initialize-SuiteWorkspace)
    if($script:Calls.Count -ne 2){throw 'Existing workspace permissions were unnecessarily reset.'}
    Write-Host 'PASS: first-run workspace creation separates owner/DACL commands; existing workspace performs neither. Native command boundary mocked.'
}finally{Remove-Item -LiteralPath $script:FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue}

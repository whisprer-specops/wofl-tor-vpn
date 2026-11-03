function Install-HybridEngine([string]$InstallRoot,[string]$State) {
    $expected='99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df'
    $name='sing-box-1.14.4-windows-amd64.zip'
    $cache=Join-Path $State 'downloads';New-Item -ItemType Directory -Path $cache -Force | Out-Null
    $archive=Join-Path $cache $name
    if(-not (Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected){
        Write-Host 'Downloading pinned sing-box 1.14.4 from its official GitHub release (about 33 MB)...'
        $part=$archive+'.partial'
        try {
            Invoke-WebRequest -Uri ('https://github.com/SagerNet/sing-box/releases/download/v1.14.4/'+$name) -OutFile $part -TimeoutSec 180
            if((Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -ne $expected){throw 'Routing engine checksum mismatch; rejected.'}
            Move-Item -LiteralPath $part -Destination $archive -Force
        }finally{if(Test-Path -LiteralPath $part){Remove-Item -LiteralPath $part -Force}}
    }
    $temp=Join-Path $cache ([guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -LiteralPath $archive -DestinationPath $temp
        $source=Join-Path $temp 'sing-box-1.14.4-windows-amd64'
        foreach($file in @('sing-box.exe','libcronet.dll','LICENSE')){
            $path=Join-Path $source $file
            if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "Engine archive missing $file"}
            $target=if($file -eq 'LICENSE'){'sing-box-LICENSE'}else{$file}
            Copy-Item -LiteralPath $path -Destination (Join-Path $InstallRoot "bin\$target") -Force
        }
        $manifestPath=Join-Path $InstallRoot 'SHA256SUMS.json'
        $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
        foreach($file in @('sing-box.exe','libcronet.dll','sing-box-LICENSE')){
            $manifest['bin/'+$file]=(Get-FileHash -LiteralPath (Join-Path $InstallRoot "bin\$file") -Algorithm SHA256).Hash
        }
        Write-HybridJson $manifest $manifestPath
    }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
}

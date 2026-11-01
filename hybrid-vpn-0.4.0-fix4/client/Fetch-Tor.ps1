function Install-HybridTor([string]$InstallRoot,[string]$State) {
    $name='tor-expert-bundle-windows-x86_64-15.0.26.tar.gz'
    $expected='c1988c701de2f24f7d098d1d6d7f507b58f27740d097f29c246e0524d639b252'
    $cache=Join-Path $State 'downloads';New-Item -ItemType Directory -Path $cache -Force | Out-Null
    $archive=Join-Path $cache $name
    if(-not (Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected){
        $ok=$false
        foreach($base in @('https://dist.torproject.org/torbrowser/15.0.26/','https://archive.torproject.org/tor-package-archive/torbrowser/15.0.26/')){
            $part=$archive+'.partial'
            try {
                Write-Host 'Downloading the pinned Tor Expert Bundle (about 23 MB), then verifying SHA-256...'
                Invoke-WebRequest -Uri ($base+$name) -OutFile $part -TimeoutSec 180
                if((Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -ne $expected){throw 'Tor download checksum mismatch; rejected.'}
                Move-Item -LiteralPath $part -Destination $archive -Force;$ok=$true;break
            }catch{Write-Warning $_.Exception.Message}finally{if(Test-Path -LiteralPath $part){Remove-Item -LiteralPath $part -Force}}
        }
        if(-not $ok){throw 'No verified Tor bundle could be downloaded. No client tunnel or server setup was started.'}
    }
    $temp=Join-Path $cache ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        $entries=@(& tar.exe -tzf $archive)
        if($LASTEXITCODE -ne 0){throw 'Tor archive listing failed.'}
        foreach($entry in $entries){if($entry -match '(^[/\\]|^[A-Za-z]:|(^|[/\\])\.\.([/\\]|$))'){throw 'Unsafe archive member rejected.'}}
        Invoke-HybridChecked tar.exe @('-xzf',$archive,'-C',$temp)
        foreach($required in @('tor\tor.exe','data\geoip','data\geoip6')){if(-not (Test-Path -LiteralPath (Join-Path $temp $required))){throw "Tor bundle missing $required"}}
        $dest=Join-Path $InstallRoot 'bin\tor';New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -Path "$temp\tor\*" -Destination $dest -Recurse -Force
        New-Item -ItemType Directory -Path "$dest\data" -Force | Out-Null
        Copy-Item -Path "$temp\data\*" -Destination "$dest\data" -Recurse -Force
        # Bind extracted payloads to the installed runtime manifest after authentic archive hash verification.
        $manifestPath=Join-Path $InstallRoot 'SHA256SUMS.json'
        $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
        Get-ChildItem -LiteralPath $dest -Recurse -File | ForEach-Object {
            $relative=[IO.Path]::GetRelativePath($InstallRoot,$_.FullName).Replace('\','/')
            $manifest[$relative]=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
        Write-HybridJson $manifest $manifestPath
    }finally{Remove-Item -LiteralPath $temp -Recurse -Force}
}

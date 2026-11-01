#requires -Version 7.0
function Test-HybridTcp {
    [CmdletBinding()]
    param([ValidateRange(1,3)][int]$Attempts=3,
          [ValidateRange(1,60)][int]$TimeoutSeconds=30,
          [string]$DiagnosticPath)
    # Fixed destination and proxy: no direct fallback, redirects or TLS bypass.
    $history=[Collections.Generic.List[object]]::new()
    $answer=$null
    for($attempt=1;$attempt -le $Attempts;$attempt++) {
        $handler=$null;$client=$null;$request=$null;$response=$null;$stream=$null;$body=$null;$cancel=$null
        $entry=@{Attempt=$attempt;Utc=[DateTime]::UtcNow.ToString('o');Status=$null;Bytes=0;Error=$null}
        try {
            $handler=[Net.Http.HttpClientHandler]::new()
            $handler.UseProxy=$true
            $handler.Proxy=[Net.WebProxy]::new('socks5://127.0.0.1:17880')
            $handler.AllowAutoRedirect=$false
            $client=[Net.Http.HttpClient]::new($handler)
            $cancel=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
            $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,'https://check.torproject.org/api/ip')
            $request.Version=[Version]::new(1,1)
            $request.VersionPolicy=[Net.Http.HttpVersionPolicy]::RequestVersionExact
            [void]$request.Headers.TryAddWithoutValidation('User-Agent','WhisprHybridVerification/0.4.0-fix4')
            $response=$client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancel.Token).GetAwaiter().GetResult()
            $entry.Status=[int]$response.StatusCode
            if($entry.Status -ne 200){throw "Tor check returned HTTP $($entry.Status)."}
            $length=$response.Content.Headers.ContentLength
            $chunked=$response.Headers.TransferEncodingChunked -eq $true
            if($null -eq $length -and -not $chunked){throw 'Tor check has no explicit HTTP body framing.'}
            if($null -ne $length -and ($length -lt 1 -or $length -gt 65536)){throw 'Tor check Content-Length outside 1..65536 bytes.'}
            if($null -ne $length -and $chunked){throw 'Tor check has ambiguous HTTP body framing.'}
            $stream=$response.Content.ReadAsStreamAsync($cancel.Token).GetAwaiter().GetResult()
            $body=[IO.MemoryStream]::new()
            $buffer=[byte[]]::new(4096)
            while($true){
                $count=$stream.ReadAsync($buffer,0,$buffer.Length,$cancel.Token).GetAwaiter().GetResult()
                if($count -eq 0){break}
                if($body.Length+$count -gt 65536){throw 'Tor check exceeds 65536 bytes.'}
                $body.Write($buffer,0,$count);$entry.Bytes=$body.Length
            }
            if($null -ne $length -and $body.Length -ne $length){throw 'Tor check body is truncated.'}
            $json=[Text.UTF8Encoding]::new($false,$true).GetString($body.ToArray()) | ConvertFrom-Json -ErrorAction Stop
            if($json.IsTor -isnot [bool] -or -not $json.IsTor){throw 'TCP verification did not report a Tor exit.'}
            $address=$null
            if(-not [Net.IPAddress]::TryParse([string]$json.IP,[ref]$address)){throw 'Tor check returned an invalid exit IP.'}
            $answer=[pscustomobject]@{IsTor=$true;IP=$address.ToString();VerifiedUtc=[DateTime]::UtcNow.ToString('o')}
        } catch {
            $entry.Error=$_.Exception.ToString()
            Write-Warning "TCP/Tor verification attempt $attempt/$Attempts failed: $($_.Exception.Message)"
        } finally {
            foreach($item in @($stream,$body,$response,$request,$client,$handler,$cancel)){if($item){$item.Dispose()}}
            $history.Add($entry)
        }
        if($answer){break}
        if($attempt -lt $Attempts){Start-Sleep -Seconds 2}
    }
    if($DiagnosticPath){
        try { Write-HybridJson @{Endpoint='https://check.torproject.org/api/ip';Verified=($null -ne $answer);Attempts=$history.ToArray()} $DiagnosticPath }
        catch { Write-Warning "Could not save TCP verification diagnostics: $($_.Exception.Message)" }
    }
    if(-not $answer){throw "TCP/Tor HTTPS verification failed after $Attempts attempt(s). $($history[-1].Error)"}
    return $answer
}

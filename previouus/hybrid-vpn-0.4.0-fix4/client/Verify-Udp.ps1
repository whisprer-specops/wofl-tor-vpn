function Read-HybridExact($Stream,[int]$Count) {
    $buffer=[byte[]]::new($Count);$offset=0
    while($offset -lt $Count) {
        $n=$Stream.Read($buffer,$offset,$Count-$offset)
        if($n -eq 0){throw 'SOCKS control connection closed.'}
        $offset+=$n
    }
    return ,$buffer
}
function Test-HybridUdp {
    param([string]$ExpectedAddress)
    $tcp=[Net.Sockets.TcpClient]::new();$udp=$null
    try {
        $connect=$tcp.ConnectAsync('127.0.0.1',17880)
        if(-not $connect.Wait(5000)){throw 'Local SOCKS connection timed out.'}
        [void]$connect.GetAwaiter().GetResult()
        $s=$tcp.GetStream();$s.ReadTimeout=5000;$s.WriteTimeout=5000
        $hello=[byte[]]@(5,1,0);$s.Write($hello,0,$hello.Length)
        $r=Read-HybridExact $s 2
        if($r[0] -ne 5 -or $r[1] -ne 0){throw 'SOCKS authentication negotiation failed.'}
        $request=[byte[]]@(5,3,0,1,0,0,0,0,0,0);$s.Write($request,0,$request.Length)
        $r=Read-HybridExact $s 4
        if($r[0] -ne 5 -or $r[1] -ne 0 -or $r[3] -ne 1){throw 'SOCKS UDP association failed or returned an unsupported address family.'}
        $relay=Read-HybridExact $s 6
        $relayIp=[Net.IPAddress]::new([byte[]]$relay[0..3])
        if($relayIp.Equals([Net.IPAddress]::Any)){$relayIp=[Net.IPAddress]::Loopback}
        if(-not [Net.IPAddress]::IsLoopback($relayIp)){throw 'Refusing a non-loopback SOCKS relay.'}
        $port=([int]$relay[4]*256)+[int]$relay[5]
        $udp=[Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
        $udp.Client.ReceiveTimeout=6000;$udp.Connect($relayIp,$port)
        $transaction=[byte[]]::new(12);[Security.Cryptography.RandomNumberGenerator]::Fill($transaction)
        $stun=[byte[]](@(0,1,0,0,0x21,0x12,0xa4,0x42)+$transaction)
        # SOCKS passes this hostname to the routing engine; DNS uses its protected Tor TCP resolver.
        $domain=[Text.Encoding]::ASCII.GetBytes('stun.cloudflare.com')
        $packet=[byte[]](@(0,0,0,3,$domain.Length)+$domain+@(13,150)+$stun) # UDP 3478
        for($attempt=0;$attempt -lt 3;$attempt++) {
            [void]$udp.Send($packet,$packet.Length)
            try {
                $from=[Net.IPEndPoint]::new([Net.IPAddress]::Any,0)
                $reply=$udp.Receive([ref]$from)
                if($reply.Length -lt 10 -or $reply[2] -ne 0){continue}
                $offset=switch($reply[3]){1{10} 4{22} 3{7+[int]$reply[4]} default{throw 'Invalid SOCKS UDP address type.'}}
                if($reply.Length -lt $offset+20){continue}
                if($reply[$offset] -ne 1 -or $reply[$offset+1] -ne 1){continue}
                if([Convert]::ToHexString([byte[]]$reply[($offset+4)..($offset+7)]) -ne '2112A442'){continue}
                if([Convert]::ToHexString([byte[]]$reply[($offset+8)..($offset+19)]) -ne [Convert]::ToHexString($transaction)){continue}
                $end=$offset+20+([int]$reply[$offset+2]*256)+[int]$reply[$offset+3]
                if($end -gt $reply.Length){continue}
                $pos=$offset+20
                while($pos+4 -le $end) {
                    $kind=([int]$reply[$pos]*256)+[int]$reply[$pos+1]
                    $len=([int]$reply[$pos+2]*256)+[int]$reply[$pos+3]
                    $value=$pos+4
                    if($value+$len -gt $end){throw 'Malformed STUN attribute.'}
                    if($kind -eq 0x20 -and $len -ge 8 -and $reply[$value+1] -eq 1) {
                        $mask=[byte[]]@(0x21,0x12,0xa4,0x42)
                        $ip=[byte[]]::new(4)
                        for($i=0;$i -lt 4;$i++){$ip[$i]=$reply[$value+4+$i] -bxor $mask[$i]}
                        $mapped=[Net.IPAddress]::new($ip).ToString()
                        if($mapped -ne $ExpectedAddress){throw "UDP exit mismatch: expected $ExpectedAddress, observed $mapped"}
                        return @{ObservedAddress=$mapped;VerifiedUtc=[DateTime]::UtcNow.ToString('o');Method='SOCKS UDP association through WireGuard to Cloudflare STUN'}
                    }
                    $pos=$value+$len+(4-($len%4))%4
                }
            }catch [Net.Sockets.SocketException]{if($attempt -eq 2){throw 'UDP/STUN verification timed out. No connected status was granted.'}}
        }
        throw 'No valid STUN binding response; UDP remains unverified.'
    } finally { if($udp){$udp.Dispose()};$tcp.Dispose() }
}

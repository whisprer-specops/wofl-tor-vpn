#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('nyc1','lon1','sgp1','syd1')][string[]]$Servers = @('nyc1','lon1','sgp1','syd1'),
    [ValidateRange(1024,65535)][int]$ProbePort = 51831,
    [ValidateRange(3,12)][int]$Samples = 8,
    [string]$OutputDirectory = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads')
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Run this on the Windows computer that will use the VPN.' }
$ssh = (Get-Command ssh.exe -ErrorAction Stop).Source
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) { throw 'Output directory must already exist.' }
$run = Join-Path $OutputDirectory ('HybridVPN-Preflight-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $run | Out-Null
$limitations = [Collections.Generic.List[string]]::new()
function Save-Read([string]$Name, [scriptblock]$Read) {
    try { ConvertTo-Json -InputObject @(& $Read) -Depth 12 | Set-Content -LiteralPath (Join-Path $run "$Name.json") -Encoding utf8 }
    catch { $limitations.Add("${Name}: $($_.Exception.Message)") }
}
function Start-Ssh([string]$Alias, [string]$RemoteCommand) {
    $si = [Diagnostics.ProcessStartInfo]::new()
    $si.FileName = $ssh
    $si.UseShellExecute = $false
    $si.CreateNoWindow = $true
    $si.RedirectStandardInput = $true
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError = $true
    foreach ($arg in @('-T','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=8','-o','ConnectionAttempts=1','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2',$Alias,$RemoteCommand)) {
        $si.ArgumentList.Add($arg)
    }
    $p = [Diagnostics.Process]::new()
    $p.StartInfo = $si
    if (-not $p.Start()) { throw "Could not start SSH for $Alias" }
    $p.StandardInput.Close()
    return $p
}
Write-Host 'Hybrid VPN 0.4.0: preparation only. This does not install or activate a VPN.' -ForegroundColor Cyan
Write-Host 'No elevation or sudo password is requested. Existing SSH authentication is used.'
Write-Host 'Each server briefly listens on UDP 51831 by default, with a random token, then exits.'
Write-Host 'Blocked probes are recorded; the script does not open firewall ports.'
Save-Read 'windows' {
    Get-CimInstance Win32_OperatingSystem | Select-Object -Property @('Caption','Version','BuildNumber','OSArchitecture')
}
Save-Read 'adapters' {
    Get-NetAdapter -IncludeHidden | Select-Object -Property @('Name','InterfaceDescription','ifIndex','InterfaceGuid','Status','LinkSpeed','Virtual','HardwareInterface')
}
Save-Read 'interfaces' {
    Get-NetIPInterface | Select-Object -Property @('InterfaceAlias','InterfaceIndex','AddressFamily','ConnectionState','Dhcp','AutomaticMetric','InterfaceMetric')
}
Save-Read 'addresses' {
    Get-NetIPAddress | Select-Object -Property @('InterfaceAlias','InterfaceIndex','AddressFamily','IPAddress','PrefixLength','AddressState')
}
Save-Read 'routes' {
    Get-NetRoute -PolicyStore ActiveStore | Select-Object -Property @('InterfaceAlias','InterfaceIndex','AddressFamily','DestinationPrefix','NextHop','RouteMetric','Protocol')
}
Save-Read 'dns' {
    Get-DnsClientServerAddress | Select-Object -Property @('InterfaceAlias','InterfaceIndex','AddressFamily','ServerAddresses')
}
Save-Read 'nrpt' {
    Get-DnsClientNrptPolicy -Effective | Select-Object -Property @('Namespace','NameServers','DirectAccessEnabled','DnsSecValidationRequired')
}
Save-Read 'firewall-profiles' {
    Get-NetFirewallProfile -PolicyStore ActiveStore | Select-Object -Property @('Name','Enabled','DefaultInboundAction','DefaultOutboundAction','AllowLocalFirewallRules')
}
Save-Read 'old-vpn-services' {
    Get-CimInstance Win32_Service | Where-Object { ($_.Name + ' ' + $_.DisplayName) -match '(?i)torvpn|wireguard|sing.box' } |
        Select-Object -Property @('Name','DisplayName','State','StartMode')
}
Save-Read 'old-vpn-processes' {
    Get-Process | Where-Object { $_.ProcessName -match '(?i)torvpn|tun2socks|wireguard|sing.box|^tor$|chronomanc' } |
        Select-Object -Property @('ProcessName','Id','Path','CPU','WorkingSet64')
}
$remoteTemplate = @'
import json, os, platform, secrets, socket, subprocess, time
TOKEN = __TOKEN__
PORT = __PORT__
def read(args):
    try:
        p = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=3)
        return {"exit":p.returncode, "stdout":p.stdout[:100000], "stderr":p.stderr[:2000]}
    except Exception as e:
        return {"unavailable":str(e)}
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.bind(("0.0.0.0", PORT))
    s.settimeout(0.4)
except OSError as e:
    print(json.dumps({"error":"UDP probe bind failed", "detail":str(e)}), flush=True)
    raise SystemExit(2)
print(json.dumps({"ready":True,"host":platform.node(),"ssh_connection":os.environ.get("SSH_CONNECTION", ""),"port":PORT}), flush=True)
end = time.monotonic() + 20
received = 0
while time.monotonic() < end:
    try:
        packet, peer = s.recvfrom(128)
    except socket.timeout:
        continue
    if not packet.startswith(TOKEN.encode() + b":") or len(packet) > 100:
        continue
    s.sendto(packet, peer)
    received += 1
    if packet == (TOKEN + ":STOP").encode():
        break
s.close()
commands = {
 "os": ["cat", "/etc/os-release"],
 "addresses": ["ip", "-j", "address", "show"],
 "routes4": ["ip", "-j", "-4", "route", "show", "table", "all"],
 "routes6": ["ip", "-j", "-6", "route", "show", "table", "all"],
 "udp_listeners": ["ss", "-H", "-lun"],
 "forward4": ["sysctl", "-n", "net.ipv4.ip_forward"],
 "forward6": ["sysctl", "-n", "net.ipv6.conf.all.forwarding"],
 "wireguard_version": ["wg", "--version"],
 "wireguard_interfaces": ["sudo", "-n", "wg", "show", "interfaces"],
 "nft_rules": ["sudo", "-n", "nft", "list", "ruleset"],
 "iptables_rules": ["sudo", "-n", "iptables-save"],
 "ip6tables_rules": ["sudo", "-n", "ip6tables-save"],
 "ufw": ["sudo", "-n", "ufw", "status", "verbose"],
}
print(json.dumps({"inventory":{k:read(v) for k,v in commands.items()},"probe_packets":received}), flush=True)
'@
$results = [Collections.Generic.List[object]]::new()
foreach ($alias in $Servers) {
    Write-Host "`n$alias — SSH inventory and UDP probe..." -ForegroundColor Cyan
    $p = $null; $udp = $null; $stderr = $null
    try {
        $token = [guid]::NewGuid().ToString('N')
        $script = $remoteTemplate.Replace('__TOKEN__', ('"' + $token + '"')).Replace('__PORT__', [string]$ProbePort)
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
        $command = "python3 -u -c 'import base64;exec(base64.b64decode(""$b64""))'"
        $p = Start-Ssh $alias $command
        $stderr = $p.StandardError.ReadToEndAsync()
        $first = $p.StandardOutput.ReadLineAsync()
        if (-not $first.Wait(12000)) { throw 'SSH/Python readiness timed out after 12 seconds.' }
        $line = $first.GetAwaiter().GetResult()
        if (-not $line) { throw 'SSH returned no readiness message. Check the saved SSH error.' }
        $ready = $line | ConvertFrom-Json
        if (-not $ready.ready) { throw $line }
        # SSH_CONNECTION is supplied by sshd, not guessed from the alias.
        $parts = $ready.ssh_connection -split '\s+'
        if ($parts.Count -ne 4) { throw 'No usable SSH_CONNECTION from the server.' }
        $ip = [Net.IPAddress]::Parse($parts[2])
        if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'This IPv4 UDP probe requires an IPv4 SSH server address.' }
        $udp = [Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
        $udp.Client.ReceiveTimeout = 800
        $udp.Connect($ip, $ProbePort)
        $rtts = [Collections.Generic.List[double]]::new()
        $timeouts = 0
        for ($i=0; $i -lt $Samples; $i++) {
            $payload = [Text.Encoding]::ASCII.GetBytes("${token}:$i")
            $watch = [Diagnostics.Stopwatch]::StartNew()
            [void]$udp.Send($payload, $payload.Length)
            try {
                $peer = [Net.IPEndPoint]::new([Net.IPAddress]::Any,0)
                $reply = $udp.Receive([ref]$peer)
                if ([Convert]::ToBase64String($reply) -eq [Convert]::ToBase64String($payload)) { $rtts.Add($watch.Elapsed.TotalMilliseconds) }
                else { $timeouts++ }
            } catch [Net.Sockets.SocketException] { $timeouts++ }
            Start-Sleep -Milliseconds 80
        }
        $stop = [Text.Encoding]::ASCII.GetBytes("${token}:STOP")
        [void]$udp.Send($stop,$stop.Length)
        $tailTask = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit(65000)) { throw 'Remote inventory exceeded its bounded collection time.' }
        $tail = $tailTask.GetAwaiter().GetResult()
        ($line + "`n" + $tail) | Set-Content -LiteralPath (Join-Path $run "$alias-server.jsonl") -Encoding utf8
        if ($p.ExitCode -ne 0) { throw "SSH/remote helper exited $($p.ExitCode)." }
        $median = $null
        if ($rtts.Count) {
            $sorted = @($rtts | Sort-Object)
            $mid = [int][Math]::Floor($sorted.Count / 2)
            $median = if ($sorted.Count % 2) { $sorted[$mid] } else { ($sorted[$mid-1]+$sorted[$mid])/2 }
        }
        $row = [pscustomobject]@{Server=$alias; Address=$ip.ToString(); Sent=$Samples; Received=$rtts.Count; LossPercent=[Math]::Round(100*$timeouts/$Samples,1); MedianMs=$median; RttMs=@($rtts.ToArray()); Status=if($rtts.Count){'UDP echo observed; WireGuard handshake not tested'}else{'No UDP echo; firewall/path unknown'}}
        $results.Add($row)
        Write-Host "$alias : received $($row.Received)/$Samples; loss $($row.LossPercent)%; median $median ms"
    } catch {
        $limitations.Add("${alias}: $($_.Exception.Message)")
        $results.Add([pscustomobject]@{Server=$alias;Status='Unresolved';Error=$_.Exception.Message})
        Write-Warning "${alias}: $($_.Exception.Message)"
    } finally {
        if ($udp) { $udp.Dispose() }
        if ($p) {
            if (-not $p.HasExited) { try { $p.Kill($true); $p.WaitForExit(3000) | Out-Null } catch {} }
            if ($stderr) { try { $stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $run "$alias-ssh-stderr.txt") -Encoding utf8 } catch {} }
            $p.Dispose()
        }
    }
}
ConvertTo-Json -InputObject @($results.ToArray()) -Depth 8 | Set-Content -LiteralPath (Join-Path $run 'endpoint-measurements.json') -Encoding utf8
ConvertTo-Json -InputObject @($limitations.ToArray()) | Set-Content -LiteralPath (Join-Path $run 'limitations.json') -Encoding utf8
@'
Preparation evidence only. No VPN installed or activated. No integrity scans.
Remote helper briefly binds an unprivileged UDP port and sends same-size token echoes.
No firewall, route, driver, service, sysctl, startup, DNS or SSH configuration changed.
Missing sudo-n access is expected on password-protected servers: do not change sudo policy.
UDP echo is not a WireGuard handshake, sustained throughput test, or anonymity test.
Loss/RTT are small-sample measurements from the CURRENT Windows routing state.
An active VPN, ProxyJump, NAT or firewall can affect these results.
No response does not mean the endpoint is slow or unavailable over a properly opened WG port.
Endpoint geography does not establish stealth or unlinkability. All four VPSs share a provider.
The report contains local/public IPs, usernames in SSH errors, paths and server firewall rules.
Private WireGuard keys, Tor credentials and profile contents are not requested.
The listener exits automatically; if SSH terminates early allow 20 seconds for its deadline.
The replacement needs separate crash/leak testing before production use.
'@ | Set-Content -LiteralPath (Join-Path $run 'READ-ME.txt') -Encoding utf8
$zip = $run + '.zip'
Compress-Archive -LiteralPath $run -DestinationPath $zip
Write-Host "`nSaved: $zip" -ForegroundColor Green
Write-Host 'Send this ZIP back. A completed preflight does not mean the VPN is installed or verified.'

#requires -Version 7.0
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../client/Common.ps1"
$peer=@{endpoint='137.184.105.114';port=51832;client_ipv4='10.88.70.2/32';ipv6=$false;server_public_key='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='}
$cfg=Get-HybridConfig -Peer $peer -PrivateKey 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' -TorPath 'C:\owned\tor.exe'
if($cfg.endpoints.Count -ne 1 -or $cfg.endpoints[0].detour -ne 'wg-transport'){throw 'WireGuard must use the dedicated connected transport.'}
$transport=@($cfg.outbounds | Where-Object tag -eq 'wg-transport')
if($transport.Count -ne 1 -or $transport[0].type -ne 'direct' -or $transport[0].inet4_bind_address -ne '0.0.0.0'){throw 'Explicit IPv4 transport missing.'}
if($cfg.endpoints[0].peers.Count -ne 1 -or $cfg.endpoints[0].peers[0].address -ne $peer.endpoint){throw 'Expected one literal IPv4 WireGuard peer.'}
if(-not $cfg.route.auto_detect_interface){throw 'Interface detection must remain enabled for existing transports.'}
$tun=@($cfg.inbounds | Where-Object type -eq 'tun')[0]
if($tun.route_exclude_address -notcontains ($peer.endpoint+'/32')){throw 'WireGuard endpoint must remain outside TUN routes.'}
if(@($cfg.route.rules | Where-Object {$_.ContainsKey('outbound') -and $_.outbound -eq 'wg-transport'}).Count){throw 'Application traffic must never route to the raw WireGuard transport.'}
$udp=@($cfg.route.rules | Where-Object {$_.ContainsKey('network') -and $_.network -eq 'udp' -and $_.ContainsKey('outbound')})
if($udp.Count -ne 1 -or $udp[0].outbound -ne 'udp-exit'){throw 'Application UDP must still route to WireGuard.'}
if($cfg.route.rules[-1].action -ne 'reject'){throw 'Unmatched traffic must be rejected.'}
Write-Host 'WireGuard transport, route exclusion and application UDP routing contracts passed.'

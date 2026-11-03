"""Unmodified render contract from the shipped fix5 setup.py; test fixture only. MIT, whispr.dev."""
from pathlib import Path
ROOT=Path("/etc/whispr-hybrid")

def render(state, private):
    addresses='10.88.70.1/24'+(', fd89:77:70::1/64' if state['ipv6'] else '')
    out=['# Managed only by whispr Hybrid VPN 0.4.0','[Interface]',f'Address = {addresses}',
         f'ListenPort = {state["port"]}',f'PrivateKey = {private}',
         f'PostUp = /usr/bin/python3 -I {ROOT}/firewall.py apply',
         f'PostDown = /usr/bin/python3 -I {ROOT}/firewall.py remove','']
    for pub,record in sorted(state['clients'].items()):
        allowed=record['ipv4']+'/32'
        if state['ipv6']:allowed+=', '+record['ipv6']+'/128'
        out+=['[Peer]',f'PublicKey = {pub}',f'AllowedIPs = {allowed}','']
    return '\n'.join(out)+'\n'

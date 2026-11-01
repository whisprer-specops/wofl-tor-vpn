#!/usr/bin/env python3
"""Dedicated WireGuard UDP exit. Existing services/interfaces are not reconfigured."""
import argparse
import base64
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import socket
import subprocess
import tempfile
import time

ROOT=Path('/etc/whispr-hybrid')
CONFIG=Path('/etc/wireguard/wg-whispr.conf')
SYSCTL=Path('/etc/sysctl.d/80-whispr-hybrid.conf')
IFACE='wg-whispr'

def command(args, *, data=None, check=True):
    result=subprocess.run(args,input=data,capture_output=True,text=True,check=False,timeout=180)
    if check and result.returncode:
        raise RuntimeError(args[0]+' failed ('+str(result.returncode)+'): '+result.stderr[-2500:])
    return result

def atomic(path, text, mode=0o600):
    path=Path(path)
    fd,temp=tempfile.mkstemp(prefix='.'+path.name+'-',dir=path.parent)
    try:
        os.fchmod(fd,mode)
        with os.fdopen(fd,'w') as f:
            f.write(text);f.flush();os.fsync(f.fileno())
        os.replace(temp,path)
    finally:
        if os.path.exists(temp):os.unlink(temp)

def uplink(v6=False):
    args=['ip','-j','-6' if v6 else '-4','route','get','2606:4700:4700::1111' if v6 else '1.1.1.1']
    p=command(args,check=False)
    if p.returncode:return None
    routes=json.loads(p.stdout)
    if not routes:return None
    name=routes[0].get('dev','')
    if not re.fullmatch(r'[A-Za-z0-9_.:-]{1,15}',name) or name.startswith(('wg','tun','docker','veth','br-')):
        raise RuntimeError('No unambiguous public uplink: '+name)
    return name

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

def setup(args):
    if os.geteuid()!=0:raise RuntimeError('Run this command through sudo.')
    decoded=base64.b64decode(args.public_key,validate=True)
    if len(decoded)!=32 or base64.b64encode(decoded).decode()!=args.public_key:
        raise RuntimeError('Invalid client public key')
    source=Path(__file__).resolve().with_name('firewall.py')
    if not source.is_file() or not source.with_name('manage.py').is_file():raise RuntimeError('Missing server scripts from complete release')
    if not shutil.which('wg') or not shutil.which('iptables'):
        print('Installing Ubuntu/Debian wireguard-tools and iptables (sudo already active).',flush=True)
        command(['apt-get','update'])
        command(['apt-get','install','-y','--no-install-recommends','wireguard-tools','iptables'])
    first=not (ROOT/'state.json').exists()
    if first:
        if ROOT.exists() and any(ROOT.iterdir()):raise RuntimeError('Unowned /etc/whispr-hybrid already exists')
        if CONFIG.exists() or SYSCTL.exists():raise RuntimeError('Existing interface/sysctl file needs review; refusing overwrite')
        if command(['ip','link','show',IFACE],check=False).returncode==0:raise RuntimeError('Interface name already exists')
        for binary in ('iptables','ip6tables'):
            if shutil.which(binary):
                for table,chain in [('filter','WHISPR_H_IN'),('filter','WHISPR_H_PORT'),('filter','WHISPR_H_FWD'),('nat','WHISPR_H_NAT')]:
                    if command([binary,'-w','5','-t',table,'-S',chain],check=False).returncode==0:
                        raise RuntimeError('Unowned firewall chain collision: '+chain)
        # Binding tests avoid stealing an existing service's port; the configuration is rechecked on activation.
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as probe:probe.bind(('0.0.0.0',args.port))
        # Refuse overlap with a pre-existing host network before reserving our subnets.
        for interface in json.loads(command(['ip','-j','address','show']).stdout):
            for address in interface.get('addr_info',[]):
                net=ipaddress.ip_network(address['local']+'/'+str(address['prefixlen']),strict=False)
                planned=ipaddress.ip_network('10.88.70.0/24' if net.version==4 else 'fd89:77:70::/64')
                if net.overlaps(planned):raise RuntimeError('Dedicated WG subnet conflicts with '+interface.get('ifname','existing interface'))
        for family in ('-4','-6'):
            for route in json.loads(command(['ip','-j',family,'route','show','table','all']).stdout):
                destination=route.get('dst','default')
                if destination=='default':continue
                try:net=ipaddress.ip_network(destination,strict=False)
                except ValueError:continue
                planned=ipaddress.ip_network('10.88.70.0/24' if net.version==4 else 'fd89:77:70::/64')
                if net.overlaps(planned):raise RuntimeError('Dedicated WG subnet overlaps an existing route: '+destination)
        ip4=uplink()
        if not ip4:raise RuntimeError('No IPv4 uplink')
        ip6=uplink(True)
        v6=bool(ip6 and shutil.which('ip6tables'))
        ROOT.mkdir(mode=0o700,parents=True,exist_ok=True)
        os.chmod(ROOT,0o700)
        private=command(['wg','genkey']).stdout.strip()
        public=command(['wg','pubkey'],data=private+'\n').stdout.strip()
        atomic(ROOT/'server.key',private+'\n')
        state={'schema':1,'version':'0.4.0','port':args.port,'uplink4':ip4,'uplink6':ip6,'ipv6':v6,
               'public_key':public,'clients':{},'created':time.time(),
               'prior_forward4':Path('/proc/sys/net/ipv4/ip_forward').read_text().strip(),
               'prior_forward6':Path('/proc/sys/net/ipv6/conf/all/forwarding').read_text().strip()}
        atomic(ROOT/'state.json',json.dumps(state,indent=2))
    else:
        state=json.loads((ROOT/'state.json').read_text())
        if state.get('schema')!=1 or state['port']!=args.port:raise RuntimeError('Existing server uses another schema/port')
        private=(ROOT/'server.key').read_text().strip()
        if CONFIG.exists() and state.get('config_sha256') and hashlib.sha256(CONFIG.read_bytes()).hexdigest()!=state['config_sha256']:
            raise RuntimeError('Managed WireGuard config was edited outside this installer; refusing overwrite')
    if args.public_key not in state['clients']:
        used={r['slot'] for r in state['clients'].values()}
        slot=next((i for i in range(2,254) if i not in used),None)
        if slot is None:raise RuntimeError('Peer address pool exhausted')
        state['clients'][args.public_key]={'slot':slot,'ipv4':f'10.88.70.{slot}','ipv6':f'fd89:77:70::{slot:x}'}
    record=state['clients'][args.public_key]
    config=render(state,private)
    state['config_sha256']=hashlib.sha256(config.encode()).hexdigest()
    # Keep recoverable configuration files before touching live network state.
    if CONFIG.exists():
        atomic(ROOT/'previous-wg.conf',CONFIG.read_text())
        atomic(ROOT/'previous-state.json',(ROOT/'state.json').read_text())
    atomic(ROOT/'state.json',json.dumps(state,indent=2))
    atomic(ROOT/'firewall.py',source.read_text(),0o700)
    atomic(ROOT/'setup.py',Path(__file__).read_text(),0o700)
    atomic(ROOT/'manage.py',source.with_name('manage.py').read_text(),0o700)
    CONFIG.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    atomic(CONFIG,config)
    settings='# whispr Hybrid VPN: forwarding required; unrelated firewall policy is retained\nnet.ipv4.ip_forward = 1\n'
    if state['ipv6']:settings+='net.ipv6.conf.all.forwarding = 1\n'
    atomic(SYSCTL,settings,0o644)
    command(['sysctl','-p',str(SYSCTL)])
    live=command(['ip','link','show',IFACE],check=False).returncode==0
    if not live:
        command(['systemctl','start','wg-quick@'+IFACE])
    else:
        allowed=record['ipv4']+'/32'+(','+record['ipv6']+'/128' if state['ipv6'] else '')
        command(['wg','set',IFACE,'peer',args.public_key,'allowed-ips',allowed])
        command(['/usr/bin/python3','-I',str(ROOT/'firewall.py'),'apply'])
    command(['systemctl','enable','wg-quick@'+IFACE])
    current=command(['wg','show',IFACE,'public-key']).stdout.strip()
    if current!=state['public_key']:raise RuntimeError('Live server public key differs from owned state')
    report={'schema':1,'version':'0.4.0','server_public_key':current,'port':state['port'],
            'client_ipv4':record['ipv4']+'/32','client_ipv6':record['ipv6']+'/128' if state['ipv6'] else None,
            'ipv6':state['ipv6'],'interface':IFACE,'client_public_key':args.public_key}
    reportpath=Path(args.report)
    # Only write back into the invoking user's staging directory, never a caller-selected privileged target.
    user=os.environ.get('SUDO_USER')
    if not user:raise RuntimeError('SUDO_USER is required for non-secret report delivery')
    owner=pwd.getpwnam(user)
    parent=reportpath.parent
    if not parent.is_dir() or parent.is_symlink() or parent.stat().st_uid!=owner.pw_uid:
        raise RuntimeError('Report staging directory ownership check failed')
    if not str(parent).startswith('/tmp/whispr-hybrid-'):raise RuntimeError('Unexpected report staging path')
    if reportpath.exists() or reportpath.is_symlink():raise RuntimeError('Report destination must be new')
    fd=os.open(reportpath,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as f:json.dump(report,f,indent=2)
    os.chown(reportpath,owner.pw_uid,owner.pw_gid)
    print('WireGuard UDP exit configured; existing services retained. Client verification is still required.',flush=True)
    print('If DigitalOcean Cloud Firewall is enabled, permit inbound UDP '+str(state['port'])+' for this VPS.',flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--public-key',required=True)
    parser.add_argument('--port',type=int,default=51832,choices=range(1024,65536),metavar='PORT')
    parser.add_argument('--report',required=True)
    args=parser.parse_args()
    lock=os.open('/run/lock/whispr-hybrid.lock',os.O_CREAT|os.O_RDWR,0o600)
    try:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        setup(args)
    except Exception as exc:
        print('STOP: '+str(exc),file=__import__('sys').stderr)
        print('No global firewall reset was performed. Owned state is retained in /etc/whispr-hybrid for inspection.',file=__import__('sys').stderr)
        raise SystemExit(1)
    finally:
        os.close(lock)

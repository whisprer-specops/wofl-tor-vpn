#!/usr/bin/env python3
"""Explicit maintenance for this app's server interface and peer registry only."""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
ROOT=Path('/etc/whispr-hybrid')
CONFIG=Path('/etc/wireguard/wg-whispr.conf')
SYSCTL=Path('/etc/sysctl.d/80-whispr-hybrid.conf')

def main():
    parser=argparse.ArgumentParser()
    group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--revoke-public-key')
    group.add_argument('--remove-server',action='store_true')
    parser.add_argument('--all-clients',action='store_true')
    args=parser.parse_args()
    if os.geteuid()!=0:raise RuntimeError('Requires sudo')
    with open('/run/lock/whispr-hybrid.lock','a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        state=json.loads((ROOT/'state.json').read_text())
        if CONFIG.exists() and hashlib.sha256(CONFIG.read_bytes()).hexdigest()!=state['config_sha256']:
            raise RuntimeError('Managed configuration changed outside this app; refusing destructive maintenance')
        spec=importlib.util.spec_from_file_location('hybrid_setup',ROOT/'setup.py')
        setup=importlib.util.module_from_spec(spec);spec.loader.exec_module(setup)
        if args.revoke_public_key:
            if args.revoke_public_key not in state['clients']:raise RuntimeError('This key is not registered by this app')
            subprocess.run(['wg','set','wg-whispr','peer',args.revoke_public_key,'remove'],check=True)
            del state['clients'][args.revoke_public_key]
            text=setup.render(state,(ROOT/'server.key').read_text().strip())
            state['config_sha256']=hashlib.sha256(text.encode()).hexdigest()
            setup.atomic(CONFIG,text);setup.atomic(ROOT/'state.json',json.dumps(state,indent=2))
            print('Registered peer revoked; other peers retained.')
        else:
            if len(state['clients'])>1 and not args.all_clients:
                raise RuntimeError('Multiple devices registered. Use --all-clients only if all should be disconnected.')
            backup=Path('/var/backups')/('whispr-hybrid-'+str(time.time_ns()))
            shutil.copytree(ROOT,backup);os.chmod(backup,0o700)
            subprocess.run(['systemctl','stop','wg-quick@wg-whispr'],check=True)
            subprocess.run(['systemctl','disable','wg-quick@wg-whispr'],check=True)
            subprocess.run(['/usr/bin/python3','-I',str(ROOT/'firewall.py'),'remove'],check=True)
            if CONFIG.exists():CONFIG.unlink()
            if SYSCTL.exists():
                if not SYSCTL.read_text().startswith('# whispr Hybrid VPN:'):raise RuntimeError('Sysctl ownership changed; preserved')
                SYSCTL.unlink()
            print('App-owned WireGuard interface/config/firewall hooks removed.')
            print('Forwarding is left enabled to avoid disrupting other projects. Root-only state/keys retained at '+str(ROOT))
            print('Backup: '+str(backup))

if __name__=='__main__':
    try:main()
    except Exception as exc:
        print('STOP: '+str(exc),file=__import__('sys').stderr);raise SystemExit(1)

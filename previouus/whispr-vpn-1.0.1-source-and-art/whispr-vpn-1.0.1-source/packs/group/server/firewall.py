#!/usr/bin/env python3
"""Manage only whispr's interface-scoped iptables chains. Never flush global policy."""
import json
import shlex
import subprocess
import sys
from pathlib import Path

ROOT = Path('/etc/whispr-hybrid')
IFACE = 'wg-whispr'

def run(binary, args, check=True):
    return subprocess.run([binary, '-w', '5', *args], check=check, capture_output=True, text=True)

def chains_in_table(binary, table):
    # Enumerating the table succeeds even when none of our chains exist.
    # nft-backed iptables may return code 2 when -C references a missing jump
    # target; avoid that query instead of treating all code-2 errors as absence.
    result = run(binary, ['-t', table, '-S'], False)
    if result.returncode:
        raise RuntimeError('Cannot inspect '+table+' table: '+result.stderr)
    chains = set()
    for line in result.stdout.splitlines():
        parts = shlex.split(line)
        if len(parts) >= 2 and parts[0] in ('-P', '-N'):
            chains.add(parts[1])
    return chains

def present(binary, table, chain, rule):
    result=run(binary, ['-t', table, '-C', chain, *rule], False)
    if result.returncode not in (0,1):raise RuntimeError(result.stderr)
    return result.returncode==0

def insert(binary, table, chain, rule):
    if not present(binary, table, chain, rule):
        run(binary, ['-t', table, '-I', chain, '1', *rule])

def family(binary, cfg, v6, remove):
    network = 'fd89:77:70::/64' if v6 else '10.88.70.0/24'
    uplink = cfg['uplink6' if v6 else 'uplink4']
    jumps = [
        ('filter', 'INPUT', ['-i', IFACE, '-j', 'WHISPR_H_IN']),
        ('filter', 'INPUT', ['-i', uplink, '-p', 'udp', '--dport', str(cfg['port']), '-j', 'WHISPR_H_PORT']),
        ('filter', 'FORWARD', ['-i', IFACE, '-j', 'WHISPR_H_FWD']),
        ('filter', 'FORWARD', ['-o', IFACE, '-j', 'WHISPR_H_FWD']),
        ('nat', 'POSTROUTING', ['-s', network, '-o', uplink, '-p', 'udp', '-j', 'WHISPR_H_NAT']),
    ]
    chains = [('filter','WHISPR_H_IN'),('filter','WHISPR_H_PORT'),('filter','WHISPR_H_FWD'),('nat','WHISPR_H_NAT')]
    if remove:
        existing = {table: chains_in_table(binary, table) for table in ('filter', 'nat')}
        for table, parent, rule in jumps:
            if rule[-1] not in existing[table]:
                continue
            while present(binary, table, parent, rule):
                run(binary, ['-t',table,'-D',parent,*rule])
        for table, chain in chains:
            if chain in existing[table]:
                run(binary,['-t',table,'-F',chain])
                run(binary,['-t',table,'-X',chain])
        return
    # Remove previous OWN chains before rebuilding; unknown collisions are rejected by setup.py.
    family(binary,cfg,v6,True)
    for table,chain in chains:
        run(binary,['-t',table,'-N',chain])
    # VPN clients cannot access services on the VPS itself.
    run(binary,['-A','WHISPR_H_IN','-j','DROP'])
    run(binary,['-A','WHISPR_H_PORT','-j','ACCEPT'])
    excluded = ['::/128','::1/128','fc00::/7','fe80::/10','ff00::/8'] if v6 else [
        '0.0.0.0/8','10.0.0.0/8','100.64.0.0/10','127.0.0.0/8','169.254.0.0/16',
        '172.16.0.0/12','192.168.0.0/16','224.0.0.0/4','240.0.0.0/4']
    for dest in excluded:
        run(binary,['-A','WHISPR_H_FWD','-i',IFACE,'-d',dest,'-j','DROP'])
    run(binary,['-A','WHISPR_H_FWD','-i',IFACE,'-s',network,'-o',uplink,'-p','udp','-j','ACCEPT'])
    run(binary,['-A','WHISPR_H_FWD','-o',IFACE,'-d',network,'-m','conntrack','--ctstate','ESTABLISHED,RELATED','-j','ACCEPT'])
    run(binary,['-A','WHISPR_H_FWD','-j','DROP'])
    run(binary,['-t','nat','-A','WHISPR_H_NAT','-j','MASQUERADE'])
    # Expose only the interface-scoped rules, after all chain contents are complete.
    for table,parent,rule in jumps:
        insert(binary,table,parent,rule)

def main():
    if len(sys.argv)!=2 or sys.argv[1] not in ('apply','remove'):
        raise SystemExit('Use apply or remove')
    cfg=json.loads((ROOT/'state.json').read_text())
    family('iptables',cfg,False,sys.argv[1]=='remove')
    if cfg['ipv6']:
        family('ip6tables',cfg,True,sys.argv[1]=='remove')

if __name__=='__main__':
    main()

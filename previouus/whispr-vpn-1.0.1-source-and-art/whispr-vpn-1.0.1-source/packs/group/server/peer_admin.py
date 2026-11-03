#!/usr/bin/env python3
"""Add/remove only a friend peer on an already configured whispr WireGuard exit.
No firewall, sysctl, service, package or server key changes. Python 3.10+ stdlib.
"""
from __future__ import annotations
import argparse
import base64
import copy
from datetime import datetime, timezone
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import sys
import tempfile
import uuid

ROOT = Path('/etc/whispr-hybrid')
CONFIG = Path('/etc/wireguard/wg-whispr.conf')
BACKUPS = Path('/var/backups/whispr-friend-peers')
LOCK = Path('/run/lock/whispr-hybrid.lock')
IFACE = 'wg-whispr'

def stamp() -> str:
    return datetime.now(timezone.utc).isoformat()

def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def valid_key(key: str) -> str:
    if not isinstance(key, str) or not re.fullmatch(r'[A-Za-z0-9+/]{43}=', key):
        raise ValueError('Invalid WireGuard public key')
    raw = base64.b64decode(key, validate=True)
    if len(raw) != 32 or base64.b64encode(raw).decode() != key or raw == bytes(32):
        raise ValueError('Invalid canonical WireGuard public key')
    return key

def command(args: list[str]) -> str:
    result = subprocess.run(args, capture_output=True, text=True, timeout=20, check=False)
    if result.returncode:
        # Never include private config contents in diagnostics.
        raise RuntimeError(f'{args[0]} {args[1]} failed ({result.returncode})')
    return result.stdout.strip()

def secure(path: Path, directory: bool = False) -> None:
    s = path.lstat()
    if s.st_uid != 0 or s.st_mode & 0o022 or stat.S_ISLNK(s.st_mode):
        raise RuntimeError(f'Untrusted ownership/permissions: {path}')
    if (directory and not stat.S_ISDIR(s.st_mode)) or (not directory and not stat.S_ISREG(s.st_mode)):
        raise RuntimeError(f'Unexpected file type: {path}')

def sync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def atomic(path: Path, data: bytes) -> None:
    fd, name = tempfile.mkstemp(prefix='.'+path.name+'-', dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        sync_directory(path.parent)
    finally:
        if os.path.exists(name):
            os.unlink(name)

def json_bytes(value: dict) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True)+'\n').encode()

def render(state: dict, private: str) -> bytes:
    addresses = '10.88.70.1/24'+(', fd89:77:70::1/64' if state['ipv6'] else '')
    lines = ['# Managed only by whispr Hybrid VPN 0.4.0', '[Interface]', f'Address = {addresses}',
             f'ListenPort = {state["port"]}', f'PrivateKey = {private}',
             f'PostUp = /usr/bin/python3 -I {ROOT}/firewall.py apply',
             f'PostDown = /usr/bin/python3 -I {ROOT}/firewall.py remove', '']
    for key, record in sorted(state['clients'].items()):
        allowed = record['ipv4']+'/32'
        if state['ipv6']:
            allowed += ', '+record['ipv6']+'/128'
        lines += ['[Peer]', f'PublicKey = {key}', f'AllowedIPs = {allowed}', '']
    return ('\n'.join(lines)+'\n').encode()

def expected_peers(state: dict) -> dict[str, set[str]]:
    if state.get('schema') != 1 or not isinstance(state.get('ipv6'), bool):
        raise RuntimeError('Unrecognized managed server state')
    valid_key(state['public_key'])
    if type(state.get('port')) is not int or not 1024 <= state['port'] <= 65535:
        raise RuntimeError('Invalid recorded listener port')
    used: set[int] = set()
    result = {}
    for key, item in state['clients'].items():
        valid_key(key)
        slot = item['slot']
        if type(slot) is not int or slot not in range(2, 254) or slot in used:
            raise RuntimeError('Invalid or duplicate managed address allocation')
        used.add(slot)
        if item['ipv4'] != f'10.88.70.{slot}' or item['ipv6'] != f'fd89:77:70::{slot:x}':
            raise RuntimeError('Managed peer address differs from its slot')
        result[key] = {item['ipv4']+'/32'} | ({item['ipv6']+'/128'} if state['ipv6'] else set())
    if not isinstance(state.get('friend_peers', {}), dict):
        raise RuntimeError('Invalid friend ownership record')
    for key, info in state.get('friend_peers', {}).items():
        if key not in result or not re.fullmatch(r'[0-9a-f]{32}', info.get('request_id', '')):
            raise RuntimeError('Invalid friend peer ownership record')
    return result

def live_peers() -> dict[str, set[str]]:
    output = command(['wg', 'show', IFACE, 'allowed-ips'])
    result = {}
    for line in output.splitlines():
        fields = line.split()
        if not fields:
            continue
        key = valid_key(fields[0])
        if key in result:
            raise RuntimeError('Duplicate live peer')
        ips = set()
        for field in fields[1:]:
            for item in field.split(','):
                if item and item != '(none)':
                    ips.add(str(ipaddress.ip_network(item, strict=True)))
        result[key] = ips
    return result

def assert_listener(state: dict) -> None:
    if command(['wg', 'show', IFACE, 'public-key']) != state['public_key']:
        raise RuntimeError('Live server public key differs from managed state')
    if command(['wg', 'show', IFACE, 'listen-port']) != str(state['port']):
        raise RuntimeError('Live listener port differs from managed state')

def restore_pending() -> bool:
    pending = ROOT/'friend-peer-pending.json'
    if not pending.exists():
        return False
    secure(pending)
    journal = json.loads(pending.read_bytes())
    name = journal['backup_name']
    if not re.fullmatch(r'[0-9]{8}T[0-9]{12}Z-[0-9a-f]{32}', name):
        raise RuntimeError('Unrecognized pending transaction identity')
    secure(BACKUPS, True)
    backup = BACKUPS/name
    secure(backup, True)
    for name in ('old-state.json', 'old-wg.conf'):
        secure(backup/name)
    old_state_bytes = (backup/'old-state.json').read_bytes()
    old_config = (backup/'old-wg.conf').read_bytes()
    if digest(old_state_bytes) != journal['old_state_sha'] or digest(old_config) != journal['old_config_sha']:
        raise RuntimeError('Pending transaction backup integrity failed')
    for path, before, after in [(ROOT/'state.json', journal['old_state_sha'], journal['new_state_sha']),
                                (CONFIG, journal['old_config_sha'], journal['new_config_sha'])]:
        secure(path)
        if digest(path.read_bytes()) not in (before, after):
            raise RuntimeError('Files changed outside pending transaction; refusing automatic recovery')
    old = json.loads(old_state_bytes)
    old_peers = expected_peers(old)
    assert_listener(old)
    target = valid_key(journal['public_key'])
    now = live_peers()
    if {k:v for k,v in now.items() if k != target} != {k:v for k,v in old_peers.items() if k != target}:
        raise RuntimeError('Other live peers changed; refusing automatic recovery')
    if target in old_peers:
        command(['wg', 'set', IFACE, 'peer', target, 'allowed-ips', ','.join(sorted(old_peers[target]))])
    elif target in now:
        command(['wg', 'set', IFACE, 'peer', target, 'remove'])
    if live_peers() != old_peers:
        raise RuntimeError('Peer rollback could not be verified; protection/configuration requires owner attention')
    atomic(CONFIG, old_config)
    atomic(ROOT/'state.json', old_state_bytes)
    pending.unlink()
    sync_directory(ROOT)
    return True

def load_state() -> tuple[dict, bytes, bytes]:
    secure(ROOT, True)
    secure(CONFIG.parent, True)
    for path in (ROOT/'state.json', ROOT/'server.key', CONFIG):
        secure(path)
    raw = (ROOT/'state.json').read_bytes()
    state = json.loads(raw)
    config = CONFIG.read_bytes()
    if digest(config) != state.get('config_sha256'):
        raise RuntimeError('Managed WireGuard file changed outside the installer; refusing enrolment')
    expected = expected_peers(state)
    assert_listener(state)
    if live_peers() != expected:
        raise RuntimeError('Live peers differ from persistent managed state; no peer was changed')
    # Compare the private key without displaying it or passing it on a command line.
    private = (ROOT/'server.key').read_text().strip()
    valid_key(private)
    match = re.search(rb'^PrivateKey\s*=\s*(\S+)\s*$', config, re.MULTILINE)
    if not match or match.group(1).decode() != private:
        raise RuntimeError('Persistent server private key binding differs')
    return state, raw, config

def transact(old: dict, old_raw: bytes, old_config: bytes, new: dict, key: str, action: str) -> str:
    private = (ROOT/'server.key').read_text().strip()
    new_config = render(new, private)
    new['config_sha256'] = digest(new_config)
    new_raw = json_bytes(new)
    if not BACKUPS.exists():
        BACKUPS.mkdir(mode=0o700)
    secure(BACKUPS, True)
    backup_name = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'-'+uuid.uuid4().hex
    backup = BACKUPS/backup_name
    backup.mkdir(mode=0o700)
    sync_directory(BACKUPS)
    atomic(backup/'old-state.json', old_raw)
    atomic(backup/'old-wg.conf', old_config)
    journal = {'schema':1, 'public_key':key, 'action':action, 'backup_name':backup_name,
               'old_state_sha':digest(old_raw), 'old_config_sha':digest(old_config),
               'new_state_sha':digest(new_raw), 'new_config_sha':digest(new_config), 'created':stamp()}
    atomic(ROOT/'friend-peer-pending.json', json_bytes(journal))
    try:
        atomic(CONFIG, new_config)
        atomic(ROOT/'state.json', new_raw)
        if action == 'revoke':
            command(['wg', 'set', IFACE, 'peer', key, 'remove'])
        else:
            allowed = sorted(expected_peers(new)[key])
            command(['wg', 'set', IFACE, 'peer', key, 'allowed-ips', ','.join(allowed)])
        if live_peers() != expected_peers(new):
            raise RuntimeError('Live peer verification failed')
        (ROOT/'friend-peer-pending.json').unlink()
        sync_directory(ROOT)
    except Exception:
        try:
            restore_pending()
        except Exception as recovery:
            raise RuntimeError('Peer operation failed and automatic rollback requires attention; run Repair-Enrollment.ps1') from recovery
        raise
    return str(backup)

def operate(action: str, key: str | None, request_id: str | None, label: str) -> dict:
    # Recovery is constrained to a journal created by this tool and checks all other peers.
    secure(ROOT, True)
    recovered = restore_pending()
    state, raw, config = load_state()
    if action == 'recover':
        return {'schema':1, 'action':action, 'recovered':recovered, 'status':'verified', 'port':state['port']}
    key = valid_key(key)
    if not re.fullmatch(r'[0-9a-f]{32}', request_id or ''):
        raise ValueError('Invalid request identity')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}', label):
        raise ValueError('Invalid device label')
    friends = state.get('friend_peers', {})
    existing = key in state['clients']
    if existing and (key not in friends or friends[key]['request_id'] != request_id):
        raise RuntimeError('That key is not owned by this friend request; existing peer retained')
    if action == 'check' and not existing:
        raise RuntimeError('Friend is not enrolled on this exit')
    backup = None
    if action == 'revoke':
        if existing:
            new = copy.deepcopy(state)
            del new['clients'][key]
            del new['friend_peers'][key]
            backup = transact(state, raw, config, new, key, 'revoke')
        return {'schema':1, 'action':action, 'request_id':request_id, 'client_public_key':key,
                'status':'revoked' if existing else 'already-absent', 'backup':backup, 'recovered':recovered}
    if action == 'register' and not existing:
        new = copy.deepcopy(state)
        used = {r['slot'] for r in state['clients'].values()}
        slot = next((s for s in range(2,254) if s not in used), None)
        if slot is None:
            raise RuntimeError('No free peer addresses remain')
        new['clients'][key] = {'slot':slot, 'ipv4':f'10.88.70.{slot}', 'ipv6':f'fd89:77:70::{slot:x}'}
        new.setdefault('friend_peers', {})[key] = {'request_id':request_id, 'device_name':label, 'created':stamp()}
        backup = transact(state, raw, config, new, key, 'register')
        state = new
    item = state['clients'][key]
    return {'schema':1, 'action':action, 'request_id':request_id, 'status':'verified', 'backup':backup,
            'server_public_key':state['public_key'], 'port':state['port'], 'client_public_key':key,
            'client_ipv4':item['ipv4']+'/32', 'client_ipv6':item['ipv6']+'/128' if state['ipv6'] else None,
            'ipv6':state['ipv6'], 'interface':IFACE, 'recovered':recovered}

def prepare_report(path: Path) -> tuple[int, int, int]:
    user = os.environ.get('SUDO_USER')
    if not user:
        raise RuntimeError('SUDO_USER is required for public report delivery')
    owner = pwd.getpwnam(user)
    if path.name != 'report.json' or not re.fullmatch(r'/tmp/whispr-enrol-[A-Za-z0-9]+', str(path.parent)):
        raise RuntimeError('Unexpected report staging path')
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        s = os.fstat(fd)
        if s.st_uid != owner.pw_uid or s.st_mode & 0o077:
            raise RuntimeError('Staging directory ownership/permissions differ')
        if os.path.lexists(path):
            raise RuntimeError('Public report path must not exist yet')
        return fd, owner.pw_uid, owner.pw_gid
    except Exception:
        os.close(fd)
        raise

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--action', choices=('register','revoke','check','recover'), required=True)
    parser.add_argument('--public-key')
    parser.add_argument('--request-id')
    parser.add_argument('--label', default='Friend-PC')
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise RuntimeError('Use sudo for peer administration')
    report_fd, uid, gid = prepare_report(args.report)
    lock_fd = None
    try:
        lock_fd = os.open(LOCK, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        s = os.fstat(lock_fd)
        if s.st_uid != 0 or not stat.S_ISREG(s.st_mode) or s.st_mode & 0o022:
            raise RuntimeError('Untrusted server administration lock')
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = operate(args.action, args.public_key, args.request_id, args.label)
        fd = os.open('report.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=report_fd)
        with os.fdopen(fd, 'wb') as output:
            os.fchown(output.fileno(), uid, gid)
            output.write(json_bytes(result))
            output.flush()
            os.fsync(output.fileno())
        print('Verified peer operation; interface, firewall rules, server keys and other peers retained.')
    finally:
        if lock_fd is not None:
            os.close(lock_fd)
        os.close(report_fd)

if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'STOP: {error}', file=sys.stderr)
        raise SystemExit(1)

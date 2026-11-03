#!/usr/bin/env python3
"""Configure an owned exit if new; synchronise only group-managed peers thereafter."""
from __future__ import annotations
import argparse
import base64
import copy
import fcntl
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import pwd
import re
import stat
import sys
from types import SimpleNamespace

HERE=Path(__file__).resolve().parent

def module(name):
    spec=importlib.util.spec_from_file_location('group_'+name,HERE/(name+'.py'))
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result

peer=module('peer_admin')

def kid(key):
    peer.valid_key(key);return hashlib.sha256(base64.b64decode(key)).hexdigest()

def validate(data):
    if set(data)!={'Schema','GroupId','MembershipRevision','Members','OwnerId','Node'} or data['Schema']!=1 or not re.fullmatch('[0-9a-f]{32}',data['GroupId']):raise ValueError('Invalid group input identity')
    if type(data['MembershipRevision']) is not int or data['MembershipRevision']<1:raise ValueError('Invalid membership revision')
    if not isinstance(data['Members'],list) or not 1<=len(data['Members'])<=64:raise ValueError('Expected 1-64 members')
    members={}
    for m in data['Members']:
        if set(m)!={'Id','PublicKey','Name'} or m['Id']!=kid(m['PublicKey']) or m['Id'] in members:raise ValueError('Invalid member identity')
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9 ._()-]{0,63}',m['Name']):raise ValueError('Invalid member name')
        members[m['Id']]=m
    if data['OwnerId'] not in members:raise ValueError('VPS owner must belong to the group')
    n=data['Node']
    if set(n)!={'Name','Latitude','Longitude','Port'} or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9 ._()-]{0,63}',n['Name']):raise ValueError('Invalid node metadata')
    for k,lo,hi in [('Latitude',-90,90),('Longitude',-180,180)]:
        if type(n[k]) not in (int,float) or not math.isfinite(n[k]) or not lo<=n[k]<=hi:raise ValueError('Invalid node coordinates')
    if type(n['Port']) is not int or not 1024<=n['Port']<=65535:raise ValueError('Invalid UDP port')
    return members

def save_metadata(state):
    peer.atomic(peer.ROOT/'state.json',peer.json_bytes(state))

def synchronise(data):
    members=validate(data);owner_key=members[data['OwnerId']]['PublicKey']
    peer.secure(peer.ROOT,True);peer.restore_pending()
    state,raw,config=peer.load_state()
    if state['port']!=data['Node']['Port']:raise RuntimeError('Existing managed exit uses another UDP port; no port change was made')
    if owner_key not in state['clients']:raise RuntimeError('This managed VPS does not recognise this device as an existing peer. Use the device which set it up; the tool will not take it over.')
    member_hash=','.join(sorted(members))
    record=state.get('shared_group')
    if record is not None:
        if record['id']!=data['GroupId'] or record['owner_key']!=owner_key:raise RuntimeError('This VPS is already published by another group/owner identity')
        if record.get('membership_revision',1)>data['MembershipRevision']:raise RuntimeError('Server has a newer member list; use the latest group.json')
        if record.get('membership_revision')==data['MembershipRevision'] and record.get('membership_hash',member_hash)!=member_hash:raise RuntimeError('Conflicting member lists at the same revision')
        managed=record['managed_keys']
        if not isinstance(managed,list) or len(set(managed))!=len(managed) or owner_key in managed:raise RuntimeError('Invalid group peer ownership record')
        for k in managed:peer.valid_key(k)
    else:
        state=copy.deepcopy(state)
        state['shared_group']={'id':data['GroupId'],'owner_key':owner_key,'managed_keys':[],'revision':0,'membership_revision':data['MembershipRevision'],'membership_hash':member_hash}
        save_metadata(state)
    state,_,_=peer.load_state();state=copy.deepcopy(state);state['shared_group']['membership_revision']=data['MembershipRevision'];state['shared_group']['membership_hash']=member_hash;save_metadata(state)
    wanted={m['PublicKey'] for m in members.values()}
    # Each addition/removal is independently journalled; retry after interruption is safe.
    for key in sorted(wanted):
        state,raw,config=peer.load_state();managed=state['shared_group']['managed_keys']
        if key not in state['clients']:
            new=copy.deepcopy(state);used={r['slot'] for r in state['clients'].values()};slot=next((x for x in range(2,254) if x not in used),None)
            if slot is None:raise RuntimeError('Managed WireGuard address pool is full; completed peer changes are retained')
            new['clients'][key]={'slot':slot,'ipv4':f'10.88.70.{slot}','ipv6':f'fd89:77:70::{slot:x}'}
            new['shared_group']['managed_keys'].append(key)
            peer.transact(state,raw,config,new,key,'register')
        elif key!=owner_key and key not in managed and key in state.get('friend_peers',{}):
            new=copy.deepcopy(state);new['shared_group']['managed_keys'].append(key);save_metadata(new)
    state,_,_=peer.load_state()
    for key in list(state['shared_group']['managed_keys']):
        if key in wanted:continue
        state,raw,config=peer.load_state();new=copy.deepcopy(state);new['shared_group']['managed_keys'].remove(key)
        if key in new['clients']:
            del new['clients'][key];new.get('friend_peers',{}).pop(key,None)
            peer.transact(state,raw,config,new,key,'revoke')
        else:save_metadata(new)
    state,_,_=peer.load_state();new=copy.deepcopy(state)
    new['shared_group']['revision']+=1;new['shared_group']['membership_revision']=data['MembershipRevision'];save_metadata(new)
    assignments={}
    for mid,m in members.items():
        r=new['clients'][m['PublicKey']]
        assignments[mid]={'IPv4':r['ipv4']+'/32','IPv6':r['ipv6']+'/128' if new['ipv6'] else None}
    return {'Schema':1,'GroupId':data['GroupId'],'OwnerId':data['OwnerId'],'ServerPublicKey':new['public_key'],'Port':new['port'],'IPv6':new['ipv6'],'Assignments':assignments,'Revision':new['shared_group']['revision'],'MembersRevision':data['MembershipRevision']}

def bootstrap_and_sync(data,report_parent):
    members=validate(data);created=False
    if not (peer.ROOT/'state.json').exists():
        # The original installer refuses unmanaged interfaces, chain/subnet/port collisions and unknown files.
        setup=module('setup')
        setup.setup(SimpleNamespace(public_key=members[data['OwnerId']]['PublicKey'],port=data['Node']['Port'],report=str(report_parent/'bootstrap-report.json')))
        created=True
    result=synchronise(data);result['CreatedServer']=created;return result

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--input',type=Path,required=True);p.add_argument('--report',type=Path,required=True);args=p.parse_args()
    if os.geteuid()!=0:raise RuntimeError('Use sudo to configure this owned exit')
    if args.input.name!='input.json' or args.report.name!='report.json' or args.input.parent!=args.report.parent or not re.fullmatch(r'/tmp/whispr-hybrid-[A-Za-z0-9]+',str(args.report.parent)):raise RuntimeError('Invalid staging paths')
    actor=pwd.getpwnam(os.environ.get('SUDO_USER',''))
    fd=os.open(args.report.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    lock=None
    try:
        st=os.fstat(fd)
        if st.st_uid!=actor.pw_uid or st.st_mode&0o077:raise RuntimeError('Untrusted staging directory ownership/permissions')
        input_fd=os.open('input.json',os.O_RDONLY|os.O_NOFOLLOW,dir_fd=fd)
        with os.fdopen(input_fd,'rb') as stream:
            st=os.fstat(stream.fileno())
            if not stat.S_ISREG(st.st_mode) or st.st_uid!=actor.pw_uid or st.st_size>262144:raise RuntimeError('Untrusted/oversized group input')
            data=json.load(stream)
        validate(data)
        if os.path.lexists(args.report):raise RuntimeError('Report path already exists')
        lock=os.open(peer.LOCK,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
        st=os.fstat(lock)
        if st.st_uid!=0 or st.st_mode&0o022 or not stat.S_ISREG(st.st_mode):raise RuntimeError('Untrusted server lock')
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        result=bootstrap_and_sync(data,args.report.parent)
        output_fd=os.open('report.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=fd)
        with os.fdopen(output_fd,'wb') as out:
            os.fchown(out.fileno(),actor.pw_uid,actor.pw_gid);out.write(peer.json_bytes(result));out.flush();os.fsync(out.fileno())
        print('Shared exit verified. Existing server identity and unrelated peers retained.')
    finally:
        if lock is not None:os.close(lock)
        os.close(fd)
if __name__=='__main__':
    try:main()
    except Exception as e:print('STOP: '+str(e),file=sys.stderr);raise SystemExit(1)

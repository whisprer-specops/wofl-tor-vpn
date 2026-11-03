from __future__ import annotations
import base64
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import os
import pwd
import uuid
import shutil
import io
from contextlib import redirect_stdout
import unittest
from unittest.mock import patch

FILE = Path(__file__).resolve().parents[1]/'server/peer_admin.py'
spec = importlib.util.spec_from_file_location('peer_admin', FILE)
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)

def key(n):
    return base64.b64encode(hashlib.sha256(str(n).encode()).digest()).decode()

class PeerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.patches = [patch.object(a,'ROOT',self.root/'owned'), patch.object(a,'CONFIG',self.root/'wireguard/wg-whispr.conf'), patch.object(a,'BACKUPS',self.root/'backups')]
        for p in self.patches:
            p.start();self.addCleanup(p.stop)
        a.ROOT.mkdir(mode=0o700);a.CONFIG.parent.mkdir(mode=0o700)
        self.server, self.owner, self.friend = key(1), key(2), key(3)
        self.state = {'schema':1,'port':51832,'ipv6':True,'public_key':self.server,'clients':{self.owner:{'slot':2,'ipv4':'10.88.70.2','ipv6':'fd89:77:70::2'}},'uplink4':'eth0','uplink6':'eth0'}
        (a.ROOT/'server.key').write_text(key(99));(a.ROOT/'server.key').chmod(0o600)
        self.save(self.state)
        self.live = copy.deepcopy(a.expected_peers(self.state))
        self.calls=[];self.fail_after_set=False
        self.commands=patch.object(a,'command',side_effect=self.command);self.commands.start();self.addCleanup(self.commands.stop)
        self.baseline=self.bytes()
    def save(self,state):
        cfg=a.render(state,key(99));state['config_sha256']=a.digest(cfg)
        a.atomic(a.CONFIG,cfg);a.atomic(a.ROOT/'state.json',a.json_bytes(state))
    def bytes(self):return ((a.ROOT/'state.json').read_bytes(),a.CONFIG.read_bytes())
    def command(self,args):
        self.calls.append(args[:])
        self.assertEqual(args[0],'wg','Only wg may be called, never firewall/service tools')
        self.assertEqual(args[2],a.IFACE)
        if args[1]=='show':
            if args[3]=='public-key':return self.server
            if args[3]=='listen-port':return '51832'
            if args[3]=='allowed-ips':return '\n'.join(k+'\t'+' '.join(sorted(v)) for k,v in self.live.items())
            self.fail('Unexpected read command')
        self.assertEqual(args[1],'set');self.assertEqual(args[3],'peer')
        pub=args[4]
        self.assertNotEqual(pub,self.owner,'The owner peer must never be modified')
        if args[5]=='remove':self.live.pop(pub,None)
        else:
            self.assertEqual(args[5],'allowed-ips');self.live[pub]=set(args[6].split(','))
            if self.fail_after_set:
                self.fail_after_set=False;raise RuntimeError('Injected wg failure after live change')
        return ''
    def register(self,public=None,rid='a'*32):return a.operate('register',public or self.friend,rid,'Friend-PC')
    def test_register_repeat_and_revoke_preserve_owner(self):
        result=self.register();self.assertEqual(result['client_ipv4'],'10.88.70.3/32')
        self.assertEqual(self.live[self.owner],a.expected_peers(self.state)[self.owner])
        first=self.bytes();self.register();self.assertEqual(self.bytes(),first)
        second=self.register(key(4),'b'*32);self.assertEqual(second['client_ipv4'],'10.88.70.4/32')
        self.assertEqual(a.operate('check',self.friend,'a'*32,'Friend-PC')['status'],'verified')
        self.assertEqual(a.operate('revoke',self.friend,'a'*32,'Friend-PC')['status'],'revoked')
        self.assertEqual(set(self.live),{self.owner,key(4)})
        self.assertEqual(a.operate('revoke',self.friend,'a'*32,'Friend-PC')['status'],'already-absent')
        state=json.loads((a.ROOT/'state.json').read_bytes());self.assertEqual(state['public_key'],self.server)
        self.assertEqual((a.ROOT/'server.key').read_text(),key(99));self.assertEqual(a.digest(a.CONFIG.read_bytes()),state['config_sha256'])
        self.assertFalse((a.ROOT/'friend-peer-pending.json').exists())
    def test_cannot_enrol_or_revoke_owner_or_wrong_request(self):
        for action in ('register','revoke','check'):
            with self.assertRaisesRegex(RuntimeError,'not owned'):a.operate(action,self.owner,'a'*32,'Friend-PC')
        self.assertEqual(self.bytes(),self.baseline)
        self.register();snapshot=self.bytes()
        with self.assertRaisesRegex(RuntimeError,'not owned'):a.operate('revoke',self.friend,'b'*32,'Friend-PC')
        self.assertEqual(self.bytes(),snapshot)
    def test_config_and_live_mismatch_refuse_without_changes(self):
        self.live[key(9)]={'10.88.70.9/32'}
        with self.assertRaisesRegex(RuntimeError,'Live peers differ'):self.register()
        self.assertEqual(self.bytes(),self.baseline)
        self.live.pop(key(9));a.CONFIG.write_bytes(a.CONFIG.read_bytes()+b'# change\n');before=self.bytes()
        with self.assertRaisesRegex(RuntimeError,'changed outside'):self.register()
        self.assertEqual(self.bytes(),before)
    def test_wg_error_rolls_back_target_and_persistent_bytes(self):
        self.fail_after_set=True
        with self.assertRaisesRegex(RuntimeError,'Injected wg'):self.register()
        self.assertEqual(self.bytes(),self.baseline);self.assertEqual(set(self.live),{self.owner})
        self.assertFalse((a.ROOT/'friend-peer-pending.json').exists())
    def test_write_error_rolls_back_byte_for_byte(self):
        original=a.atomic;failed=False
        def write(path,data):
            nonlocal failed
            if path==a.ROOT/'state.json' and not failed:failed=True;raise OSError('Injected state write failure')
            return original(path,data)
        with patch.object(a,'atomic',side_effect=write):
            with self.assertRaisesRegex(OSError,'Injected state'):self.register()
        self.assertEqual(self.bytes(),self.baseline);self.assertEqual(set(self.live),{self.owner})
    def test_crash_journal_recovers_without_touching_other_peers(self):
        real=a.live_peers;calls=0
        def read():
            nonlocal calls
            calls+=1
            if calls==2:raise KeyboardInterrupt('Simulated abrupt interruption')
            return real()
        with patch.object(a,'live_peers',side_effect=read):
            with self.assertRaises(KeyboardInterrupt):self.register()
        self.assertTrue((a.ROOT/'friend-peer-pending.json').exists());self.assertIn(self.friend,self.live)
        report=a.operate('recover',None,None,'Friend-PC')
        self.assertTrue(report['recovered']);self.assertEqual(self.bytes(),self.baseline);self.assertEqual(set(self.live),{self.owner})
    def test_pending_recovery_refuses_unrelated_live_changes(self):
        real=a.live_peers;calls=0
        def read():
            nonlocal calls
            calls+=1
            if calls==2:raise KeyboardInterrupt()
            return real()
        with patch.object(a,'live_peers',side_effect=read):
            with self.assertRaises(KeyboardInterrupt):self.register()
        self.live[self.owner]={'10.88.70.200/32'};snapshot=self.bytes()
        with self.assertRaisesRegex(RuntimeError,'Other live peers'):a.restore_pending()
        self.assertEqual(self.bytes(),snapshot);self.assertEqual(self.live[self.owner],{'10.88.70.200/32'})
    def test_exhausted_pool_and_invalid_keys(self):
        state=copy.deepcopy(self.state)
        for slot in range(3,254):state['clients'][key(1000+slot)]={'slot':slot,'ipv4':f'10.88.70.{slot}','ipv6':f'fd89:77:70::{slot:x}'}
        self.save(state);self.live=a.expected_peers(state);before=self.bytes()
        with self.assertRaisesRegex(RuntimeError,'No free peer'):self.register()
        self.assertEqual(self.bytes(),before)
        for invalid in ['bad; touch /tmp/nope','A'*43+'=',base64.b64encode(bytes(32)).decode()]:
            with self.assertRaises(ValueError):a.valid_key(invalid)
    def test_cli_public_report_and_staging_preflight(self):
        stage=Path('/tmp')/('whispr-enrol-'+uuid.uuid4().hex)
        stage.mkdir(mode=0o700);self.addCleanup(lambda:shutil.rmtree(stage,ignore_errors=True))
        report=stage/'report.json'
        arguments=['peer_admin.py','--action','register','--public-key',self.friend,'--request-id','a'*32,'--label','Friend-PC','--report',str(report)]
        with patch.object(a,'LOCK',self.root/'lock'), patch.dict(os.environ,{'SUDO_USER':pwd.getpwuid(os.geteuid()).pw_name}), patch.object(a.sys,'argv',arguments):
            output=io.StringIO()
            with redirect_stdout(output):a.main()
        data=report.read_text();self.assertEqual(json.loads(data)['client_public_key'],self.friend)
        self.assertNotIn(key(99),data+output.getvalue());self.assertEqual(report.stat().st_mode & 0o777,0o600)
        before=self.bytes()
        with patch.dict(os.environ,{'SUDO_USER':pwd.getpwuid(os.geteuid()).pw_name}):
            with self.assertRaisesRegex(RuntimeError,'Unexpected report staging'):a.prepare_report(self.root/'report.json')
        self.assertEqual(self.bytes(),before)
    def test_render_matches_existing_setup_contract(self):
        spec=importlib.util.spec_from_file_location('original',Path(__file__).resolve().parent/'fixtures/fix5_render_reference.py')
        original=importlib.util.module_from_spec(spec);spec.loader.exec_module(original)
        original.ROOT=a.ROOT
        self.assertEqual(a.render(self.state,key(99)).decode(),original.render(self.state,key(99)))

if __name__=='__main__':unittest.main(verbosity=2)

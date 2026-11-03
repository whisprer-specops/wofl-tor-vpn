import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from test_peer_admin import PeerTests, a, key
FILE=Path(__file__).resolve().parents[1]/'server/group_admin.py'
spec=importlib.util.spec_from_file_location('group_admin',FILE);g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g)
class GroupTests(PeerTests):
    def setUp(self):
        super().setUp();self.patch=patch.object(g,'peer',a);self.patch.start();self.addCleanup(self.patch.stop)
        self.data={'Schema':1,'GroupId':'b'*32,'MembershipRevision':1,'OwnerId':g.kid(self.owner),'Members':[{'Id':g.kid(k),'PublicKey':k,'Name':n} for k,n in [(self.owner,'Owner'),(self.friend,'Friend')]],'Node':{'Name':'Test Frankfurt','Latitude':50.1109,'Longitude':8.6821,'Port':51832}}
    def test_group_add_idempotence_and_member_removal(self):
        r=g.synchronise(self.data);self.assertEqual(r['Assignments'][g.kid(self.friend)]['IPv4'],'10.88.70.3/32');self.assertEqual(r['Revision'],1)
        before_peers=copy.deepcopy(self.live);r=g.synchronise(self.data);self.assertEqual(self.live,before_peers);self.assertEqual(r['Revision'],2)
        d=copy.deepcopy(self.data);d['Members']=d['Members'][:1];d['MembershipRevision']=2
        r=g.synchronise(d);self.assertEqual(set(self.live),{self.owner});self.assertEqual(set(r['Assignments']),{g.kid(self.owner)})
    def test_wrong_group_owner_and_stale_member_roster_refuse(self):
        g.synchronise(self.data);before=self.bytes()
        d=copy.deepcopy(self.data);d['GroupId']='c'*32
        with self.assertRaisesRegex(RuntimeError,'another group'):g.synchronise(d)
        self.assertEqual(self.bytes(),before)
        d=copy.deepcopy(self.data);d['Members'].append({'Id':g.kid(key(4)),'PublicKey':key(4),'Name':'Third'})
        with self.assertRaisesRegex(RuntimeError,'Conflicting member'):g.synchronise(d)
        d['MembershipRevision']=2;g.synchronise(d)
        with self.assertRaisesRegex(RuntimeError,'newer member'):g.synchronise(self.data)
    def test_unknown_native_peers_preserved_and_legacy_friend_adopted(self):
        state=copy.deepcopy(self.state)
        state['clients'][key(9)]={'slot':9,'ipv4':'10.88.70.9','ipv6':'fd89:77:70::9'}
        state['clients'][self.friend]={'slot':3,'ipv4':'10.88.70.3','ipv6':'fd89:77:70::3'}
        state['friend_peers']={self.friend:{'request_id':'a'*32}}
        self.save(state);self.live=a.expected_peers(state)
        g.synchronise(self.data)
        d=copy.deepcopy(self.data);d['Members']=d['Members'][:1];d['MembershipRevision']=2;g.synchronise(d)
        self.assertEqual(set(self.live),{self.owner,key(9)})
        self.assertNotIn(self.friend,json.loads((a.ROOT/'state.json').read_bytes()).get('friend_peers',{}))
    def test_existing_different_device_cannot_take_over(self):
        d=copy.deepcopy(self.data);d['OwnerId']=g.kid(self.friend)
        with self.assertRaisesRegex(RuntimeError,'does not recognise'):g.synchronise(d)
        self.assertEqual(self.bytes(),self.baseline)
    def test_partial_group_failure_is_retryable(self):
        self.data['Members'].append({'Id':g.kid(key(4)),'PublicKey':key(4),'Name':'Third'})
        self.fail_after_set=True
        with self.assertRaisesRegex(RuntimeError,'Injected'):g.synchronise(self.data)
        r=g.synchronise(self.data);self.assertEqual(len(r['Assignments']),3);self.assertEqual(len(self.live),3)
    def test_bootstrap_only_when_missing(self):
        class NeverSetup:
            def setup(self,args):raise AssertionError('Existing server must not re-run firewall/service setup')
        with patch.object(g,'module',return_value=NeverSetup()):r=g.bootstrap_and_sync(self.data,self.root)
        self.assertFalse(r['CreatedServer'])
    def test_fresh_bootstrap_registers_owner_then_group(self):
        (a.ROOT/'state.json').unlink();a.CONFIG.unlink()
        calls=[];test=self
        class InitialSetup:
            def setup(self,args):
                calls.append(args)
                test.assertEqual(args.public_key,test.owner)
                test.assertEqual(args.port,51832)
                test.save(copy.deepcopy(test.state));test.live=a.expected_peers(test.state)
        with patch.object(g,'module',return_value=InitialSetup()):r=g.bootstrap_and_sync(self.data,self.root)
        self.assertTrue(r['CreatedServer']);self.assertEqual(len(calls),1);self.assertEqual(set(self.live),{self.owner,self.friend})
    def test_invalid_input_rejected(self):
        for field,value in [('GroupId','bad'),('OwnerId','bad'),('MembershipRevision',0)]:
            d=copy.deepcopy(self.data);d[field]=value
            with self.assertRaises(ValueError):g.validate(d)
        d=copy.deepcopy(self.data);d['Node']['Latitude']=float('nan')
        with self.assertRaises(ValueError):g.validate(d)
if __name__=='__main__':unittest.main(verbosity=2)

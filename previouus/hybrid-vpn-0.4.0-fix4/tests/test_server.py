"""State-preservation tests for the actual server firewall planner and WG renderer.
These model iptables command semantics; they do not exercise a kernel firewall.
"""
import copy
import importlib.util
from pathlib import Path
import subprocess
import unittest

ROOT=Path(__file__).resolve().parents[1]

def load(name):
    spec=importlib.util.spec_from_file_location('hybrid_'+name,ROOT/'server'/f'{name}.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

class FakeTables:
    def __init__(self):
        self.missing_target_checks=0
        self.tables={('filter','INPUT'):[['-p','tcp','--dport','2357','-j','ACCEPT']],
                     ('filter','FORWARD'):[['-j','OTHER_PROJECT']],
                     ('filter','OTHER_PROJECT'):[['-i','wg-ollama','-j','ACCEPT']],
                     ('nat','POSTROUTING'):[['-s','172.18.0.0/16','-j','MASQUERADE']]}
    def __call__(self,binary,args,check=True):
        args=list(args);table='filter'
        if args[:1]==['-t']:table=args[1];args=args[2:]
        if args==['-S']:
            text=''.join(('-P ' if chain in ('INPUT','FORWARD','POSTROUTING') else '-N ')+chain+(' ACCEPT' if chain in ('INPUT','FORWARD','POSTROUTING') else '')+'\n' for (kind,chain) in self.tables if kind==table)
            return subprocess.CompletedProcess([binary,*args],0,text,'')
        op,chain=args[:2];rest=args[2:];key=(table,chain);code=0
        if op=='-C' and '-j' in rest and rest[rest.index('-j')+1].startswith('WHISPR_H_') and (table,rest[rest.index('-j')+1]) not in self.tables:
            self.missing_target_checks+=1
            return subprocess.CompletedProcess([binary,*args],2,'',"iptables v1.8.7 (nf_tables): Chain '"+rest[rest.index('-j')+1]+"' does not exist\n")
        if op=='-S':code=0 if key in self.tables else 1
        elif op=='-C':code=0 if rest in self.tables.get(key,[]) else 1
        elif op=='-N':self.tables[key]=[]
        elif op=='-F':self.tables[key]=[]
        elif op=='-X':del self.tables[key]
        elif op=='-A':self.tables[key].append(rest)
        elif op=='-I':self.tables[key].insert(int(rest[0])-1,rest[1:])
        elif op=='-D':self.tables[key].remove(rest)
        else:raise AssertionError(op)
        result=subprocess.CompletedProcess([binary,*args],code,'','')
        if check and code:raise subprocess.CalledProcessError(code,result.args)
        return result

class ServerTests(unittest.TestCase):
    def test_apply_reapply_remove_preserves_other_projects(self):
        firewall=load('firewall');fake=FakeTables();firewall.run=fake
        original=copy.deepcopy(fake.tables)
        cfg={'uplink4':'eth0','port':51832}
        firewall.family('iptables',cfg,False,False)
        once=copy.deepcopy(fake.tables)
        forward=fake.tables[('filter','WHISPR_H_FWD')]
        self.assertIn(['-i','wg-whispr','-s','10.88.70.0/24','-o','eth0','-p','udp','-j','ACCEPT'],forward)
        self.assertIn(['-i','wg-whispr','-d','169.254.0.0/16','-j','DROP'],forward)
        self.assertEqual(forward[-1],['-j','DROP'])
        self.assertEqual(fake.tables[('filter','OTHER_PROJECT')],original[('filter','OTHER_PROJECT')])
        firewall.family('iptables',cfg,False,False)
        self.assertEqual(fake.tables,once)
        firewall.family('iptables',cfg,False,True)
        self.assertEqual(fake.tables,original)
        self.assertEqual(fake.missing_target_checks,0)
    def test_table_inspection_failures_are_not_suppressed(self):
        firewall=load('firewall')
        firewall.run=lambda *args:subprocess.CompletedProcess([],4,'','Permission denied')
        with self.assertRaisesRegex(RuntimeError,'Permission denied'):
            firewall.chains_in_table('iptables','filter')

    def test_peer_allowed_addresses_do_not_expand_to_other_devices(self):
        setup=load('setup')
        state={'ipv6':True,'port':51832,'clients':{'DEVICE_PUBLIC_KEY':{'ipv4':'10.88.70.2','ipv6':'fd89:77:70::2'}}}
        text=setup.render(state,'SERVER_PRIVATE_FIXTURE')
        self.assertIn('AllowedIPs = 10.88.70.2/32, fd89:77:70::2/128',text)
        self.assertNotIn('AllowedIPs = 0.0.0.0/0',text)
        self.assertNotIn('SaveConfig',text)
        self.assertIn('/usr/bin/python3 -I /etc/whispr-hybrid/firewall.py apply',text)
    def test_firewall_provider_errors_are_not_reported_as_empty_sets(self):
        firewall=load('firewall')
        firewall.run=lambda *args:subprocess.CompletedProcess([],4,'','provider unavailable')
        with self.assertRaisesRegex(RuntimeError,'provider unavailable'):
            firewall.present('iptables','filter','INPUT',['-j','WHISPR_H_IN'])

if __name__=='__main__':unittest.main()

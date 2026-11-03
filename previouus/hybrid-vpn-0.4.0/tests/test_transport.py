"""Real engine loopback integration tests. Python 3.10+, PowerShell 7, pinned sing-box.
No TUN, Windows firewall or VPS modifications. Never substitutes for Windows leak tests.
Usage: python tests/test_transport.py --engine /path/to/sing-box --pwsh /path/to/pwsh
"""
import argparse
import copy
import json
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]
ENGINE=None
PWSH=None

def exact(s,n):
    b=b''
    while len(b)<n:
        part=s.recv(n-len(b))
        if not part:raise EOFError('socket closed')
        b+=part
    return b

def free_port(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET,kind) as s:
        s.bind(('127.0.0.1',0));return s.getsockname()[1]

def pair():
    text=subprocess.check_output([ENGINE,'generate','wg-keypair'],text=True)
    return dict(line.split(': ',1) for line in text.strip().splitlines())

def connect_socks(port, command, address, target_port):
    s=socket.create_connection(('127.0.0.1',port),timeout=3)
    s.sendall(b'\x05\x01\x00')
    if exact(s,2)!=b'\x05\x00':raise ValueError('authentication')
    s.sendall(bytes([5,command,0,1])+socket.inet_aton(address)+struct.pack('!H',target_port))
    response=exact(s,4)
    length={1:4,4:16}.get(response[3])
    if length is None:raise ValueError('unexpected address type')
    bind=exact(s,length+2)
    return s,response,bind

class Processes:
    def __init__(self,directory):self.directory=directory;self.procs=[];self.logs=[]
    def start(self,cfg,name):
        path=Path(self.directory)/f'{name}.json';path.write_text(json.dumps(cfg))
        subprocess.run([ENGINE,'check','-c',str(path)],check=True,capture_output=True)
        log=open(Path(self.directory)/(name+'.log'),'w+');self.logs.append(log)
        p=subprocess.Popen([ENGINE,'run','-c',str(path)],stdout=log,stderr=log)
        self.procs.append(p);time.sleep(.4)
        if p.poll() is not None:
            log.seek(0);raise RuntimeError(log.read())
        return p
    def close(self):
        for p in reversed(self.procs):
            if p.poll() is None:p.terminate()
        for p in self.procs:
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:p.kill();p.wait()
        for log in self.logs:log.close()

class TransportTests(unittest.TestCase):
    def test_generated_configs_and_real_wireguard_udp(self):
        with tempfile.TemporaryDirectory() as temp:
            temp=Path(temp);client_key=pair();server_key=pair()
            wg_port=free_port(socket.SOCK_DGRAM);mixed_port=free_port()
            script='''param($Common,$Output,$Private,$Public,$Port)
. $Common
$p=@{endpoint='127.0.0.1';port=[int]$Port;client_ipv4='10.88.70.2/32';ipv6=$false;server_public_key=$Public}
Get-HybridConfig -Peer $p -PrivateKey $Private -TorPath 'C:\\Program Files\\whispr Hybrid VPN\\bin\\tor\\tor.exe' | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Output
'''
            generator=temp/'generate.ps1';generator.write_text(script)
            generated=temp/'generated.json'
            subprocess.run([PWSH,'-NoLogo','-NoProfile','-File',str(generator),
                            str(ROOT/'client/Common.ps1'),str(generated),client_key['PrivateKey'],
                            server_key['PublicKey'],str(wg_port)],check=True,capture_output=True)
            actual=json.loads(generated.read_text(encoding='utf-8-sig'))
            subprocess.run([ENGINE,'check','-c',str(generated)],check=True,capture_output=True)
            self.assertEqual(actual['route']['rules'][-1]['action'],'reject')
            dual=copy.deepcopy(actual)
            dual['endpoints'][0]['address'].append('fd89:77:70::2/128')
            dual['endpoints'][0]['peers'][0]['allowed_ips'].append('::/0')
            dual['route']['rules']=[r for r in dual['route']['rules'] if r.get('ip_version')!=6]
            dual_path=temp/'dual.json';dual_path.write_text(json.dumps(dual))
            subprocess.run([ENGINE,'check','-c',str(dual_path)],check=True,capture_output=True)
            # Preserve all routing rules while substituting loopback test ports and removing the privileged TUN.
            actual['inbounds']=[i for i in actual['inbounds'] if i['type']!='tun']
            actual['inbounds'][0]['listen_port']=mixed_port
            actual['route']['auto_detect_interface']=False
            actual['dns']['servers'][0]['server']='1.1.1.1' # never queried: fixture destinations are numeric
            server={'log':{'level':'error'},'endpoints':[{'type':'wireguard','tag':'wg-server','system':False,
                    'address':['10.88.70.1/24'],'private_key':server_key['PrivateKey'],'listen_port':wg_port,
                    'peers':[{'public_key':client_key['PublicKey'],'allowed_ips':['10.88.70.2/32']}]}],
                    'outbounds':[{'type':'direct','tag':'egress'}],'route':{'final':'egress'}}
            echo=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);echo.bind(('127.0.0.1',0));echo.settimeout(.3)
            self.addCleanup(echo.close);echo_count=[];stop=threading.Event()
            def echo_worker():
                while not stop.is_set():
                    try:data,addr=echo.recvfrom(512)
                    except socket.timeout:continue
                    except OSError:return
                    echo_count.append(data);echo.sendto(data,addr)
            worker=threading.Thread(target=echo_worker,daemon=True);worker.start()
            processes=Processes(temp)
            try:
                try:
                    server_process=processes.start(server,'server')
                except RuntimeError as exc:
                    if 'create netlink socket: operation not permitted' in str(exc):
                        self.skipTest('Runtime network initialization denied by this host; config validation passed, actual WG exchange still untested here')
                    raise
                client_process=processes.start(actual,'client')
                control,response,bind=connect_socks(mixed_port,3,'0.0.0.0',0)
                self.addCleanup(control.close);self.assertEqual(response[1],0)
                relay_ip=socket.inet_ntoa(bind[:4]);relay_port=struct.unpack('!H',bind[4:])[0]
                if relay_ip=='0.0.0.0':relay_ip='127.0.0.1'
                udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);udp.settimeout(5);self.addCleanup(udp.close)
                udp.connect((relay_ip,relay_port))
                payload=secrets.token_bytes(24)
                packet=b'\x00\x00\x00\x01'+socket.inet_aton('127.0.0.1')+struct.pack('!H',echo.getsockname()[1])+payload
                udp.send(packet);reply=udp.recv(1024)
                self.assertEqual(reply[10:],payload)
                self.assertEqual(echo_count,[payload])
                # Cutting the real WireGuard peer must not fall back to the direct echo target.
                server_process.terminate();server_process.wait(timeout=5)
                udp.settimeout(.7);udp.send(packet)
                with self.assertRaises(socket.timeout):udp.recv(1024)
                self.assertEqual(echo_count,[payload])
                self.assertIsNone(client_process.poll())
            finally:
                stop.set();processes.close()

    def test_stun_verifier_accepts_correct_exit_and_rejects_wrong_exit(self):
        # Exercise the shipped PowerShell SOCKS/STUN parser, not a Python reimplementation of it.
        def run(expected):
            tcp=socket.socket();tcp.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);tcp.bind(('127.0.0.1',17880));tcp.listen(1);tcp.settimeout(5)
            udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);udp.bind(('127.0.0.1',0));udp.settimeout(5)
            errors=[]
            def serve():
                try:
                    c,_=tcp.accept()
                    with c:
                        exact(c,3);c.sendall(b'\x05\x00');exact(c,10)
                        c.sendall(b'\x05\x00\x00\x01'+socket.inet_aton('127.0.0.1')+struct.pack('!H',udp.getsockname()[1]))
                        packet,addr=udp.recvfrom(1024)
                        domain_len=packet[4];start=7+domain_len
                        self.assertEqual(packet[5:5+domain_len],b'stun.cloudflare.com')
                        tx=packet[start+8:start+20]
                        mask=bytes.fromhex('2112a442');mapped=socket.inet_aton('203.0.113.7')
                        value=b'\x00\x01'+struct.pack('!H',12345^0x2112)+bytes(a^b for a,b in zip(mapped,mask))
                        stun=b'\x01\x01\x00\x0c'+mask+tx+b'\x00\x20\x00\x08'+value
                        header=b'\x00\x00\x00\x01'+socket.inet_aton('127.0.0.1')+struct.pack('!H',3478)
                        udp.sendto(header+stun,addr);time.sleep(.2)
                except Exception as exc:errors.append(exc)
                finally:tcp.close();udp.close()
            thread=threading.Thread(target=serve,daemon=True);thread.start()
            ps=f"$ErrorActionPreference='Stop'; . '{ROOT/'client/Verify-Udp.ps1'}'; Test-HybridUdp -ExpectedAddress '{expected}' | ConvertTo-Json"
            p=subprocess.run([PWSH,'-NoLogo','-NoProfile','-Command',ps],capture_output=True,text=True,timeout=12)
            thread.join(timeout=6)
            if errors:raise errors[0]
            return p
        ok=run('203.0.113.7');self.assertEqual(ok.returncode,0,ok.stderr)
        self.assertEqual(json.loads(ok.stdout)['ObservedAddress'],'203.0.113.7')
        bad=run('203.0.113.8');self.assertNotEqual(bad.returncode,0)
        self.assertIn('UDP exit mismatch',bad.stderr)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--engine',required=True);p.add_argument('--pwsh',required=True)
    args,rest=p.parse_known_args();ENGINE=args.engine;PWSH=args.pwsh
    unittest.main(argv=['test_transport.py',*rest])

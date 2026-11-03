"""Exercise the real friend installer with a reset-seeded existing identity.
Windows ACL/COM/download/scheduler boundaries use the original test fixture.
No Windows/network operations or real private data are used.
"""
import argparse,importlib.util,json,subprocess,tempfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);p.add_argument('--pwsh',type=Path,required=True);a=p.parse_args()
flow=a.source/'packs/friend/tests/test_friend_flow.py'
spec=importlib.util.spec_from_file_location('friend_fixture',flow);mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod);mod.PWSH=str(a.pwsh.resolve())
case=mod.FriendFlow('test_interrupted_initial_download_is_retryable')
reset=Path(__file__).resolve().parents[1]/'Reset-WhisprVpn.ps1'
with tempfile.TemporaryDirectory() as td:
 t=Path(td);pkg,env,boundary=case.fixture(t)
 backup=t/'old-state';backup.mkdir()
 (backup/'device-key.json').write_text(json.dumps({'PublicKey':mod.PUBLIC,'PrivateKey':mod.PRIVATE}))
 peer={'schema':1,'ssh_alias':'fkt1','endpoint':'203.0.113.8','port':51832,'server_public_key':mod.SERVER,'client_public_key':mod.PUBLIC,'client_ipv4':'10.88.70.2/32','client_ipv6':None,'ipv6':False,'interface':'wg-whispr'}
 (backup/'peer.json').write_text(json.dumps(peer));(backup/'session.json').write_text('{"State":"armed"}')
 seed=t/'data/whispr-hybrid';seed.parent.mkdir()
 command=f". '{reset}' -LibraryOnly; function Secure-Directory([string]$Path) {{[void](New-Item -ItemType Directory -Path $Path)}}; Restore-Seed '{backup}' '{seed}' (Get-SeedPlan '{backup}')"
 r=subprocess.run([str(a.pwsh),'-NoLogo','-NoProfile','-Command',command],capture_output=True,text=True,timeout=30)
 assert r.returncode==0,r.stdout+r.stderr
 original=(seed/'device-key.json').read_bytes()
 case.run_ps(pkg/'Install-Friend.ps1',f"-DeviceName Reset-PC -OutputDirectory '{t/'exchange'}'",env,boundary)
 assert (seed/'device-key.json').read_bytes()==original
 assert json.loads((seed/'peer.json').read_text())==peer
 assert json.loads((seed/'friend-install.json').read_text())['phase']=='ready'
 assert not (seed/'session.json').exists()
 assert json.loads((t/'exchange/friend-request.json').read_text())['PublicKey']==mod.PUBLIC
 print('PASS: the original fresh installer accepts reset-seeded state, retains the exact private identity and approved exit, reaches ready, and does not resurrect an armed session.')

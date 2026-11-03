#!/usr/bin/env python3
"""Fetch exact upstream release archives, verifying every byte by SHA-256."""
from concurrent.futures import ThreadPoolExecutor
import hashlib,json,os,sys,urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parent
LOCK=[
 {'name':'PowerShell-7.6.9-win-x64.zip','url':'https://github.com/PowerShell/PowerShell/releases/download/v7.6.9/PowerShell-7.6.9-win-x64.zip','sha256':'ce7484804c0f0ad4dda10c958e71acdaf7eebfb22505c1b480f89e0e9f1da94d'},

]
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()
def fetch(row):
 folder=ROOT/'downloads';folder.mkdir(exist_ok=True)
 target=folder/row['name'];partial=target.with_name(target.name+'.partial')
 if target.exists() and digest(target)==row['sha256']:
  print('VERIFIED CACHE: '+row['name'],flush=True);return
 print('Downloading '+row['name'],flush=True)
 req=urllib.request.Request(row['url'],headers={'User-Agent':'whispr-VPN-release-builder/1.0'})
 try:
  with urllib.request.urlopen(req,timeout=180) as r,partial.open('wb') as f:
   while True:
    data=r.read(1024*1024)
    if not data:break
    f.write(data)
  if digest(partial)!=row['sha256']:raise RuntimeError('Checksum mismatch: '+row['name'])
  partial.replace(target);print('VERIFIED: '+row['name'],flush=True)
 finally:
  if partial.exists():partial.unlink()
if __name__=='__main__':
 (ROOT/'dependencies.lock.json').write_text(json.dumps(LOCK,indent=2)+'\n')
 with ThreadPoolExecutor(max_workers=3) as pool:list(pool.map(fetch,LOCK))

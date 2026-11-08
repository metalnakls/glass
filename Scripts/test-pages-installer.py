#!/usr/bin/env python3
"""Installed-app failure checks; uses a temporary, deliberately failing worker fixture."""
import hashlib,pathlib,re,shutil,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parent.parent
bootstrap=(root/'site/install.sh').read_text()
digest=re.search(r'installers/([0-9a-f]{64})\.sh',bootstrap)[1]
installer=root/f'site/installers/{digest}.sh'
app=pathlib.Path('/Applications/Glass.app/Contents/MacOS/Glass')
original=hashlib.sha256(app.read_bytes()).digest()
with tempfile.TemporaryDirectory(prefix='glass-installer-failure-') as tmp:
 d=pathlib.Path(tmp); release=d/'release';release.mkdir()
 (release/'Glass.zip').write_bytes(b'corrupt archive')
 result=subprocess.run(['bash',str(installer),'--release-dir',str(release),'--verify-only'],capture_output=True,text=True)
 assert result.returncode!=0 and 'Checksum mismatch' in result.stderr
 assert hashlib.sha256(app.read_bytes()).digest()==original
 print('Corrupt archive rejected before changing the installed app.')
 # Keep release pins and replacement logic intact; inject a failing worker step.
 version=re.search(r"version='([^']+)'",installer.read_text())[1]
 cached=pathlib.Path.home()/f'Library/Caches/Glass-Setup/{version}/Glass.zip'
 shutil.copyfile(cached,release/'Glass.zip')
 worker=release/'install-background-worker.sh';worker.write_text('#!/bin/bash\nexit 42\n')
 script=installer.read_text()
 script=re.sub(r"worker_hash='[0-9a-f]+'", "worker_hash='"+hashlib.sha256(worker.read_bytes()).hexdigest()+"'", script)
 script=script.replace('cache="$HOME/Library/Caches/Glass-Setup/$version"','cache="'+str(d/'cache')+'"')
 probe=d/'install.sh';probe.write_text(script)
 result=subprocess.run(['bash',str(probe),'--release-dir',str(release)],capture_output=True,text=True)
 assert result.returncode==42, result.stdout+result.stderr
 assert 'restoring the previous app' in result.stderr
 assert hashlib.sha256(app.read_bytes()).digest()==original, 'Previous application was not restored exactly'
 subprocess.run(['codesign','--verify','--deep','--strict','/Applications/Glass.app'],check=True)
 print('Worker failure restored the exact previous app and its valid signature.')

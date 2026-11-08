#!/usr/bin/env python3
"""Validate the exact bootstrap/installer pair deployed to Pages."""
import hashlib,pathlib,re,subprocess
root=pathlib.Path(__file__).resolve().parent.parent
bootstrap=(root/'site/install.sh').read_text()
pins=re.findall(r'https://metalnakls\.github\.io/glass/installers/([0-9a-f]{64})\.sh',bootstrap)
assert len(pins)==1, 'Expected one content-addressed installer URL'
assert "'"+pins[0]+"'" in bootstrap, 'Bootstrap checksum differs from its URL'
for path in (root/'site/installers').glob('*.sh'):
 assert hashlib.sha256(path.read_bytes()).hexdigest()==path.stem, f'Installer digest mismatch: {path.name}'
 assert not re.search(r'@(VERSION|ARCHIVE_HASH|WORKER_HASH|ARCHIVE_API|WORKER_API)@',path.read_text())
 subprocess.run(['bash','-n',str(path)],check=True)
assert (root/f'site/installers/{pins[0]}.sh').is_file()
subprocess.run(['sh','-n',str(root/'site/install.sh')],check=True)
assert 'curl -fsSL https://metalnakls.github.io/glass/install.sh | sh' in (root/'site/index.html').read_text()
print('Pages command, installer hash, release pins, and shell syntax verified.')

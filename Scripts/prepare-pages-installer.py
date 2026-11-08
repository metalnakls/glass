#!/usr/bin/env python3
"""Pin the one-command installer to an existing published GitHub release."""
import hashlib,json,pathlib,re,subprocess,sys
root=pathlib.Path(__file__).resolve().parent.parent
release=json.loads(subprocess.check_output(['gh','release','view',sys.argv[1],'--repo','metalnakls/glass','--json','tagName,assets,isDraft,isPrerelease']))
assert not release['isDraft'] and not release['isPrerelease']
assert re.fullmatch(r'v[0-9]+(?:\.[0-9]+)*',release['tagName'])
assets={a['name']:a for a in release['assets']}
script=(root/'Scripts/install-glass.template.sh').read_text()
script=script.replace('@VERSION@',release['tagName'].removeprefix('v'))
for prefix,name in [('ARCHIVE','Glass.zip'),('WORKER','install-background-worker.sh')]:
 a=assets[name]; digest=a['digest']; assert re.fullmatch(r'sha256:[0-9a-f]{64}',digest)
 assert a['apiUrl'].startswith('https://api.github.com/repos/metalnakls/glass/releases/assets/')
 script=script.replace('@'+prefix+'_HASH@',digest[7:]).replace('@'+prefix+'_API@',a['apiUrl'])
digest=hashlib.sha256(script.encode()).hexdigest()
(root/'site/installers').mkdir(exist_ok=True)
(root/f'site/installers/{digest}.sh').write_text(script)
bootstrap='''#!/bin/sh
set -eu
setup=$(mktemp -d "${TMPDIR:-/tmp}/glass-setup.XXXXXX")
trap 'rm -rf "$setup"' 0
curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120 'https://metalnakls.github.io/glass/installers/DIGEST.sh' -o "$setup/install.sh"
printf '%s  %s\\n' 'DIGEST' "$setup/install.sh" | shasum -a 256 -c -
/bin/bash "$setup/install.sh" "$@"
'''.replace('DIGEST',digest)
(root/'site/install.sh').write_text(bootstrap)
print(digest)

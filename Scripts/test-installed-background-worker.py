#!/usr/bin/env python3
"""Exercise the installed watcher using one synthetic torrent, never downloading data."""
import argparse, os, pathlib, plistlib, secrets, string, subprocess, sys, time
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=pathlib.Path, default=pathlib.Path('/Applications/Glass.app'))
parser.add_argument('--label', default='tsmc.glass.downloads')
parser.add_argument('--test-toggle', action='store_true')
args = parser.parse_args()
app = args.app
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleVersion'] == info['CFBundleShortVersionString']
job = subprocess.check_output(['launchctl','print',f'gui/{os.getuid()}/{args.label}'],text=True)
assert 'state = running' in job
assert str(app/'Contents/Library/LoginItems/GlassWorker.app/Contents/MacOS/GlassWorker') in job
suffix = ''.join(secrets.choice(string.ascii_lowercase) for _ in range(10))
name = 'Glass Worker Probe '+suffix
folder = pathlib.Path.home()/'Downloads'
source = folder/('Unprocessed '+suffix+'.torrent')
target = folder/(name+'.torrent')
media = (name+'.mkv').encode()
data = b'd4:infod6:lengthi100e4:name'+str(len(media)).encode()+b':'+media+b'12:piece lengthi16384e6:pieces20:'+b'0'*20+b'ee'
assert not source.exists() and not target.exists()
try:
    if args.test_toggle:
        subprocess.run([str(app/'Contents/MacOS/Glass'),'--disable-background-worker'],check=True)
        time.sleep(1)
    source.write_bytes(data)
    if args.test_toggle:
        time.sleep(3)
        assert source.exists() and not target.exists(), 'Disabled worker still renamed the fixture'
        subprocess.run([str(app/'Contents/MacOS/Glass'),'--enable-background-worker'],check=True)
    deadline = time.monotonic()+45
    while time.monotonic()<deadline and not target.exists(): time.sleep(.2)
    assert target.exists(), 'Installed worker did not rename fixture'
    assert not source.exists(), 'Source was not moved'
    assert target.read_bytes()==data, 'Torrent contents changed'
    print(f'Installed {info["CFBundleVersion"]} LaunchAgent renamed the Downloads fixture and preserved all bytes.')
finally:
    if args.test_toggle:
        subprocess.run([str(app/'Contents/MacOS/Glass'),'--enable-background-worker'],check=False)
    source.unlink(missing_ok=True)
    target.unlink(missing_ok=True)

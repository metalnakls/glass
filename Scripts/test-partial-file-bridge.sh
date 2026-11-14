#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRANSMISSION_SOURCE="${GLASS_TRANSMISSION_SOURCE:-$ROOT_DIR/Vendor/transmission/source}"
TRANSMISSION_BUILD="${GLASS_TRANSMISSION_BUILD:-$ROOT_DIR/.build/libtransmission/Debug}"
TEST_DIR="$(mktemp -d /tmp/glass-partial-bridge.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$TEST_DIR" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1]); folder=root/'payload'/'Album'; folder.mkdir(parents=True)
def enc(v):
    if isinstance(v,int): return b'i'+str(v).encode()+b'e'
    if isinstance(v,bytes): return str(len(v)).encode()+b':'+v
    if isinstance(v,list): return b'l'+b''.join(map(enc,v))+b'e'
    return b'd'+b''.join(enc(k)+enc(v[k]) for k in sorted(v))+b'e'
content=bytes(i%251 for i in range(60000)); piece=16384
files=[{b'length':20000,b'path':[n]} for n in [b'left.flac',b'middle.flac',b'right.flac']]
(root/'test.torrent').write_bytes(enc({b'info':{b'name':b'Album',b'files':files,b'piece length':piece,b'pieces':b''.join(hashlib.sha1(content[i:i+piece]).digest() for i in range(0,len(content),piece))}}))
with (folder/'left.flac.part').open('wb') as f: f.seek(piece); f.write(content[piece:20000])
(folder/'middle.flac').write_bytes(content[20000:40000])
(folder/'right.flac.part').write_bytes(content[40000:3*piece])
PY
clang++ -std=c++20 -fobjc-arc -I "$ROOT_DIR/Apps/Glass" \
    -I "$TRANSMISSION_SOURCE" \
    -I "$TRANSMISSION_SOURCE/third-party/fmt/include" \
    -I "$TRANSMISSION_BUILD/build" \
    "$ROOT_DIR/Tests/GlassNativeTests/PartialFileBridgeTests.mm" \
    "$ROOT_DIR/Apps/Glass/LocalTransmissionBridge.mm" \
    "$TRANSMISSION_BUILD/install/lib/libGlassTransmission.a" \
    -framework Foundation -framework SystemConfiguration -framework Security \
    -lcurl -lz -lbz2 -liconv -lresolv -o "$TEST_DIR/check"
"$TEST_DIR/check" "$TEST_DIR"

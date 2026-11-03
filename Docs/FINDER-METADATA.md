# Finder metadata

Glass preserves payload filenames and contents. Finder presentation is metadata,
not a torrent rename or a deletion.

## Unchecked partial files

The local Transmission bridge hides engine-generated `.part` files for unchecked
files on refresh. These may contain the shared boundary pieces of a selected file.
Their bytes and paths remain available for verification and seeding. Selecting a
file restores its visibility before downloading continues. A small extended
attribute identifies flags owned by Glass, so files already hidden by the user
stay hidden. Completed payloads are not hidden. Restart, move and rename states
are reconciled on refresh; unchanged states avoid repeated filesystem access.

This applies to the embedded local engine. It does not change a remote
Transmission server's storage behavior. Finder's Show Hidden Files option can
still display these files.

## Completed MKV extensions

`TorrentFinderMetadata` checks files belonging to Glass's current torrents in
bounded background batches. It sets Finder's native Hide Extension property on
completed `.mkv` files, including uppercase `.MKV`. The real filename keeps its
extension. Incomplete files, sidecars and other formats are left alone.

Remote files use the existing linked mounted-folder mapping and security-scoped
bookmark, without mounting a share or asking for credentials. Filesystem work has
one serial utility queue, away from UI rendering. Missing, disconnected or
read-only destinations can be retried on later passes. Existing completed torrents
are eligible on launch; ongoing downloads are rechecked as they finish.

The SMB server must support Finder metadata. Finder's global Show all filename
extensions preference can override the individual file flag.

## Downloads worker

The background worker selects prohibited activation before Finder artwork work
initializes AppKit. It does not create a SwiftUI scene. The foreground app retains
its normal activation and document-opening behavior.

## Validation

- `bash Scripts/test-partial-file-visibility.sh`: sparse bytes, Finder flags,
  user-owned flags, re-selection, completion, symlinks and missing paths.
- `bash Scripts/test-partial-file-bridge.sh`: real embedded Transmission verifies
  a selected middle file using hidden adjacent fragments, then reselects/restarts.
  Requires the Debug libtransmission library built by the normal build script.
- SwiftPM `TorrentFinderMetadataTests` and `TorrentGhostIconTests`: extension
  eligibility, mapped paths, unchanged names/bytes, icon preservation. Set
  `GLASS_TEST_SMB_ROOTS` to colon-separated mounted roots to exercise temporary
  fixtures on real shares; without it the SMB test does not access a share.
- The signed app's `--background-worker --background-worker-self-test` checks
  rename/icon work, unchanged torrent bytes and prohibited activation together.

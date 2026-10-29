# Glass file icons

## Report and correction

The experimental glass renderer kept Finder's outer silhouette but discarded
its interior: the file-type glyph, extension label, folded corner and folder
seam. `NativeGlassIcon` now retains a cached detail mask above the native glass.
Rows, file browsers, folder groups, Inspector and folder flights continue to
use that owner. Size, optical insets, rotation, saved Tune values and the
original-artwork switch remain unchanged. Reduce Transparency uses original
monochrome artwork. Tune previews use the same owner on a neutral surface.

`NativeIconGeometry` extracts the mask once per cached native image. It removes
bright paper/colour surfaces using the brightest channel, excludes baked shadows,
and keeps darker details. No per-frame image processing or file I/O is added to
scrolling. The existing 128-pixel row and 512-pixel preview caches remain bounded.

## Torrent ghosts

A `.torrent` file describes another file or folder; its own filename is not
reliable evidence of the payload. `TorrentMetainfoPreview.iconContent` classifies
v1 single-file/multifile and v2 file trees. A multifile torrent remains a folder
when it contains just one file. V2's binary piece-layer keys no longer invalidate
otherwise readable metadata. Existing preview file lists and Smart Rename policy
are preserved; this change does not reinterpret their v2 fallback.

`TorrentGhostIcon` renders on its own actor, away from scrolling and the main
thread, using the same Finder artwork, outline and detail mask. A faint
body and dotted outline distinguish the description from the downloaded item.
Finder artwork is static and neutral so it can sit on light or dark backgrounds;
it cannot contain a live SwiftUI glass effect. File-type artwork comes from
`NSWorkspace`, including types registered by other apps, with a generic fallback.

Two native surfaces use that renderer:

- `GlassThumbnail` is a Quick Look thumbnail extension for exactly
  `org.bittorrent.torrent`. It reads at most 8 MiB, parses off the main actor,
  renders off the main actor, returns a bounded bitmap, and never writes to the source file. Finder decides
  when to request/cache thumbnails; its “Show icon preview” setting applies.
- The existing Downloads worker adds per-file Finder custom icons while doing
  its existing scan. It uses the same authorized folder and service lifecycle.
  It changes resource-fork/Finder metadata only, leaving metainfo bytes and
  info hashes intact. The foreground watcher works while Glass is open; the
  existing standalone background agent remains a debug-only feature.

`TorrentFinderIconWriter` serializes custom-icon writes. A versioned marker and
resource-fork digest make repeat scans idempotent. Existing custom icons, later
user replacements, and user removals are preserved. File modification time is
rechecked after rendering. Unrecognized payloads are left alone. Files outside
Downloads rely on Quick Look; the app does not start scanning other folders.

## Platform references

- [Apple: custom file thumbnails](https://developer.apple.com/documentation/quicklookthumbnailing/providing-thumbnails-of-your-custom-file-types)
- [Apple: per-file custom icons](https://developer.apple.com/documentation/appkit/nsworkspace/seticon(_:forfile:options:))
- [BitTorrent v2 file trees, BEP 52](https://www.bittorrent.org/beps/bep_0052.html)

## Acceptance checks

Check the same folder, MKV, PDF, ZIP and text artwork at row and preview sizes in
both appearances. Native optical bounds, tilts, reduced transparency and saved
Tune settings must survive. Offscreen `ImageRenderer` checks only geometry and
raster detail; it does not establish the appearance of live glass.

Core tests cover payload classification and bounded input. Native tests cover
transparent ghost artwork, retained detail, byte-preserving Finder writes,
idempotence and user-icon preservation. The installed extension must also be
requested through Quick Look, and the worker exercised in an isolated folder.

Validated on 29 October 2026:

- 65 core tests and 3 native icon tests passed (the native tests include multiple
  sizes and tilts); the final focused rerun also passed.
- Signed build and installed app passed strict verification; installed executable
  and thumbnail-extension hashes matched their build products.
- Real Quick Look requests returned centered 256- and 512-pixel thumbnails for
  the same MKV/folder fixtures at 1× and 2×. Actual output was compared on light
  and dark backgrounds. The callback draws in the supplied bitmap's bounds so
  Retina requests cannot shrink the artwork into one quarter of the image.
- The exact installed worker passed its isolated rename, ghost-icon and source
  byte-preservation self-test.

Unverified visually: the live glass compositor, folder-flight transitions and
all saved Tune combinations in the running user window. Offscreen comparison
confirms retained glyphs/folds and optical bounds, not those live effects.

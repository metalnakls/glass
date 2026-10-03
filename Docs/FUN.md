# Fun mode

Keep names, sizes and controls on the normal alignment. Let the artwork feel like a small object resting above that list: about 1.5× its normal size, a stable tilt of at most nine degrees, a small sideways offset and a soft downward shadow. Each torrent keeps its pose when scrolling or refreshing. Posters use a subtle shadow sampled from their artwork; folders keep a neutral shadow. Compact density still stays compact and the grid caps its extra scale.

Fun mode is optional and defaults off. Appearance tuning includes the switch, scale, tilt and coloured-poster-shadow controls. Save includes them in bundled defaults. Preserve the user's saved padding, colours and timing.

With `--tune-appearance`, Command-comma opens Appearance and Command-Shift-comma opens Test Torrents. The two windows also link to each other. The sample window uses the actual list and inspector with an isolated in-memory provider, original pastel posters and a widescreen preview. It includes seasons, nested folders, paused and downloading items, completion and unavailable data. Reset restores the samples; Complete downloads exercises completion states. No sample action invokes the real torrent engine or profile/keychain stores.

Folder flights stay independent of row expansion. Their final destination is measured again after row layout settles, followed by a gentle 180 ms tail from the current presentation position. The native flight and static image use the same cached system artwork and the same fun pose. Handoff reveals the real icons before removing the flight layer.

Future design work: custom glass folder and MKV artwork, more varied poster compositions and a review of real-cache poster treatment. Keep these as replaceable native image assets; no ongoing rendering loop or custom shader is required for the current design.

Validation: 114 tests pass; canonical build, signing and installation succeed. Both shortcuts and the populated sample list/inspector were checked in the installed app. The final animation feel still needs hands-on tuning.

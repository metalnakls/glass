# Glass Product Spec

Glass is a quiet macOS desktop client for Transmission RPC servers. It should feel native in the same family as Finder, Mail, and Notes: system-owned chrome, predictable selection, toolbar customization, source-list sidebar, detail list, and attached inspector.

## Primary Workflows

- Manage multiple remote Transmission profiles with credentials stored in Keychain.
- Refresh torrents manually or automatically while reusing the same RPC session token per profile.
- Add magnet links from the toolbar, menu, Cmd+V, or `magnet:` open events.
- Add `.torrent` files from the toolbar, menu, file open, or drag/drop.
- Move source `.torrent` files to Trash only after the server successfully accepts them.
- Start, pause, verify, reannounce, prioritize, queue-move, rename, remove, and delete torrent data.
- Inspect server stats, torrent facts, files, peers, trackers, pieces, and settings.

## Native UI Requirements

- One native title only.
- No fake chrome, custom window frame mutation, fake toolbar rows, or layout-owned AppKit views.
- Root scene uses `WindowGroup`.
- Main window uses `NavigationSplitView` for sidebar/detail.
- Inspector is attached with SwiftUI `.inspector`.
- Torrent list starts as native `List(selection:)` with native context menus, keyboard selection, and swipe actions where available.
- Toolbar uses SwiftUI `.toolbar(id:)` for customization. Filter belongs to the main/detail toolbar.
- On macOS 27 and newer, the top scroll edge uses `.scrollEdgeEffectStyle(.soft, for: .top)` on the actual scrollable list.

## Backend Requirements

- Keep Transmission raw status values while exposing typed status helpers.
- Downloading filter follows Transmission status `4`, not current transfer speed.
- Queued/running state remains separate from downloading state so queued torrents can still stop.
- Fetch `queuePosition`.
- Support queue move RPCs, session settings get/set, free-space fallback, and session token reuse.
- Coalesce overlapping refreshes per profile.
- Merge fresh torrent snapshots by server order while reusing unchanged values.

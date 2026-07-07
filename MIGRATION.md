# Glass Migration

This is a temporary migration/provenance note. Durable structure belongs in `ARCHITECTURE.md`.

## Current State

`~/glass` is the clean Glass repository on `main`, with no Transmission history.

The private GitHub remote is:

```text
git@github.com:USER/glass.git
```

`~/trans` stays intact as the Transmission/upstream reference checkout. Keep using it for upstream source inspection and fetches, but do not use it as the active Glass working tree.

## Codex Project

Use `~/glass` as the active Codex project from here on.

That keeps search, build commands, git status, and patches scoped to the new app. When old Transmission or previous Glass code is needed, reference it explicitly by absolute path under `~/trans`.

Do not keep doing app rebuild work from `~/trans`; that repo is now reference material.

## Migration Boundary

The old Glass UI experiments were intentionally not copied forward as the frontend foundation.

Carried forward:

- Transmission RPC models and client behavior.
- Profile and credential persistence.
- Backend refresh/cache/action behavior.
- Import parsing and source-file cleanup semantics.
- Product requirements from the native Glass work.

Not carried forward:

- Old `GlassRootView`.
- Old torrent row/list layout.
- Fake chrome experiments.
- Fake toolbar/header views.
- Layout-owned AppKit representables.
- Dirty `~/trans` frontend churn.

The fresh app keeps the feature stack but rebuilds placement through native SwiftUI surfaces.

## Product Requirements

Glass is a quiet macOS desktop client for Transmission RPC servers. It should feel native in the same family as Finder, Mail, and Notes: system-owned chrome, predictable selection, toolbar customization, source-list sidebar, detail list, and attached inspector.

Primary workflows:

- Manage multiple remote Transmission profiles with credentials stored in Keychain.
- Refresh torrents manually or automatically while reusing the same RPC session token per profile.
- Add magnet links from the toolbar, menu, Cmd+V, or `magnet:` open events.
- Add `.torrent` files from the toolbar, menu, file open, or drag/drop.
- Move source `.torrent` files to Trash only after the server successfully accepts them.
- Start, pause, verify, reannounce, prioritize, queue-move, rename, remove, and delete torrent data.
- Inspect server stats, torrent facts, files, peers, trackers, pieces, and settings.

Native UI requirements:

- One native title only.
- No fake chrome, custom window frame mutation, fake toolbar rows, or layout-owned AppKit views.
- Root scene uses `WindowGroup`.
- Main window uses `NavigationSplitView` for sidebar/detail.
- Inspector is attached with SwiftUI `.inspector`.
- Torrent list starts as native `List(selection:)` with native context menus, keyboard selection, and swipe actions where available.
- Toolbar uses SwiftUI `.toolbar(id:)` for customization. Filter belongs to the main/detail toolbar.
- On macOS 27 and newer, the top scroll edge uses `.scrollEdgeEffectStyle(.soft, for: .top)` on the actual scrollable list.

Backend requirements:

- Keep Transmission raw status values while exposing typed status helpers.
- Downloading filter follows Transmission status `4`, not current transfer speed.
- Queued/running state remains separate from downloading state so queued torrents can still stop.
- Fetch `queuePosition`.
- Support queue move RPCs, session settings get/set, free-space fallback, and session token reuse.
- Coalesce overlapping refreshes per profile.
- Merge fresh torrent snapshots by server order while reusing unchanged values.

## Upstream Reference

Fetch upstream Transmission only in the old checkout:

```sh
git -C ~/trans fetch --all --tags
```

Glass should not add Transmission as a git remote unless there is a very specific reason. Keeping `~/trans` as the reference checkout avoids mixing unrelated histories.

Backend material was lifted behavior-preserving from the Glass package inside `~/trans/glass` during the fresh rebuild.

`mveinot/transmission-control` was reviewed as a modern Transmission RPC reference. Useful backend ideas carried into this direction are explicit queue RPC support, centralized session-token reuse, update coalescing, and cleanup only after successful `torrent-add`.

## Build Commands

Package tests:

```sh
swift test --package-path ~/glass
```

Package executable:

```sh
swift build --package-path ~/glass --product GlassMac
```

Signed debug app:

```sh
GLASS_CODESIGN_IDENTITY=DEVELOPMENT_SIGNING_IDENTITY \
  ~/glass/Scripts/build-mac-app.sh debug
```

The real app bundle is:

```text
~/glass/.build/Xcode/Build/Products/Debug/Glass.app
```

The old manual bundle path `~/glass/.build/Glass.app` is obsolete and should not reappear.

## App Target Rules

- `Apps/Glass/Glass.xcodeproj` owns the packaged macOS app.
- `Apps/Glass/Transmission_Tahoe.icon` is the app icon source of truth.
- Do not generate or commit `.icns`.
- Do not bring back manual app-bundle assembly.
- Do not move old frontend files back into the new app.
- Layout, toolbar, sidebar, list, inspector, and chrome stay SwiftUI-owned.
- AppKit is allowed only for narrow platform adapters such as lifecycle, pasteboard, open-file hooks, keychain, and file trashing.

## Next Work

After switching Codex to `~/glass`, use feature branches for substantial work:

```sh
git -C ~/glass switch -c ui-native-shell
```

Keep `~/trans` clean enough to fetch upstream and compare implementation details, but do not commit Glass work there.

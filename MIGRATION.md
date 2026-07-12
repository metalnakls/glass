# Glass Migration

This is a temporary migration/provenance note. Durable structure belongs in `README.md`.

## Current State

`/Users/wsb/glass` is the clean Glass repository on `main`, with no Transmission history.

The private GitHub remote is:

```text
git@swagless:metalnakls/glass.git
```

`/Users/wsb/trans` stays intact as the Transmission/upstream reference checkout. Keep using it for upstream source inspection and fetches, but do not use it as the active Glass working tree.

Use this file for temporary migration/provenance and `README.md` for the durable project map.

## Codex Project

Use `/Users/wsb/glass` as the active Codex project from here on.

That keeps search, build commands, git status, and patches scoped to the new app. When old Transmission or previous Glass code is needed, reference it explicitly by absolute path under `/Users/wsb/trans`.

Do not keep doing app rebuild work from `/Users/wsb/trans`; that repo is now reference material.

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
- Dirty `/Users/wsb/trans` frontend churn.

The fresh app keeps the feature stack but rebuilds placement through native SwiftUI surfaces.

## Product Requirements

Glass is a quiet macOS desktop client for local torrents and remote Transmission RPC servers. It should feel native in the same family as Finder, Mail, and Notes: system-owned chrome, predictable selection, toolbar customization, source-list sidebar, detail list, and attached inspector.

Primary workflows:

- Download local torrents through an embedded libtransmission session owned by Glass, without requiring Transmission.app or `transmission-daemon`.
- Manage multiple remote Transmission profiles with credentials stored in Keychain.
- Refresh torrents automatically at a quiet two-second cadence while reusing the same RPC session token per profile.
- Add magnet links from the toolbar, menu, Cmd+V, or `magnet:` open events to the selected source.
- Add `.torrent` files from the toolbar, menu, file open, or drag/drop to the selected source.
- Move source `.torrent` files to Trash only after the selected source successfully accepts them.
- Start, pause, verify, reannounce, prioritize, queue-move, rename, remove, and delete torrent data.
- Inspect torrent facts, files, peers, trackers, pieces, and settings.

Native UI requirements:

- One native title only.
- No fake chrome, custom window frame mutation, fake toolbar rows, or layout-owned AppKit views.
- Root scene uses `WindowGroup`.
- Main window uses `NavigationSplitView` for sidebar/detail.
- Inspector is attached with SwiftUI `.inspector`.
- Torrent list uses the native macOS 27 `ScrollView` + `LazyVStack` + `swipeActionsContainer()` path, with context menus, keyboard selection, and swipe actions.
- The detail leaf owns its standard SwiftUI toolbar and title. The inspector is attached to the complete split view.
- On macOS 27 and newer, the top scroll edge uses `.scrollEdgeEffectStyle(.soft, for: .top)` on the actual scrollable list.

Backend requirements:

- Keep Transmission raw status values while exposing typed status helpers.
- Downloading filter follows Transmission status `4`, not current transfer speed.
- Queued/running state remains separate from downloading state so queued torrents can still stop.
- Fetch `queuePosition`.
- Support queue move RPCs, session settings get/set, free-space fallback, and session token reuse.
- Coalesce overlapping refreshes per profile.
- Merge fresh torrent snapshots by server order while reusing unchanged values.
- Do not republish equal snapshots or perform cache file writes on every two-second poll.
- Keep the local source keyed by its source ID in the same cache/history paths as remote profiles.
- Local source behavior is libtransmission-backed, not loopback RPC to `127.0.0.1:9091`.

## Upstream Reference

Fetch upstream Transmission only in the old checkout:

```sh
git -C /Users/wsb/trans fetch --all --tags
```

Glass should not add Transmission as a git remote unless there is a very specific reason. Keeping `/Users/wsb/trans` as the reference checkout avoids mixing unrelated histories.

Backend material was lifted behavior-preserving from the Glass package inside `/Users/wsb/trans/glass` during the fresh rebuild.

The old tree also contains iOS intent and iOS-target residue:

- `/Users/wsb/trans/glass/README.md` describes `apps/Glass` as an iOS app target.
- `/Users/wsb/trans/glass/apps/Glass/Glass.xcodeproj` contains `IPHONEOS_DEPLOYMENT_TARGET`.
- The same old app entry currently imports AppKit, so it is not a clean source of truth.

Treat the old iOS material as requirements/provenance only. Rebuild the iOS app as a native iOS target in the fresh repo instead of copying that target forward.

`mveinot/transmission-control` was reviewed as a modern Transmission RPC reference. Useful backend ideas carried into this direction are explicit queue RPC support, centralized session-token reuse, update coalescing, and cleanup only after successful `torrent-add`.

## Build Commands

Package tests:

```sh
swift test --package-path /Users/wsb/glass
```

Signed debug app:

```sh
GLASS_CODESIGN_IDENTITY=2D7A6CBCAA6173CA3FC1904539A19C9800B39B78 \
  /Users/wsb/glass/Scripts/build-mac-app.sh debug
```

The real app bundle is:

```text
/Users/wsb/glass/.build/Xcode/Build/Products/Debug/Glass.app
```

The old manual bundle path `/Users/wsb/glass/.build/Glass.app` is obsolete and should not reappear.

Local libtransmission source is pinned by:

```text
/Users/wsb/glass/Vendor/transmission/REVISION
```

The build script fetches `Vendor/transmission/source` inside `/Users/wsb/glass`. `/Users/wsb/trans` remains reference/provenance only and is not a build input.

## App Target Rules

- `Apps/Glass/Glass.xcodeproj` owns the packaged macOS app.
- A future iOS app target should be native iOS, not Catalyst.
- The macOS and iOS app targets should share core/services and reusable SwiftUI code, but each target owns its own scene setup and platform adapters.
- `Apps/Glass/Transmission_Tahoe.icon` is the app icon source of truth.
- Do not generate or commit `.icns`.
- Do not bring back manual app-bundle assembly.
- Do not move old frontend files back into the new app.
- Layout, toolbar, sidebar, list, inspector, and chrome stay SwiftUI-owned.
- AppKit is allowed only for narrow platform adapters such as lifecycle, pasteboard, open-file hooks, keychain, and file trashing.
- UIKit follows the same rule for iOS: narrow adapters only, not shared flow/layout/business logic.

## Cross-Platform Handoff

Copy/paste this block when starting the next implementation pass:

```text
Work in /Users/wsb/glass, not /Users/wsb/trans. /Users/wsb/trans is only the upstream/reference checkout.

Glass is a native SwiftUI app family:
- macOS target: Apps/Glass.
- future iOS target: rebuild as native iOS, not Catalyst.
- do not copy old frontend files or the old mixed iOS/AppKit target.

Keep shared code honest:
- GlassRemoteCore: Transmission models, RPC client, profile/credential abstractions.
- GlassRemoteServices: provider orchestration, refresh coalescing, client pooling, source cleanup.
- GlassRemoteUI: reusable SwiftUI views and UI state that are actually shared.
- platform targets: scene setup, commands, toolbar placement, file/open-url/pasteboard/device adapters.

Avoid broad #if os(...) hacks in shared logic. If behavior differs by platform, inject an adapter protocol from the app target.

Do not split TransmissionRPCClient just because it is long. Split only if separating real responsibilities: transport/session-token retry, RPC DTOs, and high-level method surface.

Do not split RemoteAppModel just for tidiness. The useful next split is provider-driven:
- GlassAppModel owns selected source, source list, cross-source commands, and shared undo/toast state.
- TorrentProvider is the common interface for remote and local torrent sources.
- RemoteTorrentProvider wraps current Transmission RPC behavior.
- LocalTorrentProvider wraps the embedded local libtransmission session.

Local wiring is a product requirement. Glass should handle local torrent downloads and remote Transmission RPC profiles in one app.
```

## Next Work

After switching Codex to `/Users/wsb/glass`, use feature branches for substantial work:

```sh
git -C /Users/wsb/glass switch -c ui-native-shell
```

Keep `/Users/wsb/trans` clean enough to fetch upstream and compare implementation details, but do not commit Glass work there.

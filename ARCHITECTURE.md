# Architecture

Glass is a fresh macOS app. The tree is split by runtime responsibility, not by old Transmission source layout or old Glass UI experiments.

## Layout

- `Apps/Glass`: packaged macOS app target, bundle metadata, signing settings, and `Transmission_Tahoe.icon`.
- `Sources/GlassRemoteCore`: pure Transmission RPC/backend primitives.
- `Sources/GlassRemoteServices`: app-facing state and remote orchestration.
- `Sources/GlassRemoteUI`: SwiftUI views and UI-only helpers.
- `Tests`: core and service tests.
- `Scripts`: build wrappers.
- `Resources`: shared app resources referenced by the app target, currently entitlements.

There should be no lowercase `script/` directory and no manual app-bundle assembly path.

## Modules

The three library modules are intentional:

- `GlassRemoteCore` owns value types, Codable mapping, profile persistence protocols, credential protocols, and `TransmissionRPCClient`.
- `GlassRemoteServices` owns `RemoteAppModel`: profile CRUD, per-profile client pooling, refresh coalescing, cached snapshots, action-triggered refresh, and `.torrent` source cleanup.
- `GlassRemoteUI` owns SwiftUI presentation and calls services. It does not own RPC, profile persistence, keychain, trashing, or session-token policy.

This split keeps the UI rebuild from contaminating backend tests. If the app stays small after the native UI settles, `Core` and `Services` can be collapsed later.

## Backend

The RPC client centralizes Transmission session-id retry behavior. A single client actor is kept per profile by the services layer so sequential refresh/action calls reuse the token.

The service layer exposes `TransmissionRPCServicing` only for tests and service isolation. Production uses `TransmissionRPCClient`.

## UI

`GlassRemoteUI` composes:

- `GlassRootView`: scene composition, toolbar, importer, drag/drop, sheets, inspector attachment.
- `ProfileSidebarView`: native source-list sidebar.
- `TorrentListView`: native selectable torrent list.
- `TorrentInspectorView`: attached inspector content and controls.
- Dialog views for profile, magnet, and rename workflows.

SwiftUI is the layout and chrome owner. AppKit must not own titlebar layout, toolbar placement, split-view geometry, list layout, or inspector attachment.

## App Target

`Apps/Glass/Glass.xcodeproj` is the real macOS app target. It owns the bundle identifier, Info.plist, entitlements reference, document and URL registrations, signing configuration, and Icon Composer app icon package at `Apps/Glass/Transmission_Tahoe.icon`.

`Scripts/build-mac-app.sh` delegates to that Xcode target. It does not manually assemble an app bundle or generate legacy icon resources.

## Platform Adapters

`Apps/Glass` is the only app target that imports AppKit for app lifecycle and pasteboard/open-file hooks. Keychain lives behind `CredentialStore`; file trashing lives behind `TorrentSourceFileDisposing`.

Seeing `AppKit-*.pcm` under `.build/Xcode/ModuleCache.noindex` is expected. It is a compiler cache, not app source. macOS SwiftUI itself depends on AppKit, and the app target uses narrow AppKit adapters for lifecycle, open-file, and pasteboard integration.

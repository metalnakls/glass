# Glass

Glass is a fresh native SwiftUI app family. The current repo starts with the macOS app, but the architecture must leave room for a rebuilt native iOS app without Catalyst and without copying business logic.

The tree is split by runtime responsibility, not by old Transmission source layout or old Glass UI experiments.

## Layout

- `Apps/Glass`: packaged macOS app target, bundle metadata, signing settings, `Transmission_Tahoe.icon`, and the narrow libtransmission bridge for local downloads.
- Future `Apps/GlassIOS`: native iOS app target. Rebuild it from the old iOS requirements and workflows, not from the old broken mixed AppKit/UIKit target.
- `Sources/GlassRemoteCore`: Transmission value types, RPC/backend primitives, and profile/credential abstractions.
- `Sources/GlassRemoteServices`: app-facing state, provider orchestration, refresh coalescing, client pooling, and source cleanup.
- `Sources/GlassRemoteUI`: SwiftUI views and UI-only helpers.
- `Tests`: core and service tests.
- `Scripts`: build wrappers, including the pinned libtransmission source build.
- `Vendor/transmission`: pinned Transmission source metadata. `Vendor/transmission/source` is fetched by the build script and is not committed.
- `Resources`: shared app resources referenced by the app target, currently entitlements.

There should be no lowercase `script/` directory and no manual app-bundle assembly path.

## Modules

The three library modules are intentional:

- `GlassRemoteCore` owns value types, Codable mapping, profile persistence protocols, credential protocols, and `TransmissionRPCClient`.
- `GlassRemoteServices` owns `RemoteAppModel`: source selection, provider routing, profile CRUD, per-profile client pooling, refresh coalescing, cached snapshots, action-triggered refresh, and `.torrent` source cleanup.
- `GlassRemoteUI` owns SwiftUI presentation and calls services. It does not own RPC, profile persistence, keychain, trashing, or session-token policy.

This split keeps the UI rebuild from contaminating backend tests. If the app stays small after the native UI settles, `Core` and `Services` can be collapsed later.

Do not split files just to make them small. `TransmissionRPCClient.swift` can stay large while it is one coherent RPC surface. A split is useful only when it separates real responsibilities, such as transport/session-token retry, request/response DTOs, and high-level torrent/session methods.

`RemoteAppModel` should not be split for aesthetics either. The useful split is product-driven: keep the provider boundary so remote Transmission servers and local torrents are peers.

Provider direction:

- `GlassAppModel`: selected source, source list, cross-source commands, shared undo/toast state.
- `TorrentProvider`: common protocol for listing torrents, refreshing, adding imports, and running torrent actions.
- `RemoteTorrentProvider`: current Transmission RPC-backed behavior.
- `LocalTorrentProvider`: local torrents managed by Glass through an embedded libtransmission session, not through loopback RPC.
- platform adapters: pasteboard, document import, file trash, local device identity, keychain/security.

## Backend

Remote profiles use Transmission RPC. The RPC client centralizes Transmission session-id retry behavior. A single client actor is kept per profile by the services layer so sequential refresh/action calls reuse the token.

The local source is “This Mac, managed by Glass.” It starts an in-process libtransmission session from the macOS app target, persists local session state under Glass app support, and adds magnet links or `.torrent` data directly to that session. It must work without Transmission.app or `transmission-daemon` running.

The service layer exposes `TransmissionRPCServicing` only for tests and service isolation. Production uses `TransmissionRPCClient`.

The app target exposes local libtransmission through `LocalTransmissionSession` and `LocalTransmissionBridge`. AppKit/Objective-C++ are allowed there only as narrow platform and C++ adapters; shared services remain source-agnostic.

## UI

`GlassRemoteUI` composes:

- `GlassRootView`: scene composition, toolbar, importer, drag/drop, sheets, inspector attachment.
- `ProfileSidebarView`: native source-list sidebar.
- `TorrentListView`: native selectable torrent list.
- `TorrentInspectorView`: attached inspector content and controls.
- Dialog views for profile, magnet, and rename workflows.

SwiftUI is the layout and chrome owner. AppKit must not own titlebar layout, toolbar placement, split-view geometry, list layout, or inspector attachment.

Shared SwiftUI code should contain behavior, state transitions, formatting, row content, dialogs, and command intent wherever the platform pattern is the same. Platform targets own scene setup and native placement.

Avoid broad `#if os(...)` branches in shared modules. When platform behavior differs, prefer protocols injected from the app target. Narrow availability checks for APIs such as macOS-only scroll edge styling are fine when they stay local to the surface using the API.

## App Target

`Apps/Glass/Glass.xcodeproj` is the real macOS app target. It owns the bundle identifier, Info.plist, entitlements reference, document and URL registrations, signing configuration, and Icon Composer app icon package at `Apps/Glass/Transmission_Tahoe.icon`.

`Scripts/build-mac-app.sh` delegates to that Xcode target. It does not manually assemble an app bundle or generate legacy icon resources.

The future iOS app should be a separate native iOS target, not Catalyst. It should link the same core/services packages and reuse shared SwiftUI components where the platform interaction model actually matches.

## Platform Adapters

`Apps/Glass` is the only app target that imports AppKit for app lifecycle and pasteboard/open-file hooks. Keychain lives behind `CredentialStore`; file trashing lives behind `TorrentSourceFileDisposing`.

Seeing `AppKit-*.pcm` under `.build/Xcode/ModuleCache.noindex` is expected. It is a compiler cache, not app source. macOS SwiftUI itself depends on AppKit, and the app target uses narrow AppKit adapters for lifecycle, open-file, and pasteboard integration.

For iOS, UIKit should follow the same rule: only narrow platform adapters such as pasteboard, document import/open-url handling, device identity, and security prompts. UIKit must not own shared app flow, torrent rows, source navigation, or business logic.

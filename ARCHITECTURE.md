# Architecture

Glass is split by responsibility rather than by old UI experiments.

## Core

`GlassRemoteCore` owns value types, Codable mapping, profile persistence protocols, credential protocols, and `TransmissionRPCClient`.

The RPC client centralizes Transmission session-id retry behavior. A single client actor is kept per profile by the services layer so sequential refresh/action calls reuse the token.

## Services

`GlassRemoteServices` owns `RemoteAppModel`, which coordinates:

- profile CRUD and credential persistence
- per-profile RPC client pooling
- refresh coalescing
- cached/stale torrent snapshots
- server free-space fetch and fallback behavior
- torrent actions and action-triggered refresh
- `.torrent` source cleanup after successful add

The service layer exposes a `TransmissionRPCServicing` protocol only for tests and service isolation. Production uses `TransmissionRPCClient`.

## UI

`GlassRemoteUI` is SwiftUI-only. It composes:

- `GlassRootView`: scene composition, toolbar, importer, drag/drop, sheets, inspector attachment
- `ProfileSidebarView`: native source-list sidebar
- `TorrentListView`: native selectable torrent list
- `TorrentInspectorView`: attached inspector content and controls
- dialog views for profile, magnet, and rename workflows

The UI calls services; it does not own RPC, profile persistence, keychain, trashing, or session-token policy.

## Platform Adapters

`GlassMac` is the only target that imports AppKit for app lifecycle and pasteboard/open-file hooks. Keychain lives behind `CredentialStore`; file trashing lives behind `TorrentSourceFileDisposing`.

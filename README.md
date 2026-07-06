# Glass

Glass is a fresh macOS-first Transmission remote client.

This repository intentionally starts without Transmission history or source tree. `/Users/wsb/trans` remains the reference checkout for upstream Transmission and the older Glass experiments.

## Build

```sh
swift test
swift build --product GlassMac
./Scripts/build-mac-app.sh debug
```

The app target is package-first. `Scripts/build-mac-app.sh` wraps the SwiftPM product in a signed macOS `.app` bundle with the Glass bundle identifier, document type support for `.torrent`, and the `magnet:` URL scheme.

## Shape

- `GlassRemoteCore`: Transmission RPC models, request surface, profile store, credential store.
- `GlassRemoteServices`: remote app model, refresh/cache behavior, profile client pooling, source-file cleanup.
- `GlassRemoteUI`: native SwiftUI views only.
- `GlassMac`: macOS executable target and narrow platform adapters.

AppKit is limited to app lifecycle, pasteboard, document opening, keychain, and file trashing. Layout, toolbar, sidebar, list, inspector, and chrome are SwiftUI.

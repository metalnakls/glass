# Glass

Glass is a fresh macOS-first Transmission remote client.

This repository intentionally starts without Transmission history or source tree. `/Users/wsb/trans` remains the reference checkout for upstream Transmission and the older Glass experiments.

## Build

```sh
swift test
swift build --product GlassMac
./Scripts/build-mac-app.sh debug
```

The packaged app is owned by `Apps/Glass/Glass.xcodeproj`. That target owns the bundle identifier, entitlements, document type support for `.torrent`, the `magnet:` URL scheme, and the app icon. `Scripts/build-mac-app.sh` is only a thin wrapper around the Xcode app build.

## Shape

- `GlassRemoteCore`: Transmission RPC models, request surface, profile store, credential store.
- `GlassRemoteServices`: remote app model, refresh/cache behavior, profile client pooling, source-file cleanup.
- `GlassRemoteUI`: native SwiftUI views only.
- `Apps/Glass`: signed macOS app target, Info.plist, entitlements reference, and `Transmission_Tahoe.icon`.
- `GlassMac`: SwiftPM executable target for package-level builds and narrow platform adapters.

AppKit is limited to app lifecycle, pasteboard, document opening, keychain, and file trashing. Layout, toolbar, sidebar, list, inspector, and chrome are SwiftUI.

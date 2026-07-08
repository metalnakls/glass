# Agents

## Build And Signing

Use the wrapper for signed macOS app builds:

```sh
GLASS_CODESIGN_IDENTITY=DEVELOPMENT_SIGNING_IDENTITY \
  ~/glass/Scripts/build-mac-app.sh debug
```

The wrapper builds:

- project: `~/glass/Apps/Glass/Glass.xcodeproj`
- scheme: `Glass`
- configuration: `Debug` or `Release`
- derived data: `~/glass/.build/Xcode`

It forces manual signing with:

- `CODE_SIGN_STYLE=Manual`
- `CODE_SIGN_IDENTITY=$GLASS_CODESIGN_IDENTITY`

After building, it verifies the bundle with:

```sh
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
```

Debug app output:

```text
~/glass/.build/Xcode/Build/Products/Debug/Glass.app
```

If `GLASS_CODESIGN_IDENTITY` is not set, the script tries the first local `Apple Development:` identity from:

```sh
security find-identity -v -p codesigning
```

Bundle metadata:

- bundle id: `org.transmissionbt.glass.mac`
- entitlements: `~/glass/Resources/Glass.entitlements`

Run SwiftPM tests with: swift test --package-path ~/glass --disable-sandbox

# Agents

## Build And Signing

Use the wrapper for signed macOS app builds:

```sh
GLASS_CODESIGN_IDENTITY=2D7A6CBCAA6173CA3FC1904539A19C9800B39B78 \
  /Users/wsb/glass/Scripts/build-mac-app.sh debug
```

The wrapper builds:

- project: `/Users/wsb/glass/Apps/Glass/Glass.xcodeproj`
- scheme: `Glass`
- configuration: `Debug` or `Release`
- derived data: `/Users/wsb/glass/.build/Xcode`

It forces manual signing with:

- `CODE_SIGN_STYLE=Manual`
- `CODE_SIGN_IDENTITY=$GLASS_CODESIGN_IDENTITY`

After building, it verifies the bundle with:

```sh
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
```

Debug app output:

```text
/Users/wsb/glass/.build/Xcode/Build/Products/Debug/Glass.app
```

If `GLASS_CODESIGN_IDENTITY` is not set, the script tries the first local `Apple Development:` identity from:

```sh
security find-identity -v -p codesigning
```

Bundle metadata:

- bundle id: `tsmc.glass`
- entitlements: `/Users/wsb/glass/Resources/Glass.entitlements`

Run SwiftPM tests with: swift test --package-path /Users/wsb/glass --disable-sandbox

# Automatic updates

Glass uses Sparkle 2 and publishes update artifacts from this repository's GitHub Releases.

## One-time setup

Make `metalnakls/glass` public before shipping the first update.

Add these GitHub Actions secrets:

- `MACOS_CERTIFICATE_P12`: base64 of your exported Developer ID Application .p12
- `MACOS_CERTIFICATE_PASSWORD`: password used when exporting the .p12
- `DEVELOPER_ID_APPLICATION`: exact identity, e.g. `Developer ID Application: Name (TEAMID)`
- `APPLE_ID`: Apple ID used for notarization
- `APPLE_APP_PASSWORD`: app-specific password from appleid.apple.com
- `APPLE_TEAM_ID`: Apple Developer Team ID
- `SPARKLE_PUBLIC_ED_KEY`: output of Sparkle's `generate_keys`
- `SPARKLE_PRIVATE_ED_KEY`: Sparkle private EdDSA key

No extra update repository or GitHub PAT is required. The workflow uses the repository's built-in `GITHUB_TOKEN`.

## Sparkle key

Use Sparkle's bundled `generate_keys` tool once on your Mac. Keep the private key private. Put the printed public key in `SPARKLE_PUBLIC_ED_KEY`, and export the private key for CI as `SPARKLE_PRIVATE_ED_KEY`.

## Certificate

In Keychain Access, export the **Developer ID Application** certificate together with its private key as a password-protected .p12, then:

```sh
base64 -i DeveloperID.p12 | pbcopy
```

Paste that value into `MACOS_CERTIFICATE_P12`.

## Shipping

Every push to `main` runs the release workflow. A successful run signs + notarizes Glass and creates a GitHub Release containing both the update ZIP and `appcast.xml`.

Installed copies read the stable feed URL:

```
https://github.com/metalnakls/glass/releases/latest/download/appcast.xml
```

Sparkle checks hourly and handles update installation/relaunch.

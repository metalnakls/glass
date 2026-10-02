# Automatic updates

Glass uses Sparkle 2. Source code stays private in `metalnakls/glass`; update artifacts are published from the public `metalnakls/glass-updates` repository.

## One-time setup

Create a **public** GitHub repository named `glass-updates` with a `main` branch.

Add these GitHub Actions secrets to the private `glass` repository:

- `MACOS_CERTIFICATE_P12`: base64 of your exported Developer ID Application .p12
- `MACOS_CERTIFICATE_PASSWORD`: password used when exporting the .p12
- `DEVELOPER_ID_APPLICATION`: exact identity, e.g. `Developer ID Application: Name (TEAMID)`
- `APPLE_ID`: Apple ID used for notarization
- `APPLE_APP_PASSWORD`: app-specific password from appleid.apple.com
- `APPLE_TEAM_ID`: Apple Developer Team ID
- `SPARKLE_PUBLIC_ED_KEY`: output of Sparkle's `generate_keys`
- `SPARKLE_PRIVATE_ED_KEY`: Sparkle private EdDSA key
- `UPDATES_REPO_TOKEN`: fine-grained GitHub PAT with Contents: Read/Write for `metalnakls/glass-updates`

## Sparkle key

Use Sparkle's bundled `generate_keys` tool once on your Mac. Keep the private key private. Put the printed public key in `SPARKLE_PUBLIC_ED_KEY`, and export the private key for CI as `SPARKLE_PRIVATE_ED_KEY`.

## Certificate

In Keychain Access, export the **Developer ID Application** certificate together with its private key as a password-protected .p12, then:

```sh
base64 -i DeveloperID.p12 | pbcopy
```

Paste that value into `MACOS_CERTIFICATE_P12`.

## Shipping

After this branch is merged, every push to `main` runs the release workflow. A successful run signs + notarizes Glass, creates a public release in `glass-updates`, and replaces `appcast.xml`. Installed copies check the feed hourly and Sparkle handles the update/relaunch flow.

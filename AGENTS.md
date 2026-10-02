# Agents

For build/install changes, follow the global `app-build-install-scripts` and `macos-app-signing` skills. The project workflow is implemented in [Scripts/build-mac-app.sh](Scripts/build-mac-app.sh).

## Git delivery

When a turn changes project files and all required validation succeeds, commit only that turn's files and push the commit to the current branch's configured upstream. Routine pushes to this private repository are authorized. Choose a concise commit name automatically, then ask whether the user wants it changed; push once the name is settled. If renamed, amend only before pushing. Preserve unrelated work, never force-push or rewrite published history, and stop to report if validation or the push fails. A user request not to push for a specific turn takes precedence.

## Local build and install

Run the one local build/install command:

```sh
./Scripts/build-mac-app.sh debug
```

The script builds and signs one app with the required identity, strictly verifies it, then updates the contents of `/Applications/Glass.app` in place with `ditto`. It strictly verifies the installed app and restores the previous contents if installation verification fails. Before updating an existing app, it retains the previous app at `.app-backups/Glass.app.backup` inside the repository (the directory is gitignored). A normal build never removes backups. Cleanup is explicit only:

```sh
./Scripts/build-mac-app.sh cleanup-backups
```

Ordinary local signing uses an Apple Development identity from the signing keychain. No identity is hardcoded. On first use the script lists the Apple Development identities in the keychain and asks which one to use; the choice is saved to the gitignored, machine-local `.signing-identity` and reused until that identity stops being available. Set `GLASS_CODESIGN_IDENTITY` to override the saved choice for a single build. The script never selects a different identity on its own.

Run SwiftPM tests with: swift test --package-path . --disable-sandbox

## Versioning and releases

Glass uses a single version number for both `CFBundleVersion` and `CFBundleShortVersionString`, set through the `GLASS_VERSION` build setting. Sparkle compares `CFBundleVersion`, so it must rise for every release or no update is offered.

Local builds derive a date-based version (`YYYYMMDDHHMM`) so debugging never modifies the repository. Releases pass an explicit `GLASS_VERSION`.

Bump rules:

- Small fixes and incremental work are point releases. Pick the next sensible number and commit it; do not ask.
- Big features and breaking changes are major releases. Ask before shipping one.
- There is no marketing version. If `12.42` is the next sensible number, use it.

The version bump is its own commit and always ships with the release.

Releases are unsigned: no Developer ID certificate, no Apple notarization, no stapling. Sparkle signs updates with EdDSA using `SPARKLE_PRIVATE_ED_KEY` from GitHub Secrets, and the matching `SPARKLE_PUBLIC_ED_KEY` is injected at build time. Because releases are unsigned, users must open the app once from Finder after installing an update.

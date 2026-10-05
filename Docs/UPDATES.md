# Automatic updates

Glass updates itself with [Sparkle](https://sparkle-project.org). Releases are
published from this Mac because the app needs the macOS 27 SDK for APIs such as
`swipeActionsContainer()`, which no GitHub-hosted runner ships.

Releases are **not** signed with a Developer ID certificate and are **not**
notarized. Sparkle still verifies every update with EdDSA, so a tampered download
is rejected. Because the app is unsigned, macOS quarantines the download the
first time.

## Publishing a release

Bump `VERSION`, build, then release:

```sh
printf '2.2\n' > VERSION
./Scripts/release.sh
```

`Scripts/release.sh` builds the app, verifies its signature, zips it to a
stable `Glass.zip`, signs it with Sparkle EdDSA, writes `appcast.xml`, and
publishes a GitHub Release. The EdDSA private key is read from the login
Keychain, so the export from earlier setups is no longer needed.

## Secrets

The EdDSA private key lives in the login Keychain, not in the repository and not
in a plaintext file. `release.sh` reads it directly:

```sh
security find-generic-password -a ed25519 -s https://sparkle-project.org -w
```

`SPARKLE_PRIVATE_ED_KEY` still overrides the Keychain when it is set, for CI or
one-off runs. Before signing, `release.sh` derives the public key half from the
private seed and compares it with the `SUPublicEDKey` baked into the app. A
mismatch aborts the release, because an update signed with the wrong key is
rejected by Sparkle at install time rather than at download time.

The matching public key is embedded in the app at build time through the
`SPARKLE_PUBLIC_ED_KEY` build setting. Local builds that lack it simply run
without the updater rather than failing to verify anything.

No Apple certificates, no notarization secrets, and no extra update repository
are required.

## Versioning

The release version lives in the `VERSION` file at the repository root and feeds
both `CFBundleVersion` and `CFBundleShortVersionString` through the
`GLASS_VERSION` build setting. Sparkle decides what is newer by comparing
`CFBundleVersion`, so the number must rise for every release.

- Small fixes are point releases. Pick the next sensible number without asking.
- Big features and breaking changes are major releases. Ask first.
- There is no separate marketing version.

Local builds derive a date-based version (`YYYYMMDDHHMM`) so debugging never
modifies the repository.

## The update feed

Installed copies read the stable feed URL:

```
https://github.com/metalnakls/glass/releases/latest/download/appcast.xml
```

The download asset is always named `Glass.zip`, so the link never changes.
Glass checks hourly and installs and relaunches updates on its own.

## First launch

Because releases are unsigned, open the app once from Finder, or clear the
quarantine flag:

```sh
xattr -cr /Applications/Glass.app
```

The quarantine flag is reapplied on each update, so this is once per version.

## CI

There is no hosted CI. The macOS app cannot be built on GitHub runners because
they lack the macOS 27 SDK, and the `swift test` workflow was removed with it.
Run the package tests locally before releasing:

```sh
swift test --package-path . --disable-sandbox
```

## Appearance updates without an app release

In a `--tune` build, use **Save**, keeping the default project JSON destination.
Then publish only the appearance config:

```sh
./Scripts/push-tunes --check  # validate without network or publishing
./Scripts/push-tunes
```

This commits only the saved config on `main` and pushes it on an allowed even
minute. It leaves unrelated staged and working-tree changes alone and refuses
to push unrelated local commits. Synchronize `main` first if it has diverged.
It never changes `VERSION`, builds release assets, or invokes Sparkle.
App releases happen only when `Scripts/release.sh` is run; tuning commits do
not trigger an app release.

Glass fetches the public GitHub config on launch and checks again on activation
at most once per day. **Glass → Update Appearance** checks immediately. Changes
apply live and replace local values for published keys, including tuning edits.
Cached published values are reapplied on launch. Reset uses the latest remote
defaults. Valid config is cached for offline launches; missing or invalid config
keeps the last valid values, falling back to bundled defaults on first launch.
Only known appearance keys, booleans, finite bounded numbers, and hex colours
are accepted. This is HTTPS configuration delivery, separate from Sparkle's
signed application updates.

Older app versions that read the former `tunes` branch need the 4.2 app update
to switch to the config on `main`. The old branch is retained for compatibility. Publishing config requires an explicit invocation;
building, saving, and committing do not publish it.

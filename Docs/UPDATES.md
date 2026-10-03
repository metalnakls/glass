# Automatic updates

Glass updates itself with [Sparkle](https://sparkle-project.org). Releases are
built by GitHub Actions on every push to `main`, signed with Sparkle's EdDSA key,
and published as a GitHub Release that also carries `appcast.xml`.

Glass releases are **not** signed with a Developer ID certificate and are **not**
notarized. There is no Apple notarization step and no Apple secrets in CI. Sparkle
still verifies every update with EdDSA, so a tampered download is rejected. Because
the app itself is unsigned, macOS Gatekeeper asks the user to open Glass once from
Finder after installing an update.

## One-time setup

Make this repository public, then add one GitHub Actions secret:

- `SPARKLE_PUBLIC_ED_KEY`: the public key printed by Sparkle's `generate_keys`
- `SPARKLE_PRIVATE_ED_KEY`: the matching private key

No extra update repository, no personal access token, and no Apple certificates are
required. The workflow uses the repository's built-in `GITHUB_TOKEN`.

## Sparkle keys

Generate a key pair once with Sparkle's bundled tool:

```sh
find ~/Library/Developer/Xcode/DerivedData -name generate_keys -type f -perm +111 | head -1
```

Put the printed public key in the `SPARKLE_PUBLIC_ED_KEY` secret. Export the private
key for CI as `SPARKLE_PRIVATE_ED_KEY`, and keep a copy somewhere safe. Losing the
private key means losing the ability to sign updates.

## Versioning

The release version lives in the `VERSION` file at the repository root and feeds
both `CFBundleVersion` and `CFBundleShortVersionString` through the `GLASS_VERSION`
build setting. Sparkle decides what is newer by comparing `CFBundleVersion`, so the
number must rise for every release.

Every push to `main` publishes a release, so bump `VERSION` in the same commit as
the change you want to ship.

- Small fixes are point releases. Pick the next sensible number without asking.
- Big features and breaking changes are major releases. Ask first.
- There is no separate marketing version.

## How a release runs

1. `.github/workflows/release.yml` reads `VERSION`
2. It builds Release with an ad-hoc signature and the injected public key
3. It zips `Glass.app` and signs the ZIP with `sign_update`
4. It creates a GitHub Release containing the ZIP and `appcast.xml`

Installed copies read the stable feed URL:

```
https://github.com/metalnakls/glass/releases/latest/download/appcast.xml
```

Glass checks hourly and installs and relaunches updates on its own.

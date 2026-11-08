# Automatic updates

Glass updates itself with [Sparkle](https://sparkle-project.org). Releases are
published from this Mac because the app needs the macOS 27 SDK for APIs such as
`swipeActionsContainer()`, which no GitHub-hosted runner ships.

Releases are **not** signed with a Developer ID certificate and are **not**
notarized. Sparkle still verifies every update with EdDSA, so a tampered download
is rejected. Because the app is unsigned, macOS quarantines the download the
first time.

## Publishing a release

Reserve and commit one version when preparing an authorized release, reusing any
already reserved version. Then run the release script:

```sh
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

- Individual fixes, local commits/builds, and Tune updates do not change `VERSION`.
- Reserve the next point version once for an authorized release batch. Keep an
  already reserved version through subsequent fixes and release interruptions.
  A pending 8.7 stays 8.7 until published; its follow-up fixes do not become 8.8–8.10.
- Advance again only after publication, unless the user explicitly changes the target.
- Big features and breaking changes are major releases. Ask first.
- There is no separate marketing version.

Local builds derive a date-based version (`YYYYMMDDHHMM`) so debugging never
modifies the repository.

Before building, `Scripts/release.sh` checks GitHub's latest published release
and the first differing `VERSION` committed since it. A later accidental bump
blocks publication. Restore the first reserved value in a new commit to correct
it; neither published history nor existing releases need to be rewritten.
`python3 Scripts/check-release-version.py --repo metalnakls/glass` runs that check
without building or publishing. A failed lookup stops the check rather than
assuming there is no previous release. Source pushes alone do not publish apps.
If the user explicitly names a different target, pass that exact value through
`GLASS_REQUESTED_RELEASE_VERSION`; a plain “release” request never authorizes this override.

## The update feed

Installed copies read the stable feed URL:

```
https://glass.metalglass.workers.dev
```

The Worker passes through the appcast hosted on GitHub Releases. Its private D1
`installations` table keeps one current row per random installation ID: Glass
version, macOS version, Mac model identifier, first report, first report of the
current Glass version, and latest report. `POST /installations` accepts reports;
there is no public read endpoint. Query the table through the Metal Cloudflare
account (`flare` database):

```sql
SELECT installation_id, app_version, mac_model, os_version,
       version_first_seen, last_reported
FROM installations ORDER BY version_first_seen DESC;
```

The older `weekly_install_checks` table remains for legacy clients.

Glass reports at first foreground launch and when version, OS, or model changes.
Successful unchanged reports are suppressed. Failures retry on a later launch or
activation, with a one-minute in-process backoff. The preferences UUID identifies
an installation, not a person or guaranteed physical Mac. `version_first_seen`
is server receipt time, not exact install time. See the [privacy page](../site/privacy.html).

The download asset is always named `Glass.zip`. Glass checks hourly and installs
and relaunches updates on its own; installation reporting is independent of
Sparkle's optional weekly profile. Existing clients need a new app release to
start reporting. A local install does not publish the app or privacy page.

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

Debug builds always include the tuner; release builds never include it.
Use **View → Appearance…** (⌘,) and **Save**, keeping the default project JSON destination.
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
Known keys with supported values are applied individually. Unknown keys and
unsupported values are skipped, so one value does not discard the rest of a
saved Tune. This is HTTPS configuration delivery, separate from Sparkle's
signed application updates.

Older app versions that read the former `tunes` branch need the 4.2 app update
to switch to the config on `main`. The old branch is retained for compatibility. Publishing config requires an explicit invocation;
building, saving, and committing do not publish it.

## One-command installation

The public page follows the Minecraft installer flow:

```sh
curl -fsSL https://metalnakls.github.io/glass/install.sh | sh
```

The bootstrap verifies the SHA-256 of a content-addressed installer. That
installer pins one published release and verifies the app archive and worker
installer before changing the installation. It uses only macOS built-in tools,
backs up an existing app, installs to /Applications/Glass.app, applies ad-hoc
signing through the worker installer, registers the per-user LaunchAgent, and
opens Glass. Failed replacement restores the previous app and worker plist.
Verified downloads are cached for retries. No sudo or Finder automation is used.

The release script refreshes the Pages pins after publication. To regenerate
them independently:

```sh
python3 Scripts/prepare-pages-installer.py v10.1  # use the newly published tag
```

Commit `site/install.sh` and the newly generated `site/installers/<sha256>.sh`
together. Existing content-addressed installers stay available to bootstraps
that were already downloaded. Pages deployment verifies these pins before
uploading the site. This changes installer distribution, not the app version.

Unsigned releases use a separate, sandboxed Downloads worker. macOS rejects an
ad-hoc helper launched through SMAppService even when registration reports
success, so the installer uses `~/Library/LaunchAgents/tsmc.glass.downloads.plist`.
The main app does not run the watcher. Its enable/disable control communicates
with the worker. The worker continues when Glass closes.

The standalone `install-background-worker.sh` release asset remains available
for existing app installations and supports removal:

```sh
bash install-background-worker.sh uninstall
```

Release validation must exercise the installed LaunchAgent with Glass both open
and closed. A successful registration or direct helper self-test alone is
insufficient. `--verify-only` on the unified installer checks downloads without
changing the app; `--release-dir` accepts already-downloaded, checksum-matching
release assets for offline verification.

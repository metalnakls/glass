# Glass Migration

## Current State

`/Users/wsb/glass` is the new clean Glass repository. It starts fresh on `main` with no Transmission history.

`/Users/wsb/trans` stays intact as the Transmission/upstream reference checkout. Keep using it for upstream source inspection and fetches, but do not use it as the active Glass working tree.

Current local Glass commits:

- `glass`: fresh repo, backend/service/UI scaffold
- `icon`: real macOS Xcode app target with `Transmission_Tahoe.icon`

## Codex Project

Use `/Users/wsb/glass` as the active Codex project from here on.

That keeps search, build commands, git status, and patches scoped to the new app. When old Transmission or previous Glass code is needed, reference it explicitly by absolute path under `/Users/wsb/trans`.

Do not keep doing app rebuild work from `/Users/wsb/trans`; that repo is now reference material.

## Git Setup

The local repo is already initialized:

```sh
git -C /Users/wsb/glass status
git -C /Users/wsb/glass log --oneline --decorate --max-count=8
```

The only missing setup is the remote.

For an existing empty GitHub repo:

```sh
git -C /Users/wsb/glass remote add origin git@github.com:USER/glass.git
git -C /Users/wsb/glass push -u origin main
```

If `origin` already exists:

```sh
git -C /Users/wsb/glass remote set-url origin git@github.com:USER/glass.git
git -C /Users/wsb/glass push -u origin main
```

With GitHub CLI, create and push a new repo:

```sh
gh repo create glass --private --source /Users/wsb/glass --remote origin --push
```

Use `--public` instead of `--private` only if the repo should be public.

## Upstream Reference

Fetch upstream Transmission only in the old checkout:

```sh
git -C /Users/wsb/trans fetch --all --tags
```

Glass should not add Transmission as a git remote unless there is a very specific reason. Keeping `/Users/wsb/trans` as the reference checkout avoids mixing unrelated histories.

See `UPSTREAM.md` for provenance and reference rules.

## Build Commands

Package tests:

```sh
swift test --package-path /Users/wsb/glass
```

Package executable:

```sh
swift build --package-path /Users/wsb/glass --product GlassMac
```

Signed debug app:

```sh
GLASS_CODESIGN_IDENTITY=2D7A6CBCAA6173CA3FC1904539A19C9800B39B78 \
  /Users/wsb/glass/Scripts/build-mac-app.sh debug
```

The real app bundle is:

```text
/Users/wsb/glass/.build/Xcode/Build/Products/Debug/Glass.app
```

The old manual bundle path `/Users/wsb/glass/.build/Glass.app` is obsolete and should not reappear.

## App Target Rules

- `Apps/Glass/Glass.xcodeproj` owns the packaged macOS app.
- `Apps/Glass/Transmission_Tahoe.icon` is the app icon source of truth.
- Do not generate or commit `.icns`.
- Do not bring back manual app-bundle assembly.
- Do not move old frontend files back into the new app.
- Layout, toolbar, sidebar, list, inspector, and chrome stay SwiftUI-owned.
- AppKit is allowed only for narrow platform adapters such as lifecycle, pasteboard, open-file hooks, keychain, and file trashing.

## Next Work

After switching Codex to `/Users/wsb/glass`, use feature branches for substantial work:

```sh
git -C /Users/wsb/glass switch -c ui-native-shell
```

Keep `/Users/wsb/trans` clean enough to fetch upstream and compare implementation details, but do not commit Glass work there.

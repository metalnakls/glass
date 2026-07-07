# Glass Migration

## Current State

`~/glass` is the new clean Glass repository. It starts fresh on `main` with no Transmission history.

`~/trans` stays intact as the Transmission/upstream reference checkout. Keep using it for upstream source inspection and fetches, but do not use it as the active Glass working tree.

Current local Glass commits:

- `glass`: fresh repo, backend/service/UI scaffold
- `icon`: real macOS Xcode app target with `Transmission_Tahoe.icon`

## Codex Project

Use `~/glass` as the active Codex project from here on.

That keeps search, build commands, git status, and patches scoped to the new app. When old Transmission or previous Glass code is needed, reference it explicitly by absolute path under `~/trans`.

Do not keep doing app rebuild work from `~/trans`; that repo is now reference material.

## Git Setup

The local repo is already initialized:

```sh
git -C ~/glass status
git -C ~/glass log --oneline --decorate --max-count=8
```

The only missing setup is the remote.

For an existing empty GitHub repo:

```sh
git -C ~/glass remote add origin git@github.com:USER/glass.git
git -C ~/glass push -u origin main
```

If `origin` already exists:

```sh
git -C ~/glass remote set-url origin git@github.com:USER/glass.git
git -C ~/glass push -u origin main
```

With GitHub CLI, create and push a new repo:

```sh
gh repo create glass --private --source ~/glass --remote origin --push
```

Use `--public` instead of `--private` only if the repo should be public.

## Upstream Reference

Fetch upstream Transmission only in the old checkout:

```sh
git -C ~/trans fetch --all --tags
```

Glass should not add Transmission as a git remote unless there is a very specific reason. Keeping `~/trans` as the reference checkout avoids mixing unrelated histories.

See `UPSTREAM.md` for provenance and reference rules.

## Build Commands

Package tests:

```sh
swift test --package-path ~/glass
```

Package executable:

```sh
swift build --package-path ~/glass --product GlassMac
```

Signed debug app:

```sh
GLASS_CODESIGN_IDENTITY=DEVELOPMENT_SIGNING_IDENTITY \
  ~/glass/Scripts/build-mac-app.sh debug
```

The real app bundle is:

```text
~/glass/.build/Xcode/Build/Products/Debug/Glass.app
```

The old manual bundle path `~/glass/.build/Glass.app` is obsolete and should not reappear.

## App Target Rules

- `Apps/Glass/Glass.xcodeproj` owns the packaged macOS app.
- `Apps/Glass/Transmission_Tahoe.icon` is the app icon source of truth.
- Do not generate or commit `.icns`.
- Do not bring back manual app-bundle assembly.
- Do not move old frontend files back into the new app.
- Layout, toolbar, sidebar, list, inspector, and chrome stay SwiftUI-owned.
- AppKit is allowed only for narrow platform adapters such as lifecycle, pasteboard, open-file hooks, keychain, and file trashing.

## Next Work

After switching Codex to `~/glass`, use feature branches for substantial work:

```sh
git -C ~/glass switch -c ui-native-shell
```

Keep `~/trans` clean enough to fetch upstream and compare implementation details, but do not commit Glass work there.

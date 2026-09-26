# Agents

For build/install changes, follow the global [app-build-install-scripts](/Users/wsb/.codex/skills/app-build-install-scripts/SKILL.md) and [macos-app-signing](/Users/wsb/.codex/skills/macos-app-signing/SKILL.md) skills. The project workflow is implemented in [Scripts/build-mac-app.sh](Scripts/build-mac-app.sh).

## Local build and install

Run the one local build/install command:

```sh
GLASS_CODESIGN_IDENTITY=919F9538E1E91B7C10FD2556CC9030B76ED39E58 \
  /Users/wsb/glass/Scripts/build-mac-app.sh debug
```

The script builds and signs one app with the required identity, strictly verifies it, then updates the contents of `/Applications/Glass.app` in place with `ditto`. It strictly verifies the installed app and restores the previous contents if installation verification fails. Before updating an existing app, it retains a timestamped backup at `/Applications/Glass.app.backup-YYYYMMDD-HHMMSS` (a numeric suffix is added on collision). A normal build never removes backups. Cleanup is explicit only:

```sh
/Users/wsb/glass/Scripts/build-mac-app.sh cleanup-backups
```

Ordinary local signing requires Apple Development identity `919F9538E1E91B7C10FD2556CC9030B76ED39E58`; the wrapper stops if it is unavailable or another identity is supplied.

Run SwiftPM tests with: swift test --package-path /Users/wsb/glass --disable-sandbox

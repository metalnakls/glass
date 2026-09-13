# Agents

## Local build and install

Run the one local build/install command:

```sh
GLASS_CODESIGN_IDENTITY=919F9538E1E91B7C10FD2556CC9030B76ED39E58 \
  /Users/wsb/glass/Scripts/build-mac-app.sh debug
```

The wrapper builds and strictly verifies the final app, then installs it at `/Applications/Glass.app`. If that wrapper exists, its contents are refreshed in place with `ditto`; the previous wrapper is retained as `/Applications/Glass.app.backup-YYYYMMDD-HHMMSS`. Backups are never removed by a normal build. Cleanup is explicit only:

```sh
/Users/wsb/glass/Scripts/build-mac-app.sh cleanup-backups
```

Ordinary local signing requires Apple Development identity `919F9538E1E91B7C10FD2556CC9030B76ED39E58`; the wrapper stops if it is unavailable or another identity is supplied.

For build-script, CI/CD, certificate, identity, and signing diagnostics, follow the global [`app-build-install-scripts`](/Users/wsb/.codex/skills/app-build-install-scripts/SKILL.md) and [`macos-app-signing`](/Users/wsb/.codex/skills/macos-app-signing/SKILL.md) skills.

Run SwiftPM tests with: swift test --package-path /Users/wsb/glass --disable-sandbox

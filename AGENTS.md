# Agents

For build/install changes, follow the global [app-build-install-scripts](~/.codex/skills/app-build-install-scripts/SKILL.md) and [macos-app-signing](~/.codex/skills/macos-app-signing/SKILL.md) skills. The project workflow is implemented in [Scripts/build-mac-app.sh](Scripts/build-mac-app.sh).

## Git delivery

When a turn changes project files and all required validation succeeds, commit only that turn's files and push the commit to the current branch's configured upstream. Routine pushes to this private repository are authorized. Choose a concise commit name automatically, then ask whether the user wants it changed; push once the name is settled. If renamed, amend only before pushing. Preserve unrelated work, never force-push or rewrite published history, and stop to report if validation or the push fails. A user request not to push for a specific turn takes precedence.

## Local build and install

Run the one local build/install command:

```sh
GLASS_CODESIGN_IDENTITY=DEVELOPMENT_SIGNING_IDENTITY \
  ~/glass/Scripts/build-mac-app.sh debug
```

The script builds and signs one app with the required identity, strictly verifies it, then updates the contents of `/Applications/Glass.app` in place with `ditto`. It strictly verifies the installed app and restores the previous contents if installation verification fails. Before updating an existing app, it retains the previous app at `.app-backups/Glass.app.backup` inside the repository (the directory is gitignored). A normal build never removes backups. Cleanup is explicit only:

```sh
~/glass/Scripts/build-mac-app.sh cleanup-backups
```

Ordinary local signing requires Apple Development identity `DEVELOPMENT_SIGNING_IDENTITY`; the wrapper stops if it is unavailable or another identity is supplied.

Run SwiftPM tests with: swift test --package-path ~/glass --disable-sandbox

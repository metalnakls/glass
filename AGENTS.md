# Agents

For build/install changes, follow the global `app-build-install-scripts` and `macos-app-signing` skills. The project workflow is implemented in [Scripts/build-mac-app.sh](Scripts/build-mac-app.sh).

Run `Scripts/build-mac-app.sh` outside the sandbox (escalated). Sandboxed runs cannot read the login keychain, so `security find-identity` falsely reports `0 valid identities` and the script aborts with "No Apple Development signing identity was found". The identities do exist; do not re-investigate or re-derive them. Escalate the build instead.

## Git delivery

When a turn changes project files and all required validation succeeds, commit only that turn's files. Choose a concise commit name automatically, then ask whether the user wants it changed; amend only when renaming is requested and before pushing. Preserve unrelated work, never force-push or rewrite published history, and stop to report if validation fails.

Never push without an explicit yes in the conversation. Commit locally, then ask. `Scripts/build-mac-app.sh` prints a push reminder after four build/install runs without a push, and repeats it every three runs after that; when that reminder appears, ask the user whether to push and list the unpushed commits. A user request not to push for a specific turn always takes precedence.

When a turn changes repository files, finish that turn with a local commit. Do not defer versioning to a later cleanup session. Stage only the files belonging to the active task and preserve unrelated dirty-worktree changes. Never commit secrets or machine-local configuration.

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

The release version lives in the `VERSION` file at the repository root. Local builds derive a date-based version (`YYYYMMDDHHMM`) so debugging never modifies the repository.

Local commits and pushes do not allocate app versions or publish releases.
Only `Scripts/release.sh` publishes an app release; Tune publication is separate.

Bump rules:

- Do not change `VERSION` for individual fixes, local commits, builds, tests, or Tune updates.
- When the user requests a release, reserve one point version for the whole unreleased batch, in one preparation commit. If an unreleased version is already reserved, keep it through every follow-up fix, pause, and resumed release. For example, fixes to a pending 8.7 remain 8.7, never 8.8, 8.9, or 8.10.
- Advance again only after that version has actually been published, or when the user explicitly requests a different version. Never renumber an already published release.
- Big features and breaking changes are major releases. Ask before shipping one.
- There is no marketing version. If `12.42` is the next sensible number, use it.

See `Docs/UPDATES.md` for the release pipeline.
The release script checks the first reserved version against the latest published
release before building. If it rejects an accidental second bump, restore the
reserved value in a new commit; do not rewrite published history or bypass the check.
Use `GLASS_REQUESTED_RELEASE_VERSION` only for an exact version explicitly named
by the user, never to work around an accidental bump or a plain “release” request.

Releases are unsigned: no Developer ID certificate, no Apple notarization, no stapling. Sparkle signs updates with EdDSA using the private key in the login Keychain (`-a ed25519 -s https://sparkle-project.org`), and the matching `SPARKLE_PUBLIC_ED_KEY` is injected at build time. Because releases are unsigned, users must open the app once from Finder after installing an update.

## Shared interface conventions

For UI layout, controls, animation, Tune, or presentation changes, read
[Docs/DESIGN-SYSTEM.md](Docs/DESIGN-SYSTEM.md) before editing. It defines component
owners, variants, and protected behavior. For the current list/import recovery,
also read [Docs/UI-RECOVERY-PLAN.md](Docs/UI-RECOVERY-PLAN.md). A plan does not
authorize implementation after the user asks to stop.

### Required workflow

1. State the requested change and existing behavior it must preserve. Read the
   relevant recent conversation, current diff, shared owner, and callers. When
   the user says it worked before, locate the relevant history before choosing a
   replacement. An old commit is evidence, not automatically a safe app rollback.
2. Identify one owner for the faulty behavior and a falsifiable cause. Record
   the observed failure, proposed change, and affected variants. If the cause is
   uncertain, use a focused reproduction before changing production code.
3. Reuse the existing component. If a real use case needs different behavior,
   add a named semantic variant and migrate its callers. Screen code supplies
   data, actions, and variants; the component owns styling, padding, hit targets,
   and motion.
4. Make one coherent correction. A spacing request does not authorize changing
   sticky release timing, selection, row identity, scroll ownership, or import
   lifecycle. A structural change requires a written reason and checks for every
   affected behavior. Ask before changing an established interaction.
5. Validate the reported failure and the affected sibling variants. For visual
   work, compare the same content, dimensions, scroll position, appearance, and
   saved Tune values. Build/test success establishes compilation and tested
   behavior only. Report anything not observed as unverified.
6. If a correction causes another regression, stop stacking fixes. Compare the
   failed delta with the baseline, update the diagnosis, and repair or withdraw
   that delta without reverting unrelated work. Resume with an explanation of
   why the next change addresses the evidence.

### Native components and layout ownership

- Use native SwiftUI/AppKit controls, selection, keyboard, focus, rename, drag,
  scrolling, and accessibility semantics. Preserve hybrid List ownership. A
  custom implementation needs a concrete unmet requirement and one shared owner.
- Start with default stack spacing, `.padding()`, and native row/content margins.
  Custom values belong in named shared metrics with a reason, scope, and units,
  or approved Tune overrides. Moving a magic number into an enum does not by
  itself justify that number.
- Own each inset once. Distinguish component interior, row columns, document
  margins, and sticky viewport inset. Never compensate for one layer with a
  second layer's padding, negative offsets, masks, or duplicated safe areas.
- Keep native row separators; headers have none. Main-list rules span the
  text/metadata region, excluding artwork and the state control. Derive bounds
  from the same row geometry as the content.
- Use named variants instead of screen-specific copies or growing collections
  of booleans. Share parts when structure differs; do not force torrent rows and
  file rows into one universal view.
- Tune edits the shared owner's value immediately. Each control has a precise
  label, unit, default, range, and documented effect. Preserve saved user values;
  migrate changed meanings explicitly rather than resetting preferences.
- Native glass controls own internal padding and the full clickable area.
  Decorative effects pass input through. Motion remains interruptible, respects
  Reduce Motion, and never delays the action it represents. Keep original filename case.

### Ask instead of inventing

Ask a concise question with two or three concrete choices when intended
appearance/behavior is ambiguous, a reference cannot be established, requirements
conflict, or native behavior cannot satisfy a requested custom effect. State the
uncertainty and recommend an option. Await the answer for dependent work; continue
only independent work. Do not infer a new product requirement from one screenshot
or invent a draft/session to preserve.

### Completion and delivery

List passed and unverified acceptance checks. A design system is complete only
when its declared callers use it and its variants have been checked. Validate
runtime fixes before replacing the installed app where tooling permits, then
verify the exact installed build. A restart needs a stated purpose; prefer an
isolated fixture for repeated experiments. Documentation-only turns require
document validation, not app builds or restarts. Commit only validated current-task
files; preserve pre-existing unfinished source changes. Never push automatically.

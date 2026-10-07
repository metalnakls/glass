# UI recovery plan — 7 October 2026

Status: main-list recovery authorized after the audit, with a Sol sub-agent
requested for implementation. Start with stages 1–3 and the shared owners they
affect. Broader migration and import verification remain separate checkpoints.
Interrupted source changes remain unvalidated work, not an accepted baseline.

## Why the recent turns regressed

1. **Established behavior changed outside the request.** `d6cf155` changed the
   sticky inset from 20 to zero while adding blur. `d1cd133` replaced the two-item
   release boundary with the next header's boundary while introducing the system.
   These explain two repeatedly reported regressions.
2. **Ownership remained split.** `TorrentListView` combines title padding, native
   row insets, content margins and a safe-area bar. `TorrentStickyHeaders` caches
   anchor geometry and positions titles independently. Moving a constant into
   `GlassDesignSystem.swift` did not consolidate that contract.
3. **The component layer is incomplete.** Screens still construct an update glass
   button and row-column offsets. Grid titles have another style. Separators
   accept caller-calculated geometry, so cannot keep themselves aligned when
   rows change. A wrapper inventory was called a finished system too early.
4. **Tests missed production wiring.** Geometry tests explicitly pass
   `topInset: 20` while production passed zero. The early-release test supplies
   a boundary instead of protecting the controller's two-row calculation. Its
   name still mentions fade/blur despite the sharp-title requirement. Passing
   212 tests did not establish native separators, Tune invalidation or appearance.
5. **Experiments reached the installed app before assumptions were settled.**
   Separator modifiers were tried on branches, containers and the whole ForEach.
   The last running build lost all dividers. That shows the attempted policy
   failed; it does not prove a general macOS rule about separator ownership.
6. **Comparison state was unstable.** Restarts, scroll offsets, saved Tune values,
   cached measurements and patches changed together. The interrupted tool call
   partly edited source. Source and installed build are not equivalent evidence.

These are process and implementation failures. Constants and comments alone
cannot prevent them. The new AGENTS workflow requires a baseline, preserved
contracts, one owner per decision, named variants and explicit acceptance checks.

## Recovery order

### 1. Establish the reference

Inventory the unfinished source delta and exact installed build. Establish
header inset, row geometry and two-item release behavior individually from
history and accepted screenshots; do not revert the whole app to a commit with
other known defects. Record window size, density, appearance, scroll position
and relevant Tune values. Preserve user data and preferences.

Exit: each L1–L7 contract in DESIGN-SYSTEM.md has a reference or an explicit user
decision. History supports the former 20-point pin inset and two-item rule; it
does not prove that every initial-spacing layer is correct.

### 2. Reproduce native List behavior

Use a focused fixture with headers and 1-, 2-, 3-, and many-row sections on the
target OS, including the same List/reorder path as production. Establish where
separator visibility, tint and alignment apply. Check header boundaries,
selection, first and last rows. Observe actual row/header/viewport frames and
reproduce Tune changes after the view is visible.

Exit: native rules appear only where required, endpoints are measured, and a
specific cause explains each failure. No further guess-and-install cycle.

### 3. Repair the main list in separate checkpoints

1. **Row geometry and rules:** one owner supplies artwork, text/metadata and
   state-control columns. Native separators use those bounds. Restore row rules,
   remove header rules, and center content between boundaries.
2. **Header policy:** retain the hybrid controller; consolidate its pin inset,
   short-section eligibility and two-item release rule. Preserve one sharp title
   above native blur through forward/reverse handoff. Refresh measurements from
   actual layout changes.
3. **Tune spacing:** implement the distinct meanings in DESIGN-SYSTEM.md. Verify
   before-first, below-header, between-sections and after-last settings separately
   at defaults and the user's saved values.

Pass each checkpoint's visual/input checks before starting the next. Commit
validated corrections separately. Remove superseded modifiers within the same
checkpoint instead of accumulating compensating padding or overlays.

### 4. Complete shared component contracts

Audit callers against the owner table. Add semantic variants for real differences:
search expansion, picker content, row density and import state. Keep platform
sizing inside the owner. Migrate divergent callers and remove duplicate geometry.
Check main list, Inspector, Add and Tune wherever the changed owner is used.
Centralize setting definitions and document intentional custom metrics.

Add a focused review/validation check for new duplicated styling and bypasses of
shared components. Scope automated checks to migrated UI and documented exceptions;
a blanket ban on numbers is not a design system.

Exit: changing a shared control reaches all declared callers, with matching size,
input and motion demonstrated for its variants.

### 5. Verify the magnet flow

The separate `magnets` commit must not be rewritten during header repair. Once
the list is stable, verify clipboard import, resolving/ready/error states,
destination selection, early Add, cancellation, metadata completion and Smart
Rename through the shared Add card. Check multiple-card retention. Existing
unit tests do not prove real peer resolution or the visible transition.

### 6. Deliver with evidence

Validate before installing where tooling permits. Use the repository build/sign/
install workflow and identify the exact installed build. Check affected contracts
after launch; report passed and unverified items separately. Keep unfinished
source out of validated feature commits. No automatic push.

## Coverage of recent requests

| Report / correction | Required outcome | Stage |
| --- | --- | --- |
| Title faded, popped, clipped or lost blur | One sharp title, native blur behind it, continuous handoff | 2–3 |
| Header too low, then too close to top | Historical pin inset independent of document spacing | 1–3 |
| First-header Tune value affected the wrong thing | Precise control semantics, live measurements, checked at scroll origin | 2–3 |
| Two-item gap disappeared | Production release rule and separate short-section rule protected | 3 |
| Native rules wanted, but none on titles | Torrent boundaries only; no header-to-first-item rule | 2–3 |
| Dividers too long; items uncentered | Text/metadata span, excluded artwork/state columns, centered content | 3 |
| Controls drifted across screens | One owner per family, named variants, all affected callers checked | 4 |
| Magnet sheet became an unrelated form | Shared card, spinner, location, early Add and eventual naming | 5 |
| Assumed draft and unnecessary computer use | No invented state; observation has a specific purpose | All |

Earlier confirmed worker renaming, location fallback and document-icon work are
regression boundaries, not permission for another redesign. Also preserve
Inspector alignment, full-width search, Tune choices and native click targets.

## Behavioral checks

- Exercise production header configuration and release-boundary calculation,
  rather than supplying desired constants to isolated geometry helpers.
- Use native rendering for separator checks and measured frames for alignment.
  Tests that repeat implementation constants do not protect user behavior.
- Check forward/reverse handoff, resize and group expansion. For shared controls,
  cover light/dark, narrow/wide, keyboard, full hit targets and Reduce Motion.
- Verify each changed Tune binding at a contrasting value, then restore the
  original. Check saved-value reload without resetting preferences.
- Use fixtures for repeated diagnosis. Inspect the user's app only for a specific
  unresolved question or final installed-build verification.

## User decisions

The user has authorized the main-list recovery. Within an approved
step, ask for a missing visual reference, conflicting behavior or a native/custom
tradeoff. Give two or three concrete choices and a recommendation. Never answer
that uncertainty by inventing an interaction or deleting an established one.

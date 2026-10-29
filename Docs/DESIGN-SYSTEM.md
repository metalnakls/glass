# Glass interface contracts

Status: partially implemented. The current wrappers and metrics are a starting
point, not a completed design system. This document defines required behavior;
it does not certify that the app satisfies it. Current gaps and the recovery
order are in [UI-RECOVERY-PLAN.md](UI-RECOVERY-PLAN.md).

## Principles

Native controls own platform behavior and default spacing. Shared components own
the app's deliberate additions. Screens supply content, actions, and semantic
variants. One shared change must reach every declared caller without repeating
the edit on every screen.

A component contract includes layout, input, accessibility, lifecycle, motion,
and persistence where relevant. A style wrapper alone is not that contract.
Preserve SwiftUI List ownership and existing AppKit bridges unless an explicitly
approved requirement needs an architectural change.

## Owners and variants

These are existing owners to consolidate, not parallel replacements to create.
Variants below describe the intended interface, not APIs already implemented.
Add variants only for real callers.

| Concern | Existing owner | Intended variants / inputs | Owner controls |
| --- | --- | --- | --- |
| Actions | `GlassPillButton` | text, icon; enabled, disabled, pending | Native glass, size, interior spacing, full hit target, accessible name |
| Search | `GlassSearchPill` | expandable, always expanded; available-width or constrained | Height, glyph slots, focus, clearing, Escape, transition |
| Choice picker | `GlassMorphingPicker`, `GlassPickerChoice` | section list, destination choices | Glass morph, dismissal, native row spacing, symbol column, keyboard behavior |
| Floating controls | `GlassFloatingDock`, `glassFloatingChrome` | top, bottom, both | Outer placement, safe areas, input pass-through, scroll indicators |
| Add presentation | `GlassAddCard`, `GlassAddHeader`, `GlassModalMetrics` | resolving, ready, failure; one or multiple imports | Stable dimensions, title/location/dock structure across states |
| File browser | `TorrentFilesBrowser`, `TorrentFileRowLabel`, file-list layout support | inspector, add selection | Columns, insets, separators, file interaction, context-specific progress |
| Torrent rows | `TorrentListView`, `TorrentRowView`, `TorrentDraftRow`, `TorrentListRowChrome`, `TorrentListLayout` | existing densities; single/group, selected/unselected, pending/active/completed | Shared row geometry and native separator policy |
| Section titles | `TorrentStickyHeaders`, `StickyTitleLabel` | inline, pinned, outgoing; short/long section; large scroll jump | Measured position, pin inset, two-item release gap, visible current title and direct handoff |
| Scroll effect | `glassScrollEdges`, `HeaderBackdrop` | floating controls; section titles | One native top effect, sharp foreground titles, interruptible exit |
| Settings | `AppearancePreferences`, `GlassAppearanceDefaults`, `GlassTuningSlider`, Tune | saved override or default; explicit units | Native controls, accessible labels/values, key, meaning, units, range, default, owner |
| Artwork | `NativeGlassIcon`, `NativeIconGeometry`, `TorrentGhostIcon`, preview owners | glass/original, document/folder, torrent ghost, artwork, unavailable | Native source, shared optical bounds, readable details, cached rendering, empty state |

### Variant rules

- Use an enum for mutually exclusive states. Avoid boolean combinations that can
  express impossible states; independent options may remain independent.
- Variants select documented behavior, not arbitrary caller-selected padding.
- The rendering owner derives geometry. Callers must not approximate its icon,
  text, or control columns with another set of dimensions.
- Use content slots for differing content. Share parts where structure differs;
  the main torrent list and nested file browser need distinct row types.
- Introducing an owner includes migrating affected callers and removing their
  superseded constants/styles in the same scoped change.

## Protected main-list behavior

| ID | Contract | Evidence required |
| --- | --- | --- |
| L1 | Native torrent-row separators remain; title rows and header-to-first-item boundaries have no rule. | Native List with multiple sections, selected and unselected rows. |
| L2 | Rules start at the text column and end before the state-control column. Contents are centered vertically between row boundaries. | Each supported density and a narrow window. |
| L3 | Pinned titles retain established breathing room. History before `d6cf155` used a 20-point pin inset, separate from the label's 8-point interior. These are historical app values, not Apple defaults. | Accepted reference compared against inline and pinned positions. |
| L4 | An outgoing title begins clearing two displayed rows before the following section. Existing short-section eligibility is a separate rule and also survives. | Forward/reverse scrolling with 1-, 2-, 3-, and many-row sections; production controller policy exercised. |
| L5 | Headers stay fully visible at every scroll speed. A large jump resolves directly to the current section without animating skipped headers through the pinned slot. Inline labels remain visible. | Forward/reverse jumps, native live scrolling, interrupted layout motion and short/long sections. |
| L6 | One native blur surface acts on content behind sharp titles. The main list uses an AppKit header material whose gradient moves with the owning title through exit; other floating controls retain the system scroll-edge effect. No duplicate backdrop or opaque replacement band. | Title exit, fade interruption, light/dark appearance and content passing beneath the title. |
| L7 | Selection, keyboard, rename, group expansion, drag, row identity and state-button actions survive layout changes. | Native input checks with representative rows. |

### Distinct spacing quantities

| Quantity | Meaning | Must not also control |
| --- | --- | --- |
| Before first header | Document space before the first inline title. At scroll origin, changes move the title and following content together. | Sticky inset or later section spacing. |
| Pinned header top inset | Distance from viewport top to the pinned title's measured frame. | Initial document blank space. |
| Below headers | Space after an inline title before its first item. | The title's top position. |
| Between sections | Document spacing before later titles. | Two-item release policy. |
| After last item | Scrollable space after the final row. | Bottom control size or every row's padding. |

Use these semantics in labels/help and implementation. Agree with the user before
changing a setting's meaning. A pinned title stays pinned while document spacing
changes; test the first-header control at scroll origin rather than guessing
from a scrolled screenshot.

Account for native safe-area reservation, row insets and title interior once.
Tune changes invalidate SwiftUI layout and any cached AppKit measurements. An
arbitrary delay or unrelated state toggle is not a permanent invalidation fix.

## Other accepted behavior to protect

- Inspector and Add share the file browser, search, location and dock parts.
  Expanded search fills available width. Location text truncates only when its
  available space is exhausted. Season headers, filenames and sizes use shared
  columns; sizes remain readable.
- Tune uses the shared picker, native row spacing, aligned symbol slots and full
  row targets. Bottom test/reset/save actions remain icons on one row.
- Location and Tune pickers share their glass transition and typography. Discuss
  a native-versus-custom tradeoff before replacing the requested morph.
- Share top progressive blur. Inspector and Add have no bottom blur. Decorative
  floating space passes input through; close/search respond on the first click.
- File and magnet Add share presentation. Cmd-V and Cmd-N begin clipboard magnet
  resolution, show a spinner, and allow destination selection without a magnet
  text box. Early Add retains the destination, resolves metadata, and runs Smart
  Rename. Closing an unsubmitted preview cancels its own work.
- Multiple imports remain visible as queued cards; none disappear silently.
  Pre-add file rows show size/selection, not meaningless download percentages.
- Empty Quick Look uses an empty selection/unavailable state, never a generated
  text-file stand-in. Torrent files use content-aware dotted ghost artwork through
  Quick Look and the Downloads worker; the bundled document icon remains the
  fallback. Shared owners and limits are in [FILE-ICONS.md](FILE-ICONS.md). Wide
  artwork stays centered within its established box.
- Drafts remain selectable native list entries with shared row chrome, separator
  neighbors, swipe removal, and focused Delete/Command-Delete actions. Resolve
  their stable list identity through the draft store; removal discards saved Add
  state without touching a transfer provider or source/downloaded files.
- Preserve confirmed Smart Rename and location fallback behavior. Metadata and
  renaming stay responsive in services with pending/error states. A visual fix
  must not change paths, filesystem data, or these lifecycles.

## Completion criteria

Each declared owner has a small interface, migrated real callers, documented
variants, and evidence for affected behavior. Values have one source; obsolete
caller styles are removed. Both production policy and native rendering are
checked. Until then, report the migration as partial.

## Motion ownership

`GlassMotion` owns fixed SwiftUI timing, named transition variants, and Reduce
Motion policy. Views use `glassMotion(_:value:)` on the specific changed state
and `glassTransition(_:)` for insertion/removal. Explicit state mutations use
`GlassMotion.animation(_:reduceMotion:)`. Do not attach a global animation to
live torrent summaries or change row identity to force a transition.

`BlurReplacementContent` owns semantic label replacement. Add/Stall and location
labels use it in all three Add action layouts and the location picker. Search
owns expansion for buttons, Escape, and external presentation changes. Shared
callers include Inspector docks, Add cards, Tune navigation, list controls,
row state feedback, file preview, location feedback, and undo presentation.

Native popovers/sheets own their presentation. `TorrentFolderMotion` and
`TorrentListElevation` retain gesture geometry and saved Tune timing. Inspector
blur also preserves its saved timing. Countdown animation represents elapsed
time rather than a fixed transition. These are intentional named exceptions.

`python3 Scripts/check-motion-policy.py` rejects new fixed SwiftUI timing outside
the shared owner; the local build/install script runs it before building.
Compilation and policy tests do not establish visual quality in every variant.

### Header and Tune follow-up

The user clarified on 29 October 2026 that speed must never hide headers.
The earlier velocity-based suppression/restoration policy is withdrawn. Native
bounds notifications coalesce into the existing queued layout update, which reads
the latest viewport instead of replaying intermediate section positions. Only
headers intersecting that viewport are presented. Scroll offsets never animate;
any unfinished inline-layout animation is cancelled when scrolling or pinning
places the title. Structural layout motion remains separate. The 20-point pin
inset, two-row release rule and short-section eligibility remain unchanged.

The old title-restoration Tune value remains saved for compatibility, but its
inactive slider is removed. There is no speed threshold, idle timer or title
opacity animation in the scroll path. Tests exercise the native fast/slow scroll
notifications, forward/reverse jumps, and interruption of an inline animation.

`glassScrollEdges(.sectionTitles)` disables the system edge effect only in the
main list, whose `HeaderBackdrop` owns one `NSVisualEffectView` with `.headerView`
material and `.withinWindow` blending. This is necessary because the system
variable-blur filter disappeared at the outgoing title's last glyph in the
native reproduction. The user subsequently requested that the material move with
its header, replacing the previous window-top anchoring. Layout retains the
owning title's geometry even after its last glyph is clipped, so the full
material and gradient travel out together. Beginning the two-row release no
longer starts an independent opacity exit. The gradient keeps its full height
and clears the viewport through the same measured translation as the title.
Reversing to inline also keeps any finishing fade attached to that title.

Saved background durations remain for activation and removal. Their native
opacity transition explicitly enables Core Animation actions in its own
transaction, then restores the caller's state. Scroll coordinates remain
unanimated. Tests cover bar/viewport offsets, complete exit, reversal, fast-scroll
visibility and disabled-action calling contexts. No private rendering API is
used in the application.
Inspector, Add and Tune retain `glassScrollEdges(.floatingControls)`.

Both Tune slider groups use `GlassTuningSlider`: native keyboard behavior,
semantic text, visible units and an accessible label/value. Stored values and
ranges are preserved. Header colour overrides remain saved for compatibility;
their inactive controls are removed because the native material owns colour.
The header strength, reach and background timing controls now affect that native
backdrop. The title exit label describes section removal. Scroll speed has no title
opacity control.

`GlassInspector.showPup` is a Boolean, default `true`, exposed as **Show pup** in
Tune → Inspector. It removes/recreates the decorative child panel immediately,
and participates in save/reset through the existing appearance owner. It does
not change Inspector selection, layout or focus.

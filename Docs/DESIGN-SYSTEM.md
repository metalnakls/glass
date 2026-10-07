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
| Torrent rows | `TorrentListView`, `TorrentRowView`, `TorrentListLayout` | existing densities; single/group, selected/unselected, pending/active/completed | Shared row geometry and native separator policy |
| Section titles | `TorrentStickyHeaders`, `StickyTitleLabel`, header appearance | inline, pinned, outgoing; short/long section | Measured position, pin inset, two-item release gap, continuous handoff |
| Scroll effect | `glassScrollEdges`, native top bar | main list, inspector, add | Native top blur, sharp foreground titles, no duplicate fade |
| Settings | `AppearancePreferences`, `GlassAppearanceDefaults`, Tune | saved override or default | One setting definition: key, type, meaning, units, range, default, owner |
| Artwork | preview/icon owners and bundle document assets | document, folder, artwork, unavailable | Asset provenance, shared slot, aspect ratio, optical centering, empty state |

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
| L5 | One title remains sharp and continuous through inline, pinned and outgoing states. No fade/pop, duplicate, or clipping before the intended window exit. | Recording through handoffs in both directions. |
| L6 | Native progressive blur acts on passing content behind titles. No opaque replacement band or second custom title fade. | Light/dark appearance and content passing beneath the title. |
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
  text-file stand-in. Torrent files retain a document icon with the app mark
  inside; record the asset's source before updating it. Wide artwork stays
  centered within its established box.
- Preserve confirmed Smart Rename and location fallback behavior. Metadata and
  renaming stay responsive in services with pending/error states. A visual fix
  must not change paths, filesystem data, or these lifecycles.

## Completion criteria

Each declared owner has a small interface, migrated real callers, documented
variants, and evidence for affected behavior. Values have one source; obsolete
caller styles are removed. Both production policy and native rendering are
checked. Until then, report the migration as partial.

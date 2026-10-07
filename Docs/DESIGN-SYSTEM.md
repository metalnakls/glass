# Glass interface system

Glass keeps SwiftUI's native controls and List ownership. AppKit supplies native
selection, row elevation and continuous sticky-title positioning. A visual fix
must not replace the list, import workflow or another screen's structure.

## Ownership

| Concern | Single owner | Screen supplies |
| --- | --- | --- |
| Glass buttons, padding and hit targets | `GlassPillButton` | Label and action |
| Custom control slot | `GlassControlMetrics` | Search/progress content |
| Expanding search | `GlassSearchPill` | Binding and prompt |
| Location/section choices | `GlassMorphingPicker` | Choices and selection |
| Dock spacing and scroll-safe areas | `GlassFloatingDock` / `glassFloatingChrome` | Controls |
| Progressive blur | `glassScrollEdges` and native `safeAreaBar` | Bar content |
| Import geometry, surface and dock | `GlassAddCard` / `GlassModalMetrics` | Draft editor or pending state |
| Main-list dividers | `GlassListRowSeparator` / native List row bounds | Visibility and column insets |
| Files, selection, priorities and dividers | `TorrentFilesBrowser` | Entries and actions |
| Main-list title positions | `TorrentStickyHeaders` | Section identities and measured anchors |
| Appearance overrides | `GlassAppearanceDefaults` and Tune | Persisted setting bindings |

Use `.padding()`, default stack spacing and native margins by default. Deliberate
optical adjustments live in shared metrics with a reason. Tune overrides adjust
those owners, rather than adding another layer of padding in the caller.

## Scroll and title contract

The native top bar owns progressive blur. It must receive the scroll safe area;
the List must not ignore that safe area. A transparent title plane stays above
the native effect in all inline, pinned and outgoing states. Its coordinates are
converted from the actual scroll view, not assumed to start at the window origin.

The first header's row owns the initial document space; the List top margin is zero.
“Before first header” controls that row padding without adding another container margin.
The native bar retains the established title inset. The next section
pushes the previous title; opacity and blur are never applied to the title itself.
Native row boundaries own main-list separators; content overlays do not.
Title padding retains its shared optical inset and is measured by the same label in every state.
Bottom blur is disabled in Inspector and Add, as requested.

## Import contract

Files and magnets present the same card, title, location picker, file browser and
dock. A magnet has no separate Form or text box. Clipboard commands begin
resolution immediately and show a pending state inside the card. Resolved
metadata enters the existing file-draft editor and Smart Rename preparation.

Adding an unresolved magnet persists its destination first. Model-owned work
continues after dismissal and resolves metadata before submission and naming.
Canceling a preview discards only its metadata fetch, never existing downloads.
Loading and loaded states retain the same geometry.

## Change procedure

Change the owner, inspect its callers, then validate both shared contexts. Verify
initial position, pinning, section handoff, reverse scrolling and resize for title
changes; pending, loaded, cancel and early Add for import changes. A passing build
does not establish that a visual or interactive behavior has been observed.

Apple references: [safeAreaBar](https://developer.apple.com/documentation/swiftui/view/safeareabar(edge:alignment:spacing:content:))
and [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).

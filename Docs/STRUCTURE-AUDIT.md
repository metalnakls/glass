# Structure and scrolling audit — 2026-10-06

## Boundary map

- SwiftUI owns scenes, dialogs, row content and the native `List`; AppKit supplies custom glass flight, header pinning and selection effects.
- The source scan finds SwiftUI view declarations in 32 files and `@Observable` declarations in eight files; these are file counts, not an architecture score.
- `GlassRootView` owns navigation, selection and optimistic removal/rename presentation.
- `RemoteAppModel` coordinates source refresh, commands, detail state, profiles and persistence.
- `TorrentSourceState` owns per-source records; stable `TorrentRecord` identities separate telemetry updates from library structure revisions.
- `TransmissionRPCClient` is an actor in the Foundation-based core; UI actions generally delegate network work to the model.
- `TorrentListPresentationModel` owns group expansion and now publishes one `TorrentListLayout` snapshot.
- Row order, section positions, separator neighbors, folder destinations and prefetch slots derive from that snapshot.
- The inspector still owns its group polling loop and file-edit orchestration; these are candidates for extraction into a dedicated inspector model.
- Thumbnail generation has bounded image caching and serial file/disk lanes, but the preloader has a cancellation bookkeeping risk described below.

This is a source-wide pattern scan with detailed inspection of the root, list, inspector, app model, RPC client and thumbnail/preload boundaries. It is not an exhaustive correctness or security audit of every feature.

## Reproduced defects and implemented changes

### High: custom dividers retained obsolete row geometry

`TorrentListElevationController` cached divider frames by visible range and horizontal geometry. Changing native row height without changing that range reused obsolete vertical positions. A regression test failed by two points after a 48-to-50-point height change. Group expansion and changing header spacing introduced the same invalidation hazard.

Removed the separate `SelectionSeparatorCanvas`, its geometry cache and its scroll updates. Each divider is now a lightweight overlay inside its native row, with a shared snapshot deciding whether a following row exists in the same section and whether selection hides the boundary. The native list owns scrolling, insertion, removal and layout of the whole row. No divider positions are calculated separately.

The installed macOS build rendered extra header rules when native separator modifiers were used on the conditional row hierarchy. The final implementation keeps system rules hidden and uses row-owned rules, retaining the existing custom inset and selection treatment.

### High: inline headers lived outside the scrolling document

Titles were children of the scroll view beside its clip view; every scroll notification translated document coordinates into a separate viewport surface. Inline titles could move in a different display transaction from the document.

The single header surface is now attached to the native document. Inline title coordinates stay in document space, so native scrolling carries them with the rows. Pinning and the existing opacity/blur remain custom. A native integration test scrolls 24 points without calling the title presentation method and verifies that row and title move by exactly the same amount.

Header release points also used a cache that ignored row-height changes. Its key now includes the actual release positions. Offscreen titles no longer borrow another section's measurements. Header observers detach when the list closes or switches to the grid.

### High: structural row order had several calculation paths

The view, elevation, headers and folder flights separately regrouped rows or counted title slots. `TorrentListLayout` now stores sectioned entries, native identities, header/torrent indices, separator neighbors and icon metadata once per structural update. Telemetry still updates stable records. Tests cover expanded mixed-completion groups, section boundaries, lowercase titles and selection neighbors using the same indices.

## Profiling evidence

A 25-second CPU Profiler plus Core Animation Commits recording of the previously installed debug app captured 26,120 CPU samples and 541 animation commit intervals while the list was scrolled down and back. The commit median was 2.61 ms, p95 17.38 ms, and maximum 261.68 ms; 35 intervals exceeded 16.67 ms and five exceeded 33.33 ms. These are CPU-side commit durations, not GPU frame times or an FPS measurement.

The largest named leaf costs included SwiftUI AttributeGraph dirty propagation (3.26%) and update stack work (2.61%). Identified row body costs were below 1% each of cycle-weighted samples. This supports investigating layout/observation boundaries; it does not prove that glass alone causes every hitch.

The trace includes idle time, inspector work and two scripted scroll actions. It is not a controlled benchmark. A follow-up trace is useful for detecting remaining stalls, but no percentage speedup should be claimed from different inspector state, warmed caches or interaction timing.

## Remaining priorities

1. **Inspector ownership:** move group polling, snapshot publication and file-edit transactions from `TorrentInspectorView` into a cancellable `TorrentInspectorModel`. Keep selection identity and completion checks together; add tests for switching sources/selection during a request. The current view `.task` cancels correctly on identity change, but orchestration and view rendering remain coupled.
2. **Artwork cancellation:** `TorrentArtworkPreloader.resolveFileLists` marks every target as requested before its task executes, then cancels the previous task when new targets arrive. Queued targets skipped by cancellation remain in `requestedFileLists`, so later visits can suppress their resolution. A failed request is also recorded permanently. Extract a serial resolver queue that distinguishes queued, completed and retryable work, and test cancellation with a suspended fake resolver before changing it. This source path is identified; a live occurrence was not reproduced in this run.
3. **App-model scope:** `RemoteAppModel` combines profiles/persistence, additions, commands, detail loading and completion watching. Extract detail sessions and mutation coordination into source-owned components incrementally. Keep the existing stable record identities, refresh coalescing and granular structure revisions.
4. **Root filtering:** `GlassRootView.visibleRecords` rebuilds hidden-ID sets and logical-group filtering. Measure invalidation under active telemetry before adding another cache; a cache must include rename, removal and completion inputs.
5. **GPU glass cost:** every glass icon remains a live system material. Frost adds a material pass and blur; HDR adds an extended-range highlight pass. Compare frame-time traces with the same viewport and tuning values before trading quality for speed. No quality reduction or bitmap substitution was introduced here.

## Glass tuning meaning

- **Frost:** opacity of the extra frosted material beneath the live glass.
- **Frost blur:** radius applied to that extra material; it has no effect when Frost is zero.
- **Opacity:** opacity of the complete icon, including live glass and HDR.

These affect different stages, although their current names do not explain that relationship well.

## Validation

The suite covers native selection geometry during resize/recycling/scrolling/height changes, header pin/push/fade geometry, shared row indices, and existing same-view folder flights. Build/install uses the canonical development-signing script and strict verification. Runtime visual observations and follow-up trace results are recorded after installation below.

### Installed observations

All 177 tests passed. The canonical debug build was signed, strictly verified, installed and launched with tuning enabled by its build configuration. Visual inspection of expanded Fargo showed four season icons and dividers in the correct gaps; collapsing restored the shared fan, and the Loading/Completed spacing remained present. The unwanted rules beneath titles were absent in the final row-owned implementation.

The follow-up 25-second trace captured 25 commit intervals (p95 18.18 ms, maximum 18.68 ms). Native automation reported `noWindowsAvailable` when attempting the scroll workload, so this recording is effectively an idle/detail-refresh sample and is **not comparable** with the earlier scroll recording. A three-second live process sample showed the main thread predominantly in its normal event loop; no new Glass crash report appeared. Continuous kinetic scrolling, GPU frame time and a measured before/after improvement remain unverified.

Header labels are preserved on the reserved list rows for accessibility now that the visible title surface belongs to the native document.

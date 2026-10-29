# Performance audit — 29 October 2026

Scope: all 116 Swift application source files under `Sources` and `Apps/Glass`
were included in targeted scans. Follow-up inspection covered the main list,
Inspector, Add windows, artwork, Tune, model refresh, persistence and commands.
Runtime evidence comes from native AppKit/SwiftUI fixtures and the earlier main
window CPU capture. This is not an allocation, energy or GPU benchmark of every
screen. The working tree also contains unfinished interface changes; those were
inspected without reverting or including them in this correction.

## Measured problems

### 1. Whole-window invalidation during scrolling — corrected previously

The root view observed the Inspector's focused Quick Look action. Focus changes
during native scrolling invalidated the entire window. Moving that dependency
into the keyboard-handler modifier preserved Space/Quick Look behavior while
isolating its updates (`018b0d4`).

In the same 300-step diagnostic fixture, root invalidations fell from 271 to zero.
Total step time changed from 5,737 ms to 3,674 ms; the worst step changed from
196.55 ms to 26.75 ms. These are fixture timings, not frame-rate guarantees.
The earlier CPU capture was dominated by native scrolling/window layout; header
geometry calculation accounted for about 0.1% of main-thread samples.

### 2. Header position frozen across section changes — corrected here

Owner: [`TorrentStickyHeaders`](../Sources/GlassRemoteUI/Support/TorrentStickyHeaders.swift).

Reproduction: scroll a three-row section to offset 100, grow it to eight rows,
wait for layout to settle, then start a live scroll without changing the offset.
The header moved from y = -20 to y = 20: a **40-point jump with zero document
movement**. The permanent native regression test failed by exactly 40 points
before the correction.

Cause: `configure` saved the previous pinned placement. Later layout updates
continued presenting it even after the document changed. Starting a scroll
cleared that saved placement, abruptly exposing the current geometry. This
behavior entered in `4567fcf`; rolling back the app is unnecessary.

The correction removes that second position authority. Every placement now
comes from the current measured header frames, viewport and release boundaries.
Native clip bounds changes handle wheel, momentum, keyboard and programmatic
scrolling through the same path. Live-scroll notifications now measure speed for
title visibility only; they cannot release a stale position.

This changes the faulty freeze/resume logic, not the visual design. The same
title instances, typography, saved Tune values, 20-point
pin inset, 8-point title interior, two-displayed-row release boundary and
short-section eligibility remain. Native List still owns scrolling and input.
Section edits update pinning during layout instead of deferring it until a later
gesture.

Tests exercise the actual `safeAreaBar` header surface, section growth and
shrinkage, forward/reverse scrolling, pin/push/exit boundaries, and sections with
1, 2, 3 and 12 rows. Existing tests cover live spacing changes, native separator
geometry and single-title ownership. An additional isolated interruption probe
did not reproduce animation drift; the section-change animation policy is
therefore retained rather than rewritten speculatively.

The user subsequently requested suppression during fast scrolling. The new
presentation policy hides floating titles above 2.5 viewport heights/second,
leaves inline labels in place, and restores the current title after the gesture
ends and scrolling settles. Suppression stays latched through slower strokes
and reversals in the same gesture. A native live-scroll
test exercises the actual notification path and restoration without moving the
document. This is an explicitly requested interaction change, not a claim that
the previous multiple-title presentation was functionally broken.

### Fast-scroll handoff — corrected after live feedback

The first suppression implementation had two reproducible faults: crossing the
pin boundary by one point changed opacity directly between 0 and 1, in both
directions; and rounding every sub-frame notification to 1/120 second made a
1,200 pt/s gesture sampled at 240 Hz appear to move at only 600 pt/s. The focused
regressions failed on the installed implementation before these corrections.

The same header owner now uses a continuous visibility curve across one measured
title height approaching the pin line. It applies in both directions, including
the return to inline positioning. Speed sampling accumulates sub-frame movement.
The speed threshold and saved restoration duration remain intact. The settling
policy was subsequently corrected as described below. Native presentation-layer
checks also exposed an animation bug:
the scroll-geometry transaction disabled opacity animation, making restoration
instantaneous. Opacity now animates outside that transaction. Already visible
titles fade out over 0.12 seconds; newly crossed floating titles start suppressed.
Native List geometry, the window-top backdrop and its fade remain separate.

All 29 tests across scroll motion, native header continuity, backdrop alignment,
sticky geometry and native list rows passed. Actual presentation-layer opacity
checks cover fade-out, restoration, interruption and revisiting a section whose
old fade is unfinished. Motion ownership and whitespace checks also passed.
These checks do not establish subjective trackpad feel in the live library.

### Repeated header blinking — gesture lifecycle correction

A subsequent report exposed an incomplete condition in the speed policy.
Repeated native presentation updates kept opacity monotonic in both directions,
but the production controller restored a header during the slow part of the same
live gesture. The next faster stroke suppressed it again. The 80 ms slow-speed
reset and the idle task both permitted restoration before native tracking ended.
A focused List fixture reproduced this with two fast/slow bursts and a pause
inside one begin/end pair; its assertions failed on the installed implementation.

`TorrentHeaderScrollMotion` now latches suppression through native tracking.
`TorrentStickyHeaders` observes the native end notification and starts idle
recovery only after tracking has ended. Momentum updates extend the deadline.
Legacy wheel events still recover by inactivity: AppKit documents that some
scrolls have no [begin/end notification pair](https://developer.apple.com/documentation/appkit/nsscrollview/didlivescrollnotification).
The correction changes the faulty restoration condition, preserving continuous
opacity, saved durations, pin/release geometry and the window-top backdrop.

Passed: 31 tests across the five affected header/native-list suites, including
both tracked gestures and legacy wheels, changing speed, a stationary finger,
native end notifications and repeated presentation-layer updates in either
direction. Motion ownership and whitespace checks passed. Live-library trackpad
feel remains unverified by these isolated fixtures.

### Header blur exit — reproduced and corrected

The supplied screenshots showed the blur disappearing as a title left the top.
A native layer probe reproduced the precise boundary: between document offsets
118 and 119, the system `PocketBlur` layer dropped its `variableBlur` filter as
the final title glyph left. The layer retained its dimensions, so changing the
title position or padding would not address the cause. This inspection was
temporary diagnostics; application code uses no private filter APIs.

The main list now owns a stable `NSVisualEffectView` using the native header
material, within-window blending and a gradient mask. Its explicit exit uses
the saved background duration. `glassScrollEdges(.sectionTitles)` disables the
additional system edge effect for this variant only. The outgoing title cannot
remove the material, and floating-title suppression does not hide the backdrop.

In an isolated native window with a 0.4-second exit, measured presentation
opacity progressed 0.75 → 0.45 → 0.14 → 0.02 → 0 while the full 115-point gradient
extent remained. This proves continuous fading in that fixture; live-library
appearance and GPU cost of the changed material still require observation.

The subsequent alignment correction keeps that fade and anchors its top to the
window, independently of the title and safe-area bar. Previously the effect used
the bar's local origin: a native regression fixture reproduced 28- and 44-point
vertical errors with matching bar insets. The corrected fixture covers those
insets, an inset scroll viewport, forward/reverse document offsets and a departing
title. All 26 header/backdrop/native-list tests passed. Fade timing, strength and
title pin/release geometry are unchanged. A full-size-content native window
confirmed alignment during forward/reverse scrolling at heights of 350, 400 and
600 points, including unclipped drawing above the safe-area bar. Debug build
`202610291605` was installed with strict signature verification and matching
built/installed executable hashes. Live-library visual alignment remains
unverified by screen capture.

### 3. Reorder wrapper builds every row description — next priority

Owner: `GlassNativeReorderableRow` in
[`GlassDesignSystem`](../Sources/GlassRemoteUI/Support/GlassDesignSystem.swift).

With 500 simple entries and eight visible rows, the current per-item reorder
wrapper invoked all 500 row builders. A plain native List invoked 301. Both
tables had only 21 available native row views: this is extra SwiftUI construction,
not proof that AppKit realizes the whole library. Native List itself also does
work beyond the viewport, so claiming an eight-row target would be misleading.

Option: use one collection-level identity/reorder boundary and keep expensive row
content behind native realization. Compare it with the current wrapper using the
same library, selection and dimensions. Do not blindly restore `16093dd`: current
unfinished changes reverted that approach. Acceptance must include native rules,
selection, keyboard, drag across sections, expansion and row moves as well as
construction counts and scroll timing.

## Other optimization options

These are source-level findings. Their cost has not been measured in a live
library, so they should not be presented as established causes of the scroll lag.

| Priority | Area and evidence | Proposed change and validation |
| --- | --- | --- |
| High | Artwork file-list preloading marks an entire batch requested before completing it, then cancels that batch when new viewport targets arrive. Entries never reached by the cancelled loop remain marked requested. See `TorrentArtworkPreloader.resolveFileLists`. | Track queued, in-flight and completed requests separately, or use one bounded worker with updated priorities. Test fast direction changes, cancellation, retry after failure, and returning to previously skipped rows. This is a correctness issue as well as wasted prefetch work. |
| High | `TorrentThumbnailService.revision` is global. `TorrentFileIcon` includes it in every thumbnail task ID; resolving one new file path can restart unrelated row tasks and tint extraction. | Expose per-torrent/path changes, retaining a separate generation for true global invalidations such as source mapping changes. Cache tint alongside the image. Measure task starts for one resolution among many visible rows; unchanged rows should stay untouched. |
| Medium | `TorrentFilesBrowser.body` recreates lookup/neighbor maps and formats/measures every displayed size to find the widest column. The Inspector independently computes its shared size column. Tree topology is already cached, but this presentation work still runs on telemetry updates. | Cache size-column measurement by structural file data and font/appearance inputs. Reuse topology and precomputed folder aggregates where profiling justifies it; preserve current progress, wanted and priority values. Benchmark 100, 1,000 and 10,000 files with warm topology and telemetry-only updates. |
| Medium | Every `AppearancePreferences` read observes one revision. Any Tune edit invalidates all appearance readers; reset writes each key and increments repeatedly. | Cache observable values per key, skip unchanged writes, and batch reset notifications. Validate immediate main-window and detached-Tune updates, persisted overrides and reset behavior. Do not reset saved preferences as an optimization. |
| Medium | Explicit `persistTorrentCache()` paths sort, encode and save synchronously on the main actor, including flushing on deactivation. Periodic persistence already uses a delayed background write. | Measure large-cache flushes. If material, use one ordered writer that guarantees the latest snapshot wins and still flushes durably. Adding more detached writes without ordering could introduce stale overwrites. |
| Lower | Header updates reread anchor geometry, sort headers and compute release points on every native bounds update. `SectionStructure` compares already-computed values, so its cache avoids little work. The global geometry observer can also schedule an update for scrolling that the clip notification already handled. | After the continuity fix, consider a document-layout snapshot invalidated by structure, anchor, size and Tune changes; scrolling would only project that snapshot. Test native estimated row heights, recycled anchors, resize and live Tune before trusting the cache. Earlier CPU evidence makes this lower priority than row construction. |
| Lower | `allTorrentRecords` builds arrays and an ownership set on each access; filtered-library and Inspector paths derive further collections. The main list already separates structural presentation from record telemetry. | Profile representative filters and multi-selection. Cache only structural derivations with correct add/remove, completion, rename and grouping invalidation. Preserve the existing stable `TorrentRecord` objects. |
| Lower | Command enablement parses the clipboard magnet string during command/focus refresh. | Cache parsing by `NSPasteboard.changeCount` if it still appears in a post-fix profile. Read the current clipboard when the command executes. |

## Existing work to preserve

- Artwork already uses bounded image/disk caches and serial background lanes for
  disk and file access. Another generic background-task rewrite is not needed.
- File tree topology already excludes progress, wanted and priority telemetry
  from its structural cache key. Extend that separation rather than replacing it.
- Source refreshes run independently, deduplicate requests, distinguish active
  and quiet sources, and back off after failures. No continuously firing timer
  was found in the application-source scan.
- Periodic torrent-cache writes are coalesced and performed off the main actor.
- Add-file parsing and episode-index filesystem work already have background
  execution paths. A synchronous API name alone did not establish main-thread IO.

## Design-system and HIG pass

The shared-owner review covered native buttons, picker choices, floating chrome,
search, main-list rows, Add and Inspector callers, and Tune's settings controls.
`GlassTuningSlider` now owns both Tune slider families, with native adjustment,
readable units, semantic text and accessible label/value pairs. The underlying
keys and ranges are unchanged. This follows Apple's guidance to provide labels,
visible values and live feedback for [sliders](https://developer.apple.com/design/human-interface-guidelines/sliders),
and use system text styles and semantic colours for [labels](https://developer.apple.com/design/human-interface-guidelines/labels).

Tune's header colour controls were inactive under the system blur and have been
removed; their saved keys remain intact. The native material owns its colour.
Strength, gradient reach and background timing now act on the real backdrop.
Timing labels distinguish fast-scroll title restoration from section removal.
Tune → Inspector adds **Show pup**, default on, using the existing save/reset
owner. A native check observed child-panel counts 1 → 0 → 1 when toggled on/off/on.

Inspector, Headers, Motion and Icons fit the 260- and 340-point Inspector limits
in the native layout fixture, with document width equal to viewport width.
This verifies horizontal fit, not every translated label or VoiceOver utterance.
The app retains native scrolling and uses one scroll effect per pane, consistent
with Apple's [scroll-view guidance](https://developer.apple.com/design/human-interface-guidelines/scroll-views).
Existing custom window chrome and unfinished Add changes remain separate work;
this pass does not certify every screen as fully HIG-compliant. The contracts
remain explicitly partial in [DESIGN-SYSTEM.md](DESIGN-SYSTEM.md).

## Delivery and remaining checks

Passed: 37 tests across native header continuity, backdrop fade, scroll-speed
policy, sticky geometry, native list rows, Tune preferences, Quick Look keyboard
policy and main-window chrome; motion ownership; whitespace and document links.
The required debug build and install succeeded with strict signature verification
and matching installed/built executable hashes. Installed version
`202610291539` was relaunched from `/Applications/Glass.app`.

The header regression and native variant tests establish geometry and ownership
in isolated fixtures. They do not establish subjective trackpad feel in the
user's live library. Light/dark appearance, momentum under concurrent server
updates, drag/rename/keyboard interactions, and GPU/energy/memory behavior have
not all been observed end to end in this audit.

Recommended order after this correction: measure and reduce row construction;
repair preload cancellation; narrow artwork invalidation; benchmark Inspector
presentation work; then consider Tune/persistence and header geometry caching.
Keep each change independently measurable rather than stacking rewrites.

# 002 — Reveal actions behind the rounded frame

- Status: IMPLEMENTED; trackpad feel check pending
- Baseline: 53aa537
- Severity: HIGH
- Category: Physicality and layering
- Scope: TorrentSwipeRow and TorrentListView

## Problem

At the baseline, `Sources/GlassRemoteUI/Support/TorrentSwipeRow.swift:42` abruptly exposed actions at -0.5 points; the foreground was clamped to 110 points and only moved left. The global selection surface sat below the action buttons, which visibly cut into its frame.

## Target

Follow native horizontal trackpad deltas in either direction. Lock vertical scrolling out of the swipe gesture. Ignore momentum as an additional destructive gesture. Actions fade in over 36 points and scale from 0.8 to 1 across 80 points. A rounded even-odd reveal mask keeps the actions behind the moving frame. Below the commit threshold, restore with a 280 ms spring and 0.12 bounce. Reduced Motion drops movement on settle.

For torrent cards, 56 points commits torrent-only removal on release; a full swipe of `max(180, width * 0.55)` commits torrent + data. Full-swipe threshold crossing gives one native alignment haptic. Complete the exit over 180 ms ease-out before calling the existing removal/undo path. Inspector priority gestures keep the tap-to-apply reveal behavior.

## Repo conventions

Keep the permanent list padding, 12-point rounded card, yellow X, red trash, native NSEvent input, and existing removal callbacks. Reuse the user’s saved selection glow/shadow tuning.

## Steps

1. Track both positive and negative native deltas, with phase-aware end/cancel and short debounce for unphased mouse wheels.
2. Animate the reveal and cut its action plane around the actual foreground frame.
3. Opt torrent cards into short/full release commits; preserve file-priority action semantics.
4. Restore the row when a removal is cancelled or rejected.

## Boundaries

Do not delete existing downloads for a feel check. No synthetic screenshots or per-frame CPU blur. Do not bypass existing confirmation and undo handling.

## Verification

Compile and run tests, then use a disposable torrent to test both directions, short release, long release, cancellation, reversal, vertical scrolling, momentum, and Reduce Motion. Watch the rounded edge while sliding: neither action may paint over the card. This destructive/trackpad feel check remains for the user.

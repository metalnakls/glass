# 001 — Respond before the server

- Status: IMPLEMENTED; live feel check pending
- Baseline: 53aa537
- Severity: HIGH
- Category: Feedback and interruptibility
- Scope: TorrentRowView, TorrentListView, RemoteAppModel

## Problem

At the baseline, `Sources/GlassRemoteUI/Views/TorrentRowView.swift:183` incremented `clickRevision` and sent a command while `stateSymbol` still came only from the previous server state. Its finite 12-degree rotation ended before the response, leaving the user unsure whether the click registered.

## Target

Set an optimistic play/pause symbol synchronously. Use native SF Symbol magic replacement with a 220 ms smooth transition. Press feedback scales to 0.96 over 120 ms ease-out. Native breathing repeats at 1.6 speed only while a command is awaiting confirmation. Server confirmation cancels the pending effect; a failed command restores the actual state. A 12-second timeout prevents indefinite feedback when a server refuses the requested state. Reduced Motion removes the transform and uses subdued opacity while pending.

## Repo conventions

Use SwiftUI symbol transitions, the existing Reduce Motion environment, and source-scoped provider commands. Preserve the completed checkmark and unavailable question mark. Keep saved tuning in `SelectionAppearanceView`.

## Steps

1. Return provider success from start/stop without changing their source ownership.
2. Make the row transfer callback async; retain optimistic state until refreshed status confirms it.
3. Replace the finite rotation with short press feedback and native pending breathing.
4. Add optional progress-disc fill with black/white glyph layers masked by the same animatable fill shape.

## Boundaries

No continuous Swift timer, Metal rendering loop, new dependency, or change to completion history. Do not click real torrents during automated UI checks.

## Verification

Run `swift test --package-path . --disable-sandbox`, then the canonical debug build/install. In the installed app, test a disposable torrent against a delayed server: immediate symbol change, continuing feedback, confirmation stopping the loop, failure reverting, and Reduce Motion avoiding rotation/scaling. Tune the fill through zero, partial, and full progress and inspect glyph contrast. This live command/latency test remains for the user.

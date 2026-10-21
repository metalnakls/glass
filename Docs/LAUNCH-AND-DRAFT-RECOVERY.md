# Completion delivery and draft list interaction

Completion tracking must use `TorrentSummary.isCompleted`, the same predicate as
list grouping. Overall progress below 100% does not necessarily mean an unfinished
transfer: a finish date or zero remaining wanted bytes can already mark it complete.
Watching those startup baselines produced a new completion on every launch.

`GlassCompletionNotificationCenter` owns separate read and delivery histories.
Successful delivery is remembered per destination/hash and completion date, even
if the alert remains unread. Existing delivered alerts seed that history during
configuration. A missing finish date does not become a new event merely because
Glass restarted. A later dated completion is eligible; an explicit new import
resets both histories for its download. Failed delivery is not recorded.

Drafts use their stable list identity for native selection, separator neighbors,
and focused deletion. Root command routing resolves that identity through the
saved draft store. Discarding a draft removes its saved editor state; it never
calls a transfer provider or deletes source/downloaded files.

Drafts previously bypassed the native swipe wrapper and selection-card owner.
`TorrentListRowChrome` now shares the existing row height, elevation anchors,
selection surface, hit geometry, and motion with regular rows. Its bounds are
unchanged for regular rows. The swipe component's draft variant labels both
removal directions as Discard Draft. Draft ordering and editor recovery remain
owned by the existing draft store and Add flow.

Regression checks cover repeated launches with partial-but-completed local
baselines, persistent delivery independent of read state, later completion dates,
new-import resets, native List selection, adjacent separators, selective draft
removal, and regular/compact/grid control alignment. Foreground key dispatch and
real Notification Center delivery require live app verification in addition to
these component tests.

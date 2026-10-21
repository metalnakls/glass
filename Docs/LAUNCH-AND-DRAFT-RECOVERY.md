# Completion delivery

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


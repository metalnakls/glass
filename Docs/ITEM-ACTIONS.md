# Item actions

`TorrentItemActions` resolves removal identities for the main list. Menu command
availability and execution use the same resolver. Swipes and context menus route
through the root removal dispatcher. Group membership only collects targets;
it never removes a member's actions.

- Saved editor draft: discard saved editor state.
- Pending or failed addition: remove the submission using its queue ID.
- Accepted addition: remove its actual provider transfer, respecting Delete Data.
- Live transfer: retain the existing removal/undo path.
- Group: apply the appropriate action to every member, including pending members.

`TorrentNativeSwipeRow` supplies both swipe icons to all list rows. Lifecycle
state may change the primary action (resume/retry/progress), but must not disable
the row's selection, swipe surface, or context menu. `TorrentRemovalActions`
supplies the corresponding context-menu labels and icons.

Queued removal is immediate. An already-submitted request is allowed to settle
before its real transfer is removed. Removed submission IDs cannot be recreated
by stale callbacks from an open Add batch. Unsubmitted drafts never send synthetic
IDs to Transmission or delete source torrent files.

Regression coverage includes all Add phases inside and outside groups, saved
editor drafts, stale selections, pending-only removal, accepted failed setup,
and callbacks after removal. Runtime gestures remain a separate acceptance check.

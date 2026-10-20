# Completion notifications

GlassCompletionNotificationCenter owns delivery, actions and unread acknowledgement
for both the foreground model and the background worker. Previously, completion
banners used the server name instead of the saved list title; app activation
cleared the entire Dock counter without clearing individual delivered notifications.

The foreground model watches unfinished downloads from successful live snapshots,
including restored local downloads and downloads added outside the current launch.
Watches continue when Glass loses focus. Completed downloads present on the first
snapshot do not replay old notifications. Source/hash identity suppresses duplicate
completion calls across refreshes; removal retires the watch and permits a new one.
Cached lists alone do not start polling or request notification permission.

Notification bodies use the saved display title, preserving case and the list's
media-extension preference. The payload retains the real file/root path separately.
The Open action has no foreground option: it opens the download through the existing
local/mapped-share file action. Missing paths, unavailable mappings and failed opens
fall back to activating Glass. Clicking the banner body remains the macOS default
foreground action.

A download is acknowledged when at least half its row/card is visible in the active,
non-minimized main Glass window. Collapsed groups acknowledge their represented
members. Offscreen, filtered-out and other-destination downloads remain unread.
Measured AppKit viewport intersection, activation and window focus trigger acknowledgement; merely
creating a lazy row does not. Matching uses source UUID plus torrent hash, including
legacy delivered notifications. Dismissal and Open clear the specific notification.
System alerts appear even when the completed item is visible. For those foreground
completions, presentation includes the banner and sound but omits Notification Center
retention; Glass does not immediately retract the newly delivered alert. Offscreen
completions also appear in Notification Center. Retained unseen completions provide
the badge count across launches; visible items do not contribute to that count.
Delivery errors are recorded in the notifications log rather than discarded.

Protected behavior: native list ownership, row identity, selection, grouping,
scrolling, layout, Tune values, file actions and download paths remain unchanged.

Validation: tests cover case/extension formatting, destination-specific selective
removal, activation preserving unseen notifications, and native list/grid viewport
visibility. Build/signature verification does not prove Notification Center clicks
or cold background-action launches; those require an actual completion notification.

Installation retains the existing app wrapper and a verified previous backup, then
replaces the bundle contents before copying the signed build. This removes obsolete
resources that otherwise survive a merge and invalidate the signature. Installer
fixture tests cover stale-resource removal and rollback after a failed copy.

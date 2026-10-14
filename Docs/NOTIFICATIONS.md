# Completion notifications

GlassCompletionNotificationCenter owns delivery, actions and unread acknowledgement
for both the foreground model and the background worker. Previously, completion
banners used the server name instead of the saved list title; app activation
cleared the entire Dock counter without clearing individual delivered notifications.

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
Notification Center's retained completions provide the badge count across launches.

Protected behavior: native list ownership, row identity, selection, grouping,
scrolling, layout, Tune values, file actions and download paths remain unchanged.

Validation: tests cover case/extension formatting, destination-specific selective
removal, activation preserving unseen notifications, and native list/grid viewport
visibility. Build/signature verification does not prove Notification Center clicks
or cold background-action launches; those require an actual completion notification.

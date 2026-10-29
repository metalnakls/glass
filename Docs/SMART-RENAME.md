# Smart Rename and season headings

Download selection and naming are independent. With Smart Rename enabled, its plan
covers all supported media files, including unchecked files and seasons. Wanted
flags and priorities still control downloading; disabling Smart Rename retains the
original names. Existing collision checks and non-media-file handling remain intact.

The shared file tree recognizes release-style season folders such as
`Friends.S01.1994.720p.BDRip.HDCLUB` as `Season 1`, including multi-season torrents.
This is presentation only: original paths, folder IDs, collapse state, file indices
and file actions remain tied to the original metadata. Add and Inspector share this
owner. Searching accepts both the season heading and the original release name.
Episode directories and season ranges retain their original labels.

Regression coverage includes ten Friends seasons, collapse/search identity,
unchecked transfer flags and the complete rename plan. The supplied Friends.torrent
is also checked in an isolated fixture without starting a download or changing it.

Season imports share `TorrentSeriesIdentity` with library grouping. A missing
leading “The”, capitalization, or release separators must not split a show into
different disk roots. `TorrentSeasonStoragePlan` preserves the existing root's
spelling within the chosen source and base directory; choosing the show folder
itself uses that folder instead of nesting an alias beneath it. The Add queue
resolves against existing transfers and earlier queued seasons before submission,
including resolved magnets and restored queues. Accepted/attempted submissions
retain their persisted destination and rename plan for safe retries. Other
sources, other destinations, and distinct manually chosen titles stay independent.

New season transfers are submitted paused until their naming plan completes, so
downloading cannot create a separate release folder before the shared root is
assigned. They then start unless the user chose a paused import. Duplicate
transfers retain their existing state. Existing split folders require a separate,
verified repair of files and Transmission paths; import matching never moves them.

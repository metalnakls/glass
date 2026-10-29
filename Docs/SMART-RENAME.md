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

When the server repairs only a series alias (for example `Walking Dead` to
`The Walking Dead`), Glass retains that transfer's saved season by source and
torrent hash. It resolves the stored name against the server's current spelling
on refresh and restart. Unrelated root renames still invalidate stale season
metadata, and custom display labels remain intact. This does not rewrite files.

## Import ownership and recovery

| Owner | Contract |
| --- | --- |
| Draft store | Retains unsubmitted names, destination, wanted flags, priorities and source bytes. Preparing names must not replace a restored or explicitly entered name, even when it equals the original release name. |
| Add queue | Owns the submission only after its complete snapshot saves successfully. Repeating preparation retries a failed save; the editor remains recoverable until that succeeds. Once attempted, retries keep the saved destination, selection and rename plan. |
| Series storage plan | Matches physical show roots within one source and destination. Add can use earlier queued seasons; Smart Rename consults existing transfers only. Unsubmitted additions cannot rename a live transfer. |
| Transmission | Owns transfer identity, paths and bytes. Duplicate adds retain their existing names and running/paused state. A rename error is reported; it does not authorize a filesystem merge. |

The October 29 audit reproduced and corrected failed-save acknowledgement,
restored-name replacement, and Add/Smart Rename folder-rule drift. Regression
checks also cover batch grouping, selected/unselected files and priorities,
magnet metadata validation/cancellation, lost replies, completed rename retries,
source/destination isolation, duplicate transfers, selective draft retirement,
and persistence across relaunch. Live Ultra repair separately verified all 32
episode inode/size pairs and resumed season 4 at 100% with no engine error.

Scope: these checks cover the import/naming stack, not every app interaction.
They do not make filename-only matching a universal show identifier. Existing
nonempty directories, alternate releases with overlapping paths, and an external
client moving data still require explicit collision checks and relocation;
automatic title matching is not permission to overwrite their contents.

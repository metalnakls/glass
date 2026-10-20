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

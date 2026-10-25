# Glass and YINA: shared shows

Status: design proposal plus episode-index serialization and export foundations.
The manual Inspector export control was withdrawn at the user's request; automatic
publication needs the shared ownership protocol below. This is not
authorization to enable automatic downloading, deletion, or shared watch-state
changes. The user owns UX decisions. Coding is delegated to Luna agents.

## Starting point

Glass already exposes Transmission file selection and priorities, including
files that are not selected. Current YINA `meh` has a local history-based show
shelf and mpv playlist. Its older `multiplayer` branch has portable
`.iina-multiplayer/room.json`, per-peer progress files, revision-aware resets,
and synchronized playback, but that implementation is not in current `meh`.
Do not merge the old branch wholesale or claim it is installed.

Preserve Glass's native list/Inspector controls and existing download choices;
preserve YINA's manual playlist, resume behavior, and playback synchronization.
The separate YINA chat owns changes in that repository.

## Ownership

| Owner | Responsibility |
| --- | --- |
| YINA | Playback, actual playback stalls, resume, watched events, session participants, requests to play an episode |
| Glass | Source selection, download requests, prefetch and retention policy, explanations and conflict controls |
| Transmission | Actual bytes, file selection, priorities, transfers and seeding counters |
| One coordinator per download library | Serializing policy changes and deletion, deduplicating requests, enforcing active playback and Keep claims |
| Portable show metadata | Catalog, relative paths, stable identities, durable watch/retention decisions; no credentials or machine paths |

Initially the coordinator can run with Glass on a designated Mac. When it is
offline, playback continues and automation pauses. For unattended NAS use it
must run on an always-on host. iPhone is a controller, not the scheduler.
Do not alter Transmission RPC to make peer Glass clients negotiate with every
other client. Put the policy protocol above RPC; retain compatibility with
ordinary Transmission clients. Unmanaged clients remain an explicit limitation:
the coordinator cannot prevent them deleting files outside this protocol.

## Portable format and first slice

Use `.yina.json` at an explicitly established media root. The first protocol is a
versioned **single-torrent snapshot**. Its export implementation is retained for
integration work, with no dedicated Inspector control exposed to the user.
It includes video files regardless of their wanted flag, original filename case,
relative paths, torrent hash/file index identity, optional episode numbering,
byte totals, selection and capture time. No torrent credentials, tracker
passkeys, bookmarks, remote server URLs or absolute paths belong in it.

Envelope: `schemaVersion`, `hashString`, `capturedAt` (ISO-8601), `episodes`.
Each episode: `id: {hashString, fileIndex}`, `relativePath`, optional `season`
and `episode`, `bytesCompleted`, `totalBytes`, optional `wanted`.
Numbering is descriptive; file identity remains authoritative. Ambiguous names
must not silently map two episodes onto one catalog identity.

Snapshots older than 15 minutes, or dated in the future, have unknown current
transfer availability. Partial bytes do not prove an active download. A complete
file remains complete even when deselected. A snapshot never alone establishes
local playability: YINA must also establish a reachable contained regular file.
Preallocation means existence and byte size alone cannot prove completion.

The initial exporter must not replace another torrent's manifest, an unknown
schema, or a manifest with fields it cannot preserve. It does not continuously
write on refresh. Export through the mapped local/SMB filesystem, not through
Transmission's remote path as if that path were local. Perform I/O off the UI
thread, validate containment including symlinks, and replace atomically.

YINA's proposed first consumer adds an Unavailable Episodes section alongside
the existing playable playlist. Dimmed rows retain accessible text/status and
show snapshot age. Do not enqueue unavailable paths in mpv, change manual
reorder, or pretend a disabled row can request a download yet. Completion of
that consumer is tracked in the YINA chat.

Future live integration requires an explicit format upgrade: stable show and
catalog episode IDs, multiple transfer/assets per episode, coordinator identity,
generation, and expiring availability. Publish durable catalog updates to disk;
subscribe to live progress while either app is viewing that show. Throttle
checkpoint writes rather than writing every percentage tick over SMB.

Playback cannot safely share a mutable JSON document with catalog publishing.
Use separate per-participant records under `.yina/` for watch progress and
immutable reset/events, preserving the old branch's observed-revision principle.
Read old metadata through a compatibility adapter; never delete it on discovery.
Explicit migration must retain identities and resets, with fixtures from the old
schema. A move of the media root changes local mapping, not show identity.

## Adaptive queue

Start with the next two episodes as the minimum desired ready buffer, plus the
currently requested episode. This is a target subject to available sources and
storage, not a promise. A skip reprioritizes immediately without discarding
other people's needs. Manual file selection and Keep pins outrank automation.

Plan in playback time and bytes, not a fixed episode count. Estimate a
conservative completion time from remaining bytes and sustained *per-transfer*
throughput, with uncertainty for stalls and sparse observations. Compare it with
the predicted time the episode will be needed, adjusted for playback speed and
recent binge/skip behavior. Account for the aggregate bandwidth shared by all
queued episodes; do not assign the full measured link speed to each episode.

If estimates indicate the next season needs several hours, start it during the
previous season. Cheap, fast episodes can stay close to the two-episode floor.
Choose a bounded storage budget and free-space reserve; report when reliable
readiness is impossible instead of silently sacrificing retention promises.
Use smoothing, hysteresis and cooldowns so estimates do not repeatedly toggle
checkboxes or download limits. Manual overrides remain stable.

Observe three distinct bottlenecks: Internet/swarm delivery, client-to-NAS read
performance, and NAS disk contention. YINA reports read stalls/cache underruns,
not every dropped video frame (which may be decoder/GPU pressure). Glass observes
transfer rates and queues. Correlate sustained changes with download concurrency.
Start with passive measurements; bounded idle probes are optional and never
benchmark an HDD while somebody is watching. Do not mistake cached reads for
sustained disk throughput.

When playback suffers, first reduce concurrent writers and download pressure;
reduce upload pressure too when seeding competes for disk reads or the link.
Prioritize the current/requested episode. Restore capacity gradually after a
healthy interval. All active viewers contribute demand; optimize the union of
their buffers. A NAS disconnect means unknown state, not missing media or consent
to delete. Keep a last-known catalog visible and stop destructive work.

## Watched episodes as a cache

Enable cache management per show/library, with a visible distinction between
managed downloads and existing user-owned media. Never adopt and delete arbitrary
files just because they appeared in a playlist.

An episode becomes eligible only after a watched event plus 48 hours, no Keep
claim, no active playback, no outstanding need from an enrolled viewer, and any
enabled seeding requirement. Rewatching extends the grace period. Seeking to the
end or skipping is not proof of watching; accumulate playback coverage and
support an explicit Mark Watched correction. Autoplay can still run while a
person sleeps: the 48-hour grace protects that case without pretending to detect
sleep. Progress corrections/reset must cancel pending deletion eligibility.

Space pressure never silently shortens 48 hours or breaks Keep. Pause prefetch
and explain what is holding space. Show anticipated reclaimable space separately
from space that can actually be reclaimed now.

Important implementation constraint: Glass's current RPC removal is whole-torrent
removal. Unchecking an episode does not delete its existing bytes. A season-pack
episode eviction needs a coordinated backend operation that pauses/reconciles
file state, respects shared torrent pieces, updates/rechecks the transfer and
avoids unintended re-download. Until supported and tested, retain the pack until
all of it is eligible, or expose episode eviction as unavailable. Do not unlink
files behind a running Transmission session as an approximation.

Optional “Seed to 2× before cleanup” adds a second gate; 48 hours and 2× must both
pass. Define this as uploaded bytes >= twice downloaded payload bytes for the
transfer (ratio 2.0), not twice the full season size when only a subset was
downloaded. Transmission does not provide reliable episode-attributed upload
accounting. Show this as a torrent-level hold; never invent per-episode ratios.
Low demand may prevent the ratio ever reaching 2×. Expose that reason and allow
an explicit user policy change, never a hidden timeout bypass.

## People, conflicts and deletion

Keep person, device and viewing session separate. Watching on a friend's Mac can
advance your progress only when you are a participant in that session. Do not
infer that everyone watched because one household cursor moved forward. Preserve
individual progress; derive a shared resume view where desired. Queue demand is
the union of participating viewers, not the furthest user's next episode.

A deletion proposal identifies exact assets and the observed policy generation.
If someone is downloading, watching, keeping, or still needs them, leave the data
in place and expose `!` on the torrent row. Clicking opens an anchored explanation
with Keep and Release My Hold actions. Keep applies everywhere. Releasing one
hold cannot override somebody else's; execute only after all blocking claims
clear and the coordinator rechecks current state. An offline user is not an
implicit approval. Persistent Keep survives disconnect; playback leases expire
conservatively. Uncertain state defers deletion.

Use authenticated coordinator requests with request IDs, serialized decisions
and generation checks. Deduplicate identical info hashes on the same backend;
matching title/episode names alone are not sufficient (different encodes matter).
Deletion and playback lease acquisition must serialize at the same authority.
A folder lock or optimistic JSON overwrite is not a substitute for fencing an
old coordinator after a network partition. Initially, no automatic failover:
losing the coordinator pauses mutations. Later failover needs backend-enforced
fencing before it can safely delete. Never trust arbitrary shared JSON as a
credential-bearing command channel.

## Finding releases and metadata

Use two source adapters first: Torznab (e.g. Jackett/Prowlarr) and Stremio addon
stream responses. The latter can expose torrent infoHash/fileIdx, but some
responses are only HTTP/debrid streams and cannot become Transmission downloads.
Show capabilities honestly. AIOStreams aggregates addons; it is not itself a
BitTorrent tracker, and its built-in torrent search has debrid requirements.
Torrentio, TPB+ and TorrentsDB need individual compatibility fixtures before
claiming support. Avoid building a separate scraper for every site initially.

For RuTracker, establish a supported authenticated indexer adapter and keep
credentials in local secure storage. Rank with explicit preferences: language,
audio/subtitles, quality/HDR, codec/device compatibility, release group, size,
seed health and pack versus episode. Fetch automatically only within those
constraints; otherwise show the ambiguity on the relevant item.

Use an established metadata provider such as TMDb for artwork, episode summaries
and external IDs, retaining provenance, language and attribution requirements.
IMDb IDs can be cross-references; do not treat scraped IMDb pages as an artwork
API. Share resolved metadata between both apps, separate from transfer identity.
Support specials, alternate ordering, multiple encodes and multi-episode files.

AI can interpret noisy release names and explain candidates. Deterministic rules
must enforce hard preferences and decide whether confirmation is needed. Apple's
current Foundation Models documentation includes Private Cloud Compute; check
entitlement, device/account availability and failure fallback when implementing.
Cloud availability must never be required for playback, cleanup safety, or basic
search. Do not send tracker secrets or shared watch histories with matching tasks.

Trakt can be an optional per-person watch-history adapter. Deduplicate outbound
watch events and queue them while offline. A remote watched flag is not evidence
that every shared-library participant watched, and must never independently
authorize cache deletion. Map explicit people/accounts rather than inheriting
the account of whichever computer hosts a viewing session.

## iPhone and motion

Keep the same information hierarchy, labels, artwork, state controls and actions.
Adapt Inspector into a native glass bottom card with detents, keyboard-safe
layout and accessible touch targets. Share models/policy and design semantics;
native platform interaction remains appropriate. Current package is macOS-only:
an iOS target and AppKit separation are real work, not a build flag.

Use a shared app-owned document/folder icon family, with SF Symbols where suitable;
do not depend on Finder icon extraction on iPhone. Preserve the current macOS
assets until a side-by-side replacement is approved.

Audit motion by state transition across list, Inspector, Add and Tune. The existing
`GlassMotion` owns timing. `TorrentRowView` currently uses magic symbol replacement
and whole-symbol repeated rotation for pending actions: candidates for the
“corny” state changes the user described, not yet visually diagnosed causes.
Proposal: one restrained symbol replacement for state changes, a stable progress
indicator for waiting, native glass continuity for actual shape changes, no bounce
for network polling, and a steady `!` for attention. Keep actions immediate,
interruptible motion and Reduce Motion support. Compare identical fixtures and
saved Tune values before changing timings. Do not mix this audit into export work.

## Delivery sequence and acceptance

1. Explicit snapshot export and read-only YINA unavailable rows. Check unchecked
   files, renamed paths, SMB mapping, stale/malformed manifests, path traversal,
   sparse partial files, native overwrite behavior and existing playlist actions.
2. Multiple-torrent show catalog, compatibility migration, coordinator connection,
   live availability and a Request Download action. Test reconnect, deduplication,
   offline behavior and multiple viewers before queue automation.
3. Adaptive queue in recommendation mode, then opt-in automatic wanted/priority
   updates. Replay fast/slow swarms, skips, concurrent viewing and disk contention.
4. Retention proposals without deletion; then narrowly supported eviction with
   tested participant holds, 48-hour boundary, ratios, restarts and races.
5. Source discovery/metadata, iPhone parity and a separate visual motion pass.

Product decisions to settle before those stages: shared versus individual
viewing membership; cache budget/free-space reserve; exact watched threshold;
source preferences; who may change library retention policy. These do not block
the explicit snapshot export.

## External references

- [Stremio stream response contract](https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/api/responses/stream.md)
- [AIOStreams integrations and requirements](https://github.com/Viren070/AIOStreams)
- [Transmission RPC specification](https://github.com/transmission/transmission/blob/main/docs/rpc-spec.md)
- [TMDb TV artwork interface](https://developer.themoviedb.org/reference/tv-series-images)
- [Apple Foundation Models](https://developer.apple.com/documentation/FoundationModels)

These references inform the proposal, not a claim of implemented provider support.

## First-slice validation

Glass's full SwiftPM suite passed: 267 tests, including index serialization,
per-file availability, stale snapshots, nested roots, symlink escape rejection,
and refusal to replace foreign or unfamiliar manifests. This establishes model
and filesystem-validation behavior, not the native save panel or a real SMB
round trip. Those user-visible checks and YINA's consumer verification remain
separate acceptance checks. No queue automation, deletion or motion changes are
included in this slice.

The required debug build/install succeeded, with strict signature verification
of both built and installed Glass. Installed build `202610250818` matches the
built executable by SHA-256. No app launch or real-share export was performed.

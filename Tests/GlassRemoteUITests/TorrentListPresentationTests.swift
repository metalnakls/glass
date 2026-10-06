import Foundation
import GlassRemoteCore
@testable import GlassRemoteServices
@testable import GlassRemoteUI
import Testing

@MainActor
@Suite("Torrent library presentation")
struct TorrentListPresentationTests {
    @Test("queued seasons stay visible outside collapsed groups and completed filters")
    func queuedSeasonsStayVisible() throws {
        let source = UUID()
        let existing = [filterRecord(source, season: 1, complete: true), filterRecord(source, season: 2, complete: true)]
        let pending = TorrentRecord(filterRecord(source, season: 3, complete: false).summary,
            sourceID: source, isAdding: true, additionID: UUID())
        pending.updateAddition(phase: .failed, error: "RPC unavailable")
        let records = existing + [pending]
        let rows = TorrentListRowPresentation.rows(records: records, pendingRenameNames: [:], expandedGroupIDs: [])
        #expect(rows.filter { $0.id == pending.id }.count == 1)
        #expect(rows.first?.id == pending.id)
        #expect(rows.count == 2)
        for filter in [TorrentGroup.all, .downloading, .completed] {
            #expect(TorrentLibraryFilter.records(records, group: filter).contains { $0 === pending })
        }
    }

    @Test("one snapshot supplies native indices, section boundaries and selection neighbors")
    func sharedLayoutBoundaries() throws {
        let source = UUID()
        let complete = filterRecord(source, season: 1, complete: true)
        let partial = filterRecord(source, season: 2, complete: false)
        let movie = filterRecord(source, season: 3, complete: true, rawName: "Finished Movie.mkv")
        let collapsedRows = TorrentListRowPresentation.rows(records: [movie, complete, partial], pendingRenameNames: [:], expandedGroupIDs: [])
        let groupID = try #require(collapsedRows.first { !$0.isTorrent }?.id)
        let collapsed = TorrentListLayout(rows: collapsedRows)
        #expect(collapsed.nativeRowIDs == [nil, groupID, nil, movie.id])
        #expect(collapsed.headerIndices == ["unfinished": 0, "finished": 2])
        #expect(collapsed.nextRowIDs.isEmpty)

        let expandedRows = TorrentListRowPresentation.rows(records: [movie, complete, partial], pendingRenameNames: [:], expandedGroupIDs: [groupID])
        let expanded = TorrentListLayout(rows: expandedRows)
        #expect(expanded.nativeRowIDs == [nil, groupID, complete.id, partial.id, nil, movie.id])
        #expect(expanded.headerIndices == ["unfinished": 0, "finished": 4])
        #expect(collapsed.sections.allSatisfy { !$0.allowsStickyHeader })
        #expect(expanded.sections.first { $0.id == "unfinished" }?.allowsStickyHeader == true)
        #expect(expanded.sections.first { $0.id == "finished" }?.allowsStickyHeader == false)
        let loading = try #require(expanded.sections.first { $0.id == "unfinished" })
        let standalone = try #require(collapsedRows.first { $0.isTorrent })
        let short = TorrentListSection(id: loading.id, title: loading.title, rows: [loading.rows[0], standalone])
        #expect(!short.allowsStickyHeader)
        let anotherMovie = filterRecord(source, season: 4, complete: false, rawName: "Another Movie.mkv")
        let anotherRow = TorrentListRowPresentation(id: anotherMovie.id, kind: .torrent(record: anotherMovie, displayName: nil))
        let long = TorrentListSection(id: loading.id, title: loading.title, rows: short.rows + [anotherRow])
        #expect(long.allowsStickyHeader)
        for lowercase in [false, true] {
            let entries = expanded.entries(lowercase: lowercase)
            #expect(entries.count == expanded.nativeRowIDs.count)
            for (id, index) in expanded.rowIndices { #expect(entries[index].id == id) }
            for (id, index) in expanded.headerIndices { #expect(entries[index].id == "section:" + id) }
        }
        #expect(expanded.showsSeparator(after: groupID, selection: nil))
        #expect(expanded.showsSeparator(after: complete.id, selection: nil))
        #expect(!expanded.showsSeparator(after: partial.id, selection: nil))
        #expect(!expanded.showsSeparator(after: movie.id, selection: nil))
        #expect(!expanded.showsSeparator(after: groupID, selection: complete.id))
        #expect(!expanded.showsSeparator(after: complete.id, selection: complete.id))
        #expect(expanded.showsSeparator(after: complete.id, selection: "unmounted"))
        #expect(expanded.movingFolderIDs == [complete.id, partial.id])
        let high = filterRecord(source, season: 10, complete: false, rawName: "High.mkv", priority: 1, added: 40)
        let old = filterRecord(source, season: 11, complete: false, rawName: "Old.mkv", priority: 0, added: 10)
        let new = filterRecord(source, season: 12, complete: false, rawName: "New.mkv", priority: 0, added: 20)
        let earlier = filterRecord(source, season: 13, complete: true, rawName: "Earlier.mkv", added: 30, done: 100)
        let latest = filterRecord(source, season: 14, complete: true, rawName: "Latest.mkv", added: 5, done: 200)
        let sortRows = TorrentListRowPresentation.rows(records: [new, earlier, old, latest, high, complete, partial], pendingRenameNames: [:], expandedGroupIDs: [groupID])
        let sorted = TorrentListLayout(rows: sortRows, sorting: TorrentListSorting(loading: .priority, completed: .lastDownloaded))
        #expect(sorted.sections.first { $0.id == "unfinished" }?.rows.map(\.id) == [high.id, old.id, new.id, groupID, complete.id, partial.id])
        #expect(sorted.sections.first { $0.id == "finished" }?.rows.map(\.id) == [latest.id, earlier.id])
        #expect(TorrentListLayout(rows: sortRows).sections.first { $0.id == "finished" }?.rows.map(\.id) == [earlier.id, latest.id])
    }

    @Test("server queue telemetry cannot reorder the visible library")
    func queueTelemetryKeepsOrder() throws {
        let source = UUID()
        func record(_ id: Int, queue: Int) -> TorrentRecord {
            TorrentRecord(TorrentSummary(id: id, hashString: "q-\(id)", name: id == 1 ? "Wolf" : "Click", status: 0,
                percentDone: 0.5, rateDownload: 0, rateUpload: 0, sizeWhenDone: 100,
                leftUntilDone: 50, eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: nil,
                queuePosition: queue), sourceID: source)
        }
        let first = record(1, queue: 8)
        let second = record(2, queue: 0)
        let rows = TorrentListRowPresentation.rows(records: [first, second], pendingRenameNames: [:], expandedGroupIDs: [])
        #expect(rows.map(\.id) == [first.id, second.id])
        let updated = record(1, queue: 20)
        #expect(!first.apply(updated.summary, displayName: nil))
        #expect(first.summary.queuePosition == 20)
    }

    @Test("unfinished section keeps completed siblings in their expanded group")
    func unfinishedSectionsKeepGroupsTogether() throws {
        let source = UUID()
        let complete = filterRecord(source, season: 1, complete: true)
        let partial = filterRecord(source, season: 2, complete: false)
        let finished = filterRecord(source, season: 3, complete: true, rawName: "Finished Movie.mkv")
        let records = [finished, complete, partial]
        let collapsed = TorrentListRowPresentation.rows(records: records, pendingRenameNames: [:], expandedGroupIDs: [])
        let groupID = try #require(collapsed.first { !$0.isTorrent }?.id)
        let rows = TorrentListRowPresentation.rows(records: records, pendingRenameNames: [:], expandedGroupIDs: [groupID])
        let sections = TorrentListSection.sections(for: rows)
        #expect(sections.map(\.id) == ["unfinished", "finished"])
        #expect(sections.map(\.title) == ["Loading", "Completed"])
        #expect(TorrentListSection.sections(for: rows, lowercase: true).map(\.title) == ["loading", "completed"])
        #expect(sections[0].rows.map(\.id) == [groupID, complete.id, partial.id])
        #expect(sections[1].rows.map(\.id) == [finished.id])
        #expect(Set(sections.flatMap { $0.rows.map(\.id) }).count == rows.count)
    }

    @Test("completion keeps torrent identities in one list and removes the loading title")
    func completionPreservesFlatIdentity() throws {
        let source = UUID()
        let loading = filterRecord(source, season: 1, complete: false, rawName: "Loading Movie.mkv")
        let completed = filterRecord(source, season: 2, complete: true, rawName: "Completed Movie.mkv")
        func entries() -> [TorrentListEntry] {
            TorrentListEntry.entries(for: TorrentListRowPresentation.rows(records: [loading, completed], pendingRenameNames: [:], expandedGroupIDs: []), lowercase: false)
        }
        let before = entries().map(\.id)
        let done = filterRecord(source, season: 1, complete: true, rawName: "Loading Movie.mkv")
        _ = loading.apply(done.summary, displayName: nil)
        let after = entries().map(\.id)
        #expect(before.contains("section:unfinished"))
        #expect(!after.contains("section:unfinished"))
        #expect(after == ["section:finished", loading.id, completed.id])
        #expect(Set(before.filter { !$0.hasPrefix("section:") }) == Set(after.filter { !$0.hasPrefix("section:") }))
    }

    @Test("group completion follows member completion even with rounded engine progress")
    func groupCompletionAndStorageErrors() {
        func torrent(_ id: Int, progress: Double, error: Int? = nil) -> TorrentSummary {
            TorrentSummary(id: id, hashString: "member-\(id)", name: "Season \(id)", status: 0,
                percentDone: progress, rateDownload: 0, rateUpload: 0, sizeWhenDone: 100,
                leftUntilDone: 1, eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: "/downloads",
                error: error, errorString: error == 3 ? "No data found!" : nil)
        }
        let finished = TorrentNameSequenceGroup(id: "group", displayName: "Show", torrents: [torrent(1, progress: 1), torrent(2, progress: 1)])
        #expect(finished.summary.isCompleted)
        let mixed = TorrentNameSequenceGroup(id: "group", displayName: "Show", torrents: [torrent(1, progress: 1), torrent(2, progress: 0.99)])
        #expect(!mixed.summary.isCompleted)
        let unavailable = TorrentNameSequenceGroup(id: "group", displayName: "Show", torrents: [torrent(1, progress: 1), torrent(2, progress: 1, error: 3)])
        #expect(!unavailable.summary.hasStorageError)
        #expect(unavailable.summary.errorString == nil)
        #expect(unavailable.locationErrors.isEmpty)
        let missing = TorrentNameSequenceGroup(id: "group", displayName: "Show", torrents: [torrent(1, progress: 1, error: 3), torrent(2, progress: 1, error: 3)])
        #expect(missing.summary.hasStorageError)
        #expect(missing.summary.errorString == "No data found!")
        #expect(missing.locationErrors.count == 2)
    }

    @Test("unfinished live seasons override missing completed seasons and seeding siblings")
    func groupTransferStatePriority() {
        func season(_ id: Int, progress: Double, status: Int = 0, error: Int? = nil) -> TorrentSummary {
            TorrentSummary(id: id, hashString: "season-\(id)", name: "Fargo \(id)", status: status,
                percentDone: progress, rateDownload: 0, rateUpload: 0, sizeWhenDone: 100,
                leftUntilDone: progress == 1 ? 0 : 100, eta: -1, uploadRatio: 0,
                peersConnected: nil, downloadDir: "/downloads", error: error)
        }
        let dead = [season(1, progress: 1, error: 3), season(2, progress: 1, error: 3)]
        let paused = season(3, progress: 0)
        let downloading = season(4, progress: 0.2, status: 4)
        let seeding = season(5, progress: 1, status: 6)
        let pausedGroup = TorrentNameSequenceGroup(id: "group", displayName: "Fargo", torrents: dead + [paused, seeding])
        #expect(!pausedGroup.summary.hasStorageError)
        #expect(pausedGroup.summary.isUnfinished)
        #expect(!pausedGroup.summary.canStopTransfer)
        #expect(pausedGroup.transferTorrents.map(\.id) == [3])
        let active = TorrentNameSequenceGroup(id: "group", displayName: "Fargo", torrents: dead + [paused, downloading])
        #expect(!active.summary.hasStorageError)
        #expect(active.summary.canStopTransfer)
        #expect(active.summary.isDownloading)
        let missingOnly = TorrentNameSequenceGroup(id: "group", displayName: "Fargo", torrents: dead)
        #expect(missingOnly.summary.hasStorageError)
        #expect(missingOnly.summary.isCompleted)
    }

    @Test("same torrents on two sources form independent groups")
    func groupsKeepTheirSource() throws {
        let first = UUID()
        let second = UUID()
        let records = [first, second].flatMap { sourceID in
            [record(sourceID, season: 1), record(sourceID, season: 2)]
        }
        let defaultRows = TorrentListRowPresentation.rows(records: records, pendingRenameNames: [:], expandedGroupIDs: [])
        let groups = defaultRows.filter { !$0.isTorrent }
        #expect(groups.count == 2)
        #expect(defaultRows.count == 2)
        #expect(groups.allSatisfy { $0.groupIsExpanded == false })
        let rows = TorrentListRowPresentation.rows(
            records: records, pendingRenameNames: [:], expandedGroupIDs: Set(groups.map(\.id))
        )
        #expect(Set(rows.map(\.id)).count == rows.count)
        for group in groups {
            let members = try #require(group.groupMemberIDs)
            #expect(members.count == 2)
            #expect(members.allSatisfy { id in records.first { $0.id == id }?.sourceID == group.sourceID })
            #expect(group.selectedGroup?.torrents.count == 2)
        }

        let collapsed = TorrentListRowPresentation.rows(
            records: records, pendingRenameNames: [:], expandedGroupIDs: [groups[1].id]
        )
        #expect(collapsed.filter { $0.isTorrent && $0.sourceID == first }.isEmpty)
        #expect(collapsed.filter { $0.isTorrent && $0.sourceID == second }.count == 2)
    }

    @Test("a pending rename changes only the record on its source")
    func renameKeepsItsSource() throws {
        let first = record(UUID(), season: 1)
        let second = record(UUID(), season: 1)
        let rows = TorrentListRowPresentation.rows(
            records: [first, second], pendingRenameNames: [first.id: "Renamed"], expandedGroupIDs: []
        )
        guard case let .torrent(_, firstName) = try #require(rows.first { $0.id == first.id }).kind,
              case let .torrent(_, secondName) = try #require(rows.first { $0.id == second.id }).kind else {
            Issue.record("Expected individual torrent rows")
            return
        }
        #expect(firstName == "Renamed")
        #expect(secondName == nil)
    }

    @Test("season folders keep a series group title and short child names")
    func seasonFolderNamesInLibrary() throws {
        let sourceID = UUID()
        let seasons = [4, 5].map { season in
            TorrentRecord(TorrentSummary(
                id: season, hashString: "fargo-\(season)", name: "Season \(season)",
                status: TransmissionTorrentStatus.stopped.rawValue, percentDone: 0,
                rateDownload: 0, rateUpload: 0, sizeWhenDone: 100, leftUntilDone: 100,
                eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: "/Volumes/and/Fargo"
            ), sourceID: sourceID)
        }
        let loneRows = TorrentListRowPresentation.rows(records: [seasons[0]], pendingRenameNames: [:], expandedGroupIDs: [])
        guard case let .torrent(_, loneName) = try #require(loneRows.first).kind else {
            Issue.record("Expected a lone season torrent")
            return
        }
        #expect(loneName == "Fargo 4")
        let collapsed = TorrentListRowPresentation.rows(records: seasons, pendingRenameNames: [:], expandedGroupIDs: [])
        let group = try #require(collapsed.first)
        #expect(collapsed.count == 1)
        #expect(group.selectedGroup?.displayName == "Fargo")
        let expanded = TorrentListRowPresentation.rows(records: seasons, pendingRenameNames: [:], expandedGroupIDs: [group.id])
        let names = expanded.compactMap { row -> String? in
            guard case let .torrent(_, name) = row.kind else { return nil }
            return name
        }
        #expect(names == ["Season 4", "Season 5"])
    }

    @Test("seasons sharing one flat root retain grouping with short child names")
    func flatSeasonFolderNames() throws {
        let sourceID = UUID()
        let seasons = [4, 5].map { season in
            TorrentRecord(TorrentSummary(
                id: season, hashString: "fargo-\(season)", name: "Fargo",
                status: TransmissionTorrentStatus.stopped.rawValue, percentDone: 0,
                rateDownload: 0, rateUpload: 0, sizeWhenDone: 100, leftUntilDone: 100,
                eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: "/Volumes/and"
            ), sourceID: sourceID, displayName: "Fargo \(season)")
        }
        let collapsed = TorrentListRowPresentation.rows(records: seasons, pendingRenameNames: [:], expandedGroupIDs: [])
        let group = try #require(collapsed.first)
        #expect(collapsed.count == 1)
        #expect(group.selectedGroup?.displayName == "Fargo")
        let expanded = TorrentListRowPresentation.rows(records: seasons, pendingRenameNames: [:], expandedGroupIDs: [group.id])
        let names = expanded.compactMap { row -> String? in
            guard case let .torrent(_, name) = row.kind else { return nil }
            return name
        }
        #expect(names == ["Season 4", "Season 5"])
        #expect(seasons.allSatisfy { $0.summary.name == "Fargo" && $0.summary.downloadDir == "/Volumes/and" })
    }

    @Test("unfinished filter keeps the complete group, including finished siblings")
    func unfinishedFilterKeepsGroups() throws {
        let source = UUID()
        let complete = filterRecord(source, season: 3, complete: true)
        let stopped = filterRecord(source, season: 4, complete: false)
        let filtered = TorrentLibraryFilter.records([complete, stopped], group: .downloading)
        #expect(filtered.map(\.id) == [complete.id, stopped.id])
        let rows = TorrentListRowPresentation.rows(records: filtered, pendingRenameNames: [:], expandedGroupIDs: [])
        let group = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(group.selectedGroup?.displayName == "Fargo")
        #expect(group.selectedGroup?.torrents.count == 2)
        #expect(TorrentLibraryFilter.records([complete, stopped], group: .completed).isEmpty)
    }

    @Test("finished series disappear without affecting another source's unfinished series")
    func filterKeepsSourceBoundaries() {
        let first = UUID()
        let second = UUID()
        let done = [3, 4].map { filterRecord(first, season: $0, complete: true) }
        let unfinished = [filterRecord(second, season: 3, complete: true), filterRecord(second, season: 4, complete: false)]
        let all = done + unfinished
        #expect(TorrentLibraryFilter.records(all, group: .downloading).map(\.id) == unfinished.map(\.id))
        #expect(TorrentLibraryFilter.records(all, group: .completed).map(\.id) == done.map(\.id))
        #expect(TorrentLibraryFilter.records(all, group: .all).map(\.id) == all.map(\.id))
    }

    @Test("filter preserves aliases and excludes downloads already finished in full")
    func filterUsesAliasesAndActiveState() throws {
        let source = UUID()
        let first = filterRecord(source, season: 4, complete: true, rawName: "Fargo", displayName: "Fargo 4")
        let second = filterRecord(source, season: 5, complete: false, rawName: "Fargo", displayName: "Fargo 5")
        #expect(TorrentLibraryFilter.records([first, second], group: .downloading).count == 2)
        let active = filterRecord(source, season: 1, complete: true, downloading: true)
        #expect(TorrentLibraryFilter.records([active], group: .downloading).isEmpty)
        let lone = filterRecord(source, season: 2, complete: false, rawName: "Movie.mkv")
        #expect(TorrentLibraryFilter.records([lone], group: .downloading).count == 1)
    }

    private func filterRecord(_ source: UUID, season: Int, complete: Bool, downloading: Bool = false,
                              rawName: String? = nil, displayName: String? = nil, priority: Int? = nil, added: Int? = nil, done: Int? = nil) -> TorrentRecord {
        TorrentRecord(TorrentSummary(id: season, hashString: "fargo-\(season)", name: rawName ?? "Fargo \(season)",
            status: downloading ? TransmissionTorrentStatus.downloading.rawValue : TransmissionTorrentStatus.stopped.rawValue,
            percentDone: complete ? 1 : 0.5, rateDownload: 0, rateUpload: 0,
            sizeWhenDone: 100, leftUntilDone: complete ? 0 : 50, eta: -1, uploadRatio: 0,
            peersConnected: nil, downloadDir: "/downloads", bandwidthPriority: priority, addedDate: added, doneDate: done), sourceID: source, displayName: displayName)
    }

    private func record(_ sourceID: UUID, season: Int) -> TorrentRecord {
        TorrentRecord(TorrentSummary(
            id: season, hashString: "season-\(season)", name: "Example Season \(season)",
            status: TransmissionTorrentStatus.stopped.rawValue, percentDone: 0.5,
            rateDownload: 0, rateUpload: 0, sizeWhenDone: 100, leftUntilDone: 50,
            eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: nil
        ), sourceID: sourceID)
    }
}

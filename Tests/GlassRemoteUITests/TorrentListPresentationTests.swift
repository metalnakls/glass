import Foundation
import GlassRemoteCore
@testable import GlassRemoteServices
@testable import GlassRemoteUI
import Testing

@MainActor
@Suite("Torrent library presentation")
struct TorrentListPresentationTests {
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
        #expect(unavailable.summary.hasStorageError)
        #expect(unavailable.summary.errorString == "No data found!")
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

    @Test("season folders display their series title before and after grouping")
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
        #expect(names == ["Fargo 4", "Fargo 5"])
    }

    @Test("seasons sharing one flat root still group by their saved names")
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
        #expect(names == ["Fargo 4", "Fargo 5"])
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

    @Test("filter preserves flat-root display aliases and active finished torrents")
    func filterUsesAliasesAndActiveState() throws {
        let source = UUID()
        let first = filterRecord(source, season: 4, complete: true, rawName: "Fargo", displayName: "Fargo 4")
        let second = filterRecord(source, season: 5, complete: false, rawName: "Fargo", displayName: "Fargo 5")
        #expect(TorrentLibraryFilter.records([first, second], group: .downloading).count == 2)
        let active = filterRecord(source, season: 1, complete: true, downloading: true)
        #expect(TorrentLibraryFilter.records([active], group: .downloading).count == 1)
        let lone = filterRecord(source, season: 2, complete: false, rawName: "Movie.mkv")
        #expect(TorrentLibraryFilter.records([lone], group: .downloading).count == 1)
    }

    private func filterRecord(_ source: UUID, season: Int, complete: Bool, downloading: Bool = false,
                              rawName: String? = nil, displayName: String? = nil) -> TorrentRecord {
        TorrentRecord(TorrentSummary(id: season, hashString: "fargo-\(season)", name: rawName ?? "Fargo \(season)",
            status: downloading ? TransmissionTorrentStatus.downloading.rawValue : TransmissionTorrentStatus.stopped.rawValue,
            percentDone: complete ? 1 : 0.5, rateDownload: 0, rateUpload: 0,
            sizeWhenDone: 100, leftUntilDone: complete ? 0 : 50, eta: -1, uploadRatio: 0,
            peersConnected: nil, downloadDir: "/downloads"), sourceID: source, displayName: displayName)
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

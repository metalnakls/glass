import Foundation
import Testing
import GlassRemoteCore
@testable import GlassRemoteServices
@testable import GlassRemoteUI

@MainActor @Suite("Retroactive season labels")
struct SeasonGroupingTests {
    @Test("new seasons join existing series despite an omitted leading article", arguments: [false, true], [false, true])
    func omittedArticle(pending: Bool, legacyFolders: Bool) throws {
        let source = UUID()
        func record(_ number: Int) -> TorrentRecord {
            let title = number == 4 ? "Walking Dead" : "The Walking Dead"
            let native = legacyFolders && number != 4
            return TorrentRecord(TorrentSummary(id: number, hashString: "s\(number)",
                name: native ? "Season \(number)" : title, status: 0, percentDone: 0,
                rateDownload: 0, rateUpload: 0, sizeWhenDone: 100, leftUntilDone: 100,
                eta: -1, uploadRatio: 0, peersConnected: nil,
                downloadDir: native ? "/downloads/The Walking Dead" : "/downloads", fileCount: 10),
                sourceID: source, displayName: native ? nil : title,
                season: native ? nil : .init(title: title, season: number),
                isAdding: number == 4 && pending, additionID: number == 4 && pending ? UUID() : nil)
        }
        let existing = [record(2), record(3)]
        let baseline = try #require(TorrentListRowPresentation.rows(records: existing, pendingRenameNames: [:], expandedGroupIDs: []).first)
        let added = record(4)
        for phase in [TorrentAdditionPhase.queued, .failed] {
            if pending { added.updateAddition(phase: phase, error: phase == .failed ? "RPC unavailable" : nil) }
            let records = existing + [added]
            let rows = TorrentListRowPresentation.rows(records: records, pendingRenameNames: [:], expandedGroupIDs: [baseline.id])
            #expect(rows.map(\.id) == [baseline.id] + records.map(\.id))
            #expect(rows.first?.groupMemberIDs == records.map(\.id))
            let labels = rows.dropFirst().compactMap { row -> String? in
                if case let .torrent(_, title) = row.kind { return title }; return nil
            }
            #expect(labels == ["Season 2", "Season 3", "Season 4"])
            #expect(added.summary.name == "Walking Dead")
        }
    }

    @Test(arguments: [[1, 2], [2, 1]])
    func additionOrder(seasons: [Int]) throws {
        let source = UUID()
        func record(_ season: Int) -> TorrentRecord {
            TorrentRecord(TorrentSummary(id: season, hashString: "season-\(season)",
                name: "Santa.Clarita.Diet.s0\(season).WEB-DL", status: 0, percentDone: 0,
                rateDownload: 0, rateUpload: 0, sizeWhenDone: 100, leftUntilDone: 100,
                eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: "/downloads", fileCount: 10),
                sourceID: source, displayName: "Santa Clarita Diet",
                season: .init(title: "Santa Clarita Diet", season: season))
        }
        let first = record(seasons[0])
        let lone = TorrentListRowPresentation.rows(records: [first], pendingRenameNames: [:], expandedGroupIDs: [])
        if case let .torrent(_, displayName) = try #require(lone.first).kind { #expect(displayName == "Santa Clarita Diet") }
        else { Issue.record("Lone season should be a torrent") }
        let second = record(seasons[1])
        let grouped = TorrentListRowPresentation.rows(records: [first, second], pendingRenameNames: [:], expandedGroupIDs: [])
        let group = try #require(grouped.first)
        #expect(grouped.count == 1)
        #expect(group.selectedGroup?.displayName == "Santa Clarita Diet")
        let expanded = TorrentListRowPresentation.rows(records: [first, second], pendingRenameNames: [:], expandedGroupIDs: [group.id])
        let labels = expanded.dropFirst().compactMap { row -> String? in
            if case let .torrent(_, displayName) = row.kind { return displayName }; return nil
        }
        #expect(labels == ["Season 1", "Season 2"])
        #expect(first.summary.name == "Santa.Clarita.Diet.s0\(seasons[0]).WEB-DL")
        #expect(first.summary.downloadDir == "/downloads")
    }
}

import Foundation
import GlassRemoteCore
@testable import GlassRemoteServices
@testable import GlassRemoteUI
import Testing

@MainActor
@Suite("Torrent library presentation")
struct TorrentListPresentationTests {
    @Test("same torrents on two sources form independent groups")
    func groupsKeepTheirSource() throws {
        let first = UUID()
        let second = UUID()
        let records = [first, second].flatMap { sourceID in
            [record(sourceID, season: 1), record(sourceID, season: 2)]
        }
        let rows = TorrentListRowPresentation.rows(records: records, pendingRenameNames: [:], collapsedGroupIDs: [])
        let groups = rows.filter { !$0.isTorrent }
        #expect(groups.count == 2)
        #expect(Set(rows.map(\.id)).count == rows.count)
        for group in groups {
            let members = try #require(group.groupMemberIDs)
            #expect(members.count == 2)
            #expect(members.allSatisfy { id in records.first { $0.id == id }?.sourceID == group.sourceID })
            #expect(group.selectedGroup?.torrents.count == 2)
        }

        let collapsed = TorrentListRowPresentation.rows(
            records: records, pendingRenameNames: [:], collapsedGroupIDs: [groups[0].id]
        )
        #expect(collapsed.filter { $0.isTorrent && $0.sourceID == first }.isEmpty)
        #expect(collapsed.filter { $0.isTorrent && $0.sourceID == second }.count == 2)
    }

    @Test("a pending rename changes only the record on its source")
    func renameKeepsItsSource() throws {
        let first = record(UUID(), season: 1)
        let second = record(UUID(), season: 1)
        let rows = TorrentListRowPresentation.rows(
            records: [first, second], pendingRenameNames: [first.id: "Renamed"], collapsedGroupIDs: []
        )
        guard case let .torrent(_, firstName) = try #require(rows.first { $0.id == first.id }).kind,
              case let .torrent(_, secondName) = try #require(rows.first { $0.id == second.id }).kind else {
            Issue.record("Expected individual torrent rows")
            return
        }
        #expect(firstName == "Renamed")
        #expect(secondName == nil)
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

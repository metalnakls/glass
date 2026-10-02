import Foundation
import GlassRemoteCore
@testable import GlassRemoteServices
@testable import GlassRemoteUI
import Testing

@MainActor
@Suite("Torrent add preparation")
struct TorrentAddPreparationTests {
    @Test("smart names are applied before the user edits the draft")
    func smartNamesStartApplied() throws {
        let item = makeItem()
        #expect(item.name == "Show Name 1")
        #expect(item.selectedFileIndices == [0, 1])
        let plan = try #require(item.namingPlan())
        #expect(plan.pathRenames.map(\.name) == ["S01E01 — Pilot.mkv", "S01E02.mkv"])
    }

    @Test("deselected files are excluded from downloading and renaming")
    func selectionReachesSubmission() throws {
        let item = makeItem()
        item.setFileWanted(1, false)
        #expect(item.fileSelection.filesWanted == [0])
        #expect(item.fileSelection.filesUnwanted == [1])
        let plan = try #require(item.namingPlan())
        #expect(plan.pathRenames.count == 1)
        #expect(plan.pathRenames[0].path == item.draft.preview.files[0].name)
        item.setAllFilesWanted(false)
        #expect(!item.canAdd)
    }

    @Test("manual root names are preserved with smart file renaming")
    func manualNameSurvivesSmartPlan() throws {
        let item = makeItem()
        item.name = "My Show"
        #expect(try #require(item.namingPlan()).rootName == "My Show")
        item.restoreOriginalName()
        #expect(item.name == item.draft.preview.name)
    }

    @Test("an inferred season starts named and joins either a single season or an existing group", arguments: [[2], [2, 3]])
    func inferredSeasonJoinsLibrary(existingSeasons: [Int]) throws {
        let item = makeItem(rootName: "Fargo", files: ["S05E01.mkv", "S05E22.mkv"])
        #expect(item.name == "Fargo 5")
        #expect(try #require(item.namingPlan()).rootName == "Fargo 5")
        item.restoreOriginalName()
        #expect(item.name == "Fargo")
        item.applySmartName()
        #expect(item.name == "Fargo 5")

        let sourceID = UUID()
        let records = (existingSeasons + [5]).map { season in
            TorrentRecord(TorrentSummary(
                id: season, hashString: "season-\(season)", name: season == 5 ? item.name : "Fargo \(season)",
                status: TransmissionTorrentStatus.stopped.rawValue, percentDone: 0,
                rateDownload: 0, rateUpload: 0, sizeWhenDone: 100, leftUntilDone: 100,
                eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: nil
            ), sourceID: sourceID)
        }
        let rows = TorrentListRowPresentation.rows(records: records, pendingRenameNames: [:], expandedGroupIDs: [])
        #expect(rows.count == 1)
        let group = try #require(rows.first)
        #expect(!group.isTorrent)
        #expect(group.groupMemberIDs?.count == records.count)
        #expect(group.groupIsExpanded == false)
        #expect(group.selectedGroup?.displayName == "Fargo")
    }

    private func makeItem(
        rootName: String = "Show.Name.S01.1080p",
        files: [String] = ["Show.Name.S01E01.Pilot.1080p.mkv", "Show.Name.S01E02.1080p.mkv"]
    ) -> TorrentBatchItemState {
        func string(_ value: String) -> String { "\(value.utf8.count):\(value)" }
        let encodedFiles = files.map { "d6:lengthi100e4:pathl\(string($0))ee" }.joined()
        let data = Data("d4:infod5:filesl\(encodedFiles)e4:name\(string(rootName))ee".utf8)
        return TorrentBatchItemState(draft: TorrentFileAddDraft(
            data: data,
            preview: TorrentFilePreview(data: data, fallbackURL: nil),
            sourceURL: URL(fileURLWithPath: "/tmp/preview.torrent")
        ))
    }
}

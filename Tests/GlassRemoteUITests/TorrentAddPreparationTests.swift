import Foundation
import GlassRemoteCore
@testable import GlassRemoteUI
import Testing

@MainActor
@Suite("Torrent add preparation")
struct TorrentAddPreparationTests {
    @Test("smart names are applied before the user edits the draft")
    func smartNamesStartApplied() throws {
        let item = makeItem()
        #expect(item.name == "Show Name")
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

    private func makeItem() -> TorrentBatchItemState {
        func string(_ value: String) -> String { "\(value.utf8.count):\(value)" }
        let files = ["Show.Name.S01E01.Pilot.1080p.mkv", "Show.Name.S01E02.1080p.mkv"]
        let encodedFiles = files.map { "d6:lengthi100e4:pathl\(string($0))ee" }.joined()
        let data = Data("d4:infod5:filesl\(encodedFiles)e4:name\(string("Show.Name.S01.1080p"))ee".utf8)
        return TorrentBatchItemState(draft: TorrentFileAddDraft(
            data: data,
            preview: TorrentFilePreview(data: data, fallbackURL: nil),
            sourceURL: URL(fileURLWithPath: "/tmp/preview.torrent")
        ))
    }
}

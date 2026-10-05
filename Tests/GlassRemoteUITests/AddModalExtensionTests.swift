import Foundation
import Testing
import GlassRemoteCore
@testable import GlassRemoteServices
@testable import GlassRemoteUI

@MainActor @Suite("Add title extension presentation")
struct AddModalExtensionTests {
    @Test("background imports preserve metainfo, source and parsed preview")
    func importedDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("movie.torrent")
        let data = Data("d4:infod6:lengthi100e4:name9:movie.mkvee".utf8)
        try data.write(to: url)
        let draft = try await TorrentFileAddDraft.load(from: url)
        #expect(draft.data == data)
        #expect(draft.sourceURL == url)
        #expect(draft.preview.name == "movie.mkv")
        #expect(draft.preview.size == 100)
        await #expect(throws: CocoaError.self) {
            _ = try await TorrentFileAddDraft.load(from: directory.appendingPathComponent("missing.torrent"))
        }
    }

    @Test func singleMovieTitle() throws {
        let name = "The.Mosquito.Coast.1986.720p.mkv"
        let data = Data("d4:infod6:lengthi100e4:name\(name.utf8.count):\(name)ee".utf8)
        let draft = TorrentFileAddDraft(data: data, preview: TorrentFilePreview(data: data, fallbackURL: nil), sourceURL: URL(fileURLWithPath: "/tmp/movie.torrent"))
        let item = TorrentBatchItemState(draft: draft)
        #expect(item.presentedName(holdingOption: false) == "The Mosquito Coast")
        #expect(item.presentedName(holdingOption: false, showExtensions: true) == "The Mosquito Coast.mkv")
        #expect(item.presentedName(holdingOption: true) == "The.Mosquito.Coast.1986.720p")
        #expect(item.presentedName(holdingOption: true, showExtensions: true) == name)
        item.editPresentedName("My Movie")
        #expect(item.name == "My Movie.mkv")
        #expect(item.namingPlan()?.rootName == "My Movie.mkv")
        #expect(TorrentExtensionPolicy.hiddenExtension(paths: ["movie.mkv", "notes.txt"]) == nil)
    }
}

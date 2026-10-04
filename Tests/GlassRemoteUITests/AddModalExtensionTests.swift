import Foundation
import Testing
import GlassRemoteCore
@testable import GlassRemoteServices
@testable import GlassRemoteUI

@MainActor @Suite("Add title extension presentation")
struct AddModalExtensionTests {
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

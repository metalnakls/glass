import Testing
import Foundation
import GlassRemoteCore
@testable import GlassRemoteUI

@Suite("Torrent folder artwork")
struct TorrentArtworkKindTests {
    @MainActor @Test("a grouped season uses folder styling even when it has movie artwork")
    func groupedSeasonOverridesMovieArtwork() throws {
        let torrent = TorrentSummary(id: 3, hashString: "season-3", name: "Season 3.mkv", status: 0,
            percentDone: 1, rateDownload: 0, rateUpload: 0, sizeWhenDone: 100,
            leftUntilDone: 0, eta: -1, uploadRatio: 0, peersConnected: nil,
            downloadDir: "/Movies/Fargo", fileCount: 1)
        let input = try #require(TorrentThumbnailInput.movie(torrent, sourceID: UUID(), isLocal: true))
        let grouped = TorrentRowView(torrent: torrent, folderID: "season-3", thumbnailInput: input, toggleTransfer: { false })
        #expect(grouped.iconRole == .folder)
        let standalone = TorrentRowView(torrent: torrent, thumbnailInput: input, toggleTransfer: { false })
        #expect(standalone.iconRole == .artwork)
    }
}

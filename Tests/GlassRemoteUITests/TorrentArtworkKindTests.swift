import Testing
import Foundation
import GlassRemoteCore
@testable import GlassRemoteUI

@Suite("Torrent folder artwork")
struct TorrentArtworkKindTests {
    @Test func singleFileFolders() {
        #expect(TorrentArtworkKind.isFolder(name: "Fargo", fileCount: 1))
        #expect(TorrentArtworkKind.isFolder(name: "Roger Dodger", fileCount: 1))
        #expect(TorrentArtworkKind.isFolder(name: "Unknown", fileCount: nil))
        #expect(TorrentArtworkKind.isFolder(name: "Series.S05", fileCount: 10))
        #expect(!TorrentArtworkKind.isFolder(name: "Movie.mkv", fileCount: 1))
    }

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

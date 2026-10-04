import Testing
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
}

import Foundation
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("Artwork lookahead")
struct TorrentArtworkPreloaderTests {
    @Test("ends and empty lists never request invalid rows")
    func bounds() {
        #expect(TorrentArtworkPreloader.indices(visible: NSRange(location: 0, length: 2), count: 3) == [0, 1, 2])
        #expect(TorrentArtworkPreloader.indices(visible: NSRange(location: 2, length: 1), count: 3) == [2, 1, 0])
        #expect(TorrentArtworkPreloader.indices(visible: NSRange(location: NSNotFound, length: 0), count: 3).isEmpty)
        #expect(TorrentArtworkPreloader.indices(visible: NSRange(location: 0, length: 1), count: 0).isEmpty)
    }
}

import Foundation
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("Artwork lookahead")
struct TorrentArtworkPreloaderTests {
    @Test("visible rows lead a bounded buffer on both sides")
    func buffer() {
        let indices = TorrentArtworkPreloader.indices(visible: NSRange(location: 10, length: 4), count: 100)
        #expect(Array(indices.prefix(4)) == [10, 11, 12, 13])
        #expect(indices.count == 16)
        #expect(Set(indices) == Set(4..<20))
        #expect(indices[4...7] == [14, 9, 15, 8])
    }

    @Test("ends and empty lists never request invalid rows")
    func bounds() {
        #expect(TorrentArtworkPreloader.indices(visible: NSRange(location: 0, length: 2), count: 3) == [0, 1, 2])
        #expect(TorrentArtworkPreloader.indices(visible: NSRange(location: 2, length: 1), count: 3) == [2, 1, 0])
        #expect(TorrentArtworkPreloader.indices(visible: NSRange(location: NSNotFound, length: 0), count: 3).isEmpty)
        #expect(TorrentArtworkPreloader.indices(visible: NSRange(location: 0, length: 1), count: 0).isEmpty)
    }
}

import Testing
@testable import GlassRemoteUI

@Suite("File priority swipes")
struct TorrentFilePriorityTests {
    @Test func repeatSwipeRestoresNormal() {
        for high in [true, false] {
            let first = TorrentFilePriority.swiping(current: 0, high: high)
            #expect(first == (high ? 1 : -1))
            #expect(TorrentFilePriority.swiping(current: first, high: high) == 0)
        }
    }

    @Test func oppositeSwipeChangesPriorityDirectly() {
        #expect(TorrentFilePriority.swiping(current: -1, high: true) == 1)
        #expect(TorrentFilePriority.swiping(current: 1, high: false) == -1)
    }
}

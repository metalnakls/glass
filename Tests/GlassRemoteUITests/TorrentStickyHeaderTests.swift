import Foundation
import Testing
@testable import GlassRemoteUI

@Suite("Continuous sticky titles")
struct TorrentStickyHeaderTests {
    let frames = [CGRect(x: 8, y: 6, width: 480, height: 48), CGRect(x: 8, y: 186, width: 480, height: 48)]
    func viewport(_ y: CGFloat) -> CGRect { CGRect(x: 0, y: y, width: 500, height: 600) }

    @Test("inline-to-pinned handoff preserves the actual frame and padding")
    func measuredHandoff() throws {
        #expect(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(6)) == nil)
        let pinned = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(7)))
        #expect(pinned.titles[0].frame == CGRect(x: 8, y: 0, width: 480, height: 48))
        #expect(pinned.backdropOpacity < 1)
    }
    @Test("incoming title pushes the old title without overlap or a material reset")
    func continuousPush() throws {
        let before = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(137)))
        #expect(before.titles[0].frame.minY == 0)
        let pushing = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(150)))
        #expect(pushing.titles.map(\.index) == [0, 1])
        #expect(pushing.titles[0].frame.minY == -12)
        #expect(pushing.titles[0].frame.maxY == pushing.titles[1].frame.minY)
        let handoff = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(187)))
        #expect(handoff.titles[0].index == 1)
        #expect(handoff.titles[0].frame.minX == 8)
        #expect(handoff.titles[0].frame.minY == 0)
        #expect(handoff.backdropOpacity == pushing.backdropOpacity)
    }
    @Test("reversing scroll reproduces the same geometry and respects horizontal origin")
    func reverseAndHorizontalOrigin() throws {
        let down = TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(150))
        _ = TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(220))
        #expect(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(150)) == down)
        let shifted = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: CGRect(x: 3, y: 150, width: 500, height: 600)))
        #expect(shifted.titles.allSatisfy { $0.frame.minX == 5 })
    }
}

@testable import GlassRemoteUI
import Testing
import Foundation

struct TorrentFocusTests {
    @Test func scrollingDoesNotRearmWhileSelectedRowStaysVisible() {
        var state = TorrentFocusState()
        state.select()
        state.visibility(true)
        #expect(state.showsFocus)
        state.liveScroll(true)
        state.visibility(true)
        state.liveScroll(false)
        #expect(!state.showsFocus)
        state.select()
        #expect(state.showsFocus)
    }

    @Test func returningRowRearmsAfterScrollingEnds() {
        var state = TorrentFocusState()
        state.visibility(true)
        state.liveScroll(true)
        state.visibility(false)
        state.visibility(true)
        state.scroll() // Momentum continues after the row returns.
        #expect(!state.showsFocus)
        state.liveScroll(false)
        #expect(state.showsFocus)
    }

    @Test func wheelScrollingWaitsForReentryOrClick() {
        var state = TorrentFocusState()
        state.visibility(true)
        state.scroll()
        #expect(!state.showsFocus)
        state.visibility(false)
        #expect(!state.showsFocus)
        state.visibility(true)
        #expect(state.showsFocus)
    }

    @Test(arguments: [-30.0, 0.0, 250.0, 570.0])
    func selectedRowIsOutsideBothBlurRegions(y: Double) {
        let row = CGRect(x: 0, y: y, width: 400, height: 60)
        let regions = TorrentFocusRegions(viewport: CGSize(width: 400, height: 600), selectedRow: row)
        #expect(regions.above.isEmpty || !regions.above.intersects(row))
        #expect(regions.below.isEmpty || !regions.below.intersects(row))
        #expect(regions.above.minY == 0)
        #expect(regions.below.maxY == 600)
        #expect(regions.above.height >= 0)
        #expect(regions.below.height >= 0)
    }

}

import Foundation
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("Highlight width tuning")
struct HighlightWidthTests {
    @Test func keepsCenter() {
        let original = CGRect(x: 20, y: 80, width: 360, height: 48)
        let wider = TorrentListElevationController.resizedHighlight(original, adjustment: 40)
        #expect(wider == CGRect(x: 0, y: 80, width: 400, height: 48))
        let narrower = TorrentListElevationController.resizedHighlight(original, adjustment: -80)
        #expect(narrower.midX == original.midX)
        #expect(narrower.width == 280)
        let data = Data("{\"GlassList.highlightWidth\":-80}".utf8)
        #expect(throws: Never.self) { try GlassTuningUpdates.validate(data, against: GlassAppearanceDefaults.bundled) }
    }
}

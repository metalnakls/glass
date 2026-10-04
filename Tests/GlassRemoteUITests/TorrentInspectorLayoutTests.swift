@testable import GlassRemoteUI
import Testing

@Suite("Inspector resizing")
struct TorrentInspectorLayoutTests {
    @Test("narrow windows collapse and wider windows restore the inspector")
    func resizing() {
        #expect(!TorrentInspectorLayout.isVisible(width: 700, wasVisible: true))
        #expect(TorrentInspectorLayout.isVisible(width: 800, wasVisible: false))
        #expect(TorrentInspectorLayout.isVisible(width: 740, wasVisible: true))
        #expect(!TorrentInspectorLayout.isVisible(width: 740, wasVisible: false))
    }
}

@testable import GlassRemoteUI
import Foundation
import GlassRemoteCore
import Testing

@Suite("Inspector resizing")
struct TorrentInspectorLayoutTests {
    @Test("live progress keeps a group request stable but membership and file edits restart it")
    func groupRefreshIdentity() {
        let sourceID = UUID()
        func input(progress: Double = 0, hash: String = "one", revision: Int = 0, isActive: Bool = true) -> TorrentGroupInspectorLoadInput {
            let torrent = TorrentSummary(id: 1, hashString: hash, name: "Season 1", status: 4,
                percentDone: progress, rateDownload: progress * 1000, rateUpload: 0,
                sizeWhenDone: 100, leftUntilDone: 100, eta: -1, uploadRatio: 0,
                peersConnected: nil, downloadDir: "/downloads")
            return TorrentGroupInspectorLoadInput(sourceID: sourceID,
                group: TorrentNameSequenceGroup(id: "group", displayName: "Show", torrents: [torrent]),
                revision: revision, isActive: isActive)
        }
        #expect(input() == input(progress: 0.5))
        #expect(input() != input(hash: "two"))
        #expect(input() != input(revision: 1))
        #expect(input() != input(isActive: false))
    }

    @Test("narrow windows collapse and wider windows restore the inspector")
    func resizing() {
        #expect(!TorrentInspectorLayout.isVisible(width: 700, wasVisible: true))
        #expect(TorrentInspectorLayout.isVisible(width: 800, wasVisible: false))
        #expect(TorrentInspectorLayout.isVisible(width: 740, wasVisible: true))
        #expect(!TorrentInspectorLayout.isVisible(width: 740, wasVisible: false))
    }
}

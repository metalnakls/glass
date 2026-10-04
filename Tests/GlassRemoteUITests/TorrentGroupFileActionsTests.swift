import Testing
import GlassRemoteCore
@testable import GlassRemoteUI

@MainActor @Suite("Group folder actions")
struct TorrentGroupFileActionsTests {
    @Test func containingFolder() {
        #expect(TorrentFileActions.groupDirectory(["/downloads/Fargo", "/downloads/Fargo"]) == "/downloads/Fargo")
        #expect(TorrentFileActions.groupDirectory(["/downloads/Fargo/Season 1", "/downloads/Fargo/Season 2"]) == "/downloads/Fargo")
        #expect(TorrentFileActions.groupDirectory(["/first", "/second"]) == nil)
        #expect(TorrentFileActions.groupDirectory([String]()) == nil)
    }
    @Test func existingSharedRoot() {
        let torrents = (1...2).map { season in
            TorrentSummary(id: season, hashString: "s\(season)", name: "Fargo", status: 0, percentDone: 0,
                rateDownload: 0, rateUpload: 0, sizeWhenDone: 100, leftUntilDone: 100,
                eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: "/downloads", fileCount: 10)
        }
        #expect(TorrentFileActions.groupDirectory(torrents) == "/downloads/Fargo")
    }

}

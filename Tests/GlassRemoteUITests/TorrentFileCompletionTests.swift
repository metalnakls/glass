import GlassRemoteCore
import Testing
@testable import GlassRemoteUI

@Suite("Completed inspector files")
struct TorrentFileCompletionTests {
    @Test func latestFileStatsDetermineEditableFiles() {
        let details = TorrentDetails(id: 1, hashString: "files", name: "Files", files: [
            TorrentFile(name: "done", length: 100, bytesCompleted: 0),
            TorrentFile(name: "downloading", length: 100, bytesCompleted: 100)
        ], fileStats: [
            TorrentFileStats(bytesCompleted: 100, wanted: true, priority: 0),
            TorrentFileStats(bytesCompleted: 50, wanted: true, priority: 0)
        ])
        #expect(TorrentFileCompletion.isComplete(details, index: 0))
        #expect(!TorrentFileCompletion.isComplete(details, index: 1))
        #expect(!TorrentFileCompletion.isComplete(details, index: 2))
    }

    @Test func fileCompletionWorksWithoutOptionalStats() {
        let details = TorrentDetails(id: 1, hashString: "files", name: "Files", files: [
            TorrentFile(name: "done", length: 100, bytesCompleted: 100)
        ])
        #expect(TorrentFileCompletion.isComplete(details, index: 0))
    }
}

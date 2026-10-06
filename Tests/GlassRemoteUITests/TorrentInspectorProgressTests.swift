import GlassRemoteCore
@testable import GlassRemoteUI
import Testing

@Suite("Persistent inspector progress")
struct TorrentInspectorProgressTests {
    private func torrent(_ id: Int, bytes: UInt64, progress: Double) -> TorrentSummary {
        TorrentSummary(id: id, hashString: "season\(id)", name: "Season \(id)", status: 4,
            percentDone: progress, rateDownload: 0, rateUpload: 0, sizeWhenDone: bytes,
            leftUntilDone: 0, eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: "/downloads")
    }

    @Test("completed and downloading seasons fill independently, not as one continuous fill")
    func independentSeasons() {
        let progress = TorrentInspectorProgress(torrents: [torrent(1, bytes: 100, progress: 0),
            torrent(2, bytes: 200, progress: 1), torrent(3, bytes: 100, progress: 0.5)])
        #expect(progress.segments.map(\.fraction) == [0, 1, 0.5])
        #expect(progress.segments.map(\.id) == ["season1", "season2", "season3"])
        #expect(progress.totalBytes == 400)
        #expect(progress.fraction == 0.625)
    }

    @Test("a single torrent uses the same progress model and unknown totals stay finite")
    func singleAndUnknown() {
        #expect(TorrentInspectorProgress(torrents: [torrent(1, bytes: 100, progress: 0.4)]).fraction == 0.4)
        let unknown = TorrentInspectorProgress(torrents: [torrent(1, bytes: 0, progress: .nan)])
        #expect(unknown.fraction == 0)
        #expect(unknown.segments[0].fraction == 0)
    }

    @MainActor @Test("Finder device tags distinguish the rack model without per-server hardcoding")
    func finderModelMapping() {
        #expect(NativeLocationIconCache.deviceType(model: "MacPro7,1@ECOLOR=226,226,224")?.identifier == "com.apple.macpro-2019-rackmount")
        #expect(NativeLocationIconCache.deviceType(model: "MacPro7,1")?.identifier == "com.apple.macpro-2019")
        #expect(NativeLocationIconCache.deviceType(model: "unknown-test-device") == nil)
    }
}

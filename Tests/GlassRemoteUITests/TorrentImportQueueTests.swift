import Foundation
import GlassRemoteCore
@testable import GlassRemoteUI
import Testing

@MainActor
@Suite("Finder torrent imports")
struct TorrentImportQueueTests {
    @Test("A second open event joins the in-flight batch without losing either file")
    func joinsOpenEvents() async {
        let queue = TorrentImportQueue()
        let loader = SuspendedLoader()
        var delivered: [String] = []
        let first = URL(fileURLWithPath: "/tmp/first.torrent")
        let second = URL(fileURLWithPath: "/tmp/second.torrent")
        let update: @MainActor ([TorrentFileAddDraft], [URL], Bool) -> Void = { drafts, _, _ in
            delivered = drafts.compactMap { $0.sourceURL?.lastPathComponent }
        }
        queue.enqueue([first], load: loader.load, update: update)
        await loader.waitForRequest()
        queue.enqueue([second, first], load: loader.load, update: update)
        loader.resume()
        await loader.waitForRequest()
        #expect(delivered == ["first.torrent"])
        loader.resume()
        while delivered.count < 2 { await Task.yield() }
        #expect(delivered == ["first.torrent", "second.torrent"])
        queue.cancel()
    }

    @Test("Dismissing the sheet prevents a late loader from resurrecting it")
    func cancelsLateResult() async {
        let queue = TorrentImportQueue()
        let loader = SuspendedLoader()
        var deliveries = 0
        queue.enqueue([URL(fileURLWithPath: "/tmp/canceled.torrent")], load: loader.load) { _, _, finished in
            if finished { deliveries += 1 }
        }
        await loader.waitForRequest()
        queue.cancel()
        loader.resume()
        while !loader.finished { await Task.yield() }
        #expect(deliveries == 0)
    }
}

@MainActor
private final class SuspendedLoader {
    var continuation: CheckedContinuation<TorrentFileAddDraft?, Never>?
    private var url: URL?
    var finished = false
    func load(_ url: URL) async -> TorrentFileAddDraft? {
        self.url = url
        let draft = await withCheckedContinuation { continuation = $0 }
        finished = true
        return draft
    }
    func waitForRequest() async {
        while continuation == nil { await Task.yield() }
    }
    func resume() {
        let request = continuation
        continuation = nil
        let data = Data("d4:infod6:lengthi100e4:name9:Movie.mkvee".utf8)
        request?.resume(returning: TorrentFileAddDraft(data: data,
            preview: TorrentFilePreview(data: data, fallbackURL: url), sourceURL: url!))
    }
}

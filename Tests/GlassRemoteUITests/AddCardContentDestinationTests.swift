import AppKit
import GlassRemoteCore
import GlassRemoteServices
import SwiftUI
import Testing
@testable import GlassRemoteUI

@MainActor @Suite(.serialized)
struct AddCardContentDestinationTests {
    @Test("The native Add card opens inside the payload root and captures the content destination",
          arguments: [true, false])
    func albumOrMovie(album: Bool) async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileProfileStore(fileURL: folder.appendingPathComponent("profiles.json"))
        let profile = RemoteProfile(name: "Fixture share", rpcURL: URL(string: "http://127.0.0.1:1")!, username: "")
        try store.saveProfiles([profile])
        let model = RemoteAppModel(profileStore: store, credentialStore: KeychainCredentialStore(service: "Glass.AddCardTest"))
        model.selectedProfileID = album ? profile.id : model.localSourceID
        let names = album ? ["01. Artist - First.flac", "02. Artist - Second.flac", "Cover.jpg"] : ["Movie.mkv", "English.srt"]
        let root = "[2026-05-15] Fixture " + (album ? "Album" : "Movie")
        let files = names.map { "d6:lengthi1e4:pathl\($0.utf8.count):\($0)ee" }.joined()
        let data = Data("d4:infod5:filesl\(files)e4:name\(root.utf8.count):\(root)12:piece lengthi16384e6:pieces20:01234567890123456789ee".utf8)
        let draft = TorrentFileAddDraft(data: data, preview: .init(data: data, fallbackURL: nil), sourceURL: nil)
        var captured: TorrentAddDraft?
        let card = AddTorrentBatchView(model: model, platformIntegration: UnavailableGlassPlatformIntegration.shared,
            drafts: [draft], capture: { captured = $0 }, discardDraft: {},
            submit: { _, _, _, _, _, _ in fatalError("Preview cannot submit during this test") }, didFinishAdding: { _, _ in })
        let host = NSHostingView(rootView: card)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func table(_ view: NSView) -> NSTableView? {
            if let view = view as? NSTableView { return view }
            return view.subviews.lazy.compactMap(table).first
        }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if captured?.items.first?.name == (album ? "Fixture Album" : "Fixture Movie"),
               table(host)?.numberOfRows == names.count { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let saved = try #require(captured)
        #expect(saved.sourceID == (album ? model.localSourceID : profile.id))
        #expect(saved.downloadDirectory == (album ? TorrentDownloadDirectoryPolicy.downloadsDirectory : nil))
        #expect(saved.items.first?.name == (album ? "Fixture Album" : "Fixture Movie"))
        #expect(table(host)?.numberOfRows == names.count)
    }
}

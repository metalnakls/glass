import AppKit
import GlassRemoteCore
@testable import GlassRemoteServices
import SwiftUI
import Observation
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("Production list responsiveness", .serialized)
struct TorrentListResponsivenessTests {
    @Test("production torrent rows settle and scroll")
    func settlesAndScrolls() async throws {
        _ = NSApplication.shared
        GlassAppearanceDefaults.register()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = RemoteAppModel(profileStore: FileProfileStore(fileURL: folder.appendingPathComponent("profiles.json")),
            credentialStore: KeychainCredentialStore(service: "GlassTests.DraftInteraction"))
        let source = UUID()
        let records = (0..<16).map { id in
            TorrentRecord(TorrentSummary(id: id, hashString: "fixture-\(id)", name: "Movie \(id).mkv", status: 0,
                percentDone: id < 8 ? 0.5 : 1, rateDownload: 0, rateUpload: 0, sizeWhenDone: 100,
                leftUntilDone: id < 8 ? 50 : 0, eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: nil), sourceID: source)
        }
        let state = ListInteractionState()
        state.selection = records[0].id
        let fixture = TorrentListView(model: model, platformIntegration: UnavailableGlassPlatformIntegration.shared,
            records: records, drafts: [], structureRevision: 0, pendingRenameNames: [:], pendingRenameOldNames: [:],
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }), presentation: TorrentListPresentationModel(),
            revealSelectionToken: UUID(), remove: { _, _, _ in }, removeSelected: { _ in })
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 760, height: 444),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: NavigationStack { fixture }.inspector(isPresented: .constant(true)) { Color.clear.inspectorColumnWidth(min: 260, ideal: 300, max: 340) }.toolbarVisibility(.hidden, for: .windowToolbar).background(MainWindowChrome()).ignoresSafeArea(.container, edges: .top))
        window.contentView = host
        defer { window.close() }
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        let native = try #require(table(in: host))
        #expect(native.numberOfRows == 18)
        let scroll = try #require(native.enclosingScrollView)
        for y in stride(from: 0, through: 400, by: 20) {
            let start = ContinuousClock.now
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
            #expect(start.duration(to: .now) < .seconds(1))
        }
    }
}

@MainActor @Observable
private final class ListInteractionState { var selection: String? }

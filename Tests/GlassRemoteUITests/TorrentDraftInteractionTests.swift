import AppKit
import GlassRemoteCore
import GlassRemoteServices
import SwiftUI
import Observation
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("Native draft interactions", .serialized)
struct TorrentDraftInteractionTests {
    @Test("production List permits native draft selection")
    func selectionAndDeletion() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = RemoteAppModel(profileStore: FileProfileStore(fileURL: folder.appendingPathComponent("profiles.json")),
            credentialStore: KeychainCredentialStore(service: "GlassTests.DraftInteraction"))
        let draft = TorrentAddDraft(id: UUID(), magnet: "magnet:?dn=Fixture")
        let state = DraftInteractionState()
        let fixture = TorrentListView(model: model, platformIntegration: UnavailableGlassPlatformIntegration.shared,
            records: [], drafts: [draft], structureRevision: 0, pendingRenameNames: [:], pendingRenameOldNames: [:],
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }), presentation: TorrentListPresentationModel(),
            revealSelectionToken: UUID(), remove: { _, _, _ in }, removeSelected: { _ in })
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: fixture)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
            if let table = table(in: host), table.numberOfRows == 2 { break }
        }
        let native = try #require(table(in: host))
        #expect(native.numberOfRows == 2)
        #expect(native.delegate?.tableView?(native, shouldSelectRow: 1) ?? true)
        native.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(10))
            if state.selection == draft.listID { break }
        }
        #expect(state.selection == draft.listID)

    }
}

@MainActor @Observable
private final class DraftInteractionState {
    var selection: String?
}

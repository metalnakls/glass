import Foundation
import Testing
@testable import GlassRemoteUI

@MainActor
@Suite("Add draft recovery")
struct TorrentAddDraftStoreTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("add-drafts.json")
    }

    private func item(id: UUID = UUID(), name: String = "Movie.mkv") -> TorrentAddDraftItem {
        TorrentAddDraftItem(
            id: id,
            data: Data("d4:infod6:lengthi100e4:name9:Movie.mkvee".utf8),
            sourceURL: nil,
            name: name
        )
    }

    @Test("native list selection resolves only its own draft for removal")
    func selectedDraftRemoval() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = TorrentAddDraftStore(fileURL: file)
        let first = TorrentAddDraft(id: UUID(), items: [item(name: "First")])
        let second = TorrentAddDraft(id: UUID(), items: [item(name: "Second")])
        store.capture(first)
        store.capture(second)
        #expect(store.draft(selectionID: nil) == nil)
        #expect(store.draft(selectionID: "torrent:another") == nil)
        let selected = try #require(store.draft(selectionID: first.listID))
        store.discard(selected.id)
        store.flush()
        let restored = TorrentAddDraftStore(fileURL: file)
        #expect(restored.draft(selectionID: first.listID) == nil)
        #expect(restored.draft(selectionID: second.listID)?.id == second.id)
        #expect(TorrentSwipeRowKind.draft.removalLabel(deleteData: false) == "Discard Draft")
        #expect(TorrentSwipeRowKind.draft.removalLabel(deleteData: true) == "Discard Draft")
    }

    @Test("A captured Add survives a relaunch")
    func reloadsCapturedDraft() {
        let fileURL = temporaryFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let itemID = UUID()
        let draftID = UUID()
        let store = TorrentAddDraftStore(fileURL: fileURL)
        store.capture(TorrentAddDraft(
            id: draftID,
            sourceID: UUID(),
            downloadDirectory: "/tmp/Movies",
            pendingURLs: [URL(fileURLWithPath: "/tmp/second.torrent")],
            frontItemID: itemID,
            items: [item(id: itemID, name: "Edited Name")]
        ))
        store.flush()

        let reloaded = TorrentAddDraftStore(fileURL: fileURL)
        #expect(reloaded.drafts.count == 1)
        #expect(reloaded.drafts.first?.id == draftID)
        #expect(reloaded.drafts.first?.items.first?.name == "Edited Name")
        #expect(reloaded.drafts.first?.pendingURLs == [URL(fileURLWithPath: "/tmp/second.torrent")])
    }

    @Test("Cancel removes the draft so it is never offered")
    func discardRemovesFromDisk() {
        let fileURL = temporaryFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let cancelledID = UUID()
        let keptID = UUID()
        let store = TorrentAddDraftStore(fileURL: fileURL)
        store.capture(TorrentAddDraft(id: cancelledID, magnet: "magnet:?xt=urn:btih:one"))
        store.capture(TorrentAddDraft(id: keptID, magnet: "magnet:?xt=urn:btih:two"))
        store.flush()
        store.discard(cancelledID)
        store.flush()

        let reloaded = TorrentAddDraftStore(fileURL: fileURL)
        #expect(reloaded.drafts.map(\.id) == [keptID])
    }

    @Test("Every edit updates the same record instead of adding a card")
    func captureReplacesRecord() {
        let store = TorrentAddDraftStore(fileURL: nil)
        let draftID = UUID()
        store.capture(TorrentAddDraft(id: draftID, items: [item(name: "First")]))
        store.capture(TorrentAddDraft(id: draftID, items: [item(name: "Second")]))
        #expect(store.drafts.count == 1)
        #expect(store.drafts.first?.items.first?.name == "Second")
    }

    @Test("A magnet draft offers its display name and no parsed items")
    func magnetDraftSummary() {
        let magnet = "magnet:?xt=urn:btih:abc&dn=The%20Movie"
        let draft = TorrentAddDraft(id: UUID(), magnet: magnet)
        #expect(draft.displayName == "The Movie")
        #expect(draft.isEmpty == false)
    }
}

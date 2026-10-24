import Foundation
import GlassRemoteCore
@testable import GlassRemoteServices
@testable import GlassRemoteUI
import Testing

@MainActor struct TorrentItemActionsTests {
    @Test("all Add phases use the same removal identity standalone and inside a group")
    func pendingActionParity() throws {
        let source = UUID(), additionID = UUID()
        func summary(_ index: Int) -> TorrentSummary {
            TorrentSummary(id: index, hashString: "item-\(index)", name: "Series \(index)",
                status: 0, percentDone: 0, rateDownload: 0, rateUpload: 0,
                sizeWhenDone: 100, leftUntilDone: 100, eta: -1, uploadRatio: 0,
                peersConnected: nil, downloadDir: "/downloads")
        }
        let live = TorrentRecord(summary(1), sourceID: source)
        let pending = TorrentRecord(summary(2), sourceID: source, isAdding: true, additionID: additionID)
        for phase in [TorrentAdditionPhase.queued, .resolvingMetadata, .adding, .confirming, .failed] {
            pending.updateAddition(phase: phase, error: nil)
            let rows = TorrentListRowPresentation.rows(records: [live, pending], pendingRenameNames: [:], expandedGroupIDs: [])
            let group = try #require(rows.first)
            let standalone = TorrentItemActions.removals(selection: pending.id,
                records: [live, pending], rows: rows, drafts: [])
            #expect(standalone.count == 1)
            if case let .addition(id) = standalone.first { #expect(id == additionID) }
            else { Issue.record("A pending item must resolve to its queue identity") }
            let grouped = TorrentItemActions.removals(selection: group.id,
                records: [live, pending], rows: rows, drafts: [])
            #expect(grouped.count == 2)
            #expect(grouped.contains { if case let .addition(id) = $0 { return id == additionID }; return false })
            #expect(grouped.contains { if case let .transfer(torrent, id) = $0 { return torrent.hashString == live.hashString && id == source }; return false })
        }
    }

    @Test("editor drafts and stale selections share the same resolver")
    func draftAndStaleSelection() {
        let draft = TorrentAddDraft(id: UUID())
        let actions = TorrentItemActions.removals(selection: draft.listID, records: [], rows: [], drafts: [draft])
        #expect(actions.count == 1)
        if case let .draft(selected) = actions.first { #expect(selected.id == draft.id) }
        else { Issue.record("Draft must resolve to saved editor state") }
        #expect(TorrentItemActions.removals(selection: "gone", records: [], rows: [], drafts: [draft]).isEmpty)
    }
}

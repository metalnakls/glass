import Foundation
import GlassRemoteCore
@testable import GlassRemoteServices
@testable import GlassRemoteUI
import Testing

@MainActor @Suite("Native torrent reordering")
struct TorrentListReorderTests {
    private func record(_ id: Int, source: UUID, name: String? = nil, complete: Bool = false, adding: Bool = false) -> TorrentRecord {
        TorrentRecord(TorrentSummary(id: id, hashString: "move-\(id)", name: name ?? [1: "Aurora", 2: "Solar Drift", 3: "Quiet Coast"][id] ?? "Archive", status: 0,
            percentDone: complete ? 1 : 0.5, rateDownload: 0, rateUpload: 0, sizeWhenDone: 100,
            leftUntilDone: complete ? 0 : 50, eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: nil),
            sourceID: source, isAdding: adding)
    }
    private func rows(_ records: [TorrentRecord], expanded: Set<String> = []) -> [TorrentListRowPresentation] {
        TorrentListRowPresentation.rows(records: records, pendingRenameNames: [:], expandedGroupIDs: expanded)
    }

    @Test("normal row moves preserve all identities and owner")
    func moveBefore() throws {
        let source = UUID()
        let a = record(1, source: source), b = record(2, source: source), c = record(3, source: source)
        let plan = try #require(TorrentListReorderPlan(sources: [c.id], destination: .before(a.id), rows: rows([a, b, c])))
        #expect(plan.orderedRows.map(\.id) == [c.id, a.id, b.id])
        #expect(plan.hashes == [c.hashString])
        #expect(plan.beforeHashes == [a.hashString])
        #expect(plan.sourceID == source)
    }

    @Test("end moves stay in their section ahead of completed rows")
    func sectionEnd() throws {
        let source = UUID()
        let a = record(1, source: source), b = record(2, source: source), done = record(3, source: source, complete: true)
        let plan = try #require(TorrentListReorderPlan(sources: [a.id], destination: .end, rows: rows([a, b, done])))
        #expect(plan.orderedRows.map(\.id) == [b.id, a.id, done.id])
        #expect(plan.beforeHashes == [done.hashString])
    }

    @Test("headers and pending additions cannot be dragged; cross-owner moves are rejected")
    func invalidMoves() {
        let source = UUID()
        let a = record(1, source: source), pending = record(2, source: source, adding: true), other = record(3, source: UUID())
        let input = rows([a, pending, other])
        #expect(TorrentListReorderPlan(sources: ["section:unfinished"], destination: .end, rows: input) == nil)
        #expect(TorrentListReorderPlan(sources: [pending.id], destination: .before(a.id), rows: input) == nil)
        #expect(TorrentListReorderPlan(sources: [a.id], destination: .before(other.id), rows: input) == nil)
    }

    @Test("an expanded group moves with its seasons as one queue block")
    func expandedGroup() throws {
        let source = UUID()
        let a = record(1, source: source, name: "Fargo Season 1"), b = record(2, source: source, name: "Fargo Season 2"), movie = record(3, source: source)
        let collapsed = rows([a, b, movie])
        let group = try #require(collapsed.first { $0.groupMemberIDs != nil })
        let input = rows([a, b, movie], expanded: [group.id])
        let plan = try #require(TorrentListReorderPlan(sources: [group.id], destination: .end, rows: input))
        #expect(plan.orderedRows.map(\.id) == [movie.id, group.id, a.id, b.id])
        #expect(Set(plan.hashes) == Set([a.hashString, b.hashString]))
    }
}

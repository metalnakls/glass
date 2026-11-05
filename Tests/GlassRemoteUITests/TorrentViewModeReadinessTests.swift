import AppKit
import Testing
@testable import GlassRemoteUI

@Suite("View-mode native layout readiness without windows")
struct TorrentViewModeReadinessTests {
    @Test("container layout with no row anchors waits instead of consuming sources")
    func delayedRows() {
        let waiting = TorrentViewModeReadiness.decision(containerLaidOut: true, scrollSubmitted: true,
            sourceIDs: ["a", "b"], destinationIDs: ["a", "b"],
            visibleDestinationIDs: [], hasPendingVisibleLayout: false)
        #expect(waiting == .wait)
        let incomingButNotLaidOut = TorrentViewModeReadiness.decision(containerLaidOut: true, scrollSubmitted: true,
            sourceIDs: ["a", "b"], destinationIDs: ["a", "b"],
            visibleDestinationIDs: ["a"], hasPendingVisibleLayout: true)
        #expect(incomingButNotLaidOut == .wait)
        let laidOut = TorrentViewModeReadiness.decision(containerLaidOut: true, scrollSubmitted: true,
            sourceIDs: ["a", "b"], destinationIDs: ["a", "b"],
            visibleDestinationIDs: ["a"], hasPendingVisibleLayout: false)
        #expect(laidOut == .ready)
    }

    @Test("an unrelated early row cannot consume the handoff before its scroll anchor arrives")
    func partialRegistration() {
        #expect(TorrentViewModeReadiness.decision(containerLaidOut: true, scrollSubmitted: true,
            sourceIDs: ["selected"], destinationIDs: ["selected", "other"], visibleDestinationIDs: ["other"],
            hasPendingVisibleLayout: false, requiredAnchorID: "selected") == .wait)
        #expect(TorrentViewModeReadiness.decision(containerLaidOut: true, scrollSubmitted: true,
            sourceIDs: ["selected"], destinationIDs: ["selected", "other"], visibleDestinationIDs: ["selected", "other"],
            hasPendingVisibleLayout: false, requiredAnchorID: "selected") == .ready)
        #expect(TorrentViewModeReadiness.decision(containerLaidOut: true, scrollSubmitted: true,
            sourceIDs: ["selected"], destinationIDs: ["other"], visibleDestinationIDs: ["other"],
            hasPendingVisibleLayout: false, requiredAnchorID: "selected") == .settle)
    }

    @Test("a new layout pass is required after submitting scroll restoration")
    func restoredScrollLayout() {
        #expect(TorrentViewModeReadiness.decision(containerLaidOut: false, scrollSubmitted: true,
            sourceIDs: ["a"], destinationIDs: ["a"], visibleDestinationIDs: ["a"],
            hasPendingVisibleLayout: false) == .wait)
        #expect(TorrentViewModeReadiness.decision(containerLaidOut: true, scrollSubmitted: false,
            sourceIDs: ["a"], destinationIDs: ["a"], visibleDestinationIDs: ["a"],
            hasPendingVisibleLayout: false) == .wait)
    }

    @Test("empty or disjoint data settles; offscreen source IDs do not block visible destinations")
    func unmatchedData() {
        for ids: Set<String> in [[], ["new-item"]] {
            #expect(TorrentViewModeReadiness.decision(containerLaidOut: true, scrollSubmitted: true,
                sourceIDs: ["old-item"], destinationIDs: ids, visibleDestinationIDs: [],
                hasPendingVisibleLayout: false) == .settle)
        }
        #expect(TorrentViewModeReadiness.decision(containerLaidOut: true, scrollSubmitted: true,
            sourceIDs: ["a"], destinationIDs: ["a", "b"], visibleDestinationIDs: ["b"],
            hasPendingVisibleLayout: false) == .ready)
    }

    @MainActor @Test("tearing down an old viewport cannot cancel its replacement")
    func viewportIdentity() {
        let owner = TorrentViewModeTransition()
        let old = ViewModeViewportView()
        let replacement = ViewModeViewportView()
        old.owner = owner; replacement.owner = owner
        owner.attachViewport(old)
        owner.labels.visible = false
        owner.attachViewport(replacement)
        TorrentViewModeViewport.dismantleNSView(old, coordinator: ())
        #expect(owner.viewport === replacement)
        #expect(!owner.labels.visible)
        TorrentViewModeViewport.dismantleNSView(replacement, coordinator: ())
        #expect(owner.viewport == nil)
        #expect(owner.labels.visible)
    }
}

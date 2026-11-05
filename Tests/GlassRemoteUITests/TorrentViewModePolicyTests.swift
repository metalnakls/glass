import Foundation
import Testing
@testable import GlassRemoteUI

@Suite("View-mode handoff policy (no windows)")
struct TorrentViewModePolicyTests {
    @Test("explicit Regular stays Regular; size level is part of presentation identity")
    func requestedPresentation() {
        #expect(TorrentViewPresentation.requested(grid: false, iconsEnabled: true, compactEnabled: true, size: 0).mode == .compact)
        #expect(TorrentViewPresentation.requested(grid: false, iconsEnabled: true, compactEnabled: true, size: 1).mode == .regular)
        #expect(TorrentViewPresentation.requested(grid: true, iconsEnabled: true, compactEnabled: true, size: 0).mode == .icons)
        #expect(TorrentViewPresentation.requested(grid: true, iconsEnabled: false, compactEnabled: false, size: 0) == .init(mode: .regular, sizeLevel: 1))
        #expect(TorrentViewPresentation(mode: .regular, sizeLevel: 1) != .init(mode: .regular, sizeLevel: 2))
    }

    @Test("only stable IDs with measured visible endpoints can fly")
    func measuredPairs() {
        let old = CGRect(x: 10, y: 80, width: 16, height: 16)
        let new = CGRect(x: 140, y: 40, width: 64, height: 56)
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 400)
        let pairs = TorrentViewModeGeometry.matches(source: ["shared": old, "removed": old],
            destination: ["shared": new, "new": new], viewport: viewport)
        #expect(pairs == [.init(id: "shared", source: old, destination: new)])
        #expect(TorrentViewModeGeometry.matches(source: ["shared": old], destination: [:], viewport: viewport).isEmpty)
    }

    @Test("invisible, zero-sized and non-finite geometry never fabricates an origin")
    func invalidGeometry() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 400)
        let valid = CGRect(x: 10, y: 10, width: 16, height: 16)
        for invalid in [CGRect.zero, CGRect(x: 500, y: 500, width: 16, height: 16), CGRect(x: Double.infinity, y: 0, width: 16, height: 16)] {
            #expect(TorrentViewModeGeometry.matches(source: ["a": invalid], destination: ["a": valid], viewport: viewport).isEmpty)
            #expect(TorrentViewModeGeometry.matches(source: ["a": valid], destination: ["a": invalid], viewport: viewport).isEmpty)
        }
    }

    @MainActor @Test("late old-mode and old-generation endpoints cannot join a new handoff")
    func generations() {
        let owner = TorrentViewModeTransition()
        let old = TorrentArtworkTransitionContext(owner: owner, id: "a", mode: .icons)
        #expect(owner.accepts(old))
        owner.prepare(to: .regular, selection: nil, reduceMotion: false, destinationIDs: ["a"])
        #expect(!owner.accepts(old))
        #expect(owner.accepts(.init(owner: owner, id: "a", mode: .regular)))
        #expect(!owner.accepts(.init(owner: owner, id: "a", mode: .compact)))
        let regular = TorrentArtworkTransitionContext(owner: owner, id: "a", mode: .regular)
        owner.prepare(to: .compact, selection: nil, reduceMotion: true, destinationIDs: ["a"])
        #expect(!owner.accepts(regular))
        #expect(owner.accepts(.init(owner: owner, id: "a", mode: .compact)))
    }
}

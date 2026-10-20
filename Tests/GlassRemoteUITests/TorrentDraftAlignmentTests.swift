import AppKit
import GlassRemoteCore
import GlassRemoteServices
import SwiftUI
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("Draft control alignment", .serialized)
struct TorrentDraftAlignmentTests {
    @Test("draft and retry glass controls share their trailing column", arguments: [false, true], [false, true])
    func trailingAlignment(compact: Bool, grid: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = RemoteAppModel(profileStore: FileProfileStore(fileURL: folder.appendingPathComponent("profiles.json")),
            credentialStore: KeychainCredentialStore(service: "GlassTests.DraftAlignment"))
        let draft = TorrentAddDraft(id: UUID(), magnet: "magnet:?dn=Movie")
        let columns = TorrentRowColumns(showsArtwork: !compact, compact: compact, stateGap: 8)
        let torrent = TorrentSummary(id: 1, hashString: "fixture", name: "Movie", status: 0, percentDone: 0,
            rateDownload: 0, rateUpload: 0, sizeWhenDone: 100, leftUntilDone: 100, eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: nil)
        let draftView = TorrentDraftRow(model: model, draft: draft, grid: grid, rowHeight: 64,
            leadingPadding: TorrentRowColumns.horizontalInset, trailingPadding: TorrentRowColumns.horizontalInset,
            columns: columns, resume: {}, discard: {})
        let retryView = TorrentRowView(torrent: torrent, density: compact ? .compact : .regular, grid: grid,
            isAdding: true, additionPhase: .failed, toggleTransfer: { true })
            .padding(.horizontal, grid ? 0 : TorrentRowColumns.horizontalInset)
        let draftBounds = try await controlFrame(draftView, compact: compact, grid: grid)
        let retryBounds = try await controlFrame(retryView, compact: compact, grid: grid)
        #expect(abs(draftBounds.minX - retryBounds.minX) <= 0.5)
        #expect(abs(draftBounds.maxX - retryBounds.maxX) <= 0.5)
    }

    private func controlFrame<V: View>(_ view: V, compact: Bool, grid: Bool) async throws -> CGRect {
        _ = NSApplication.shared
        let height: CGFloat = grid ? 164 : 64
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 500, height: height),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.frame(width: 500, height: height)
            .background(Color.white).environment(\.colorScheme, .light))
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        // Native glass is composited outside cached screenshots. Measure its
        // actual AppKit backing views, without relying on private class names.
        let diameter = GlassListMetrics.stateDiameter(compact: compact && !grid)
        func frames(in view: NSView) -> [CGRect] {
            let frame = host.convert(view.bounds, from: view)
            let matches = abs(frame.width - diameter) < 0.5 && abs(frame.height - diameter) < 0.5 && frame.midX > 400
            return (matches ? [frame] : []) + view.subviews.flatMap { frames(in: $0) }
        }
        let controls = frames(in: host)
        let frame = try #require(controls.first)
        #expect(controls.allSatisfy { abs($0.midX - frame.midX) < 0.5 })
        return frame
    }
}

import AppKit
import SwiftUI
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("Artwork surface sizing without windows")
struct TorrentArtworkSurfaceSizingTests {
    @Test("native artwork wrapper preserves explicit layout slots", arguments: [CGSize(width: 64, height: 56), CGSize(width: 16, height: 16), CGSize(width: 36, height: 42)])
    func slots(_ size: CGSize) {
        let owner = TorrentViewModeTransition()
        let host = NSHostingView(rootView: Color.red.frame(width: size.width, height: size.height)
            .modifier(TorrentArtworkSurface())
            .environment(\.torrentArtworkTransition, .init(owner: owner, id: "fixture", mode: .icons)))
        let fitting = host.fittingSize
        #expect(abs(fitting.width - size.width) < 0.01)
        #expect(abs(fitting.height - size.height) < 0.01)
    }
}

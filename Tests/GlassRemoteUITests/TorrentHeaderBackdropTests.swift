import AppKit
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("Native header backdrop", .serialized)
struct TorrentHeaderBackdropTests {
    @Test("the blur fades after title exit and retains its gradient until the fade completes")
    func gradualExit() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 500, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let backdrop = HeaderBackdrop(frame: .init(x: 0, y: 0, width: 500, height: 400))
        backdrop.externallyHosted = true
        window.contentView = backdrop.pinnedSurface
        window.orderFront(nil)
        var appearance = TorrentHeaderAppearance()
        appearance.backgroundIn = 0
        appearance.backgroundOut = 1
        backdrop.configure(appearance)
        let host = TitleHost(title: "Queue", inset: 16)
        let headers = [TorrentStickyHeaders.Header(id: "queue", title: "Queue", index: 0, inset: 16)]
        backdrop.present(layout: .init(titles: [.init(index: 0,
            frame: .init(x: 0, y: 20, width: 500, height: 47), pinned: true)], backdropHeight: 115),
            headers: headers, hosts: ["queue": host])
        try await Task.sleep(for: .milliseconds(100))
        let effect = try #require(backdrop.pinnedSurface.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        #expect(effect.blendingMode == .withinWindow)
        #expect(effect.material == .headerView)
        let extent = effect.frame
        // The title has left, but its backdrop must not lose its size or vanish
        // in the same update. Test the presentation layer, not its target alpha.
        backdrop.present(layout: .init(titles: [], backdropHeight: 0),
                         headers: headers, hosts: ["queue": host], backdropActive: false)
        try await Task.sleep(for: .milliseconds(100))
        let fading = try #require(effect.layer?.presentation()?.opacity)
        if !ReduceMotion.enabled {
            #expect(fading > 0 && fading < Float(appearance.strength))
        }
        #expect(effect.frame == extent)
        #expect(effect.layer?.mask?.frame.size == extent.size)
        #expect(!effect.isHidden)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(effect.alphaValue == 0)
        #expect(effect.frame == extent)
    }
}

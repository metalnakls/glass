import AppKit
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("Native header backdrop", .serialized)
struct TorrentHeaderBackdropTests {
    @Test("the blur fades after title exit even when the scroll transaction disables layer actions", arguments: [false, true])
    func gradualExit(scrollDisablesActions: Bool) async throws {
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
        // Native scroll/layout callbacks can run inside a transaction that
        // disables actions. That must apply to coordinates, not the blur fade.
        CATransaction.begin()
        CATransaction.setDisableActions(scrollDisablesActions)
        backdrop.present(layout: .init(titles: [], backdropHeight: 0),
                         headers: headers, hosts: ["queue": host], backdropActive: false)
        #expect(CATransaction.disableActions() == scrollDisablesActions)
        CATransaction.commit()
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

    @Test("blur entrance and interrupted exit remain gradual inside scroll transactions")
    func interruptedFade() async throws {
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
        appearance.backgroundIn = 0.4
        appearance.backgroundOut = 1
        backdrop.configure(appearance)
        func present(_ active: Bool) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdrop.present(layout: .init(titles: [], backdropHeight: 115),
                             headers: [], hosts: [:], backdropActive: active)
            #expect(CATransaction.disableActions())
            CATransaction.commit()
        }
        present(true)
        let effect = try #require(backdrop.pinnedSurface.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        try await Task.sleep(for: .milliseconds(80))
        let entering = try #require(effect.layer?.presentation()?.opacity)
        if !ReduceMotion.enabled { #expect(entering > 0 && entering < Float(appearance.strength)) }
        try await Task.sleep(for: .milliseconds(450))
        present(false)
        try await Task.sleep(for: .milliseconds(180))
        let before = try #require(effect.layer?.presentation()?.opacity)
        present(true)
        try await Task.sleep(for: .milliseconds(30))
        let after = try #require(effect.layer?.presentation()?.opacity)
        if !ReduceMotion.enabled {
            #expect(before > 0 && before < Float(appearance.strength))
            #expect(abs(after - before) < 0.1)
            #expect(after < Float(appearance.strength))
        }
        try await Task.sleep(for: .milliseconds(450))
        #expect(abs((effect.layer?.presentation()?.opacity ?? 0) - Float(appearance.strength)) < 0.01)
        #expect(effect.frame.height == 115)
    }
    @Test("the header fade stays at the window top independently of bar, viewport and title positions", arguments: [0.0, 28.0, 44.0])
    func windowTopAlignment(barInset: CGFloat) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 500, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = HeaderViewportSurface(frame: .init(x: 0, y: 0, width: 500, height: 400))
        window.contentView = root
        let viewportInset: CGFloat = barInset == 44 ? 12 : 0
        let scroll = NSScrollView(frame: .init(x: 0, y: viewportInset, width: 500, height: 400 - viewportInset))
        let table = NSTableView(frame: .init(x: 0, y: 0, width: 500, height: 1000))
        table.headerView = nil
        scroll.documentView = table
        root.addSubview(scroll)
        let backdrop = HeaderBackdrop(frame: table.bounds)
        backdrop.externallyHosted = true
        table.addSubview(backdrop)
        // A safe-area bar can start below the clip viewport in a full-size-content
        // window. Only the title follows the viewport; the fade starts at the window top.
        let bar = HeaderViewportSurface(frame: .init(x: 0, y: barInset, width: 500, height: 47))
        root.addSubview(bar)
        backdrop.pinnedSurface.frame = bar.bounds
        bar.addSubview(backdrop.pinnedSurface)
        let title = TitleHost(title: "Completed", inset: 16)
        let header = TorrentStickyHeaders.Header(id: "finished", title: "Completed", index: 0, inset: 16)
        for offset: CGFloat in [0, 100, 60] {
            scroll.contentView.scroll(to: .init(x: 0, y: offset))
            let viewport = table.convert(scroll.contentView.bounds, from: scroll.contentView)
            let titleY: CGFloat = offset == 100 ? -12 : 20
            backdrop.present(layout: .init(titles: [.init(index: 0,
                frame: .init(x: 0, y: titleY, width: viewport.width, height: 47), pinned: true)], backdropHeight: 115),
                headers: [header], hosts: ["finished": title], viewport: viewport)
            let effect = try #require(backdrop.pinnedSurface.subviews.compactMap { $0 as? NSVisualEffectView }.first)
            let windowTop = root.convert(window.convertFromScreen(window.frame), from: nil).minY
            let viewportTop = root.convert(scroll.contentView.bounds, from: scroll.contentView).minY
            #expect(abs(root.convert(effect.bounds, from: effect).minY - windowTop) < 1)
            #expect(abs(root.convert(title.bounds, from: title).minY - viewportTop - titleY) < 1)
            #expect(effect.frame.height == 115 + viewportInset)
            #expect(effect.layer?.mask?.frame == effect.bounds)
        }
    }

}

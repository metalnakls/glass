import AppKit
import CoreImage.CIFilterBuiltins
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("Native header backdrop", .serialized)
struct TorrentHeaderBackdropTests {
    @Test("faint tint does not reveal sharp rows behind the header", arguments: [0.15, 0.62, 0.95])
    func faintTintKeepsSpatialBlur(strength: Double) async throws {
        _ = NSApplication.shared
        let backdrop = HeaderBackdrop(frame: .init(x: 0, y: 0, width: 500, height: 400))
        backdrop.externallyHosted = true
        var appearance = TorrentHeaderAppearance()
        appearance.strength = strength
        appearance.backgroundIn = 0
        backdrop.configure(appearance)
        let host = TitleHost(title: "Queue", inset: 16)
        backdrop.present(layout: .init(titles: [.init(index: 0,
            frame: .init(x: 0, y: 20, width: 500, height: 47), pinned: true)], backdropHeight: 115),
            headers: [.init(id: "queue", title: "Queue", index: 0, inset: 16)], hosts: ["queue": host])
        let effect = try #require(backdrop.pinnedSurface.subviews.compactMap { $0 as? TorrentHeaderMaterialView }.first)
        #expect(effect.alphaValue == 1)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            #expect(effect.backgroundFilters.isEmpty)
            return
        }
        #expect(try stripeContrast(effect, y: 36) < 0.12)
        #expect(try stripeContrast(effect, y: 130) > 0.9)
    }

    @Test("spatial blur and its feather follow the moving surface", arguments: [-40.0, 0, 28, 80])
    func spatialMaskMoves(y: Double) throws {
        _ = NSApplication.shared
        let effect = TorrentHeaderMaterialView(frame: .init(x: 0, y: 0, width: 500, height: 115))
        effect.configure(strength: 0.62, titleHeight: 47)
        effect.frame.origin.y = y
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            #expect(effect.backgroundFilters.isEmpty)
            return
        }
        #expect(try stripeContrast(effect, y: y + 36) < 0.12)
        #expect(try stripeContrast(effect, y: y + 130) > 0.9)
        #expect(try stripeContrast(effect, y: y + 105) > stripeContrast(effect, y: y + 80))
    }

    /// Render the filter installed on the native view, rather than a separate
    /// approximation of it. A dimming overlay alone retains the input contrast.
    private func stripeContrast(_ effect: TorrentHeaderMaterialView, y: CGFloat) throws -> CGFloat {
        let filter = try #require(effect.backgroundFilters.first?.copy() as? CIFilter)
        let stripes = CIFilter.checkerboardGenerator()
        stripes.width = 8
        stripes.sharpness = 1
        stripes.color0 = .black; stripes.color1 = .white
        let source = try #require(stripes.outputImage)
            .cropped(to: CGRect(x: -500, y: -500, width: 1500, height: 1500))
        filter.setValue(source, forKey: kCIInputImageKey)
        let output = try #require(filter.outputImage)
        let image = try #require(CIContext().createCGImage(output, from: CGRect(x: 100, y: y, width: 128, height: 1)))
        let bitmap = NSBitmapImageRep(cgImage: image)
        let values = (0..<128).compactMap { bitmap.colorAt(x: $0, y: 0)?.usingColorSpace(.deviceRGB)?.redComponent }
        return try #require(values.max()) - #require(values.min())
    }

    @Test("outgoing blur follows its header until the whole gradient leaves, then reverses without a cut")
    func outgoingSurfaceTravelsTogether() async throws {
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
        backdrop.configure(appearance)
        let host = TitleHost(title: "Queue", inset: 16)
        let headers = [TorrentStickyHeaders.Header(id: "queue", title: "Queue", index: 0, inset: 16)]
        let frames = [CGRect(x: 0, y: 0, width: 500, height: 47)]
        let offsets: [CGFloat] = [33, 34, 53, 73, 100, 120, 147, 120, 73, 33]
        for offset in offsets {
            let viewport = CGRect(x: 0, y: offset, width: 500, height: 400)
            let sticky = try #require(TorrentStickyHeaders.stickyLayout(frames: frames, viewport: viewport,
                appearance: appearance, releases: [100], stickyAllowed: [true]))
            let title = try #require(sticky.titles.first)
            let layout = TorrentStickyHeaderGeometry.displayLayout(frames: frames, viewport: viewport, sticky: sticky)
            backdrop.present(layout: layout, headers: headers, hosts: ["queue": host], viewport: viewport)
            try await Task.sleep(for: .milliseconds(20))
            let effect = try #require(backdrop.pinnedSurface.subviews.compactMap { $0 as? TorrentHeaderMaterialView }.first)
            #expect(effect.frame.minY == title.frame.minY - TorrentStickyHeaders.topInset)
            #expect(effect.frame.height == 115)
            #expect(effect.tint.frame == effect.bounds)
            #expect(backdrop.backdropIsActive == (effect.frame.maxY > 0))
            if effect.frame.maxY > 0 { #expect(abs(effect.alphaValue - 1) < 0.001) }
        }
    }

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
        let effect = try #require(backdrop.pinnedSurface.subviews.compactMap { $0 as? TorrentHeaderMaterialView }.first)
        #expect(effect.backgroundFilters.first?.name == "CIMaskedVariableBlur")
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
            #expect(fading > 0 && fading < 1)
        }
        #expect(effect.frame == extent)
        #expect(effect.tint.frame.size == extent.size)
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
        let effect = try #require(backdrop.pinnedSurface.subviews.compactMap { $0 as? TorrentHeaderMaterialView }.first)
        try await Task.sleep(for: .milliseconds(80))
        let entering = try #require(effect.layer?.presentation()?.opacity)
        if !ReduceMotion.enabled { #expect(entering > 0 && entering < 1) }
        try await Task.sleep(for: .milliseconds(450))
        present(false)
        try await Task.sleep(for: .milliseconds(180))
        let before = try #require(effect.layer?.presentation()?.opacity)
        present(true)
        try await Task.sleep(for: .milliseconds(30))
        let after = try #require(effect.layer?.presentation()?.opacity)
        if !ReduceMotion.enabled {
            #expect(before > 0 && before < 1)
            #expect(abs(after - before) < 0.1)
            #expect(after < 1)
        }
        try await Task.sleep(for: .milliseconds(450))
        #expect(abs((effect.layer?.presentation()?.opacity ?? 0) - 1) < 0.01)
        #expect(effect.frame.height == 115)
    }
    @Test("the blur and gradient move with the header independently of bar and viewport positions", arguments: [0.0, 28.0, 44.0])
    func attachedHeaderAlignment(barInset: CGFloat) throws {
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
        backdrop.attachViewport(to: scroll)
        // A safe-area bar can start below the clip viewport in a full-size-content
        // window. The title, native material and gradient must travel together.
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
            let effect = try #require(scroll.subviews.compactMap { $0 as? TorrentHeaderMaterialView }.first)
            let expectedBlurTop = root.convert(scroll.contentView.bounds, from: scroll.contentView).minY + titleY - TorrentStickyHeaders.topInset
            let viewportTop = root.convert(scroll.contentView.bounds, from: scroll.contentView).minY
            #expect(abs(root.convert(effect.bounds, from: effect).minY - expectedBlurTop) < 1)
            #expect(abs(root.convert(title.bounds, from: title).minY - viewportTop - titleY) < 1)
            #expect(effect.frame.height == 115)
            #expect(effect.tint.frame == effect.bounds)
        }
    }

}

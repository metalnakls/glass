import AppKit
import Foundation
import SwiftUI
import Testing
@testable import GlassRemoteUI

@Suite("Continuous sticky titles")
struct TorrentStickyHeaderTests {
    let frames = [CGRect(x: 8, y: 6, width: 480, height: 48), CGRect(x: 8, y: 186, width: 480, height: 48)]
    func viewport(_ y: CGFloat) -> CGRect { CGRect(x: 0, y: y, width: 500, height: 600) }

    @MainActor @Test("rows inserted after the header cannot paint over it")
    func lateRowStacking() throws {
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let table = NSTableView(frame: frame)
        table.wantsLayer = true
        window.contentView = table
        defer { window.close() }
        let backdrop = HeaderBackdrop(frame: frame)
        backdrop.isHidden = false
        table.addSubview(backdrop)
        // Native List realizes more cells after the header surface is attached.
        let row = NSTableRowView(frame: frame)
        row.wantsLayer = true
        table.addSubview(row, positioned: .above, relativeTo: nil)
        let overflow = TorrentArtworkOverflow.Anchor(frame: frame)
        overflow.enabled = true
        overflow.order = 10_000
        row.addSubview(overflow)
        overflow.configure()
        let headerLayer = try #require(backdrop.layer)
        let rowLayer = try #require(row.layer)
        #expect(headerLayer.zPosition > rowLayer.zPosition)
    }

    @MainActor @Test("inline titles scroll in the native document even before a header layout update")
    func inlineDocumentScrolling() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        let table = NSTableView(frame: CGRect(x: 0, y: 0, width: 500, height: 1000))
        table.headerView = nil
        scroll.documentView = table
        window.contentView?.addSubview(scroll)
        let controller = TorrentStickyHeaders()
        controller.attach(table)
        defer { controller.detach(); window.close() }
        let backdrop = try #require(table.subviews.compactMap { $0 as? HeaderBackdrop }.first)
        #expect(backdrop.superview === scroll.documentView)
        let host = TitleHost(title: "Completed", inset: 40)
        let header = TorrentStickyHeaders.Header(id: "finished", title: "Completed", index: 0, inset: 40)
        let frame = CGRect(x: 0, y: 180, width: 500, height: 48)
        let layout = TorrentStickyHeaderGeometry.displayLayout(frames: [frame], viewport: scroll.contentView.bounds, sticky: nil)
        backdrop.present(layout: layout, headers: [header], hosts: ["finished": host], backdropActive: false, viewport: scroll.contentView.bounds)
        let titleBefore = host.convert(CGPoint.zero, to: window.contentView)
        let rowBefore = table.convert(frame.origin, to: window.contentView)
        // No present() call between measurements: the document itself must move
        // both surfaces, rather than waiting for a separate overlay transaction.
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 24))
        let titleAfter = host.convert(CGPoint.zero, to: window.contentView)
        let rowAfter = table.convert(frame.origin, to: window.contentView)
        #expect(abs(titleAfter.y - titleBefore.y) == 24)
        #expect(titleAfter.y - titleBefore.y == rowAfter.y - rowBefore.y)
        #expect(host.frame == frame)
    }

    @MainActor @Test("a pinned title stays still when native scrolling advances before header callbacks")
    func pinnedViewportScrolling() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        let table = NSTableView(frame: CGRect(x: 0, y: 0, width: 500, height: 1000))
        table.headerView = nil
        scroll.documentView = table
        window.contentView?.addSubview(scroll)
        let controller = TorrentStickyHeaders()
        controller.attach(table)
        defer { controller.detach(); window.close() }
        // Reproduce an asynchronous scroll advancing while the main-thread
        // pinning callback has not run. Neither title presentation nor its
        // coordinates are updated again during these scroll steps.
        NotificationCenter.default.removeObserver(controller)
        let backdrop = try #require(table.subviews.compactMap { $0 as? HeaderBackdrop }.first)
        let host = TitleHost(title: "Completed", inset: 40)
        let header = TorrentStickyHeaders.Header(id: "finished", title: "Completed", index: 0, inset: 40)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 200))
        let viewport = scroll.contentView.bounds
        let layout = try #require(TorrentStickyHeaderGeometry.layout(
            frames: [CGRect(x: 0, y: 180, width: 500, height: 48)], viewport: viewport, topInset: 20))
        backdrop.present(layout: layout, headers: [header], hosts: ["finished": host], viewport: viewport)
        let position = host.convert(CGPoint.zero, to: window.contentView)
        for y: CGFloat in [224, 210, 240, 220] {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            #expect(host.convert(CGPoint.zero, to: window.contentView) == position)
            #expect(!host.isHidden)
        }
    }

    @MainActor @Test("pin and push move one title between document and viewport without changing its slots")
    func singleNativeOwner() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try #require(window.contentView)
        let scroll = NSScrollView(frame: root.bounds)
        let table = NSTableView(frame: CGRect(x: 0, y: 0, width: 500, height: 1000))
        table.headerView = nil
        scroll.documentView = table
        root.addSubview(scroll)
        let firstInline = NSView(frame: frames[0])
        let secondInline = NSView(frame: frames[1])
        let first = TitleHost(title: "Downloading", inset: 40)
        let second = TitleHost(title: "Finished", inset: 40)
        first.isHidden = true; second.isHidden = true
        table.addSubview(firstInline); table.addSubview(secondInline)
        let backdrop = HeaderBackdrop(frame: table.bounds)
        table.addSubview(backdrop)
        backdrop.attachViewport(to: scroll)
        let headers = [TorrentStickyHeaders.Header(id: "first", title: "Downloading", index: 0, inset: 40),
                       TorrentStickyHeaders.Header(id: "second", title: "Finished", index: 1, inset: 40)]
        let hosts = ["first": first, "second": second]
        for y: CGFloat in [20, 150, 170, 187] {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            let viewport = scroll.contentView.bounds
            let layout = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport))
            backdrop.present(layout: layout, headers: headers, hosts: hosts, viewport: viewport)
            #expect(backdrop.backdropIsActive)
            for placement in layout.titles {
                let host = placement.index == 0 ? first : second
                let parent: NSView = placement.pinned ? backdrop.pinnedSurface : backdrop
                #expect(host.superview === parent)
                #expect(!host.isHidden)
                let expectedFrame = placement.pinned ? placement.frame
                    : placement.frame.offsetBy(dx: viewport.minX, dy: viewport.minY)
                #expect(host.frame == expectedFrame)
                let label = try #require(host.subviews.first)
                #expect(label.frame.width > 0)
                #expect(label.frame.height > 0)
                #expect(label.safeAreaInsets.top == 0)
                #expect(label.safeAreaInsets.bottom == 0)
                #expect((backdrop.subviews + backdrop.pinnedSurface.subviews).filter { $0 === host }.count == 1)
            }
        }
        // Reversing back to the top returns the same cached objects inline.
        scroll.contentView.scroll(to: .zero)
        let inline = TorrentStickyHeaderGeometry.displayLayout(frames: frames, viewport: scroll.contentView.bounds, sticky: nil)
        backdrop.present(layout: inline, headers: headers, hosts: hosts, backdropActive: false, viewport: scroll.contentView.bounds)
        #expect(first.superview === backdrop && second.superview === backdrop)
        #expect(first.frame == frames[0] && second.frame == frames[1])
        backdrop.dismiss()
        #expect(!backdrop.backdropIsActive)
        #expect(first.superview === backdrop)
        #expect(second.superview === backdrop)
        #expect(first.isHidden && second.isHidden)
        #expect(firstInline.subviews.isEmpty && secondInline.subviews.isEmpty)
        #expect(firstInline.frame == frames[0] && secondInline.frame == frames[1])
    }

    @Test("visible inline titles share the overlay without duplicate pinned copies")
    func stableInlineSlots() throws {
        let inline = TorrentStickyHeaderGeometry.displayLayout(frames: frames, viewport: viewport(0), sticky: nil)
        #expect(inline.titles.map(\.index) == [0, 1])
        #expect(inline.titles[0].frame == frames[0])
        #expect(inline.backdropHeight == 0)
        let sticky = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(150)))
        let display = TorrentStickyHeaderGeometry.displayLayout(frames: frames, viewport: viewport(150), sticky: sticky)
        #expect(display.titles.map(\.index) == [0, 1])
        #expect(display.titles[0].frame == sticky.titles[0].frame)
        let short = TorrentStickyHeaderGeometry.displayLayout(frames: frames, viewport: viewport(60), sticky: nil)
        #expect(short.titles.map(\.index) == [1])
        #expect(short.titles[0].frame.minY == frames[1].minY - 60)
    }

    @MainActor @Test("title fade and blur do not change the reserved header height")
    func stableHeaderHeight() {
        let host = TitleHost(title: "Completed", inset: 40)
        let size = host.fittingSize(width: 500)
        host.setExitProgress(0.8, duration: 0)
        #expect(host.fittingSize(width: 500) == size)
        host.setExitProgress(0, duration: 0)
        #expect(host.fittingSize(width: 500) == size)
        #expect(host.fittingSize(width: 600).width == 600)
    }

    @Test("inline-to-pinned handoff preserves the actual frame and padding")
    func measuredHandoff() throws {
        #expect(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(6)) == nil)
        let pinned = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(7)))
        #expect(pinned.titles[0].frame == CGRect(x: 8, y: 0, width: 480, height: 48))
    }
    @Test("top breathing room changes the pin boundary without a positional jump")
    func paddedPinBoundary() throws {
        #expect(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(-14), topInset: 20) == nil)
        let pinned = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(-13), topInset: 20))
        #expect(pinned.titles[0].frame.minY == 20)
        let pushing = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(126), topInset: 20))
        #expect(pushing.titles[0].frame.maxY == pushing.titles[1].frame.minY)
        let handoff = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(167), topInset: 20))
        #expect(handoff.titles[0].index == 1)
        #expect(handoff.titles[0].frame.minY == 20)
    }
    @Test("incoming title pushes the old title without overlap")
    func continuousPush() throws {
        let before = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(137)))
        #expect(before.titles[0].frame.minY == 0)
        let pushing = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(150)))
        #expect(pushing.titles.map(\.index) == [0, 1])
        #expect(pushing.titles[0].frame.minY == -12)
        #expect(pushing.titles[0].frame.maxY == pushing.titles[1].frame.minY)
        let handoff = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(187)))
        #expect(handoff.titles[0].index == 1)
        #expect(handoff.titles[0].frame.minX == 8)
        #expect(handoff.titles[0].frame.minY == 0)
    }
    @Test("outgoing title begins its timed fade and blur when pushing upward")
    func earlyRelease() throws {
        let layout = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(130), topInset: 20, releasePoints: [162, 500]))
        let outgoing = try #require(layout.titles.first { $0.index == 0 })
        #expect(outgoing.retiring)
        #expect(outgoing.frame.minY == -16)
        #expect(outgoing.frame.maxY == 32)
        #expect(layout.titles.first { $0.index == 1 }?.frame.minY == 56)
    }
    @Test("two-item sections never float their title")
    func shortSectionStaysInline() {
        #expect(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(50), topInset: 20, stickyAllowed: [false, true]) == nil)
        #expect(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(190), topInset: 20, stickyAllowed: [false, true])?.titles.first?.index == 1)
    }
    @Test("handoff retains the outgoing title until it clears the viewport")
    func outgoingTravelCompletes() throws {
        let layout = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(170), topInset: 20))
        let outgoing = try #require(layout.titles.first { $0.index == 0 })
        #expect(outgoing.frame.maxY == 16)
        #expect(outgoing.exitProgress > 0 && outgoing.exitProgress < 1)
        let cleared = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(187), topInset: 20))
        #expect(!cleared.titles.contains { $0.index == 0 })
    }
    @Test("reversing scroll reproduces the same geometry and respects horizontal origin")
    func reverseAndHorizontalOrigin() throws {
        let down = TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(150))
        _ = TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(220))
        #expect(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport(150)) == down)
        let shifted = try #require(TorrentStickyHeaderGeometry.layout(frames: frames, viewport: CGRect(x: 3, y: 150, width: 500, height: 600)))
        #expect(shifted.titles.allSatisfy { $0.frame.minX == 5 })
    }
}

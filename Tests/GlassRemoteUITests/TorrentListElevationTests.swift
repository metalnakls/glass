import AppKit
import SwiftUI
import Testing
@testable import GlassRemoteUI

@Suite("Selection geometry")
struct TorrentListElevationTests {
    @MainActor private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 7 }
        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { "Row \(row)" }
    }

    @MainActor @Test("separator neighbors survive partial anchor registration and missing selection")
    func stableSeparators() async throws {
        _ = NSApplication.shared
        let rows = Rows()
        let table = NSTableView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let column = NSTableColumn(identifier: .init("name"))
        column.width = 400
        table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 48; table.dataSource = rows
        let scroll = NSScrollView(frame: table.frame)
        let window = NSWindow(contentRect: table.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scroll); scroll.documentView = table; table.reloadData()
        let controller = TorrentListElevationController()
        controller.setRows([nil, "a", "b", "c", nil, "d", "e"])
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        controller.attach(table)
        #expect(table.gridStyleMask.isEmpty)
        defer { controller.detach(); window.close() }
        func anchor(_ id: String, _ index: Int) -> TorrentListElevationAnchor.Anchor {
            let row = table.rect(ofRow: index)
            let view = TorrentListElevationAnchor.Anchor(frame: CGRect(x: 20, y: row.minY + 3, width: 360, height: row.height - 6))
            view.rowID = id; table.addSubview(view); controller.register(view)
            return view
        }
        let b = anchor("b", 2)
        #expect(b.hitTest(CGPoint(x: 10, y: 10)) == nil)
        for _ in 0..<4 { await Task.yield() }
        let canvas = try #require(table.subviews.first { String(describing: type(of: $0)).contains("SelectionSeparatorCanvas") })
        func visibleLines() -> Int { canvas.layer?.sublayers?.filter { $0.opacity == 1 }.count ?? 0 }
        // Only one anchor exists; all three boundaries must still be present.
        #expect(visibleLines() == 3)
        controller.setSelection("b")
        #expect(visibleLines() == 1)
        controller.setSelection(nil)
        #expect(visibleLines() == 3)
        controller.setSelection("not-mounted")
        #expect(visibleLines() == 3)
        let a = anchor("a", 1)
        controller.setSelection("a")
        try await Task.sleep(for: .milliseconds(100))
        controller.setSelection("b")
        let surface = try #require(table.subviews.first { String(describing: type(of: $0)).contains("SelectionSurfaceHost") })
        #expect(surface.layer?.animation(forKey: "glide") != nil)
        // A destination layout notification must not cancel either moving layer.
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: b)
        controller.register(a); controller.register(b)
        for _ in 0..<4 { await Task.yield() }
        #expect(surface.layer?.animation(forKey: "glide") != nil)
        let overlay = try #require(scroll.subviews.first { String(describing: type(of: $0)).contains("ElevationOverlay") })
        #expect(overlay.layer?.sublayers?.filter { $0.animation(forKey: "glide") != nil }.count == 2)
        #expect(overlay.layer?.mask?.animation(forKey: "glide") != nil)
        controller.configureGeometry(TorrentCardGeometry(leading: 20, trailing: 20, separatorInset: 62))
        table.setFrameSize(CGSize(width: 450, height: table.frame.height))
        // Simulate an intermediate hosting layout width during live resize.
        b.setFrameSize(CGSize(width: 90, height: b.frame.height))
        controller.register(b)
        for _ in 0..<4 { await Task.yield() }
        #expect(surface.frame.minX == 20)
        #expect(surface.frame.width == table.bounds.width - 40)
        // Transient SwiftUI expansion frames must never become selection geometry.
        b.frame = CGRect(x: 20, y: 230, width: 90, height: 100)
        controller.register(b)
        for _ in 0..<4 { await Task.yield() }
        #expect(surface.frame.minY == table.rect(ofRow: 2).minY + 3)
        #expect(surface.frame.height == table.rect(ofRow: 2).height - 6)
        // Even recycling the selected host cannot pin the card to the wrong row.
        b.rowID = "e"
        controller.register(b)
        controller.setRows([nil, "a", "c", "d", nil, "e", "b"])
        for _ in 0..<4 { await Task.yield() }
        #expect(surface.frame.minY == table.rect(ofRow: 6).minY + 3)
        // Scrolling changes viewport coordinates without changing the row frame.
        surface.layer?.removeAllAnimations()
        let shadow = try #require(overlay.layer?.sublayers?.first)
        let beforeScroll = shadow.frame.minY
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 24))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        #expect(shadow.frame.minY == beforeScroll - 24)
        table.rowHeight = 60
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<7))
        controller.configureGeometry(TorrentCardGeometry(leading: 20, trailing: 20, separatorInset: 62))
        #expect(surface.frame.minY == table.rect(ofRow: 6).minY + 3)
        #expect(surface.frame.height == table.rect(ofRow: 6).height - 6)
        #expect(shadow.frame == overlay.convert(surface.frame, from: table))
    }

    @MainActor @Test("separator rules stay pinned to their rows while the viewport scrolls")
    func separatorsTrackRows() async throws {
        _ = NSApplication.shared
        let rows = Rows()
        let table = NSTableView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let column = NSTableColumn(identifier: .init("name"))
        column.width = 400
        table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 48; table.dataSource = rows
        let scroll = NSScrollView(frame: table.frame)
        let window = NSWindow(contentRect: table.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scroll); scroll.documentView = table; table.reloadData()
        let controller = TorrentListElevationController()
        controller.setRows(["a", "b", "c", "d", "e", "f", "g"])
        controller.attach(table)
        controller.configureGeometry(TorrentCardGeometry(leading: 20, trailing: 20, separatorInset: 62))
        defer { controller.detach(); window.close() }
        for _ in 0..<4 { await Task.yield() }
        let canvas = try #require(table.subviews.first { String(describing: type(of: $0)).contains("SelectionSeparatorCanvas") })
        let window0 = table.rows(in: table.visibleRect)
        let first = try #require(canvas.layer?.sublayers?.first { $0.frame.height > 0 })
        let startY = first.frame.minY
        #expect(first.frame.minY > table.visibleRect.minY)

        // Scrolling must not rebuild rule geometry: the same sublayer keeps its
        // document-space position and simply leaves the viewport.
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 96))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        for _ in 0..<4 { await Task.yield() }
        #expect(canvas.layer?.sublayers?.contains(first) == true)
        #expect(first.frame.minY == startY)

        // Coming back restores the identical rule set at the identical positions.
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 0))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        for _ in 0..<4 { await Task.yield() }
        #expect(first.frame.minY == startY)
        #expect(table.rows(in: table.visibleRect) == window0)
    }

    @Test("swipe actions remain behind transparent artwork rather than a rectangular cutoff")
    func artworkSwipeBoundary() {
        let path = SwipeRevealMask(offset: 40, inset: 76, trailingInset: 24)
            .path(in: CGRect(x: 0, y: 0, width: 400, height: 48))
        #expect(path.contains(CGPoint(x: 70, y: 24), eoFill: true))
        #expect(!path.contains(CGPoint(x: 180, y: 24), eoFill: true))
    }

    @MainActor @Test("the shared card envelope contains every tuned icon pose")
    func artworkEnvelope() {
        for role in [TorrentIconRole.folder, .fan, .artwork, .document] {
            for position in 0..<5 {
                let pose = TorrentIconPose.forRole(role, position: position)
                let extent = pose.scale * (18 * abs(cos(pose.angle)) + 21 * abs(sin(pose.angle)))
                let left = 18 + pose.x - extent
                #expect(left >= -TorrentIconPose.leadingOverflow - 0.001)
            }
        }
    }
}

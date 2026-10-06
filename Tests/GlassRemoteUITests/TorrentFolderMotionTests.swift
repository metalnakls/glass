import AppKit
import SwiftUI
import Testing
@testable import GlassRemoteUI

@Suite("Independent folder flights")
struct TorrentFolderMotionTests {
    @MainActor private final class Rows: NSObject, NSTableViewDataSource {
        var count = 2
        func numberOfRows(in tableView: NSTableView) -> Int { count }
        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { "Row \(row)" }
    }

    @MainActor @Test("folder flight waits for the new row snapshot and uses final row positions")
    func independentFlight() async throws {
        _ = NSApplication.shared
        let rows = Rows()
        let table = NSTableView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let column = NSTableColumn(identifier: .init("name"))
        column.width = 400
        table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 48; table.dataSource = rows
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 300)
        let scroll = NSScrollView(frame: viewport)
        let window = NSWindow(contentRect: viewport, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scroll)
        scroll.documentView = table
        table.reloadData()
        let header = HeaderBackdrop(frame: table.bounds)
        table.addSubview(header)
        let motion = TorrentFolderMotion()
        motion.attach(table)
        let source = TorrentFolderIconContainer(frame: CGRect(x: 20, y: 50, width: 27, height: 27))
        source.controller = motion; source.id = "first"; source.size = 27
        table.addSubview(source); motion.register(source)
        let originalIcon = try #require(source.subviews.first)
        motion.prepare(groupID: "group", members: ["first", "second"], expanding: true,
            inset: 20, indices: ["group": 1], reduceMotion: false)
        #expect(motion.flyingIDs == ["first", "second"])
        // Every flying icon is a live view in the same window, never a grey
        // image. There is exactly one host per visible member.
        let liveViews = table.subviews.flatMap(\.subviews)
            .filter { $0.subviews.contains { $0 is NSHostingView<FolderFlightArtwork> } }
        #expect(liveViews.count == 2)
        #expect(liveViews.contains { $0 === originalIcon })
        #expect(source.subviews.isEmpty)
        let flightSurface = try #require(originalIcon.superview)
        #expect(flightSurface.superview === table)
        #expect(try #require(flightSurface.layer).zPosition < #require(header.layer).zPosition)
        #expect(liveViews.allSatisfy { !$0.clipsToBounds && $0.layer?.masksToBounds != true })
        #expect(liveViews.flatMap(\.subviews).allSatisfy { !$0.clipsToBounds })
        #expect(liveViews.allSatisfy { $0.window === window && $0.layer?.contents == nil })
        motion.animateAfterLayout(indices: ["group": 1, "first": 2, "second": 3], expectedRows: 4)
        rows.count = 4; table.reloadData()
        // A real icon can sit away from the estimated row centre (native insets).
        let landing = TorrentFolderLandingAnchor.Anchor(frame: CGRect(x: 70, y: 178, width: 36, height: 42))
        landing.id = "first"
        landing.pose = TorrentIconPose(scale: 1.4, angle: 0.12, x: -11)
        table.addSubview(landing)
        motion.register(landing)
        let destination = TorrentFolderIconContainer(frame: landing.frame)
        destination.controller = motion; destination.id = "first"
        destination.rotation = landing.pose.angle
        table.addSubview(destination); motion.register(destination)
        #expect(destination.subviews.isEmpty)
        var flights: [CALayer] = []
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(10))
            flights = table.subviews.flatMap { $0.layer?.sublayers ?? [] }
                .filter { $0.animation(forKey: "folderFlight") != nil }
            if flights.count == 2 { break }
        }
        #expect(flights.count == 2)
        let animation = try #require(flights.first?.animation(forKey: "folderFlight"))
        #expect(animation.duration == 0.26)
        #expect(abs(flights[0].position.x + 18 - destination.frame.midX) < 0.1)
        #expect(abs(flights[0].position.y + 18 - landing.frame.midY) < 0.1)
        #expect(abs(hypot(flights[0].sublayerTransform.m11, flights[0].sublayerTransform.m12) - 1) < 0.001)
        #expect(motion.flyingIDs.count == 2)
        // Row geometry can finish changing after the initial flight starts.
        // Keep the overlay alive for a separate, remeasured settle tail.
        destination.setFrameOrigin(CGPoint(x: destination.frame.minX, y: destination.frame.minY + 20))
        table.rowHeight = 60
        table.reloadData()
        var tail: CAAnimation?
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(10))
            if let candidate = flights.first?.animation(forKey: "folderFlight"), candidate.duration == 0.12 {
                tail = candidate; break
            }
        }
        #expect(tail != nil)
        #expect(motion.flyingIDs.count == 2)
        // A late host movement must get a final landing, not a snap on reveal.
        destination.setFrameOrigin(CGPoint(x: destination.frame.minX + 26, y: destination.frame.minY))
        var finalLanding: CAAnimation?
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(10))
            if let candidate = flights.first?.animation(forKey: "folderFlight"), candidate.duration == 0.08 {
                finalLanding = candidate; break
            }
        }
        #expect(finalLanding != nil)
        #expect(motion.flyingIDs.count == 2)
        #expect(abs(flights[0].position.x + 18 - destination.frame.midX) < 0.1)
        // The exact original material returns to the landing container. No
        // duplicate static icon exists and no render-ack fade is needed.
        for _ in 0..<100 {
            if motion.flyingIDs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(motion.flyingIDs.isEmpty)
        #expect(destination.subviews.first === originalIcon)
        #expect(source.subviews.isEmpty)
        #expect(originalIcon.window === window)
        #expect(liveViews.filter { $0.superview === destination }.count == 1)
        motion.cancel()
        motion.detach()
        window.close()
    }

    @MainActor @Test("Reduce Motion leaves real row icons visible")
    func reducedMotion() {
        let motion = TorrentFolderMotion()
        motion.prepare(groupID: "group", members: ["first"], expanding: true,
            inset: 20, indices: ["group": 1], reduceMotion: true)
        #expect(motion.flyingIDs.isEmpty)
    }

    @MainActor @Test("recycling a native row cannot retain the previous glass icon")
    func recycledContainerHasOneIcon() throws {
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 36, height: 36)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = TorrentFolderIconContainer(frame: frame)
        window.contentView = NSView(frame: frame)
        window.contentView?.addSubview(container)
        let motion = TorrentFolderMotion()
        defer { motion.detach(); window.close() }
        container.configure(controller: motion, id: "season-2", size: 36, rotation: -0.1)
        let previous = try #require(container.subviews.first)
        container.configure(controller: motion, id: "season-3", size: 36, rotation: 0)
        #expect(container.subviews.count == 1)
        #expect(container.subviews.first !== previous)
        #expect(previous.superview == nil)
        container.configure(controller: motion, id: "season-3", size: 36, rotation: 0.1)
        #expect(container.subviews.count == 1)
        let current = try #require(container.subviews.first)
        let replacement = TorrentFolderIconContainer(frame: frame)
        window.contentView?.addSubview(replacement)
        replacement.configure(controller: motion, id: "season-3", size: 36, rotation: 0.1)
        motion.place(container)
        #expect(container.subviews.isEmpty)
        #expect(replacement.subviews.first === current)
        motion.unregister(replacement)
        #expect(container.subviews.first === current)
        replacement.isActive = false
        replacement.removeFromSuperview()
        motion.place(container)
        #expect(container.subviews.count == 1)
        #expect(container.subviews.first?.isHidden == false)
        #expect(container.subviews.first?.layer?.zPosition == 0)
    }

    @MainActor @Test("all visible members fly, extra leaves emerge behind the fan, and unacknowledged overlays retire")
    func visibleMembersAndHandoff() async throws {
        _ = NSApplication.shared
        let rows = Rows()
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 360)
        let table = NSTableView(frame: viewport)
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.headerView = nil; table.rowHeight = 48; table.dataSource = rows
        let scroll = NSScrollView(frame: viewport)
        let window = NSWindow(contentRect: viewport, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scroll); scroll.documentView = table
        table.reloadData()
        let motion = TorrentFolderMotion()
        motion.attach(table)
        defer { motion.detach(); window.close() }
        let members = (0..<20).map { "member-\($0)" }
        motion.prepare(groupID: "group", members: members, expanding: true,
            inset: 20, indices: ["group": 1], reduceMotion: false)
        let visibleIDs = motion.flyingIDs
        #expect(visibleIDs.count > 3)
        #expect(visibleIDs.count < members.count)
        #expect(visibleIDs.contains("member-3"))
        #expect(!visibleIDs.contains("member-19"))
        let flightViews = table.subviews.flatMap(\.subviews)
            .filter { $0.identifier?.rawValue.hasPrefix("member-") == true }
        let flights = flightViews.compactMap(\.layer)
        #expect(flightViews.count == visibleIDs.count)
        #expect(flightViews.allSatisfy { $0.subviews.filter { $0 is NSHostingView<FolderFlightArtwork> }.count == 1 })
        let extra = try #require(flightViews.first { $0.identifier?.rawValue == "member-3" }?.layer)
        let first = try #require(flightViews.first { $0.identifier?.rawValue == "member-0" }?.layer)
        #expect(extra.opacity == 0)
        #expect(extra.zPosition < first.zPosition)
        var indices = ["group": 1]
        for (slot, id) in members.enumerated() { indices[id] = slot + 2 }
        rows.count = 22; table.reloadData()
        motion.animateAfterLayout(indices: indices, expectedRows: 22)
        for _ in 0..<25 {
            if extra.animation(forKey: "folderEmergence") != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let emergence = try #require(extra.animation(forKey: "folderEmergence") as? CABasicAnimation)
        #expect(emergence.fromValue as? Float == 0)
        #expect(emergence.toValue as? Int == 1)
        // No reveal anchors are installed: virtualized/recycled rows must not
        // leave permanent copies of the flight images above the real icons.
        for _ in 0..<180 {
            if motion.flyingIDs.isEmpty && flightViews.allSatisfy({ $0.superview == nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(motion.flyingIDs.isEmpty)
        #expect(flights.allSatisfy { $0.superlayer == nil })

        motion.prepare(groupID: "group", members: members, expanding: false,
            inset: 20, indices: indices, reduceMotion: false)
        #expect(motion.flyingIDs.count > 3)
        #expect(!motion.flyingIDs.contains("member-19"))
        let returning = table.subviews.flatMap(\.subviews)
            .filter { $0.identifier?.rawValue.hasPrefix("member-") == true }.compactMap(\.layer)
        rows.count = 2; table.reloadData()
        motion.animateAfterLayout(indices: ["group": 1], expectedRows: 2)
        for _ in 0..<180 {
            if motion.flyingIDs.isEmpty && returning.allSatisfy({ $0.superlayer == nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(motion.flyingIDs.isEmpty)
        #expect(returning.allSatisfy { $0.superlayer == nil })
    }
}

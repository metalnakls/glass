import AppKit
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
        let motion = TorrentFolderMotion()
        motion.attach(table)
        motion.prepare(groupID: "group", members: ["first", "second"], expanding: true,
            inset: 20, indices: ["group": 1], reduceMotion: false)
        #expect(motion.flyingIDs == ["first", "second"])
        motion.animateAfterLayout(indices: ["group": 1, "first": 2, "second": 3], expectedRows: 4)
        rows.count = 4; table.reloadData()
        // A real icon can sit away from the estimated row centre (native insets).
        let landing = TorrentFolderLandingAnchor.Anchor(frame: CGRect(x: 70, y: 178, width: 36, height: 42))
        landing.id = "first"
        landing.pose = TorrentIconPose(scale: 1.4, angle: 0.12, x: -11)
        table.addSubview(landing)
        motion.register(landing)
        var flights: [CALayer] = []
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(10))
            flights = scroll.subviews.flatMap { $0.layer?.sublayers ?? [] }
                .filter { $0.animation(forKey: "folderFlight") != nil }
            if flights.count == 2 { break }
        }
        #expect(flights.count == 2)
        let animation = try #require(flights.first?.animation(forKey: "folderFlight"))
        #expect(animation.duration == 0.30)
        let pose = landing.pose
        #expect(abs(flights[0].position.x - (landing.frame.midX + pose.x)) < 0.1)
        #expect(abs(flights[0].position.y - landing.frame.midY) < 0.1)
        #expect(motion.flyingIDs.count == 2)
        // Row geometry can finish changing after the initial flight starts.
        // Keep the overlay alive for a separate, remeasured settle tail.
        table.rowHeight = 60
        table.reloadData()
        var tail: CAAnimation?
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(10))
            if let candidate = flights.first?.animation(forKey: "folderFlight"), candidate.duration == 0.32 {
                tail = candidate; break
            }
        }
        #expect(tail != nil)
        #expect(motion.flyingIDs.count == 2)
        // A late host movement must get a final landing, not a snap on reveal.
        landing.setFrameOrigin(CGPoint(x: landing.frame.minX + 26, y: landing.frame.minY))
        var finalLanding: CAAnimation?
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(10))
            if let candidate = flights.first?.animation(forKey: "folderFlight"), candidate.duration == 0.16 {
                finalLanding = candidate; break
            }
        }
        #expect(finalLanding != nil)
        #expect(motion.flyingIDs.count == 2)
        #expect(abs(flights[0].position.x - (landing.frame.midX + pose.x)) < 0.1)
        // Rendering, not a timer, controls the final dissolve. Both flight
        // images remain opaque while either visible static icon is uncommitted.
        for _ in 0..<60 {
            if motion.revealToken(for: "first") != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let token = try #require(motion.revealToken(for: "first"))
        #expect(motion.flyingIDs.isEmpty)
        #expect(flights.allSatisfy { $0.opacity == 1 })
        motion.acknowledgeReveal("first", token: token)
        await Task.yield()
        #expect(flights.allSatisfy { $0.opacity == 1 })
        let rendered = TorrentFolderRevealAnchor.Anchor(frame: CGRect(x: 20, y: 202, width: 36, height: 36))
        rendered.controller = motion; rendered.id = "second"; rendered.visible = true
        table.addSubview(rendered)
        rendered.commitReveal()
        for _ in 0..<30 {
            if flights.allSatisfy({ $0.opacity == 0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(flights.allSatisfy { $0.opacity == 0 })
        motion.cancel()
        #expect(motion.flyingIDs.isEmpty)
        #expect(flights.allSatisfy { $0.superlayer == nil })
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
}

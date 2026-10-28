import AppKit
import SwiftUI
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("Native list laziness", .serialized)
struct TorrentListLazinessTests {
    private struct Entry: Identifiable { let id: Int }
    private final class Builds {
        var rows = Set<Int>()
        func row(_ id: Int) -> some View {
            rows.insert(id)
            return Text("Torrent \(id)").frame(height: 60)
        }
    }
    private struct Fixture: View {
        let builds: Builds
        let reordered: Bool
        let entries = (0..<500).map { Entry(id: $0) }
        var body: some View {
            if reordered {
                List {
                    GlassNativeReorderableRows(items: entries) { entry in builds.row(entry.id) }
                }.listStyle(.plain)
            } else {
                List { ForEach(entries) { entry in builds.row(entry.id) } }.listStyle(.plain)
            }
        }
    }
    @Test("reordering preserves native List's lazy row creation")
    func viewportOnly() async throws {
        _ = NSApplication.shared
        func rowBuilds(reordered: Bool) async throws -> (builders: Int, available: Int, visible: Int) {
            let window = NSWindow(contentRect: CGRect(x: -2000, y: -2000, width: 500, height: 500),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let builds = Builds()
            let host = NSHostingView(rootView: Fixture(builds: builds, reordered: reordered))
            window.contentView = host
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(10))
                host.layoutSubtreeIfNeeded()
            }
            func table(in view: NSView) -> NSTableView? {
                if let table = view as? NSTableView { return table }
                return view.subviews.lazy.compactMap { table(in: $0) }.first
            }
            let native = try #require(table(in: host))
            var available = 0
            native.enumerateAvailableRowViews { _, _ in available += 1 }
            let visible = native.rows(in: native.visibleRect).length
            return (builds.rows.count, available, visible)
        }
        let native = try await rowBuilds(reordered: false)
        let reordered = try await rowBuilds(reordered: true)
        print("Plain List: \(native); reordered List: \(reordered); library: 500")
        #expect(native.builders > 0 && native.builders < 500)
        #expect(reordered.builders <= native.builders)
        #expect(reordered.available <= native.available)
        #expect(reordered.visible == native.visible)
        #expect(reordered.visible > 0)
    }
}

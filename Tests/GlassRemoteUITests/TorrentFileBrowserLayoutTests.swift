import AppKit
import GlassRemoteCore
import SwiftUI
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("File browser native layout", .serialized)
struct TorrentFileBrowserLayoutTests {
    private struct MarginProbe: NSViewRepresentable {
        final class Anchor: NSView {}
        func makeNSView(context: Context) -> Anchor { Anchor() }
        func updateNSView(_ view: Anchor, context: Context) {}
    }
    private static let entries = [
        "Series/Season 1/01. A Very Long Episode Title That Needs Room.mkv",
        "Series/Season 1/02. The Arrival.mkv",
        "Series/Season 1/Subtitles/English.srt",
        "Series/Season 2/01. Home.mkv",
        "Series/Read Me.txt"
    ].enumerated().map { index, path in
        TorrentFileBrowserEntry(index: index,
            file: TorrentFile(name: path, length: index == 2 ? 48_000 : 1_500_000_000,
                bytesCompleted: index == 1 ? 1_500_000_000 : 300_000_000),
            rootName: "Series", isWanted: index != 3)
    }

    private struct Fixture: View {
        let scrolls: Bool
        @State private var search = ""
        var body: some View {
            Group {
                if scrolls { browser }
                else { GlassChromeScrollView { browser } }
            }
            .glassFloatingChrome(top: {
                HStack {
                    GlassPillButton {} label: { Label("Downloads", systemImage: "folder") }
                    Spacer()
                }.background(MarginProbe())
            }, bottom: {
                GlassPillButton {} label: { Text("Search files").frame(maxWidth: .infinity) }
            })
        }
        private var browser: some View {
            TorrentFilesBrowser(entries: TorrentFileBrowserLayoutTests.entries,
                searchText: $search, onSetWanted: { _, _ in }, onSetPriority: { _, _ in },
                onSetAllWanted: { _ in }, showsControls: false, isCompact: true,
                showsCompletion: !scrolls, scrolls: scrolls, showsActionBar: false)
        }
    }

    @Test("embedded and scrolling browsers retain native rows", arguments: [300.0, 480.0], [false, true])
    func render(width: Double, scrolls: Bool) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: width, height: 560),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: Fixture(scrolls: scrolls))
        window.contentView = host
        // Opt in only for a deliberate rendered-animation audit. Ordinary test
        // runs must not present windows on the user's desktop.
        let measuresPresentation = ProcessInfo.processInfo.environment["GLASS_TEST_PRESENTATION_ANIMATIONS"] == "1"
        if measuresPresentation { window.orderFront(nil) }
        func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
        }
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for _ in 0..<15 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
            let table = try #require(descendants(host, NSTableView.self).first)
            #expect(!table.enclosingScrollView!.hasVerticalScroller,
                "Hide scrollbars defaults on without disabling native scrolling")
            let rows = TorrentFileTreeRow.rows(entries: Self.entries, collapsed: [], query: "")
            #expect(table.numberOfRows == rows.count)
            #expect(table.bounds.width <= host.bounds.width)
            let row = try #require(descendants(host, TorrentFileListStyling.Anchor.self).first)
            let dock = try #require(descendants(host, MarginProbe.Anchor.self).first)
            let rowFrame = host.convert(row.bounds, from: row)
            let dockFrame = host.convert(dock.bounds, from: dock)
            #expect(abs(rowFrame.minX - dockFrame.minX) < 1, "file and glass leading margins must match")
            #expect(abs(rowFrame.maxX - dockFrame.maxX) < 1, "file and glass trailing margins must match")
            if !scrolls {
                #expect(table.rect(ofRow: rows.count - 1).maxY <= table.enclosingScrollView!.contentView.bounds.height + 1,
                    "the last embedded row must remain fully visible")
            }
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            #expect(table.selectedRowIndexes == IndexSet(integer: 0))
            if let directory = ProcessInfo.processInfo.environment["GLASS_FILE_TREE_SNAPSHOTS"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent("\(Int(width))-\(scrolls ? "add" : "inspector")-\(dark ? "dark" : "light").png"))
            }
            let disclosure = try #require(descendants(host, NSButton.self).first { $0.bezelStyle == .disclosure && $0.toolTip == "Season 1" })
            let heightBefore = table.enclosingScrollView!.frame.height
            let followingRow = try #require(table.rowView(atRow: 6, makeIfNecessary: false))
            let positionBefore = followingRow.frame.minY
            disclosure.performClick(nil)
            try await Task.sleep(for: .milliseconds(70))
            host.layoutSubtreeIfNeeded()
            let heightDuring = table.enclosingScrollView!.frame.height
            let positionDuring = followingRow.layer?.presentation()?.frame.minY ?? followingRow.frame.minY
            for _ in 0..<35 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
            if !scrolls {
                let heightAfter = table.enclosingScrollView!.frame.height
                #expect(heightDuring < heightBefore && heightDuring > heightAfter,
                    "folder collapse must pass through an intermediate height")
            }
            #expect(table.numberOfRows == rows.count - 4)
            #expect(table.selectedRowIndexes == IndexSet(integer: 0))
            if scrolls && measuresPresentation {
                let positionAfter = followingRow.frame.minY
                #expect(positionDuring < positionBefore && positionDuring > positionAfter,
                    "scrolling file rows must move through intermediate positions")
            }
            window.setContentSize(.init(width: width == 300 ? 480 : 300, height: 560))
            for _ in 0..<15 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
            #expect(descendants(host, NSTableView.self).first === table, "resize must keep the same native List")
            #expect(table.numberOfRows == rows.count - 4, "resize must retain collapsed folders")
            #expect(table.selectedRowIndexes == IndexSet(integer: 0))
            window.setContentSize(.init(width: width, height: 560))
            for _ in 0..<15 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
            disclosure.performClick(nil)
            for _ in 0..<35 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
            #expect(table.numberOfRows == rows.count)
        }
    }

    @Test("flat file lists have no empty disclosure column")
    func flatFileNames() async throws {
        _ = NSApplication.shared
        let entries = ["S01E01.mkv", "S01E02.mkv"].enumerated().map {
            TorrentFileBrowserEntry(index: $0.offset,
                file: TorrentFile(name: $0.element, length: 10_000, bytesCompleted: 0), rootName: "")
        }
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 300, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: TorrentFilesBrowser(entries: entries, searchText: .constant(""),
            onSetWanted: { _, _ in }, onSetPriority: { _, _ in }, onSetAllWanted: { _ in },
            showsControls: false, isCompact: true, showsActionBar: false))
        window.contentView = host
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        #expect(!buttons(host).contains { $0.bezelStyle == .disclosure })
    }
}

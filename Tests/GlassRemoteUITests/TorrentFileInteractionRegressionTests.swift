import AppKit
import GlassRemoteCore
import SwiftUI
import Testing
@testable import GlassRemoteUI

@MainActor @Suite("File inspector regressions")
struct TorrentFileInteractionRegressionTests {
    @Test func checkboxNameGapMatchesDocumentMargin() {
        _ = NSApplication.shared
        let layout = TorrentFileListLayout.shared
        let gap = layout.iconLeadingInset(hierarchical: false) - layout.leadingIconWidth
        #expect(gap >= GlassContentMargins.value)
    }
    @Test func sweepIncludesSkippedRowsButNotNameColumn() {
        let middle = CGRect(x: 10, y: 40, width: 16, height: 16)
        #expect(TorrentCheckboxSweep.intersects(from: .init(x: 18,y: 0), to: .init(x: 18,y: 100), rect: middle))
        #expect(!TorrentCheckboxSweep.intersects(from: .init(x: 60,y: 0), to: .init(x: 60,y: 100), rect: middle))
    }
    @Test func episodeCodeStaysVisible() {
        let view = TorrentFilesBrowser(entries: [], searchText: .constant(""), onSetWanted: { _, _ in },
            onSetPriority: { _, _ in }, onSetAllWanted: { _ in })
        let row = TorrentFileTreeRow(id: "episode", name: "S08E01 — Mercy.mkv", depth: 0,
            indices: [0], size: 1, entry: .init(index: 0, file: .init(name: "S08E01 — Mercy.mkv", length: 1, bytesCompleted: 0), rootName: "Show"))
        #expect(view.displayName(row, hiding: "mkv") == "S08E01 — Mercy")
    }
    @Test func nativeCheckboxDragPaintsEveryCrossedRow() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 100, height: 150),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scope = UUID()
        var changes: [String: [Bool]] = [:]
        let buttons = (0..<3).map { index in
            let button = TorrentWantedCheckbox.Button(checkboxWithTitle: "", target: nil, action: nil)
            button.frame = .init(x: 10, y: 100-index*30, width: 20, height: 20)
            button.scope = scope; button.rowID = String(index)
            button.changed = { changes[String(index), default: []].append($0) }
            window.contentView?.addSubview(button)
            return button
        }
        window.orderFront(nil)
        for _ in 0..<2 {
            let value = buttons[0].beginPaint()
            var visited: Set<String> = [buttons[0].rowID]
            buttons[0].paint(from: .init(x:18,y:108), to: .init(x:18,y:48), value: value,
                visited: &visited, in: try #require(window.contentView))
            // Crossing the same rows again during a drag must not toggle twice.
            buttons[0].paint(from: .init(x:18,y:48), to: .init(x:18,y:108), value: value,
                visited: &visited, in: try #require(window.contentView))
        }
        for index in 0..<3 { #expect(changes[String(index)] == [true, false]) }
    }

    @Test func cachedGroupDropsRemovedSeasons() throws {
        func torrent(_ hash: String) -> TorrentSummary {
            .init(id: 1, hashString: hash, name: "The Walking Dead", status: 0, percentDone: 0,
                rateDownload: 0, rateUpload: 0, sizeWhenDone: 1, leftUntilDone: 1,
                eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: nil)
        }
        let oldGroup = TorrentNameSequenceGroup(id: "show", displayName: "The Walking Dead", torrents: [torrent("season3"),torrent("season8")])
        let cached = TorrentInspectorSnapshot(sourceID: UUID(), group: oldGroup,
            groupDetails: ["season3": .init(id: 1,hashString: "season3",name: "Season 3"),
                           "season8": .init(id: 2,hashString: "season8",name: "Season 8")])
        let current = TorrentNameSequenceGroup(id: "show", displayName: "The Walking Dead", torrents: [torrent("season8")])
        #expect(cached.projected(onto: current)?.groupDetails.keys.sorted() == ["season8"])
        let added = TorrentNameSequenceGroup(id: "show", displayName: "The Walking Dead", torrents: [torrent("season9")])
        #expect(cached.projected(onto: added) == nil)
    }

    @Test func spinnerWaitsSixSeconds() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 80, height: 80),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: GlassActivityIndicator(label: "Renaming"))
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func indicators(_ view: NSView) -> Int {
            (view is NSProgressIndicator ? 1 : 0) + view.subviews.reduce(0) { $0 + indicators($1) }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(indicators(host) == 0)
        try await Task.sleep(for: .milliseconds(5300))
        #expect(indicators(host) == 0)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(indicators(host) > 0)
    }

}

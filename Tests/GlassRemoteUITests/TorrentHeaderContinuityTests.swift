import AppKit
import SwiftUI
import Testing
import GlassRemoteCore
@testable import GlassRemoteServices
@testable import GlassRemoteUI

@MainActor private func makeHeaderLayout(_ count: Int) -> TorrentListLayout {
    let source = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let records = (0..<(count + 12)).map { id in
        TorrentRecord(TorrentSummary(id: id, hashString: "fixture-\(id)", name: "Movie \(id).mkv", status: 0,
            percentDone: id < count ? 0.5 : 1, rateDownload: 0, rateUpload: 0, sizeWhenDone: 100,
            leftUntilDone: id < count ? 50 : 0, eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: nil), sourceID: source)
    }
    return TorrentListLayout(rows: TorrentListRowPresentation.rows(records: records, pendingRenameNames: [:], expandedGroupIDs: []))
}

/// Native rows keep this fixture independent of the changing reorder-wrapper API.
private struct HeaderContinuityFixture: View {
    let controller: TorrentStickyHeaders
    let layout: TorrentListLayout
    var body: some View {
        List {
            ForEach(layout.entries(lowercase: false)) { entry in
                ForEach([entry]) { _ in
                    switch entry {
                    case let .header(section):
                        TorrentStickyTitle(title: section.title, id: section.id, rowIndex: layout.headerIndices[section.id]!, inset: 16, controller: controller)
                            .modifier(TorrentInlineHeaderSpacing(isFirst: layout.headerIndices[section.id] == 0, beforeFirst: 16, betweenSections: 16, belowHeader: 0))
                    default: Text(entry.id).frame(height: 64)
                    }
                }.reorderable().listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
        }.reorderContainer(for: TorrentListEntry.self) { _ in }.listStyle(.plain)
            .contentMargins(.top, 0, for: .scrollContent)
            .safeAreaBar(edge: .top, spacing: 0) {
                TorrentHeaderSurface(controller: controller).frame(height: controller.titleHeight).allowsHitTesting(false)
            }.glassScrollEdges(.sectionTitles)
    }
}
@MainActor private func headerDescendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { headerDescendants($0, T.self) }
}
@MainActor @Suite("Native header continuity", .serialized)
struct TorrentHeaderContinuityTests {
    @Test("starting a scroll after section growth or shrinkage cannot move a title without moving the document", arguments: [3, 8])
    func scrollAfterSectionChange(initialCount: Int) async throws {
        _ = NSApplication.shared
        let controller = TorrentStickyHeaders()
        let initial = makeHeaderLayout(initialCount)
        controller.configure(initial, lowercase: false, inset: 16)
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { controller.detach(); window.close() }
        let host = NSHostingView(rootView: HeaderContinuityFixture(controller: controller, layout: initial))
        window.contentView = host
        func settle() async throws {
            for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
        }
        try await settle()
        let table = try #require(headerDescendants(host, NSTableView.self).first)
        let scroll = try #require(table.enclosingScrollView)
        scroll.contentView.scroll(to: .init(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        let title = try #require(headerDescendants(host, TitleHost.self).first { $0.isPinned && !$0.isHidden })
        func position() -> CGFloat {
            host.convert(title.bounds, from: title).minY - host.convert(scroll.contentView.bounds, from: scroll.contentView).minY
        }
        let height = title.frame.height
        let changedCount = initialCount == 3 ? 8 : 3
        let changed = makeHeaderLayout(changedCount)
        controller.configure(changed, lowercase: false, inset: 16)
        host.rootView = HeaderContinuityFixture(controller: controller, layout: changed)
        try await settle()
        try await Task.sleep(for: .milliseconds(400))
        let settled = position()
        let nextHeader = try #require(changed.headerIndices["finished"])
        let release = table.rect(ofRow: max(1, nextHeader - 2)).minY
        let viewport = table.convert(scroll.contentView.bounds, from: scroll.contentView)
        let expected = min(TorrentStickyHeaders.topInset, release - viewport.minY - height)
        #expect(abs(settled - expected) < 1)
        let offset = scroll.contentView.bounds.origin
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        #expect(scroll.contentView.bounds.origin == offset)
        #expect(abs(position() - settled) < 1)
        scroll.contentView.scroll(to: .init(x: 0, y: 101))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        #expect(abs(position() - settled) <= 1)
        #expect(title.alphaValue == 1)
        #expect(title.layer?.filters == nil)
    }
    @Test("native header positions stay continuous forwards and backwards for short and long sections",
          arguments: [1, 2, 3, 12])
    func nativeScrollContinuity(count: Int) async throws {
        _ = NSApplication.shared
        let controller = TorrentStickyHeaders()
        let layout = makeHeaderLayout(count)
        controller.configure(layout, lowercase: false, inset: 16)
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { controller.detach(); window.close() }
        let host = NSHostingView(rootView: HeaderContinuityFixture(controller: controller, layout: layout))
        window.contentView = host
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
        let table = try #require(headerDescendants(host, NSTableView.self).first)
        let scroll = try #require(table.enclosingScrollView)
        let title = try #require(headerDescendants(host, TitleHost.self).filter { !$0.isHidden }.min {
            table.convert($0.bounds, from: $0).minY < table.convert($1.bounds, from: $1).minY
        })
        let inline = table.convert(title.bounds, from: title)
        let nextHeader = try #require(layout.headerIndices["finished"])
        let release = table.rect(ofRow: max(1, nextHeader - 2)).minY
        let start = scroll.contentView.bounds.minY
        var offsets = Array(stride(from: start, through: table.rect(ofRow: nextHeader).minY + 24, by: 16))
        // Sample both sides of pin, push and exit boundaries as well as the full sweep.
        for boundary in [inline.minY - TorrentStickyHeaders.topInset,
                         release - inline.height - TorrentStickyHeaders.topInset, release] {
            offsets += [boundary - 1, boundary, boundary + 1].filter { $0 >= start }
        }
        offsets.sort()
        for y in offsets + offsets.reversed() {
            scroll.contentView.scroll(to: .init(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(2))
            host.layoutSubtreeIfNeeded()
            let viewport = table.convert(scroll.contentView.bounds, from: scroll.contentView)
            let inlineY = inline.minY - viewport.minY
            let expected = count > 2
                ? max(inlineY, min(TorrentStickyHeaders.topInset, release - viewport.minY - inline.height))
                : inlineY
            if expected + inline.height > 0 && expected < viewport.height {
                #expect(!title.isHidden)
                let actual = host.convert(title.bounds, from: title).minY
                    - host.convert(scroll.contentView.bounds, from: scroll.contentView).minY
                #expect(abs(actual - expected) < 1, "count=\(count), offset=\(y), actual=\(actual), expected=\(expected)")
                #expect(title.alphaValue == 1)
                #expect(title.layer?.filters == nil)
            }
        }
    }
    @Test("native live-scroll notifications keep the current floating title visible")
    func liveScrollVisibility() async throws {
        _ = NSApplication.shared
        let controller = TorrentStickyHeaders()
        let layout = makeHeaderLayout(12)
        controller.configure(layout, lowercase: false, inset: 16)
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { controller.detach(); window.close() }
        let host = NSHostingView(rootView: HeaderContinuityFixture(controller: controller, layout: layout))
        window.contentView = host
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
        let table = try #require(headerDescendants(host, NSTableView.self).first)
        let scroll = try #require(table.enclosingScrollView)
        scroll.contentView.scroll(to: .init(x: 0, y: 40))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(20))
        let title = try #require(headerDescendants(host, TitleHost.self).first { $0.isPinned && !$0.isHidden })
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        try await Task.sleep(for: .milliseconds(16))
        scroll.contentView.scroll(to: .init(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        #expect(title.alphaValue == 1)
        let pinnedFrame = title.frame
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        try await Task.sleep(for: .milliseconds(400))
        #expect(title.alphaValue == 1)
        #expect(title.frame == pinnedFrame)
        #expect(scroll.contentView.bounds.minY == 100)
    }

    @Test("headers remain visible through fast and slow scrolling", arguments: [true, false])
    func slowScrollRestoresHeader(trackedGesture: Bool) async throws {
        _ = NSApplication.shared
        let controller = TorrentStickyHeaders()
        let layout = makeHeaderLayout(12)
        controller.configure(layout, lowercase: false, inset: 16)
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 500, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { controller.detach(); window.close() }
        let host = NSHostingView(rootView: HeaderContinuityFixture(controller: controller, layout: layout))
        window.contentView = host
        window.orderFront(nil)
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
        let table = try #require(headerDescendants(host, NSTableView.self).first)
        let scroll = try #require(table.enclosingScrollView)
        scroll.contentView.scroll(to: .init(x: 0, y: 40))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(20))
        let title = try #require(headerDescendants(host, TitleHost.self).first { $0.isPinned && !$0.isHidden })
        NotificationCenter.default.post(name: trackedGesture ? NSScrollView.willStartLiveScrollNotification
                                                             : NSScrollView.didLiveScrollNotification, object: scroll)
        var offset: CGFloat = 40
        for burst in 0..<2 {
            try await Task.sleep(for: .milliseconds(16))
            offset += 60
            scroll.contentView.scroll(to: .init(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            #expect(title.alphaValue == 1)
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(20))
                offset += 1
                scroll.contentView.scroll(to: .init(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            }
            let suppressed = title.alphaValue < 1
            #expect(!suppressed, "header stayed invisible during the slow part of burst \(burst)")
            let opacity = try #require(title.layer?.presentation()?.opacity)
            #expect(opacity > 0.9, "header must be readable while slow scrolling continues")
        }
        // A stationary finger must not keep a title hidden either.
        try await Task.sleep(for: .milliseconds(220))
        let suppressed = title.alphaValue < 1
        #expect(!suppressed)
        if trackedGesture {
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(title.alphaValue == 1)
        #expect(scroll.contentView.bounds.minY == offset)
    }

}

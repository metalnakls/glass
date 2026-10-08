import AppKit
import SwiftUI
import GlassRemoteCore
@testable import GlassRemoteServices
import Testing
@testable import GlassRemoteUI

/// Exercise native List rendering through the production reorder preference boundary.
@MainActor @Suite("Native torrent-list rows", .serialized)
struct TorrentNativeListTests {
    private struct Entry: Identifiable { let id: Int; var header: Bool { id == 0 || id == 4 } }
    private enum Slot { case text, state }
    private struct FrameProbe: NSViewRepresentable {
        let id: Int
        let slot: Slot
        func makeNSView(context: Context) -> ProbeView { ProbeView(id: id, slot: slot) }
        func updateNSView(_ view: ProbeView, context: Context) { view.id = id; view.slot = slot }
        final class ProbeView: NSView {
            var id: Int
            var slot: Slot
            init(id: Int, slot: Slot) { self.id = id; self.slot = slot; super.init(frame: .zero) }
            required init?(coder: NSCoder) { fatalError() }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }

    private struct Fixture: View {
        let compact: Bool
        let selection: Int?
        private var columns: TorrentRowColumns { .init(showsArtwork: !compact, compact: compact, stateGap: 8) }
        var body: some View {
            List(selection: .constant(selection)) {
                ForEach((0..<8).map { Entry(id: $0) }) { entry in
                    GlassNativeReorderableRow(item: entry, moveDisabled: entry.header) {
                        if entry.header {
                            Text("Header").font(.largeTitle.bold()).padding(.vertical, GlassListMetrics.titleVerticalInset)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack(spacing: 0) {
                                if !compact { Color.blue.frame(width: TorrentRowColumns.artworkWidth, height: 42).padding(.trailing, TorrentRowColumns.artworkGap) }
                                Text("Torrent \(entry.id)").frame(maxWidth: .infinity, alignment: .leading)
                                    .background(FrameProbe(id: entry.id, slot: .text))
                                Circle().fill(.blue).frame(width: GlassListMetrics.stateDiameter(compact: compact), height: GlassListMetrics.stateDiameter(compact: compact))
                                    .padding(TorrentRowColumns.statePadding).background(FrameProbe(id: entry.id, slot: .state)).padding(.leading, 8)
                            }.padding(.horizontal, TorrentRowColumns.horizontalInset).frame(height: 64)
                        }
                    }
                    .tag(entry.id).selectionDisabled(entry.header).moveDisabled(entry.header)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .modifier(GlassListRowSeparator(visible: [1, 2, 5, 6].contains(entry.id) && selection != entry.id && selection != entry.id + 1,
                        leading: columns.textLeading, trailing: columns.textTrailing, tint: .red))
                    // Diagnostic color makes native rules measurable without font/appearance heuristics.
                }
            }.reorderContainer(for: Entry.self) { _ in }
                .listStyle(.plain).contentMargins(.horizontal, 0, for: .scrollContent)
                .environment(\.defaultMinListRowHeight, 0)
        }
    }

    private struct SpacingFixture: View {
        let controller: TorrentStickyHeaders
        let beforeFirst: CGFloat
        let belowHeader: CGFloat
        let betweenSections: CGFloat
        var body: some View {
            List {
                ForEach((0..<8).map { Entry(id: $0) }) { entry in
                    GlassNativeReorderableRow(item: entry, moveDisabled: entry.header) {
                        if entry.header {
                            TorrentStickyTitle(title: "Header", id: entry.id == 0 ? "unfinished" : "finished", rowIndex: entry.id, inset: 16, controller: controller)
                                .modifier(TorrentInlineHeaderSpacing(isFirst: entry.id == 0, beforeFirst: beforeFirst,
                                    betweenSections: betweenSections, belowHeader: belowHeader))
                        } else { Text("Torrent \(entry.id)").frame(height: 64) }
                    }.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
            }.reorderContainer(for: Entry.self) { _ in }.listStyle(.plain)
                .contentMargins(.top, 0, for: .scrollContent)
                .safeAreaBar(edge: .top, spacing: 0) {
                    TorrentHeaderSurface(controller: controller).frame(height: controller.titleHeight).allowsHitTesting(false)
                }.glassScrollEdges()
        }
    }

    private func configure(_ controller: TorrentStickyHeaders) {
        let source = UUID()
        let records = (0..<6).map { id in
            TorrentRecord(TorrentSummary(id: id, hashString: "fixture-\(id)", name: ["Aurora.mkv", "Solar Drift.mkv", "Quiet Coast.mkv", "Ocean.mkv", "Forest.mkv", "Ridge.mkv"][id], status: 0,
                percentDone: id < 3 ? 0.5 : 1, rateDownload: 0, rateUpload: 0, sizeWhenDone: 100,
                leftUntilDone: id < 3 ? 50 : 0, eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: nil), sourceID: source)
        }
        let layout = TorrentListLayout(rows: TorrentListRowPresentation.rows(records: records, pendingRenameNames: [:], expandedGroupIDs: []))
        #expect(layout.headerIndices == ["unfinished": 0, "finished": 4])
        #expect(layout.sections.allSatisfy { $0.rows.count == 3 && $0.allowsStickyHeader })
        controller.configure(layout, lowercase: false, inset: 16)
    }

    @Test("header Tune spacing updates the measured native title immediately and independently")
    func liveHeaderSpacing() async throws {
        _ = NSApplication.shared
        let controller = TorrentStickyHeaders()
        configure(controller)
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 500, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { controller.detach(); window.close() }
        let host = NSHostingView(rootView: SpacingFixture(controller: controller, beforeFirst: 16, belowHeader: 0, betweenSections: 16))
        window.contentView = host
        func measure() async throws -> [CGRect] {
            for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
            func titles(_ view: NSView) -> [TitleHost] {
                (view as? TitleHost).map { [$0] } ?? view.subviews.flatMap(titles)
            }
            let frames = titles(host).map { host.convert($0.bounds, from: $0) }.sorted { $0.minY < $1.minY }
            try #require(frames.count == 2)
            return frames
        }
        let baseline = try await measure()
        host.rootView = SpacingFixture(controller: controller, beforeFirst: 48, belowHeader: 0, betweenSections: 16)
        let first = try await measure()
        #expect(abs(first[0].minY - baseline[0].minY - 32) < 1)
        #expect(abs(first[1].minY - baseline[1].minY - 32) < 1)
        host.rootView = SpacingFixture(controller: controller, beforeFirst: 48, belowHeader: 20, betweenSections: 16)
        let below = try await measure()
        #expect(abs(below[0].minY - first[0].minY) < 1)
        #expect(abs(below[1].minY - first[1].minY - 20) < 1)
        host.rootView = SpacingFixture(controller: controller, beforeFirst: 48, belowHeader: 20, betweenSections: 44)
        let between = try await measure()
        #expect(abs(between[0].minY - below[0].minY) < 1)
        #expect(abs(between[1].minY - below[1].minY - 28) < 1)
        host.rootView = SpacingFixture(controller: controller, beforeFirst: 16, belowHeader: 0, betweenSections: 16)
        let restored = try await measure()
        #expect(restored == baseline)
    }

    @Test("production titles pin twenty points below the actual native viewport above native blur")
    func nativePinnedInset() async throws {
        _ = NSApplication.shared
        let controller = TorrentStickyHeaders()
        configure(controller)
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { controller.detach(); window.close() }
        let host = NSHostingView(rootView: SpacingFixture(controller: controller, beforeFirst: 16, belowHeader: 0, betweenSections: 16))
        window.contentView = host
        func settle() async throws {
            for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
        }
        try await settle()
        func table(_ view: NSView) -> NSTableView? {
            (view as? NSTableView) ?? view.subviews.lazy.compactMap(table).first
        }
        let native = try #require(table(host))
        let scroll = try #require(native.enclosingScrollView)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 40))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        func titles(_ view: NSView) -> [TitleHost] {
            (view as? TitleHost).map { [$0] } ?? view.subviews.flatMap(titles)
        }
        func pinFrame() throws -> CGRect {
            let title = try #require(titles(host).first { $0.isPinned && !$0.isHidden })
            #expect(title.alphaValue == 1)
            #expect(title.layer?.filters == nil)
            let frame = host.convert(title.bounds, from: title)
            let viewport = host.convert(scroll.contentView.bounds, from: scroll.contentView)
            #expect(abs(frame.minY - viewport.minY - 20) < 1)
            return frame
        }
        let pinned = try pinFrame()
        host.rootView = SpacingFixture(controller: controller, beforeFirst: 48, belowHeader: 0, betweenSections: 16)
        try await settle()
        #expect(try pinFrame() == pinned)
    }

    @Test("native rules exclude title boundaries and match actual content columns", arguments: [390.0, 500.0, 600.0], [nil, 2] as [Int?])
    func nativeRules(width: Double, selection: Int?) throws {
        let compact = TorrentRowDensity(width: width) == .compact
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: width, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: Fixture(compact: compact, selection: selection))
        window.contentView = host
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)); host.layoutSubtreeIfNeeded() }
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let native = try #require(table(in: host))
        #expect(native.numberOfRows == 8)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        func redXs(at boundary: CGFloat) -> [Int] {
            let y = Int(boundary * scale)
            return (0..<bitmap.pixelsWide).filter { x in
                (max(0, y - 2)..<min(bitmap.pixelsHigh, y + 2)).contains { py in
                    guard let c = bitmap.colorAt(x: x, y: py)?.usingColorSpace(.deviceRGB) else { return false }
                    return c.redComponent > 0.7 && c.greenComponent < 0.6 && c.blueComponent < 0.6
                }
            }
        }
        func probes(_ view: NSView) -> [FrameProbe.ProbeView] {
            (view as? FrameProbe.ProbeView).map { [$0] } ?? view.subviews.flatMap(probes)
        }
        let slots = probes(host)
        for i in 0..<8 {
            let row = native.rect(ofRow: i)
            let converted = host.convert(row, from: native)
            let boundary = host.isFlipped ? converted.maxY : host.bounds.height - converted.minY
            let xs = redXs(at: boundary)
            if [1, 2, 5, 6].contains(i) && selection != i && selection != i + 1 {
                let columns = TorrentRowColumns(showsArtwork: !compact, compact: compact, stateGap: 8)
                let cell = try #require(native.view(atColumn: 0, row: i, makeIfNecessary: false))
                let contentFrame = host.convert(cell.bounds, from: cell)
                #expect(!xs.isEmpty)
                #expect(abs(CGFloat(xs.first ?? -999) / scale - (contentFrame.minX + columns.textLeading)) <= 1)
                #expect(abs(CGFloat(xs.last ?? -999) / scale - (contentFrame.maxX - columns.textTrailing)) <= 1)
                let text = try #require(slots.first { $0.id == i && $0.slot == .text })
                let state = try #require(slots.first { $0.id == i && $0.slot == .state })
                let textFrame = host.convert(text.bounds, from: text)
                let stateFrame = host.convert(state.bounds, from: state)
                #expect(abs(CGFloat(xs.first ?? -999) / scale - textFrame.minX) <= 1)
                #expect(abs(CGFloat(xs.last ?? -999) / scale - textFrame.maxX) <= 1)
                #expect(CGFloat(xs.last ?? -999) / scale < stateFrame.minX)
                #expect(abs(textFrame.midY - converted.midY) <= 1)
                #expect(abs(stateFrame.midY - converted.midY) <= 1)
            } else { #expect(xs.isEmpty) }
            if i != 0 && i != 4 { #expect(row.height == 64) }
        }
    }
}

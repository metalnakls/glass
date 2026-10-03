import AppKit
import Observation
import SwiftUI

private struct StickyTitleLabel: View {
    let title: String
    let inset: CGFloat
    var body: some View {
        Text(title).font(.largeTitle.bold()).foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, inset).padding(.vertical, 8)
    }
}

struct TorrentStickyTitle: View {
    let title: String
    let id: String
    let rowIndex: Int
    let inset: CGFloat
    let controller: TorrentStickyHeaders
    var body: some View {
        StickyTitleLabel(title: title, inset: inset)
            .opacity(controller.overlayIDs.contains(id) ? 0 : 1)
            .background(HeaderAnchor(controller: controller, id: id, title: title, index: rowIndex, inset: inset))
    }
}

/// Converts the actual inline title frames into one continuous pin/push layout.
/// Both titles keep their measured x coordinate, height and internal padding.
enum TorrentStickyHeaderGeometry {
    struct Placement: Equatable { let index: Int; let frame: CGRect }
    struct Layout: Equatable {
        let titles: [Placement]
        let backdropHeight: CGFloat
        let backdropOpacity: CGFloat
    }
    static func layout(frames: [CGRect], viewport: CGRect, feather: CGFloat = 32) -> Layout? {
        guard let index = frames.indices.last(where: { frames[$0].minY < viewport.minY }) else { return nil }
        let original = frames[index]
        let next = index + 1 < frames.count ? frames[index + 1] : nil
        var pinned = original.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
        pinned.origin.y = min(0, (next?.minY ?? .greatestFiniteMagnitude) - viewport.minY - original.height)
        var titles = [Placement(index: index, frame: pinned)]
        let height = original.height + feather
        if let next, next.minY - viewport.minY < height {
            titles.append(Placement(index: index + 1, frame: next.offsetBy(dx: -viewport.minX, dy: -viewport.minY)))
        }
        // Only the first pin fades the material in. Section handoff never resets it.
        let opacity = min(1, max(0, (viewport.minY - frames[0].minY) / 12))
        return Layout(titles: titles, backdropHeight: height, backdropOpacity: opacity)
    }
}

private struct HeaderAnchor: NSViewRepresentable {
    let controller: TorrentStickyHeaders
    let id: String
    let title: String
    let index: Int
    let inset: CGFloat
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.controller = controller; view.id = id; view.title = title; view.index = index; view.inset = inset
        view.connect()
    }
    final class Anchor: NSView {
        weak var controller: TorrentStickyHeaders?
        var id = "", title = ""
        var index = 0
        var inset: CGFloat = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); connect() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        func connect() {
            guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
            var parent = superview
            while let view = parent {
                if let table = view as? NSTableView {
                    controller?.register(table: table, anchor: self, id: id, title: title, index: index, inset: inset)
                    return
                }
                parent = view.superview
            }
        }
    }
}

@MainActor @Observable
final class TorrentStickyHeaders: NSObject {
    struct Header { var id: String; var title: String; var index: Int; var inset: CGFloat }
    private struct Measurement: Equatable {
        let leading: CGFloat
        let trailing: CGFloat
        let top: CGFloat
        let height: CGFloat
        func frame(in row: CGRect) -> CGRect {
            CGRect(x: row.minX + leading, y: row.minY + top,
                   width: max(0, row.width - leading - trailing), height: height)
        }
    }
    var overlayIDs: Set<String> = []
    @ObservationIgnored private weak var table: NSTableView?
    @ObservationIgnored private var headers: [String: Header] = [:]
    @ObservationIgnored private var measurements: [String: Measurement] = [:]
    @ObservationIgnored private let overlay = HeaderBackdrop()
    @ObservationIgnored private var updateScheduled = false

    func register(table: NSTableView, anchor: NSView, id: String, title: String, index: Int, inset: CGFloat) {
        guard index < table.numberOfRows else { return }
        let measured = table.convert(anchor.bounds, from: anchor)
        let row = table.rect(ofRow: index)
        let measurement = Measurement(leading: measured.minX - row.minX, trailing: row.maxX - measured.maxX,
                                      top: measured.minY - row.minY, height: measured.height)
        let changed = measurements[id] != measurement || headers[id].map { $0.title != title || $0.index != index || $0.inset != inset } ?? true
        measurements[id] = measurement
        headers[id] = Header(id: id, title: title, index: index, inset: inset)
        let needsAttach = self.table !== table
        if needsAttach, let scroll = table.enclosingScrollView {
            NotificationCenter.default.removeObserver(self)
            overlay.removeFromSuperview()
            self.table = table
            table.floatsGroupRows = false
            scroll.addSubview(overlay, positioned: .above, relativeTo: nil)
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.contentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(update), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(update), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        }
        if changed || needsAttach { scheduleUpdate() }
    }
    func configure(_ sections: [TorrentListSection], inset: CGFloat) {
        var index = 0
        headers = Dictionary(uniqueKeysWithValues: sections.map { section in
            defer { index += section.rows.count + 1 }
            return (section.id, Header(id: section.id, title: section.title, index: index, inset: inset))
        })
        measurements = measurements.filter { headers[$0.key] != nil }
        scheduleUpdate()
    }
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.update()
        }
    }
    @objc private func update() {
        guard let table, let scroll = table.enclosingScrollView else { return }
        let clip = scroll.contentView
        let ordered = headers.values.filter { $0.index < table.numberOfRows }.sorted { $0.index < $1.index }
        let frames = ordered.map { header in
            let row = table.rect(ofRow: header.index)
            // Offscreen headers retain their last measured row-relative geometry.
            let measured = measurements[header.id] ?? measurements.values.first
            return measured?.frame(in: row) ?? row
        }
        let viewport = table.convert(clip.bounds, from: clip)
        guard let layout = TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport) else {
            overlay.isHidden = true
            if !overlayIDs.isEmpty { overlayIDs = [] }
            return
        }
        // Clip at the viewport, never at the moving title's own edge.
        overlay.frame = scroll.convert(clip.bounds, from: clip)
        overlay.isHidden = false
        overlay.present(layout: layout, headers: ordered)
        let ids = Set(layout.titles.map { ordered[$0.index].id })
        if overlayIDs != ids { overlayIDs = ids }
    }
    isolated deinit { NotificationCenter.default.removeObserver(self); overlay.removeFromSuperview() }
}

private final class HeaderBackdrop: NSView {
    private let effect = NSVisualEffectView()
    private let fadeMask = CAGradientLayer()
    private var titles: [String: TitleHost] = [:]
    private var backdropSize = CGSize.zero
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        effect.material = .headerView
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        fadeMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fadeMask.locations = [0, 0.48, 1]
        fadeMask.startPoint = CGPoint(x: 0.5, y: 1)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 0)
        effect.layer?.mask = fadeMask
        addSubview(effect)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present(layout: TorrentStickyHeaderGeometry.Layout, headers: [TorrentStickyHeaders.Header]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        effect.frame = CGRect(x: 0, y: 0, width: bounds.width, height: layout.backdropHeight)
        effect.alphaValue = layout.backdropOpacity
        if backdropSize != effect.bounds.size {
            backdropSize = effect.bounds.size
            fadeMask.frame = effect.bounds
        }
        let visible = Set(layout.titles.map { headers[$0.index].id })
        for (id, host) in titles { host.isHidden = !visible.contains(id) }
        for placement in layout.titles {
            let header = headers[placement.index]
            let host: TitleHost
            if let existing = titles[header.id] { host = existing }
            else {
                host = TitleHost(rootView: StickyTitleLabel(title: header.title, inset: header.inset))
                titles[header.id] = host
                addSubview(host)
            }
            host.setTitle(header.title, inset: header.inset)
            host.frame = placement.frame
            host.isHidden = false
        }
    }
}

private final class TitleHost: NSHostingView<StickyTitleLabel> {
    private var titleKey = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func setTitle(_ title: String, inset: CGFloat) {
        let key = "\(title):\(inset)"
        guard titleKey != key else { return }
        titleKey = key
        rootView = StickyTitleLabel(title: title, inset: inset)
    }
}

import AppKit
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
        HeaderAnchor(controller: controller, id: id, title: title, index: rowIndex, inset: inset)
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
    static func layout(frames: [CGRect], viewport: CGRect, feather: CGFloat = 48, topInset: CGFloat = 0) -> Layout? {
        guard let index = frames.indices.last(where: { frames[$0].minY < viewport.minY + topInset }) else { return nil }
        let original = frames[index]
        let next = index + 1 < frames.count ? frames[index + 1] : nil
        var pinned = original.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
        pinned.origin.y = min(topInset, (next?.minY ?? .greatestFiniteMagnitude) - viewport.minY - original.height)
        var titles = [Placement(index: index, frame: pinned)]
        let height = topInset + original.height + feather
        if let next, next.minY - viewport.minY < height {
            titles.append(Placement(index: index + 1, frame: next.offsetBy(dx: -viewport.minX, dy: -viewport.minY)))
        }
        // Only the first pin fades the material in. Section handoff never resets it.
        let opacity = min(1, max(0, (viewport.minY + topInset - frames[0].minY) / 12))
        return Layout(titles: titles, backdropHeight: height, backdropOpacity: opacity)
    }
}

private struct HeaderAnchor: NSViewRepresentable {
    let controller: TorrentStickyHeaders
    let id: String
    let title: String
    let index: Int
    let inset: CGFloat
    func makeNSView(context: Context) -> Anchor { Anchor(titleHost: controller.titleHost(id: id, title: title, inset: inset)) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Anchor, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        return nsView.titleHost.fittingSize(width: width)
    }
    func updateNSView(_ view: Anchor, context: Context) {
        view.controller = controller; view.id = id; view.title = title; view.index = index; view.inset = inset
        view.titleHost.setTitle(title, inset: inset)
        view.connect()
    }
    final class Anchor: NSView {
        weak var controller: TorrentStickyHeaders?
        var id = "", title = ""
        var index = 0
        var inset: CGFloat = 0
        let titleHost: TitleHost
        init(titleHost: TitleHost) {
            self.titleHost = titleHost
            super.init(frame: .zero)
            titleHost.inlineContainer = self
            if !titleHost.isPinned { addSubview(titleHost) }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            if titleHost.superview === self { titleHost.frame = bounds }
            connect()
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        func connect() {
            guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
            titleHost.inlineContainer = self
            if !titleHost.isPinned, titleHost.superview !== self {
                addSubview(titleHost)
                titleHost.isHidden = false
                titleHost.frame = bounds
                titleHost.needsLayout = true
                titleHost.layoutSubtreeIfNeeded()
            }
            var parent = superview
            while let view = parent {
                if let table = view as? NSTableView {
                    controller?.register(table: table, anchor: self, host: titleHost, id: id, title: title, index: index, inset: inset)
                    return
                }
                parent = view.superview
            }
        }
    }
}

@MainActor
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
    private weak var table: NSTableView?
    private var headers: [String: Header] = [:]
    private var measurements: [String: Measurement] = [:]
    private var titleHosts: [String: TitleHost] = [:]
    private let overlay = HeaderBackdrop()
    private var updateScheduled = false

    fileprivate func titleHost(id: String, title: String, inset: CGFloat) -> TitleHost {
        if let host = titleHosts[id] { host.setTitle(title, inset: inset); return host }
        let host = TitleHost(title: title, inset: inset)
        titleHosts[id] = host
        return host
    }

    fileprivate func register(table: NSTableView, anchor: NSView, host: TitleHost, id: String, title: String, index: Int, inset: CGFloat) {
        guard index < table.numberOfRows else { return }
        let measured = table.convert(anchor.bounds, from: anchor)
        let row = table.rect(ofRow: index)
        guard table.row(at: CGPoint(x: measured.midX, y: measured.midY)) == index else { return }
        if let previous = titleHosts[id], previous !== host { previous.removeFromSuperview() }
        titleHosts[id] = host
        let measurement = Measurement(leading: measured.minX - row.minX, trailing: row.maxX - measured.maxX,
                                      top: measured.minY - row.minY, height: measured.height)
        let changed = measurements[id] != measurement || headers[id].map { $0.title != title || $0.index != index || $0.inset != inset } ?? true
        measurements[id] = measurement
        headers[id] = Header(id: id, title: title, index: index, inset: inset)
        let needsAttach = self.table !== table
        attach(table)
        if changed || needsAttach { scheduleUpdate() }
    }
    func attach(_ table: NSTableView) {
        guard self.table !== table, let scroll = table.enclosingScrollView else { return }
        NotificationCenter.default.removeObserver(self)
        overlay.removeFromSuperview()
        self.table = table
        table.floatsGroupRows = false
        scroll.addSubview(overlay, positioned: .above, relativeTo: nil)
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        scheduleUpdate()
    }

    func configure(_ sections: [TorrentListSection], inset: CGFloat) {
        var index = 0
        headers = Dictionary(uniqueKeysWithValues: sections.map { section in
            defer { index += section.rows.count + 1 }
            return (section.id, Header(id: section.id, title: section.title, index: index, inset: inset))
        })
        measurements = measurements.filter { headers[$0.key] != nil }
        for header in headers.values { _ = titleHost(id: header.id, title: header.title, inset: header.inset) }
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
        guard let layout = TorrentStickyHeaderGeometry.layout(frames: frames, viewport: viewport, topInset: 20) else {
            overlay.isHidden = true
            overlay.restoreInlineTitles()
            return
        }
        // Clip at the viewport, never at the moving title's own edge.
        overlay.frame = scroll.convert(clip.bounds, from: clip)
        overlay.isHidden = false
        overlay.present(layout: layout, headers: ordered, hosts: titleHosts)
    }
    isolated deinit { NotificationCenter.default.removeObserver(self); overlay.removeFromSuperview() }
}

final class HeaderBackdrop: NSView {
    private let effect = NSVisualEffectView()
    private let fadeMask = CAGradientLayer()
    private var titles: [String: TitleHost] = [:]
    func restoreInlineTitles(except retained: Set<String> = []) {
        for (id, host) in titles where !retained.contains(id) {
            host.isPinned = false
            if let inline = host.inlineContainer, inline.window != nil {
                inline.addSubview(host)
                host.isHidden = false
                host.frame = inline.bounds
                host.needsLayout = true
                host.layoutSubtreeIfNeeded()
            } else { host.removeFromSuperview() }
            titles[id] = nil
        }
    }
    private var backdropSize = CGSize.zero
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        fadeMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fadeMask.locations = [0, 0.25, 1]
        fadeMask.startPoint = CGPoint(x: 0.5, y: 1)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 0)
        effect.layer?.mask = fadeMask
        addSubview(effect)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present(layout: TorrentStickyHeaderGeometry.Layout, headers: [TorrentStickyHeaders.Header], hosts: [String: TitleHost]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        effect.frame = CGRect(x: 0, y: 0, width: bounds.width, height: layout.backdropHeight)
        effect.alphaValue = layout.backdropOpacity * 0.75
        if backdropSize != effect.bounds.size {
            backdropSize = effect.bounds.size
            fadeMask.frame = effect.bounds
        }
        let visible = Set(layout.titles.map { headers[$0.index].id })
        restoreInlineTitles(except: visible)
        for placement in layout.titles {
            let header = headers[placement.index]
            guard let host = hosts[header.id] else { continue }
            let reparented = host.superview !== self
            if reparented { addSubview(host) }
            host.isPinned = true
            host.isHidden = false
            host.alphaValue = 1
            titles[header.id] = host
            // Scrolling changes position only. Hosting layout never participates
            // in the per-scroll movement and cannot resize a competing copy.
            if host.frame.size != placement.frame.size { host.setFrameSize(placement.frame.size) }
            host.setFrameOrigin(placement.frame.origin)
            if reparented {
                host.needsLayout = true
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
        }
    }
}

final class TitleHost: NSView {
    weak var inlineContainer: NSView?
    var isPinned = false
    private let hosting: NSHostingController<StickyTitleLabel>
    private var titleKey = ""
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init(title: String, inset: CGFloat) {
        hosting = NSHostingController(rootView: StickyTitleLabel(title: title, inset: inset))
        super.init(frame: .zero)
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        if let view = hosting.view as? NSHostingView<StickyTitleLabel> {
            view.sizingOptions = []
            view.safeAreaRegions = []
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
        }
        addSubview(hosting.view)
        titleKey = "\(title):\(inset)"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func fittingSize(width: CGFloat) -> CGSize {
        let fitted = hosting.sizeThatFits(in: CGSize(width: width, height: 1000))
        return CGSize(width: width, height: fitted.height)
    }
    func setTitle(_ title: String, inset: CGFloat) {
        let key = "\(title):\(inset)"
        guard titleKey != key else { return }
        titleKey = key
        hosting.rootView = StickyTitleLabel(title: title, inset: inset)
    }
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        hosting.view.frame = bounds
    }
    override func layout() {
        super.layout()
        hosting.view.frame = bounds
    }
}

import AppKit
import Observation
import SwiftUI

struct TorrentStickyTitle: View {
    let title: String
    let id: String
    let rowIndex: Int
    let inset: CGFloat
    let controller: TorrentStickyHeaders
    var body: some View {
        Text(title).font(.largeTitle.bold()).foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, inset).padding(.vertical, 8)
            .opacity(controller.pinnedID == id ? 0 : 1)
            .background(HeaderAnchor(controller: controller, id: id, title: title, index: rowIndex, inset: inset))
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
            guard window != nil else { return }
            var parent = superview
            while let view = parent {
                if let table = view as? NSTableView {
                    controller?.register(table: table, id: id, title: title, index: index, inset: inset)
                    return
                }
                parent = view.superview
            }
        }
    }
}

/// Header geometry stays in the table. Only a title which has passed the viewport
/// top is copied into the backdrop layer; the next header pushes that layer away.
@MainActor @Observable
final class TorrentStickyHeaders: NSObject {
    struct Header { var id: String; var title: String; var index: Int; var inset: CGFloat }
    var pinnedID: String?
    @ObservationIgnored private weak var table: NSTableView?
    @ObservationIgnored private var headers: [String: Header] = [:]
    @ObservationIgnored private let overlay = HeaderBackdrop()
    @ObservationIgnored private var lastTitle = ""
    func register(table: NSTableView, id: String, title: String, index: Int, inset: CGFloat) {
        let changed = headers[id].map { $0.title != title || $0.index != index || $0.inset != inset } ?? true
        headers[id] = Header(id: id, title: title, index: index, inset: inset)
        let needsAttach = self.table !== table
        if self.table !== table, let scroll = table.enclosingScrollView {
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
        // Registration happens during SwiftUI layout; defer observable changes.
        if changed || needsAttach { Task { @MainActor [weak self] in self?.update() } }
    }
    func configure(_ sections: [TorrentListSection], inset: CGFloat) {
        var index = 0
        headers = Dictionary(uniqueKeysWithValues: sections.map { section in
            defer { index += section.rows.count + 1 }
            return (section.id, Header(id: section.id, title: section.title, index: index, inset: inset))
        })
        Task { @MainActor [weak self] in self?.update() }
    }
    @objc private func update() {
        guard let table, let clip = table.enclosingScrollView?.contentView else { return }
        let ordered = headers.values.filter { $0.index < table.numberOfRows }.sorted { $0.index < $1.index }
        let top = clip.bounds.minY
        guard let header = ordered.last(where: { table.rect(ofRow: $0.index).minY < top }) else {
            overlay.isHidden = true; pinnedID = nil; return
        }
        let height = table.rect(ofRow: header.index).height
        let next = ordered.first(where: { $0.index > header.index }).map { table.rect(ofRow: $0.index).minY }
        let push = min(0, (next ?? .greatestFiniteMagnitude) - top - height)
        let scroll = table.enclosingScrollView!
        let y = scroll.isFlipped ? clip.frame.minY + push : clip.frame.maxY - height - push
        overlay.frame = NSRect(x: clip.frame.minX, y: y, width: clip.frame.width, height: height)
        overlay.isHidden = false
        overlay.setTitle(header.title, inset: header.inset)
        if pinnedID != header.id { pinnedID = header.id }
    }
    isolated deinit { NotificationCenter.default.removeObserver(self); overlay.removeFromSuperview() }
}

private final class HeaderBackdrop: NSView {
    private let effect = NSVisualEffectView()
    private let title = NSHostingView(rootView: AnyView(EmptyView()))
    private var titleKey = ""
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        effect.material = .headerView
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        addSubview(effect); addSubview(title)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setTitle(_ text: String, inset: CGFloat) {
        let key = "\(text):\(inset)"
        guard titleKey != key else { return }
        titleKey = key
        title.rootView = AnyView(Text(text).font(.largeTitle.bold()).foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.leading, inset))
    }
    override func layout() {
        super.layout()
        title.frame = bounds
        effect.frame = bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        // The material's alpha falls off smoothly. The title itself is never masked.
        let mask = CAGradientLayer()
        mask.frame = effect.bounds
        mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        mask.locations = [0, 0.55, 1]
        mask.startPoint = CGPoint(x: 0.5, y: 1)
        mask.endPoint = CGPoint(x: 0.5, y: 0)
        effect.layer?.mask = mask
    }
}

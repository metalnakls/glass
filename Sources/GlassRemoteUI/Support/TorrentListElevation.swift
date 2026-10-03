import AppKit
import SwiftUI

/// Draw the shadow above the table's row clipping, while SwiftUI draws the card
/// behind its content. Native selection, virtualization and hit testing stay intact.
struct TorrentListElevationAnchor: NSViewRepresentable {
    let controller: TorrentListElevationController
    let selected: Bool
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.controller = controller
        view.selected = selected
        view.connect()
    }
    final class Anchor: NSView {
        weak var controller: TorrentListElevationController?
        var selected = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
        func connect() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    table.selectionHighlightStyle = .none
                    table.focusRingType = .none
                    controller?.attach(table)
                    if selected { controller?.select(self) }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

@MainActor
final class TorrentListElevationController: NSObject {
    private weak var table: NSTableView?
    private weak var selectedAnchor: NSView?
    private let overlay = ElevationOverlay()

    func attach(_ table: NSTableView) {
        guard self.table !== table, let scroll = table.enclosingScrollView else { return }
        detach()
        self.table = table
        scroll.addSubview(overlay, positioned: .above, relativeTo: scroll.contentView)
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.frameDidChangeNotification, object: scroll.contentView)
    }
    func select(_ anchor: NSView) {
        let changed = selectedAnchor !== anchor
        selectedAnchor = anchor
        update(animated: changed)
    }
    func clear() { selectedAnchor = nil; update(animated: true) }
    func detach() {
        NotificationCenter.default.removeObserver(self)
        overlay.removeFromSuperview()
        table = nil
        selectedAnchor = nil
    }
    @objc private func scrolled() { update(animated: false) }
    private func update(animated: Bool) {
        guard let table, let clip = table.enclosingScrollView?.contentView else { return }
        overlay.frame = clip.frame
        guard let selectedAnchor, selectedAnchor.window != nil else {
            overlay.show(nil, animated: animated)
            return
        }
        let index = table.row(for: selectedAnchor)
        guard index >= 0 else { overlay.show(nil, animated: animated); return }
        var rect = overlay.convert(table.rect(ofRow: index), from: table)
        rect.origin.x = 10
        rect.size.width = max(0, overlay.bounds.width - 20)
        rect = rect.insetBy(dx: 0, dy: 3)
        overlay.show(rect, animated: animated)
    }
}

@MainActor
private final class ElevationOverlay: NSView {
    private let top = CALayer()
    private let bottom = CALayer()
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        for shadow in [top, bottom] {
            shadow.backgroundColor = NSColor.white.cgColor
            shadow.cornerRadius = 12
            shadow.shadowColor = NSColor.black.cgColor
            layer?.addSublayer(shadow)
        }
        top.shadowOpacity = 0.12
        top.shadowRadius = 8
        top.shadowOffset = CGSize(width: 0, height: -4)
        bottom.shadowOpacity = 0.22
        bottom.shadowRadius = 12
        bottom.shadowOffset = CGSize(width: 0, height: 7)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(_ rect: CGRect?, animated: Bool) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        defer { CATransaction.commit() }
        guard let rect, rect.intersects(bounds) else { layer.opacity = 0; return }
        layer.opacity = 1
        for shadow in [top, bottom] {
            shadow.frame = rect
            shadow.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: 12, cornerHeight: 12, transform: nil)
        }
        // Cut out the card itself: this overlay paints shadows only, never over
        // names, icons, progress rings or buttons.
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRoundedRect(in: rect, cornerWidth: 12, cornerHeight: 12)
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path = path
        mask.fillRule = .evenOdd
        layer.mask = mask
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.25
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "elevation")
        }
    }
}

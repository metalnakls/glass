import AppKit
import SwiftUI

struct TorrentShadowSettings: Equatable {
    var topStrength = 0.12
    var topSoftness = 8.0
    var topLift = 4.0
    var bottomStrength = 0.22
    var bottomSoftness = 12.0
    var bottomLift = 7.0
    var easeIn = 0.25
    var easeOut = 0.30
}

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
        override func layout() { super.layout(); connect() }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); connect() }
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
    private var settings = TorrentShadowSettings()
    var dragSelectionChanged: ((Int) -> Void)?
    private var dragMonitor: Any?
    private var dragStartedInTable = false
    func configure(_ settings: TorrentShadowSettings) {
        self.settings = settings
        update(animated: false)
    }

    func attach(_ table: NSTableView) {
        guard self.table !== table, let scroll = table.enclosingScrollView else { return }
        detach()
        self.table = table
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.trackSelectionDrag(event)
            return event
        }
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
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        dragStartedInTable = false
        NotificationCenter.default.removeObserver(self)
        overlay.removeFromSuperview()
        table = nil
        selectedAnchor = nil
    }
    @objc private func scrolled() { update(animated: false) }
    private func trackSelectionDrag(_ event: NSEvent) {
        guard let table, event.window === table.window else { return }
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: point)
        if event.type == .leftMouseDown {
            dragStartedInTable = row >= 0 && table.visibleRect.contains(point)
            // Leave native controls in charge of their own press/drag gestures.
            var hit = table.hitTest(table.superview?.convert(event.locationInWindow, from: nil) ?? point)
            while let view = hit, view !== table {
                if view is NSControl { dragStartedInTable = false; break }
                hit = view.superview
            }
        } else if event.type == .leftMouseUp {
            dragStartedInTable = false
        } else if dragStartedInTable, row >= 0, table.visibleRect.contains(point) {
            dragSelectionChanged?(row)
        }
    }
    private func update(animated: Bool) {
        guard let table, let clip = table.enclosingScrollView?.contentView else { return }
        overlay.frame = clip.frame
        guard let selectedAnchor, selectedAnchor.window != nil else {
            overlay.show(nil, settings: settings, animated: animated)
            return
        }
        // The anchor fills the actual SwiftUI card background. Its bounds are
        // the single source of truth for the card, outline, cutout and shadows.
        let rect = overlay.convert(selectedAnchor.bounds, from: selectedAnchor)
        overlay.show(rect, settings: settings, animated: animated)
    }
}

@MainActor
private final class ElevationOverlay: NSView {
    private let top = CALayer()
    private let bottom = CALayer()
    private var displayedRect: CGRect?
    private var departing: CALayer?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        for shadow in [top, bottom] {
            shadow.backgroundColor = NSColor.clear.cgColor
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
    func show(_ rect: CGRect?, settings: TorrentShadowSettings, animated: Bool) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        defer { CATransaction.commit() }
        guard let rect, rect.intersects(bounds) else {
            if animated, displayedRect != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                layer.mask = nil
                fadePreviousRow(in: layer, duration: settings.easeOut)
                top.shadowOpacity = 0
                bottom.shadowOpacity = 0
                top.removeAllAnimations()
                bottom.removeAllAnimations()
            } else {
                layer.opacity = 0
            }
            displayedRect = nil
            return
        }
        let moving = animated && displayedRect != nil && displayedRect != rect
        if moving && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            fadePreviousRow(in: layer, duration: settings.easeOut)
        }
        displayedRect = rect
        layer.opacity = 1
        top.shadowOpacity = Float(min(max(settings.topStrength, 0), 1))
        top.shadowRadius = max(settings.topSoftness, 0)
        top.shadowOffset = CGSize(width: 0, height: -max(settings.topLift, 0))
        bottom.shadowOpacity = Float(min(max(settings.bottomStrength, 0), 1))
        bottom.shadowRadius = max(settings.bottomSoftness, 0)
        bottom.shadowOffset = CGSize(width: 0, height: max(settings.bottomLift, 0))
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
            for shadow in [top, bottom] {
                animate(shadow, key: "shadowOpacity", from: 0, to: Double(shadow.shadowOpacity), duration: settings.easeIn)
                animate(shadow, key: "shadowRadius", from: shadow.shadowRadius + 12, to: shadow.shadowRadius, duration: settings.easeIn)
            }
        }
    }

    private func fadePreviousRow(in parent: CALayer, duration: Double) {
        guard let displayedRect else { return }
        departing?.removeFromSuperlayer()
        let ghost = CALayer()
        ghost.frame = bounds
        for original in [top, bottom] {
            let current = original.presentation() ?? original
            let shadow = CALayer()
            shadow.frame = original.frame
            shadow.shadowPath = original.shadowPath
            shadow.shadowColor = original.shadowColor
            shadow.shadowOffset = original.shadowOffset
            shadow.shadowOpacity = current.shadowOpacity
            shadow.shadowRadius = current.shadowRadius + 12
            ghost.addSublayer(shadow)
            animate(shadow, key: "shadowRadius", from: current.shadowRadius, to: shadow.shadowRadius, duration: duration)
        }
        let cutout = CGMutablePath()
        cutout.addRect(bounds)
        cutout.addRoundedRect(in: displayedRect, cornerWidth: 12, cornerHeight: 12)
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path = cutout
        mask.fillRule = .evenOdd
        ghost.mask = mask
        ghost.opacity = 0
        parent.addSublayer(ghost)
        animate(ghost, key: "opacity", from: 1, to: 0, duration: duration)
        departing = ghost
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.01) { ghost.removeFromSuperlayer() }
    }

    // Yina OSC's smoothstep dissolve, with adjustable durations. Core Animation
    // interpolates these samples; no per-frame Swift work or rendering timer.
    private func animate(_ layer: CALayer, key: String, from: Double, to: Double, duration: Double) {
        guard duration > 0 else { layer.removeAnimation(forKey: key); return }
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = (0...120).map { index in
            let t = Double(index) / 120
            return from + (to - from) * t * t * (3 - 2 * t)
        }
        animation.duration = duration
        animation.calculationMode = .linear
        layer.add(animation, forKey: key)
    }
}

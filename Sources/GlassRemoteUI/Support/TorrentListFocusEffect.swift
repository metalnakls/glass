import AppKit
import SwiftUI

/// Scrolling dismisses focus until a click or an offscreen-to-onscreen transition.
struct TorrentFocusState {
    private(set) var armed = false
    private(set) var visible = false
    private(set) var scrolling = false
    private var pendingReentry = false
    var showsFocus: Bool { armed && visible && !scrolling }

    mutating func select() { armed = true }
    mutating func scroll() { if !scrolling { armed = false } }
    mutating func liveScroll(_ active: Bool) {
        if active && !scrolling { armed = false; pendingReentry = false }
        scrolling = active
        if !active && pendingReentry { armed = true; pendingReentry = false }
    }
    mutating func visibility(_ value: Bool) {
        if value && !visible {
            if scrolling { pendingReentry = true } else { armed = true }
        }
        if !value { pendingReentry = false }
        visible = value
    }
}

struct TorrentFocusSettings: Equatable {
    var strength = 0.55
    var feather = 90.0
    var aboveGap = 0.0
    var belowGap = 0.0
    var tuning = false
}

struct TorrentFocusRegions {
    let above: CGRect
    let below: CGRect

    init(viewport: CGSize, selectedRow: CGRect, aboveGap: Double = 0, belowGap: Double = 0) {
        let top = min(max(selectedRow.minY - 2 - max(aboveGap, 0), 0), viewport.height)
        let bottom = min(max(selectedRow.maxY + 2 + max(belowGap, 0), 0), viewport.height)
        above = CGRect(x: 0, y: 0, width: viewport.width, height: top)
        below = CGRect(x: 0, y: bottom, width: viewport.width, height: viewport.height - bottom)
    }
}

struct TorrentListFocusAnchor: NSViewRepresentable {
    let controller: TorrentListFocusController
    let id: String
    let selected: Bool

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.controller = controller
        view.selected = selected
        view.id = id
        view.connect()
    }

    final class Anchor: NSView {
        weak var controller: TorrentListFocusController?
        var selected = false
        var id = ""
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
        func connect() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    controller?.attach(to: table)
                    if selected { controller?.select(anchor: self, id: id) }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

@MainActor
final class TorrentListFocusController: NSObject {
    private weak var table: NSTableView?
    private weak var anchor: NSView?
    private var selectedID: String?
    private let overlay = FocusOverlay()
    private var state = TorrentFocusState()
    private var eventMonitor: Any?
    private var scrollSettlementTask: Task<Void, Never>?
    private var lastGeometry: CGRect = .null
    private var settings = TorrentFocusSettings()
    var onGapChange: ((Bool, Double) -> Void)?

    func configure(_ settings: TorrentFocusSettings) {
        self.settings = settings
        overlay.settings = settings
        overlay.onGapChange = { [weak self] above, value in self?.onGapChange?(above, value) }
        lastGeometry = .null
        update()
    }

    func attach(to table: NSTableView) {
        guard self.table !== table, let scroll = table.enclosingScrollView else { return }
        detach()
        self.table = table
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        scroll.addSubview(overlay, positioned: .above, relativeTo: scroll.contentView)
        let center = NotificationCenter.default
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        center.addObserver(self, selector: #selector(startScroll), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        center.addObserver(self, selector: #selector(endScroll), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            self?.handle(event)
            return event
        }
        update()
    }

    func clearSelection() {
        selectedID = nil
        anchor = nil
        state = TorrentFocusState()
        update()
    }

    func select(anchor: NSView, id: String) {
        self.anchor = anchor
        if selectedID != id { selectedID = id; state.select() }
        update()
    }

    func detach() {
        scrollSettlementTask?.cancel()
        scrollSettlementTask = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        overlay.removeFromSuperview()
        table = nil
        lastGeometry = .null
    }

    private func handle(_ event: NSEvent) {
        guard let table, event.window === table.window, let clip = table.enclosingScrollView?.contentView,
              clip.bounds.contains(clip.convert(event.locationInWindow, from: nil)) else { return }
        if event.type == .scrollWheel {
            state.liveScroll(true)
            update()
            // Traditional wheels do not always send live-scroll end notices.
            // One cancellable settle task per gesture, never a rendering timer.
            scrollSettlementTask?.cancel()
            scrollSettlementTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                guard let self else { return }
                self.state.liveScroll(false)
                self.update()
            }
        } else {
            let clickedRow = table.row(at: table.convert(event.locationInWindow, from: nil))
            // Run after List updates its selection, including clicks on an already selected row.
            DispatchQueue.main.async { [weak self] in
                guard let self, let anchor = self.anchor, clickedRow >= 0,
                      table.row(for: anchor) == clickedRow else { return }
                self.state.select()
                self.update()
            }
        }
    }

    @objc private func startScroll() { state.liveScroll(true); update() }
    @objc private func endScroll() {
        scrollSettlementTask?.cancel()
        scrollSettlementTask = nil
        state.liveScroll(false)
        update()
    }
    @objc private func boundsChanged() { update() }
    @objc private func accessibilityChanged() { lastGeometry = .null; update() }

    private func update() {
        guard let table, let clip = table.enclosingScrollView?.contentView else { return }
        overlay.frame = clip.frame
        var focusRect = CGRect.null
        if let anchor, anchor.window != nil {
            let row = table.row(for: anchor)
            if row >= 0 { focusRect = overlay.convert(table.rect(ofRow: row), from: table) }
        }
        let visible = !focusRect.isNull && overlay.bounds.intersects(focusRect)
        state.visibility(visible)
        if visible && (state.showsFocus || settings.tuning) && (lastGeometry != focusRect || overlay.maskSize != overlay.bounds.size) {
            overlay.updateMask(focusRect: focusRect)
            lastGeometry = focusRect
        }
        overlay.setFocused(state.showsFocus || (settings.tuning && visible), strength: settings.strength)
    }
}

/// Native within-window backdrops. No snapshots, duplicate rows, or frame timers.
@MainActor
private final class FocusOverlay: NSView {
    private let above = FocusBand(above: true)
    private let below = FocusBand(above: false)
    private var focused = false
    var settings = TorrentFocusSettings()
    var onGapChange: ((Bool, Double) -> Void)?
    private let upperHandle = FocusHandle(above: true)
    private let lowerHandle = FocusHandle(above: false)
    private var focusRect = CGRect.null
    private(set) var maskSize = CGSize.zero
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard settings.tuning else { return nil }
        let local = convert(point, from: superview)
        if upperHandle.frame.contains(local) { return upperHandle }
        if lowerHandle.frame.contains(local) { return lowerHandle }
        return nil
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.opacity = 0
        addSubview(above)
        addSubview(below)
        addSubview(upperHandle)
        addSubview(lowerHandle)
        upperHandle.changed = { [weak self] y in self?.moveHandle(above: true, y: y) }
        lowerHandle.changed = { [weak self] y in self?.moveHandle(above: false, y: y) }
    }

    private func moveHandle(above: Bool, y: CGFloat) {
        let gap = above ? focusRect.minY - 2 - y : y - focusRect.maxY - 2
        onGapChange?(above, min(max(Double(gap), 0), 240))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateMask(focusRect: CGRect) {
        maskSize = bounds.size
        self.focusRect = focusRect
        // Keep the entire selected row physically outside either backdrop's
        // bounds. Native material tint can never spill across the focused row.
        let regions = TorrentFocusRegions(viewport: bounds.size, selectedRow: focusRect, aboveGap: settings.aboveGap, belowGap: settings.belowGap)
        above.frame = regions.above
        below.frame = regions.below
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        above.layer?.opacity = settings.tuning ? Float(settings.strength) : 1
        below.layer?.opacity = settings.tuning ? Float(settings.strength) : 1
        CATransaction.commit()
        above.updateMask(feather: settings.feather)
        below.updateMask(feather: settings.feather)
        upperHandle.isHidden = !settings.tuning
        lowerHandle.isHidden = !settings.tuning
        upperHandle.frame = CGRect(x: 18, y: max(0, regions.above.maxY - 11), width: 120, height: 22)
        lowerHandle.frame = CGRect(x: 18, y: min(bounds.height - 22, regions.below.minY - 11), width: 120, height: 22)
    }

    func setFocused(_ value: Bool, strength: Double) {
        let target: Float = value ? (settings.tuning ? 1 : Float(min(max(strength, 0), 1))) : 0
        guard let layer, focused != value || layer.opacity != target else { return }
        focused = value
        let start = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = target
        CATransaction.commit()
        layer.removeAnimation(forKey: "focus")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            isHidden = !value
            return
        }
        isHidden = false
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = (0...120).map { index -> Float in
            let t = Float(index) / 120
            return start + (target - start) * t * t * (3 - 2 * t)
        }
        animation.duration = value ? 0.25 : 0.30
        animation.calculationMode = .linear
        animation.delegate = self
        layer.add(animation, forKey: "focus")
    }
}

extension FocusOverlay: @MainActor CAAnimationDelegate {
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        if flag && !focused { isHidden = true }
    }
}

/// A one-dimensional feather, stretching across the list without softening the
/// selected row's left/right edges. Two bounded native backdrops, no row copies.
@MainActor
private final class FocusBand: NSView {
    private let blur = NSVisualEffectView()
    private let shade = CALayer()
    private let above: Bool
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(above: Bool) {
        self.above = above
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        blur.blendingMode = .withinWindow
        blur.material = .hudWindow
        blur.state = .active
        addSubview(blur)
        shade.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        layer?.addSublayer(shade)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateMask(feather: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        blur.frame = bounds
        shade.frame = bounds
        blur.isHidden = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        guard bounds.height > 0 else { isHidden = true; return }
        isHidden = false
        let height = max(2, Int(bounds.height / 2))
        var pixels = [UInt8](repeating: 0, count: height * 4)
        for y in 0..<height {
            let position = (CGFloat(y) + 0.5) * bounds.height / CGFloat(height)
            let distance = above ? bounds.height - position : position
            let t = min(distance / max(feather, 1), 1)
            pixels[y * 4 + 3] = UInt8((t * t * (3 - 2 * t) * 255).rounded())
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let alpha = CGImage(width: 1, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        let mask = CALayer()
        mask.frame = bounds
        mask.contents = alpha
        mask.contentsGravity = .resize
        layer?.mask = mask
        // The parent mask feathers both native material and the vignette.
        // The blur views' actual frames already exclude the selected row.
    }
}

@MainActor
private final class FocusHandle: NSView {
    private let above: Bool
    var changed: ((CGFloat) -> Void)?
    init(above: Bool) {
        self.above = above
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel(above ? "Upper blur position" : "Lower blur position")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 9, yRadius: 9).fill()
        let text = above ? "↕  Upper blur" : "↕  Lower blur"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) { drag(event) }
    override func mouseDragged(with event: NSEvent) { drag(event) }
    private func drag(_ event: NSEvent) {
        guard let superview else { return }
        changed?(superview.convert(event.locationInWindow, from: nil).y)
    }
}

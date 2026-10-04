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
    var hdrWhite = 0.0
    var hdrSoftness = 0.0
    var hdrSpread = 0.0
    var isDark = false
    var highlightColorLight = "FFFFFF"
    var highlightColorDark = "1F1F1F"
    var increasedContrast = false
    var highlightWidth = 0.0
}

struct TorrentCardGeometry: Equatable {
    var leading: CGFloat
    var trailing: CGFloat
    var separatorInset: CGFloat
}

/// Draw the shadow above the table's row clipping, while SwiftUI draws the card
/// behind its content. Native selection, virtualization and hit testing stay intact.
struct TorrentListElevationAnchor: NSViewRepresentable {
    let controller: TorrentListElevationController
    let rowID: String
    let selected: Bool
    let separatorLeadingInset: CGFloat
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.controller = controller
        view.rowID = rowID
        view.selected = selected
        view.separatorLeadingInset = separatorLeadingInset
        view.connect()
    }
    final class Anchor: NSView {
        weak var controller: TorrentListElevationController?
        var selected = false
        var rowID = ""
        var separatorLeadingInset: CGFloat = 62
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
                    controller?.register(self)
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
    private let separators = SelectionSeparatorCanvas()
    private let surface = SelectionSurfaceHost(rootView: SelectionSurface(settings: TorrentShadowSettings(), entrance: 0, motion: 0))
    private var surfaceVisible = false
    private var entrance = 0
    private var motion = 0
    private var selectedID: String?
    private var selectedAnchorID: String?
    private let anchors = NSMapTable<NSString, TorrentListElevationAnchor.Anchor>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    private var settings = TorrentShadowSettings()
    private var cardGeometry: TorrentCardGeometry?
    private var swipingID: String?
    func configureGeometry(_ geometry: TorrentCardGeometry) {
        cardGeometry = geometry
        update(animated: false)
    }
    func setSwiping(_ id: String?) { swipingID = id; scheduleRefresh() }
    private var rowIDs: [String?] = []
    private var refreshTask: Task<Void, Never>?
    private var lastSurfaceSettings: TorrentShadowSettings?
    private var separatorGeometry: (x: CGFloat, width: CGFloat, inset: CGFloat)?
    func setRows(_ ids: [String?]) {
        rowIDs = ids
        scheduleRefresh()
    }
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            self.update(animated: false)
        }
    }
    private var movementViews: [NSView] = []
    func configure(_ settings: TorrentShadowSettings) {
        self.settings = settings
        update(animated: false)
    }

    private var tableAttached: ((NSTableView) -> Void)?
    func observeTable(_ callback: @escaping (NSTableView) -> Void) {
        tableAttached = callback
        if let table { callback(table) }
    }

    func attach(_ table: NSTableView) {
        guard self.table !== table, let scroll = table.enclosingScrollView else { return }
        detach()
        self.table = table
        tableAttached?(table)
        table.floatsGroupRows = false
        table.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(rowGeometryChanged), name: NSView.frameDidChangeNotification, object: table)
        table.addSubview(separators, positioned: .below, relativeTo: nil)
        table.addSubview(surface, positioned: .above, relativeTo: separators)
        scroll.addSubview(overlay, positioned: .above, relativeTo: scroll.contentView)
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.frameDidChangeNotification, object: scroll.contentView)
    }
    func select(_ anchor: NSView) {
        let id = (anchor as? TorrentListElevationAnchor.Anchor)?.rowID
        let changed = selectedAnchorID != id
        let anchorChanged = selectedAnchor !== anchor
        selectedAnchor = anchor
        selectedAnchorID = id
        if changed || anchorChanged {
            for view in movementViews { NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: view); NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: view) }
            movementViews.removeAll()
            var ancestor: NSView? = anchor
            while let view = ancestor, view !== table {
                view.postsFrameChangedNotifications = true
                view.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(rowGeometryChanged), name: NSView.frameDidChangeNotification, object: view)
                NotificationCenter.default.addObserver(self, selector: #selector(rowGeometryChanged), name: NSView.boundsDidChangeNotification, object: view)
                movementViews.append(view)
                ancestor = view.superview
            }
        }
        update(animated: changed)
    }
    func register(_ anchor: TorrentListElevationAnchor.Anchor) {
        for key in anchors.keyEnumerator().allObjects as? [NSString] ?? [] {
            if anchors.object(forKey: key) === anchor, key as String != anchor.rowID {
                anchors.removeObject(forKey: key)
            }
        }
        anchors.setObject(anchor, forKey: anchor.rowID as NSString)
        scheduleRefresh()
        guard anchor.rowID == selectedID else { return }
        if selectedAnchor !== anchor || selectedAnchorID != anchor.rowID { select(anchor) }
    }
    func setSelection(_ id: String?) {
        selectedID = id
        guard let id else { clear(); return }
        if let anchor = anchors.object(forKey: id as NSString), anchor.rowID == id, anchor.window != nil {
            select(anchor)
        } else {
            selectedAnchor = nil
            selectedAnchorID = nil
            update(animated: true)
        }
    }
    func clear() { selectedAnchor = nil; selectedAnchorID = nil; update(animated: true) }
    func detach() {
        refreshTask?.cancel()
        refreshTask = nil
        separatorGeometry = nil
        lastSurfaceSettings = nil
        NotificationCenter.default.removeObserver(self)
        movementViews.removeAll()
        overlay.removeFromSuperview()
        surface.removeFromSuperview()
        separators.removeFromSuperview()
        surfaceVisible = false
        table = nil
        selectedAnchor = nil
        selectedAnchorID = nil
        anchors.removeAllObjects()
    }
    @objc private func rowGeometryChanged() { scheduleRefresh() }
    @objc private func scrolled() {
        surface.layer?.removeAnimation(forKey: "glide")
        overlay.cancelMotion()
        update(animated: false)
    }
    static func resizedHighlight(_ rect: CGRect, adjustment: Double) -> CGRect {
        let width = max(1, rect.width + adjustment)
        return CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
    }
    private func update(animated: Bool) {
        guard let table, let clip = table.enclosingScrollView?.contentView else { return }
        if overlay.frame != clip.frame { overlay.frame = clip.frame }
        guard let selectedID, table.numberOfRows == rowIDs.count,
              let rowIndex = rowIDs.firstIndex(where: { $0 == selectedID }) else {
            surface.layer?.removeAnimation(forKey: "glide")
            surface.layer?.removeAnimation(forKey: "appear")
            surface.layer?.opacity = 0
            surfaceVisible = false
            updateSeparators(highlightID: nil)
            overlay.show(nil, settings: settings, animated: animated)
            return
        }
        // Selection is an identity, not the last frame reported by a recycled
        // SwiftUI host. Native row bounds also keep expansion and resizing in sync.
        let nativeRow = table.rect(ofRow: rowIndex)
        guard !nativeRow.isEmpty else { return }
        var surfaceRect = nativeRow.insetBy(dx: 0, dy: 3)
        if let geometry = cardGeometry {
            surfaceRect.origin.x = geometry.leading
            surfaceRect.size.width = max(0, table.bounds.width - geometry.leading - geometry.trailing)
        }
        // Swiping moves the foreground horizontally, while row placement stays native.
        if swipingID == selectedID,
           let anchor = anchors.object(forKey: selectedID as NSString),
           anchor.rowID == selectedID, anchor.window === table.window {
            let anchorRect = table.convert(anchor.bounds, from: anchor)
            surfaceRect.origin.x = anchorRect.minX
        }
        surfaceRect = Self.resizedHighlight(surfaceRect, adjustment: settings.highlightWidth)
        let rect = overlay.convert(surfaceRect, from: table)
        let visible = rect.intersects(overlay.bounds)
        let previous = surface.layer?.presentation()?.frame ?? surface.frame
        let previousOpacity = surface.layer?.presentation()?.opacity ?? surface.layer?.opacity ?? 0
        let wasVisible = surfaceVisible && previous.intersects(table.visibleRect) && previousOpacity > 0.01
        let previousPosition = surface.layer?.presentation()?.position ?? surface.layer?.position
        let geometryChanged = surface.frame != surfaceRect
        let settingsChanged = lastSurfaceSettings != settings
        let continueGlide = geometryChanged && surface.layer?.animation(forKey: "glide") != nil
        let animateMovement = animated || continueGlide
        updateSeparators(highlightID: visible ? selectedID : nil)
        // A layout pass at the destination must not reset an in-flight glide.
        if !geometryChanged && !settingsChanged && visible == surfaceVisible { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if geometryChanged { surface.frame = surfaceRect }
        surface.layer?.opacity = visible ? 1 : 0
        if visible && !wasVisible { entrance &+= 1 }
        if visible && animated && wasVisible && previous != surfaceRect { motion &+= 1 }
        if settingsChanged || !wasVisible || (animated && geometryChanged) {
            surface.rootView = SelectionSurface(settings: settings, entrance: entrance, motion: motion)
        }
        lastSurfaceSettings = settings
        CATransaction.commit()
        if visible, animateMovement, wasVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            surface.layer?.removeAnimation(forKey: "appear")
            animateFrame(surface.layer, from: previous, fromPosition: previousPosition, to: surfaceRect, duration: settings.easeIn)
        } else if visible, !wasVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            surface.layer?.removeAnimation(forKey: "glide")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = settings.easeIn
            fade.timingFunction = CAMediaTimingFunction(controlPoints: 1.0 / 3, 0, 2.0 / 3, 1)
            surface.layer?.add(fade, forKey: "appear")
        }
        surfaceVisible = visible
        overlay.show(rect, settings: settings, animated: animateMovement)
    }

    private func updateSeparators(highlightID: String?) {
        guard let table, table.numberOfRows == rowIDs.count else { return }
        // Row identities and neighbors come from the list snapshot, never the
        // order in which virtualized SwiftUI anchors happen to register.
        if let geometry = cardGeometry {
            separatorGeometry = (geometry.leading, max(0, table.bounds.width - geometry.leading - geometry.trailing), geometry.separatorInset)
        } else {
            for anchor in anchors.objectEnumerator()?.allObjects as? [TorrentListElevationAnchor.Anchor] ?? [] {
                guard anchor.window === table.window else { continue }
                let rect = table.convert(anchor.bounds, from: anchor)
                let index = table.row(at: CGPoint(x: rect.midX, y: rect.midY))
                guard rowIDs.indices.contains(index), rowIDs[index] == anchor.rowID else { continue }
                separatorGeometry = (rect.minX, rect.width, anchor.separatorLeadingInset)
                break
            }
        }
        guard let geometry = separatorGeometry else { return }
        separators.frame = table.bounds
        let rows = rowIDs.enumerated().compactMap { index, id -> SelectionSeparatorCanvas.Row? in
            guard let id else { return nil }
            let nativeRect = table.rect(ofRow: index)
            guard nativeRect.intersects(table.visibleRect.insetBy(dx: 0, dy: -60)) else { return nil }
            let nextID = index + 1 < rowIDs.count ? rowIDs[index + 1] : nil
            let rect = CGRect(x: geometry.x, y: nativeRect.minY + 3,
                              width: geometry.width, height: max(0, nativeRect.height - 6))
            return SelectionSeparatorCanvas.Row(id: id, rect: rect, leadingInset: geometry.inset, nextID: nextID)
        }
        separators.update(rows, selectedID: highlightID, settings: settings)
    }

    private func animateFrame(_ layer: CALayer?, from: CGRect, fromPosition: CGPoint?, to: CGRect, duration: Double) {
        guard let layer, duration > 0 else { layer?.removeAnimation(forKey: "glide"); return }
        let position = CABasicAnimation(keyPath: "position")
        let target = layer.position
        position.fromValue = NSValue(point: fromPosition ?? CGPoint(
            x: target.x + from.minX - to.minX + (from.width - to.width) * layer.anchorPoint.x,
            y: target.y + from.minY - to.minY + (from.height - to.height) * layer.anchorPoint.y
        ))
        position.toValue = NSValue(point: target)
        let size = CABasicAnimation(keyPath: "bounds.size")
        size.fromValue = NSValue(size: from.size)
        size.toValue = NSValue(size: to.size)
        let group = CAAnimationGroup()
        group.animations = [position, size]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(controlPoints: 1.0 / 3, 0, 2.0 / 3, 1)
        layer.add(group, forKey: "glide")
    }
}

@MainActor
private final class SelectionSurfaceHost: NSHostingView<SelectionSurface> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct SelectionSurface: View {
    let settings: TorrentShadowSettings
    let entrance: Int
    let motion: Int
    var body: some View {
        SelectionSurfaceContent(settings: settings, motion: motion).id(entrance)
    }
}

private struct SelectionSurfaceContent: View {
    let settings: TorrentShadowSettings
    let motion: Int
    @State private var entranceBlur = 12.0
    @Environment(\.colorScheme) private var colorScheme
    private var highlightColor: NSColor { HeaderFadeColor.decode(colorScheme == .dark ? settings.highlightColorDark : settings.highlightColorLight) }
    private var white: Color {
        let rgb = highlightColor.usingColorSpace(.sRGB) ?? .white
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let boost = min(max(settings.hdrWhite, 0), 3)
        let red = linear(rgb.redComponent) + boost
        let green = linear(rgb.greenComponent) + boost
        let blue = linear(rgb.blueComponent) + boost
        return Color(.sRGBLinear, red: red, green: green, blue: blue)
            .headroom(max(1, red, green, blue))
    }
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .circular)
            .fill(Color(nsColor: highlightColor))
            .overlay {
                if settings.hdrWhite > 0 {
                    RoundedRectangle(cornerRadius: 12, style: .circular)
                        .fill(white)
                        .padding(-settings.hdrSpread)
                        .drawingGroup(opaque: false, colorMode: .extendedLinear)
                        .blur(radius: max(settings.hdrSoftness, 2))
                }
            }
            .allowedDynamicRange(.high)
            .overlay {
                if settings.increasedContrast {
                    RoundedRectangle(cornerRadius: 12, style: .circular)
                        .strokeBorder(colorScheme == .dark ? .white.opacity(0.45) : .black.opacity(0.35), lineWidth: 1)
                }
            }
            .blur(radius: entranceBlur)
            .keyframeAnimator(initialValue: 0.0, trigger: motion) { content, blur in
                content.blur(radius: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : blur)
            } keyframes: { _ in
                CubicKeyframe(4, duration: max(settings.easeIn / 2, 0.001))
                CubicKeyframe(0, duration: max(settings.easeIn / 2, 0.001))
            }
            .onAppear {
                withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil :
                    .timingCurve(1.0 / 3, 0, 2.0 / 3, 1, duration: settings.easeIn)) {
                    entranceBlur = 0
                }
            }
    }
}

@MainActor
private final class ElevationOverlay: NSView {
    private let top = CALayer()
    private let bottom = CALayer()
    private var displayedRect: CGRect?
    private var departing: CALayer?
    private var displayedSettings: TorrentShadowSettings?
    func cancelMotion() {
        top.removeAllAnimations()
        bottom.removeAllAnimations()
        (layer?.mask as? CAShapeLayer)?.removeAllAnimations()
    }
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
        if rect == displayedRect && displayedSettings == settings { return }
        displayedSettings = settings
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
        let moving = animated && displayedRect?.intersects(bounds) == true && displayedRect != rect && layer.opacity > 0
        let oldFrames = [top, bottom].map { $0.presentation()?.frame ?? $0.frame }
        let oldPaths = [top, bottom].map { $0.presentation()?.shadowPath ?? $0.shadowPath }
        let oldMaskPath = (layer.mask?.presentation() as? CAShapeLayer)?.path ?? (layer.mask as? CAShapeLayer)?.path
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
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.frame = bounds
        mask.path = path
        mask.fillRule = .evenOdd
        layer.mask = mask
        if moving && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for (index, shadow) in [top, bottom].enumerated() {
                shadow.removeAnimation(forKey: "shadowOpacity")
                shadow.removeAnimation(forKey: "shadowRadius")
                let position = CABasicAnimation(keyPath: "position")
                position.fromValue = NSValue(point: CGPoint(x: oldFrames[index].midX, y: oldFrames[index].midY))
                position.toValue = NSValue(point: shadow.position)
                let size = CABasicAnimation(keyPath: "bounds.size")
                size.fromValue = NSValue(size: oldFrames[index].size)
                size.toValue = NSValue(size: shadow.bounds.size)
                let shape = CABasicAnimation(keyPath: "shadowPath")
                shape.fromValue = oldPaths[index]
                shape.toValue = shadow.shadowPath
                let glide = CAAnimationGroup()
                glide.animations = [position, size, shape]
                glide.duration = settings.easeIn
                glide.timingFunction = CAMediaTimingFunction(controlPoints: 1.0 / 3, 0, 2.0 / 3, 1)
                shadow.add(glide, forKey: "glide")
            }
            let cutout = CABasicAnimation(keyPath: "path")
            cutout.fromValue = oldMaskPath
            cutout.toValue = mask.path
            cutout.duration = settings.easeIn
            cutout.timingFunction = CAMediaTimingFunction(controlPoints: 1.0 / 3, 0, 2.0 / 3, 1)
            mask.add(cutout, forKey: "glide")
        } else if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
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

@MainActor
private final class SelectionSeparatorCanvas: NSView {
    struct Row {
        let id: String
        let rect: CGRect
        let leadingInset: CGFloat
        let nextID: String?
    }
    private var lines: [String: CALayer] = [:]
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ rows: [Row], selectedID: String?, settings: TorrentShadowSettings) {
        let ids = Set(rows.map(\.id))
        for id in Array(lines.keys) where !ids.contains(id) {
            lines.removeValue(forKey: id)?.removeFromSuperlayer()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for row in rows {
            let isNew = lines[row.id] == nil
            let line = lines[row.id] ?? CALayer()
            if isNew { layer?.addSublayer(line); lines[row.id] = line }
            let y = row.rect.maxY + 3
            let touchesHighlight = selectedID != nil && (row.id == selectedID || row.nextID == selectedID)
            let opacity: Float = row.nextID != nil && !touchesHighlight ? 1 : 0
            let previous = line.presentation()?.opacity ?? line.opacity
            let changed = !isNew && line.opacity != opacity
            line.frame = CGRect(x: row.rect.minX + row.leadingInset, y: y,
                                width: max(0, row.rect.width - row.leadingInset - 14), height: 0.5)
            line.backgroundColor = (settings.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.12).cgColor
            line.opacity = opacity
            if changed && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = previous
                fade.toValue = opacity
                fade.duration = opacity == 0 ? settings.easeIn : settings.easeOut
                fade.timingFunction = CAMediaTimingFunction(controlPoints: 1.0 / 3, 0, 2.0 / 3, 1)
                line.add(fade, forKey: "selection")
            }
        }
    }
}

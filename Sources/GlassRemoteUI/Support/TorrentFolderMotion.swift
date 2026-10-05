import AppKit
import Observation
import SwiftUI

/// Live folder views move in the scroll overlay, independently of native row layout.
@MainActor @Observable
final class TorrentFolderMotion {
    private(set) var flyingIDs = Set<String>()
    @ObservationIgnored private weak var table: NSTableView?
    @ObservationIgnored private let overlay = FolderFlightOverlay()
    @ObservationIgnored private var layers: [String: CALayer] = [:]
    @ObservationIgnored private var views: [String: FolderFlightView] = [:]
    @ObservationIgnored private var icons: [String: FolderFlightView] = [:]
    @ObservationIgnored private let containers = NSMapTable<NSString, TorrentFolderIconContainer>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    @ObservationIgnored private var members: [String] = []
    @ObservationIgnored private var groupID = ""
    @ObservationIgnored private var expanding = false
    @ObservationIgnored private var inset: CGFloat = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var completion: Task<Void, Never>?
    @ObservationIgnored private var scrollObserver: NSObjectProtocol?
    @ObservationIgnored private var poses: [String: TorrentIconPose] = [:]
    @ObservationIgnored private let anchors = NSMapTable<NSString, TorrentFolderLandingAnchor.Anchor>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    @ObservationIgnored private var scrollOrigin = CGPoint.zero
    func register(_ container: TorrentFolderIconContainer) {
        guard !container.id.isEmpty, container.window != nil else { return }
        containers.setObject(container, forKey: container.id as NSString)
        place(container)
    }

    func unregister(_ container: TorrentFolderIconContainer) {
        guard containers.object(forKey: container.id as NSString) === container else { return }
        containers.removeObject(forKey: container.id as NSString)
        guard views[container.id] == nil else { return }
        icons.removeValue(forKey: container.id)?.removeFromSuperview()
    }

    func place(_ container: TorrentFolderIconContainer) {
        guard views[container.id] == nil, container.window != nil,
              containers.object(forKey: container.id as NSString) === container else { return }
        let icon = artwork(for: container.id)
        for child in container.subviews where child !== icon { child.removeFromSuperview() }
        if icon.superview !== container { container.addSubview(icon) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        icon.setFrameOrigin(CGPoint(x: container.bounds.midX - 18, y: container.bounds.midY - 18))
        icon.layer?.sublayerTransform = Self.transform(scale: container.size / 36)
        icon.pose.rotation = container.rotation
        icon.isHidden = false; icon.alphaValue = 1
        CATransaction.commit()
    }

    private func artwork(for id: String) -> FolderFlightView {
        if let icon = icons[id] { return icon }
        let icon = FolderFlightView()
        icon.identifier = NSUserInterfaceItemIdentifier(id)
        icons[id] = icon
        return icon
    }

    func register(_ anchor: TorrentFolderLandingAnchor.Anchor) {
        anchors.setObject(anchor, forKey: anchor.id as NSString)
    }

    func attach(_ table: NSTableView) {
        guard self.table !== table, let scroll = table.enclosingScrollView else { return }
        if self.table != nil { detach() }
        self.table = table
        scrollOrigin = scroll.contentView.bounds.origin
        overlay.frame = scroll.contentView.frame
        scroll.addSubview(overlay, positioned: .above, relativeTo: scroll.contentView)
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let clip = self.table?.enclosingScrollView?.contentView else { return }
                    let origin = clip.bounds.origin
                    guard origin != self.scrollOrigin else { return }
                    self.scrollOrigin = origin
                    self.cancel()
                }
            }
    }

    func prepare(groupID: String, members: [String], expanding: Bool, inset: CGFloat,
                 indices: [String: Int], reduceMotion: Bool) {
        let interrupted = Dictionary(uniqueKeysWithValues: layers.map { id, model in
            let layer = model.presentation() ?? model
            return (id, (CGPoint(x: layer.position.x + 18, y: layer.position.y + 18),
                layer.sublayerTransform.m11, views[id]?.pose.rotation ?? 0, layer.opacity))
        })
        cancel()
        guard !reduceMotion, let table, let scroll = table.enclosingScrollView else { return }
        overlay.frame = scroll.contentView.frame
        self.groupID = groupID; self.members = members
        self.expanding = expanding; self.inset = inset
        poses = Dictionary(uniqueKeysWithValues: ([groupID] + self.members).map { ($0, TorrentIconPose.forRole($0 == groupID ? .fan : .folder)) })
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (slot, id) in self.members.enumerated() {
            let sourceID = expanding ? groupID : id
            guard let row = indices[sourceID], row < table.numberOfRows else { continue }
            let sourceFrame = table.rect(ofRow: row)
            let landingFrame = sourceFrame.offsetBy(dx: 0, dy: CGFloat(slot + 1) * (table.rowHeight + table.intercellSpacing.height))
            let visible = expanding
                ? (slot < 3 && sourceFrame.intersects(table.visibleRect)) || landingFrame.intersects(table.visibleRect)
                : sourceFrame.intersects(table.visibleRect)
            guard visible else { continue }
            let source = endpoint(row: row, slot: slot, fan: expanding, id: sourceID)
            // Move the same hosting view out of its row/fan container. There
            // is no second material and no bitmap replacement during flight.
            let view = artwork(for: id)
            views[id] = view
            overlay.addSubview(view)
            view.layoutSubtreeIfNeeded()
            guard let layer = view.layer else { view.removeFromSuperview(); views[id] = nil; continue }
            layer.name = id
            layer.contentsScale = table.window?.backingScaleFactor ?? 2
            let center = interrupted[id]?.0 ?? source.center
            view.setFrameOrigin(CGPoint(x: center.x - 18, y: center.y - 18))
            layer.sublayerTransform = Self.transform(scale: interrupted[id]?.1 ?? source.size.width / 36)
            view.pose.rotation = interrupted[id]?.2 ?? source.angle
            view.alphaValue = CGFloat(interrupted[id]?.3 ?? (expanding && slot >= 3 ? 0 : 1))
            // Extra folders emerge from behind the three visible fan leaves.
            layer.zPosition = slot < 3 ? CGFloat(100 + slot) : -CGFloat(slot)
            views[id] = view
            layers[id] = layer
        }
        CATransaction.commit()
        flyingIDs = Set(layers.keys)
    }

    func animateAfterLayout(indices: [String: Int], expectedRows: Int) {
        guard !layers.isEmpty else { return }
        let token = generation
        completion = Task { @MainActor [weak self] in
            // Let SwiftUI commit the row snapshot first. Flights use final model
            // row rectangles, never the rows' moving presentation positions.
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(8))
                guard let self, self.generation == token, !Task.isCancelled else { return }
                if self.table?.numberOfRows == expectedRows { break }
            }
            guard let self, self.generation == token, !Task.isCancelled,
                  let table = self.table, table.numberOfRows == expectedRows else {
                self?.cancel(); return
            }
            table.layoutSubtreeIfNeeded()
            for (slot, id) in self.members.enumerated() {
                guard let layer = self.layers[id], let row = indices[self.expanding ? id : self.groupID], row < table.numberOfRows else { continue }
                let target = self.endpoint(row: row, slot: slot, fan: !self.expanding, id: self.expanding ? id : self.groupID)
                self.fly(id, to: target, duration: 0.30,
                    timing: CAMediaTimingFunction(controlPoints: 1.0 / 3, 0, 2.0 / 3, 1), fromPresentation: false)
                if slot >= 3 {
                    let opacity = CABasicAnimation(keyPath: "opacity")
                    opacity.fromValue = layer.opacity
                    opacity.toValue = self.expanding ? 1 : 0
                    opacity.duration = self.expanding ? 0.16 : 0.12
                    opacity.beginTime = CACurrentMediaTime() + (self.expanding ? 0.04 + min(Double(slot - 3) * 0.015, 0.10) : 0.18)
                    opacity.fillMode = .backwards
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    self.views[id]?.alphaValue = self.expanding ? 1 : 0
                    CATransaction.commit()
                    layer.add(opacity, forKey: "folderEmergence")
                }
            }
            try? await Task.sleep(for: .milliseconds(270))
            // Native insertion can keep changing the host geometry after the
            // nominal row animation duration. Wait for a stable landing view.
            var lastTargets: [String: CGPoint] = [:]
            var stableFrames = 0
            for _ in 0..<20 {
                guard !Task.isCancelled, self.generation == token else { return }
                var targets: [String: CGPoint] = [:]
                for (slot, id) in self.members.enumerated() {
                    guard self.layers[id] != nil, let row = indices[self.expanding ? id : self.groupID] else { continue }
                    targets[id] = self.endpoint(row: row, slot: slot, fan: !self.expanding, id: self.expanding ? id : self.groupID).center
                }
                let stable = targets.count == lastTargets.count && targets.allSatisfy { id, point in
                    guard let previous = lastTargets[id] else { return false }
                    return hypot(point.x - previous.x, point.y - previous.y) < 0.1
                }
                stableFrames = stable ? stableFrames + 1 : 0
                lastTargets = targets
                if stableFrames >= 3 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled, self.generation == token else { return }
            // Native rows have now settled. Re-measure the destination and give
            // the image a gentle tail from its current presentation position.
            table.layoutSubtreeIfNeeded()
            for (slot, id) in self.members.enumerated() {
                guard self.layers[id] != nil, let row = indices[self.expanding ? id : self.groupID], row < table.numberOfRows else { continue }
                let target = self.endpoint(row: row, slot: slot, fan: !self.expanding, id: self.expanding ? id : self.groupID)
                self.fly(id, to: target, duration: 0.32,
                    timing: CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1))
            }
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, self.generation == token else { return }
            // A host can finish layout after the nominal tail. Do not hand off
            // to a different position, angle or size: settle there first.
            for _ in 0..<3 {
                var adjusted = false
                for (slot, id) in self.members.enumerated() {
                    guard let layer = self.layers[id], let row = indices[self.expanding ? id : self.groupID], row < table.numberOfRows else { continue }
                    let target = self.endpoint(row: row, slot: slot, fan: !self.expanding, id: self.expanding ? id : self.groupID)
                    let current = layer.presentation() ?? layer
                    let angle = self.views[id]?.pose.rotation ?? 0
                    let scale = hypot(current.sublayerTransform.m11, current.sublayerTransform.m12)
                    guard hypot(current.position.x + 18 - target.center.x, current.position.y + 18 - target.center.y) > 0.25
                        || abs(36 * scale - target.size.width) > 0.25 || abs(angle - target.angle) > 0.005 else { continue }
                    self.fly(id, to: target, duration: 0.16,
                        timing: CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1))
                    adjusted = true
                }
                if !adjusted { break }
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled, self.generation == token else { return }
            }
            // Reparent the original material into its landing container in
            // one transaction. No static/flight overlap or dissolve is needed.
            self.cancel()
        }
    }

    /// AppKit owns the view layer's origin/anchor point. Transform the live
    /// content around its centre instead of overriding that native geometry.
    private static func transform(scale: CGFloat) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(18, 18, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -18, -18, 0)
    }

    private func fly(_ id: String, to target: (center: CGPoint, size: CGSize, angle: Double),
                     duration: Double, timing: CAMediaTimingFunction, fromPresentation: Bool = true) {
        guard let view = views[id], let layer = layers[id] else { return }
        let current = fromPresentation ? (layer.presentation() ?? layer) : layer
        let origin = CGPoint(x: target.center.x - 18, y: target.center.y - 18)
        let transform = Self.transform(scale: target.size.width / 36)
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = current.position; position.toValue = origin
        let geometry = CABasicAnimation(keyPath: "sublayerTransform")
        geometry.fromValue = current.sublayerTransform; geometry.toValue = transform
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.setFrameOrigin(origin); layer.sublayerTransform = transform
        withAnimation(.timingCurve(fromPresentation ? 0.16 : 1.0 / 3,
            fromPresentation ? 1 : 0, fromPresentation ? 0.3 : 2.0 / 3, 1, duration: duration)) {
            view.pose.rotation = target.angle
        }
        CATransaction.commit()
        let flight = CAAnimationGroup()
        flight.animations = [position, geometry]; flight.duration = duration
        flight.timingFunction = timing
        layer.add(flight, forKey: "folderFlight")
    }

    private func endpoint(row: Int, slot: Int, fan: Bool, id: String) -> (center: CGPoint, size: CGSize, angle: Double) {
        guard let table else { return (.zero, .zero, 0) }
        let rowFrame = table.rect(ofRow: row)
        let fanCount = min(members.count, 3)
        let progress = slot >= 3 || fanCount < 2 ? 0.5 : Double(slot) / Double(fanCount - 1)
        let size: CGFloat = fan ? 27 : 36
        let angle = fan ? (-9 + 18 * progress) * .pi / 180 : 0
        // The static fan rotates around the folder's bottom, whereas a layer
        // rotates around its center. Match that transformed center exactly.
        let center: CGPoint
        if let anchor = anchors.object(forKey: id as NSString), anchor.id == id, anchor.window === table.window {
            center = anchor.convert(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: table)
        } else {
            center = CGPoint(x: inset + 18, y: rowFrame.midY)
        }
        let point = CGPoint(x: center.x + (fan ? -5 + 10 * progress + size / 2 * sin(angle) : 0),
                            y: center.y + (fan ? abs(progress - 0.5) * 2 + size / 2 * (1 - cos(angle)) : 0))
        let anchor = anchors.object(forKey: id as NSString)
        let pose = anchor?.id == id ? anchor!.pose : (poses[id] ?? TorrentIconPose())
        let dx = (point.x - center.x) * pose.scale
        let dy = (point.y - center.y) * pose.scale
        let transformed = CGPoint(x: center.x + dx * cos(pose.angle) - dy * sin(pose.angle) + pose.x,
                                  y: center.y + dx * sin(pose.angle) + dy * cos(pose.angle))
        return (overlay.convert(transformed, from: table), CGSize(width: size * pose.scale, height: size * pose.scale), angle + pose.angle)
    }

    func cancel() {
        generation += 1
        completion?.cancel(); completion = nil
        let returning = views
        views.removeAll()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (id, view) in returning {
            view.layer?.removeAllAnimations()
            if let container = containers.object(forKey: id as NSString), container.window != nil {
                place(container)
            } else {
                view.removeFromSuperview(); icons[id] = nil
            }
        }
        CATransaction.commit()
        layers.removeAll(); flyingIDs = []
    }
    func detach() {
        cancel()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        for icon in icons.values { icon.removeFromSuperview() }
        icons.removeAll(); containers.removeAllObjects()
        overlay.removeFromSuperview(); table = nil
    }
}

@MainActor @Observable final class FolderFlightPose {
    var rotation: Double = 0
}

struct FolderFlightArtwork: View {
    let pose: FolderFlightPose
    var body: some View {
        NativeGlassIcon(image: TorrentFileIconCache.icon(fileName: "", isFolder: true),
            size: 36, isFolder: true, rotation: pose.rotation)
    }
}

private final class FolderFlightView: NSView {
    let pose = FolderFlightPose()
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        let rect = NSRect(x: 0, y: 0, width: 36, height: 36)
        super.init(frame: rect)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        let host = NSHostingView(rootView: FolderFlightArtwork(pose: pose))
        host.frame = rect
        host.sizingOptions = []
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class FolderFlightOverlay: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Report the actual untransformed leading-icon layout, including native cell insets.
struct TorrentFolderLandingAnchor: NSViewRepresentable {
    let controller: TorrentFolderMotion
    let id: String
    var pose = TorrentIconPose()
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.controller = controller; view.id = id; view.pose = pose; view.connect()
    }
    final class Anchor: NSView {
        weak var controller: TorrentFolderMotion?
        var id = ""
        var pose = TorrentIconPose()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
        override func layout() { super.layout(); connect() }
        func connect() { controller?.register(self) }
    }
}

/// The row owns only a placeholder container; the controller owns the one
/// material view and moves it between this container and the flight overlay.
struct TorrentFolderGlassIcon: NSViewRepresentable {
    let controller: TorrentFolderMotion
    let id: String
    var size: CGFloat = 36
    var rotation: Double = 0
    @Environment(\.nativeGlassRotation) private var inheritedRotation
    func makeNSView(context: Context) -> TorrentFolderIconContainer { TorrentFolderIconContainer() }
    func updateNSView(_ view: TorrentFolderIconContainer, context: Context) {
        view.configure(controller: controller, id: id, size: size, rotation: rotation + inheritedRotation)
    }
    static func dismantleNSView(_ view: TorrentFolderIconContainer, coordinator: ()) {
        view.controller?.unregister(view)
    }
}

final class TorrentFolderIconContainer: NSView {
    weak var controller: TorrentFolderMotion?
    var id = ""
    var size: CGFloat = 36
    var rotation: Double = 0
    func configure(controller: TorrentFolderMotion, id: String, size: CGFloat, rotation: Double) {
        if self.id != id || self.controller !== controller { self.controller?.unregister(self) }
        self.controller = controller; self.id = id; self.size = size; self.rotation = rotation
        controller.register(self)
    }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); controller?.place(self) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { controller?.unregister(self) } else { controller?.register(self) }
    }
}

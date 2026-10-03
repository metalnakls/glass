import AppKit
import Observation

/// Folder images move in the scroll view's overlay, independently of native row layout.
@MainActor @Observable
final class TorrentFolderMotion {
    private(set) var flyingIDs = Set<String>()
    @ObservationIgnored private weak var table: NSTableView?
    @ObservationIgnored private let overlay = FolderFlightOverlay()
    @ObservationIgnored private var layers: [String: CALayer] = [:]
    @ObservationIgnored private var members: [String] = []
    @ObservationIgnored private var groupID = ""
    @ObservationIgnored private var expanding = false
    @ObservationIgnored private var inset: CGFloat = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var completion: Task<Void, Never>?
    @ObservationIgnored private var scrollObserver: NSObjectProtocol?
    @ObservationIgnored private var poses: [String: TorrentIconPose] = [:]
    @ObservationIgnored private var scrollOrigin = CGPoint.zero
    private static let image = TorrentFileIconCache.icon(fileName: "", isFolder: true).cgImage(forProposedRect: nil, context: nil, hints: nil)

    func attach(_ table: NSTableView) {
        guard self.table !== table, let scroll = table.enclosingScrollView else { return }
        detach()
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
        let interrupted = layers.mapValues { $0.presentation() ?? $0 }
            .mapValues { ($0.position, $0.bounds.size, $0.value(forKeyPath: "transform.rotation.z") as? Double ?? 0) }
        cancel()
        guard !reduceMotion, let table, let scroll = table.enclosingScrollView else { return }
        overlay.frame = scroll.contentView.frame
        self.groupID = groupID; self.members = Array(members.prefix(3))
        self.expanding = expanding; self.inset = inset
        poses = Dictionary(uniqueKeysWithValues: ([groupID] + self.members).map { ($0, TorrentIconPose.forRole($0 == groupID ? .fan : .folder)) })
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (slot, id) in self.members.enumerated() {
            let sourceID = expanding ? groupID : id
            guard let row = indices[sourceID], row < table.numberOfRows else { continue }
            let source = endpoint(row: row, slot: slot, fan: expanding, id: sourceID)
            let layer = CALayer()
            layer.contents = Self.image
            layer.contentsGravity = .resizeAspect
            let scale = poses[sourceID]?.scale ?? 1
            if scale > 1 {
                layer.shadowOpacity = 0.10
                layer.shadowRadius = 3 * scale
                layer.shadowOffset = CGSize(width: 0, height: 2 * scale)
            }
            layer.contentsScale = table.window?.backingScaleFactor ?? 2
            layer.position = interrupted[id]?.0 ?? source.center
            layer.bounds.size = interrupted[id]?.1 ?? source.size
            layer.setValue(interrupted[id]?.2 ?? source.angle, forKeyPath: "transform.rotation.z")
            overlay.layer?.addSublayer(layer)
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
                let position = CABasicAnimation(keyPath: "position")
                position.fromValue = layer.position; position.toValue = target.center
                let size = CABasicAnimation(keyPath: "bounds.size")
                size.fromValue = layer.bounds.size; size.toValue = target.size
                let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
                rotation.fromValue = layer.value(forKeyPath: "transform.rotation.z") ?? 0
                rotation.toValue = target.angle
                CATransaction.begin(); CATransaction.setDisableActions(true)
                layer.position = target.center; layer.bounds.size = target.size
                layer.setValue(target.angle, forKeyPath: "transform.rotation.z")
                CATransaction.commit()
                let flight = CAAnimationGroup()
                flight.animations = [position, size, rotation]
                flight.duration = 0.30
                flight.timingFunction = CAMediaTimingFunction(controlPoints: 1.0 / 3, 0, 2.0 / 3, 1)
                layer.add(flight, forKey: "folderFlight")
            }
            try? await Task.sleep(for: .milliseconds(270))
            guard !Task.isCancelled, self.generation == token else { return }
            // Native rows have now settled. Re-measure the destination and give
            // the image a gentle tail from its current presentation position.
            table.layoutSubtreeIfNeeded()
            for (slot, id) in self.members.enumerated() {
                guard let layer = self.layers[id], let row = indices[self.expanding ? id : self.groupID], row < table.numberOfRows else { continue }
                let target = self.endpoint(row: row, slot: slot, fan: !self.expanding, id: self.expanding ? id : self.groupID)
                let current = layer.presentation() ?? layer
                let position = CABasicAnimation(keyPath: "position")
                position.fromValue = current.position; position.toValue = target.center
                let size = CABasicAnimation(keyPath: "bounds.size")
                size.fromValue = current.bounds.size; size.toValue = target.size
                let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
                rotation.fromValue = current.value(forKeyPath: "transform.rotation.z") ?? 0
                rotation.toValue = target.angle
                CATransaction.begin(); CATransaction.setDisableActions(true)
                layer.position = target.center; layer.bounds.size = target.size
                layer.setValue(target.angle, forKeyPath: "transform.rotation.z")
                CATransaction.commit()
                let tail = CAAnimationGroup()
                tail.animations = [position, size, rotation]; tail.duration = 0.18
                tail.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                layer.add(tail, forKey: "folderFlight")
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, self.generation == token else { return }
            self.flyingIDs = []
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, self.generation == token else { return }
            self.cancel()
        }
    }

    private func endpoint(row: Int, slot: Int, fan: Bool, id: String) -> (center: CGPoint, size: CGSize, angle: Double) {
        guard let table else { return (.zero, .zero, 0) }
        let rowFrame = table.rect(ofRow: row)
        let progress = members.count > 1 ? Double(slot) / Double(members.count - 1) : 0.5
        let size: CGFloat = fan ? 27 : 36
        let angle = fan ? (-9 + 18 * progress) * .pi / 180 : 0
        // The static fan rotates around the folder's bottom, whereas a layer
        // rotates around its center. Match that transformed center exactly.
        let point = CGPoint(x: inset + 18 + (fan ? -5 + 10 * progress + size / 2 * sin(angle) : 0),
                            y: rowFrame.midY + (fan ? abs(progress - 0.5) * 2 + size / 2 * (1 - cos(angle)) : 0))
        let pose = poses[id] ?? TorrentIconPose()
        let center = CGPoint(x: inset + 18, y: rowFrame.midY)
        let dx = (point.x - center.x) * pose.scale
        let dy = (point.y - center.y) * pose.scale
        let transformed = CGPoint(x: center.x + dx * cos(pose.angle) - dy * sin(pose.angle) + pose.x,
                                  y: center.y + dx * sin(pose.angle) + dy * cos(pose.angle))
        return (overlay.convert(transformed, from: table), CGSize(width: size * pose.scale, height: size * pose.scale), angle + pose.angle)
    }

    func cancel() {
        generation += 1
        completion?.cancel(); completion = nil
        for layer in layers.values { layer.removeFromSuperlayer() }
        layers.removeAll(); flyingIDs = []
    }
    func detach() {
        cancel()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        overlay.removeFromSuperview(); table = nil
    }
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

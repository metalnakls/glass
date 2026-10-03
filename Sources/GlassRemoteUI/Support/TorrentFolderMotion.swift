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
    @ObservationIgnored private var scrollOrigin = CGPoint.zero
    private static let image = NSWorkspace.shared.icon(for: .folder).cgImage(forProposedRect: nil, context: nil, hints: nil)

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
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (slot, id) in self.members.enumerated() {
            let sourceID = expanding ? groupID : id
            guard let row = indices[sourceID], row < table.numberOfRows else { continue }
            let source = endpoint(row: row, slot: slot, fan: expanding)
            let layer = CALayer()
            layer.contents = Self.image
            layer.contentsGravity = .resizeAspect
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
                let target = self.endpoint(row: row, slot: slot, fan: !self.expanding)
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
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, self.generation == token else { return }
            self.cancel()
        }
    }

    private func endpoint(row: Int, slot: Int, fan: Bool) -> (center: CGPoint, size: CGSize, angle: Double) {
        guard let table else { return (.zero, .zero, 0) }
        let rowFrame = table.rect(ofRow: row)
        let progress = members.count > 1 ? Double(slot) / Double(members.count - 1) : 0.5
        let size: CGFloat = fan ? 27 : 36
        let angle = fan ? (-9 + 18 * progress) * .pi / 180 : 0
        // The static fan rotates around the folder's bottom, whereas a layer
        // rotates around its center. Match that transformed center exactly.
        let point = CGPoint(x: inset + 18 + (fan ? -5 + 10 * progress + size / 2 * sin(angle) : 0),
                            y: rowFrame.midY + (fan ? abs(progress - 0.5) * 2 + size / 2 * (1 - cos(angle)) : 0))
        return (overlay.convert(point, from: table), CGSize(width: size, height: size), angle)
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

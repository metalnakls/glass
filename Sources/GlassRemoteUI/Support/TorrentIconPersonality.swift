import AppKit
import SwiftUI

/// Art direction follows the object, rather than a hash of its torrent ID.
enum TorrentIconRole { case artwork, document, folder, fan }

struct TorrentIconPose {
    var scale: CGFloat = 1
    var angle: Double = 0
    var x: CGFloat = 0
    /// A shared envelope keeps every card wide enough for the tuned artwork,
    /// without changing its width as differently tilted rows are selected.
    @MainActor static var leadingOverflow: CGFloat {
        let preferences = AppearancePreferences.shared
        guard preferences.value(for: "GlassList.funMode", fallback: false) else { return 0 }
        let scale = preferences.value(for: "GlassList.funScale", fallback: 1.5)
        let angle = preferences.value(for: "GlassList.funTilt", fallback: 9.0) * 0.6 * .pi / 180
        let extent = scale * (18 * abs(cos(angle)) + 21 * abs(sin(angle)))
        return max(0, 2 * (extent - 18) + 4)
    }

    @MainActor static func forRole(_ role: TorrentIconRole, position: Int = 0) -> Self {
        let preferences = AppearancePreferences.shared
        guard preferences.value(for: "GlassList.funMode", fallback: false) else { return Self() }
        let scale = preferences.value(for: "GlassList.funScale", fallback: 1.5)
        let tilt = preferences.value(for: "GlassList.funTilt", fallback: 9.0)
        // A repeating shallow fan progresses through level, balancing both sides.
        let rhythm = [-0.8, -0.4, 0.0, 0.4, 0.8]
        let amplitude: Double = switch role {
        case .fan: 0 // The fan already has its own spread.
        case .folder: 0.75
        case .artwork: 0.65
        case .document: 0.5
        }
        let lean = rhythm[max(0, position) % rhythm.count] * amplitude
        // Spend the enlargement on the outer gutter, preserving space for names.
        let angle = lean * tilt * .pi / 180
        // All roles share an optical center, including the expanded chevron.
        let envelopeAngle = tilt * 0.6 * .pi / 180
        let rightExtent = scale * (18 * abs(cos(envelopeAngle)) + 21 * abs(sin(envelopeAngle)))
        return Self(scale: scale, angle: angle, x: min(0, 18 - rightExtent) - 4)
    }
}

struct TorrentIconPersonality: ViewModifier {
    let role: TorrentIconRole
    var position = 0
    var enabled = true
    var grid = false
    func body(content: Content) -> some View {
        let pose = enabled ? TorrentIconPose.forRole(role, position: position) : TorrentIconPose()
        content
            // Rotate native glass's outline, never its composited material.
            .environment(\.nativeGlassRotation, role == .artwork ? 0 : pose.angle)
            .scaleEffect(grid ? min(pose.scale, 1.2) : pose.scale)
            .rotationEffect(.radians(role == .artwork ? pose.angle : 0))
            .offset(x: grid ? 0 : pose.x)
    }
}

/// Only relax the native row ancestors. The scroll viewport keeps its clipping.
struct TorrentArtworkOverflow: NSViewRepresentable {
    let enabled: Bool
    var order: Int = 0
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.enabled = enabled; view.order = order; view.configure() }
    final class Anchor: NSView {
        struct SavedClip {
            weak var view: NSView?
            let clips: Bool
            let layerClips: Bool
            let z: CGFloat?
        }
        var enabled = false
        var order = 0
        private var saved: [SavedClip] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configure() }
        override func layout() { super.layout(); configure() }
        func configure() {
            guard enabled, window != nil else { restore(); return }
            var ancestor = superview
            while let view = ancestor, !(view is NSTableView), !(view is NSClipView) {
                if !saved.contains(where: { $0.view === view }) {
                    saved.append(SavedClip(view: view, clips: view.clipsToBounds, layerClips: view.layer?.masksToBounds ?? false, z: view.layer?.zPosition))
                }
                // This runs from native layout too. Rewriting the same layer
                // properties there can schedule another display/layout pass.
                if view.clipsToBounds { view.clipsToBounds = false }
                if view is NSTableRowView, !view.wantsLayer { view.wantsLayer = true }
                if let layer = view.layer {
                    if layer.masksToBounds { layer.masksToBounds = false }
                    if view is NSTableRowView, layer.zPosition != TorrentListRenderOrder.row(at: order) {
                        layer.zPosition = TorrentListRenderOrder.row(at: order)
                    }
                }
                ancestor = view.superview
            }
        }
        private func restore() {
            for item in saved { item.view?.clipsToBounds = item.clips; item.view?.layer?.masksToBounds = item.layerClips; item.view?.layer?.zPosition = item.z ?? 0 }
            saved.removeAll()
        }
        isolated deinit { restore() }
    }
}

@MainActor enum TorrentArtworkTint {
    static func color(_ image: NSImage) -> Color {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .black }
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .high
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Color(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }
}

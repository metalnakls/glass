import AppKit
import SwiftUI

/// Stable, restrained poses: repainting and scrolling never randomize the icons.
struct TorrentIconPose {
    var scale: CGFloat = 1
    var angle: Double = 0
    var x: CGFloat = 0
    @MainActor static func forIdentity(_ id: String) -> Self {
        let preferences = AppearancePreferences.shared
        guard preferences.value(for: "GlassList.funMode", fallback: false) else { return Self() }
        let seed = id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let tilt = preferences.value(for: "GlassList.funTilt", fallback: 9.0)
        return Self(scale: preferences.value(for: "GlassList.funScale", fallback: 1.5),
                    angle: (Double(seed % 201) / 100 - 1) * tilt * .pi / 180,
                    x: CGFloat(Int((seed >> 8) % 7) - 3))
    }
}

struct TorrentIconPersonality: ViewModifier {
    let id: String
    var enabled = true
    var grid = false
    func body(content: Content) -> some View {
        let pose = enabled ? TorrentIconPose.forIdentity(id) : TorrentIconPose()
        content
            .scaleEffect(grid ? min(pose.scale, 1.2) : pose.scale)
            .rotationEffect(.radians(pose.angle))
            .offset(x: pose.x)
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

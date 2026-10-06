import AppKit
import SwiftUI

/// Live glass follows Finder's rendered artwork, including its optical insets.
struct NativeGlassIcon: View {
    let image: NSImage
    var size: CGFloat = 36
    var isFolder = false
    var rotation: Double = 0
    @Environment(\.nativeGlassRotation) private var inheritedRotation
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @AppearanceStorage("GlassList.iconGlassRegular") private var regular = false
    @AppearanceStorage("GlassList.iconGlassBlur") private var blur = 0.5
    @AppearanceStorage("GlassList.iconGlassFrost") private var frost = 0.15
    @AppearanceStorage("GlassList.iconGlassOpacity") private var opacity = 1.0
    @AppearanceStorage("GlassList.iconGlassBrightness") private var brightness = 0.0
    @AppearanceStorage("GlassList.iconGlassTint") private var tint = "FFFFFF"
    @AppearanceStorage("GlassList.iconGlassTintStrength") private var tintStrength = 0.0
    @AppearanceStorage("GlassList.iconGlassHDRLight") private var hdrLight = 0.0
    @AppearanceStorage("GlassList.iconGlassHDRDark") private var hdrDark = 0.0
    @AppearanceStorage("GlassList.iconGlassHDRSoftness") private var hdrSoftness = 0.35
    @AppearanceStorage("GlassList.iconGlassHDRWidth") private var hdrWidth = 1.5

    private var material: Glass {
        (regular ? Glass.regular : Glass.clear)
            .tint(tintStrength > 0 ? Color(nsColor: HeaderFadeColor.decode(tint)).opacity(tintStrength) : nil)
    }
    private var hdr: Double { colorScheme == .dark ? hdrDark : hdrLight }

    var body: some View {
        Group {
            if let artwork = NativeIconGeometry.artwork(for: image) {
                let source = Image(decorative: artwork.image, scale: 1).resizable().scaledToFit()
                    .frame(width: size, height: size)
                    .rotationEffect(.radians(rotation + inheritedRotation))
                if reduceTransparency {
                    source.saturation(0)
                } else {
                    let silhouette = NativeIconSilhouette(unitPath: artwork.path, rotation: rotation + inheritedRotation)
                    ZStack {
                        if frost > 0 {
                            silhouette.fill(.ultraThinMaterial)
                                .blur(radius: blur * size / 36)
                                .opacity(frost)
                        }
                        silhouette.fill(.white.opacity(0.02 + brightness * 0.35))
                            .glassEffect(material, in: silhouette)
                    }
                        .frame(width: size, height: size)
                        .overlay {
                            if hdr > 0 {
                                let white = Color(.sRGBLinear, red: 1 + hdr, green: 1 + hdr, blue: 1 + hdr)
                                    .headroom(1 + hdr)
                                silhouette.stroke(LinearGradient(colors: [white, white.opacity(0.04)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: hdrWidth * size / 36)
                                    .drawingGroup(opaque: false, colorMode: .extendedLinear)
                                    .blur(radius: hdrSoftness * size / 36)
                                    .blendMode(.plusLighter)
                            }
                        }
                        // Glass optics extend past their shape. Bound them
                        // to the exact pixels of the original icon too.
                        .mask(source)
                        .opacity(opacity)
                        .allowedDynamicRange(.high)
                }
            }
        }
        // Recreate the native material when the window changes appearance;
        // retained glass render nodes must not keep the previous theme.
        .id(colorScheme)
        .frame(width: size, height: size)
        .modifier(TorrentIconShadow())
        .accessibilityHidden(true)
    }
}

struct NativeIconSilhouette: Shape {
    let unitPath: Path
    var rotation: Double = 0
    var animatableData: Double {
        get { rotation }
        set { rotation = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let turn = CGAffineTransform(translationX: 0.5, y: 0.5)
            .rotated(by: rotation).translatedBy(x: -0.5, y: -0.5)
        return unitPath.applying(turn)
            .applying(CGAffineTransform(a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.minX, ty: rect.minY))
    }
}

private struct NativeGlassRotationKey: EnvironmentKey {
    static let defaultValue: Double = 0
}

extension EnvironmentValues {
    var nativeGlassRotation: Double {
        get { self[NativeGlassRotationKey.self] }
        set { self[NativeGlassRotationKey.self] = newValue }
    }
}

@MainActor enum NativeIconGeometry {
    final class Artwork {
        let image: CGImage
        let path: Path
        init(image: CGImage, path: Path) {
            self.image = image; self.path = path
        }
    }
    private static let artworks: NSCache<NSImage, Artwork> = {
        let cache = NSCache<NSImage, Artwork>()
        cache.countLimit = 128
        return cache
    }()

    static func artwork(for image: NSImage) -> Artwork? {
        if let cached = artworks.object(forKey: image) { return cached }
        let size = 128
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let original = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let context = context(bytes.baseAddress, size: size) else { return nil }
            // NSWorkspace's CGImage representation omits semantic optical
            // insets. Draw the NSImage exactly as the ordinary icon view does.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: rect, from: .zero, operation: .copy, fraction: 1,
                respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
            return context.makeImage()
        }
        guard let original else { return nil }
        let path = outline(alpha: stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }, width: size, height: size)
        let result = Artwork(image: original, path: path)
        artworks.setObject(result, forKey: image)
        return result
    }

    /// Trace only opaque pixels so baked shadows and transparent margins do
    /// not enlarge the material. Preserve tabs and holes in the native shape.
    nonisolated static func outline(alpha: [UInt8], width: Int, height: Int) -> Path {
        guard width > 0, height > 0, alpha.count == width * height else { return Path() }
        struct Vertex: Hashable { let x: Int; let y: Int }
        var edges: [Vertex: [Vertex]] = [:]
        func filled(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < width && y >= 0 && y < height && alpha[y * width + x] >= 128
        }
        func edge(_ x: Int, _ y: Int, _ ex: Int, _ ey: Int) {
            edges[Vertex(x: x, y: y), default: []].append(Vertex(x: ex, y: ey))
        }
        for y in 0..<height {
            for x in 0..<width where filled(x, y) {
                if !filled(x, y - 1) { edge(x, y, x + 1, y) }
                if !filled(x + 1, y) { edge(x + 1, y, x + 1, y + 1) }
                if !filled(x, y + 1) { edge(x + 1, y + 1, x, y + 1) }
                if !filled(x - 1, y) { edge(x, y + 1, x, y) }
            }
        }
        var path = Path()
        while let start = edges.keys.first {
            var current = start
            path.move(to: CGPoint(x: Double(current.x) / Double(width), y: Double(current.y) / Double(height)))
            repeat {
                guard var nextEdges = edges[current], let next = nextEdges.popLast() else { break }
                if nextEdges.isEmpty { edges[current] = nil } else { edges[current] = nextEdges }
                path.addLine(to: CGPoint(x: Double(next.x) / Double(width), y: Double(next.y) / Double(height)))
                current = next
            } while current != start
            path.closeSubpath()
        }
        return path
    }

    private static func context(_ data: UnsafeMutableRawPointer?, size: Int) -> CGContext? {
        CGContext(data: data, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

/// One appearance policy for native icons in rows, groups, inspector, and flight.
struct TorrentIconShadow: ViewModifier {
    var tint: Color = .black
    @AppearanceStorage("GlassList.funMode") private var enabled = false
    @AppearanceStorage("GlassList.iconShadowStrength") private var strength = 0.12
    @AppearanceStorage("GlassList.iconShadowSoftness") private var softness = 5.0
    @AppearanceStorage("GlassList.iconShadowOffset") private var offset = 3.0
    func body(content: Content) -> some View {
        content.shadow(color: tint.opacity(enabled ? strength : 0), radius: softness, y: offset)
    }
}

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
    @AppearanceStorage("GlassList.iconGlassEnabled") private var glassEnabled = true
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
            if !glassEnabled {
                // Bypass the material, frost, HDR and silhouette work entirely.
                // Keep the same host, optical size and pose for group flights.
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: size, height: size)
                    .rotationEffect(.radians(rotation + inheritedRotation))
            } else if let artwork = NativeIconGeometry.artwork(for: image, highResolution: size > 64) {
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
                        .overlay {
                            Image(decorative: artwork.ink, scale: 1)
                                .resizable().renderingMode(.template).scaledToFit()
                                .foregroundStyle(.primary.opacity(0.68))
                                .frame(width: size, height: size)
                                .rotationEffect(.radians(rotation + inheritedRotation))
                        }
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
        let ink: CGImage
        init(image: CGImage, path: Path, ink: CGImage) {
            self.image = image; self.path = path; self.ink = ink
        }
    }
    private static let artworks: NSCache<NSImage, Artwork> = {
        let cache = NSCache<NSImage, Artwork>()
        cache.countLimit = 128
        return cache
    }()

    private static let previewArtworks: NSCache<NSImage, Artwork> = {
        let cache = NSCache<NSImage, Artwork>()
        cache.countLimit = 8
        return cache
    }()

    static func artwork(for image: NSImage, highResolution: Bool = false) -> Artwork? {
        let cache = highResolution ? previewArtworks : artworks
        if let cached = cache.object(forKey: image) { return cached }
        guard let result = rasterize(image, highResolution: highResolution) else { return nil }
        cache.setObject(result, forKey: image)
        return result
    }

    /// Also used by the Finder renderer on its own actor. The image and drawing
    /// context belong to the caller; this operation touches no shared cache/UI.
    nonisolated static func rasterize(_ image: NSImage, highResolution: Bool) -> Artwork? {
        let size = highResolution ? 512 : 128
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
        guard let ink = detailMask(pixels: pixels, size: size) else { return nil }
        return Artwork(image: original, path: path, ink: ink)
    }

    /// Extract local detail rather than treating the icon's entire shaded body
    /// as ink. Glass owns that body and its outside edge; Finder supplies the
    /// actual glyph, extension label, fold and seam. Integral sums keep this
    /// cached pass linear in the number of pixels, including large previews.
    nonisolated private static func detailMask(pixels: [UInt8], size: Int) -> CGImage? {
        let stride = size + 1
        var tones = [Double](repeating: 0, count: size * size)
        var sums = [Double](repeating: 0, count: stride * stride)
        var counts = [Int](repeating: 0, count: stride * stride)
        for y in 0..<size {
            for x in 0..<size {
                let pixel = y * size + x, offset = pixel * 4
                let alpha = Double(pixels[offset + 3]) / 255
                let opaque = alpha > 0.9
                let tone = opaque ? (0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1])
                    + 0.0722 * Double(pixels[offset + 2])) / (255 * alpha) : 0
                tones[pixel] = tone
                let index = (y + 1) * stride + x + 1
                sums[index] = tone + sums[index - 1] + sums[index - stride] - sums[index - stride - 1]
                counts[index] = (opaque ? 1 : 0) + counts[index - 1] + counts[index - stride] - counts[index - stride - 1]
            }
        }
        func box<T: Numeric>(_ values: [T], x: Int, y: Int, radius: Int) -> T {
            let left = max(0, x - radius), right = min(size, x + radius + 1)
            let top = max(0, y - radius), bottom = min(size, y + radius + 1)
            return values[bottom * stride + right] - values[top * stride + right]
                - values[bottom * stride + left] + values[top * stride + left]
        }
        let radius = max(2, size / 16)
        let border = max(1, size / 128)
        let interiorCount = (border * 2 + 1) * (border * 2 + 1)
        var ink = [UInt8](repeating: 0, count: pixels.count)
        for y in border..<(size - border) {
            for x in border..<(size - border) {
                guard box(counts, x: x, y: y, radius: border) == interiorCount else { continue }
                let count = box(counts, x: x, y: y, radius: radius)
                guard count > 0 else { continue }
                let mean = box(sums, x: x, y: y, radius: radius) / Double(count)
                let contrast = abs(tones[y * size + x] - mean)
                let coverage = min(1, max(0, (contrast - 0.06) * 5))
                let byte = UInt8((coverage * 255).rounded()), offset = (y * size + x) * 4
                ink[offset] = byte; ink[offset + 1] = byte; ink[offset + 2] = byte; ink[offset + 3] = byte
            }
        }
        return ink.withUnsafeMutableBytes { bytes in context(bytes.baseAddress, size: size)?.makeImage() }
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

    nonisolated private static func context(_ data: UnsafeMutableRawPointer?, size: Int) -> CGContext? {
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

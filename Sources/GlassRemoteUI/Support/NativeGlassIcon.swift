import AppKit
import SwiftUI

/// Live glass follows Finder's rendered artwork, including its optical insets.
struct NativeGlassIcon: View {
    let image: NSImage
    var size: CGFloat = 36
    var isFolder = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if let artwork = NativeIconGeometry.artwork(for: image) {
                let source = Image(decorative: artwork.image, scale: 1).resizable().scaledToFit()
                    .frame(width: size, height: size)
                if reduceTransparency {
                    source.saturation(0)
                } else {
                    let silhouette = NativeIconSilhouette(unitPath: artwork.path)
                    silhouette.fill(.white.opacity(0.02))
                        .frame(width: size, height: size)
                        .glassEffect(.clear, in: silhouette)
                        // Glass optics extend past their shape. Bound them
                        // to the exact pixels of the original icon too.
                        .mask(source)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct NativeIconSilhouette: Shape {
    let unitPath: Path
    func path(in rect: CGRect) -> Path {
        unitPath.applying(CGAffineTransform(a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.minX, ty: rect.minY))
    }
}

@MainActor enum NativeIconGeometry {
    final class Artwork {
        let image: CGImage
        let flightImage: CGImage
        let path: Path
        init(image: CGImage, flightImage: CGImage, path: Path) {
            self.image = image; self.flightImage = flightImage; self.path = path
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
        // Moving layers retain the same optical size and alpha as the source.
        // The material is approximated only for the brief, cached flight image.
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0 else { continue }
            let luminance = (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])) / alpha
            let value = UInt8(min(255, max(0, (luminance * 0.42 + 148) * alpha)))
            pixels[index] = value; pixels[index + 1] = value; pixels[index + 2] = value
        }
        guard let flight = pixels.withUnsafeMutableBytes({ context($0.baseAddress, size: size)?.makeImage() }) else { return nil }
        let result = Artwork(image: original, flightImage: flight, path: path)
        artworks.setObject(result, forKey: image)
        return result
    }

    static func flightImage(for image: NSImage) -> CGImage? { artwork(for: image)?.flightImage }

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

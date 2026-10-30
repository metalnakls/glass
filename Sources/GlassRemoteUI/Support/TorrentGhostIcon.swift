import AppKit
import GlassRemoteCore

/// Static companion to NativeGlassIcon for Finder, which cannot host live glass.
/// Both use Finder artwork, its optical bounds, and the same extracted details.
public actor TorrentGhostIcon {
    private static let shared = TorrentGhostIcon()
    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()

    public static func image(content: TorrentIconContent, pixelSize: Int) async -> CGImage? {
        await shared.render(content: content, pixelSize: pixelSize)
    }

    private func render(content: TorrentIconContent, pixelSize: Int) -> CGImage? {
        let size = min(512, max(16, pixelSize))
        let name: String
        let folder: Bool
        switch content {
        case .file(let fileName): name = fileName; folder = false
        case .folder: name = ""; folder = true
        case .unknown: name = ""; folder = false
        }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        let key = "\(folder ? "folder" : "file:\(ext)")@\(size)" as NSString
        if let cached = images.object(forKey: key) { return cached.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        let source = TorrentFileIconCache.makeIcon(fileName: name, isFolder: folder, pointSize: size > 64 ? 512 : 32)
        guard let artwork = NativeIconGeometry.rasterize(source, highResolution: size > 64, details: folder ? .both : .dark),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                  bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        context.saveGState()
        context.clip(to: rect, mask: artwork.image)
        context.setFillColor(CGColor(gray: 1, alpha: 0.80))
        context.fill(rect)
        context.restoreGState()
        context.saveGState()
        context.clip(to: rect, mask: artwork.ink)
        context.setFillColor(CGColor(gray: 0.50, alpha: 0.85))
        context.fill(rect)
        context.restoreGState()

        // Simplify raster stair-steps, then distribute dots evenly around the
        // whole silhouette, including the closing gap and the folded corner.
        let diameter = max(1, CGFloat(size) / 64)
        let path = artwork.path.applying(CGAffineTransform(a: CGFloat(size), b: 0,
            c: 0, d: -CGFloat(size), tx: 0, ty: CGFloat(size))).cgPath
        let dots = TorrentGhostOutline.dots(path: path, spacing: diameter * 3.4,
            tolerance: max(0.25, CGFloat(size) / 512))
        for point in dots {
            let rim = diameter * 1.5
            context.setFillColor(CGColor(gray: 1, alpha: 0.45))
            context.fillEllipse(in: CGRect(x: point.x - rim / 2, y: point.y - rim / 2, width: rim, height: rim))
            context.setFillColor(CGColor(gray: 0.5, alpha: 0.9))
            context.fillEllipse(in: CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                width: diameter, height: diameter))
        }
        guard let result = context.makeImage() else { return nil }
        images.setObject(NSImage(cgImage: result, size: rect.size), forKey: key, cost: size * size * 4)
        return result
    }
}

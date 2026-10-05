import AppKit
import SwiftUI

/// Centers the visible ink, rather than the font's baseline and side bearings.
struct FilePriorityIcon: NSViewRepresentable {
    let high: Bool

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignCenter
        view.contentTintColor = .secondaryLabelColor
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = FilePriorityGlyph.image(high: high)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        CGSize(width: 12, height: 16)
    }
}

@MainActor
enum FilePriorityGlyph {
    private static let star = render(high: true)
    private static let frown = render(high: false)

    static func image(high: Bool) -> NSImage { high ? star : frown }

    private static func render(high: Bool) -> NSImage {
        let scale = 4.0
        let pixels = 128
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: scale)
        (transform as NSAffineTransform).concat()
        if high {
            let symbol = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)!
                .withSymbolConfiguration(.init(pointSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                    weight: .regular))!
            symbol.draw(at: CGPoint(x: 8, y: 8), from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            let rotation = NSAffineTransform()
            rotation.translateX(by: 16, yBy: 16)
            rotation.rotate(byDegrees: -90)
            rotation.concat()
            NSAttributedString(string: ":(", attributes: [.font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.black]).draw(at: .zero)
        }
        NSGraphicsContext.restoreGraphicsState()
        let bounds = inkBounds(bitmap)
        let cropped = bitmap.cgImage!.cropping(to: bounds)!
        let image = NSImage(cgImage: cropped, size: CGSize(width: bounds.width / scale, height: bounds.height / scale))
        image.isTemplate = true
        return image
    }

    static func inkBounds(_ bitmap: NSBitmapImageRep) -> CGRect {
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

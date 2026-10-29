import AppKit
import SwiftUI
@testable import GlassRemoteUI
import Testing

@Suite("Native glass artwork")
struct NativeGlassIconTests {
    @MainActor @Test("the detail overlay contains the glyph, not a second shaded icon body", arguments: [false, true], [false, true])
    func detailsExcludeBodyShading(highResolution: Bool, brightGlyph: Bool) throws {
        let image = NSImage(size: .init(width: 128, height: 128), flipped: false) { rect in
            let start = brightGlyph ? NSColor(srgbRed: 1, green: 0.35, blue: 0, alpha: 1) : NSColor(white: 0.65, alpha: 1)
            let end = brightGlyph ? NSColor(srgbRed: 1, green: 0.65, blue: 0, alpha: 1) : .white
            NSGradient(starting: start, ending: end)!.draw(in: rect, angle: 0)
            NSColor(white: brightGlyph ? 1 : 0.1, alpha: 1).setStroke()
            let glyph = NSBezierPath(roundedRect: .init(x: 48, y: 48, width: 32, height: 32), xRadius: 6, yRadius: 6)
            glyph.lineWidth = 4
            glyph.stroke()
            return true
        }
        let artwork = try #require(NativeIconGeometry.artwork(for: image, highResolution: highResolution))
        let mask = NSBitmapImageRep(cgImage: artwork.ink)
        let scale = highResolution ? 4 : 1
        // These are smooth body-only areas away from the glyph and contour.
        for y in [24, 104] {
            for x in stride(from: 20, through: 108, by: 8) {
                #expect((mask.colorAt(x: x * scale, y: y * scale)?.alphaComponent ?? 1) < 0.03)
            }
        }
        #expect((mask.colorAt(x: 48 * scale, y: 64 * scale)?.alphaComponent ?? 0) > 0.5)
    }

    @MainActor private func footprint(_ image: CGImage) -> CGRect {
        let bitmap = NSBitmapImageRep(cgImage: image)
        // Clear glass can have very low alpha in an offscreen renderer.
        // Measure its outline relative to its own opacity, like the source.
        var peakAlpha: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                peakAlpha = max(peakAlpha, bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
        guard peakAlpha > 0 else { return .zero }
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= peakAlpha * 0.5 {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return .zero }
        return CGRect(x: Double(minX) / Double(bitmap.pixelsWide), y: Double(minY) / Double(bitmap.pixelsHigh),
            width: Double(maxX - minX + 1) / Double(bitmap.pixelsWide), height: Double(maxY - minY + 1) / Double(bitmap.pixelsHigh))
    }

    @Test("glass and system artwork have the same optical bounds at every tilt", arguments: [0.0, -9.0, 9.0])
    @MainActor func matchingRenderedBounds(degrees: Double) throws {
        let image = TorrentFileIconCache.icon(fileName: "", isFolder: true)
        let angle = degrees * .pi / 180
        let original = ImageRenderer(content: Image(nsImage: image).resizable().scaledToFit().frame(width: 36, height: 36).rotationEffect(.radians(angle)))
        original.scale = 2
        let originalImage = try #require(original.cgImage)
        let expected = footprint(originalImage)
        let artwork = try #require(NativeIconGeometry.artwork(for: image))
        let maskRenderer = ImageRenderer(content: Image(decorative: artwork.image, scale: 1).resizable().scaledToFit().frame(width: 36, height: 36).rotationEffect(.radians(angle)))
        maskRenderer.scale = 2
        let mask = footprint(try #require(maskRenderer.cgImage))
        // Include equality at exactly two pixels despite normalized subtraction
        // rounding (e.g. 0.02777777777777779 versus 0.027777777777777776).
        let tolerance = 2.0 / 72.0 + 1e-12
        #expect(abs(expected.minX - mask.minX) <= tolerance)
        #expect(abs(expected.minY - mask.minY) <= tolerance)
        #expect(abs(expected.width - mask.width) <= tolerance)
        #expect(abs(expected.height - mask.height) <= tolerance)
        let glass = ImageRenderer(content: NativeGlassIcon(image: image, size: 36, isFolder: true, rotation: angle))
        glass.scale = 2
        let bounds = footprint(try #require(glass.cgImage))
        #expect(abs(expected.minX - bounds.minX) <= tolerance)
        #expect(abs(expected.minY - bounds.minY) <= tolerance)
        #expect(abs(expected.width - bounds.width) <= tolerance)
        #expect(abs(expected.height - bounds.height) <= tolerance)
    }

}

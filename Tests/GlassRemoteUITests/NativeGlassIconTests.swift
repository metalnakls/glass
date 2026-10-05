import AppKit
import SwiftUI
@testable import GlassRemoteUI
import Testing

@Suite("Native glass artwork")
struct NativeGlassIconTests {
    @MainActor private func footprint(_ image: CGImage) -> CGRect {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= 0.5 {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return .zero }
        return CGRect(x: Double(minX) / Double(bitmap.pixelsWide), y: Double(minY) / Double(bitmap.pixelsHigh),
            width: Double(maxX - minX + 1) / Double(bitmap.pixelsWide), height: Double(maxY - minY + 1) / Double(bitmap.pixelsHigh))
    }

    @Test("glass and system artwork have the same rendered optical bounds")
    @MainActor func matchingRenderedBounds() throws {
        let image = TorrentFileIconCache.icon(fileName: "", isFolder: true)
        let original = ImageRenderer(content: Image(nsImage: image).resizable().scaledToFit().frame(width: 36, height: 36))
        original.scale = 2
        let originalImage = try #require(original.cgImage)
        let expected = footprint(originalImage)
        let artwork = try #require(NativeIconGeometry.artwork(for: image))
        let mask = footprint(artwork.image)
        let tolerance = 2.0 / 72.0
        #expect(abs(expected.minX - mask.minX) <= tolerance)
        #expect(abs(expected.minY - mask.minY) <= tolerance)
        #expect(abs(expected.width - mask.width) <= tolerance)
        #expect(abs(expected.height - mask.height) <= tolerance)
        let glass = ImageRenderer(content: NativeGlassIcon(image: image, size: 36, isFolder: true))
        glass.scale = 2
        let bounds = footprint(try #require(glass.cgImage))
        #expect(abs(expected.minX - bounds.minX) <= tolerance)
        #expect(abs(expected.minY - bounds.minY) <= tolerance)
        #expect(abs(expected.width - bounds.width) <= tolerance)
        #expect(abs(expected.height - bounds.height) <= tolerance)
    }

    @Test("moving and static icons preserve the exact same size and transparent margins")
    @MainActor func nativeFolder() throws {
        let image = TorrentFileIconCache.icon(fileName: "", isFolder: true)
        let artwork = try #require(NativeIconGeometry.artwork(for: image))
        #expect(artwork === NativeIconGeometry.artwork(for: image))
        #expect(artwork.flightImage === NativeIconGeometry.flightImage(for: image))
        let source = NSBitmapImageRep(cgImage: artwork.image)
        let flight = NSBitmapImageRep(cgImage: artwork.flightImage)
        #expect(source.pixelsWide == flight.pixelsWide)
        #expect(source.pixelsHigh == flight.pixelsHigh)
        var foundInk = false
        var foundMargin = false
        for y in 0..<source.pixelsHigh {
            for x in 0..<source.pixelsWide {
                let original = try #require(source.colorAt(x: x, y: y))
                let moving = try #require(flight.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                #expect(abs(original.alphaComponent - moving.alphaComponent) < 0.001)
                let point = CGPoint(x: (Double(x) + 0.5) / Double(source.pixelsWide), y: (Double(y) + 0.5) / Double(source.pixelsHigh))
                #expect(artwork.path.contains(point) == (original.alphaComponent >= 0.5))
                if moving.alphaComponent > 0.5 {
                    foundInk = true
                    #expect(abs(moving.redComponent - moving.blueComponent) < 0.01)
                } else if moving.alphaComponent == 0 { foundMargin = true }
            }
        }
        #expect(foundInk)
        #expect(foundMargin)
    }
}

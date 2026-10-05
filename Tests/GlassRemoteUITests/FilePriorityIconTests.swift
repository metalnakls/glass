import AppKit
import Testing
@testable import GlassRemoteUI

@Suite("Priority glyph alignment")
struct FilePriorityIconTests {
    @MainActor @Test("both glyphs have no invisible margins and retain their natural size", arguments: [true, false])
    func visibleBounds(high: Bool) throws {
        _ = NSApplication.shared
        let image = FilePriorityGlyph.image(high: high)
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        #expect(FilePriorityGlyph.inkBounds(bitmap) == CGRect(x: 0, y: 0,
            width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        #expect(abs(image.size.width - CGFloat(bitmap.pixelsWide) / 4) < 0.001)
        #expect(abs(image.size.height - CGFloat(bitmap.pixelsHigh) / 4) < 0.001)
        #expect(image.size.width <= 12)
        #expect(image.size.height <= 16)
    }
}

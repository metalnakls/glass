import CoreGraphics
import Testing
@testable import GlassRemoteUI

struct TorrentGhostOutlineTests {
    @Test("dot pitch includes the closing gap and ignores interior contours")
    func uniformClosedOutline() {
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: 100, height: 100))
        path.addRect(CGRect(x: 20, y: 20, width: 4, height: 4))
        let dots = TorrentGhostOutline.dots(path: path, spacing: 10, tolerance: 0.5)
        #expect(dots.count == 40)
        for i in dots.indices {
            let a = dots[i], b = dots[(i + 1) % dots.count]
            #expect(abs(hypot(a.x - b.x, a.y - b.y) - 10) < 0.001)
        }
    }

    @Test("changing the tracing start does not move the dots")
    func stableOrigin() {
        let corners: [CGPoint] = [.init(x: 0,y: 0),.init(x: 100,y: 0),.init(x: 100,y: 100),.init(x: 0,y: 100)]
        func sample(_ start: Int) -> [CGPoint] {
            let path = CGMutablePath()
            path.move(to: corners[start])
            for offset in 1..<4 { path.addLine(to: corners[(start + offset) % 4]) }
            path.closeSubpath()
            return TorrentGhostOutline.dots(path: path, spacing: 13, tolerance: 0.5)
        }
        for start in 1..<4 { #expect(sample(start) == sample(0)) }
    }
}

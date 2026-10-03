import SwiftUI

struct DropCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(28, min(rect.width, rect.height) / 4)
        var path = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1)
        ]
        for (corner, sx, sy) in corners {
            path.move(to: CGPoint(x: corner.x, y: corner.y + length * sy))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + length * sx, y: corner.y))
        }
        return path
    }
}

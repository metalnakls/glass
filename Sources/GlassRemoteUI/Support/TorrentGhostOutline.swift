import CoreGraphics

/// One deterministic outer contour, sampled by distance rather than raster steps.
enum TorrentGhostOutline {
    static func dots(path: CGPath, spacing: CGFloat, tolerance: CGFloat) -> [CGPoint] {
        var loops: [[CGPoint]] = []
        var current: [CGPoint] = []
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint:
                if !current.isEmpty { loops.append(current) }
                current = [element.pointee.points[0]]
            case .addLineToPoint: current.append(element.pointee.points[0])
            case .closeSubpath:
                if !current.isEmpty { loops.append(current); current = [] }
            default: break // The native alpha contour contains only line segments.
            }
        }
        if !current.isEmpty { loops.append(current) }
        func area(_ points: [CGPoint]) -> CGFloat {
            guard points.count > 2 else { return 0 }
            return abs(points.indices.reduce(CGFloat.zero) { result, i in
                let a = points[i], b = points[(i + 1) % points.count]
                return result + a.x * b.y - b.x * a.y
            })
        }
        guard var points = loops.max(by: { area($0) < area($1) }), points.count > 2, spacing > 0 else { return [] }
        if points.first == points.last { points.removeLast() }
        let start = points.indices.min { a, b in
            points[a].y == points[b].y ? points[a].x < points[b].x : points[a].y < points[b].y
        }!
        points = Array(points[start...]) + Array(points[..<start])
        let opposite = points.indices.max { distance(points[0], points[$0]) < distance(points[0], points[$1]) }!
        guard opposite > 0 else { return [] }
        let first = simplify(Array(points[...opposite]), tolerance: tolerance)
        let second = simplify(Array(points[opposite...]) + [points[0]], tolerance: tolerance)
        let contour = first.dropLast() + second.dropLast()
        let vertices = Array(contour)
        let lengths = vertices.indices.map { distance(vertices[$0], vertices[($0 + 1) % vertices.count]) }
        let perimeter = lengths.reduce(0, +)
        guard perimeter > 0 else { return [] }
        let count = max(3, Int((perimeter / spacing).rounded()))
        let pitch = perimeter / CGFloat(count)
        var segment = 0, consumed: CGFloat = 0
        return (0..<count).map { index in
            let target = CGFloat(index) * pitch
            while segment < lengths.count - 1 && consumed + lengths[segment] < target {
                consumed += lengths[segment]; segment += 1
            }
            let a = vertices[segment], b = vertices[(segment + 1) % vertices.count]
            let fraction = lengths[segment] > 0 ? (target - consumed) / lengths[segment] : 0
            return CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
        }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }

    private static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let a = points.first!, b = points.last!
        let dx = b.x - a.x, dy = b.y - a.y, squared = dx * dx + dy * dy
        var maximum: CGFloat = 0, split = 0
        for i in 1..<(points.count - 1) {
            let p = points[i]
            let t = squared > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / squared)) : 0
            let error = distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
            if error > maximum { maximum = error; split = i }
        }
        guard maximum > tolerance else { return [a, b] }
        return simplify(Array(points[...split]), tolerance: tolerance).dropLast()
            + simplify(Array(points[split...]), tolerance: tolerance)
    }
}

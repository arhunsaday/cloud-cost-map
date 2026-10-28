import CoreGraphics
import Foundation

/// Squarified treemap (Bruls, Huizing & van Wijk, 2000): keeps tiles close to
/// square so their areas are comparable at a glance.
public enum TreemapLayout {
    /// Rectangles for `values` (any order, non-negative) inside `rect`, in the same order.
    public static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }

        // Work largest first, then put results back in input order.
        let order = values.indices.sorted { values[$0] > values[$1] }
        let scale = Double(rect.width * rect.height) / total
        let areas = order.map { values[$0] * scale }

        var result = [CGRect](repeating: .zero, count: values.count)
        var remaining = rect
        var row: [Int] = [] // indices into `areas`
        var i = 0

        func worst(_ row: [Int], side: Double) -> Double {
            let sum = row.reduce(0) { $0 + areas[$1] }
            guard sum > 0, side > 0 else { return .infinity }
            let maxA = row.map { areas[$0] }.max()!, minA = row.map { areas[$0] }.min()!
            return max(side * side * maxA / (sum * sum), (sum * sum) / (side * side * max(minA, .ulpOfOne)))
        }

        func layoutRow(_ row: [Int]) {
            let sum = row.reduce(0) { $0 + areas[$1] }
            let horizontal = remaining.width >= remaining.height // lay the row along the short side
            if horizontal {
                let w = CGFloat(sum) / remaining.height
                var y = remaining.minY
                for j in row {
                    let h = CGFloat(areas[j]) / w
                    result[order[j]] = CGRect(x: remaining.minX, y: y, width: w, height: h)
                    y += h
                }
                remaining = CGRect(x: remaining.minX + w, y: remaining.minY, width: max(remaining.width - w, 0), height: remaining.height)
            } else {
                let h = CGFloat(sum) / remaining.width
                var x = remaining.minX
                for j in row {
                    let w = CGFloat(areas[j]) / h
                    result[order[j]] = CGRect(x: x, y: remaining.minY, width: w, height: h)
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + h, width: remaining.width, height: max(remaining.height - h, 0))
            }
        }

        while i < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worst(row + [i], side: side) <= worst(row, side: side) {
                row.append(i)
                i += 1
            } else {
                layoutRow(row)
                row = []
            }
        }
        if !row.isEmpty { layoutRow(row) }
        return result
    }

    public struct Tile: Identifiable, Sendable {
        public var id: String { node.id }
        public let node: CostNode
        public let rect: CGRect
        /// 1 for children of the root passed in, 2 for their children.
        public let depth: Int
        public let branch: Int
        public let siblingPosition: Double
    }

    /// Two-level layout: each child of `root` becomes a framed tile with a
    /// header strip, and its own children fill the rest of the frame.
    public static func tiles(for root: CostNode, in rect: CGRect, header: CGFloat = 20, padding: CGFloat = 2) -> [Tile] {
        let children = root.children.filter { $0.cost > 0 }
        let frames = squarify(children.map(\.cost), in: rect)
        var out: [Tile] = []
        for (i, (child, frame)) in zip(children, frames).enumerated() {
            let position = children.count > 1 ? Double(i) / Double(children.count - 1) : 0
            out.append(Tile(node: child, rect: frame, depth: 1, branch: i, siblingPosition: position))
            let inner = frame.insetBy(dx: padding, dy: padding)
            let showsHeader = inner.height > header * 2.2 && inner.width > 60
            let body = CGRect(x: inner.minX, y: inner.minY + (showsHeader ? header : 0),
                              width: inner.width, height: inner.height - (showsHeader ? header : 0))
            let grandchildren = child.children.filter { $0.cost > 0 }
            guard !grandchildren.isEmpty, body.width > 8, body.height > 8 else { continue }
            for (j, (g, r)) in zip(grandchildren, squarify(grandchildren.map(\.cost), in: body)).enumerated() {
                out.append(Tile(node: g, rect: r, depth: 2, branch: i,
                                siblingPosition: grandchildren.count > 1 ? Double(j) / Double(grandchildren.count - 1) : 0))
            }
        }
        return out
    }
}

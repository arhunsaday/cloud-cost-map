import Foundation

/// Partitions a tree into concentric rings. Angles are fractions of a turn
/// (0…1, clockwise from 12 o'clock) so the view decides on radians and size.
public struct SunburstLayout: Sendable {
    public struct Segment: Identifiable, Sendable, Hashable {
        public var id: String { node.id }
        public let node: CostNode
        /// 1 for the focus's children, 2 for grandchildren…
        public let depth: Int
        public let start: Double
        public let end: Double
        /// Index of the depth-1 ancestor, used to pick a hue.
        public let branch: Int
        /// Position among siblings, 0…1, used to vary lightness within a branch.
        public let siblingPosition: Double

        public var span: Double { end - start }
        public var mid: Double { (start + end) / 2 }
    }

    public let segments: [Segment]
    public let depth: Int

    /// - Parameters:
    ///   - maxDepth: number of rings drawn around the centre.
    ///   - minSpan: segments narrower than this fraction of a turn are dropped (merged visually into their parent's ring).
    public init(root: CostNode, maxDepth: Int = 3, minSpan: Double = 0.002) {
        var out: [Segment] = []
        func visit(_ node: CostNode, start: Double, end: Double, depth: Int, branch: Int) {
            guard depth < maxDepth, node.cost > 0 else { return }
            var cursor = start
            let visible = node.children.filter { $0.cost > 0 }
            for (i, child) in visible.enumerated() {
                let span = (end - start) * child.cost / node.cost
                defer { cursor += span }
                guard span >= minSpan else { continue }
                let b = depth == 0 ? i : branch
                out.append(Segment(node: child, depth: depth + 1, start: cursor, end: cursor + span, branch: b,
                                   siblingPosition: visible.count > 1 ? Double(i) / Double(visible.count - 1) : 0))
                visit(child, start: cursor, end: cursor + span, depth: depth + 1, branch: b)
            }
        }
        visit(root, start: 0, end: 1, depth: 0, branch: 0)
        segments = out
        depth = out.map(\.depth).max() ?? 0
    }

    /// The segment under a point given in polar form (angle as a fraction of a turn, ring index from 1).
    public func segment(atAngle angle: Double, ring: Int) -> Segment? {
        segments.first { $0.depth == ring && angle >= $0.start && angle < $0.end }
    }
}

import Foundation

/// One box in a cost hierarchy. Groups carry the sum of their children; leaves
/// carry an amount directly. Every chart, table and export reads this one type,
/// so a provider only has to produce a tree to get every visualisation for free.
public struct CostNode: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var subtitle: String?
    public var cost: Double
    public var children: [CostNode]
    /// Free-form explanation of how this amount was derived (SKU, allocation rule…).
    public var detail: String?
    public var flag: CostFlag?
    /// Provider identifiers of the billing lines that make up this node.
    public var skus: [String]
    /// Stable key used to colour the node consistently across views and months
    /// (a service group, an environment, a region…).
    public var colorKey: String?

    public init(
        id: String,
        name: String,
        subtitle: String? = nil,
        cost: Double = 0,
        children: [CostNode] = [],
        detail: String? = nil,
        flag: CostFlag? = nil,
        skus: [String] = [],
        colorKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.cost = cost
        self.children = children
        self.detail = detail
        self.flag = flag
        self.skus = skus
        self.colorKey = colorKey
    }

    /// A group whose cost is the sum of its children, which are sorted largest first.
    public static func group(
        id: String,
        name: String,
        subtitle: String? = nil,
        detail: String? = nil,
        colorKey: String? = nil,
        children: [CostNode]
    ) -> CostNode {
        let sorted = children.sorted { $0.cost > $1.cost }
        return CostNode(
            id: id,
            name: name,
            subtitle: subtitle,
            cost: sorted.reduce(0) { $0 + $1.cost },
            children: sorted,
            detail: detail,
            flag: sorted.contains { $0.flag != nil } ? sorted.compactMap(\.flag).max() : nil,
            skus: [],
            colorKey: colorKey
        )
    }

    public var isLeaf: Bool { children.isEmpty }

    /// Depth-first search by id.
    public func find(_ id: String) -> CostNode? {
        if self.id == id { return self }
        for child in children {
            if let hit = child.find(id) { return hit }
        }
        return nil
    }

    /// The chain of nodes from `self` down to `id`, both included, or nil.
    public func path(to id: String) -> [CostNode]? {
        if self.id == id { return [self] }
        for child in children {
            if let rest = child.path(to: id) { return [self] + rest }
        }
        return nil
    }

    /// Every leaf under this node, in tree order.
    public var leaves: [CostNode] {
        isLeaf ? [self] : children.flatMap(\.leaves)
    }

    /// Every node under this one (itself included), paired with its depth.
    public func flattened(depth: Int = 0) -> [(node: CostNode, depth: Int)] {
        [(self, depth)] + children.flatMap { $0.flattened(depth: depth + 1) }
    }

    /// All SKUs of this node and its descendants, deduplicated and sorted.
    public var allSKUs: [String] {
        Array(Set(skus + children.flatMap(\.allSKUs))).sorted()
    }
}

/// Something about a cost that deserves attention. Ordered by severity.
public enum CostFlag: String, Codable, Sendable, Comparable, CaseIterable {
    case unassigned
    case orphan

    public var label: String {
        switch self {
        case .unassigned: "No allocation rule"
        case .orphan: "Unattached resource"
        }
    }

    private var rank: Int {
        switch self {
        case .unassigned: 0
        case .orphan: 1
        }
    }

    public static func < (lhs: CostFlag, rhs: CostFlag) -> Bool { lhs.rank < rhs.rank }
}

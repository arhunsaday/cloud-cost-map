import CloudCostCore
import SwiftUI

/// The focused node as an expandable table, searchable, for exact numbers.
struct CostListView: View {
    let focus: CostNode
    let total: Double
    let currency: String
    @Binding var selectedID: String?
    var search: String

    private var rows: [CostNode] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return focus.children }
        // Searching flattens the tree to matching leaves with their path as subtitle.
        return focus.flattened().dropFirst().compactMap { item -> CostNode? in
            let n = item.node
            guard n.isLeaf, n.name.lowercased().contains(query) || n.allSKUs.contains(where: { $0.lowercased().contains(query) }) else { return nil }
            var leaf = n
            leaf.subtitle = focus.path(to: n.id)?.dropFirst().dropLast().map(\.name).joined(separator: " › ")
            return leaf
        }
        .sorted { $0.cost > $1.cost }
    }

    var body: some View {
        Table(rows, children: \.childRows, selection: $selectedID) {
            TableColumn("Name") { node in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(Palette.base(node.colorKey)).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(node.name).lineLimit(1)
                        if let subtitle = node.subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if let flag = node.flag {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(flag.label)
                    }
                }
            }
            .width(min: 240, ideal: 420)
            TableColumn("Cost") { node in
                Text(node.cost.money(currency)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Share") { node in
                ShareBar(value: node.cost / max(total, .ulpOfOne), color: Palette.base(node.colorKey))
            }
            .width(min: 120, ideal: 160)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
}

extension CostNode {
    /// `nil` for leaves so `Table` shows no disclosure triangle.
    var childRows: [CostNode]? { isLeaf ? nil : children }
}

struct ShareBar: View {
    let value: Double
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: max(2, geo.size.width * min(max(value, 0), 1)))
                }
            }
            .frame(height: 6)
            Text(value.percent)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

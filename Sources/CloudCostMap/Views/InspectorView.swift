import CloudCostCore
import SwiftUI

/// Details of the selected node, or the report's insights when nothing is selected.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let report: CostReport
    let view: CostView
    let focus: CostNode
    @Binding var selectedID: String?
    @Binding var highlighted: Set<String>
    var onZoom: (CostNode?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let id = selectedID, let node = view.root.find(id) {
                    NodeDetail(node: node, view: view, report: report,
                               previous: model.report(account.id, report.period.previous)?.view(view.id)?.root.find(id),
                               hasPreviousMonth: model.report(account.id, report.period.previous) != nil,
                               onSelect: { selectedID = $0.id }, onZoom: onZoom, onClose: { selectedID = nil })
                } else {
                    InsightsList(report: report, view: view, highlighted: $highlighted, selectedID: $selectedID)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct NodeDetail: View {
    let node: CostNode
    let view: CostView
    let report: CostReport
    let previous: CostNode?
    let hasPreviousMonth: Bool
    var onSelect: (CostNode) -> Void
    var onZoom: (CostNode?) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                if let path = view.root.path(to: node.id)?.dropFirst().dropLast(), !path.isEmpty {
                    Text(path.map(\.name).joined(separator: " › ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Back to insights")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(Palette.base(node.colorKey)).frame(width: 12, height: 12)
                    Text(node.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                }
                if let subtitle = node.subtitle, !subtitle.isEmpty, subtitle != node.skus.joined(separator: ", ") {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(node.cost.money(report.currency)).font(.largeTitle.weight(.semibold).monospacedDigit())
                ShareBar(value: node.cost / max(view.root.cost, .ulpOfOne), color: Palette.base(node.colorKey))
                Text("of \(view.root.cost.money(report.currency)) in \(report.period.title)").font(.caption).foregroundStyle(.secondary)
                if let previous, previous.cost > 0 {
                    let fraction = report.period.elapsedFraction()
                    let change = (node.cost - previous.cost * fraction) / (previous.cost * fraction)
                    Label("\(change.signedPercent) vs. \(report.period.previous.shortTitle) (\(previous.cost.money(report.currency)))",
                          systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.callout)
                        .foregroundStyle(change > 0.1 ? .red : change < -0.1 ? .green : .secondary)
                } else if hasPreviousMonth {
                    Label("New this month", systemImage: "sparkle").font(.callout).foregroundStyle(.secondary)
                }
            }

            if let flag = node.flag {
                Label(flag.label, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            if !node.isLeaf {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Largest items").font(.headline)
                        Spacer()
                        Button("Zoom In") { onZoom(node) }.controlSize(.small)
                    }
                    ForEach(node.children.prefix(8)) { child in
                        Button { onSelect(child) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(child.name).lineLimit(1)
                                    Spacer()
                                    Text(child.cost.money(report.currency)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.callout)
                                ShareBar(value: child.cost / max(node.cost, .ulpOfOne), color: Palette.base(child.colorKey))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if node.children.count > 8 {
                        Text("and \(node.children.count - 8) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let detail = node.detail, !detail.isEmpty, !node.skus.contains(detail) {
                Section(title: "How it’s counted") { Text(detail).font(.callout) }
            }

            let skus = node.allSKUs
            if !skus.isEmpty {
                Section(title: "Billing SKU\(skus.count == 1 ? "" : "s")") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(skus.prefix(12), id: \.self) { sku in
                            Text(sku).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        }
                        if skus.count > 12 { Text("+\(skus.count - 12) more").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}

private struct InsightsList: View {
    let report: CostReport
    let view: CostView
    @Binding var highlighted: Set<String>
    @Binding var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Section(title: "Insights") {
                if report.findings.isEmpty {
                    Label("Nothing stands out this month.", systemImage: "checkmark.seal").foregroundStyle(.secondary)
                }
                VStack(spacing: 8) {
                    ForEach(report.findings) { finding in
                        FindingRow(finding: finding, currency: report.currency, isActive: highlighted == Set(finding.nodeIDs) && !highlighted.isEmpty)
                            .onTapGesture {
                                let ids = Set(finding.nodeIDs)
                                highlighted = highlighted == ids ? [] : ids
                            }
                    }
                }
            }

            Section(title: "Top cost drivers") {
                let leaves = view.root.leaves.sorted { $0.cost > $1.cost }.prefix(6)
                ForEach(Array(leaves)) { leaf in
                    Button { selectedID = leaf.id } label: {
                        HStack {
                            RoundedRectangle(cornerRadius: 2).fill(Palette.base(leaf.colorKey)).frame(width: 8, height: 8)
                            Text(leaf.name).lineLimit(1)
                            Spacer()
                            Text(leaf.cost.money(report.currency)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if !report.warnings.isEmpty {
                Section(title: "Notes") {
                    ForEach(report.warnings, id: \.self) { w in
                        Label(w, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct FindingRow: View {
    let finding: Finding
    let currency: String
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: finding.kind.symbol).foregroundStyle(color)
                Text(finding.title).font(.callout.weight(.semibold))
                Spacer()
                if finding.amount > 0 {
                    Text(finding.amount.money(currency)).font(.callout.monospacedDigit())
                }
            }
            Text(finding.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(isActive ? color.opacity(0.14) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isActive ? color.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .help(finding.nodeIDs.isEmpty ? "" : "Click to highlight in the chart")
    }

    private var color: Color {
        switch finding.kind {
        case .reclaim: .orange
        case .review: .blue
        case .info: .secondary
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
    }
}

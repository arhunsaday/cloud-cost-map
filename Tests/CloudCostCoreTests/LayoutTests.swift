import CoreGraphics
import Foundation
import Testing
@testable import CloudCostCore

@Suite struct LayoutTests {
    let tree = CostNode.group(id: "r", name: "root", children: [
        .group(id: "a", name: "A", children: [CostNode(id: "a1", name: "a1", cost: 30), CostNode(id: "a2", name: "a2", cost: 10)]),
        CostNode(id: "b", name: "B", cost: 60),
    ])

    @Test func treemapPreservesAreasAndStaysInside() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 200)
        let values = [6.0, 6, 4, 3, 2, 2, 1]
        let rects = TreemapLayout.squarify(values, in: rect)
        let total = values.reduce(0, +)
        for (v, r) in zip(values, rects) {
            #expect(abs(Double(r.width * r.height) - v / total * 60_000) < 1)
            #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(r))
        }
        #expect(TreemapLayout.squarify([], in: rect).isEmpty)
        #expect(TreemapLayout.squarify([0, 0], in: rect) == [.zero, .zero])
    }

    @Test func sunburstAnglesFollowCosts() {
        let layout = SunburstLayout(root: tree)
        let b = layout.segments.first { $0.node.id == "b" }!
        #expect(b.start == 0 && abs(b.end - 0.6) < 1e-9) // largest first
        let a1 = layout.segments.first { $0.node.id == "a1" }!
        #expect(a1.depth == 2 && abs(a1.span - 0.3) < 1e-9 && a1.branch == 1)
        #expect(layout.segment(atAngle: 0.65, ring: 2)?.node.id == "a1")
    }

    @Test func nodeHelpers() {
        #expect(tree.cost == 100)
        #expect(tree.path(to: "a2")?.map(\.id) == ["r", "a", "a2"])
        #expect(tree.leaves.count == 3)
    }

    @Test func periods() {
        #expect(BillingPeriod(year: 2026, month: 1).previous == BillingPeriod(year: 2025, month: 12))
        #expect(BillingPeriod(code: "2026-10")?.code == "2026-10")
        let recent = BillingPeriod.recent(3, now: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(recent.count == 3 && recent == recent.sorted())
    }

    @Test func csvEscapes() {
        let report = CostReport(accountID: UUID(), period: BillingPeriod(year: 2026, month: 9), currency: "EUR", billed: 1, gross: 1, credits: 0,
                                lines: [], views: [CostView(id: "x", title: "x", symbol: "x",
                                                            root: .group(id: "r", name: "r", children: [CostNode(id: "1", name: "a, \"b\"", cost: 1)]))])
        #expect(ReportExporter.csv(report, view: report.views[0]).contains("\"a, \"\"b\"\"\""))
    }
}

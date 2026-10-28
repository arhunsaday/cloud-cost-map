import Foundation

/// Spreadsheet- and script-friendly exports of a report.
public enum ReportExporter {
    /// One row per leaf of the chosen view, with its full path.
    public static func csv(_ report: CostReport, view: CostView) -> String {
        var rows = [["period", "path", "name", "cost", "currency", "flag", "skus"]]
        func walk(_ node: CostNode, path: [String]) {
            if node.isLeaf {
                rows.append([report.period.code, path.joined(separator: " / "), node.name,
                             String(format: "%.2f", node.cost), report.currency, node.flag?.rawValue ?? "",
                             node.skus.joined(separator: " ")])
            }
            for child in node.children { walk(child, path: path + [child.name]) }
        }
        for child in view.root.children { walk(child, path: [child.name]) }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// Raw invoice lines.
    public static func linesCSV(_ report: CostReport) -> String {
        var rows = [["period", "category", "product", "resource", "sku", "project", "amount", "currency"]]
        for l in report.lines.sorted(by: { $0.amount > $1.amount }) {
            rows.append([report.period.code, l.category, l.product, l.resource, l.sku, l.project ?? "",
                         String(format: "%.2f", l.amount), report.currency])
        }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    public static func json(_ report: CostReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    private static func escape(_ field: String) -> String {
        field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
    }
}

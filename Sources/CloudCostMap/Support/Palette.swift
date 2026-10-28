import AppKit
import CloudCostCore
import SwiftUI

/// Colours for cost nodes. A node's `colorKey` picks the hue, so "Compute" is
/// the same blue in every view, month and account.
enum Palette {
    private static let named: [String: Color] = [
        "compute": Color(hex: "#3B82F6"),
        "db": Color(hex: "#8B5CF6"),
        "network": Color(hex: "#14B8A6"),
        "storage": Color(hex: "#F59E0B"),
        "baremetal": Color(hex: "#EC4899"),
        "other": Color(hex: "#64748B"),
        "env:prod": Color(hex: "#E11D48"),
        "env:staging": Color(hex: "#F97316"),
        "env:demo": Color(hex: "#A855F7"),
        "env:dev": Color(hex: "#0EA5E9"),
        "env:shared": Color(hex: "#64748B"),
        "env:orphan": Color(hex: "#EAB308"),
        "env:unassigned": Color(hex: "#94A3B8"),
    ]

    /// For keys without a fixed colour (projects, regions, custom environments).
    private static let fallback: [Color] = ["#6366F1", "#10B981", "#F43F5E", "#06B6D4", "#84CC16", "#D946EF", "#F97316", "#0EA5E9"]
        .map(Color.init(hex:))

    static func base(_ key: String?) -> Color {
        guard let key else { return .gray }
        if let c = named[key] { return c }
        let hash = key.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
        return fallback[Int(hash % UInt32(fallback.count))]
    }

    /// The fill for a node drawn at `depth` (1 = innermost ring), varied slightly
    /// among siblings so neighbours with the same key stay distinguishable.
    static func fill(_ node: CostNode, depth: Int, siblingPosition: Double) -> Color {
        let lighten = Double(depth - 1) * 0.16 + siblingPosition * 0.12
        return base(node.colorKey).mix(with: .white, by: min(lighten, 0.6))
    }

    static func provider(_ kind: ProviderKind) -> Color { Color(hex: kind.tintHex) }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255, opacity: 1)
    }
}

extension Double {
    func money(_ currency: String, compact: Bool = false) -> String {
        if compact, abs(self) >= 10_000 {
            return formatted(.currency(code: currency).notation(.compactName).precision(.significantDigits(3)))
        }
        return formatted(.currency(code: currency).precision(.fractionLength(abs(self) >= 1000 ? 0 : 2)))
    }

    var percent: String { formatted(.percent.precision(.fractionLength(self < 0.1 && self > -0.1 ? 1 : 0))) }

    var signedPercent: String { formatted(.percent.precision(.fractionLength(1)).sign(strategy: .always())) }
}

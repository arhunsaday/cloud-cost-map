import CloudCostCore
import SwiftUI

/// Two levels of the focused node as nested tiles. Clicking a tile with
/// children zooms into it; clicking a leaf selects it.
struct TreemapView: View {
    let focus: CostNode
    let total: Double
    let currency: String
    let selectedID: String?
    let highlighted: Set<String>
    @Binding var hoveredID: String?
    var onActivate: (CostNode) -> Void

    private let header: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let tiles = TreemapLayout.tiles(for: focus, in: CGRect(origin: .zero, size: geo.size), header: header, padding: 2)
            let background = Color(nsColor: .windowBackgroundColor)

            Canvas { context, _ in
                for tile in tiles {
                    let rect = tile.rect.insetBy(dx: 1, dy: 1)
                    guard rect.width > 1, rect.height > 1 else { continue }
                    let color = Palette.fill(tile.node, depth: tile.depth, siblingPosition: tile.siblingPosition)
                    let shape = Path(roundedRect: rect, cornerRadius: tile.depth == 1 ? 6 : 4, style: .continuous)
                    let isHovered = tile.id == hoveredID
                    let dimmed = !highlighted.isEmpty && tile.depth == 2 && !highlighted.contains(tile.id)

                    if tile.depth == 1 {
                        let hasChildren = tiles.contains { $0.depth == 2 && $0.branch == tile.branch }
                        context.fill(shape, with: .color(hasChildren ? color.opacity(0.22) : color))
                        context.stroke(shape, with: .color(color.opacity(0.6)), lineWidth: 1)
                        if hasChildren {
                            drawHeader(tile, in: rect, context: &context, color: color)
                        } else {
                            drawLabel(tile.node, in: rect, context: &context)
                        }
                    } else {
                        context.fill(shape, with: .color(dimmed ? color.opacity(0.3) : color))
                        context.stroke(shape, with: .color(background), lineWidth: 1)
                        if tile.node.flag != nil {
                            context.stroke(Path(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: 3), with: .color(.yellow), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                        drawLabel(tile.node, in: rect, context: &context)
                    }
                    if isHovered {
                        context.fill(shape, with: .color(.white.opacity(0.14)))
                    }
                    if tile.id == selectedID || (highlighted.contains(tile.id) && tile.depth == 2) {
                        context.stroke(Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 4), with: .color(.primary), lineWidth: 2.5)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hoveredID = hit(p, tiles)?.id } else { hoveredID = nil }
            }
            .onTapGesture { p in
                if let tile = hit(p, tiles) { onActivate(tile.node) }
            }
            .overlay(alignment: .bottomLeading) {
                if let id = hoveredID, let tile = tiles.first(where: { $0.id == id }) {
                    HoverCard(node: tile.node, parent: focus, total: total, currency: currency)
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: focus.id)
    }

    /// Deepest tile under the point; a depth-1 header counts as its group.
    private func hit(_ p: CGPoint, _ tiles: [TreemapLayout.Tile]) -> TreemapLayout.Tile? {
        tiles.last { $0.rect.contains(p) }
    }

    private func drawHeader(_ tile: TreemapLayout.Tile, in rect: CGRect, context: inout GraphicsContext, color: Color) {
        guard rect.height > header * 2.2, rect.width > 60 else { return }
        let title = Text(tile.node.name).font(.caption.weight(.semibold)).foregroundStyle(color.mix(with: .primary, by: 0.35))
        let value = Text(" " + tile.node.cost.money(currency, compact: true)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        let resolved = context.resolve(Text("\(title)\(value)"))
        context.draw(resolved, in: CGRect(x: rect.minX + 7, y: rect.minY + 4, width: rect.width - 14, height: header - 4))
    }

    private func drawLabel(_ node: CostNode, in rect: CGRect, context: inout GraphicsContext) {
        guard rect.width > 54, rect.height > 26 else { return }
        let inset = rect.insetBy(dx: 6, dy: 5)
        let name = context.resolve(Text(node.name).font(.caption.weight(.medium)).foregroundStyle(.white))
        context.draw(name, in: CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: 15))
        if rect.height > 42 {
            let cost = context.resolve(Text(node.cost.money(currency, compact: true)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.85)))
            context.draw(cost, in: CGRect(x: inset.minX, y: inset.minY + 15, width: inset.width, height: 14))
        }
    }
}

struct HoverCard: View {
    let node: CostNode
    let parent: CostNode
    let total: Double
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node.name).font(.callout.weight(.semibold))
            HStack(spacing: 8) {
                Text(node.cost.money(currency)).monospacedDigit()
                Text("\((node.cost / max(total, .ulpOfOne)).percent) of total").foregroundStyle(.secondary)
            }
            .font(.caption)
            if let flag = node.flag {
                Label(flag.label, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

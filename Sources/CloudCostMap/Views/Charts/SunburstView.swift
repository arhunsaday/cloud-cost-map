import CloudCostCore
import SwiftUI

/// Rings of the focused node's descendants. Clicking a group zooms into it,
/// clicking the centre zooms out, hovering shows the segment in the centre.
struct SunburstView: View {
    let focus: CostNode
    let total: Double
    let currency: String
    let rings: Int
    let selectedID: String?
    let highlighted: Set<String>
    @Binding var hoveredID: String?
    var canZoomOut: Bool
    var onActivate: (CostNode) -> Void
    var onZoomOut: () -> Void

    private var layout: SunburstLayout { SunburstLayout(root: focus, maxDepth: rings) }

    var body: some View {
        let layout = layout
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let hole = size * 0.19
            let ring = (size / 2 - hole) / CGFloat(max(layout.depth, 1))
            let hovered = hoveredID.flatMap { id in layout.segments.first { $0.id == id } }

            ZStack {
                ForEach(layout.segments) { s in
                    let dimmed = isDimmed(s, hovered: hovered)
                    ArcShape(start: s.start, end: s.end,
                             inner: hole + ring * CGFloat(s.depth - 1), outer: hole + ring * CGFloat(s.depth))
                        .fill(Palette.fill(s.node, depth: s.depth, siblingPosition: s.siblingPosition))
                        .overlay {
                            ArcShape(start: s.start, end: s.end,
                                     inner: hole + ring * CGFloat(s.depth - 1), outer: hole + ring * CGFloat(s.depth))
                                .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.2)
                        }
                        .overlay {
                            if s.id == selectedID || highlighted.contains(s.id) {
                                ArcShape(start: s.start, end: s.end,
                                         inner: hole + ring * CGFloat(s.depth - 1) + 1.5, outer: hole + ring * CGFloat(s.depth) - 1.5)
                                    .stroke(Color.primary, lineWidth: 2.5)
                            }
                        }
                        .opacity(dimmed ? 0.35 : 1)
                        .transition(.opacity)
                }
                ForEach(layout.segments.filter { labelFits($0, ring: ring, hole: hole) }) { s in
                    segmentLabel(s)
                        .position(point(angle: s.mid, radius: hole + ring * (CGFloat(s.depth) - 0.5), center: center))
                        .allowsHitTesting(false)
                }
                CenterLabel(node: hovered?.node ?? focus, share: hovered.map { $0.node.cost / max(focus.cost, .ulpOfOne) },
                            totalShare: (hovered?.node ?? focus).cost / max(total, .ulpOfOne),
                            currency: currency, canZoomOut: canZoomOut && hovered == nil)
                    .frame(width: hole * 1.85, height: hole * 1.85)
                    .position(center)
                    .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hoveredID = hit(p, center: center, hole: hole, ring: ring, layout: layout)?.id
                case .ended:
                    hoveredID = nil
                }
            }
            .onTapGesture { p in
                let dx = p.x - center.x, dy = p.y - center.y
                if (dx * dx + dy * dy).squareRoot() < hole {
                    onZoomOut()
                } else if let s = hit(p, center: center, hole: hole, ring: ring, layout: layout) {
                    onActivate(s.node)
                }
            }
            .help(hovered.map { "\($0.node.name) — \($0.node.cost.money(currency))" } ?? "")
        }
        .animation(.smooth(duration: 0.45), value: focus.id)
        .animation(.easeOut(duration: 0.12), value: hoveredID)
    }

    /// While hovering, everything outside the hovered segment's ancestry fades.
    private func isDimmed(_ s: SunburstLayout.Segment, hovered: SunburstLayout.Segment?) -> Bool {
        if !highlighted.isEmpty, hovered == nil { return !highlighted.contains(s.id) && !highlighted.contains { $0.hasPrefix(s.id + "/") } && s.depth > 1 }
        guard let hovered else { return false }
        if s.id == hovered.id { return false }
        // Ancestors: contain the hovered segment's angular range at a lower depth.
        if s.depth < hovered.depth, s.start <= hovered.start + 1e-9, s.end >= hovered.end - 1e-9 { return false }
        // Descendants.
        if s.depth > hovered.depth, s.start >= hovered.start - 1e-9, s.end <= hovered.end + 1e-9 { return false }
        return true
    }

    private func hit(_ p: CGPoint, center: CGPoint, hole: CGFloat, ring: CGFloat, layout: SunburstLayout) -> SunburstLayout.Segment? {
        let dx = p.x - center.x, dy = p.y - center.y
        let r = (dx * dx + dy * dy).squareRoot()
        guard r >= hole else { return nil }
        let depth = Int((r - hole) / ring) + 1
        // 0 at 12 o'clock, clockwise.
        var angle = atan2(dx, -dy) / (2 * .pi)
        if angle < 0 { angle += 1 }
        return layout.segment(atAngle: angle, ring: depth)
    }

    private func labelFits(_ s: SunburstLayout.Segment, ring: CGFloat, hole: CGFloat) -> Bool {
        let radius = hole + ring * (CGFloat(s.depth) - 0.5)
        return CGFloat(s.span) * 2 * .pi * radius > 64 && ring > 34
    }

    private func segmentLabel(_ s: SunburstLayout.Segment) -> some View {
        VStack(spacing: 0) {
            Text(s.node.name).font(.caption.weight(.semibold)).lineLimit(1)
            Text(s.node.cost.money(currency, compact: true)).font(.caption2.monospacedDigit()).opacity(0.85)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 1.5)
        .frame(maxWidth: 90)
    }

    private func point(angle: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        let a = angle * 2 * .pi
        return CGPoint(x: center.x + radius * CGFloat(sin(a)), y: center.y - radius * CGFloat(cos(a)))
    }
}

private struct CenterLabel: View {
    let node: CostNode
    let share: Double?
    let totalShare: Double
    let currency: String
    let canZoomOut: Bool

    var body: some View {
        VStack(spacing: 3) {
            if canZoomOut {
                Image(systemName: "arrow.up.left.circle.fill").foregroundStyle(.secondary)
            }
            Text(node.name)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(node.cost.money(currency))
                .font(.title2.weight(.semibold).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(share.map { "\($0.percent) of view" } ?? (totalShare < 0.999 ? "\(totalShare.percent) of total" : " "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }
}

/// A ring segment. Angles are fractions of a turn from 12 o'clock, clockwise.
struct ArcShape: Shape {
    var start: Double
    var end: Double
    var inner: CGFloat
    var outer: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(start, end), AnimatablePair(inner, outer)) }
        set { (start, end, inner, outer) = (newValue.first.first, newValue.first.second, newValue.second.first, newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let a0 = Angle(radians: start * 2 * .pi - .pi / 2)
        let a1 = Angle(radians: end * 2 * .pi - .pi / 2)
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }
}

import SwiftUI

/// The spending wheel, drawn exactly like the Mac's: a thick ring of softly rounded slices sized by what each category cost in total,
/// with a thin dark arc outside the part of a slice you excluded. Tap a slice to select it.
struct SpendWheel: View {
    struct Slice: Identifiable { var id: String; var total: Double; var mine: Double; var color: Color }
    let slices: [Slice]
    var selected: String? = nil
    var centerTop: String = ""
    var centerBottom: [String] = []
    var onTap: ((String) -> Void)? = nil
    var animateIn = false
    @State private var progress: Double = 1

    // the Mac's geometry, in its 220-unit drawing space
    private static let R = 94.0, r = 60.0, R2 = 98.0, R3 = 106.0, ins = 2.8
    private struct Piece: Identifiable { var id: String; var s0: Double; var s1: Double; var color: Color; var excl: Double }

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height), k = side / 220, center = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let pieces = layout()
            ZStack {
                ForEach(pieces) { p in
                    let dim = selected != nil && selected != p.id
                    Wedge(s0: p.s0, s1: p.s1, ro: (Self.R - Self.ins) * k, ri: (Self.r + Self.ins) * k, center: center, progress: progress)
                        .fill(p.color)
                        .overlay(Wedge(s0: p.s0, s1: p.s1, ro: (Self.R - Self.ins) * k, ri: (Self.r + Self.ins) * k, center: center, progress: progress)
                            .stroke(p.color, style: StrokeStyle(lineWidth: Self.ins * 2 * k, lineJoin: .round)))
                        .opacity(dim ? 0.25 : 1)
                    if p.excl > 0.001 {
                        let e1 = max(p.s0 + 0.02, p.s0 + (p.s1 - p.s0) * p.excl)
                        let w = Wedge(s0: p.s0, s1: e1, ro: (Self.R3 - 1.6) * k, ri: (Self.R2 + 1.6) * k, center: center, progress: progress)
                        w.fill(Color.primary).overlay(w.stroke(Color.primary, style: StrokeStyle(lineWidth: 3.2 * k, lineJoin: .round)))
                            .opacity(dim ? 0.2 : 0.72)
                    }
                }
                if !centerTop.isEmpty || selectedSlice != nil { centerText }
            }
            .animation(.smooth(duration: 0.3), value: selected)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { v in
                guard let onTap else { return }
                let dx = v.location.x - center.x, dy = v.location.y - center.y, dist = (dx * dx + dy * dy).squareRoot()
                guard dist > (Self.r - 6) * k, dist < (Self.R3 + 6) * k else { return }
                var ang = atan2(dy, dx) + .pi / 2; if ang < 0 { ang += 2 * .pi }
                let sum = slices.reduce(0) { $0 + $1.total }; var acc = 0.0
                // thin slices are hard to hit, so pick the slice whose middle is nearest the tap (within a small tolerance)
                var best: (String, Double)? = nil
                for s in slices { let span = s.total / sum * 2 * .pi, mid = acc + span / 2; acc += span
                    var d = abs(ang - mid); d = min(d, 2 * .pi - d); let reach = max(span / 2, 0.07); if d <= reach, best == nil || d < best!.1 { best = (s.id, d) } }
                if let best { onTap(best.0) }
            })
        }
        .onAppear { if animateIn { progress = 0; withAnimation(.smooth(duration: 1.1).delay(0.1)) { progress = 1 } } }
    }

    private var selectedSlice: Slice? { slices.first { $0.id == selected } }
    private var centerText: some View {
        VStack(spacing: 1) {
            if let s = selectedSlice {
                Text(WF.money(s.mine)).font(.system(size: 22, weight: .bold)).minimumScaleFactor(0.6).lineLimit(1)
                Text(s.id).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Text(centerTop).font(.system(size: 22, weight: .bold)).minimumScaleFactor(0.6).lineLimit(1)
                ForEach(Array(centerBottom.enumerated()), id: \.offset) { i, l in Text(l).font(.system(size: i == 0 ? 11 : 9.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7) }
            }
        }.frame(width: 96).contentTransition(.numericText())
    }

    /// Same slicing as the Mac: a small gap between slices, and each slice inset a little so the rounded stroke fills it back out.
    private func layout() -> [Piece] {
        let sum = slices.reduce(0) { $0 + $1.total }; guard sum > 0 else { return [] }
        var ang = -Double.pi / 2; var out: [Piece] = []
        for s in slices {
            let span = s.total / sum * 2 * .pi; defer { ang += span }
            let gapA = min(0.034, span * 0.25), s0 = ang + gapA / 2 + Self.ins / 77, s1 = max(s0 + 0.002, ang + span - gapA / 2 - Self.ins / 77)
            out.append(Piece(id: s.id, s0: s0, s1: s1, color: s.color, excl: s.total > 0 ? min(1, max(0, (s.total - s.mine) / s.total)) : 0))
        }
        return out
    }
}

/// A ring segment from angle s0 to s1 that grows around the ring as `progress` goes 0 → 1.
private struct Wedge: Shape {
    var s0: Double, s1: Double, ro: CGFloat, ri: CGFloat, center: CGPoint, progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    func path(in rect: CGRect) -> Path {
        let end = min(s1, -Double.pi / 2 + progress * 2 * .pi)
        var p = Path(); guard end > s0 else { return p }
        func pt(_ rad: CGFloat, _ a: Double) -> CGPoint { CGPoint(x: center.x + rad * CGFloat(cos(a)), y: center.y + rad * CGFloat(sin(a))) }
        p.move(to: pt(ro, s0))
        p.addArc(center: center, radius: ro, startAngle: .radians(s0), endAngle: .radians(end), clockwise: false)
        p.addLine(to: pt(ri, end))
        p.addArc(center: center, radius: ri, startAngle: .radians(end), endAngle: .radians(s0), clockwise: true)
        p.closeSubpath()
        return p
    }
}

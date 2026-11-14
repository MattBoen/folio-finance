import SwiftUI

/// One set of springs so every screen moves the same way.
enum Motion {
    /// Default for layout changes: settles quickly with no visible wobble.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.84)
    /// A little overshoot for things the finger just touched.
    static let bouncy = Animation.spring(response: 0.36, dampingFraction: 0.66)
    /// Fast press-down.
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.75)
    /// Long ease-out for numbers counting up and charts drawing in.
    static let reveal = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.95)
}

// MARK: - Replaying on return

/// Pages count up and fill in the first time you see them, and again only when you come back after a while.
/// Hopping between tabs quickly keeps everything still, so it never turns into a show every time.
enum Replay {
    static let after: TimeInterval = {
        #if DEBUG
        // Testing only: launch with "-replayAfter 3" to shorten the wait.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-replayAfter"), i + 1 < args.count, let v = TimeInterval(args[i + 1]) { return v }
        #endif
        return 60
    }()

    static func due(_ leftAt: Date?) -> Bool {
        guard let leftAt else { return false }
        return Date().timeIntervalSince(leftAt) > after
    }

    /// Snap back to the start, then run the animation a frame later so SwiftUI has something to animate from.
    @MainActor static func restart(reset: @escaping @MainActor () -> Void, run: @escaping @MainActor () -> Void) {
        reset()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            run()
        }
    }
}

// MARK: - Counting numbers

/// Text whose number SwiftUI can interpolate, so amounts count instead of jumping.
struct RollingNumber: View, Animatable {
    var value: Double
    let format: (Double) -> String

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View { Text(format(value)) }
}

/// An amount that counts up from zero each time its page appears, and rolls smoothly when it changes.
struct CountUpText: View {
    let value: Double
    var format: (Double) -> String = { money($0) }

    @State private var shown: Double = 0
    @State private var leftAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RollingNumber(value: shown, format: format)
            .onAppear {
                if reduceMotion { shown = value; return }
                if Replay.due(leftAt) {
                    Replay.restart(reset: { shown = 0 }, run: { withAnimation(Motion.reveal) { shown = value } })
                } else if leftAt == nil {
                    withAnimation(Motion.reveal) { shown = value }
                }
            }
            .onDisappear { leftAt = Date() }
            .onChange(of: value) { _, new in
                // Coming up from zero (data just loaded) gets the full count; later edits just roll.
                let anim = abs(shown) < 0.5 ? Motion.reveal : Motion.spring
                if reduceMotion { shown = new } else { withAnimation(anim) { shown = new } }
            }
    }
}

/// Any text with dollar amounts in it ("$1,850 of $2,000", "+$3,150.00", "$6,300 / mo"): every amount counts
/// up from $0 each time the page appears, and the words around them stay put. Same feel as Balance Sheet.
struct CountingText: View {
    let text: String
    init(_ text: String) { self.text = text }

    @State private var p: Double = 0
    @State private var leftAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CountingFrame(parts: AmountParts.parse(text), p: reduceMotion ? 1 : p)
            .onAppear {
                if Replay.due(leftAt) {
                    Replay.restart(reset: { p = 0 }, run: { withAnimation(Motion.reveal) { p = 1 } })
                } else if leftAt == nil {
                    withAnimation(Motion.reveal) { p = 1 }
                }
            }
            .onDisappear { leftAt = Date() }
            .onChange(of: text) { old, _ in
                // Real numbers arriving after a placeholder of $0 get the full count.
                if AmountParts.parse(old).allZero, !reduceMotion {
                    p = 0
                    Task { @MainActor in withAnimation(Motion.reveal) { p = 1 } }
                }
            }
    }
}

private struct CountingFrame: View, Animatable {
    let parts: AmountParts
    var p: Double

    nonisolated var animatableData: Double {
        get { p }
        set { p = newValue }
    }

    var body: some View { Text(parts.render(p)) }
}

/// A string split into plain text and dollar amounts.
struct AmountParts: Equatable {
    enum Piece: Equatable { case text(String), amount(value: Double, decimals: Int, grouped: Bool) }
    let pieces: [Piece]

    var allZero: Bool {
        pieces.allSatisfy { if case .amount(let v, _, _) = $0 { return abs(v) < 0.005 } else { return true } }
    }

    private static let pattern = try! NSRegularExpression(pattern: "\\$([0-9][0-9,]*(?:\\.[0-9]+)?)")

    static func parse(_ s: String) -> AmountParts {
        let ns = s as NSString
        var pieces: [Piece] = []
        var last = 0
        for m in pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let digits = ns.substring(with: m.range(at: 1))
            guard let v = Double(digits.replacingOccurrences(of: ",", with: "")) else { continue }
            // Keep everything up to and including the "$" as plain text (signs, words).
            pieces.append(.text(ns.substring(with: NSRange(location: last, length: m.range.location + 1 - last))))
            let decimals = digits.split(separator: ".").dropFirst().first?.count ?? 0
            pieces.append(.amount(value: v, decimals: decimals, grouped: digits.contains(",") || v >= 1000))
            last = m.range.location + m.range.length
        }
        pieces.append(.text(ns.substring(from: last)))
        return AmountParts(pieces: pieces)
    }

    func render(_ p: Double) -> String {
        let k = min(max(p, 0), 1)
        return pieces.map { piece in
            switch piece {
            case .text(let t): return t
            case .amount(let v, let d, let g):
                let x = k >= 1 ? v : v * k
                return x.formatted(.number.precision(.fractionLength(d)).grouping(g ? .automatic : .never))
            }
        }.joined()
    }
}

// MARK: - Entrances

/// Cards rise into place one after another the first time a screen shows them.
private struct Entrance: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 24)
            .scaleEffect(shown ? 1 : 0.97, anchor: .top)
            .blur(radius: shown ? 0 : 5)
            .onAppear {
                guard !shown else { return }
                if reduceMotion { shown = true; return }
                withAnimation(Motion.spring.delay(Double(min(index, 8)) * 0.055)) { shown = true }
            }
    }
}

/// Draws a chart from left to right, again whenever `id` changes (a new range, new data).
private struct Reveal<ID: Equatable>: ViewModifier {
    let id: ID
    @State private var progress: CGFloat = 0
    @State private var leftAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .mask(alignment: .leading) {
                GeometryReader { g in Rectangle().frame(width: g.size.width * progress) }
            }
            .onAppear {
                if Replay.due(leftAt) { Replay.restart(reset: { progress = 0 }, run: run) }
                else if leftAt == nil { run() }
            }
            .onDisappear { leftAt = Date() }
            .onChange(of: id) { progress = 0; Task { @MainActor in run() } }
    }

    private func run() {
        if reduceMotion { progress = 1 } else { withAnimation(Motion.reveal) { progress = 1 } }
    }
}

/// A soft light sweep over loading placeholders.
private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: phase * g.size.width * 1.4)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
    }
}

extension View {
    /// Scroll-linked depth for cards, plus a staggered rise on first appearance when `index` is given.
    @ViewBuilder func flowIn(_ index: Int? = nil) -> some View {
        let scrolled = scrollTransition(.interactive) { c, phase in
            // Gentle: tall cards stay partly off-screen while being read, so no blur and only a slight fade.
            c.opacity(1 - abs(phase.value) * 0.18)
                .scaleEffect(1 - abs(phase.value) * 0.03)
        }
        if let index { scrolled.modifier(Entrance(index: index)) } else { scrolled }
    }

    /// Just the staggered first-appearance rise, for content that isn't in a scroll view.
    func entrance(_ index: Int = 0) -> some View { modifier(Entrance(index: index)) }

    func chartReveal<ID: Equatable>(id: ID) -> some View { modifier(Reveal(id: id)) }

    func shimmer() -> some View { modifier(Shimmer()) }
}

// MARK: - Period change badge

/// "+4.2%" pill for the top right of a chart: how much the line moved over the selected period.
struct PeriodChangeBadge: View {
    let first: Double
    let last: Double

    var body: some View {
        if abs(first) > 0.5 {
            let pct = (last - first) / abs(first) * 100
            let up = pct >= 0
            Label(String(format: "%@%.1f%%", up ? "+" : "−", abs(pct)), systemImage: up ? "arrow.up.right" : "arrow.down.right")
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(up ? Color.up : Color.down)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background((up ? Color.up : Color.down).opacity(0.14), in: Capsule())
                .contentTransition(.numericText())
                .animation(Motion.spring, value: pct)
                .sensitive()
        }
    }
}

// MARK: - Pull to refresh

extension View {
    /// Pull to refresh that finishes its work even if SwiftUI cancels the gesture's task part way, and taps a light haptic when done.
    func folioRefresh(_ work: @escaping @MainActor () async -> Void) -> some View {
        refreshable {
            await Task { await work() }.value
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
    }
}

extension BankSync {
    /// Asks the banks for new data but never makes a pull-to-refresh wait more than a few seconds for them.
    static func refreshForPull(_ auth: AuthManager) async {
        await withTaskGroup(of: Void.self) { g in
            g.addTask { await BankSync.run(auth, force: true) }
            g.addTask { try? await Task.sleep(for: .seconds(6)) }
            await g.next()
            g.cancelAll()
        }
    }
}

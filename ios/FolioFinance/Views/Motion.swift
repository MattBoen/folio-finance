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

/// An amount that counts up the first time it appears and rolls smoothly when it changes.
struct CountUpText: View {
    let value: Double
    var format: (Double) -> String = { money($0) }

    @State private var shown: Double = 0
    @State private var started = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RollingNumber(value: shown, format: format)
            .onAppear {
                guard !started else { return }
                started = true
                if reduceMotion { shown = value } else { withAnimation(Motion.reveal) { shown = value } }
            }
            .onChange(of: value) { _, new in
                // Coming up from zero (data just loaded) gets the full count; later edits just roll.
                let anim = abs(shown) < 0.5 ? Motion.reveal : Motion.spring
                if reduceMotion { shown = new } else { withAnimation(anim) { shown = new } }
            }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .mask(alignment: .leading) {
                GeometryReader { g in Rectangle().frame(width: g.size.width * progress) }
            }
            .onAppear(perform: run)
            .onChange(of: id) { progress = 0; run() }
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

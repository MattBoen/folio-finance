import SwiftUI

// MARK: - Colors

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    static let up = Color(UIColor.systemGreen)
    static let down = Color(UIColor.systemRed)
    static let heroTop = Color(hex: 0x3B8BFF)
    static let heroBottom = Color(hex: 0x5E5CE6)
}

// MARK: - Page wash (the soft color behind every screen, like the Mac app)

enum Tone {
    case balance, spending, activity, accounts, plan

    var wash: [Color] {
        switch self {
        case .balance: [.blue, .indigo, .teal, .purple]
        case .spending: [.green, .teal, .yellow, .blue]
        case .activity: [.teal, .green, .blue, .indigo]
        case .accounts: [.gray, .blue, .teal, .purple]
        case .plan: [.indigo, .purple, .blue, .teal]
        }
    }
}

struct Wash: View {
    var tone: Tone
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = tone.wash
        let a = scheme == .dark ? 0.34 : 0.26
        ZStack {
            Color(UIColor.systemGroupedBackground)
            RadialGradient(colors: [c[0].opacity(a), .clear], center: .topLeading, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [c[1].opacity(a * 0.75), .clear], center: .topTrailing, startRadius: 0, endRadius: 460)
            RadialGradient(colors: [c[2].opacity(a * 0.7), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 560)
            RadialGradient(colors: [c[3].opacity(a * 0.55), .clear], center: .bottomLeading, startRadius: 0, endRadius: 480)
        }
        .ignoresSafeArea()
    }
}

/// Backing for a switch pinned at the top of a page: the page's own wash, lined up with the screen, so no band shows.
struct PinnedBandBackground: View {
    var tone: Tone

    var body: some View {
        Color.clear
            .overlay(alignment: .top) { Wash(tone: tone).frame(height: UIScreen.main.bounds.height) }
            .clipped()
            .ignoresSafeArea(edges: .top)
    }
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
    }
}

struct SectionTitle: View {
    var text: String
    var trailing: String?

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(text).font(.title3.bold())
            Spacer()
            if let trailing { Text(trailing).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 4)
    }
}

struct IconBadge: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            )
    }
}

struct DeltaPill: View {
    var value: Double
    var body: some View {
        Text(signedMoney(value))
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(value >= 0 ? Color.up : Color.down)
            .background((value >= 0 ? Color.up : Color.down).opacity(0.14), in: Capsule())
    }
}

/// Blurs amounts when "Hide amounts" is on, like the Mac app's privacy switch.
struct Sensitive: ViewModifier {
    @AppStorage("hideAmounts") private var hide = false
    func body(content: Content) -> some View {
        content
            .blur(radius: hide ? 9 : 0)
            .animation(Motion.spring, value: hide)
    }
}

extension View {
    func sensitive() -> some View { modifier(Sensitive()) }
}

struct EmptyStateCard: View {
    var symbol: String
    var title: String
    var message: String
    @State private var bounced = false

    var body: some View {
        Card {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, value: bounced)
                    .onAppear { bounced = true }
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.subheadline)
            Spacer(minLength: 8)
            Button("Retry", action: retry).font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct BrandMark: View {
    var size: CGFloat = 80
    var body: some View {
        Image("BrandIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .shadow(color: Color.heroBottom.opacity(0.35), radius: size * 0.16, y: size * 0.08)
    }
}

// MARK: - Profile menu

struct ProfileMenu: View {
    @EnvironmentObject private var auth: AuthManager
    @AppStorage("hideAmounts") private var hide = false
    @State private var showSettings = false

    var body: some View {
        Menu {
            Section(auth.isDemo ? "Sample data" : (auth.currentEmail ?? "Your account")) {
                if auth.isDemo { Text("Changes aren't saved in demo mode") }
            }
            Button { showSettings = true } label: { Label("Settings and account", systemImage: "gearshape") }
            Toggle(isOn: $hide) { Label("Hide amounts", systemImage: "eye.slash") }
        } label: {
            Image(systemName: "person.crop.circle")
                .accessibilityLabel("Account and settings")
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

enum AppLinks {
    static let privacy = URL(string: "https://folio-finance-api.onrender.com/privacy")!
    static let terms = URL(string: "https://folio-finance-api.onrender.com/terms")!
    static let support = URL(string: "mailto:folio.finance.app@gmail.com")!
}

// MARK: - Formatting

func money(_ v: Double, cents: Bool = false) -> String {
    v.formatted(.currency(code: "USD").precision(.fractionLength(cents ? 2 : 0)))
}

func money(_ v: Decimal, cents: Bool = false) -> String {
    v.formatted(.currency(code: "USD").precision(.fractionLength(cents ? 2 : 0)))
}

func signedMoney(_ v: Double, cents: Bool = false) -> String {
    (v >= 0 ? "+" : "−") + money(abs(v), cents: cents)
}

func compactMoney(_ v: Double) -> String {
    let a = abs(v)
    let sign = v < 0 ? "−" : ""
    func trim(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(0...1))) }
    if a >= 1_000_000 { return "\(sign)$\(trim(a / 1_000_000))M" }
    if a >= 1_000 { return "\(sign)$\(trim(a / 1_000))K" }
    return "\(sign)$\(trim(a))"
}

private func dayStyle() -> Date.ISO8601FormatStyle {
    Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
}

func parseDay(_ s: String) -> Date? {
    try? Date(s, strategy: dayStyle())
}

func dayString(_ d: Date) -> String {
    d.formatted(dayStyle())
}

/// "Today", "Yesterday", or "Mon, Oct 27".
func dayHeader(_ s: String) -> String {
    guard let d = parseDay(s) else { return s }
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
}

// MARK: - Categories

enum Categories {
    static let choices = [
        "Groceries", "Dining", "Transport", "Shopping", "Bills & Utilities", "Home",
        "Entertainment", "Health", "Travel", "Subscriptions", "Income", "Other"
    ]

    static func style(_ name: String?) -> (symbol: String, color: Color) {
        let n = (name ?? "").lowercased()
        func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
        if has("grocer", "supermarket") { return ("cart.fill", Color(hex: 0x34C759)) }
        if has("dining", "food", "restaurant", "coffee", "bar") { return ("fork.knife", Color(hex: 0xFF9500)) }
        if has("transport", "gas", "auto", "fuel", "uber", "transit") { return ("car.fill", Color(hex: 0x0A84FF)) }
        if has("shop", "general merch", "clothing") { return ("bag.fill", Color(hex: 0xFF2D55)) }
        if has("bill", "utilit", "rent", "phone", "internet") { return ("bolt.fill", Color(hex: 0xFFCC00)) }
        if has("home", "house", "improvement") { return ("house.fill", Color(hex: 0xA2845E)) }
        if has("entertain", "recreation", "movie") { return ("tv.fill", Color(hex: 0xAF52DE)) }
        if has("health", "medical", "pharm", "fitness") { return ("heart.fill", Color(hex: 0xFF3B30)) }
        if has("travel", "flight", "hotel") { return ("airplane", Color(hex: 0x30B0C7)) }
        if has("subscription") { return ("repeat", Color(hex: 0x5E5CE6)) }
        if has("income", "payroll", "deposit", "salary") { return ("arrow.down.circle.fill", Color(hex: 0x34C759)) }
        if has("transfer", "payment") { return ("arrow.left.arrow.right", Color(hex: 0x8E8E93)) }
        return ("ellipsis.circle.fill", Color(hex: 0x8E8E93))
    }
}

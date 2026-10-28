import SwiftUI

/// One line in a breakdown: icon, title, optional share bar, value.
struct BreakdownRow: Identifiable {
    let id = UUID()
    var symbol: String? = nil
    var color: Color = .secondary
    var title: String
    var subtitle: String? = nil
    var value: String
    /// 0...1 share shown as a thin bar under the row.
    var fraction: Double? = nil
    var valueColor: Color? = nil
}

struct BreakdownSection: Identifiable {
    let id = UUID()
    var title: String? = nil
    var rows: [BreakdownRow]
}

/// The standard "tap a tile, see what's inside" sheet used across the app, so every breakdown looks and behaves the same.
struct BreakdownSheet<Extra: View>: View {
    let title: String
    var headline: String
    var caption: String? = nil
    var tone: Tone = .balance
    var sections: [BreakdownSection] = []
    var footnote: String? = nil
    @ViewBuilder var extra: () -> Extra

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Wash(tone: tone)
                ScrollView {
                    VStack(spacing: 14) {
                        Card {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(title).font(.subheadline).foregroundStyle(.secondary)
                                Text(headline)
                                    .font(.system(size: 38, weight: .bold, design: .rounded))
                                    .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                                    .contentTransition(.numericText())
                                    .sensitive()
                                if let caption { Text(caption).font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
                        extra()
                        ForEach(sections) { section in
                            VStack(spacing: 8) {
                                if let t = section.title { SectionTitle(t) }
                                Card(padding: 0) {
                                    VStack(spacing: 0) {
                                        ForEach(section.rows) { row in
                                            BreakdownRowView(row: row)
                                            if row.id != section.rows.last?.id { Divider().padding(.leading, row.symbol == nil ? 16 : 62) }
                                        }
                                    }
                                }
                            }
                        }
                        if let footnote {
                            Text(footnote).font(.footnote).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).padding(.horizontal, 24)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

extension BreakdownSheet where Extra == EmptyView {
    init(title: String, headline: String, caption: String? = nil, tone: Tone = .balance, sections: [BreakdownSection] = [], footnote: String? = nil) {
        self.init(title: title, headline: headline, caption: caption, tone: tone, sections: sections, footnote: footnote) { EmptyView() }
    }
}

struct BreakdownRowView: View {
    let row: BreakdownRow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                if let s = row.symbol { IconBadge(symbol: s, color: row.color, size: 34) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.body).lineLimit(1)
                    if let sub = row.subtitle { Text(sub).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                Text(row.value).font(.body.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(row.valueColor ?? .primary).sensitive()
            }
            if let f = row.fraction { ProgressBar(fraction: f, color: row.color) }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }
}

/// Makes a whole card behave like one tappable tile, with a press effect and a light tick.
struct TileButton<Content: View>: View {
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var tick = 0

    var body: some View {
        Button { tick += 1; action() } label: { content() }
            .buttonStyle(PressableCardStyle())
            .sensoryFeedback(.selection, trigger: tick)
    }
}

/// Lets any screen jump to another tab (for example Overview's month tile opening Spending).
enum AppTab: Hashable { case overview, spending, budget, money, ask }

@MainActor
final class TabRouter: ObservableObject {
    @Published var selected: AppTab = .overview
}

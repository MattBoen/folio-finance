import SwiftUI

/// Every bill and subscription Folio found in your transactions, what's due next, and what it all adds up to.
struct BillsView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var data: Recurring?
    @State private var loaded = false
    @State private var error: String?
    @AppStorage("hiddenBills") private var hiddenRaw = ""

    private var hidden: Set<String> { Set(hiddenRaw.split(separator: "|").map(String.init)) }
    private func hide(_ id: String) { withAnimation(Motion.spring) { hiddenRaw = (hidden.union([id])).sorted().joined(separator: "|") } }
    private func unhideAll() { withAnimation(Motion.spring) { hiddenRaw = "" } }

    private var items: [RecurringItem] { (data?.items ?? []).filter { !hidden.contains($0.id) } }
    private var subs: [RecurringItem] { items.filter(\.isSubscription) }
    private var bills: [RecurringItem] { items.filter { !$0.isSubscription } }
    private var upcoming: [UpcomingBill] { (data?.upcoming ?? []).filter { !hidden.contains($0.id) } }
    private var monthly: Double { items.reduce(0) { $0 + $1.monthly } }
    private var subsMonthly: Double { subs.reduce(0) { $0 + $1.monthly } }

    var body: some View {
        ZStack {
            Wash(tone: .plan)
            ScrollView {
                VStack(spacing: 14) {
                    if let error { ErrorBanner(message: error) { Task { await load() } } }
                    if loaded && items.isEmpty {
                        EmptyStateCard(
                            symbol: "calendar.badge.clock",
                            title: "No bills found yet",
                            message: "Folio looks for charges that repeat. Once an account has a few months of history, your bills and subscriptions show up here on their own."
                        )
                    } else if data != nil {
                        totalCard.flowIn(0)
                        if !upcoming.isEmpty { upcomingCard.flowIn(1) }
                        if !subs.isEmpty { listCard("Subscriptions", subtitle: "\(money(subsMonthly)) a month", rows: subs, canCancel: true).flowIn(2) }
                        if !bills.isEmpty { listCard("Bills", subtitle: "\(money(bills.reduce(0) { $0 + $1.monthly })) a month", rows: bills, canCancel: false).flowIn(3) }
                        footer
                    } else {
                        ForEach(0..<2, id: \.self) { _ in Card { Color.clear.frame(height: 130) }.redacted(reason: .placeholder).shimmer() }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .folioRefresh { await load() }
        }
        .navigationTitle("Bills & subscriptions")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: Cards

    private var totalCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Repeating charges").font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    CountingText(money(monthly)).font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit().sensitive()
                    Text("a month").font(.title3).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    stat(money(monthly * 12), "a year")
                    if !subs.isEmpty { stat(money(subsMonthly * 12), "on \(subs.count) subscription\(subs.count == 1 ? "" : "s") a year") }
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            CountingText(value).font(.subheadline.weight(.semibold)).monospacedDigit().sensitive()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var upcomingCard: some View {
        let due = upcoming.reduce(0) { $0 + $1.amount }
        return VStack(spacing: 8) {
            SectionTitle("Coming up", trailing: "\(money(due)) in 30 days")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(upcoming.enumerated()), id: \.element.uid) { i, u in
                        if i > 0 { Divider().padding(.leading, 70) }
                        HStack(spacing: 12) {
                            DateChip(date: u.date)
                            Text(u.name).font(.body).lineLimit(1)
                            Spacer(minLength: 8)
                            CountingText((u.estimated ? "~" : "") + money(u.amount, cents: true)).font(.body.weight(.medium)).monospacedDigit().sensitive()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                    }
                }
            }
        }
    }

    private func listCard(_ title: String, subtitle: String, rows: [RecurringItem], canCancel: Bool) -> some View {
        VStack(spacing: 8) {
            SectionTitle(title, trailing: subtitle)
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Divider().padding(.leading, 16) }
                        row(r, canCancel: canCancel)
                    }
                }
            }
        }
    }

    private func row(_ r: RecurringItem, canCancel: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(r.name).font(.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: 8)
                CountingText((r.estimated ? "~" : "") + money(r.amount, cents: true)).font(.body.weight(.semibold)).monospacedDigit().sensitive()
            }
            HStack {
                Text("\(r.frequencyLabel) · next \(shortDay(r.nextDate))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if r.frequency != "monthly" { CountingText("\(money(r.monthly, cents: true)) a month").font(.caption).foregroundStyle(.secondary).sensitive() }
            }
            if let p = r.priceChange, p.to > p.from {
                Label("Price went up \(money(p.to - p.from, cents: true)), from \(money(p.from, cents: true))", systemImage: "arrow.up.right.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu {
            if canCancel, let url = cancelURL(r.name) { Link(destination: url) { Label("How to cancel \(r.name)", systemImage: "questionmark.circle") } }
            Button(role: .destructive) { hide(r.id) } label: { Label("This isn't a bill", systemImage: "eye.slash") }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Text("Found automatically from your transactions, so it can miss a charge or guess an amount (marked with ~). Press and hold a row for options. Folio never contacts a company or cancels anything for you, and never takes a cut of what you save.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !hidden.isEmpty { Button("Show \(hidden.count) hidden", action: unhideAll).font(.footnote.weight(.semibold)) }
        }
        .padding(.horizontal, 12).padding(.top, 4)
    }

    // MARK: Helpers

    private func shortDay(_ s: String) -> String { (parseDay(s) ?? Date()).formatted(.dateTime.month(.abbreviated).day()) }

    private func cancelURL(_ name: String) -> URL? {
        let q = "how to cancel \(name)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(q)")
    }

    private func load() async {
        error = nil
        do {
            data = try await auth.withFreshToken(.recurring)
        } catch {
            if data == nil { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
        loaded = true
    }
}

/// "NOV / 12" date block used in lists of what's coming up.
struct DateChip: View {
    let date: String
    var body: some View {
        let d = parseDay(date) ?? Date()
        VStack(spacing: 0) {
            Text(d.formatted(.dateTime.month(.abbreviated)).uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.red)
            Text(d.formatted(.dateTime.day())).font(.system(size: 17, weight: .semibold, design: .rounded))
        }
        .frame(width: 42, height: 42)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

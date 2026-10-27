import SwiftUI
import Charts

struct OverviewView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var accounts: [Account] = []
    @State private var snapshots: [NetWorthSnapshot] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var chartRange = 90

    private var totalAssets: Decimal {
        accounts.filter(\.isAsset).reduce(0) { $0 + $1.currentBalance }
    }
    private var totalLiabilities: Decimal {
        accounts.filter(\.isLiability).reduce(0) { $0 + $1.currentBalance }
    }
    private var netWorth: Decimal { totalAssets - totalLiabilities }

    // Chart data oldest → newest
    private var chartData: [NetWorthSnapshot] { snapshots.reversed() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // ── Hero card ──────────────────────────────────────────────
                    VStack(spacing: 8) {
                        Text("Net Worth")
                            .font(.subheadline)
                            .tracking(1)
                            .foregroundStyle(Color.folioCream.opacity(0.7))

                        Text(netWorth.formatted(.currency(code: "USD")))
                            .font(.system(size: 42, weight: .bold, design: .serif))
                            .foregroundStyle(Color.folioCream)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)

                        HStack(spacing: 24) {
                            StatPill(label: "Assets", value: totalAssets, positive: true)
                            StatPill(label: "Liabilities", value: totalLiabilities, positive: false)
                        }
                        .padding(.top, 4)

                        // ── Sparkline ──────────────────────────────────────────
                        if !chartData.isEmpty {
                            NetWorthChart(data: chartData, range: $chartRange)
                                .padding(.top, 12)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.top, 36)
                    .padding(.bottom, 28)
                    .background(Color.folioSlate)

                    // ── Accounts ───────────────────────────────────────────────
                    if isLoading && accounts.isEmpty {
                        ProgressView()
                            .tint(Color.folioAmber)
                            .padding(40)
                    } else if let error {
                        ErrorBanner(message: error) { Task { await load() } }
                            .padding()
                    } else if accounts.isEmpty {
                        EmptyAccountsCard().padding()
                    } else {
                        VStack(spacing: 0) {
                            AccountSection(
                                title: "Cash & Investments",
                                accounts: accounts.filter(\.isAsset)
                            )
                            Divider().padding(.horizontal)
                            AccountSection(
                                title: "Liabilities",
                                accounts: accounts.filter(\.isLiability)
                            )
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Overview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.folioSlate, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    FolioMark(size: 24)
                }
            }
            .refreshable { await load() }
            .onChange(of: chartRange) {
                Task { await loadChart() }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        async let accountsTask: AccountsResponse = auth.withFreshToken(.accounts)
        async let chartTask: NetWorthHistoryResponse = auth.withFreshToken(.netWorthHistory(days: chartRange))
        do {
            let (acctResp, chartResp) = try await (accountsTask, chartTask)
            accounts = acctResp.accounts.filter { !$0.isHidden }
            snapshots = chartResp.snapshots
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    private func loadChart() async {
        do {
            let resp: NetWorthHistoryResponse = try await auth.withFreshToken(.netWorthHistory(days: chartRange))
            snapshots = resp.snapshots
        } catch {}
    }
}

// ── Sparkline chart ───────────────────────────────────────────────────────────

private struct NetWorthChart: View {
    let data: [NetWorthSnapshot]
    @Binding var range: Int

    // Parse ISO date strings into Double x-axis values for Chart
    private var points: [(x: Double, y: Double)] {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        return data.compactMap { snap in
            guard let date = parser.date(from: snap.date) else { return nil }
            return (x: date.timeIntervalSince1970, y: Double(truncating: snap.netWorthDecimal as NSDecimalNumber))
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Chart {
                ForEach(Array(points.enumerated()), id: \.0) { _, point in
                    LineMark(
                        x: .value("Date", point.x),
                        y: .value("Net Worth", point.y)
                    )
                    .foregroundStyle(Color.folioAmber)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Date", point.x),
                        yStart: .value("Base", (points.map(\.y).min() ?? 0) * 0.97),
                        yEnd: .value("Net Worth", point.y)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.folioAmber.opacity(0.3), Color.folioAmber.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartPlotStyle { plot in
                plot.frame(height: 72)
            }

            // Range picker
            HStack(spacing: 0) {
                ForEach([30, 90, 365], id: \.self) { days in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        range = days   // triggers .onChange in OverviewView
                    } label: {
                        Text(days == 30 ? "1M" : days == 90 ? "3M" : "1Y")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(range == days ? Color.folioSlate : Color.folioCream.opacity(0.5))
                            .frame(width: 40, height: 26)
                            .background(range == days ? Color.folioCream : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(3)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// ── Sub-components ────────────────────────────────────────────────────────────

private struct StatPill: View {
    let label: String
    let value: Decimal
    let positive: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.folioCream.opacity(0.6))
            Text(value.formatted(.currency(code: "USD")))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(positive ? Color.folioCream : Color.folioAmber)
        }
    }
}

private struct AccountSection: View {
    let title: String
    let accounts: [Account]

    var body: some View {
        if accounts.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .tracking(0.5)
                    .foregroundStyle(Color.folioSlate.opacity(0.5))
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 8)

                VStack(spacing: 0) {
                    ForEach(accounts) { account in
                        AccountRow(account: account)
                        if account.id != accounts.last?.id {
                            Divider().padding(.leading, 20)
                        }
                    }
                }
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }
}

private struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.primary)
                if let inst = account.institutionName {
                    Text(inst)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(account.displayBalance)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(account.isLiability ? Color.folioAmber : Color.primary)
                Text(account.typeLabel)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

struct EmptyAccountsCard: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(Color.folioAmber)
            Text("Connect your accounts")
                .font(.headline)
                .foregroundStyle(Color.folioSlate)
            Text("Link your bank to see your net worth, accounts, and spending in one place.")
                .font(.subheadline)
                .foregroundStyle(Color.folioSlate.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.folioAmber)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.folioSlate)
            Spacer()
            Button("Retry", action: retry)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.folioAmber)
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

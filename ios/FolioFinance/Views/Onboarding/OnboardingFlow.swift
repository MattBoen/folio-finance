import SwiftUI

struct OnboardingFlow: View {
    var onFinish: () -> Void

    enum Step: Int, CaseIterable { case welcome, plaid, connect, car, plan }

    @EnvironmentObject private var auth: AuthManager
    @State private var step: Step = .welcome
    @State private var accounts: [Account] = []
    @State private var showLink = false
    @State private var showManual = false
    @State private var autoOpenedLink = false
    @State private var editing: Account?
    @State private var removing: Account?

    var body: some View {
        ZStack {
            Wash(tone: .balance)
            VStack(spacing: 0) {
                header
                Group {
                    switch step {
                    case .welcome: WelcomeStep(next: { go(.plaid) })
                    case .plaid: PlaidExplainerStep(connect: { go(.connect) }, skip: { go(.car) })
                    case .connect:
                        ConnectStep(accounts: accounts, link: { showLink = true }, manual: { showManual = true },
                                    edit: { editing = $0 }, hide: { a in Task { await hide(a) } }, remove: { removing = $0 },
                                    next: { go(.car) })
                    case .car: CarStep(next: { go(.plan) })
                    case .plan: PlanStep(finish: onFinish)
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                .id(step)
            }
        }
        .sheet(isPresented: $showLink, onDismiss: { Task { await loadAccounts() } }) {
            PlaidLinkSheet(onLinked: { _ in Task { await loadAccounts() } })
        }
        .sheet(isPresented: $showManual) { AddAccountSheet { Task { await loadAccounts() } } }
        .sheet(item: $editing) { a in AccountEditSheet(account: a) { Task { await loadAccounts() } } }
        .confirmationDialog("Remove \(removing?.name ?? "account")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let a = removing { Task { await remove(a) } } }
        } message: { Text("It's removed from your net worth. You can add it again any time.") }
        .task { await loadAccounts() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if step != .welcome {
                Button { goBack() } label: { Image(systemName: "chevron.left").font(.subheadline.weight(.semibold)) }
                    .padding(.trailing, 4).transition(.opacity)
            }
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule().fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25)).frame(height: 4)
            }
            Button("Skip") { onFinish() }
                .font(.subheadline).foregroundStyle(.secondary).padding(.leading, 8)
        }
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 8)
    }

    /// Setup connects through Plaid by default: arriving at the connect step with no accounts opens it straight away.
    private func go(_ s: Step) {
        withAnimation(Motion.spring) { step = s }
        if s == .connect, accounts.isEmpty, !autoOpenedLink, !auth.isDemo {
            autoOpenedLink = true
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                if step == .connect { showLink = true }
            }
        }
    }

    private func goBack() {
        let prev: Step = switch step {
        case .welcome, .plaid: .welcome
        case .connect: .plaid
        case .car: .connect
        case .plan: .car
        }
        withAnimation(Motion.spring) { step = prev }
    }

    private func hide(_ a: Account) async {
        let _: AnyDecodable? = try? await auth.withFreshToken(.setAccountHidden(id: a.id, hidden: true))
        await loadAccounts()
    }

    private func remove(_ a: Account) async {
        let _: AnyDecodable? = try? await auth.withFreshToken(.deleteAccount(id: a.id))
        await loadAccounts()
    }

    private func loadAccounts() async {
        if let r: AccountsResponse = try? await auth.withFreshToken(.accounts) { accounts = r.accounts }
    }
}

// MARK: - Shared layout

private struct StepScaffold<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.system(size: 30, weight: .bold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                        if let subtitle { Text(subtitle).font(.body).foregroundStyle(.secondary) }
                    }
                    content()
                }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            VStack(spacing: 10) { footer() }
                .padding(.horizontal, 24).padding(.bottom, 16).padding(.top, 8)
        }
    }
}

private struct Pill: View {
    let symbol: String; let color: Color; let title: String; let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconBadge(symbol: symbol, color: color, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct PrimaryButton: View {
    let title: String; var loading = false; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Group { if loading { ProgressView().tint(.white) } else { Text(title).font(.headline) } }
                .frame(maxWidth: .infinity).frame(height: 30)
        }
        .buttonStyle(.borderedProminent).controlSize(.large).disabled(loading)
    }
}

private struct SecondaryButton: View {
    let title: String; let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).font(.headline).frame(maxWidth: .infinity).frame(height: 30) }
            .buttonStyle(.bordered).controlSize(.large)
    }
}

// MARK: - 1. Welcome

private struct WelcomeStep: View {
    let next: () -> Void
    var body: some View {
        StepScaffold(title: "Welcome to Folio", subtitle: "A calm, complete picture of your money. Setup takes about two minutes.") {
            VStack(spacing: 22) {
                BrandMark(size: 76).frame(maxWidth: .infinity)
                Pill(symbol: "square.stack.3d.up.fill", color: .blue, title: "Everything in one place", detail: "Bank accounts, cards, investments, loans and even your car.")
                Pill(symbol: "chart.line.uptrend.xyaxis", color: .green, title: "Know where you stand", detail: "Net worth, spending and trends that update on their own.")
                Pill(symbol: "checklist", color: .indigo, title: "A plan that fits you", detail: "Folio works out your income and usual spending, then drafts a budget you can change.")
            }
        } footer: {
            PrimaryButton(title: "Get started", action: next)
        }
    }
}

// MARK: - 2. Plaid explainer

private struct PlaidExplainerStep: View {
    let connect: () -> Void
    let skip: () -> Void
    var body: some View {
        StepScaffold(title: "Connect your accounts, safely", subtitle: "Folio uses Plaid, a secure service that many finance apps use to link to banks.") {
            VStack(alignment: .leading, spacing: 20) {
                Pill(symbol: "lock.shield.fill", color: .blue, title: "You sign in with your bank, not with us", detail: "Your bank username and password go to your bank. Folio never sees or stores them.")
                Pill(symbol: "eye.fill", color: .teal, title: "Read-only", detail: "Folio can see balances and transactions. It can't move money or make payments.")
                Pill(symbol: "hand.raised.fill", color: .indigo, title: "You're in control", detail: "Choose which accounts to share and disconnect any time in Accounts.")
                Pill(symbol: "externaldrive.fill.badge.checkmark", color: .green, title: "Encrypted and private", detail: "Your data is encrypted, never sold, and never used for ads.")
                VStack(alignment: .leading, spacing: 6) {
                    Text("By tapping Agree and continue, you allow Folio to use the account data you connect, as described in our Privacy Policy, and Plaid to share it with Folio.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("Read the Privacy Policy", destination: AppLinks.privacy).font(.footnote.weight(.semibold))
                }
            }
        } footer: {
            PrimaryButton(title: "Agree and continue", action: connect)
            Button("I'll add accounts myself", action: skip).font(.subheadline)
        }
    }
}

// MARK: - 3. Connect

private struct ConnectStep: View {
    let accounts: [Account]
    let link: () -> Void
    let manual: () -> Void
    let edit: (Account) -> Void
    let hide: (Account) -> Void
    let remove: (Account) -> Void
    let next: () -> Void

    var body: some View {
        StepScaffold(
            title: accounts.isEmpty ? "Add your accounts" : "\(accounts.count) account\(accounts.count == 1 ? "" : "s") added",
            subtitle: accounts.isEmpty ? "Link banks, cards and investments, or enter a balance by hand." : "Tap an account to rename it. Touch and hold to remove it. Add more, or keep going."
        ) {
            VStack(spacing: 14) {
                if !accounts.isEmpty {
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(accounts) { a in
                                Button { edit(a) } label: { AccountRow(account: a).contentShape(Rectangle()) }
                                    .buttonStyle(PressableRowStyle())
                                    .contextMenu {
                                        Button { edit(a) } label: { Label(a.isManual ? "Edit" : "Rename", systemImage: "pencil") }
                                        if a.isManual {
                                            Button(role: .destructive) { remove(a) } label: { Label("Remove", systemImage: "trash") }
                                        } else {
                                            Button(role: .destructive) { hide(a) } label: { Label("Don't include", systemImage: "eye.slash") }
                                        }
                                    }
                                if a.id != accounts.last?.id { Divider().padding(.leading, 62) }
                            }
                        }
                    }
                }
                Button(action: link) {
                    HStack(spacing: 12) {
                        IconBadge(symbol: "link", color: .blue, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connect a bank, card or brokerage").font(.headline)
                            Text("Secure, read-only, via Plaid").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(14).frame(maxWidth: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                Button(action: manual) {
                    HStack(spacing: 12) {
                        IconBadge(symbol: "square.and.pencil", color: .gray, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add an account by hand").font(.headline)
                            Text("Type in a balance. Good for loans and cash.").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(14).frame(maxWidth: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        } footer: {
            PrimaryButton(title: accounts.isEmpty ? "Not now" : "Continue", action: next)
        }
    }
}

// MARK: - 4. Car

private struct CarStep: View {
    let next: () -> Void
    @State private var added = 0

    var body: some View {
        StepScaffold(title: "Add your car", subtitle: "Optional. Look it up by VIN or enter the details yourself. It counts toward your net worth.") {
            CarEntryView { _ in added += 1 }
        } footer: {
            if added > 0 {
                PrimaryButton(title: "Continue", action: next)
            } else {
                Button("Skip for now", action: next).font(.subheadline)
            }
        }
    }
}

// MARK: - 5. Plan

private struct PlanStep: View {
    let finish: () -> Void
    @EnvironmentObject private var auth: AuthManager
    @State private var insights: Insights?
    @State private var stage = 0
    @State private var creating = false
    @State private var showIncome = false
    @State private var error: String?

    private let stages = ["Pulling in your transactions", "Finding your income", "Adding up your spending", "Drafting a budget"]

    var body: some View {
        StepScaffold(
            title: insights == nil ? "Building your plan" : "Here's what we found",
            subtitle: insights == nil ? "Looking at your recent activity." : nil
        ) {
            if let insights { summary(insights) } else { analyzing }
        } footer: {
            if let insights {
                if insights.budget.items.isEmpty {
                    PrimaryButton(title: "Finish", action: finish)
                } else {
                    PrimaryButton(title: "Create my budget", loading: creating) { Task { await create() } }
                    Button("Skip for now", action: finish).font(.subheadline)
                }
            }
        }
        .task { await run() }
        .sheet(isPresented: $showIncome) {
            IncomeSheet(current: insights?.income.monthly ?? 0, isManual: insights?.income.source == "manual") { Task { await reload() } }
        }
    }

    private var analyzing: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(stages.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 12) {
                        Group {
                            if i < stage { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.up) }
                            else if i == stage { ProgressView() }
                            else { Image(systemName: "circle").foregroundStyle(.tertiary) }
                        }
                        .frame(width: 24)
                        Text(s).font(.body).foregroundStyle(i <= stage ? .primary : .secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private func summary(_ i: Insights) -> some View {
        VStack(spacing: 14) {
            if i.dataQuality.transactionCount == 0 {
                EmptyStateCard(symbol: "clock", title: "Not enough activity yet", message: "Once your accounts have a few weeks of transactions, Folio fills in your plan automatically. You'll find it in the Budget tab.")
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Monthly income").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Button("Edit") { showIncome = true }.font(.subheadline.weight(.semibold))
                        }
                        Text(i.income.monthly > 0 ? money(i.income.monthly) : "Not found").font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
                        Text(i.income.sources.first.map { "Mostly from \($0.name)" } ?? "Add it yourself if we missed it").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Usual monthly spending").font(.subheadline).foregroundStyle(.secondary)
                        Text(money(i.outflow.monthlyAverage)).font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("\(money(i.outflow.fixed)) in bills and fixed costs, \(money(i.outflow.variable)) flexible").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !i.budget.items.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Suggested budget").font(.subheadline).foregroundStyle(.secondary)
                            Text("\(money(i.budget.total)) a month").font(.title2.bold())
                            ForEach(i.budget.items.prefix(5)) { b in
                                HStack { Text(b.category).font(.subheadline); Spacer(); Text(money(b.amount)).font(.subheadline.weight(.semibold)).monospacedDigit() }
                            }
                            if i.budget.items.count > 5 { Text("and \(i.budget.items.count - 5) more").font(.footnote).foregroundStyle(.secondary) }
                            Text("Based on what you actually spend, trimmed a little where there's room. You can change every number later.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
    }

    private func run() async {
        async let fetched: Insights? = fetchInsights()
        // The last step waits for the real answer, so the checklist never finishes before the work does.
        for s in 1..<stages.count { try? await Task.sleep(for: .milliseconds(650)); withAnimation { stage = s } }
        insights = await fetched
        withAnimation { stage = stages.count }
        if insights == nil { error = "Couldn't build your plan right now. You can find it later in the Budget tab." ; finish() }
    }

    /// A freshly linked bank needs a moment to hand over its history, so sync first and wait a little for it.
    private func fetchInsights() async -> Insights? {
        guard !auth.isDemo else { return try? await auth.withFreshToken(.insights) }
        let banks: PlaidItemsResponse? = try? await auth.withFreshToken(.plaidItems)
        let hasBanks = !(banks?.items.isEmpty ?? true)
        if hasBanks { await BankSync.run(auth, force: true) }
        var r: Insights? = try? await auth.withFreshToken(.insights)
        var tries = 0
        while hasBanks, let cur = r, cur.dataQuality.transactionCount == 0, tries < 4 {
            try? await Task.sleep(for: .seconds(4))
            if hasBanks { await BankSync.run(auth, force: true) }
            r = try? await auth.withFreshToken(.insights)
            tries += 1
        }
        return r
    }

    private func reload() async {
        if let r: Insights = try? await auth.withFreshToken(.insights) { insights = r }
    }

    private func create() async {
        creating = true
        do {
            let _: BudgetsResponse = try await auth.withFreshToken(.generateBudget)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            finish()
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        creating = false
    }
}

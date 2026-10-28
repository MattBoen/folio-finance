import SwiftUI

/// Whether the customer has turned Ask on, shared by the Ask tab and the profile menu.
@MainActor
final class AskState: ObservableObject {
    static let shared = AskState()
    @Published var enabled = false
    @Published var loaded = false
    @Published var dailyLimit: Int?
    @Published var usedToday: Int?
    /// A question another screen asked us to send (the "Ask Folio" buttons around the app).
    @Published var pending: String?

    /// Opens the Ask tab and sends `question` there (after the user turns Ask on, if it's off).
    func ask(_ question: String, router: TabRouter) {
        pending = question
        router.selected = .ask
    }

    func load(auth: AuthManager) async {
        if auth.isDemo { loaded = true; return }
        if let s: AskSettings = try? await auth.withFreshToken(.askSettings) {
            enabled = s.enabled
            dailyLimit = s.dailyLimit
            usedToday = s.usedToday
        }
        loaded = true
    }

    func set(_ on: Bool, auth: AuthManager) async -> String? {
        if auth.isDemo { enabled = on; return nil }
        do {
            let s: AskSettings = try await auth.withFreshToken(.setAskEnabled(on))
            enabled = s.enabled
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct AskView: View {
    @EnvironmentObject private var auth: AuthManager
    @ObservedObject private var state = AskState.shared

    @State private var messages: [AskMessage] = []
    @State private var draft = ""
    @State private var thinking = false
    @State private var enabling = false
    @State private var enableError: String?
    @FocusState private var focused: Bool

    private let suggestions = [
        "What's my budget?",
        "How much did I spend on dining this month?",
        "What's my savings rate?",
        "How am I doing vs the S&P 500?",
        "Can you raise my groceries budget?",
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Wash(tone: .plan)
                if !state.loaded {
                    ProgressView().controlSize(.large)
                } else if !state.enabled {
                    ScrollView { intro.padding(.horizontal, 16).padding(.bottom, 24) }.scrollIndicators(.hidden)
                } else {
                    chat
                }
            }
            .navigationTitle("Ask Folio")
            .toolbar {
                if state.enabled && !messages.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { withAnimation(.smooth) { messages = [] } } label: { Image(systemName: "square.and.pencil") }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { ProfileMenu() }
            }
        }
        .task { await state.load(auth: auth); sendPending() }
        .onChange(of: state.pending) { sendPending() }
        .onChange(of: state.enabled) { sendPending() }
    }

    private func sendPending() {
        guard state.enabled, let q = state.pending, !thinking else { return }
        state.pending = nil
        send(q)
    }

    // MARK: Opt-in

    private var intro: some View {
        VStack(spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    IconBadge(symbol: "text.bubble.fill", color: Color.heroBottom, size: 46)
                    Text("Ask about your money").font(.title2.bold())
                    Text("Ask plain questions and get answers from your own numbers: your budget, what you spent at a place this month, your savings rate, how your investments are doing. It can also suggest a change, like a higher budget, and only makes it when you tap Confirm.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Label("How your data is used", systemImage: "hand.raised.fill").font(.headline)
                    Text("When you ask a question, Folio sends the relevant numbers from your accounts (balances, budgets, transactions) to Anthropic, the company that makes Claude, to write the answer. We don't send your name, email or bank logins. Your questions aren't saved on our servers.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Link("Read the Privacy Policy", destination: AppLinks.privacy).font(.subheadline.weight(.semibold))
                    Text("Ask is off until you turn it on, and you can turn it off any time from the profile menu.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let q = state.pending {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your question").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(q).font(.subheadline)
                        Text("Turn on Ask and it's sent right away.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let enableError { Text(enableError).font(.footnote).foregroundStyle(.red) }
            Button {
                Task {
                    enabling = true
                    enableError = await state.set(true, auth: auth)
                    enabling = false
                    if enableError == nil { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                }
            } label: {
                Group { if enabling { ProgressView().tint(.white) } else { Text("Turn on Ask").font(.headline) } }
                    .frame(maxWidth: .infinity).frame(height: 30)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(enabling)
            Text("Not now? Just leave this tab. Nothing is sent.").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    // MARK: Chat

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if messages.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Try asking").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            FlowChips(items: suggestions) { send($0) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    }
                    ForEach($messages) { $m in
                        MessageView(message: $m, onConfirm: { confirm($m.id) }, onDismiss: { dismiss($m.id) })
                            .id(m.id)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                    if thinking { TypingBubble().id("typing").transition(.opacity) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { withAnimation(.smooth) { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: thinking) { withAnimation(.smooth) { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about your money", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { send(draft) }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button { send(draft) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || thinking)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    private func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thinking else { return }
        draft = ""
        withAnimation(.smooth) { messages.append(AskMessage(role: .user, text: text)) }
        thinking = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let history = messages.filter { !$0.isError }.suffix(10).map { (role: $0.role.rawValue, content: $0.text) }
        Task {
            defer { thinking = false }
            do {
                let r: AskResponse = try await auth.withFreshToken(.ask(messages: history))
                withAnimation(.smooth) {
                    messages.append(AskMessage(role: .assistant, text: r.answer, facts: r.facts ?? [], proposal: r.proposal))
                }
                if let used = state.usedToday { state.usedToday = used + 1 }
            } catch {
                withAnimation(.smooth) { messages.append(AskMessage(role: .assistant, text: Self.friendly(error), isError: true)) }
            }
        }
    }

    private static func friendly(_ error: Error) -> String {
        if case APIError.server(let code, let msg) = error {
            if code == 503 { return "Ask isn't available right now. Please try again in a bit." }
            if code == 429 { return msg ?? "You've reached today's limit for questions. It resets tomorrow." }
            if let msg { return msg }
        }
        return (error as? LocalizedError)?.errorDescription ?? "Something went wrong. Please try again."
    }

    private func confirm(_ id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }), let p = messages[i].proposal else { return }
        messages[i].proposalState = .confirming
        Task {
            do {
                let r: ConfirmResponse = try await auth.withFreshToken(.confirmProposal(id: p.id))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                NotificationCenter.default.post(name: .budgetsChanged, object: nil)
                if let j = messages.firstIndex(where: { $0.id == id }) {
                    withAnimation(.smooth) { messages[j].proposalState = .confirmed(r.message ?? "Budget updated.") }
                }
            } catch {
                if let j = messages.firstIndex(where: { $0.id == id }) {
                    withAnimation(.smooth) { messages[j].proposalState = .failed(Self.friendly(error)) }
                }
            }
        }
    }

    private func dismiss(_ id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }), let p = messages[i].proposal else { return }
        withAnimation(.smooth) { messages[i].proposalState = .dismissed }
        Task { let _: AnyDecodable? = try? await auth.withFreshToken(.dismissProposal(id: p.id)) }
    }
}

// MARK: - Pieces

private struct ConfirmResponse: Decodable { let message: String? }

extension Notification.Name {
    /// Posted when budgets change somewhere other than the Budget screen (for example from Ask Folio).
    static let budgetsChanged = Notification.Name("FolioBudgetsChanged")
}

/// A small button that hands a question to Ask Folio. Used on Budget, Spending and Investing.
struct AskFolioButton: View {
    let title: String
    let question: String
    var prominent = false
    @EnvironmentObject private var router: TabRouter
    @State private var tick = 0

    var body: some View {
        Button {
            tick += 1
            AskState.shared.ask(question, router: router)
        } label: {
            Label(title, systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: prominent ? .infinity : nil)
                .frame(height: prominent ? 30 : nil)
        }
        .buttonStyle(.bordered)
        .controlSize(prominent ? .large : .regular)
        .tint(Color.heroBottom)
        .sensoryFeedback(.selection, trigger: tick)
    }
}

private struct MessageView: View {
    @Binding var message: AskMessage
    var onConfirm: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(.body).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(message.text).font(.body).foregroundStyle(message.isError ? Color.secondary : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !message.facts.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Numbers used").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(message.facts) { f in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(f.label).font(.footnote).foregroundStyle(.secondary)
                                        Spacer(minLength: 8)
                                        Text(f.value).font(.footnote.weight(.medium)).monospacedDigit().sensitive()
                                    }
                                }
                            }
                        }
                    }
                }
                if let p = message.proposal { ProposalCard(proposal: p, state: message.proposalState, onConfirm: onConfirm, onDismiss: onDismiss) }
            }
            .padding(.trailing, 24)
        }
    }
}

struct ProposalCard: View {
    let proposal: AskProposal
    let state: AskMessage.ProposalState
    var onConfirm: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    IconBadge(symbol: "slider.horizontal.3", color: .blue, size: 30)
                    Text(proposal.title).font(.headline)
                }
                if let d = proposal.detail { Text(d).font(.subheadline).foregroundStyle(.secondary) }
                if let cur = proposal.currentAmount, let new = proposal.newAmount {
                    HStack(spacing: 8) {
                        Text("\(proposal.category.map { "\($0) budget" } ?? "Budget")").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Text(money(cur)).font(.subheadline).foregroundStyle(.secondary).strikethrough()
                        Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        Text(money(new)).font(.headline).monospacedDigit()
                    }
                }
                switch state {
                case .open:
                    HStack(spacing: 10) {
                        Button(action: onConfirm) { Text("Confirm").font(.headline).frame(maxWidth: .infinity).frame(height: 26) }
                            .buttonStyle(.borderedProminent)
                        Button(action: onDismiss) { Text("Not now").font(.headline).frame(maxWidth: .infinity).frame(height: 26) }
                            .buttonStyle(.bordered)
                    }
                case .confirming:
                    HStack { ProgressView(); Text("Updating…").font(.subheadline).foregroundStyle(.secondary) }
                case .confirmed(let m):
                    Label(m, systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Color.up)
                case .dismissed:
                    Label("No change made", systemImage: "minus.circle").font(.subheadline).foregroundStyle(.secondary)
                case .failed(let m):
                    VStack(alignment: .leading, spacing: 8) {
                        Label(m, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(.orange)
                        Button("Try again", action: onConfirm).font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }
}

private struct TypingBubble: View {
    @State private var phase = 0
    var body: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Color.secondary).frame(width: 8, height: 8)
                        .opacity(phase == i ? 1 : 0.3)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(.regularMaterial, in: Capsule())
            Spacer()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.easeInOut(duration: 0.2)) { phase = (phase + 1) % 3 }
            }
        }
    }
}

/// Suggested questions as wrapping tappable capsules.
private struct FlowChips: View {
    let items: [String]
    var tap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { q in
                Button { tap(q) } label: {
                    Text(q).font(.subheadline)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                }
                .buttonStyle(PressableCardStyle())
            }
        }
    }
}

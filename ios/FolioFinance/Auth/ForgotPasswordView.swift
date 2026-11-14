import SwiftUI

/// Two short steps: we email a 6-digit code, then they type it with a new password. It signs them in when it works.
struct ForgotPasswordView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var email: String
    @State private var code = ""
    @State private var password = ""
    @State private var step: Step = .email
    @State private var working = false
    @State private var error: String?
    @State private var resentAt: Date?
    @FocusState private var focus: Field?

    private enum Step { case email, code }
    private enum Field { case email, code, password }

    init(email: String) { _email = State(initialValue: email) }

    private var emailOK: Bool { email.contains("@") && email.contains(".") }
    private var canReset: Bool { code.count == 6 && password.count >= 8 && !working }

    var body: some View {
        NavigationStack {
            ZStack {
                Wash(tone: .balance)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(step == .email ? "Reset your password" : "Check your email")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                            Text(step == .email
                                 ? "Enter the email you signed up with and we'll send you a 6-digit code."
                                 : "If \(email) has a Folio account, a code is on its way. It works for 15 minutes.")
                                .font(.body).foregroundStyle(.secondary)
                        }

                        if step == .email { emailStep } else { codeStep }

                        if let error { Label(error, systemImage: "exclamationmark.circle.fill").font(.footnote).foregroundStyle(.red) }
                    }
                    .padding(24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
        .onAppear { focus = .email }
    }

    private var emailStep: some View {
        VStack(spacing: 14) {
            Card(padding: 0) {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress).textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.send).focused($focus, equals: .email)
                    .onSubmit { Task { await sendCode() } }
                    .padding(16)
            }
            bigButton("Send code", enabled: emailOK && !working) { await sendCode() }
        }
    }

    private var codeStep: some View {
        VStack(spacing: 14) {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    TextField("6-digit code", text: $code)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        .focused($focus, equals: .code)
                        .onChange(of: code) { _, v in code = String(v.filter(\.isNumber).prefix(6)) }
                        .padding(16)
                    Divider().padding(.leading, 16)
                    SecureField("New password (8 or more characters)", text: $password)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .password)
                        .submitLabel(.go).onSubmit { Task { await reset() } }
                        .padding(16)
                }
            }
            bigButton("Set new password", enabled: canReset) { await reset() }
            HStack(spacing: 16) {
                Button("Send a new code") { Task { await sendCode(resend: true) } }.disabled(working)
                Button("Change email") { error = nil; code = ""; step = .email; focus = .email }
            }
            .font(.subheadline.weight(.semibold))
            Text("Not there? Check spam. We'll never ask you for this code by phone, text or email.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func bigButton(_ title: String, enabled: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Group { if working { ProgressView().tint(.white) } else { Text(title).font(.headline) } }
                .frame(maxWidth: .infinity).frame(height: 30)
        }
        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!enabled)
    }

    private func sendCode(resend: Bool = false) async {
        guard emailOK, !working else { return }
        if resend, let r = resentAt, Date().timeIntervalSince(r) < 20 { error = "Give it a moment before asking again."; return }
        working = true; error = nil
        do {
            try await auth.requestResetCode(email: email)
            resentAt = Date()
            withAnimation(Motion.spring) { step = .code }
            focus = .code
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        working = false
    }

    private func reset() async {
        guard canReset else { return }
        working = true; error = nil
        do {
            try await auth.resetPassword(email: email, code: code, password: password)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        working = false
    }
}

import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var auth: AuthManager

    @State private var email = ""
    @State private var password = ""
    @State private var slow = false
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool { email.contains("@") && !password.isEmpty && !auth.isLoading }

    var body: some View {
        ZStack {
            Wash(tone: .balance)

            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        BrandMark(size: 92)
                        VStack(spacing: 4) {
                            Text("Folio")
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                            Text("Your whole financial picture, in one place.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 56)

                    VStack(spacing: 12) {
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                TextField("Email", text: $email)
                                    .keyboardType(.emailAddress)
                                    .textContentType(.username)
                                    .accessibilityIdentifier("email")
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.next)
                                    .focused($focus, equals: .email)
                                    .onSubmit { focus = .password }
                                    .padding(16)
                                Divider().padding(.leading, 16)
                                SecureField("Password", text: $password)
                                    .textContentType(.password)
                                    .submitLabel(.go)
                                    .focused($focus, equals: .password)
                                    .onSubmit(submit)
                                    .padding(16)
                            }
                        }

                        if let error = auth.error {
                            Label(error, systemImage: "exclamationmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6)
                        }

                        Button(action: submit) {
                            Group {
                                if auth.isLoading {
                                    ProgressView().tint(.white)
                                } else {
                                    Text("Continue").font(.headline)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canSubmit)

                        if slow && auth.isLoading {
                            Label("Waking up the server. The first request after a while can take up to a minute.", systemImage: "clock")
                                .font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
                        }

                        Button {
                            auth.startDemo()
                        } label: {
                            Text("Explore with sample data")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 30)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    .padding(.horizontal, 20)

                    Text("New here? Just enter your email and a password. We'll set up your account.\nBy continuing you agree to our [Privacy Policy](\(AppLinks.privacy.absoluteString)).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .task(id: auth.isLoading) {
                slow = false
                guard auth.isLoading else { return }
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { slow = true }
            }
        }
        .confirmationDialog(
            "Create your Folio account?",
            isPresented: Binding(get: { auth.pendingNewAccount != nil }, set: { if !$0 { auth.pendingNewAccount = nil } }),
            titleVisibility: .visible
        ) {
            Button("Create account") {
                // The dialog clears the pending email as it closes, so use what's in the field.
                let e = email, p = password
                Task { await auth.createAccountAfterConfirm(email: e, password: p) }
            }
            Button("Edit email", role: .cancel) { focus = .email }
        } message: {
            Text("We don't see an account for \(auth.pendingNewAccount ?? "this email") yet. Create one with the password you entered?")
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        Task { await auth.continueWithEmail(email: email, password: password) }
    }
}

import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var auth: AuthManager

    @State private var email = ""
    @State private var password = ""
    @State private var isRegistering = false
    @State private var slow = false
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool {
        email.contains("@") && password.count >= (isRegistering ? 8 : 1) && !auth.isLoading
    }

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
                                    .textContentType(.emailAddress)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.next)
                                    .focused($focus, equals: .email)
                                    .onSubmit { focus = .password }
                                    .padding(16)
                                Divider().padding(.leading, 16)
                                SecureField(isRegistering ? "Password (8+ characters)" : "Password", text: $password)
                                    .textContentType(isRegistering ? .newPassword : .password)
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
                                    Text(isRegistering ? "Create account" : "Sign in")
                                }
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canSubmit)

                        if slow && auth.isLoading {
                            Label("Waking up the server. The first sign-in after a while can take up to a minute.", systemImage: "clock")
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

                    Button {
                        withAnimation(.snappy) { isRegistering.toggle() }
                        auth.clearError()
                    } label: {
                        HStack(spacing: 4) {
                            Text(isRegistering ? "Already have an account?" : "New to Folio?")
                                .foregroundStyle(.secondary)
                            Text(isRegistering ? "Sign in" : "Create an account")
                                .fontWeight(.semibold)
                        }
                        .font(.subheadline)
                    }
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
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        Task {
            if isRegistering {
                await auth.register(email: email, password: password)
            } else {
                await auth.login(email: email, password: password)
            }
        }
    }
}

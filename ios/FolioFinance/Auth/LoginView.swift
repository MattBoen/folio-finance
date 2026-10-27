import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var auth: AuthManager

    @State private var email = ""
    @State private var password = ""
    @State private var isRegistering = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // ── Brand mark ────────────────────────────────────────────
                    VStack(spacing: 16) {
                        FolioMark(size: 64)
                        VStack(spacing: 4) {
                            Text("Folio")
                                .font(.system(size: 32, weight: .bold, design: .serif))
                                .foregroundStyle(Color.folioSlate)
                            Text("FINANCE")
                                .font(.system(size: 13, weight: .medium, design: .default))
                                .tracking(3)
                                .foregroundStyle(Color.folioSlate.opacity(0.6))
                        }
                    }
                    .padding(.top, 64)
                    .padding(.bottom, 48)

                    // ── Form ──────────────────────────────────────────────────
                    VStack(spacing: 16) {
                        FolioTextField(
                            placeholder: "Email address",
                            text: $email,
                            keyboardType: .emailAddress,
                            textContentType: .emailAddress
                        )

                        FolioTextField(
                            placeholder: "Password",
                            text: $password,
                            textContentType: isRegistering ? .newPassword : .password,
                            isSecure: true
                        )

                        if let error = auth.error {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }

                        Button {
                            Task {
                                if isRegistering {
                                    await auth.register(email: email, password: password)
                                } else {
                                    await auth.login(email: email, password: password)
                                }
                            }
                        } label: {
                            Group {
                                if auth.isLoading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Text(isRegistering ? "Create account" : "Sign in")
                                        .fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                        }
                        .buttonStyle(.folioFilled)
                        .disabled(email.isEmpty || password.isEmpty || auth.isLoading)
                    }
                    .padding(.horizontal, 24)

                    // ── Toggle ────────────────────────────────────────────────
                    Button {
                        isRegistering.toggle()
                        auth.clearError()
                    } label: {
                        HStack(spacing: 4) {
                            Text(isRegistering ? "Already have an account?" : "Don't have an account?")
                                .foregroundStyle(Color.secondary)
                            Text(isRegistering ? "Sign in" : "Sign up")
                                .foregroundStyle(Color.folioAmber)
                                .fontWeight(.semibold)
                        }
                        .font(.subheadline)
                    }
                    .padding(.top, 24)
                }
                .padding(.bottom, 40)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationBarHidden(true)
        }
    }
}

// ── Folio mark (folded-page icon) ────────────────────────────────────────────

struct FolioMark: View {
    let size: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            let w = size * 0.8
            let h = size
            let fold = size * 0.275

            // Body
            var body = Path()
            let r: CGFloat = size * 0.1
            body.move(to: CGPoint(x: r, y: 0))
            body.addLine(to: CGPoint(x: w - fold, y: 0))
            body.addLine(to: CGPoint(x: w, y: fold))
            body.addLine(to: CGPoint(x: w, y: h - r))
            body.addArc(
                center: CGPoint(x: w - r, y: h - r),
                radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
            )
            body.addLine(to: CGPoint(x: r, y: h))
            body.addArc(
                center: CGPoint(x: r, y: h - r),
                radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
            )
            body.addLine(to: CGPoint(x: 0, y: r))
            body.addArc(
                center: CGPoint(x: r, y: r),
                radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
            )
            body.closeSubpath()
            ctx.fill(body, with: .color(Color.folioSlate))

            // Fold triangle
            var triangle = Path()
            triangle.move(to: CGPoint(x: w - fold, y: 0))
            triangle.addLine(to: CGPoint(x: w, y: fold))
            triangle.addLine(to: CGPoint(x: w - fold, y: fold))
            triangle.closeSubpath()
            ctx.fill(triangle, with: .color(Color.folioAmber))
        }
        .frame(width: size * 0.8, height: size)
    }
}

// ── Text field ────────────────────────────────────────────────────────────────

struct FolioTextField: View {
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType? = nil
    var isSecure: Bool = false

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .textContentType(textContentType)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(UIColor.separator), lineWidth: 0.5)
        )
    }
}

// ── Button style ──────────────────────────────────────────────────────────────

struct FolioFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.folioSlate)
                    .opacity(configuration.isPressed ? 0.8 : 1)
            )
    }
}

extension ButtonStyle where Self == FolioFilledButtonStyle {
    static var folioFilled: FolioFilledButtonStyle { .init() }
}

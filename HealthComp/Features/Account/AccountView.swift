import AuthenticationServices
import ComposableArchitecture
import SwiftUI

struct AccountView: View {
    @Environment(\.colorScheme) private var colorScheme

    let store: StoreOf<AccountFeature>

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "figure.run.circle.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if store.mode == .settingUpProfile {
                TextField(
                    "Display name",
                    text: Binding(
                        get: { store.displayName },
                        set: { store.send(.displayNameChanged($0)) }
                    )
                )
                .textContentType(.nickname)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .padding(14)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                .onSubmit {
                    store.send(.submitDisplayNameButtonTapped)
                }
                .accessibilityIdentifier("account.display-name")
            }

            if let message = store.message {
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("account.message")
            }

            primaryButton
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .disabled(store.isRequestInFlight)
                .overlay {
                    if store.isRequestInFlight {
                        ProgressView().tint(
                            AccountProgressAppearance.tint(
                                for: store.mode,
                                colorScheme: colorScheme
                            )
                        )
                    }
                }
            Spacer()
        }
        .padding(24)
        .animation(.easeInOut(duration: 0.2), value: store.message)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch store.mode {
        case .signedOut:
            SignInWithAppleButton(
                style: AppleSignInAppearance.buttonStyle(for: colorScheme)
            ) {
                store.send(.signInButtonTapped)
            }
            .id(colorScheme)
            .accessibilityIdentifier("account.sign-in-with-apple")

        case .settingUpProfile:
            Button("Continue") {
                store.send(.submitDisplayNameButtonTapped)
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .accessibilityIdentifier("account.submit-display-name")

        case .launchFailure:
            Button("Try Again") {
                store.send(.retryButtonTapped)
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .accessibilityIdentifier("account.retry")

        case .authenticated:
            Button("Sign Out", role: .destructive) {
                store.send(.signOutButtonTapped)
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 50)
            .accessibilityIdentifier("account.sign-out")
        }
    }

    private var title: String {
        switch store.mode {
        case .signedOut: "Welcome to HealthComp"
        case .settingUpProfile: "Choose your display name"
        case .launchFailure: "Unable to connect"
        case .authenticated: "Account"
        }
    }

    private var subtitle: String {
        switch store.mode {
        case .signedOut:
            "Sign in to join private Activity competitions."
        case .settingUpProfile:
            "Your competitor will see this name. You can change it later."
        case .launchFailure:
            "Your local data is safe. Check your connection and retry."
        case .authenticated:
            "Signing out removes this profile’s local competition cache from this device."
        }
    }
}

enum AppleSignInAppearance {
    static func buttonStyle(
        for colorScheme: ColorScheme
    ) -> ASAuthorizationAppleIDButton.Style {
        colorScheme == .dark ? .white : .black
    }

}

enum AccountProgressAppearance {
    static func tint(
        for mode: AccountFeature.State.Mode,
        colorScheme: ColorScheme
    ) -> Color {
        switch mode {
        case .signedOut:
            colorScheme == .dark ? .black : .white
        case .settingUpProfile, .launchFailure:
            .white
        case .authenticated:
            .primary
        }
    }
}

private struct SignInWithAppleButton: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled

    let style: ASAuthorizationAppleIDButton.Style
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(
            authorizationButtonType: .signIn,
            authorizationButtonStyle: style
        )
        button.cornerRadius = 10
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.invoke),
            for: .touchUpInside
        )
        return button
    }

    func updateUIView(
        _ button: ASAuthorizationAppleIDButton,
        context: Context
    ) {
        context.coordinator.action = action
        button.isEnabled = isEnabled
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func invoke() {
            action()
        }
    }
}

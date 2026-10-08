import AuthenticationServices
import ComposableArchitecture
import SwiftUI

struct AccountView: View {
    @Environment(\.colorScheme) private var colorScheme

    let store: StoreOf<AccountFeature>

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if store.mode == .settingUpProfile {
                        displayNameField
                    }
                    if store.mode == .signedOut {
                        colorCodeCard
                    }
                    if let message = store.message {
                        Text(message.text)
                            .font(.callout)
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("account.message")
                    }
                    actions
                }
                .padding(24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Theme.ground)
        .task { store.send(.appeared) }
        .animation(.easeInOut(duration: 0.2), value: store.message)
    }

    private var header: some View {
        VStack(spacing: 16) {
            BrandMark()
                .frame(width: 120)
            VStack(spacing: 8) {
                Text(title)
                    .font(.largeTitle.weight(.heavy).width(.condensed))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var displayNameField: some View {
        HStack(spacing: 12) {
            Group {
                if let initial = displayNameInitial {
                    Text(initial)
                        .font(.headline.width(.condensed))
                        .foregroundStyle(Theme.you)
                } else {
                    Image(systemName: "person.fill")
                        .foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 34, height: 34)
            .background(Theme.control, in: Circle())
            .accessibilityHidden(true)

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
            .foregroundStyle(Theme.ink)
            .onSubmit {
                store.send(.submitDisplayNameButtonTapped)
            }
            .accessibilityIdentifier("account.display-name")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .themePanel(cornerRadius: 14)
    }

    private var displayNameInitial: String? {
        store.displayName.trimmingCharacters(in: .whitespaces).first
            .map { String($0).uppercased() }
    }

    // Teaches the one color rule before the first competition.
    private var colorCodeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("HOW TO READ IT")
            codeRow(
                "Your rings",
                "Move, Exercise and Stand. Raw Health data stays on this iPhone."
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    SlantedBar().fill(Theme.move).frame(width: 24, height: 4)
                    SlantedBar().fill(Theme.exercise).frame(width: 18, height: 4)
                        .padding(.leading, 4)
                    SlantedBar().fill(Theme.stand).frame(width: 22, height: 4)
                }
            }
            codeRow("Your score", "Amber is always you.") {
                SlantedBar().fill(Theme.youFill).frame(width: 22, height: 10)
            }
            codeRow(
                "Their points",
                "Competitors receive daily points, rounded Activity percentages and modes."
            ) {
                SlantedBar().fill(Theme.ink).frame(width: 12, height: 18)
                    .padding(.leading, 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .themePanel(cornerRadius: 18)
    }

    private func codeRow<Swatch: View>(
        _ title: String,
        _ detail: String,
        @ViewBuilder swatch: () -> Swatch
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            swatch()
                .frame(width: 28, alignment: .leading)
                .padding(.top, 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            primaryButton
                .disabled(store.isRequestInFlight)
                .overlay {
                    if store.isRequestInFlight {
                        ProgressView().tint(progressTint)
                    }
                }
            if store.mode == .signedOut, store.isBrowserSignInAvailable {
                Button("Sign in with Apple in Browser") {
                    store.send(.browserSignInButtonTapped)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(store.isRequestInFlight)
                .accessibilityIdentifier("account.sign-in-with-apple.browser")
            }
        }
    }

    // The Apple button and Sign Out keep the tested contrast rule; the
    // neutral primary buttons carry onInk content in both modes.
    private var progressTint: Color {
        switch store.mode {
        case .signedOut, .authenticated:
            AccountProgressAppearance.tint(for: store.mode, colorScheme: colorScheme)
        case .settingUpProfile, .launchFailure, .profileConflict:
            Theme.onInk
        }
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
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .accessibilityIdentifier("account.sign-in-with-apple")

        case .settingUpProfile:
            Button("Continue") {
                store.send(.submitDisplayNameButtonTapped)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("account.submit-display-name")

        case .launchFailure:
            Button("Try Again") {
                store.send(.retryButtonTapped)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("account.retry")

        case .profileConflict:
            Button("Use Another Account") {
                store.send(.signOutButtonTapped)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("account.recover-profile")

        case .authenticated:
            Button("Sign Out", role: .destructive) {
                store.send(.signOutButtonTapped)
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier("account.sign-out")
        }
    }

    private var title: String {
        switch store.mode {
        case .signedOut: "Welcome to HealthComp"
        case .settingUpProfile: "Choose your display name"
        case .launchFailure: "Unable to connect"
        case .profileConflict: "Sign in with the original account"
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
        case .profileConflict:
            "Only this device’s session will be signed out. Saved history and your other devices are unchanged."
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
        case .settingUpProfile, .launchFailure, .profileConflict:
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
        button.cornerRadius = 14
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

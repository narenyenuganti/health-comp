import AuthenticationServices
import ComposableArchitecture
import SwiftUI

struct AccountView: View {
    @Environment(\.colorScheme) private var colorScheme

    let store: StoreOf<AccountFeature>
    /// A challenge link arrived before sign-in.
    var hasPendingChallenge = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if store.mode == .settingUpProfile {
                        displayNameField
                            .transition(Motion.appear)
                    }
                    // Launch failure and profile conflict fold the message
                    // into the subtitle.
                    if store.mode == .signedOut || store.mode == .settingUpProfile,
                       let message = store.message {
                        Text(message.text)
                            .font(.callout)
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("account.message")
                            .transition(Motion.appear)
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
        .moving(Motion.settle, value: store.mode)
        .moving(Motion.settle, value: store.message)
        .moving(Motion.settle, value: hasPendingChallenge)
        .sensoryFeedback(.error, trigger: store.message, condition: Self.isFailure)
    }

    /// Account deleted and session ended report something already done.
    private static func isFailure(
        _: AccountFeature.Message?,
        _ new: AccountFeature.Message?
    ) -> Bool {
        switch new {
        case nil, .accountDeleted, .sessionEnded: false
        default: true
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            BrandMark(grows: true)
                .frame(width: 120)
            VStack(spacing: 8) {
                Text(title)
                    .font(.largeTitle.weight(.heavy).width(.condensed))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .contentTransition(.opacity)
                    .animation(Motion.fade, value: title)
                if let subtitle {
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("account.subtitle")
                        .contentTransition(.opacity)
                        .animation(Motion.fade, value: subtitle)
                        .transition(Motion.appear)
                }
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

    private var actions: some View {
        VStack(spacing: 12) {
            // A ZStack, so two buttons never stack during the crossfade.
            ZStack {
                primaryButton
                    .transition(Motion.appear)
            }
            .disabled(store.isRequestInFlight)
            if store.mode == .signedOut, store.isBrowserSignInAvailable {
                Button("Sign in with Apple in Browser") {
                    store.send(.browserSignInButtonTapped)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(store.isRequestInFlight)
                .accessibilityIdentifier("account.sign-in-with-apple.browser")
            }
            Link(destination: URL(string: "https://healthcomp.app/privacy")!) {
                // 48, not 44: centered content can land on a fractional
                // origin and round the target below 44 pt.
                Text("Privacy Policy")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("account.privacy-policy")
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
            Button {
                store.send(.submitDisplayNameButtonTapped)
            } label: {
                BusyLabel("Continue", isBusy: store.isRequestInFlight)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("account.submit-display-name")

        case .launchFailure:
            Button {
                store.send(.retryButtonTapped)
            } label: {
                BusyLabel("Try Again", isBusy: store.isRequestInFlight)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("account.retry")

        case .profileConflict:
            Button {
                store.send(.signOutButtonTapped)
            } label: {
                BusyLabel("Sign Out to Switch", isBusy: store.isRequestInFlight)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("account.recover-profile")

        case .authenticated:
            Button(role: .destructive) {
                store.send(.signOutButtonTapped)
            } label: {
                BusyLabel("Sign Out", isBusy: store.isRequestInFlight)
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier("account.sign-out")
        }
    }

    private var title: String {
        switch store.mode {
        case .signedOut:
            hasPendingChallenge ? "You have a challenge" : "Welcome to HealthComp"
        case .settingUpProfile: "Choose your display name"
        case .launchFailure: store.message?.failureTitle ?? "Couldn’t connect"
        case .profileConflict: "This iPhone has history for another account"
        case .authenticated: "Account"
        }
    }

    private var subtitle: String? {
        switch store.mode {
        case .signedOut:
            hasPendingChallenge ? "Sign in with the account it was sent to." : nil
        case .settingUpProfile:
            // A new account can't be a challenge's recipient.
            "The people you play will see this name. You can change it later."
        case .launchFailure:
            store.message?.text ?? "Check your connection and try again."
        case .profileConflict:
            "Only this iPhone is signed out. Saved history and your other devices are unchanged."
        case .authenticated:
            nil
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

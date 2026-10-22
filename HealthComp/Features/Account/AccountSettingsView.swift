import ComposableArchitecture
import SwiftUI

/// What Account → Notifications needs from the competition. Hosts without
/// competition state pass nil, which hides the row.
struct AccountNotificationSettings {
    let authorization: CompetitionNotificationAuthorizationState?
    let isRequestInFlight: Bool
    let request: () -> Void

    var statusText: String {
        authorization?.permitsNotifications == true ? "On" : "Off"
    }
}

/// A short list; each setting opens its own page so explanations don't
/// stack up here.
struct AccountSettingsView: View {
    let store: StoreOf<AccountFeature>
    var notifications: AccountNotificationSettings?
    var accountCode: UUID?

    @AppStorage(AppAppearance.storageKey)
    private var appearance = AppAppearance.system

    var body: some View {
        List {
            profileSection
            settingsSection
            signOutSection
            deleteSection
        }
        .accountPageStyle(title: "Account")
        .task { store.send(.appeared) }
        .overlay {
            AccountProgressOverlay(store: store)
        }
    }

    private var profileSection: some View {
        Section {
            if store.isEditingDisplayName {
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
                .submitLabel(.done)
                .onSubmit {
                    store.send(.saveDisplayNameButtonTapped)
                }
                .accessibilityIdentifier("account.settings.display-name")

                HStack(spacing: 12) {
                    Button("Cancel", role: .cancel) {
                        store.send(.cancelDisplayNameButtonTapped)
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button("Save") {
                        store.send(.saveDisplayNameButtonTapped)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier(
                        "account.settings.save-display-name"
                    )
                }
                .disabled(store.isRequestInFlight)
            } else {
                HStack(spacing: 14) {
                    Text(store.displayName.first.map { String($0).uppercased() } ?? "")
                        .font(.title3.weight(.heavy).width(.condensed))
                        .foregroundStyle(Theme.you)
                        .frame(width: 44, height: 44)
                        .background(Theme.control, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.displayName)
                            .font(.title3.weight(.bold).width(.condensed))
                            .foregroundStyle(Theme.you)
                            .multilineTextAlignment(.leading)
                        Text("Display name · shown to competitors")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Display name, \(store.displayName)"
                )

                Button("Edit Display Name") {
                    store.send(.editDisplayNameButtonTapped)
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier(
                    "account.settings.edit-display-name"
                )
            }

            if let message = store.message {
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("account.message")
            }
            if let accountCode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("HealthComp account code")
                        .font(.headline)
                    Text(accountCode.uuidString.lowercased())
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Share this code with someone you want to compete with. It lets them confirm your display name and invite only this account; it does not grant access to your competition history.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                    ShareLink(item: accountCode.uuidString.lowercased()) {
                        Label("Share Account Code", systemImage: "square.and.arrow.up")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("account.settings.share-account-code")
                }
            }
        } header: {
            SectionLabel("PROFILE")
        }
        .listRowBackground(Theme.panel)
    }

    private var settingsSection: some View {
        Section {
            NavigationLink {
                AccountAppearancePage()
            } label: {
                LabeledContent {
                    Text(appearance.title)
                } label: {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                }
            }
            .accessibilityIdentifier("account.appearance")

            if let notifications {
                NavigationLink {
                    AccountNotificationsPage(settings: notifications)
                } label: {
                    LabeledContent {
                        Text(notifications.statusText)
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                }
                .accessibilityIdentifier("account.notifications")
            }

            NavigationLink {
                AccountPrivacyPage()
            } label: {
                Label("Privacy", systemImage: "lock")
            }
            .accessibilityIdentifier("account.privacy")

#if HEALTHCOMP_STAGING
            NavigationLink {
                StagingScoringDiagnosticPage()
            } label: {
                Label("Staging Diagnostics", systemImage: "stethoscope")
            }
            .accessibilityIdentifier("account.staging-diagnostics")
#endif
        }
        .listRowBackground(Theme.panel)
    }

    // Red means Move, so the destructive actions keep their role but stay neutral.
    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                store.send(.signOutButtonTapped)
            } label: {
                Text("Sign Out").foregroundStyle(Theme.ink)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(store.isRequestInFlight)
            .accessibilityIdentifier("account.sign-out")
            .accessibilityValue(
                store.isRequestInFlight ? "Signing out" : ""
            )
        } footer: {
            Text(
                "Signing out removes this profile’s local competition cache from this device. Completed shared history remains on the server."
            )
            .foregroundStyle(Theme.secondary)
        }
        .listRowBackground(Theme.panel)
    }

    private var deleteSection: some View {
        Section {
            NavigationLink {
                AccountDeletionPage(store: store)
            } label: {
                Text("Delete Account").foregroundStyle(Theme.ink)
            }
            .accessibilityIdentifier("account.delete.open")
        }
        .listRowBackground(Theme.panel)
    }
}

private struct AccountAppearancePage: View {
    @AppStorage(AppAppearance.storageKey)
    private var appearance = AppAppearance.system

    var body: some View {
        List {
            Section {
                AppearancePicker(selection: $appearance)
            } footer: {
                Text("System follows your iPhone’s setting.")
                    .foregroundStyle(Theme.secondary)
            }
            .listRowBackground(Theme.panel)
        }
        .accountPageStyle(title: "Appearance")
    }
}

private struct AccountNotificationsPage: View {
    let settings: AccountNotificationSettings

    var body: some View {
        List {
            Section {
                LabeledContent(
                    "Competition notifications",
                    value: settings.statusText
                )
                switch settings.authorization {
                case .notDetermined:
                    Button(action: settings.request) {
                        if settings.isRequestInFlight {
                            ProgressView()
                        } else {
                            Label(
                                "Enable Competition Notifications",
                                systemImage: "bell.badge.fill"
                            )
                        }
                    }
                    .frame(minHeight: 44)
                    .disabled(settings.isRequestInFlight)
                    .accessibilityIdentifier("competition.notifications.enable")

                case .denied:
                    Label(
                        "Competition notifications are disabled in Settings.",
                        systemImage: "bell.slash.fill"
                    )
                    .foregroundStyle(Theme.secondary)

                case .authorized, .provisional, .ephemeral, nil:
                    EmptyView()
                }
            } footer: {
                Text(
                    "HealthComp only sends competition moments, like lead changes and results. To mute someone, open your match with them."
                )
                .foregroundStyle(Theme.secondary)
            }
            .listRowBackground(Theme.panel)
        }
        .accountPageStyle(title: "Notifications")
    }
}

private struct AccountPrivacyPage: View {
    var body: some View {
        List {
            Section {
                Label(
                    "Raw Health data stays on this iPhone",
                    systemImage: "lock.iphone"
                )
                Label(
                    "Competitors receive daily points, rounded Activity percentages and modes",
                    systemImage: "person.2.shield"
                )
            }
            .listRowBackground(Theme.panel)
        }
        .accountPageStyle(title: "Privacy")
    }
}

// Red means Move, so the destructive action keeps its role but stays neutral.
private struct AccountDeletionPage: View {
    let store: StoreOf<AccountFeature>

    var body: some View {
        List {
            Section {
                Button(role: .destructive) {
                    store.send(.deleteAccountButtonTapped)
                } label: {
                    Text("Delete Account").foregroundStyle(Theme.ink)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(store.isRequestInFlight)
                .accessibilityIdentifier("account.delete")
                .accessibilityValue(
                    store.isDeletingAccount ? "Deleting account" : ""
                )
                if let message = store.message {
                    Text(message.text)
                        .font(.callout)
                        .foregroundStyle(Theme.ink)
                        .accessibilityIdentifier("account.message")
                }
            } footer: {
                Text(
                    "Deletion is permanent. Active competitions are cancelled, this profile’s local data is removed, and completed shared history remains for the other participant as Former competitor."
                )
                .foregroundStyle(Theme.secondary)
            }
            .listRowBackground(Theme.panel)
        }
        .accountPageStyle(title: "Delete Account")
        .overlay {
            AccountProgressOverlay(store: store)
        }
        .alert(
            "Delete Account?",
            isPresented: Binding(
                get: { store.isDeleteConfirmationPresented },
                set: { isPresented in
                    if !isPresented && store.isDeleteConfirmationPresented {
                        store.send(.deleteAccountConfirmationCancelled)
                    }
                }
            )
        ) {
            Button("Delete Account", role: .destructive) {
                store.send(.deleteAccountConfirmationAccepted)
            }
            .accessibilityIdentifier("account.delete.confirm")
            if store.isBrowserDeletionAvailable {
                Button("Delete with Apple in Browser", role: .destructive) {
                    store.send(.browserDeleteConfirmationAccepted)
                }
                .accessibilityIdentifier("account.delete.browser.confirm")
            }
            Button("Cancel", role: .cancel) {
                store.send(.deleteAccountConfirmationCancelled)
            }
        } message: {
            Text(
                "You will confirm with Sign in with Apple. This permanently deletes your account and cannot be undone."
            )
        }
    }
}

private struct AccountProgressOverlay: View {
    let store: StoreOf<AccountFeature>

    var body: some View {
        if store.isRequestInFlight {
            ProgressView()
                .tint(Theme.ink)
                .accessibilityLabel(
                    store.isDeletingAccount
                        ? "Deleting account"
                        : "Saving account changes"
                )
        }
    }
}

#if HEALTHCOMP_STAGING
private struct StagingScoringDiagnosticPage: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsReference = false
    @State private var armFailed = false

    private let controls = StagingScoringOperatorControls.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            List {
                Section {
                    Text("Observe one manual refresh within ten minutes. Only fixed counts are held in memory; no Health values, account IDs or request references are collected.")
                    if scenePhase == .active {
                        activityObservationState
                    } else {
                        Text("Activity observation hidden while Staging is inactive.")
                    }
                } header: {
                    Text("Activity to submission")
                } footer: {
                    Text("Counts cover all competitions checked by that refresh. Queued revisions are not proof of server acceptance. Closing or backgrounding the app clears a started observation.")
                }
                Section {
                    Text("Arm once, return to Competition and pull to refresh once, then return here within 60 seconds. Do not change accounts.")
                    Text("This screen does not refresh or send a request. A captured response is not proof that your gesture caused it.")
                }
                Section {
                    if scenePhase == .active {
                        captureState
                    } else {
                        Text("Capture hidden while Staging is inactive.")
                    }
                } footer: {
                    Text("Only an opaque request reference can appear here, not Health values or account details. The app does not log, copy or save it. Screenshots or accessibility tools could still record a visible reference.")
                }
            }
        }
        .accountPageStyle(title: "Staging Diagnostics")
        .onDisappear { showsReference = false }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { showsReference = false }
        }
    }

    @ViewBuilder
    private var activityObservationState: some View {
        switch controls.activityDisplayState() {
        case .unavailable:
            Text("Activity observation is temporarily unavailable.")
        case .off:
            Button("Observe Next Refresh") {
                _ = controls.requestActivityObservation()
            }
            .accessibilityIdentifier("staging.activity.arm")
            .frame(minHeight: 44)
        case .waiting:
            Text("Ready. Return to Competition and pull to refresh once.")
            clearActivityObservation
        case .running:
            Text("Refresh observation is running.")
            clearActivityObservation
        case let .complete(summary):
            Text("Refresh observation finished.")
                .accessibilityIdentifier("staging.activity.finished")
            ForEach(StagingScoringOperatorControls.ActivityEvent.allCases, id: \.self) { event in
                Text("\(activityLabel(event)): \(summary[event])")
                    .accessibilityIdentifier("staging.activity.\(event.rawValue)")
            }
            clearActivityObservation
        case .closed:
            Text("Activity observation cleared or expired. A new app or sign-in session is required.")
        }
    }

    private var clearActivityObservation: some View {
        Button("Clear Activity Observation") {
            controls.cancelActivityObservation()
        }
        .accessibilityIdentifier("staging.activity.clear")
        .frame(minHeight: 44)
    }

    private func activityLabel(_ event: StagingScoringOperatorControls.ActivityEvent) -> String {
        switch event {
        case .missingDependency: "Missing runtime dependency"
        case .skippedLifecycle: "Non-scoring competitions skipped"
        case .readStarted: "Activity reads started"
        case .readCompleted: "Activity reads completed"
        case .snapshotDays: "Days with Activity summaries"
        case .missingDays: "Days without Activity summaries"
        case .futureDays: "Future days skipped"
        case .unchangedOutbox: "Unchanged saved revisions"
        case .unchangedTerminal: "Unchanged terminal revisions"
        case .unchangedAccepted: "Unchanged accepted revisions"
        case .queuedRevisions: "Revision enqueue operations completed"
        case .readFailed: "Activity read failures"
        case .reconciliationFailed: "Reconciliation failures"
        }
    }

    @ViewBuilder
    private var captureState: some View {
        switch controls.displayState() {
        case .unavailable:
            Text("Diagnostic state is temporarily unavailable.")
        case .off:
            Button("Arm One Capture") {
                armFailed = !controls.requestArm()
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("staging.diagnostic.arm")
            if armFailed { Text("Capture could not be armed.") }
        case .waiting:
            Text("Waiting for one qualifying failed response. The original 60-second window is running.")
            clearButton
        case let .captured(reference):
            if showsReference {
                Text(reference)
                    .font(.body.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.disabled)
                    .privacySensitive()
                    .accessibilityIdentifier("staging.diagnostic.reference")
            } else {
                Button("Show Request Reference") { showsReference = true }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("staging.diagnostic.show")
            }
            clearButton
        case .closed:
            Text("Capture closed. Another capture requires a new app session.")
        }
    }

    private var clearButton: some View {
        Button("Clear Capture") {
            controls.cancelStartedCapture()
            showsReference = false
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("staging.diagnostic.clear")
    }
}
#endif

private extension View {
    /// Account's pages share one surface and an inline title.
    func accountPageStyle(title: String) -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.ground)
            .foregroundStyle(Theme.ink)
            .tint(Theme.ink)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// System / Light / Dark, each previewed as a tiny Home screen.
private struct AppearancePicker: View {
    @Binding var selection: AppAppearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            ForEach(AppAppearance.allCases) { option in
                Button {
                    selection = option
                } label: {
                    VStack(spacing: 8) {
                        AppearanceThumbnail(
                            option: option,
                            isSelected: selection == option
                        )
                        Text(option.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Image(
                            systemName: selection == option
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.title3)
                        .foregroundStyle(
                            selection == option ? Theme.ink : Theme.tertiary
                        )
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Appearance, \(option.title)")
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(.vertical, 8)
    }
}

private struct AppearanceThumbnail: View {
    let option: AppAppearance
    let isSelected: Bool

    var body: some View {
        Group {
            switch option {
            case .light:
                screen.environment(\.colorScheme, .light)
            case .dark:
                screen.environment(\.colorScheme, .dark)
            case .system:
                HStack(spacing: 0) {
                    screen.environment(\.colorScheme, .light)
                    screen.environment(\.colorScheme, .dark)
                }
            }
        }
        .frame(width: 56, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? Theme.ink : Theme.outline,
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .accessibilityHidden(true)
    }

    // Theme colors resolve against the overridden color scheme.
    private var screen: some View {
        VStack(spacing: 6) {
            BrandMark().frame(width: 22)
            HStack(spacing: 2) {
                SlantedBar().fill(Theme.youFill).frame(width: 12, height: 4)
                SlantedBar().fill(Theme.ink).frame(width: 10, height: 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
    }
}

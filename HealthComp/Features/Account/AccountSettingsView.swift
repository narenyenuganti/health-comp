import ActivityKit
import ComposableArchitecture
import CoreImage.CIFilterBuiltins
import PhotosUI
import SwiftUI

/// Your reusable challenge link for Account. Nil hides the section.
struct AccountChallengeLink {
    let url: URL?
    let failed: Bool
    let load: () -> Void
    let isResetting: Bool
    let resetFailed: Bool
    let reset: () -> Void
}

/// Your photo, for Account's header. The photo itself comes from the
/// environment's `profilePhotos`.
struct AccountProfilePhoto {
    let status: CompetitionFeature.OwnPhotoState.Status
    let removedByReview: Bool
    /// Asks whether a reviewer removed your last photo.
    let load: () -> Void
    /// Uploads Move and Scale's JPEG.
    let save: (Data) -> Void
    let remove: () -> Void
    /// Move and Scale closed without saving.
    let cropClosed: () -> Void
}

/// One trip through Move and Scale, with where its photo comes from.
struct AccountPhotoCropRequest: Identifiable {
    let id = UUID()
    let load: @Sendable () async throws -> Data

#if DEBUG
    /// `--profile-photo-fixture` skips the picker with this photo, since
    /// PhotosPicker can't be driven from a UI test.
    static let testLabFixture: Data? = ProcessInfo.processInfo.arguments
        .contains("--profile-photo-fixture")
        ? ProfilePhotoTestLabServer.fixtureJPEG(red: 0.85, green: 0.45, blue: 0.2)
        : nil
#endif
}

/// The people you blocked, for Account. Hidden until a non-empty list loads.
struct AccountBlockedPeople {
    let people: [AuthenticatedProfile]?
    let unblocking: Set<UUID>
    /// The person whose last Unblock failed.
    let unblockFailed: UUID?
    let load: () -> Void
    let unblock: (UUID) -> Void
}

/// Your username and who can find or challenge you, for Account → Privacy.
/// Nil hides them; so does a server that hasn't answered.
struct AccountFriendSettings {
    let state: FriendSettingsFeature.State
    let send: (FriendSettingsFeature.Action) -> Void
}

/// What Account → Notifications needs from the competition. Hosts without
/// competition state pass nil, which hides the row.
struct AccountNotificationSettings {
    let authorization: CompetitionNotificationAuthorizationState?
    let isRequestInFlight: Bool
    let request: () -> Void
    var mutedPeople: [AccountMutedPerson] = []
    var mutesInFlight: Set<String> = []
    var unmute: (String) -> Void = { _ in }
    var choicesChanged: () -> Void = {}
    /// nil reads and observes `ActivityAuthorizationInfo`; a value overrides
    /// it for the DEBUG fixture.
    var liveActivitiesEnabled: Bool? = nil

    var statusText: String {
        authorization?.permitsNotifications == true ? "On" : "Off"
    }
}

/// A muted person Account can name.
struct AccountMutedPerson: Equatable, Identifiable {
    let id: String
    let name: String

    /// Names come from the person's matches; a muted identity with no match
    /// has nothing to notify about, so it isn't listed.
    static func list(
        _ competitions: [LocalCompetitionPresentation],
        muted: Set<String>
    ) -> [AccountMutedPerson] {
        var names: [String: String] = [:]
        for competition in competitions
        where muted.contains(competition.opponentIdentity)
            && names[competition.opponentIdentity] == nil {
            names[competition.opponentIdentity] = competition.opponentDisplayName
        }
        return names
            .map { AccountMutedPerson(id: $0.key, name: $0.value) }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}

/// What Account → Health needs. HealthKit hides read denial, so there is no
/// definite "On".
struct AccountHealthSettings {
    enum State: Equatable {
        case off
        case unavailable
        case asked
    }

    let access: HealthAccessStatus
    let isReadFailing: Bool
    let connect: () -> Void

    var state: State {
        if isReadFailing || access == .unavailable { return .unavailable }
        return access == .notRequested ? .off : .asked
    }
}

/// Matches whose points stop reaching the server while signed out.
func accountLiveMatchCount(_ competitions: [LocalCompetitionPresentation]) -> Int {
    competitions.filter {
        guard !$0.isPractice else { return false }
        switch $0.lifecycle {
        case .active, .endsToday, .tallying: return true
        default: return false
        }
    }.count
}

/// Sign-out is global, so the copy says "your points", not "this iPhone".
func accountSignOutMessage(liveMatchCount: Int) -> String {
    switch liveMatchCount {
    case ...0:
        "Notifications stop until you sign back in."
    case 1:
        "While you’re signed out, your points stop reaching your live match and notifications stop. Sign back in before it ends to catch up."
    default:
        "While you’re signed out, your points stop reaching your \(liveMatchCount.formatted()) live matches and notifications stop. Sign back in before they end to catch up."
    }
}

/// A short list; each setting opens its own page so explanations don't
/// stack up here.
struct AccountSettingsView: View {
    let store: StoreOf<AccountFeature>
    var notifications: AccountNotificationSettings?
    var health: AccountHealthSettings?
    var liveMatchCount = 0
    var challengeLink: AccountChallengeLink?
    var blockedPeople: AccountBlockedPeople?
    /// Real accounts only: set, change or remove your photo.
    var profilePhoto: AccountProfilePhoto?
    var friendSettings: AccountFriendSettings?
#if HEALTHCOMP_STAGING
    var refreshCompetition: (() -> Void)?
#endif

    @State private var isSignOutConfirmationPresented = false
    @State private var isRemovePhotoConfirmationPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var cropRequest: AccountPhotoCropRequest?
    @Environment(\.profilePhotos) private var photos
    @State private var isResetLinkConfirmationPresented = false

    @AppStorage(AppAppearance.storageKey)
    private var appearance = AppAppearance.system
    @AppStorage(Sounds.enabledKey) private var soundsAreOn = true
    @State private var showsChallengeCode = false
    @State private var hasLoaded = false
    @FocusState private var isNameFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var blockedInitialSize: CGFloat = 34

    /// What can resize the list once it's open.
    private var listShape: [AnyHashable] {
        [
            AnyHashable(challengeLink?.url),
            AnyHashable(challengeLink?.failed),
            AnyHashable(challengeLink?.resetFailed),
            AnyHashable(blockedPeople?.people?.map(\.id)),
            AnyHashable(blockedPeople?.unblockFailed),
            AnyHashable(store.isEditingDisplayName),
            AnyHashable(store.message?.text),
            AnyHashable(health != nil),
            AnyHashable(photoMessage),
        ]
    }

    var body: some View {
        scrollingList
            // The id, as Account can open before the publication mounts the link.
            .task(id: challengeLink != nil) { load() }
            .onChange(of: store.isEditingDisplayName) { _, isEditing in
                isNameFocused = isEditing
            }
            .sheet(isPresented: $showsChallengeCode) {
                if let url = challengeLink?.url {
                    ChallengeLinkCodeView(url: url) { showsChallengeCode = false }
                }
            }
            .overlay {
                AccountProgressOverlay(store: store)
            }
    }

    private var list: some View {
        List {
            profileHeader
            if challengeLink != nil {
                challengeLinkSection
            }
            settingsSection
            if let blocked = blockedPeople, let people = blocked.people, !people.isEmpty {
                blockedSection(blocked, people)
            }
            footerSection
        }
        .moving(Motion.settle, value: listShape)
        .accountPageStyle(title: "Account")
    }

    /// Delete is the last row, so its message lands off the bottom of the list.
    private var scrollingList: some View {
        ScrollViewReader { proxy in
            listWithHaptics
                .onChange(of: store.message) { _, message in
                    if message?.isDeletionMessage == true {
                        proxy.scrollTo(Self.deletionMessageID, anchor: .bottom)
                    }
                }
        }
    }

    private static let deletionMessageID = "account.deletion-message"

    // Plain Bools and its own property: on the List's chain, these closures
    // don't type-check in time. Each failure clears before the next attempt.
    private var listWithHaptics: some View {
        let hasMessage: Bool = store.message != nil
        let unblockFailed: Bool = blockedPeople?.unblockFailed != nil
        let resetFailed: Bool = challengeLink?.resetFailed ?? false
        let linkURL: URL? = challengeLink?.url
        return list
            .sensoryFeedback(.error, trigger: hasMessage, condition: { _, new in new })
            .sensoryFeedback(.error, trigger: unblockFailed, condition: { _, new in new })
            .sensoryFeedback(.error, trigger: resetFailed, condition: { _, new in new })
            .sensoryFeedback(.success, trigger: linkURL, condition: Self.linkWasReset)
    }

    /// First load isn't a reset.
    private static func linkWasReset(_ old: URL?, _ new: URL?) -> Bool {
        old != nil && new != nil
    }

    /// This runs again on pop back, and a reload would clear the failure on
    /// screen. Hosts with no link yet can still load later.
    private func load() {
        store.send(.appeared)
        guard !hasLoaded else { return }
        hasLoaded = challengeLink != nil
        challengeLink?.load()
        blockedPeople?.load()
        profilePhoto?.load()
    }

    /// Centred on the page ground: your photo, your name and Edit Name.
    private var profileHeader: some View {
        Section {
            VStack(spacing: 12) {
                avatarControl
                ZStack {
                    if store.isEditingDisplayName {
                        nameEditor
                            .transition(Motion.appear)
                            .zIndex(1)
                    } else {
                        nameDisplay
                            .transition(Motion.appear)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
        }
    }

    private var nameDisplay: some View {
        VStack(spacing: 0) {
            Text(store.displayName)
                .font(.title.weight(.bold).width(.condensed))
                .foregroundStyle(Theme.you)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Display name, \(store.displayName)")
                .accessibilityAddTraits(.isHeader)
            // Its 44 pt is its own spacing.
            Button("Edit Name") {
                store.send(.editDisplayNameButtonTapped)
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityLabel("Edit Display Name")
            .accessibilityIdentifier("account.settings.edit-display-name")
            headerMessages
        }
    }

    private var nameEditor: some View {
        VStack(spacing: 12) {
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
            .multilineTextAlignment(.center)
            .font(.title3.weight(.semibold))
            .foregroundStyle(Theme.ink)
            .focused($isNameFocused)
            .onSubmit {
                store.send(.saveDisplayNameButtonTapped)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .themePanel(cornerRadius: 14)
            .accessibilityIdentifier("account.settings.display-name")

            Text("People you play, friends and anyone who finds you in search see this name.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            headerMessages

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 8))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Button("Cancel", role: .cancel) {
                    store.send(.cancelDisplayNameButtonTapped)
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    store.send(.saveDisplayNameButtonTapped)
                } label: {
                    BusyLabel("Save", isBusy: store.isRequestInFlight)
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityValue(store.isRequestInFlight ? "Saving" : "")
                .accessibilityIdentifier(
                    "account.settings.save-display-name"
                )
            }
            .disabled(store.isRequestInFlight)
        }
    }

    /// The name error, and what happened to your photo.
    @ViewBuilder
    private var headerMessages: some View {
        if let message = store.message, !message.isDeletionMessage {
            Text(message.text)
                .font(.callout)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account.message")
        }
        if let photoMessage {
            Text(photoMessage)
                .font(.callout)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account.photo.message")
        }
    }

    private var photoMessage: String? {
        guard let profilePhoto else { return nil }
        if profilePhoto.status == .removeFailed { return "Couldn’t remove your photo. Try again." }
        if profilePhoto.removedByReview, photos.own == nil {
            return "Your photo was removed after a review. You can choose another one."
        }
        return nil
    }

    /// No photo: a tap opens the picker. With one: Change or Remove.
    @ViewBuilder
    private var avatarControl: some View {
        if let profilePhoto {
            Group {
                if photos.own != nil {
                    Menu {
                        Button(action: choosePhoto) {
                            Label("Change Photo", systemImage: "photo")
                        }
                        Button { isRemovePhotoConfirmationPresented = true } label: {
                            Label("Remove Photo", systemImage: "delete.left")
                        }
                    } label: {
                        avatarFace
                    }
                    .accessibilityLabel("Profile Photo")
                    .accessibilityHint("Change or remove your photo.")
                } else {
                    Button(action: choosePhoto) {
                        avatarFace
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add Profile Photo")
                }
            }
            .disabled(profilePhoto.status == .saving || profilePhoto.status == .removing)
            .accessibilityIdentifier("account.settings.photo")
            .confirmationDialog(
                "Remove your photo?",
                isPresented: $isRemovePhotoConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Remove Photo", role: .destructive) { profilePhoto.remove() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They will see your initial instead.")
            }
            .photosPicker(
                isPresented: $isPhotoPickerPresented,
                selection: $pickedPhoto,
                matching: .images,
                preferredItemEncoding: .current
            )
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                pickedPhoto = nil
                cropRequest = AccountPhotoCropRequest {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw ProfilePhotoFailure.unreadableImage
                    }
                    return data
                }
            }
            .fullScreenCover(item: $cropRequest) { request in
                ProfilePhotoCropView(
                    load: request.load,
                    isSaving: profilePhoto.status == .saving,
                    saveFailed: profilePhoto.status == .saveFailed,
                    save: profilePhoto.save,
                    cancel: {
                        cropRequest = nil
                        profilePhoto.cropClosed()
                    },
                    chooseAnother: {
                        cropRequest = nil
                        profilePhoto.cropClosed()
                        choosePhoto()
                    }
                )
            }
            // The sheet closes once the upload lands.
            .onChange(of: profilePhoto.status) { old, new in
                if old == .saving, new == .idle { cropRequest = nil }
            }
        } else {
            avatarFace
        }
    }

    private var avatarFace: some View {
        PersonAvatar(
            name: store.displayName,
            size: 80,
            isYou: true,
            initialFont: .system(size: 36, weight: .heavy).width(.condensed)
        )
        .overlay(alignment: .bottomTrailing) {
            if profilePhoto != nil {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.onInk)
                    .frame(width: 24, height: 24)
                    .background(Theme.ink, in: Circle())
                    .padding(2)
                    .background(Theme.ground, in: Circle())
                    .offset(x: 3, y: 3)
            }
        }
        .frame(width: 80, height: 80)
        .contentShape(Circle())
    }

    private func choosePhoto() {
#if DEBUG
        // PhotosPicker can't be driven from a UI test.
        if let fixture = AccountPhotoCropRequest.testLabFixture {
            cropRequest = AccountPhotoCropRequest { fixture }
            return
        }
#endif
        isPhotoPickerPresented = true
    }

    private var challengeLinkSection: some View {
        Section {
            // Separate rows, so the List settles these. A height change inside
            // one cell jumps, and its text runs over its neighbours.
            if let url = challengeLink?.url {
                VStack(alignment: .leading, spacing: 12) {
                    let isResetting = challengeLink?.isResetting == true
                    Text(Self.displayText(url))
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Your challenge link")
                        .accessibilityValue(Self.displayText(url))
                        .accessibilityIdentifier("account.challenge-link.url")
                        .contentTransition(.opacity)
                        .animation(Motion.fade, value: url)
                    let buttons = Group {
                        Button {
                            showsChallengeCode = true
                        } label: {
                            Label("Show Code", systemImage: "qrcode")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(isResetting)
                        .accessibilityIdentifier("account.challenge-link.show-code")
                        ShareLink(
                            item: url,
                            subject: Text("My HealthComp challenge link"),
                            message: Text("Challenge me to a week of rings on HealthComp.")
                        ) {
                            Label("Share Link", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(isResetting)
                        .accessibilityIdentifier("account.challenge-link.share")
                    }
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 8) { buttons }
                    } else {
                        HStack(spacing: 8) { buttons }
                    }
                    // The 44 pt frame sits inside the label so the hit area gets it too.
                    Button { isResetLinkConfirmationPresented = true } label: {
                        Text("Reset Link")
                    }
                        .buttonStyle(QuietButtonStyle(color: Theme.ink))
                        .disabled(isResetting)
                        .accessibilityValue(isResetting ? "Resetting" : "")
                        .accessibilityIdentifier("account.challenge-link.reset")
                        .alert(
                            "Reset your challenge link?",
                            isPresented: $isResetLinkConfirmationPresented
                        ) {
                            Button("Reset Link", role: .destructive) { challengeLink?.reset() }
                                .accessibilityIdentifier("account.challenge-link.reset.confirm")
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Your old link stops working. Challenges already sent stay.")
                        }
                    Text("Anyone with this link can challenge you, unless you only allow friends. Reset it to turn off the old one; challenges already sent stay.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                if challengeLink?.resetFailed == true {
                    Text("Couldn’t reset your link. Try again.")
                        .font(.callout)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("account.challenge-link.reset-error")
                        .listRowSeparator(.hidden, edges: .top)
                }
            } else if challengeLink?.failed == true {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Couldn’t load your link.")
                        .font(.callout)
                        .foregroundStyle(Theme.ink)
                    Button("Try Again") { challengeLink?.load() }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("account.challenge-link.retry")
                }
                .padding(.vertical, 4)
            } else {
                ProgressView("Loading your link…")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.vertical, 4)
            }
        } header: {
            SectionLabel("YOUR CHALLENGE LINK")
        }
        .listRowBackground(Theme.panel)
    }

    private func blockedSection(
        _ blocked: AccountBlockedPeople,
        _ people: [AuthenticatedProfile]
    ) -> some View {
        Section {
            ForEach(people, id: \.id) { person in
                blockedRow(person, blocked)
                // Under the person, so it shows where the tap was even when
                // the list runs past the screen.
                if blocked.unblockFailed == person.id {
                    Text("Couldn’t unblock. Check your connection and try again.")
                        .font(.callout)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("account.blocked.error")
                        .listRowSeparator(.hidden, edges: .top)
                }
            }
        } header: {
            SectionLabel("BLOCKED")
        } footer: {
            Text("Blocked people can’t challenge you or find you in search. They aren’t notified.")
                .foregroundStyle(Theme.secondary)
        }
        .listRowBackground(Theme.panel)
    }

    private func blockedRow(
        _ person: AuthenticatedProfile,
        _ blocked: AccountBlockedPeople
    ) -> some View {
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        let isUnblocking = blocked.unblocking.contains(person.id)
        let layout = isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 12) {
                // At accessibility sizes the initial would squeeze the
                // name into a narrow column, so the name gets the width.
                // Never a photo: the block hides it.
                if !isAccessibilitySize {
                    PersonAvatar(
                        name: person.displayName,
                        size: blockedInitialSize,
                        initialFont: .headline.width(.condensed)
                    )
                }
                Text(person.displayName)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { blocked.unblock(person.id) } label: {
                // The ink tint doesn't dim when disabled, so saving shows here.
                Text("Unblock")
                    .foregroundStyle(isUnblocking ? Theme.secondary : Theme.ink)
                    .animation(Motion.fade, value: isUnblocking)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(isUnblocking)
            .accessibilityLabel("Unblock \(person.displayName)")
            .accessibilityValue(isUnblocking ? "Unblocking" : "")
            .accessibilityIdentifier("account.blocked.unblock")
        }
    }

    /// The URL without its scheme: "healthcomp.app/c/Xb3k…".
    static func displayText(_ url: URL) -> String {
        let text = url.absoluteString
        guard let range = text.range(of: "://") else { return text }
        return String(text[range.upperBound...])
    }

    private var settingsSection: some View {
        Section {
            if let health {
                NavigationLink {
                    AccountHealthPage(settings: health)
                } label: {
                    LabeledContent {
                        switch health.state {
                        case .off: Text("Off")
                        case .unavailable: Text("Unavailable")
                        case .asked: EmptyView()
                        }
                    } label: {
                        Label("Health", systemImage: "heart")
                    }
                }
                .accessibilityIdentifier("account.health")
            }

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
                AccountAppearancePage()
            } label: {
                LabeledContent {
                    Text(appearance.title)
                } label: {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                }
            }
            .accessibilityIdentifier("account.appearance")

            NavigationLink {
                AccountSoundsPage()
            } label: {
                LabeledContent {
                    Text(soundsAreOn ? "On" : "Off")
                } label: {
                    Label("Sounds", systemImage: "speaker.wave.2")
                }
            }
            .accessibilityIdentifier("account.sounds")

            NavigationLink {
                AccountPrivacyPage(friends: friendSettings)
            } label: {
                Label("Privacy", systemImage: "lock")
            }
            .accessibilityIdentifier("account.privacy")

#if HEALTHCOMP_STAGING
            NavigationLink {
                StagingScoringDiagnosticPage(refreshCompetition: refreshCompetition)
            } label: {
                Label("Staging Diagnostics", systemImage: "stethoscope")
            }
            .accessibilityIdentifier("account.staging-diagnostics")
#endif
        }
        .listRowBackground(Theme.panel)
    }

    /// Quiet text at the foot, for the two actions you rarely take. Neutral,
    /// because red means Move; the roles stay for VoiceOver.
    private var footerSection: some View {
        Section {
            Button(role: .destructive) {
                isSignOutConfirmationPresented = true
            } label: {
                Text("Sign Out")
            }
            .buttonStyle(QuietButtonStyle(color: Theme.ink))
            .disabled(store.isRequestInFlight)
            .accessibilityIdentifier("account.sign-out")
            .accessibilityValue(
                store.isRequestInFlight ? "Signing out" : ""
            )
            // On the button, not the List, so it can't collide with the
            // delete alert.
            .alert("Sign out?", isPresented: $isSignOutConfirmationPresented) {
                Button("Sign Out", role: .destructive) {
                    store.send(.signOutButtonTapped)
                }
                .accessibilityIdentifier("account.sign-out.confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(accountSignOutMessage(liveMatchCount: liveMatchCount))
            }

            Button(role: .destructive) {
                store.send(.deleteAccountButtonTapped)
            } label: {
                Text("Delete Account")
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(store.isRequestInFlight)
            .accessibilityIdentifier("account.delete")
            .accessibilityValue(
                store.isDeletingAccount ? "Deleting account" : ""
            )
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
                    "You’ll confirm with Sign in with Apple. Live matches are cancelled, and finished matches stay in the other person’s history under the name Former competitor. This can’t be undone."
                )
            }

            // The last row, so the in-flight scroll to the bottom lands on it.
            if let message = store.message, message.isDeletionMessage {
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.message")
                    .id(Self.deletionMessageID)
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
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

private struct AccountSoundsPage: View {
    @AppStorage(Sounds.enabledKey) private var isOn = true
    @AppStorage(Sounds.volumeKey) private var volume = 1.0

    var body: some View {
        List {
            Section {
                Toggle("Sound Effects", isOn: $isOn)
                    // Amber, as the notification switches.
                    .tint(Theme.youFill)
                    .accessibilityIdentifier("account.sounds.enabled")
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill")
                    // Letting go plays the "you move ahead" sound at the new volume.
                    Slider(value: $volume, in: 0...1, step: 0.05) { isDragging in
                        if !isDragging { Sounds.play(.ahead) }
                    }
                    .tint(Theme.youFill)
                    .accessibilityLabel("Volume")
                    .accessibilityIdentifier("account.sounds.volume")
                    Image(systemName: "speaker.wave.3.fill")
                }
                .foregroundStyle(Theme.secondary)
                .frame(minHeight: 44)
                .disabled(!isOn)
                .opacity(isOn ? 1 : 0.4)
                .accessibilityElement(children: .contain)
            } footer: {
                Text("Short sounds at big moments in a match. Let go of the slider to hear one. Silent mode turns them off too.")
                    .foregroundStyle(Theme.secondary)
            }
            .listRowBackground(Theme.panel)
        }
        .accountPageStyle(title: "Sounds")
    }
}

private struct AccountHealthPage: View {
    let settings: AccountHealthSettings

    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                switch settings.state {
                case .off:
                    LabeledContent("Health access", value: "Off")
                    Button("Connect Health", action: settings.connect)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("account.health.connect")
                case .unavailable:
                    LabeledContent("Health access", value: "Unavailable")
                    openSettingsButton
                case .asked:
                    Text("HealthComp reads Move, Exercise and Stand to score your matches.")
                    openSettingsButton
                }
            } footer: {
                Text(footer)
                    .foregroundStyle(Theme.secondary)
            }
            .listRowBackground(Theme.panel)
        }
        .accountPageStyle(title: "Health")
    }

    private var openSettingsButton: some View {
        Button("Open Settings") {
            openURL(URL(string: UIApplication.openSettingsURLString)!)
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("account.health.settings")
    }

    private var footer: String {
        switch settings.state {
        case .off:
            "Your points can’t update until HealthComp can read your Activity rings."
        case .unavailable:
            "HealthComp can’t read Health on this iPhone right now, so your points can’t update."
        case .asked:
            "iOS doesn’t tell apps whether Health access is on. If your points aren’t updating, turn on all categories for HealthComp in Settings → Privacy & Security → Health."
        }
    }
}

private struct AccountNotificationsPage: View {
    let settings: AccountNotificationSettings

    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var initialSize: CGFloat = 34
    // Read up front, so the rows it adds are there on the push.
    @State private var systemLiveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled

    private var liveActivitiesEnabled: Bool {
        settings.liveActivitiesEnabled ?? systemLiveActivitiesEnabled
    }

    var body: some View {
        List {
            Section {
                LabeledContent(
                    "Match notifications",
                    value: settings.statusText
                )
                switch settings.authorization {
                case .notDetermined:
                    Button(action: settings.request) {
                        if settings.isRequestInFlight {
                            ProgressView()
                        } else {
                            Text("Turn On Notifications")
                        }
                    }
                    .frame(minHeight: 44)
                    .disabled(settings.isRequestInFlight)
                    .accessibilityIdentifier("competition.notifications.enable")

                case .denied:
                    Text("Turned off in iOS Settings")
                        .foregroundStyle(Theme.secondary)
                    openSettingsButton

                case .authorized, .provisional, .ephemeral:
                    openSettingsButton

                case nil:
                    EmptyView()
                }
            } footer: {
                Text("HealthComp sends match moments, like lead changes and results, and friend requests. To mute someone, open your match with them.")
                    .foregroundStyle(Theme.secondary)
            }
            .listRowBackground(Theme.panel)

            choiceSection("DURING A MATCH", CompetitionNotificationChoice.allCases.filter { !$0.isServerSent })
            choiceSection("FROM THE OTHER PERSON", CompetitionNotificationChoice.allCases.filter { $0.isServerSent && !$0.isFriends })
            choiceSection("FRIENDS", CompetitionNotificationChoice.allCases.filter(\.isFriends))

            if !settings.mutedPeople.isEmpty {
                Section {
                    ForEach(settings.mutedPeople) { person in
                        mutedRow(person)
                    }
                } header: {
                    SectionLabel("MUTED")
                } footer: {
                    Text("Muting someone silences all your matches with them.")
                        .foregroundStyle(Theme.secondary)
                }
                .listRowBackground(Theme.panel)
            }
        }
        .moving(Motion.settle, value: settings.authorization)
        .moving(Motion.settle, value: settings.mutedPeople)
        .moving(Motion.settle, value: liveActivitiesEnabled)
        .accountPageStyle(title: "Notifications")
        .task {
            guard settings.liveActivitiesEnabled == nil else { return }
            let info = ActivityAuthorizationInfo()
            systemLiveActivitiesEnabled = info.areActivitiesEnabled
            for await enabled in info.activityEnablementUpdates {
                systemLiveActivitiesEnabled = enabled
            }
        }
    }

    private func choiceSection(
        _ title: String,
        _ choices: [CompetitionNotificationChoice]
    ) -> some View {
        Section {
            ForEach(choices, id: \.self) { choice in
                NotificationChoiceToggle(
                    choice: choice,
                    isForcedOff: choice == .liveActivity && !liveActivitiesEnabled,
                    changed: settings.choicesChanged
                )
                if choice == .liveActivity && !liveActivitiesEnabled {
                    Text("Live Activities are off for HealthComp in iOS Settings.")
                        .foregroundStyle(Theme.secondary)
                    Button("Open Settings") {
                        openURL(URL(string: UIApplication.openSettingsURLString)!)
                    }
                    .frame(minHeight: 44)
                    // The status section has its own Open Settings; VoiceOver
                    // tells them apart.
                    .accessibilityLabel("Open Settings for Live Activities")
                    .accessibilityIdentifier("account.notifications.live-activity.settings")
                }
            }
        } header: {
            SectionLabel(title)
        }
        .listRowBackground(Theme.panel)
    }

    private var openSettingsButton: some View {
        Button("Open Settings") {
            openURL(URL(string: UIApplication.openNotificationSettingsURLString)!)
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("account.notifications.settings")
    }

    private func mutedRow(_ person: AccountMutedPerson) -> some View {
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        let layout = isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        let isUnmuting = settings.mutesInFlight.contains(person.id)
        return layout {
            HStack(spacing: 12) {
                if !isAccessibilitySize {
                    PersonAvatar(
                        name: person.name,
                        photo: RemoteCompetitionOpponentIdentity.profileID(person.id),
                        size: initialSize,
                        initialFont: .headline.width(.condensed)
                    )
                }
                Text(person.name)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The frame sits inside the label so the tap area, not just the
            // layout, stays 44pt at the smallest text sizes.
            Button { settings.unmute(person.id) } label: {
                // The ink tint doesn't dim when disabled, so saving shows here.
                Text("Unmute")
                    .foregroundStyle(isUnmuting ? Theme.secondary : Theme.ink)
                    .animation(Motion.fade, value: isUnmuting)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.borderless)
                .disabled(isUnmuting)
                .accessibilityLabel("Unmute \(person.name)")
                .accessibilityIdentifier("account.notifications.unmute")
        }
    }


}

private struct NotificationChoiceToggle: View {
    let choice: CompetitionNotificationChoice
    let isForcedOff: Bool
    let changed: () -> Void
    @AppStorage private var isOn: Bool

    init(choice: CompetitionNotificationChoice, isForcedOff: Bool, changed: @escaping () -> Void) {
        self.choice = choice
        self.isForcedOff = isForcedOff
        self.changed = changed
        _isOn = AppStorage(wrappedValue: true, choice.storageKey)
    }

    var body: some View {
        Toggle(choice.title, isOn: isForcedOff ? .constant(false) : $isOn)
            .disabled(isForcedOff)
            // Amber, not the page's ink, which hides the thumb in dark mode.
            .tint(Theme.youFill)
            .onChange(of: isOn) { changed() }
            .accessibilityIdentifier("account.notifications.choice.\(choice.rawValue)")
    }
}

private struct AccountPrivacyPage: View {
    let friends: AccountFriendSettings?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List {
            if let friends, let shown = friends.state.shown {
                usernameSection(friends, shown)
                searchSection(friends, shown)
                challengeSection(friends, shown)
            }
            Section {
                Label(
                    "Raw Health data stays on this iPhone",
                    systemImage: "lock.iphone"
                )
                Label(
                    "The other person gets your daily points, rounded Activity percentages and modes",
                    systemImage: "person.2"
                )
                Link(destination: URL(string: "https://healthcomp.app/privacy")!) {
                    Text("Privacy Policy")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("account.privacy-policy")
            }
            .listRowBackground(Theme.panel)
        }
        .moving(Motion.settle, value: friends?.state)
        .accountPageStyle(title: "Privacy")
        // The id, as Account can open before the publication mounts these.
        .task(id: friends != nil) { friends?.send(.requested) }
        .sheet(isPresented: Binding(
            get: { friends?.state.sheet != nil },
            set: { if !$0 { friends?.send(.usernameSheetClosed) } }
        )) {
            if let friends { UsernameSheet(friends: friends) }
        }
    }

    private func usernameSection(
        _ friends: AccountFriendSettings,
        _ shown: FriendSettings
    ) -> some View {
        Section {
            if let username = shown.username {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    Text(verbatim: "@\(username)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("account.privacy.username")
                    Button { friends.send(.usernameSheetOpened) } label: {
                        Text("Edit")
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(friends.state.isSaving)
                    .accessibilityLabel("Edit Username")
                    .accessibilityIdentifier("account.privacy.username.edit")
                }
            } else {
                Button { friends.send(.usernameSheetOpened) } label: {
                    Text("Choose a Username")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .disabled(friends.state.isSaving)
                .accessibilityIdentifier("account.privacy.username.choose")
            }
        } header: {
            SectionLabel("USERNAME")
        }
        .listRowBackground(Theme.panel)
    }

    private func searchSection(
        _ friends: AccountFriendSettings,
        _ shown: FriendSettings
    ) -> some View {
        Section {
            Toggle("Show Me in Search", isOn: Binding(
                get: { shown.showInSearch },
                set: { friends.send(.showInSearchChanged($0)) }
            ))
            // Amber, not the page's ink, which hides the thumb in dark mode.
            .tint(Theme.youFill)
            .disabled(friends.state.isSaving)
            .accessibilityIdentifier("account.privacy.show-in-search")
            if friends.state.failedField == .showInSearch { saveError }
        } header: {
            SectionLabel("FINDING YOU")
        } footer: {
            Text("Off: only people with your link can add you. Search shows your name, photo and username, never your rings.")
                .foregroundStyle(Theme.secondary)
        }
        .listRowBackground(Theme.panel)
    }

    private func challengeSection(
        _ friends: AccountFriendSettings,
        _ shown: FriendSettings
    ) -> some View {
        Section {
            ForEach(FriendChallengePolicy.allCases, id: \.self) { policy in
                let isSelected = shown.challengePolicy == policy
                Button { friends.send(.challengePolicyChanged(policy)) } label: {
                    HStack(spacing: 12) {
                        Text(policy.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .opacity(isSelected ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .disabled(friends.state.isSaving)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("account.privacy.challenge.\(policy.rawValue)")
            }
            if friends.state.failedField == .challengePolicy { saveError }
        } header: {
            SectionLabel("WHO CAN CHALLENGE YOU")
        }
        .listRowBackground(Theme.panel)
    }

    private var saveError: some View {
        Text("Couldn’t save. Check your connection and try again.")
            .font(.callout)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("account.privacy.error")
            .listRowSeparator(.hidden, edges: .top)
    }
}

private struct AccountProgressOverlay: View {
    let store: StoreOf<AccountFeature>

    var body: some View {
        // Save waits in its own button.
        if store.isRequestInFlight, !store.isEditingDisplayName {
            ProgressView()
                .tint(Theme.ink)
                .accessibilityLabel(
                    store.isDeletingAccount
                        ? "Deleting account"
                        : "Saving account changes"
                )
                .waitingFade()
                .transition(Motion.appear)
        }
    }
}

#if HEALTHCOMP_STAGING
private struct StagingScoringDiagnosticPage: View {
    let refreshCompetition: (() -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsReference = false
    @State private var armFailed = false
    @State private var activityArmFailed = false

    private let controls = StagingScoringOperatorControls.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            List {
                Section {
                    Text("Run one normal competition refresh from this page. Only fixed counts are held in memory; no Health values, account IDs or request references are collected.")
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
                    Text("The separate response capture requires a manual refresh within 60 seconds. Do not change accounts.")
                    Text("The Activity check does not arm response capture. A captured response is not proof that your gesture caused it.")
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
            if let refreshCompetition {
                Button("Check Activity Now") {
                    activityArmFailed = !controls.startActivityCheck(refreshCompetition)
                }
                .accessibilityIdentifier("staging.activity.check")
                .frame(minHeight: 44)
                if activityArmFailed { Text("Activity check could not be started.") }
            } else {
                Text("Activity check is unavailable in this host.")
            }
        case .waiting:
            Text("Refresh requested. Waiting for Activity observation to start.")
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
                    choose(option)
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
                        .contentTransition(.opacity)
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
        .animation(Motion.fade, value: selection)
        .sensoryFeedback(.selection, trigger: selection)
    }

    /// The whole window changes, and dynamic colours don't interpolate through
    /// a transaction, so it crossfades from a snapshot: `Motion.fade` in UIKit.
    private func choose(_ option: AppAppearance) {
        guard option != selection else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let snapshot = window?.snapshotView(afterScreenUpdates: false)
        if let snapshot {
            snapshot.isUserInteractionEnabled = false
            snapshot.accessibilityElementsHidden = true
            window?.addSubview(snapshot)
        }
        selection = option
        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
            snapshot?.alpha = 0
        } completion: { _ in
            snapshot?.removeFromSuperview()
        }
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

/// The QR code of your challenge link. Black on white in both modes, because
/// scanners need dark modules on a light quiet zone.
private struct ChallengeLinkCodeView: View {
    let url: URL
    let done: () -> Void

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        let side = min(proxy.size.width - 64, 320)
                        if let image = challengeLinkQRCode(url) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .padding(16)
                                .background(Color.white)
                                .frame(width: side, height: side)
                                .accessibilityLabel("QR code for your challenge link")
                                .accessibilityIdentifier("account.challenge-link.qr")
                        }
                        Text("They can scan this with the iPhone Camera.")
                            .font(.callout)
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .themePanel()
                    .padding(16)
                }
            }
            .background(Theme.ground)
            .navigationTitle("Your Challenge Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private let challengeLinkQRContext = CIContext()

private func challengeLinkQRCode(_ url: URL) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(url.absoluteString.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?
        .transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
          let cgImage = challengeLinkQRContext.createCGImage(output, from: output.extent)
    else {
        return nil
    }
    return UIImage(cgImage: cgImage)
}

#if DEBUG

import CompetitionCore
import ComposableArchitecture
import Foundation
import SwiftUI

enum MultiUserCompetitionTestLabScenario:
    String,
    CaseIterable,
    Equatable,
    Sendable
{
    case sharing
    case sharingCustomScheme = "sharing-custom-scheme"
    case coldClaim = "cold-claim"
    case warmClaim = "warm-claim"
    case signedOutClaim = "signed-out-claim"
    case unavailableClaim = "unavailable-claim"
    case offlineClaim = "offline-claim"
    case challengeLink = "challenge-link"
    case account
    case welcome
    case welcomeChallenge = "welcome-challenge"
    case healthOnboarding = "health-onboarding"
    case healthOnboardingChallenge = "health-onboarding-challenge"
    /// A challenge link opened before Health is set up, through the real
    /// Home flow.
    case healthOnboardingClaim = "health-onboarding-claim"
}

struct MultiUserCompetitionTestLabConfiguration: Equatable, Sendable {
    let scenario: MultiUserCompetitionTestLabScenario
}

enum MultiUserCompetitionTestLabLaunchDecision: Equatable, Sendable {
    case disabled
    case configured(MultiUserCompetitionTestLabConfiguration)
    case invalid(String)
}

enum MultiUserCompetitionTestLabLaunchParser {
    static func decision(
        arguments: [String]
    ) -> MultiUserCompetitionTestLabLaunchDecision {
        let flag = "--multi-user-competition-test-lab"
        guard arguments.contains(flag) else { return .disabled }
        guard !arguments.contains("--local-competition-test-lab") else {
            return .invalid("Only one competition Test Lab may be enabled.")
        }

        let option = "--multi-user-competition-scenario"
        let optionIndexes = arguments.indices.filter {
            arguments[$0] == option
        }
        guard optionIndexes.count == 1,
              let index = optionIndexes.first,
              arguments.indices.contains(index + 1),
              let scenario = MultiUserCompetitionTestLabScenario(
                  rawValue: arguments[index + 1]
              )
        else {
            return .invalid("Choose one valid multi-user Test Lab scenario.")
        }

        let unknown = arguments.filter {
            $0.hasPrefix("--multi-user-competition-")
                && $0 != flag
                && $0 != option
        }
        guard unknown.isEmpty else {
            return .invalid("Unknown multi-user Test Lab option.")
        }
        return .configured(.init(scenario: scenario))
    }
}

struct MultiUserCompetitionTestLabRootView: View {
    let configuration: MultiUserCompetitionTestLabConfiguration
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            Text("REMOTE UI TEST LAB")
                .font(.body.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial)
                .accessibilityIdentifier("multiuser.testlab.banner")
                .accessibilityValue(renderedConfigurationAccessibilityValue)

            scenarioView
        }
        .accessibilityIdentifier("multiuser.testlab.root")
    }

    private var renderedConfigurationAccessibilityValue: String {
        let appearance = colorScheme == .dark ? "Dark" : "Light"
        let contentSize: String = switch dynamicTypeSize {
        case .xSmall: "xSmall"
        case .small: "small"
        case .medium: "medium"
        case .large: "large"
        case .xLarge: "xLarge"
        case .xxLarge: "xxLarge"
        case .xxxLarge: "xxxLarge"
        case .accessibility1: "accessibility1"
        case .accessibility2: "accessibility2"
        case .accessibility3: "accessibility3"
        case .accessibility4: "accessibility4"
        case .accessibility5: "accessibility5"
        @unknown default: "unknown"
        }
        return "Appearance: \(appearance); Dynamic Type: \(contentSize)"
    }

    @ViewBuilder
    private var scenarioView: some View {
        switch configuration.scenario {
        case .sharing, .sharingCustomScheme:
            MultiUserCompetitionSharingTestLabView(
                usesCustomScheme: configuration.scenario == .sharingCustomScheme
            )
        case .coldClaim, .warmClaim, .signedOutClaim,
             .unavailableClaim, .offlineClaim:
            MultiUserCompetitionClaimTestLabView(
                scenario: configuration.scenario
            )
        case .challengeLink:
            MultiUserCompetitionChallengeLinkTestLabView()
        case .account:
            MultiUserCompetitionAccountTestLabView()
        case .welcome:
            MultiUserCompetitionAccountTestLabView(mode: .signedOut)
        case .welcomeChallenge:
            MultiUserCompetitionAccountTestLabView(
                mode: .signedOut,
                hasPendingChallenge: true
            )
        case .healthOnboarding, .healthOnboardingChallenge:
            PermissionOnboardingView(
                step: .health,
                isRequesting: false,
                isForChallenge: configuration.scenario == .healthOnboardingChallenge,
                continueTapped: {},
                notNowTapped: {}
            )
        case .healthOnboardingClaim:
            MultiUserCompetitionPreHealthClaimTestLabView()
        }
    }
}

struct MultiUserCompetitionTestLabConfigurationErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView(
            "Multi-user Test Lab unavailable",
            systemImage: "exclamationmark.triangle.fill",
            description: Text(message)
        )
        .accessibilityIdentifier("multiuser.testlab.configuration-error")
    }
}

private struct MultiUserCompetitionSharingTestLabView: View {
    let usesCustomScheme: Bool
    @State private var path: [CompetitionID] = []
    @State private var showsHistory = false
    @State private var historyPerson: String?
    @State private var isChallengePresented = false
    @State private var challengeStatus: CompetitionFeature.ChallengeSheetStatus = .ready
    @State private var recipientCode = ""
    @State private var recipient: CompetitionFeature.InviteRecipient?
    @State private var recipientStatus: CompetitionFeature.InviteRecipientStatus = .idle
    @State private var archivedIDs: Set<CompetitionID> = []
    @State private var rematchState: CompetitionFeature.CompetitionRematchState = .available
    @State private var pastedInvitationStatus = "Not checked"

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack(
                path: CompetitionHomeRoute.stack(
                    path: $path,
                    showsHistory: $showsHistory,
                    person: $historyPerson
                )
            ) {
                CompetitionSharingView(
                    publication: publication,
                    challengeStatus: challengeStatus,
                    senderName: "Beta Alice",
                    dismissChallenge: {
                        challengeStatus = .ready
                        recipientCode = ""
                        recipient = nil
                        recipientStatus = .idle
                    },
                    recipientCode: Binding(
                        get: { recipientCode },
                        set: {
                            guard recipientCode != $0 else { return }
                            recipientCode = $0
                            recipient = nil
                            recipientStatus = .idle
                        }
                    ),
                    recipient: recipient,
                    recipientStatus: recipientStatus,
                    findRecipient: findRecipient,
                    createInvite: createInvite,
                    isChallengePresented: $isChallengePresented,
                    selectCompetition: { path.append($0) },
                    openHistory: { showsHistory = true },
                    reinvite: {},
                    isReinviteInFlight: false,
                    challengeAgain: { _ in
                        challengeStatus = .ready
                        recipientCode = MultiUserCompetitionTestLabFixtures.expiredRecipientID
                            .uuidString.lowercased()
                        recipient = .init(AuthenticatedProfile(
                            id: MultiUserCompetitionTestLabFixtures.expiredRecipientID,
                            displayName: "Taylor"
                        ))
                        recipientStatus = .idle
                        isChallengePresented = true
                    },
                    archive: { archivedIDs.insert($0) },
                    commandIDsInFlight: [],
                    retry: {}
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        CompetitionChallengeButton {
                            isChallengePresented = true
                        }
                    }
                }
                .navigationDestination(for: CompetitionHomeRoute.self) { route in
                    switch route {
                    case .history:
                        CompetitionHistoryView(publication: publication)
                    case let .person(identity):
                        CompetitionPersonView(
                            publication: publication,
                            opponentIdentity: identity
                        )
                    case let .competition(id):
                        destination(id)
                    }
                }
            }
            if usesCustomScheme {
                HStack {
                    PasteButton(payloadType: String.self) { strings in
                        let text = strings.first ?? ""
                        let expectedLink = rematchState == .available
                            ? "healthcomp://invite/UVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVE"
                            : "healthcomp://invite/UlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlI"
                        if text.contains(expectedLink) {
                            pastedInvitationStatus = "Complete invitation link"
                        } else if text == "Open this private link to join my seven-day HealthComp competition."
                            || text == "Open this private link to join our HealthComp rematch." {
                            pastedInvitationStatus = "Message only"
                        } else {
                            pastedInvitationStatus = "Missing invitation link"
                        }
                    }
                    Text(pastedInvitationStatus)
                }
                .padding()
                .background(.regularMaterial)
            }
        }
        .accessibilityIdentifier("multiuser.sharing.root")
    }

    @ViewBuilder
    private func destination(_ id: CompetitionID) -> some View {
        if let competition = publication.dashboard.competitions.first(
            where: { $0.id == id }
        ) {
            switch competition.lifecycle {
            case .scheduled, .active, .endsToday, .tallying:
                CompetitionDetailView(
                    competition: competition,
                    source: .remoteParticipants
                )
            case .completed, .archived:
                CompetitionResultView(
                    competition: competition,
                    beltEvent: competitionBeltEvent(
                        for: competition,
                        in: publication.dashboard.competitions
                    ),
                    source: .remoteParticipants,
                    rematch: rematchState,
                    isCommandInFlight: false,
                    send: handle,
                    openCompetition: { path.append($0) }
                )
            case .pending:
                CompetitionInviteView(
                    competition: competition,
                    source: .remoteParticipants,
                    isCommandInFlight: false,
                    link: .ready(
                        MultiUserCompetitionTestLabFixtures.shareLink(
                            byte: 0x53,
                            usesCustomScheme: usesCustomScheme
                        ),
                        minimumRevision: 0
                    ),
                    send: handle
                )
            case .declined, .expired, .cancelled:
                ContentUnavailableView(
                    "Invitation Closed",
                    systemImage: "person.crop.circle.badge.xmark"
                )
            }
        }
    }

    private var publication: LocalCompetitionPublication {
        MultiUserCompetitionTestLabFixtures.publication(
            archivedIDs: archivedIDs
        )
    }

    private func findRecipient() {
        let code = recipientCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if let linkCode = CompetitionFeature.challengeLinkCode(in: code) {
            switch linkCode.rawValue {
            case MultiUserCompetitionTestLabFixtures.ownLinkCode:
                recipientStatus = .ownCode
            case MultiUserCompetitionTestLabFixtures.samLinkCode:
                recipient = .init(link: linkCode, displayName: "Sam")
                recipientStatus = .idle
            default:
                recipientStatus = .notFound
            }
            return
        }
        guard let id = UUID(uuidString: code) else {
            recipientStatus = .invalidCode
            return
        }
        switch id {
        case MultiUserCompetitionTestLabFixtures.ownProfileID:
            recipientStatus = .ownCode
        case MultiUserCompetitionTestLabFixtures.pendingID.rawValue:
            recipient = .init(AuthenticatedProfile(id: id, displayName: "Sam"))
            recipientStatus = .idle
        default:
            recipientStatus = .notFound
        }
    }

    private func createInvite() {
        guard recipient != nil else { return }
        challengeStatus = .sent(
            challengeID: MultiUserCompetitionTestLabFixtures.pendingID,
            challenge: nil,
            link: MultiUserCompetitionTestLabFixtures.shareLink(
                byte: 0x51,
                usesCustomScheme: usesCustomScheme
            )
        )
    }

    private func handle(_ action: CompetitionFeature.Action) {
        switch action {
        case let .archiveTapped(id):
            archivedIDs.insert(id)
        case .cancelTapped:
            path.removeAll()
        case .rematchTapped:
            rematchState = .sent(
                challengeID: MultiUserCompetitionTestLabFixtures.pendingID,
                expiresAt: nil,
                link: .ready(
                    MultiUserCompetitionTestLabFixtures.shareLink(
                        byte: 0x52,
                        usesCustomScheme: usesCustomScheme
                    ),
                    minimumRevision: 0
                )
            )
        default:
            break
        }
    }
}

private struct MultiUserCompetitionClaimTestLabView: View {
    let scenario: MultiUserCompetitionTestLabScenario
    @State private var status: MainTabFeature.InviteClaimStatus
    @State private var isSignedIn: Bool
    @State private var outcome: Outcome?

    private enum Outcome {
        case accepted
        case declined
        case dismissed
        case notNow
    }

    init(scenario: MultiUserCompetitionTestLabScenario) {
        self.scenario = scenario
        _isSignedIn = State(initialValue: scenario != .signedOutClaim)
        let initialStatus: MainTabFeature.InviteClaimStatus = switch scenario {
        case .unavailableClaim: .unavailable
        case .offlineClaim: .retryable
        case .sharing, .sharingCustomScheme, .coldClaim, .warmClaim,
             .signedOutClaim, .challengeLink, .account, .welcome, .welcomeChallenge,
             .healthOnboarding, .healthOnboardingChallenge, .healthOnboardingClaim:
            .ready
        }
        _status = State(initialValue: initialStatus)
    }

    var body: some View {
        Group {
            if !isSignedIn {
                signedOutClaim
            } else if let outcome {
                outcomeView(outcome)
            } else {
                ClaimCompetitionView(
                    status: status,
                    preview: MultiUserCompetitionTestLabFixtures.claimPreview,
                    now: MultiUserCompetitionTestLabFixtures.labNow,
                    accept: accept,
                    notNow: { outcome = .notNow },
                    decline: { outcome = .declined },
                    retry: { status = .ready },
                    dismiss: { outcome = .dismissed }
                )
            }
        }
        .accessibilityIdentifier("multiuser.claim.\(scenario.rawValue)")
    }

    private var signedOutClaim: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Sign in to continue", systemImage: "person.crop.circle")
            } description: {
                Text(
                    "Your private invitation is waiting on this iPhone. Sign in before deciding whether to join."
                )
            } actions: {
                Button("Continue to Invitation") {
                    isSignedIn = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("multiuser.claim.sign-in")
            }
            .navigationTitle("Competition Invitation")
        }
    }

    private func outcomeView(_ outcome: Outcome) -> some View {
        let presentation: (String, String, String) = switch outcome {
        case .accepted:
            (
                "Competition Confirmed",
                "calendar.badge.checkmark",
                "Scheduled Aug 13–Aug 19, 2026 on the creator’s America/Los_Angeles calendar."
            )
        case .declined:
            (
                "Invitation Declined",
                "person.crop.circle.badge.xmark",
                "You did not join this competition."
            )
        case .dismissed:
            (
                "Invitation Closed",
                "link.badge.plus",
                "Ask the sender for a new private invitation."
            )
        case .notNow:
            (
                "Challenge Kept",
                "clock",
                "It stays on Home until it expires."
            )
        }
        return ContentUnavailableView(
            presentation.0,
            systemImage: presentation.1,
            description: Text(presentation.2)
        )
        .accessibilityIdentifier("multiuser.claim.outcome")
    }

    private func accept() {
        status = .claiming
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            status = .waitingForCompetition
            try? await Task.sleep(nanoseconds: 80_000_000)
            outcome = .accepted
        }
    }
}

/// A fresh install: Health isn't set up and a challenge link is waiting.
/// Runs Home's own reducer; only the server and iOS are stand-ins.
private struct MultiUserCompetitionPreHealthClaimTestLabView: View {
    @State private var store = Store(initialState: MainTabFeature.State()) {
        MainTabFeature()
    } withDependencies: {
        let token = CompetitionInviteClaimToken(rawValue: String(repeating: "B", count: 43))!
        $0.competitionRoutingClient = CompetitionRoutingClient(
            routes: {
                AsyncStream {
                    $0.yield(CompetitionRouteEnvelope(sequence: 1, route: .claimInvite(token)))
                }
            },
            enqueue: { _ in },
            consume: { _ in }
        )
        var competition = CompetitionClient.storageUnavailable()
        competition.previewInvite = { _ in MultiUserCompetitionTestLabFixtures.claimPreview }
        $0.competitionClient = competition
        $0.permissionOnboardingClient = PermissionOnboardingClient(
            requestHealthAccess: {},
            deferNotifications: {},
            healthAccess: { .notRequested },
            notificationsDeferred: { true }
        )
        $0.date = .constant(MultiUserCompetitionTestLabFixtures.labNow)
    }

    var body: some View {
        MainTabView(store: store)
    }
}

/// Someone's challenge link opened on this iPhone: "Challenge Maya?".
private struct MultiUserCompetitionChallengeLinkTestLabView: View {
    @State private var status: CompetitionFeature.ChallengeSheetStatus = .ready
    @State private var isPresented = true

    var body: some View {
        Color.clear
            .sheet(isPresented: $isPresented) {
                ChallengeFromLinkView(
                    link: MainTabFeature.ChallengeFromLink(
                        sequence: 1,
                        code: CompetitionChallengeLinkCode(
                            rawValue: MultiUserCompetitionTestLabFixtures.samLinkCode
                        )!,
                        status: .ready(displayName: "Maya")
                    ),
                    status: status,
                    send: { status = .creating },
                    retry: {},
                    openCompetition: { _ in isPresented = false },
                    close: { isPresented = false }
                )
            }
            .accessibilityIdentifier("multiuser.challenge-link.root")
    }
}

private struct MultiUserCompetitionAccountTestLabView: View {
    @State private var openedURL: URL?
    @State private var challengeURL = URL(string: "https://invites.ui.healthcomp.test/c/Xb3kP9qL2mN8vR4tY6wZ1a")
    @State private var muted = [
        AccountMutedPerson(id: "remote-opponent:v1:hermes", name: "Hermes"),
    ]
    let store: StoreOf<AccountFeature>
    let hasPendingChallenge: Bool

    init(
        mode: AccountFeature.State.Mode = .authenticated,
        hasPendingChallenge: Bool = false
    ) {
        self.hasPendingChallenge = hasPendingChallenge
        self.store = Store(
            initialState: AccountFeature.State(
                mode: mode,
                displayName: "Beta Alice"
            )
        ) {
            AccountFeature()
            Reduce<AccountFeature.State, AccountFeature.Action> { _, action in
                if case .delegate(.deleteAccountRequested) = action {
                    return .send(.operationFailed(.operationFailed))
                }
                return .none
            }
        } withDependencies: {
            $0.authenticationClient = .testValue
        }
    }

    var body: some View {
        NavigationStack {
            if store.mode == .signedOut {
                AccountView(store: store, hasPendingChallenge: hasPendingChallenge)
            } else {
                AccountSettingsView(
                    store: store,
                    notifications: AccountNotificationSettings(
                        authorization: .denied,
                        isRequestInFlight: false,
                        request: {},
                        mutedPeople: muted,
                        unmute: { id in muted.removeAll { $0.id == id } }
                    ),
                    health: AccountHealthSettings(
                        access: .requested,
                        isReadFailing: false,
                        connect: {}
                    ),
                    liveMatchCount: 2,
                    challengeLink: AccountChallengeLink(
                        url: challengeURL,
                        failed: false,
                        load: {},
                        isResetting: false,
                        resetFailed: false,
                        reset: {
                            challengeURL = URL(string: "https://invites.ui.healthcomp.test/c/Qm7tR2vX9pL4kN8wB3cY6z")
                        }
                    )
                )
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            openedURL = url
            return .handled
        })
        .safeAreaInset(edge: .bottom) {
            if let openedURL {
                Text(openedURL.absoluteString)
            }
        }
        .accessibilityIdentifier("multiuser.account.root")
    }
}

private enum MultiUserCompetitionTestLabFixtures {
    static let scheduledID = CompetitionID(
        UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!
    )
    static let activeID = CompetitionID(
        UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!
    )
    static let completedID = CompetitionID(
        UUID(uuidString: "A1000000-0000-4000-8000-000000000003")!
    )
    static let archivedID = CompetitionID(
        UUID(uuidString: "A1000000-0000-4000-8000-000000000004")!
    )
    static let pendingID = CompetitionID(
        UUID(uuidString: "A1000000-0000-4000-8000-000000000005")!
    )
    static let secondActiveID = CompetitionID(
        UUID(uuidString: "A1000000-0000-4000-8000-000000000006")!
    )
    static let expiredID = CompetitionID(
        UUID(uuidString: "A1000000-0000-4000-8000-000000000007")!
    )
    /// The signed-in lab account's own code.
    static let ownProfileID = UUID(
        uuidString: "a1000000-0000-4000-8000-000000000099"
    )!
    static let expiredRecipientID = UUID(
        uuidString: "A1000000-0000-4000-8000-000000000008"
    )!
    /// Jordan's finished week before the live one: Jordan holds the belt.
    static let jordanPastID = CompetitionID(
        UUID(uuidString: "A1000000-0000-4000-8000-000000000009")!
    )
    /// A finished week with a real name, for Share Result's Show/Hide name.
    static let caseyID = CompetitionID(
        UUID(uuidString: "A1000000-0000-4000-8000-00000000000A")!
    )
    /// An archived win decided at 2 decimals against the longest allowed name.
    static let longNameID = CompetitionID(
        UUID(uuidString: "A1000000-0000-4000-8000-00000000000D")!
    )
    static let longName = "Maximiliana Alexandrovna Featherstonehaugh-Montgomery Wellington"
    static let samLinkCode = "SamSamSamSamSamSamSam1"
    static let ownLinkCode = "OwnOwnOwnOwnOwnOwnOwn1"
    static let labNow = Date(timeIntervalSince1970: 1_786_867_200)
    static let claimPreview = CompetitionInvitePreview(
        competitionID: pendingID.rawValue,
        state: .pending,
        sender: AuthenticatedProfile(id: expiredRecipientID, displayName: "Naren"),
        timeZoneIdentifier: "America/Los_Angeles",
        expiresAt: labNow.addingTimeInterval(20 * 60 * 60)
    )

    static func publication(
        archivedIDs: Set<CompetitionID>
    ) -> LocalCompetitionPublication {
        let completedAt = Date(timeIntervalSince1970: 1_787_212_800)
        let scheduled = presentation(
            id: scheduledID,
            opponentName: "Priya",
            lifecycle: .scheduled,
            userPoints: 0,
            opponentPoints: 0,
            days: [],
            currentDayOrdinal: nil,
            terminal: nil
        )
        let active = presentation(
            id: activeID,
            opponentName: "Jordan",
            lifecycle: .active(dayOrdinal: 3),
            userPoints: 1_450,
            opponentPoints: 1_440,
            days: activeDays(),
            currentDayOrdinal: 3,
            terminal: nil,
            refreshedAt: evaluatedAt.addingTimeInterval(-600),
            opponentUpdatedAt: evaluatedAt.addingTimeInterval(-3_600)
        )
        // A second live match that ends a day after Jordan's, with a
        // refresh problem of its own.
        let secondActive = presentation(
            id: secondActiveID,
            opponentName: "Riley",
            lifecycle: .active(dayOrdinal: 2),
            userPoints: 1_020,
            opponentPoints: 990,
            days: activeDays(startDay: 14, currentDay: 2),
            currentDayOrdinal: 2,
            terminal: nil,
            startDay: 14
        )
        let expired = presentation(
            id: expiredID,
            opponentName: "Taylor",
            lifecycle: .expired(
                at: evaluatedAt.addingTimeInterval(-2 * 60 * 60),
                direction: .outgoing
            ),
            userPoints: 0,
            opponentPoints: 0,
            days: [],
            currentDayOrdinal: nil,
            terminal: nil,
            opponentIdentity: RemoteCompetitionOpponentIdentity.identity(
                for: expiredRecipientID
            )
        )
        let completedTerminal = LocalCompetitionTerminalPresentation(
            userPoints: 3_520,
            opponentPoints: 3_410,
            outcome: .win,
            basis: .stableAcrossPostBoundaryReads,
            completedAt: completedAt
        )
        let completedLifecycle: LocalCompetitionLifecyclePresentation =
            archivedIDs.contains(completedID)
                ? .archived(
                    outcome: .win,
                    basis: .stableAcrossPostBoundaryReads,
                    completedAt: completedAt,
                    archivedAt: completedAt.addingTimeInterval(86_400)
                )
                : .completed(
                    outcome: .win,
                    basis: .stableAcrossPostBoundaryReads,
                    completedAt: completedAt
                )
        let completed = presentation(
            id: completedID,
            opponentName: "Former competitor",
            lifecycle: completedLifecycle,
            userPoints: 3_520,
            opponentPoints: 3_410,
            days: [],
            currentDayOrdinal: nil,
            terminal: completedTerminal
        )
        let archivedTerminal = LocalCompetitionTerminalPresentation(
            userPoints: 3_000,
            opponentPoints: 3_000,
            outcome: .tie,
            basis: .bestAvailable,
            completedAt: completedAt.addingTimeInterval(-604_800)
        )
        let archived = presentation(
            id: archivedID,
            opponentName: "Morgan",
            lifecycle: .archived(
                outcome: .tie,
                basis: .bestAvailable,
                completedAt: archivedTerminal.completedAt,
                archivedAt: archivedTerminal.completedAt
                    .addingTimeInterval(86_400)
            ),
            userPoints: 3_000,
            opponentPoints: 3_000,
            days: [],
            currentDayOrdinal: nil,
            terminal: archivedTerminal
        )
        let pending = presentation(
            id: pendingID,
            opponentName: "Sam",
            lifecycle: .pending(
                direction: .outgoing,
                createdAt: Date(timeIntervalSince1970: 1_786_867_200),
                expiresAt: Date(timeIntervalSince1970: 1_786_867_200 + 86_400)
            ),
            userPoints: 0,
            opponentPoints: 0,
            days: [],
            currentDayOrdinal: nil,
            terminal: nil
        )
        let jordanPastCompletedAt = Date(timeIntervalSince1970: 1_786_302_000)
        let jordanPast = presentation(
            id: jordanPastID,
            opponentName: "Jordan",
            lifecycle: .archived(
                outcome: .loss,
                basis: .stableAcrossPostBoundaryReads,
                completedAt: jordanPastCompletedAt,
                archivedAt: jordanPastCompletedAt.addingTimeInterval(86_400)
            ),
            userPoints: 3_050,
            opponentPoints: 3_210,
            days: [],
            currentDayOrdinal: nil,
            terminal: LocalCompetitionTerminalPresentation(
                userPoints: 3_050,
                opponentPoints: 3_210,
                outcome: .loss,
                basis: .stableAcrossPostBoundaryReads,
                completedAt: jordanPastCompletedAt
            ),
            startDay: 1,
            opponentIdentity: active.opponentIdentity
        )
        // Same week as Former competitor; Casey won only Sunday.
        let caseyTerminal = LocalCompetitionTerminalPresentation(
            userPoints: 2_692,
            opponentPoints: 2_800,
            outcome: .loss,
            basis: .stableAcrossPostBoundaryReads,
            completedAt: completedAt
        )
        let casey = presentation(
            id: caseyID,
            opponentName: "Casey",
            lifecycle: .completed(
                outcome: .loss,
                basis: .stableAcrossPostBoundaryReads,
                completedAt: completedAt
            ),
            userPoints: 2_692,
            opponentPoints: 2_800,
            days: completedDays(),
            currentDayOrdinal: nil,
            terminal: caseyTerminal
        )
        // The week before Casey's: you trailed by 90 after Saturday and won by 0.30.
        let longNameCompletedAt = completedAt.addingTimeInterval(-604_800)
        let longNameTerminal = LocalCompetitionTerminalPresentation(
            userPoints: 2_104.30,
            opponentPoints: 2_104,
            outcome: .win,
            basis: .stableAcrossPostBoundaryReads,
            completedAt: longNameCompletedAt
        )
        let longNamed = presentation(
            id: longNameID,
            opponentName: longName,
            lifecycle: .archived(
                outcome: .win,
                basis: .stableAcrossPostBoundaryReads,
                completedAt: longNameCompletedAt,
                archivedAt: longNameCompletedAt.addingTimeInterval(86_400)
            ),
            userPoints: 2_104.30,
            opponentPoints: 2_104,
            days: completedDays(
                startDay: 6,
                owner: [300, 300, 300, 330.3, 290, 290, 294],
                opponent: [330, 330, 330, 300, 300, 260, 254]
            ),
            currentDayOrdinal: nil,
            terminal: longNameTerminal,
            startDay: 6
        )
        let competitions = [
            scheduled, active, completed, archived, pending, secondActive, expired,
            jordanPast, casey, longNamed,
        ]
        let awards = [
            LocalCompetitionAward(
                id: "remote-ui-lab:completed:victory",
                competitionID: completedID,
                awardedAt: completedAt,
                friendDisplayName: "Former competitor",
                opponentIdentity: completed.opponentIdentity
            ),
        ]
        return LocalCompetitionPublication(
            publicationRevision: 1,
            dashboard: LocalCompetitionDashboard(
                competitions: competitions,
                awards: awards,
                issues: [.competitionFailures([secondActiveID])],
                hiddenTerminalCompetitionCount: 0
            ),
            evaluatedAt: evaluatedAt,
            timeZoneIdentifier: "America/Los_Angeles",
            source: .remoteParticipants
        )
    }

    static func shareLink(
        byte: UInt8,
        usesCustomScheme: Bool
    ) -> CompetitionInviteShareLink {
        let rawToken = Data(repeating: byte, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = CompetitionInviteClaimToken(rawValue: rawToken)!
        if usesCustomScheme {
            return CompetitionInviteShareLink(fallbackToken: token)!
        }
        return CompetitionInviteShareLink(
            host: "invites.ui.healthcomp.test",
            token: token
        )!
    }

    private static func presentation(
        id: CompetitionID,
        opponentName: String,
        lifecycle: LocalCompetitionLifecyclePresentation,
        userPoints: Double,
        opponentPoints: Double,
        days: [LocalCompetitionDayPresentation],
        currentDayOrdinal: Int?,
        terminal: LocalCompetitionTerminalPresentation?,
        startDay: Int = 13,
        opponentIdentity: String? = nil,
        refreshedAt: Date? = nil,
        opponentUpdatedAt: Date? = nil
    ) -> LocalCompetitionPresentation {
        let schedule = schedule(startDay: startDay)
        return LocalCompetitionPresentation(
            id: id,
            ownerDisplayName: "Beta Alice",
            opponentDisplayName: opponentName,
            opponentIdentity: opponentIdentity
                ?? "remote-profile:v1:\(id.rawValue.uuidString.lowercased())",
            lifecycle: lifecycle,
            acceptedConfiguration: LocalCompetitionAcceptedPresentation(
                schedule: schedule,
                difficulty: .balanced
            ),
            userPoints: userPoints,
            opponentPoints: opponentPoints,
            days: days,
            currentDayOrdinal: currentDayOrdinal,
            lastRefresh: refreshedAt.map {
                LocalCompetitionRefreshPresentation(
                    trigger: .reconciliationProbe,
                    attemptedAt: $0,
                    readAt: $0,
                    status: .completed
                )
            },
            tally: nil,
            terminalResult: terminal,
            evaluatedAt: evaluatedAt,
            timeZoneIdentifier: "America/Los_Angeles",
            lastSuccessfulFullWindowRefreshAt: refreshedAt,
            opponentUpdatedAt: opponentUpdatedAt
        )
    }

    private static let evaluatedAt = Date(timeIntervalSince1970: 1_786_867_200)

    private static func schedule(startDay: Int = 13) -> CompetitionSchedule {
        let calendar = try! CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        return CompetitionSchedule(
            calendar: calendar,
            startDay: try! CompetitionDay(
                era: 1,
                year: 2026,
                month: 8,
                day: startDay,
                timeZoneIdentifier: calendar.timeZoneIdentifier
            )
        )
    }

    /// All seven days scored. By default you won Sunday (512) only and lost by 108.
    private static func completedDays(
        startDay: Int = 13,
        owner: [Double] = [420, 380, 300, 512, 400, 350, 330],
        opponent: [Double] = [450, 400, 360, 380, 420, 390, 400]
    ) -> [LocalCompetitionDayPresentation] {
        let schedule = schedule(startDay: startDay)
        let days = try! schedule.calendar.sevenDayWindow(startingOn: schedule.startDay)
        return days.enumerated().map { offset, day in
            LocalCompetitionDayPresentation(
                day: day,
                ordinal: offset + 1,
                ownerAcceptedPoints: owner[offset],
                ownerLatestAvailability: .observed,
                opponentRevealedPoints: opponent[offset],
                scoringPolicy: .remoteWireV1
            )
        }
    }

    private static func activeDays(
        startDay: Int = 13,
        currentDay: Int = 3
    ) -> [LocalCompetitionDayPresentation] {
        let schedule = schedule(startDay: startDay)
        let days = try! schedule.calendar.sevenDayWindow(
            startingOn: schedule.startDay
        )
        let owner: [Double?] = [500, 520, 430, nil, nil, nil, nil]
        let opponent: [Double?] = [480, 510, 450, nil, nil, nil, nil]
        // Rings that score exactly the owner points with no ring over 200%,
        // so a real match could produce them.
        func rings(_ move: Double, _ exercise: Double, _ stand: Double, standGoal: Double) -> ActivitySnapshot {
            ActivitySnapshot(
                moveMode: .activeEnergyKilocalories,
                standMode: .standHours,
                move: try! ActivityRingReading(value: move, goal: 500),
                exercise: try! ActivityRingReading(value: exercise, goal: 30),
                standOrRoll: try! ActivityRingReading(value: stand, goal: standGoal),
                pauseState: .running
            )
        }
        let snapshots: [ActivitySnapshot?] = [
            rings(1_000, 60, 12, standGoal: 12),
            rings(1_000, 60, 12, standGoal: 10),
            rings(900, 45, 12, standGoal: 12),
            nil, nil, nil, nil,
        ]
        return days.enumerated().map { offset, day in
            LocalCompetitionDayPresentation(
                day: day,
                ordinal: offset + 1,
                ownerAcceptedPoints: offset < currentDay ? owner[offset] : nil,
                ownerLatestAvailability: offset < currentDay
                    ? .observed
                    : .notYetOccurred,
                opponentRevealedPoints: offset < currentDay ? opponent[offset] : nil,
                ownerAcceptedSnapshot: offset < currentDay ? snapshots[offset] : nil,
                ownerLatestSnapshot: offset < currentDay ? snapshots[offset] : nil,
                scoringPolicy: .remoteWireV1
            )
        }
    }
}

#endif

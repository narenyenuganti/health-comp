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
    /// Match screens with a nudge to send, run through Home's own reducer.
    case nudge
    /// The same matches published as the simulated fixture: never a nudge.
    case nudgeSimulated = "nudge-simulated"
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
        case .nudge:
            MultiUserCompetitionNudgeTestLabView(source: .remoteParticipants)
        case .nudgeSimulated:
            MultiUserCompetitionNudgeTestLabView(source: .simulatedFixture)
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
    @State private var isChallengePresented = false
    @State private var challengeStatus: CompetitionFeature.ChallengeSheetStatus = .ready
    @State private var recipientCode = ""
    @State private var recipient: CompetitionFeature.InviteRecipient?
    @State private var recipientStatus: CompetitionFeature.InviteRecipientStatus = .idle
    @State private var archivedIDs: Set<CompetitionID> = []
    @State private var rematchState: CompetitionFeature.CompetitionRematchState = .available
    @State private var pastedInvitationStatus = "Not checked"
    @State private var labNudges: [CompetitionID: CompetitionFeature.NudgeStatus] = [:]

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack(
                path: CompetitionHomeRoute.stack(
                    path: $path,
                    showsHistory: $showsHistory
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
                    source: .remoteParticipants,
                    nudge: CompetitionNudge(status: labNudges[id], send: {
                        labNudges[id] = .sent(MultiUserCompetitionTestLabFixtures.labNow)
                    })
                )
            case .completed, .archived:
                CompetitionResultView(
                    competition: competition,
                    awards: publication.dashboard.awards,
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
             .healthOnboarding, .healthOnboardingChallenge, .healthOnboardingClaim,
             .nudge, .nudgeSimulated:
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

/// Real matches with stale scores, through Home's own reducer and match
/// screens. Only the server is a stand-in; each person answers a nudge
/// differently (see `nudge(_:)`).
private struct MultiUserCompetitionNudgeTestLabView: View {
    @State private var store: StoreOf<MainTabFeature>

    init(source: CompetitionPublicationSource) {
        typealias Fixtures = MultiUserCompetitionTestLabFixtures
        let hub = LocalCompetitionPublicationHub()
        let server = MultiUserCompetitionNudgeTestLabServer(hub: hub, source: source)
        var state = MainTabFeature.State()
        // Sat 8:00 PM here is Sun noon in Tokyo, the match's zone: still
        // today there, so the confirmation shows.
        state.competition.nudges[Fixtures.nudgeKenjiID] = .sent(
            Fixtures.labNow.addingTimeInterval(-5 * 3_600)
        )
        _store = State(initialValue: Store(initialState: state) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = CompetitionClient(
                start: {
                    let stream = hub.stream()
                    server.publish()
                    return stream
                },
                updates: { hub.stream() },
                reconcileAll: { _ in server.publish() },
                accept: { _ in server.publish() },
                decline: { _ in server.publish() },
                archive: { _ in server.publish() },
                rematch: { _ in server.publish() },
                reinvite: { server.publish() },
                waitUntil: { _ in },
                stop: { hub.finish() },
                nudge: { try await server.nudge($0) }
            )
            $0.competitionRoutingClient = CompetitionRoutingClient(
                routes: { AsyncStream { _ in } },
                enqueue: { _ in },
                consume: { _ in }
            )
            $0.permissionOnboardingClient = .inert
            $0.date = .constant(Fixtures.labNow)
        })
    }

    var body: some View {
        MainTabView(store: store)
            .accessibilityIdentifier("multiuser.nudge.root")
    }
}

private final class MultiUserCompetitionNudgeTestLabServer: @unchecked Sendable {
    private let hub: LocalCompetitionPublicationHub
    private let source: CompetitionPublicationSource
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var calls: [CompetitionID: Int] = [:]

    init(hub: LocalCompetitionPublicationHub, source: CompetitionPublicationSource) {
        self.hub = hub
        self.source = source
    }

    /// Every reconcile publishes a newer revision of the same matches.
    @discardableResult
    func publish() -> LocalCompetitionPublication {
        let next = lock.withLock { () -> UInt64 in
            revision += 1
            return revision
        }
        let publication = MultiUserCompetitionTestLabFixtures.nudgePublication(
            revision: next,
            source: source
        )
        hub.publish(publication)
        return publication
    }

    func nudge(_ id: CompetitionID) async throws -> Date {
        typealias Fixtures = MultiUserCompetitionTestLabFixtures
        let call = lock.withLock { () -> Int in
            calls[id, default: 0] += 1
            return calls[id]!
        }
        switch id {
        case Fixtures.nudgeRileyID:
            // Long enough to see the button disabled while it sends.
            try await Task.sleep(for: .seconds(4))
            return Fixtures.labNow
        case Fixtures.nudgeSamID where call == 1:
            try await Task.sleep(for: .seconds(1))
            throw CompetitionRemoteFailure.operationFailed
        case Fixtures.nudgeCaseyID:
            throw CompetitionRemoteFailure.forbidden
        case Fixtures.nudgeLongNameID:
            // The server's clock is already in the next match day (Mon
            // 12:01 AM); this iPhone's last projection is older.
            return Fixtures.labNow.addingTimeInterval(23 * 3_600 + 60)
        default:
            return Fixtures.labNow
        }
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
    static let nudgeJordanID = nudgeID(1)
    static let nudgeRileyID = nudgeID(2)
    static let nudgeSamID = nudgeID(3)
    static let nudgeCaseyID = nudgeID(4)
    static let nudgeMorganID = nudgeID(5)
    static let nudgeAveryID = nudgeID(6)
    static let nudgeQuinnID = nudgeID(7)
    static let nudgePriyaID = nudgeID(8)
    static let nudgeLongNameID = nudgeID(9)
    static let nudgeKenjiID = nudgeID(10)
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
            startDay: 14,
            // 13 h old: Riley's match offers a nudge.
            opponentUpdatedAt: evaluatedAt.addingTimeInterval(-46_800)
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
        let competitions = [
            scheduled, active, completed, archived, pending, secondActive, expired,
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

    private static func nudgeID(_ n: Int) -> CompetitionID {
        CompetitionID(UUID(uuidString: String(format: "B1000000-0000-4000-8000-%012d", n))!)
    }

    /// Ten real matches, one per nudge state. Now is Sun Aug 16, 1:00 AM
    /// in Los Angeles (5:00 PM in Tokyo).
    static func nudgePublication(
        revision: UInt64,
        source: CompetitionPublicationSource
    ) -> LocalCompetitionPublication {
        let hour: TimeInterval = 3_600
        func live(
            _ id: CompetitionID,
            _ name: String,
            day: Int,
            updatedAgo: TimeInterval?,
            zone: String = "America/Los_Angeles"
        ) -> LocalCompetitionPresentation {
            // Today is Aug 16 in both zones.
            let startDay = 17 - day
            return presentation(
                id: id,
                opponentName: name,
                lifecycle: day == 7 ? .endsToday : .active(dayOrdinal: day),
                userPoints: 1_020,
                opponentPoints: 990,
                days: activeDays(startDay: startDay, currentDay: day, zone: zone),
                currentDayOrdinal: day,
                terminal: nil,
                startDay: startDay,
                opponentUpdatedAt: updatedAgo.map { evaluatedAt.addingTimeInterval(-$0) },
                zone: zone
            )
        }
        func tallying(
            _ id: CompetitionID,
            _ name: String,
            _ attention: LocalCompetitionTallyAttention
        ) -> LocalCompetitionPresentation {
            presentation(
                id: id,
                opponentName: name,
                lifecycle: .tallying(startedAt: evaluatedAt.addingTimeInterval(-17 * hour)),
                userPoints: 3_400,
                opponentPoints: 3_345,
                days: activeDays(startDay: 9, currentDay: 7),
                currentDayOrdinal: nil,
                terminal: nil,
                startDay: 9,
                opponentUpdatedAt: evaluatedAt.addingTimeInterval(-20 * hour),
                tally: LocalCompetitionTallyPresentation(
                    attention: attention,
                    consecutiveStableCompleteReads: 0,
                    stabilityStart: nil,
                    bestAvailableDeadline: evaluatedAt.addingTimeInterval(31 * hour)
                )
            )
        }
        let competitions = [
            live(nudgeJordanID, "Jordan", day: 3, updatedAgo: 1 * hour),
            live(nudgeRileyID, "Riley", day: 2, updatedAgo: 13 * hour),
            // Never uploaded: stale since Day 1 began.
            live(nudgeSamID, "Sam", day: 2, updatedAgo: nil),
            live(nudgeCaseyID, "Casey", day: 7, updatedAgo: 20 * hour),
            tallying(nudgeMorganID, "Morgan", .awaitingOpponentCheck),
            tallying(nudgeAveryID, "Avery", .opponentPlanUnavailable),
            tallying(nudgeQuinnID, "Quinn", .awaitingStability),
            presentation(
                id: nudgePriyaID,
                opponentName: "Priya",
                lifecycle: .scheduled,
                userPoints: 0,
                opponentPoints: 0,
                days: [],
                currentDayOrdinal: nil,
                terminal: nil,
                startDay: 18
            ),
            live(
                nudgeLongNameID,
                "Alexandria Montgomery-Featherstonehaugh",
                day: 2,
                updatedAgo: 15 * hour
            ),
            live(nudgeKenjiID, "Kenji", day: 2, updatedAgo: 14 * hour, zone: "Asia/Tokyo"),
        ]
        return LocalCompetitionPublication(
            publicationRevision: revision,
            dashboard: LocalCompetitionDashboard(
                competitions: competitions,
                awards: [],
                issues: [],
                hiddenTerminalCompetitionCount: 0
            ),
            evaluatedAt: evaluatedAt,
            timeZoneIdentifier: "America/Los_Angeles",
            source: source
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
        opponentUpdatedAt: Date? = nil,
        zone: String = "America/Los_Angeles",
        tally: LocalCompetitionTallyPresentation? = nil
    ) -> LocalCompetitionPresentation {
        let schedule = schedule(startDay: startDay, zone: zone)
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
            tally: tally,
            terminalResult: terminal,
            evaluatedAt: evaluatedAt,
            timeZoneIdentifier: zone,
            lastSuccessfulFullWindowRefreshAt: refreshedAt,
            opponentUpdatedAt: opponentUpdatedAt
        )
    }

    private static let evaluatedAt = Date(timeIntervalSince1970: 1_786_867_200)

    private static func schedule(
        startDay: Int = 13,
        zone: String = "America/Los_Angeles"
    ) -> CompetitionSchedule {
        let calendar = try! CompetitionCalendar(timeZoneIdentifier: zone)
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

    private static func activeDays(
        startDay: Int = 13,
        currentDay: Int = 3,
        zone: String = "America/Los_Angeles"
    ) -> [LocalCompetitionDayPresentation] {
        let schedule = schedule(startDay: startDay, zone: zone)
        let days = try! schedule.calendar.sevenDayWindow(
            startingOn: schedule.startDay
        )
        let owner: [Double?] = [500, 520, 430, 500, 520, 430, 500]
        let opponent: [Double?] = [480, 510, 450, 490, 505, 440, 470]
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
            rings(1_000, 60, 12, standGoal: 12),
            rings(1_000, 60, 12, standGoal: 10),
            rings(900, 45, 12, standGoal: 12),
            rings(1_000, 60, 12, standGoal: 12),
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

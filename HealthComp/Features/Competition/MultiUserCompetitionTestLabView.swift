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
    /// A real account's challenge to you: Decline, Decline and Block, ••• Block.
    case incomingChallenge = "incoming-challenge"
    /// Home and Account through the real app root: block from a challenge,
    /// then Unblock. Nobody is blocked yet.
    case block
    /// The same, with two people already blocked.
    case blockedAccount = "blocked-account"
    /// The same, with Naren's challenge link opened in the claim sheet.
    case blockClaim = "block-claim"
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
        case .incomingChallenge:
            MultiUserCompetitionIncomingChallengeTestLabView()
        case .block, .blockedAccount, .blockClaim:
            MultiUserCompetitionBlockTestLabView(scenario: configuration.scenario)
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
                    source: .remoteParticipants
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
             .incomingChallenge, .block, .blockedAccount, .blockClaim:
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
                    block: { outcome = .declined },
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

/// Alex's challenge to you, as a real account: the outcome stands in for the server.
private struct MultiUserCompetitionIncomingChallengeTestLabView: View {
    @State private var outcome: String?

    var body: some View {
        NavigationStack {
            if let outcome {
                Text(outcome)
                    .accessibilityIdentifier("multiuser.incoming.outcome")
            } else {
                CompetitionInviteView(
                    competition: MultiUserCompetitionTestLabFixtures.incomingChallenge,
                    source: .remoteParticipants,
                    isCommandInFlight: false,
                    link: nil,
                    send: { action in
                        switch action {
                        case .declineTapped: outcome = "Declined"
                        case .blockTapped: outcome = "Declined and blocked"
                        default: break
                        }
                    }
                )
            }
        }
        .accessibilityIdentifier("multiuser.incoming.root")
    }
}

/// Blocking through the app's own root, Home and Account reducers; only the
/// server is a stand-in (see `MultiUserCompetitionBlockTestLabServer`).
private struct MultiUserCompetitionBlockTestLabView: View {
    @State private var mainStore: StoreOf<MainTabFeature>
    @State private var accountStore: StoreOf<AccountFeature>

    init(scenario: MultiUserCompetitionTestLabScenario) {
        typealias Fixtures = MultiUserCompetitionTestLabFixtures
        let hub = LocalCompetitionPublicationHub()
        let server = MultiUserCompetitionBlockTestLabServer(
            hub: hub,
            seeded: scenario == .blockedAccount
        )
        var state = MainTabFeature.State()
        state.competition.ownProfile = AuthenticatedProfile(
            id: Fixtures.ownProfileID,
            displayName: "Beta Alice"
        )
        let claims = scenario == .blockClaim
        _mainStore = State(initialValue: Store(initialState: state) {
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
                decline: { await server.close($0, block: false) },
                archive: { _ in server.publish() },
                rematch: { _ in server.publish() },
                reinvite: { server.publish() },
                waitUntil: { _ in },
                stop: { hub.finish() },
                block: { await server.close($0, block: true) },
                loadBlockedProfiles: { try await server.blockedProfiles() },
                unblock: { try await server.unblock($0) },
                previewInvite: { _ in Fixtures.claimPreview },
                loadChallengeLinkCode: {
                    CompetitionChallengeLinkCode(rawValue: Fixtures.ownLinkCode)!
                }
            )
            $0.competitionInviteLinkClient.makeChallengeLink = {
                URL(string: "https://invites.ui.healthcomp.test/c/\($0.rawValue)")
            }
            $0.competitionRoutingClient = CompetitionRoutingClient(
                routes: {
                    AsyncStream {
                        if claims {
                            let token = CompetitionInviteClaimToken(
                                rawValue: String(repeating: "B", count: 43)
                            )!
                            $0.yield(CompetitionRouteEnvelope(sequence: 1, route: .claimInvite(token)))
                        }
                    }
                },
                enqueue: { _ in },
                consume: { _ in }
            )
            $0.permissionOnboardingClient = .inert
            $0.date = .constant(Fixtures.labNow)
        })
        _accountStore = State(initialValue: Store(
            initialState: AccountFeature.State(mode: .authenticated, displayName: "Beta Alice")
        ) {
            AccountFeature()
        } withDependencies: {
            $0.authenticationClient = .testValue
        })
    }

    var body: some View {
        AuthenticatedRootView(mainStore: mainStore, accountStore: accountStore)
            .accessibilityIdentifier("multiuser.block.root")
    }
}

/// Alex's block takes 2 s, so the disabled screen can be seen. Sam's first
/// block and Naren's first claim-sheet block fail. Alexandria's first
/// Unblock fails; every Unblock takes 1.5 s.
private final class MultiUserCompetitionBlockTestLabServer: @unchecked Sendable {
    typealias Fixtures = MultiUserCompetitionTestLabFixtures
    private let hub: LocalCompetitionPublicationHub
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var closed: Set<CompetitionID>
    private var rejected: Set<CompetitionID> = []
    private var blockCalls: [CompetitionID: Int] = [:]
    private var unblockCalls: [UUID: Int] = [:]
    /// Newest first.
    private var blocked: [AuthenticatedProfile]

    init(hub: LocalCompetitionPublicationHub, seeded: Bool) {
        self.hub = hub
        // A block declines the pending challenge, so a seeded block has none.
        closed = seeded ? [Fixtures.blockLongNameID] : []
        blocked = seeded
            ? [Fixtures.blockSender(Fixtures.blockLongNameID)!, Fixtures.blockedMorgan]
            : []
    }

    @discardableResult
    func publish() -> LocalCompetitionPublication {
        // The revision and its state move together, so a newer revision is
        // always the newer state even when two publishes race.
        let publication = lock.withLock {
            revision += 1
            return Fixtures.blockPublication(revision: revision, closed: closed, rejected: rejected)
        }
        hub.publish(publication)
        return publication
    }

    func close(_ id: CompetitionID, block: Bool) async -> LocalCompetitionPublication {
        let call = lock.withLock {
            rejected.remove(id)
            blockCalls[id, default: 0] += block ? 1 : 0
            return blockCalls[id] ?? 0
        }
        if block, id == Fixtures.blockAlexID {
            try? await Task.sleep(for: .seconds(2))
        }
        if block, call == 1, id == Fixtures.blockSamID || id == Fixtures.blockClaimID {
            try? await Task.sleep(for: .seconds(1))
            lock.withLock { _ = rejected.insert(id) }
            return publish()
        }
        lock.withLock {
            closed.insert(id)
            if block, let sender = Fixtures.blockSender(id) {
                blocked.removeAll { $0.id == sender.id }
                blocked.insert(sender, at: 0)
            }
        }
        return publish()
    }

    func blockedProfiles() async throws -> [AuthenticatedProfile] {
        try await Task.sleep(for: .milliseconds(300))
        return lock.withLock { blocked }
    }

    func unblock(_ id: UUID) async throws {
        try await Task.sleep(for: .seconds(1.5))
        let longName = Fixtures.blockSender(Fixtures.blockLongNameID)?.id
        try lock.withLock {
            unblockCalls[id, default: 0] += 1
            if id == longName, unblockCalls[id] == 1 {
                throw CompetitionRemoteFailure.operationFailed
            }
            blocked.removeAll { $0.id == id }
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
    @State private var blocked = [
        AuthenticatedProfile(
            id: UUID(uuidString: "a1000000-0000-4000-8000-0000000000b1")!,
            displayName: "Alex"
        ),
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
                    ),
                    blockedPeople: AccountBlockedPeople(
                        people: blocked,
                        unblocking: [],
                        unblockFailed: false,
                        load: {},
                        unblock: { id in blocked.removeAll { $0.id == id } }
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
    static let incomingID = CompetitionID(
        UUID(uuidString: "A1000000-0000-4000-8000-00000000000B")!
    )
    static let incomingChallenge = presentation(
        id: incomingID,
        opponentName: "Alex",
        lifecycle: .pending(
            direction: .incoming,
            createdAt: labNow,
            expiresAt: labNow.addingTimeInterval(20 * 60 * 60)
        ),
        userPoints: 0,
        opponentPoints: 0,
        days: [],
        currentDayOrdinal: nil,
        terminal: nil
    )
    static let blockAlexID = blockID(1)
    static let blockSamID = blockID(2)
    static let blockLongNameID = blockID(3)
    static let blockPriyaID = blockID(4)
    static let blockJordanID = blockID(5)
    /// The claim sheet's challenge: `claimPreview` is this one.
    static let blockClaimID = pendingID
    static let blockedMorgan = AuthenticatedProfile(
        id: UUID(uuidString: "c1000000-0000-4000-8000-0000000000b4")!,
        displayName: "Morgan"
    )

    /// Who sent each incoming challenge in the block lab.
    static func blockSender(_ id: CompetitionID) -> AuthenticatedProfile? {
        func profile(_ suffix: String, _ name: String) -> AuthenticatedProfile {
            AuthenticatedProfile(
                id: UUID(uuidString: "c1000000-0000-4000-8000-0000000000\(suffix)")!,
                displayName: name
            )
        }
        switch id {
        case blockAlexID: return profile("b1", "Alex")
        case blockSamID: return profile("b2", "Sam")
        case blockLongNameID: return profile("b3", "Alexandria Montgomery-Featherstonehaugh")
        case blockClaimID: return claimPreview.sender
        default: return nil
        }
    }

    private static func blockID(_ n: Int) -> CompetitionID {
        CompetitionID(UUID(uuidString: String(format: "C1000000-0000-4000-8000-%012d", n))!)
    }

    /// Four challenges to you, one from you and a live match. A closed
    /// incoming challenge leaves Home, as `list_challenges` drops it.
    static func blockPublication(
        revision: UInt64,
        closed: Set<CompetitionID>,
        rejected: Set<CompetitionID>
    ) -> LocalCompetitionPublication {
        func pending(
            _ id: CompetitionID,
            _ name: String,
            _ direction: InvitationDirection,
            sentAgo hours: Double
        ) -> LocalCompetitionPresentation {
            presentation(
                id: id,
                opponentName: name,
                lifecycle: .pending(
                    direction: direction,
                    createdAt: labNow.addingTimeInterval(-hours * 3_600),
                    expiresAt: labNow.addingTimeInterval((24 - hours) * 3_600)
                ),
                userPoints: 0,
                opponentPoints: 0,
                days: [],
                currentDayOrdinal: nil,
                terminal: nil
            )
        }
        let incoming = [
            pending(blockAlexID, "Alex", .incoming, sentAgo: 1),
            pending(blockSamID, "Sam", .incoming, sentAgo: 2),
            pending(blockLongNameID, "Alexandria Montgomery-Featherstonehaugh", .incoming, sentAgo: 3),
            pending(blockClaimID, "Naren", .incoming, sentAgo: 4),
        ].filter { !closed.contains($0.id) }
        let competitions = incoming + [
            pending(blockPriyaID, "Priya", .outgoing, sentAgo: 5),
            presentation(
                id: blockJordanID,
                opponentName: "Jordan",
                lifecycle: .active(dayOrdinal: 3),
                userPoints: 1_450,
                opponentPoints: 1_440,
                days: activeDays(),
                currentDayOrdinal: 3,
                terminal: nil
            ),
        ]
        return LocalCompetitionPublication(
            publicationRevision: revision,
            dashboard: LocalCompetitionDashboard(
                competitions: competitions,
                awards: [],
                issues: rejected
                    .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
                    .map { .commandRejected($0) },
                hiddenTerminalCompetitionCount: 0
            ),
            evaluatedAt: evaluatedAt,
            timeZoneIdentifier: "America/Los_Angeles",
            source: .remoteParticipants
        )
    }

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

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
    /// Match screens with a nudge to send, run through Home's own reducer.
    case nudge
    /// The same matches published as the simulated fixture: never a nudge.
    case nudgeSimulated = "nudge-simulated"
    /// Live matches where you're behind, level or ahead: the Today page's
    /// what-it-takes panel in each state.
    case whatItTakes = "what-it-takes"
    /// Real matches with reactions, run through Home's own reducer.
    case reactions
    /// The same matches published as the simulated fixture: never a reaction.
    case reactionsSimulated = "reactions-simulated"
    /// The final-day Live Activity's views, and a button that starts a real one.
    case liveActivity = "live-activity"
    /// The empty Home with Practice Match, run through Home's own reducer.
    case practice
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
        case .sharing, .sharingCustomScheme, .whatItTakes:
            MultiUserCompetitionSharingTestLabView(
                usesCustomScheme: configuration.scenario == .sharingCustomScheme,
                showsWhatItTakes: configuration.scenario == .whatItTakes
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
        case .nudge:
            MultiUserCompetitionNudgeTestLabView(source: .remoteParticipants)
        case .nudgeSimulated:
            MultiUserCompetitionNudgeTestLabView(source: .simulatedFixture)
        case .reactions:
            MultiUserCompetitionReactionsTestLabView(source: .remoteParticipants)
        case .reactionsSimulated:
            MultiUserCompetitionReactionsTestLabView(source: .simulatedFixture)
        case .liveActivity:
            LiveActivityPreviewView()
        case .practice:
            MultiUserCompetitionPracticeTestLabView()
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
    var showsWhatItTakes = false
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
    @State private var labNudges: [CompetitionID: CompetitionFeature.NudgeStatus] = [:]
    @State private var ownReactions: [CompetitionReactionKey: CompetitionReactionKind] = [:]

    /// Once per process, never per init: SwiftUI re-runs child inits
    /// whenever the root re-evaluates. Launch arguments can't do this: an
    /// argument-domain value would mask the app's own writes.
    private static let resetReactionsSeen: Void = UserDefaults.standard
        .removeObject(forKey: CompetitionReactionsSeen.storageKey)

    init(usesCustomScheme: Bool, showsWhatItTakes: Bool = false) {
        self.usesCustomScheme = usesCustomScheme
        self.showsWhatItTakes = showsWhatItTakes
        _ = Self.resetReactionsSeen
    }

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
                    source: .remoteParticipants,
                    nudge: CompetitionNudge(status: labNudges[id], send: {
                        labNudges[id] = .sent(MultiUserCompetitionTestLabFixtures.labNow)
                    }),
                    reactions: reactionControl(id)
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
                    openCompetition: { path.append($0) },
                    reactions: reactionControl(id)
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
        showsWhatItTakes
            ? MultiUserCompetitionTestLabFixtures.whatItTakesPublication()
            : MultiUserCompetitionTestLabFixtures.publication(
                archivedIDs: archivedIDs,
                ownReactions: ownReactions
            )
    }

    /// Saves at once; the same preset again removes it, as on the server.
    private func reactionControl(_ id: CompetitionID) -> CompetitionReactionControl {
        CompetitionReactionControl(pending: [:], failed: []) { target, kind in
            let key = CompetitionReactionKey(competitionID: id, target: target)
            ownReactions[key] = ownReactions[key] == kind ? nil : kind
        }
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
             .incomingChallenge, .block, .blockedAccount, .blockClaim,
             .nudge, .nudgeSimulated, .whatItTakes, .reactions, .reactionsSimulated,
             .liveActivity, .practice:
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
        case Fixtures.nudgeRileyID, Fixtures.nudgeMorganID:
            // Long enough to see the button disabled while it sends.
            try await Task.sleep(for: .seconds(4))
            return Fixtures.labNow
        case Fixtures.nudgeSamID where call == 1:
            try await Task.sleep(for: .seconds(1))
            throw CompetitionRemoteFailure.operationFailed
        case Fixtures.nudgeAveryID where call == 1:
            throw CompetitionRemoteFailure.operationFailed
        case Fixtures.nudgeCaseyID, Fixtures.nudgeAveryID:
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

/// Real matches with reactions, through Home's own reducer and screens.
/// Only the server is a stand-in: Jordan's saves take 3 s, Sam's first save
/// fails, Quinn's first save is refused, and a pull to refresh on Home brings
/// a new reaction from Jordan on Day 3.
private struct MultiUserCompetitionReactionsTestLabView: View {
    @State private var store: StoreOf<MainTabFeature>

    /// Once per process, as in the sharing lab: the marks persist otherwise.
    private static let resetReactionsSeen: Void = UserDefaults.standard
        .removeObject(forKey: CompetitionReactionsSeen.storageKey)

    init(source: CompetitionPublicationSource) {
        _ = Self.resetReactionsSeen
        typealias Fixtures = MultiUserCompetitionTestLabFixtures
        let hub = LocalCompetitionPublicationHub()
        let server = MultiUserCompetitionReactionsTestLabServer(hub: hub, source: source)
        _store = State(initialValue: Store(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = CompetitionClient(
                start: {
                    let stream = hub.stream()
                    server.publish()
                    return stream
                },
                updates: { hub.stream() },
                reconcileAll: { trigger in
                    if trigger == .pullToRefresh { server.jordanReactsAgain() }
                    return server.publish()
                },
                accept: { _ in server.publish() },
                decline: { _ in server.publish() },
                archive: { _ in server.publish() },
                rematch: { _ in server.publish() },
                reinvite: { server.publish() },
                waitUntil: { _ in },
                stop: { hub.finish() },
                setReaction: { try await server.setReaction($0, $1, $2) }
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
            .accessibilityIdentifier("multiuser.reactions.root")
    }
}

private final class MultiUserCompetitionReactionsTestLabServer: @unchecked Sendable {
    private let hub: LocalCompetitionPublicationHub
    private let source: CompetitionPublicationSource
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var calls: [CompetitionID: Int] = [:]
    /// Yours: 😤 on Riley's Day 3, sent while that match was live.
    private var own: [CompetitionReactionKey: CompetitionReactionKind] = [
        CompetitionReactionKey(
            competitionID: MultiUserCompetitionTestLabFixtures.reactionRileyID,
            target: .day(3)
        ): .huffing,
    ]
    private var jordanReactedAgain = false

    init(hub: LocalCompetitionPublicationHub, source: CompetitionPublicationSource) {
        self.hub = hub
        self.source = source
    }

    @discardableResult
    func publish() -> LocalCompetitionPublication {
        let (next, own, again) = lock.withLock {
            () -> (UInt64, [CompetitionReactionKey: CompetitionReactionKind], Bool) in
            revision += 1
            return (revision, self.own, jordanReactedAgain)
        }
        let publication = MultiUserCompetitionTestLabFixtures.reactionsPublication(
            revision: next,
            source: source,
            ownReactions: own,
            jordanReactedAgain: again
        )
        hub.publish(publication)
        return publication
    }

    func jordanReactsAgain() {
        lock.withLock { jordanReactedAgain = true }
    }

    func setReaction(
        _ id: CompetitionID,
        _ target: CompetitionReactionTarget,
        _ kind: CompetitionReactionKind?
    ) async throws -> LocalCompetitionPublication {
        typealias Fixtures = MultiUserCompetitionTestLabFixtures
        let call = lock.withLock { () -> Int in
            calls[id, default: 0] += 1
            return calls[id]!
        }
        switch id {
        case Fixtures.reactionJordanID:
            // Long enough to see the chips disabled while it saves.
            try await Task.sleep(for: .seconds(3))
        case Fixtures.reactionSamID where call == 1:
            try await Task.sleep(for: .seconds(1))
            throw CompetitionRemoteFailure.operationFailed
        case Fixtures.reactionQuinnID where call == 1:
            // The server says no (reaction_not_allowed).
            throw CompetitionRemoteFailure.forbidden
        default:
            break
        }
        lock.withLock {
            own[CompetitionReactionKey(competitionID: id, target: target)] = kind
        }
        return publish()
    }
}

/// Practice through the real Home, match screen and result. Start answers
/// after 80 ms with a live practice; End Practice deletes it.
/// `-practiceLab <state>` picks what Home starts with (see
/// `MultiUserCompetitionPracticeTestLabServer.Setup`); `-practiceLabFinished YES`
/// is `-practiceLab won`. `-practiceLabFailStarts N` / `-practiceLabFailEnds N`
/// reject the first N starts or ends; `-practiceLabNotifications YES` reports
/// notifications as not yet asked, so the prompt can show.
private struct MultiUserCompetitionPracticeTestLabView: View {
    @State private var store: StoreOf<MainTabFeature>

    init() {
        let hub = LocalCompetitionPublicationHub()
        let defaults = UserDefaults.standard
        let server = MultiUserCompetitionPracticeTestLabServer(
            hub: hub,
            setup: defaults.bool(forKey: "practiceLabFinished")
                ? .won
                : MultiUserCompetitionPracticeTestLabServer.Setup(
                    rawValue: defaults.string(forKey: "practiceLab") ?? ""
                ) ?? .empty,
            failedStarts: defaults.integer(forKey: "practiceLabFailStarts"),
            failedEnds: defaults.integer(forKey: "practiceLabFailEnds")
        )
        let asksNotifications = defaults.bool(forKey: "practiceLabNotifications")
        _store = State(initialValue: Store(initialState: MainTabFeature.State()) {
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
                delete: { await server.delete($0) },
                loadNotificationAuthorizationState: {
                    asksNotifications ? .notDetermined : nil
                },
                waitUntil: { _ in },
                stop: { hub.finish() },
                startPractice: { _ in await server.start() }
            )
            $0.competitionRoutingClient = CompetitionRoutingClient(
                routes: { AsyncStream { _ in } },
                enqueue: { _ in },
                consume: { _ in }
            )
            $0.permissionOnboardingClient = asksNotifications
                ? PermissionOnboardingClient(
                    requestHealthAccess: {},
                    deferNotifications: {},
                    healthAccess: { .requested },
                    notificationsDeferred: { false }
                )
                : .inert
            $0.date = .constant(MultiUserCompetitionTestLabFixtures.labNow)
        })
    }

    var body: some View {
        MainTabView(store: store)
            .accessibilityIdentifier("multiuser.practice.root")
    }
}

private final class MultiUserCompetitionPracticeTestLabServer: @unchecked Sendable {
    enum Setup: String {
        /// "No matches yet"; Start gives a live practice on Day 2.
        case empty = ""
        /// "No matches yet"; Start gives tomorrow's practice, as on an iPhone.
        case startsScheduled = "starts-scheduled"
        /// "Nothing live right now": a finished real week, so no Practice Match.
        case afterRecords = "after-records"
        case scheduled
        case tallying
        case won
        case lost
        case tied
        /// The live practice beside a real live match (Jordan).
        case withLiveMatch = "with-live-match"
        /// The live practice beside a real match that starts later (Priya).
        case withScheduledMatch = "with-scheduled-match"
        /// "No matches yet", then Sam's real challenge arrives 8 s after launch.
        case challengeArrives = "challenge-arrives"
    }

    private typealias Fixtures = MultiUserCompetitionTestLabFixtures
    private let hub: LocalCompetitionPublicationHub
    private let setup: Setup
    private var others: [LocalCompetitionPresentation]
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var practice: LocalCompetitionPresentation?
    private var failedStarts: Int
    private var failedEnds: Int
    /// A rejected command, carried until the next successful one, as the
    /// remote client's `publication(adding:)` does.
    private var rejected: CompetitionID?

    init(hub: LocalCompetitionPublicationHub, setup: Setup, failedStarts: Int, failedEnds: Int) {
        self.hub = hub
        self.setup = setup
        self.failedStarts = failedStarts
        self.failedEnds = failedEnds
        let real = Fixtures.publication(archivedIDs: [Fixtures.archivedID]).dashboard.competitions
        let otherIDs: Set<CompetitionID> = switch setup {
        case .afterRecords: [Fixtures.archivedID]
        case .withLiveMatch: [Fixtures.activeID]
        default: []
        }
        others = setup == .withScheduledMatch
            ? [Fixtures.scheduledTomorrowPresentation()]
            : real.filter { otherIDs.contains($0.id) }
        practice = switch setup {
        case .empty, .startsScheduled, .afterRecords, .challengeArrives: nil
        case .scheduled: Fixtures.practiceScheduledPresentation()
        case .tallying: Fixtures.practiceTallyingPresentation()
        case .won: Fixtures.practiceResultPresentation(.win)
        case .lost: Fixtures.practiceResultPresentation(.loss)
        case .tied: Fixtures.practiceResultPresentation(.tie)
        case .withLiveMatch, .withScheduledMatch: Fixtures.practicePresentation()
        }
        if setup == .challengeArrives {
            let arriving = real.filter { $0.id == Fixtures.pendingID }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self else { return }
                lock.withLock { others = arriving }
                publish()
            }
        }
    }

    @discardableResult
    func publish() -> LocalCompetitionPublication {
        let (next, competitions, issues) = lock.withLock {
            () -> (UInt64, [LocalCompetitionPresentation], [LocalCompetitionClientIssue]) in
            revision += 1
            return (
                revision,
                ([practice].compactMap { $0 } + others).sorted {
                    $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
                },
                rejected.map { [.commandRejected($0)] } ?? []
            )
        }
        let publication = LocalCompetitionPublication(
            publicationRevision: next,
            dashboard: LocalCompetitionDashboard(
                competitions: competitions,
                awards: [],
                issues: issues,
                hiddenTerminalCompetitionCount: 0
            ),
            evaluatedAt: Fixtures.labNow,
            timeZoneIdentifier: "America/Los_Angeles",
            source: .remoteParticipants
        )
        hub.publish(publication)
        return publication
    }

    func start() async -> LocalCompetitionPublication {
        try? await Task.sleep(for: .milliseconds(80))
        lock.withLock {
            if failedStarts > 0 {
                failedStarts -= 1
                rejected = PracticeMatch.startCommandID
            } else {
                rejected = nil
                practice = setup == .startsScheduled
                    ? Fixtures.practiceScheduledPresentation()
                    : Fixtures.practicePresentation()
            }
        }
        return publish()
    }

    func delete(_ id: CompetitionID) async -> LocalCompetitionPublication {
        try? await Task.sleep(for: .milliseconds(80))
        lock.withLock {
            if failedEnds > 0 {
                failedEnds -= 1
                rejected = id
            } else {
                rejected = nil
                if practice?.id == id { practice = nil }
            }
        }
        return publish()
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
                        unblockFailed: nil,
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
    static let reactionJordanID = reactionID(1)
    static let reactionSamID = reactionID(2)
    static let reactionMorganID = reactionID(3)
    static let reactionCaseyID = reactionID(4)
    static let reactionFormerLiveID = reactionID(5)
    static let reactionLongNameID = reactionID(6)
    static let reactionRileyID = reactionID(7)
    static let reactionQuinnID = reactionID(8)
    static let reactionFormerResultID = reactionID(9)
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
        archivedIDs: Set<CompetitionID>,
        ownReactions: [CompetitionReactionKey: CompetitionReactionKind] = [:]
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
        // Reactions only on Jordan, Morgan and Former competitor: other UI
        // tests count cards and match their labels.
        func reactions(
            _ id: CompetitionID,
            received: CompetitionReaction
        ) -> [CompetitionReaction] {
            let own = ownReactions.filter { $0.key.competitionID == id }.map {
                CompetitionReaction(
                    target: $0.key.target,
                    kind: $0.value,
                    isFromYou: true,
                    updatedAt: evaluatedAt
                )
            }
            return ([received] + own).sorted { $0.updatedAt > $1.updatedAt }
        }
        var jordan = active
        jordan.reactions = reactions(activeID, received: CompetitionReaction(
            target: .day(2), kind: .huffing, isFromYou: false,
            updatedAt: evaluatedAt.addingTimeInterval(-1_800)
        ))
        var morgan = archived
        morgan.reactions = reactions(archivedID, received: CompetitionReaction(
            target: .result, kind: .clap, isFromYou: false,
            updatedAt: evaluatedAt.addingTimeInterval(-3_600)
        ))
        var former = completed
        former.reactions = reactions(completedID, received: CompetitionReaction(
            target: .result, kind: .salute, isFromYou: false,
            updatedAt: evaluatedAt.addingTimeInterval(-7_200)
        ))
        let competitions = [
            scheduled, jordan, former, morgan, pending, secondActive, expired,
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
                // Never uploaded: no score either.
                opponentPoints: updatedAgo == nil ? 0 : 990,
                days: activeDays(
                    startDay: startDay,
                    currentDay: day,
                    zone: zone,
                    opponentUploaded: updatedAgo != nil
                ),
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

    private static func reactionID(_ n: Int) -> CompetitionID {
        CompetitionID(UUID(uuidString: String(format: "C1000000-0000-4000-8000-%012d", n))!)
    }

    /// Reactions in every state. Now is Sun Aug 16, 1:00 AM in Los Angeles.
    /// Live: Jordan (Day 3, 😤 on your Day 2), Sam (Day 2, none), Casey
    /// (Day 7), Former competitor (Day 4, 👏 on your Day 1), a long name
    /// (Day 2, 🔥 on your Day 1) and Morgan tallying (🔥 on your Day 6).
    /// Recent results: Riley (👏 on the result and 🔥 on your Day 5), Quinn
    /// (none) and Former competitor (🫡 on the result). The simulated fixture
    /// carries none.
    static func reactionsPublication(
        revision: UInt64,
        source: CompetitionPublicationSource,
        ownReactions: [CompetitionReactionKey: CompetitionReactionKind],
        jordanReactedAgain: Bool
    ) -> LocalCompetitionPublication {
        let hour: TimeInterval = 3_600
        func received(
            _ target: CompetitionReactionTarget,
            _ kind: CompetitionReactionKind,
            ago: TimeInterval
        ) -> CompetitionReaction {
            CompetitionReaction(
                target: target,
                kind: kind,
                isFromYou: false,
                updatedAt: evaluatedAt.addingTimeInterval(-ago)
            )
        }
        func with(
            _ presentation: LocalCompetitionPresentation,
            _ incoming: [CompetitionReaction]
        ) -> LocalCompetitionPresentation {
            var presentation = presentation
            guard source == .remoteParticipants else { return presentation }
            let own = ownReactions.filter { $0.key.competitionID == presentation.id }.map {
                CompetitionReaction(
                    target: $0.key.target,
                    kind: $0.value,
                    isFromYou: true,
                    updatedAt: evaluatedAt
                )
            }
            presentation.reactions = (incoming + own).sorted { $0.updatedAt > $1.updatedAt }
            return presentation
        }
        func live(
            _ id: CompetitionID,
            _ name: String,
            day: Int
        ) -> LocalCompetitionPresentation {
            // Today, Aug 16, is Day `day`.
            let startDay = 17 - day
            return presentation(
                id: id,
                opponentName: name,
                lifecycle: day == 7 ? .endsToday : .active(dayOrdinal: day),
                userPoints: 1_020,
                opponentPoints: 990,
                days: activeDays(startDay: startDay, currentDay: day),
                currentDayOrdinal: day,
                terminal: nil,
                startDay: startDay,
                opponentUpdatedAt: evaluatedAt.addingTimeInterval(-hour)
            )
        }
        func finished(
            _ id: CompetitionID,
            _ name: String,
            _ outcome: CompetitionOutcome,
            owner: [Double],
            other: [Double]
        ) -> LocalCompetitionPresentation {
            // The totals are the days' sums, so the summary line agrees.
            let user = owner.reduce(0, +)
            let opponent = other.reduce(0, +)
            let completedAt = evaluatedAt.addingTimeInterval(-20 * hour)
            return presentation(
                id: id,
                opponentName: name,
                lifecycle: .completed(
                    outcome: outcome,
                    basis: .stableAcrossPostBoundaryReads,
                    completedAt: completedAt
                ),
                userPoints: user,
                opponentPoints: opponent,
                days: completedDays(startDay: 8, owner: owner, opponent: other),
                currentDayOrdinal: nil,
                terminal: LocalCompetitionTerminalPresentation(
                    userPoints: user,
                    opponentPoints: opponent,
                    outcome: outcome,
                    basis: .stableAcrossPostBoundaryReads,
                    completedAt: completedAt
                ),
                startDay: 8
            )
        }
        let tallying = presentation(
            id: reactionMorganID,
            opponentName: "Morgan",
            lifecycle: .tallying(startedAt: evaluatedAt.addingTimeInterval(-17 * hour)),
            userPoints: 3_400,
            opponentPoints: 3_345,
            days: activeDays(startDay: 9, currentDay: 7),
            currentDayOrdinal: nil,
            terminal: nil,
            startDay: 9,
            opponentUpdatedAt: evaluatedAt.addingTimeInterval(-20 * hour),
            tally: LocalCompetitionTallyPresentation(
                attention: .awaitingStability,
                consecutiveStableCompleteReads: 0,
                stabilityStart: nil,
                bestAvailableDeadline: evaluatedAt.addingTimeInterval(31 * hour)
            )
        )
        let competitions = [
            with(
                live(reactionJordanID, "Jordan", day: 3),
                [received(.day(2), .huffing, ago: 0.5 * hour)]
                    + (jordanReactedAgain ? [received(.day(3), .fire, ago: 60)] : [])
            ),
            with(live(reactionSamID, "Sam", day: 2), []),
            with(live(reactionCaseyID, "Casey", day: 7), []),
            with(
                live(reactionFormerLiveID, "Former competitor", day: 4),
                [received(.day(1), .clap, ago: 2 * hour)]
            ),
            with(
                live(reactionLongNameID, "Alexandria Montgomery-Featherstonehaugh", day: 2),
                [received(.day(1), .fire, ago: 3 * hour)]
            ),
            with(tallying, [received(.day(6), .fire, ago: 4 * hour)]),
            with(
                finished(
                    reactionRileyID,
                    "Riley",
                    .win,
                    owner: [520, 500, 480, 510, 500, 520, 490],
                    other: [480, 490, 500, 470, 500, 490, 480]
                ),
                [
                    received(.result, .clap, ago: 5 * hour),
                    received(.day(5), .fire, ago: 4 * 24 * hour),
                ]
            ),
            with(
                finished(
                    reactionQuinnID,
                    "Quinn",
                    .tie,
                    owner: [430, 420, 440, 430, 420, 430, 430],
                    other: [420, 430, 430, 440, 430, 420, 430]
                ),
                []
            ),
            with(
                finished(
                    reactionFormerResultID,
                    "Former competitor",
                    .loss,
                    owner: [420, 380, 300, 512, 400, 350, 330],
                    other: [450, 400, 360, 380, 420, 390, 400]
                ),
                [received(.result, .salute, ago: 6 * hour)]
            ),
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

    static let practiceID = CompetitionID(
        UUID(uuidString: "A1000000-0000-4000-8000-00000000000C")!
    )

    /// Day 2 against the Pacer: 486 to 452 after Day 1, nothing yet today.
    static func practicePresentation() -> LocalCompetitionPresentation {
        let schedule = schedule(startDay: 15)
        let days = try! schedule.calendar.sevenDayWindow(startingOn: schedule.startDay)
        return presentation(
            id: practiceID,
            opponentName: PracticeMatch.opponentDisplayName,
            lifecycle: .active(dayOrdinal: 2),
            userPoints: 486,
            opponentPoints: 452,
            days: days.enumerated().map { offset, day in
                LocalCompetitionDayPresentation(
                    day: day,
                    ordinal: offset + 1,
                    ownerAcceptedPoints: offset == 0 ? 486 : nil,
                    ownerLatestAvailability: offset == 0
                        ? .observed : offset == 1 ? .notSyncedYet : .notYetOccurred,
                    opponentRevealedPoints: offset == 0 ? 452 : offset == 1 ? 0 : nil
                )
            },
            currentDayOrdinal: 2,
            terminal: nil,
            startDay: 15,
            opponentIdentity: PracticeMatch.opponentIdentity
        )
    }

    /// Tomorrow's practice, Mon Aug 17 to Sun Aug 23, as Start Tomorrow makes it.
    static func practiceScheduledPresentation() -> LocalCompetitionPresentation {
        presentation(
            id: practiceID,
            opponentName: PracticeMatch.opponentDisplayName,
            lifecycle: .scheduled,
            userPoints: 0,
            opponentPoints: 0,
            days: [],
            currentDayOrdinal: nil,
            terminal: nil,
            startDay: 17,
            opponentIdentity: PracticeMatch.opponentIdentity
        )
    }

    /// Priya's match starting tomorrow, Mon Aug 17 (labNow is Sun Aug 16).
    static func scheduledTomorrowPresentation() -> LocalCompetitionPresentation {
        presentation(
            id: scheduledID,
            opponentName: "Priya",
            lifecycle: .scheduled,
            userPoints: 0,
            opponentPoints: 0,
            days: [],
            currentDayOrdinal: nil,
            terminal: nil,
            startDay: 17
        )
    }

    /// Aug 8 to 14 has ended; the last reads are still settling.
    static func practiceTallyingPresentation() -> LocalCompetitionPresentation {
        presentation(
            id: practiceID,
            opponentName: PracticeMatch.opponentDisplayName,
            lifecycle: .tallying(startedAt: labNow.addingTimeInterval(-17 * 3_600)),
            userPoints: 2_692,
            opponentPoints: 2_550,
            days: completedDays(
                startDay: 8,
                opponent: [400, 360, 320, 450, 380, 340, 300]
            ),
            currentDayOrdinal: 7,
            terminal: nil,
            startDay: 8,
            opponentIdentity: PracticeMatch.opponentIdentity
        )
    }

    /// A practice week, Aug 8 to 14, still on Home: you won 2,692 to 2,550,
    /// lost 2,692 to 2,800, or tied 2,692 all.
    static func practiceResultPresentation(
        _ outcome: CompetitionOutcome = .win
    ) -> LocalCompetitionPresentation {
        let completedAt = labNow.addingTimeInterval(-14 * 3_600)
        let opponent: [Double] = switch outcome {
        case .win: [400, 360, 320, 450, 380, 340, 300]
        case .loss: [450, 400, 360, 380, 420, 390, 400]
        default: [420, 380, 300, 512, 400, 350, 330]
        }
        let opponentPoints = opponent.reduce(0, +)
        let terminal = LocalCompetitionTerminalPresentation(
            userPoints: 2_692,
            opponentPoints: opponentPoints,
            outcome: outcome,
            basis: .stableAcrossPostBoundaryReads,
            completedAt: completedAt
        )
        return presentation(
            id: practiceID,
            opponentName: PracticeMatch.opponentDisplayName,
            lifecycle: .completed(
                outcome: outcome,
                basis: .stableAcrossPostBoundaryReads,
                completedAt: completedAt
            ),
            userPoints: 2_692,
            opponentPoints: opponentPoints,
            days: completedDays(startDay: 8, opponent: opponent),
            currentDayOrdinal: nil,
            terminal: terminal,
            startDay: 8,
            opponentIdentity: PracticeMatch.opponentIdentity
        )
    }

    /// One live match per what-it-takes state, all under real-match scoring
    /// (200% per ring). The Today day is the lab clock's day, Aug 16.
    static func whatItTakesPublication() -> LocalCompetitionPublication {
        func rings(
            _ move: Double, _ moveGoal: Double, _ exercise: Double, _ stand: Double,
            exerciseGoal: Double = 30, moveMinutes: Bool = false
        ) -> ActivitySnapshot {
            ActivitySnapshot(
                moveMode: moveMinutes ? .moveMinutes : .activeEnergyKilocalories,
                standMode: .standHours,
                move: try! ActivityRingReading(value: move, goal: moveGoal),
                exercise: try! ActivityRingReading(value: exercise, goal: exerciseGoal),
                standOrRoll: try! ActivityRingReading(value: stand, goal: 12),
                pauseState: .running
            )
        }
        func match(
            _ byte: UInt8,
            _ name: String,
            day: Int,
            user: Double,
            opponent: Double,
            today: Double?,
            opponentToday: Double?,
            accepted: ActivitySnapshot?,
            latest: ActivitySnapshot?? = .none
        ) -> LocalCompetitionPresentation {
            let latest = latest ?? accepted
            let startDay = 16 - (day - 1)
            let schedule = schedule(startDay: startDay)
            let window = try! schedule.calendar.sevenDayWindow(startingOn: schedule.startDay)
            // Earlier days share the rest of each total evenly.
            let earlier = Double(max(1, day - 1))
            let days = window.enumerated().map { offset, competitionDay in
                let ordinal = offset + 1
                let isToday = ordinal == day
                return LocalCompetitionDayPresentation(
                    day: competitionDay,
                    ordinal: ordinal,
                    ownerAcceptedPoints: isToday ? today
                        : ordinal < day ? (user - (today ?? 0)) / earlier : nil,
                    ownerLatestAvailability: isToday
                        ? (accepted == nil && latest == nil ? .notSyncedYet : .observed)
                        : ordinal < day ? .observed : .notYetOccurred,
                    opponentRevealedPoints: isToday ? opponentToday
                        : ordinal < day ? (opponent - (opponentToday ?? 0)) / earlier : nil,
                    ownerAcceptedSnapshot: isToday ? accepted : nil,
                    ownerLatestSnapshot: isToday ? latest : nil,
                    scoringPolicy: .remoteWireV1
                )
            }
            return presentation(
                id: CompetitionID(UUID(uuidString: String(
                    format: "A2000000-0000-4000-8000-0000000000%02X", byte
                ))!),
                opponentName: name,
                lifecycle: day == 7 ? .endsToday : .active(dayOrdinal: day),
                userPoints: user,
                opponentPoints: opponent,
                days: days,
                currentDayOrdinal: day,
                terminal: nil,
                startDay: startDay,
                refreshedAt: evaluatedAt.addingTimeInterval(-600),
                opponentUpdatedAt: evaluatedAt.addingTimeInterval(-900)
            )
        }
        let competitions = [
            // The approved mockup: 39 to take the lead, either ring alone.
            match(1, "Sam", day: 5, user: 1_112, opponent: 1_150, today: 215,
                  opponentToday: 248, accepted: rings(410, 600, 24, 8)),
            // Neither ring covers 50 alone, so it splits; a 64-character name.
            match(2, "Bartholomew Alexander Christopherson-Montgomery of Westminster",
                  day: 3, user: 1_000, opponent: 1_049, today: 395,
                  opponentToday: 300, accepted: rings(1_020, 600, 52.5, 6)),
            // Move Time in minutes.
            match(3, "Morgan", day: 4, user: 900, opponent: 938, today: 640.0 / 3,
                  opponentToday: nil, accepted: rings(20, 30, 24, 8, moveMinutes: true)),
            // Level by a fraction, Move capped, and they're at today's 600.
            match(4, "Devon", day: 6, user: 1_000, opponent: 1_000.2, today: 300,
                  opponentToday: 600, accepted: rings(1_200, 600, 15, 6)),
            // Last day, out of reach with room left in Move.
            match(5, "Priya", day: 7, user: 2_010, opponent: 2_390, today: 390,
                  opponentToday: 400, accepted: rings(540, 600, 60, 12)),
            // Level, but you've already scored today's 600.
            match(6, "Quinn", day: 6, user: 2_390, opponent: 2_390, today: 600,
                  opponentToday: 420, accepted: rings(1_200, 600, 60, 24)),
            // Behind, but your rings moved since the accepted reading: no panel.
            match(7, "Harper", day: 5, user: 1_000, opponent: 1_100, today: 215,
                  opponentToday: 300, accepted: rings(410, 600, 24, 8),
                  latest: rings(500, 600, 24, 8)),
            // Behind, and today's reading hasn't synced yet: no panel.
            match(8, "Avery", day: 2, user: 400, opponent: 700, today: nil,
                  opponentToday: 300, accepted: nil, latest: rings(300, 600, 10, 4)),
            // You lead: no panel.
            match(9, "Jordan", day: 3, user: 1_450, opponent: 1_440, today: 430,
                  opponentToday: 450, accepted: rings(900, 500, 45, 12)),
            // Behind with points left today, but Move and Exercise are at 200%.
            match(10, "Riley", day: 5, user: 1_000, opponent: 1_020, today: 450,
                  opponentToday: 300, accepted: rings(1_200, 600, 60, 6)),
        ]
        return LocalCompetitionPublication(
            publicationRevision: 1,
            dashboard: LocalCompetitionDashboard(
                competitions: competitions,
                awards: [],
                issues: [],
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
        opponentUpdatedAt: Date? = nil,
        zone: String = "America/Los_Angeles",
        tally: LocalCompetitionTallyPresentation? = nil,
        now: Date? = nil
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
            evaluatedAt: now ?? evaluatedAt,
            timeZoneIdentifier: zone,
            lastSuccessfulFullWindowRefreshAt: refreshedAt,
            opponentUpdatedAt: opponentUpdatedAt
        )
    }

    private static let evaluatedAt = Date(timeIntervalSince1970: 1_786_867_200)

    /// The final-day Live Activity's samples (`-liveActivityPreviewSample`):
    /// Day 7 is Sun Aug 16, and it's 6:05 PM in Los Angeles. Each sample is
    /// the same match on the last day and, after midnight, tallying.
    static func liveActivitySample(
        _ name: String
    ) -> (live: LocalCompetitionPresentation, tallying: LocalCompetitionPresentation) {
        let now = Date(timeIntervalSince1970: 1_786_928_700)
        let you = now.addingTimeInterval(-25 * 60)  // 5:40 PM
        let them = now.addingTimeInterval(-3 * 60)  // 6:02 PM
        let losAngeles = "America/Los_Angeles"
        let sample: (name: String, user: Double, opponent: Double, zone: String, you: Date?, them: Date?) =
            switch name {
            case "behind": ("Sam", 2_166, 2_171.2, losAngeles, you, them)
            // Level as shown, and neither side has an Updated time.
            case "square": ("Sam", 2_190.4, 2_190.2, losAngeles, nil, nil)
            // An account deleted mid-match, with only your Updated time.
            case "former": ("Former competitor", 1_980, 2_015, losAngeles, you, nil)
            // A 64-character name, the most points a week allows, a New York
            // match seen from Los Angeles, and only their Updated time.
            case "long": ("Bartholomew Alexander Christopherson-Montgomery of Westminster",
                          4_180, 4_195, "America/New_York", nil, them)
            default: ("Sam", 2_190.4, 2_171.2, losAngeles, you, them)
            }
        func make(_ lifecycle: LocalCompetitionLifecyclePresentation) -> LocalCompetitionPresentation {
            presentation(
                id: CompetitionID(UUID(uuidString: "00000000-0000-4000-8000-0000000000A7")!),
                opponentName: sample.name,
                lifecycle: lifecycle,
                userPoints: sample.user,
                opponentPoints: sample.opponent,
                days: [],
                currentDayOrdinal: 7,
                terminal: nil,
                startDay: 10,
                refreshedAt: sample.you,
                opponentUpdatedAt: sample.them,
                zone: sample.zone,
                now: now
            )
        }
        return (make(.endsToday), make(.tallying(startedAt: now)))
    }

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
        currentDay: Int = 3,
        zone: String = "America/Los_Angeles",
        opponentUploaded: Bool = true
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
                opponentRevealedPoints: opponentUploaded && offset < currentDay
                    ? opponent[offset] : nil,
                ownerAcceptedSnapshot: offset < currentDay ? snapshots[offset] : nil,
                ownerLatestSnapshot: offset < currentDay ? snapshots[offset] : nil,
                scoringPolicy: .remoteWireV1
            )
        }
    }
}

/// The Lock Screen card live, gone stale at midnight, and tallying, at the
/// card's 160 pt height; then the Dynamic Island's expanded, compact and
/// minimal looks on black. The cards come from the planner, so they use the
/// app's real words.
private struct LiveActivityPreviewView: View {
    private let client = CompetitionLiveActivityClient.live
    private let attributes: MatchActivityAttributes
    private let live: MatchActivityAttributes.ContentState
    private let tallying: MatchActivityAttributes.ContentState

    init() {
        let defaults = UserDefaults.standard
        // `-liveActivityPreviewSample behind|square|former|long` picks the match.
        let sample = MultiUserCompetitionTestLabFixtures.liveActivitySample(
            defaults.string(forKey: "liveActivityPreviewSample") ?? "lead"
        )
        let locale = Locale(identifier: "en_US")
        let timeZone = TimeZone(identifier: "America/Los_Angeles")!
        live = CompetitionLiveActivityPlanner.content(sample.live, locale: locale, timeZone: timeZone)!
        tallying = CompetitionLiveActivityPlanner.content(sample.tallying, locale: locale, timeZone: timeZone)!
        // `-liveActivityPreviewSecondsLeft 60` lets a UI test watch the card go stale.
        let secondsLeft = defaults.double(forKey: "liveActivityPreviewSecondsLeft")
        var attributes = CompetitionLiveActivityPlanner.attributes(sample.live)!
        attributes.endsAt = Date().addingTimeInterval(secondsLeft > 0 ? secondsLeft : (5 * 60 + 45) * 60)
        self.attributes = attributes
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                lockScreenCard(live, identifier: "liveActivity.preview.live")
                lockScreenCard(live.resolved(isStale: true), identifier: "liveActivity.preview.pending")
                lockScreenCard(tallying, identifier: "liveActivity.preview.tallying")
                expandedIsland
                HStack(spacing: 16) {
                    compactIsland
                    minimalIsland
                }
                Button("Start Live Activity") {
                    Task { await start() }
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("liveActivity.preview.start")
            }
            .padding(16)
        }
        .background(Theme.panel)
        // A sample left by an earlier run never stays on the Lock Screen.
        .task { await endSamples() }
    }

    private func lockScreenCard(
        _ state: MatchActivityAttributes.ContentState,
        identifier: String
    ) -> some View {
        MatchActivityLockScreenView(attributes: attributes, state: state)
            .accessibilityIdentifier(identifier)
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .background(Theme.ground, in: RoundedRectangle(cornerRadius: 20))
    }

    private var expandedIsland: some View {
        VStack(spacing: 8) {
            MatchActivityIslandHeader(attributes: attributes, state: live)
            HStack(alignment: .bottom) {
                MatchActivityScoreColumn(side: .you, state: live, size: matchActivityIslandScoreSize)
                MatchActivityScoreColumn(side: .them, state: live, size: matchActivityIslandScoreSize)
            }
            MatchActivityIslandBottom(state: live)
        }
        .padding(20)
        .background(.black, in: RoundedRectangle(cornerRadius: 40))
        .matchActivityIsland()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("liveActivity.preview.expanded")
    }

    private var compactIsland: some View {
        HStack {
            MatchActivityCompactScore(side: .you, state: live)
            Spacer(minLength: 60)
            MatchActivityCompactScore(side: .them, state: live)
        }
        .padding(.horizontal, 16)
        .frame(height: 37)
        .background(.black, in: Capsule())
        .matchActivityIsland()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("liveActivity.preview.compact")
    }

    private var minimalIsland: some View {
        MatchActivityMinimalLead(state: live)
            .frame(width: 37, height: 37)
            .background(.black, in: Circle())
            .matchActivityIsland()
            .accessibilityIdentifier("liveActivity.preview.minimal")
    }

    private func endSamples() async {
        for activity in await client.current() where activity.matchID == attributes.matchID {
            await client.end(activity.matchID)
        }
    }

    private func start() async {
        await endSamples()
        _ = await client.start(attributes, live, attributes.endsAt)
    }
}

#endif

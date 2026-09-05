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
    case coldClaim = "cold-claim"
    case warmClaim = "warm-claim"
    case signedOutClaim = "signed-out-claim"
    case unavailableClaim = "unavailable-claim"
    case offlineClaim = "offline-claim"
    case account
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
        case .sharing:
            MultiUserCompetitionSharingTestLabView()
        case .coldClaim, .warmClaim, .signedOutClaim,
             .unavailableClaim, .offlineClaim:
            MultiUserCompetitionClaimTestLabView(
                scenario: configuration.scenario
            )
        case .account:
            MultiUserCompetitionAccountTestLabView()
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
    @State private var path: [CompetitionID] = []
    @State private var inviteStatus: CompetitionFeature.InviteCreationStatus =
        .idle
    @State private var inviteLink: CompetitionInviteShareLink?
    @State private var archivedIDs: Set<CompetitionID> = []
    @State private var rematchParentID: CompetitionID?
    @State private var rematchStatus: CompetitionFeature.InviteCreationStatus =
        .idle
    @State private var rematchLink: CompetitionInviteShareLink?

    var body: some View {
        NavigationStack(path: $path) {
            CompetitionSharingView(
                publication: publication,
                inviteCreationStatus: inviteStatus,
                createdInviteLink: inviteLink,
                createInvite: createInvite,
                selectCompetition: { path.append($0) },
                reinvite: {},
                isReinviteInFlight: false,
                notificationsMuted: false,
                notificationMuteIsInFlight: false,
                notificationPreferenceSaveFailed: false,
                notificationAuthorization: .authorized,
                notificationOpponentDisplayName: "Priya",
                notificationAuthorizationRequestIsInFlight: false,
                requestNotificationAuthorization: {},
                toggleNotifications: {}
            )
            .navigationDestination(for: CompetitionID.self) { id in
                destination(id)
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
                    inviteCreationStatus: rematchParentID == id
                        ? rematchStatus
                        : .idle,
                    createdInviteLink: rematchParentID == id
                        ? rematchLink
                        : nil,
                    isCommandInFlight: false,
                    send: handle
                )
            case .pending:
                CompetitionInviteView(
                    competition: competition,
                    source: .remoteParticipants,
                    isCommandInFlight: false,
                    send: handle
                )
            case .declined, .expired:
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

    private func createInvite() {
        inviteStatus = .ready
        inviteLink = MultiUserCompetitionTestLabFixtures.shareLink(byte: 0x51)
    }

    private func handle(_ action: CompetitionFeature.Action) {
        switch action {
        case let .archiveTapped(id):
            archivedIDs.insert(id)
        case let .rematchTapped(id):
            rematchParentID = id
            rematchStatus = .ready
            rematchLink = MultiUserCompetitionTestLabFixtures.shareLink(
                byte: 0x52
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
    }

    init(scenario: MultiUserCompetitionTestLabScenario) {
        self.scenario = scenario
        _isSignedIn = State(initialValue: scenario != .signedOutClaim)
        let initialStatus: MainTabFeature.InviteClaimStatus = switch scenario {
        case .unavailableClaim: .unavailable
        case .offlineClaim: .retryable
        case .sharing, .coldClaim, .warmClaim, .signedOutClaim, .account:
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
                    accept: accept,
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

private struct MultiUserCompetitionAccountTestLabView: View {
    let store: StoreOf<AccountFeature>

    init() {
        self.store = Store(
            initialState: AccountFeature.State(
                mode: .authenticated,
                displayName: "Beta Alice"
            )
        ) {
            AccountFeature()
        }
    }

    var body: some View {
        NavigationStack {
            AccountSettingsView(store: store)
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
            terminal: nil
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
        let competitions = [scheduled, active, completed, archived]
        let awards = [
            LocalCompetitionAward(
                id: "remote-ui-lab:completed:completion",
                competitionID: completedID,
                kind: .completion,
                awardedAt: completedAt,
                friendDisplayName: "Former competitor"
            ),
            LocalCompetitionAward(
                id: "remote-ui-lab:completed:victory",
                competitionID: completedID,
                kind: .victory,
                awardedAt: completedAt,
                friendDisplayName: "Former competitor"
            ),
            LocalCompetitionAward(
                id: "remote-ui-lab:archived:completion",
                competitionID: archivedID,
                kind: .completion,
                awardedAt: archivedTerminal.completedAt,
                friendDisplayName: "Morgan"
            ),
        ]
        return LocalCompetitionPublication(
            publicationRevision: 1,
            dashboard: LocalCompetitionDashboard(
                competitions: competitions,
                awards: awards,
                issues: [],
                hiddenTerminalCompetitionCount: 0
            ),
            evaluatedAt: Date(timeIntervalSince1970: 1_786_867_200),
            timeZoneIdentifier: "America/Los_Angeles",
            source: .remoteParticipants
        )
    }

    static func shareLink(byte: UInt8) -> CompetitionInviteShareLink {
        let rawToken = Data(repeating: byte, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = CompetitionInviteClaimToken(rawValue: rawToken)!
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
        terminal: LocalCompetitionTerminalPresentation?
    ) -> LocalCompetitionPresentation {
        let schedule = schedule()
        return LocalCompetitionPresentation(
            id: id,
            ownerDisplayName: "Beta Alice",
            opponentDisplayName: opponentName,
            opponentIdentity: "remote-profile:v1:\(id.rawValue.uuidString.lowercased())",
            lifecycle: lifecycle,
            acceptedConfiguration: LocalCompetitionAcceptedPresentation(
                schedule: schedule,
                difficulty: .balanced
            ),
            userPoints: userPoints,
            opponentPoints: opponentPoints,
            days: days,
            currentDayOrdinal: currentDayOrdinal,
            lastRefresh: nil,
            tally: nil,
            terminalResult: terminal,
            evaluatedAt: Date(timeIntervalSince1970: 1_786_867_200),
            timeZoneIdentifier: "America/Los_Angeles",
            lastSuccessfulFullWindowRefreshAt: nil
        )
    }

    private static func schedule() -> CompetitionSchedule {
        let calendar = try! CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        return CompetitionSchedule(
            calendar: calendar,
            startDay: try! CompetitionDay(
                era: 1,
                year: 2026,
                month: 8,
                day: 13,
                timeZoneIdentifier: calendar.timeZoneIdentifier
            )
        )
    }

    private static func activeDays() -> [LocalCompetitionDayPresentation] {
        let schedule = schedule()
        let days = try! schedule.calendar.sevenDayWindow(
            startingOn: schedule.startDay
        )
        let owner: [Double?] = [500, 520, 430, nil, nil, nil, nil]
        let opponent: [Double?] = [480, 510, 450, nil, nil, nil, nil]
        return days.enumerated().map { offset, day in
            LocalCompetitionDayPresentation(
                day: day,
                ordinal: offset + 1,
                ownerAcceptedPoints: owner[offset],
                ownerLatestAvailability: offset < 3
                    ? .observed
                    : .notYetOccurred,
                opponentRevealedPoints: opponent[offset]
            )
        }
    }
}

#endif

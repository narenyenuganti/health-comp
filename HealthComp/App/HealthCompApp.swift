import ComposableArchitecture
import SwiftUI

@main
struct HealthCompApp: App {
    let store: StoreOf<AppFeature>

    init() {
        store = Self.makeStore()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(store: store)
        }
    }
}

private extension HealthCompApp {
    static func makeStore() -> StoreOf<AppFeature> {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-apple-parity") {
            return uiTestingStore()
        }
        #endif

        return Store(initialState: AppFeature.State()) {
            AppFeature()
        }
    }
}

#if DEBUG
private extension HealthCompApp {
    static func uiTestingStore() -> StoreOf<AppFeature> {
        let currentUser = User.debugDemoUser
        let friend = User(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            username: "alex",
            displayName: "Alex",
            avatarURL: nil,
            bio: "Closing rings daily",
            cosmetics: .default,
            cpBalance: 120,
            cpLifetime: 900,
            privacy: .default,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let activeCompetition = competition(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            status: .active,
            createdBy: currentUser.id
        )
        let pendingCompetition = competition(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            status: .pending,
            createdBy: friend.id
        )
        let completedCompetition = competition(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
            status: .completed,
            createdBy: currentUser.id
        )
        let friendship = Friendship(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            requesterId: currentUser.id,
            receiverId: friend.id,
            status: .accepted,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let participants = [
            participant(userId: currentUser.id, role: .challenger, competitionId: activeCompetition.id),
            participant(userId: friend.id, role: .opponent, competitionId: activeCompetition.id),
        ]

        return Store(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.authClient.restoreSession = { .existingUser(currentUser) }
            $0.authClient.signInWithApple = { .existingUser(currentUser) }
            $0.competitionClient.fetchActive = { [activeCompetition] }
            $0.competitionClient.fetchPendingInvites = { [pendingCompetition] }
            $0.competitionClient.fetchHistory = { [completedCompetition] }
            $0.competitionClient.fetchParticipants = { competitionId in
                participants.map {
                    CompetitionParticipant(
                        id: $0.id,
                        competitionId: competitionId,
                        userId: $0.userId,
                        teamId: nil,
                        role: $0.role,
                        status: .accepted,
                        goalSnapshot: nil,
                        handicapMult: 1,
                        joinedAt: Date(timeIntervalSince1970: 0)
                    )
                }
            }
            $0.competitionClient.fetchDailyScores = { competitionId in
                competitionId == completedCompetition.id
                    ? [
                        dailyScore(competitionId: competitionId, userId: currentUser.id, date: "2026-05-17", points: 600),
                        dailyScore(competitionId: competitionId, userId: friend.id, date: "2026-05-17", points: 500),
                    ]
                    : [
                        dailyScore(competitionId: competitionId, userId: currentUser.id, date: "2026-05-11", points: 300),
                        dailyScore(competitionId: competitionId, userId: friend.id, date: "2026-05-11", points: 275),
                    ]
            }
            $0.competitionClient.createCompetition = { _, _, _, _, _ in pendingCompetition }
            $0.competitionClient.acceptInvite = { _ in }
            $0.competitionClient.declineInvite = { _ in }
            $0.friendsClient.fetchFriends = {
                [FriendWithProfile(friendship: friendship, friendProfile: friend)]
            }
            $0.friendsClient.fetchPendingRequests = { [] }
            $0.friendsClient.fetchFriendActivity = {
                [FriendActivitySummary(
                    friend: friend,
                    latestRingSummary: ActivityRingSummary(
                        id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
                        userId: friend.id,
                        date: "2026-05-11",
                        moveValue: 500,
                        moveGoal: 500,
                        exerciseValue: 30,
                        exerciseGoal: 30,
                        standValue: 12,
                        standGoal: 12,
                        source: .healthkit,
                        syncedAt: Date(timeIntervalSince1970: 0)
                    )
                )]
            }
            $0.friendsClient.searchByUsername = { _ in [friend] }
            $0.friendsClient.sendRequest = { _ in friendship }
            $0.friendsClient.acceptRequest = { _ in }
            $0.friendsClient.declineRequest = { _ in }
            $0.friendsClient.removeFriend = { _ in }
            $0.competitionNotificationClient.requestAuthorization = { false }
            $0.competitionNotificationClient.schedule = { _ in }
        }
    }

    static func competition(
        id: UUID,
        status: CompetitionStatus,
        createdBy: UUID
    ) -> Competition {
        Competition(
            id: id,
            type: .oneVOne,
            modeName: "apple_activity",
            scoringFormula: .appleActivity,
            status: status,
            startDate: "2026-05-11",
            endDate: "2026-05-17",
            createdBy: createdBy,
            handicapEnabled: false,
            stakesText: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    static func participant(
        userId: UUID,
        role: ParticipantRole,
        competitionId: UUID
    ) -> CompetitionParticipant {
        CompetitionParticipant(
            id: UUID(),
            competitionId: competitionId,
            userId: userId,
            teamId: nil,
            role: role,
            status: .accepted,
            goalSnapshot: nil,
            handicapMult: 1,
            joinedAt: Date(timeIntervalSince1970: 0)
        )
    }

    static func dailyScore(
        competitionId: UUID,
        userId: UUID,
        date: String,
        points: Double
    ) -> DailyScore {
        DailyScore(
            id: UUID(),
            competitionId: competitionId,
            userId: userId,
            date: date,
            metricScores: [:],
            totalPoints: points,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}
#endif

struct AppRootView: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        Group {
            switch store.screen {
            case .loading:
                ProgressView("Loading...")

            case .auth:
                if let authStore = store.scope(state: \.auth, action: \.auth) {
                    AuthView(store: authStore)
                }

            case .onboarding:
                if let onboardingStore = store.scope(state: \.onboarding, action: \.onboarding) {
                    OnboardingView(store: onboardingStore)
                }

            case .mainTab:
                if let mainTabStore = store.scope(state: \.mainTab, action: \.mainTab) {
                    MainTabView(store: mainTabStore)
                }
            }
        }
        .onAppear {
            store.send(.onAppear)
        }
    }
}

import ComposableArchitecture
import XCTest
@testable import HealthComp

final class CompeteFeatureTests: XCTestCase {
    private let currentUserId = UUID(uuidString: "770e8400-e29b-41d4-a716-446655440000")!
    private let opponentId = UUID(uuidString: "880e8400-e29b-41d4-a716-446655440000")!

    @MainActor
    func testOnAppearLoadsActiveInvitesAndHistory() async {
        let active = makeCompetition(id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!, status: .active)
        let invite = makeCompetition(id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440001")!, status: .pending)
        let history = makeCompetition(id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440002")!, status: .completed)
        var scheduledAlerts: [CompetitionAlert] = []

        let store = TestStore(initialState: CompeteFeature.State(currentUserId: currentUserId)) {
            CompeteFeature()
        } withDependencies: {
            $0.competitionClient.fetchActive = { [active] }
            $0.competitionClient.fetchPendingInvites = { [invite] }
            $0.competitionClient.fetchHistory = { [history] }
            $0.competitionNotificationClient.requestAuthorization = { true }
            $0.competitionNotificationClient.schedule = {
                scheduledAlerts.append($0)
            }
        }

        await store.send(\.onAppear) {
            $0.isLoading = true
        }
        await store.receive(\.activeLoaded.success) {
            $0.isLoading = false
            $0.activeCompetitions = [active]
            $0.notifiedActiveCompetitionIds = [active.id]
        }
        await store.receive(\.invitesLoaded.success) {
            $0.pendingInvites = [invite]
            $0.notifiedInviteIds = [invite.id]
        }
        await store.receive(\.historyLoaded.success) {
            $0.historyCompetitions = [history]
        }

        await store.finish()
        XCTAssertEqual(Set(scheduledAlerts.map(\.title)), Set(["Competition Started", "Competition Invite"]))
        XCTAssertEqual(scheduledAlerts.count, 2)
    }

    @MainActor
    func testSelectingCompetitionBuildsAppleScoreSummary() async {
        let competition = makeCompetition(id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!, status: .active)
        var state = CompeteFeature.State(currentUserId: currentUserId)
        state.activeCompetitions = [competition]

        let participants = [
            makeParticipant(userId: currentUserId, role: .challenger),
            makeParticipant(userId: opponentId, role: .opponent),
        ]
        let scores = [
            makeDailyScore(userId: currentUserId, date: "2026-05-11", points: 300),
            makeDailyScore(userId: opponentId, date: "2026-05-11", points: 275),
        ]

        let store = TestStore(initialState: state) {
            CompeteFeature()
        } withDependencies: {
            $0.competitionClient.fetchParticipants = { _ in participants }
            $0.competitionClient.fetchDailyScores = { _ in scores }
            $0.competitionNotificationClient.requestAuthorization = { true }
            $0.competitionNotificationClient.schedule = { _ in }
        }

        await store.send(\.competitionTapped, competition.id) {
            $0.selectedCompetition = competition
            $0.isDetailLoading = true
        }
        await store.receive(\.detailLoaded.success) {
            $0.isDetailLoading = false
            $0.selectedParticipants = participants
            $0.selectedDailyScores = scores
            $0.selectedSummary = CompetitionScoreSummary(
                competition: competition,
                currentUserId: self.currentUserId,
                opponentUserId: self.opponentId,
                dailyScores: scores
            )
            $0.notifiedDailyProgressKeys = ["550e8400-e29b-41d4-a716-446655440000-2026-05-11"]
        }
        await store.finish()
    }

    @MainActor
    func testDetailLoadedSchedulesProgressEndingSoonAndFinalResultNotifications() async {
        let competition = makeCompetition(id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!, status: .completed)
        let participants = [
            makeParticipant(userId: currentUserId, role: .challenger),
            makeParticipant(userId: opponentId, role: .opponent),
        ]
        let scores = [
            makeDailyScore(userId: currentUserId, date: "2026-05-17", points: 600),
            makeDailyScore(userId: opponentId, date: "2026-05-17", points: 500),
        ]
        let payload = CompetitionDetailPayload(
            competition: competition,
            participants: participants,
            dailyScores: scores
        )
        var scheduledAlerts: [CompetitionAlert] = []

        let store = TestStore(initialState: CompeteFeature.State(currentUserId: currentUserId)) {
            CompeteFeature()
        } withDependencies: {
            $0.competitionNotificationClient.requestAuthorization = { true }
            $0.competitionNotificationClient.schedule = {
                scheduledAlerts.append($0)
            }
        }

        await store.send(.detailLoaded(.success(payload))) {
            $0.selectedCompetition = competition
            $0.selectedParticipants = participants
            $0.selectedDailyScores = scores
            $0.selectedSummary = CompetitionScoreSummary(
                competition: competition,
                currentUserId: self.currentUserId,
                opponentUserId: self.opponentId,
                dailyScores: scores
            )
            $0.notifiedDailyProgressKeys = ["550e8400-e29b-41d4-a716-446655440000-2026-05-17"]
            $0.notifiedResultCompetitionIds = [competition.id]
        }

        await store.finish()
        XCTAssertEqual(Set(scheduledAlerts.map(\.title)), Set(["Daily Progress", "Competition Complete"]))
        XCTAssertTrue(scheduledAlerts.contains {
            $0.body == "Apple Activity is complete. You won."
        })
    }

    @MainActor
    func testDecliningInviteReloadsCompetitions() async {
        let competition = makeCompetition(id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!, status: .pending)
        var declinedCompetitionId: UUID?
        var state = CompeteFeature.State(currentUserId: currentUserId)
        state.pendingInvites = [competition]

        let store = TestStore(initialState: state) {
            CompeteFeature()
        } withDependencies: {
            $0.competitionClient.declineInvite = {
                declinedCompetitionId = $0
            }
            $0.competitionClient.fetchActive = { [] }
            $0.competitionClient.fetchPendingInvites = { [] }
            $0.competitionClient.fetchHistory = { [] }
            $0.competitionNotificationClient.requestAuthorization = { true }
            $0.competitionNotificationClient.schedule = { _ in }
        }
        store.exhaustivity = .off

        await store.send(\.declineInviteTapped, competition.id)
        await store.skipReceivedActions()

        XCTAssertEqual(declinedCompetitionId, competition.id)
        XCTAssertEqual(store.state.pendingInvites, [])
    }

    private func makeCompetition(id: UUID, status: CompetitionStatus) -> Competition {
        Competition(
            id: id,
            type: .oneVOne,
            modeName: "apple_activity",
            scoringFormula: .appleActivity,
            status: status,
            startDate: "2026-05-11",
            endDate: "2026-05-17",
            createdBy: currentUserId,
            handicapEnabled: false,
            stakesText: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeParticipant(userId: UUID, role: ParticipantRole) -> CompetitionParticipant {
        CompetitionParticipant(
            id: UUID(),
            competitionId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            userId: userId,
            teamId: nil,
            role: role,
            status: .accepted,
            goalSnapshot: nil,
            handicapMult: 1,
            joinedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeDailyScore(userId: UUID, date: String, points: Double) -> DailyScore {
        DailyScore(
            id: UUID(),
            competitionId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            userId: userId,
            date: date,
            metricScores: [:],
            totalPoints: points,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}

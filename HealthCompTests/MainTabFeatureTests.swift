import CompetitionCore
import ComposableArchitecture
import XCTest
@testable import HealthComp

final class MainTabFeatureTests: XCTestCase {
    @MainActor
    func testInitialStateOwnsLocalCompetitionChild() {
        XCTAssertEqual(
            MainTabFeature.State(),
            MainTabFeature.State(competition: CompetitionFeature.State())
        )
    }

    @MainActor
    func testTaskForwardsToCompetitionChild() async {
        let recorder = MainTabLifecycleRecorder()
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.localCompetitionClient = recorder.client
        }

        await store.send(.task)
        await store.receive(.onboardingChecked([]))
        await store.receive(.competition(.task))
        await store.finish()

        XCTAssertEqual(recorder.startCount, 1)
    }

    @MainActor
    func testOnboardingAsksOnlyForHealthBeforeTheCompetitionStarts() async {
        let recorder = MainTabLifecycleRecorder()
        let permissions = PermissionOnboardingRecorder(health: .notRequested)
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.localCompetitionClient = recorder.client
            $0.permissionOnboardingClient = permissions.client
        }

        await store.send(.task)
        await store.receive(.onboardingChecked([.health])) {
            $0.onboarding = MainTabFeature.PermissionOnboarding(
                steps: [.health]
            )
        }
        // Prompts toggling the scene don't reach the competition before it
        // starts.
        await store.send(.scenePhaseChanged(.active))

        await store.send(.onboardingContinueTapped) {
            $0.onboarding?.isRequesting = true
        }
        await store.receive(.onboardingStepCompleted) {
            $0.onboarding = nil
        }
        await store.receive(.competition(.task))
        await store.finish()

        XCTAssertEqual(permissions.calls, ["health"])
        XCTAssertEqual(recorder.startCount, 1)
        XCTAssertEqual(recorder.reconcileTriggers, [])
    }

    func testOnboardingShowsOnlyPermissionsIOSHasNotAskedFor() {
        XCTAssertEqual(
            PermissionOnboardingClient.steps(health: .notRequested),
            [.health]
        )
        XCTAssertEqual(PermissionOnboardingClient.steps(health: .requested), [])
        XCTAssertEqual(PermissionOnboardingClient.steps(health: .unavailable), [])
    }

    @MainActor
    func testClaimLinkDuringOnboardingShowsChallengeBeforeHealth() async throws {
        for routeFirst in [true, false] {
            try await assertChallengeBeforeHealth(routeFirst: routeFirst)
        }
    }

    @MainActor
    private func assertChallengeBeforeHealth(routeFirst: Bool) async throws {
        let claimedID = competitionID("81000000-0000-0000-0000-000000000031")
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(
                rawValue: "JJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJ"
            )
        )
        let envelope = CompetitionRouteEnvelope(
            sequence: 7,
            route: .claimInvite(token)
        )
        let claims = MainTabClaimRecorder(
            expectedToken: token,
            results: [.success(claimedID, expectedRevision: 2)]
        )
        let permissions = PermissionOnboardingRecorder(health: .notRequested)
        let routing = MainTabRoutingRecorder()
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.permissionOnboardingClient = permissions.client
            $0.continuousClock = TestClock()
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        if routeFirst {
            await store.send(.routeReceived(envelope)) {
                $0.pendingClaimRoute = envelope
            }
            await store.send(.task)
            await store.receive(.onboardingChecked([.health])) {
                $0.onboarding = MainTabFeature.PermissionOnboarding(
                    steps: [.health]
                )
                $0.inviteClaimStatus = .loadingPreview
            }
        } else {
            await store.send(.task)
            await store.receive(.onboardingChecked([.health])) {
                $0.onboarding = MainTabFeature.PermissionOnboarding(
                    steps: [.health]
                )
            }
            await store.send(.routeReceived(envelope)) {
                $0.pendingClaimRoute = envelope
                $0.inviteClaimStatus = .loadingPreview
            }
        }
        // The sheet names the sender before Health, as it does after.
        await receivePreview(store, envelope)
        XCTAssertEqual(store.state.inviteClaimPreview?.sender.displayName, "Naren")

        await store.send(.acceptClaimTapped) {
            $0.acceptsClaimOnStart = true
            $0.inviteClaimStatus = .idle
        }
        XCTAssertEqual(claims.requestCount, 0)

        await store.send(.onboardingContinueTapped) {
            $0.onboarding?.isRequesting = true
        }
        await store.receive(.onboardingStepCompleted) {
            $0.onboarding = nil
        }
        await store.receive(.competition(.task))

        let first = publication(revision: 1, visibleIDs: [])
        await store.send(.competition(.publication(first))) {
            $0.competition.publication = first
            $0.acceptsClaimOnStart = false
        }
        await store.receive(.processPendingClaim) {
            $0.claimRouteSequenceInFlight = envelope.sequence
            $0.inviteClaimStatus = .claiming
        }
        await store.receive(
            .claimInviteResponse(
                sequence: envelope.sequence,
                .success(claimedID, expectedRevision: 2)
            )
        ) {
            $0.pendingClaimRoute = nil
            $0.claimRouteSequenceInFlight = nil
            $0.lastHandledClaimRouteSequence = envelope.sequence
            $0.inviteClaimPreview = nil
            $0.inviteClaimPreviewEvaluatedAt = nil
            $0.pendingClaimNavigation = .init(
                competitionID: claimedID,
                expectedPublicationRevision: 2
            )
            $0.inviteClaimStatus = .waitingForCompetition
        }
        XCTAssertEqual(claims.requestCount, 1)

        let acknowledged = publication(revision: 2, visibleID: claimedID)
        await store.send(.competition(.publication(acknowledged))) {
            $0.competition.publication = acknowledged
            $0.path = [claimedID]
            $0.pendingClaimNavigation = nil
            $0.inviteClaimStatus = .idle
        }
        XCTAssertEqual(permissions.calls, ["health"])

        await store.send(.stop)
        await store.receive(.competition(.stop))
        await store.finish()
    }

    @MainActor
    func testNotNowOnChallengeDuringOnboardingKeepsHealthStep() async throws {
        let envelope = try claimEnvelope(sequence: 7)
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(
            expectedToken: try XCTUnwrap(
                CompetitionInviteClaimToken(rawValue: Self.claimToken)
            ),
            results: []
        )
        let onboarding = MainTabFeature.PermissionOnboarding(steps: [.health])
        let store = TestStore(
            initialState: MainTabFeature.State(onboarding: onboarding)
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        await store.send(.routeReceived(envelope)) {
            $0.pendingClaimRoute = envelope
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, envelope)
        await store.send(.notNowClaimTapped) {
            $0.pendingClaimRoute = nil
            $0.lastHandledClaimRouteSequence = envelope.sequence
            $0.inviteClaimPreview = nil
            $0.inviteClaimPreviewEvaluatedAt = nil
            $0.inviteClaimStatus = .idle
        }
        await store.finish()

        XCTAssertEqual(routing.consumedSequences, [envelope.sequence])
        XCTAssertEqual(claims.declinedIDs, [])
        XCTAssertEqual(store.state.onboarding, onboarding)
        XCTAssertFalse(store.state.acceptsClaimOnStart)
    }

    @MainActor
    func testDeclineBeforeHealthDeclinesOnTheServerAndKeepsHealthStep()
        async throws {
        let envelope = try claimEnvelope(sequence: 7)
        let routing = MainTabRoutingRecorder()
        let permissions = PermissionOnboardingRecorder(health: .notRequested)
        let claims = MainTabClaimRecorder(
            expectedToken: try XCTUnwrap(
                CompetitionInviteClaimToken(rawValue: Self.claimToken)
            ),
            results: []
        )
        let onboarding = MainTabFeature.PermissionOnboarding(steps: [.health])
        let store = TestStore(
            initialState: MainTabFeature.State(onboarding: onboarding)
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.permissionOnboardingClient = permissions.client
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        await store.send(.routeReceived(envelope)) {
            $0.pendingClaimRoute = envelope
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, envelope)
        await store.send(.declineClaimConfirmed) {
            $0.inviteClaimStatus = .declining
        }
        await store.receive(
            .declineClaimFinished(sequence: envelope.sequence, succeeded: true)
        ) {
            $0.pendingClaimRoute = nil
            $0.lastHandledClaimRouteSequence = envelope.sequence
            $0.inviteClaimPreview = nil
            $0.inviteClaimPreviewEvaluatedAt = nil
            $0.inviteClaimStatus = .idle
        }
        await store.finish()

        XCTAssertEqual(
            claims.declinedIDs,
            [CompetitionID(MainTabClaimRecorder.preview.competitionID)]
        )
        XCTAssertEqual(claims.requestCount, 0)
        XCTAssertEqual(routing.consumedSequences, [envelope.sequence])
        // Health is still the next step, and nothing asked for it.
        XCTAssertEqual(store.state.onboarding, onboarding)
        XCTAssertEqual(permissions.calls, [])
        XCTAssertFalse(store.state.acceptsClaimOnStart)
    }

    @MainActor
    func testFailedDeclineBeforeHealthReturnsToTheSheet() async throws {
        let envelope = try claimEnvelope(sequence: 7)
        let routing = MainTabRoutingRecorder()
        let permissions = PermissionOnboardingRecorder(health: .notRequested)
        let claims = MainTabClaimRecorder(
            expectedToken: try XCTUnwrap(
                CompetitionInviteClaimToken(rawValue: Self.claimToken)
            ),
            results: []
        )
        claims.declineSucceeds = false
        let onboarding = MainTabFeature.PermissionOnboarding(steps: [.health])
        let store = TestStore(
            initialState: MainTabFeature.State(onboarding: onboarding)
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.permissionOnboardingClient = permissions.client
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        await store.send(.routeReceived(envelope)) {
            $0.pendingClaimRoute = envelope
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, envelope)
        await store.send(.declineClaimConfirmed) {
            $0.inviteClaimStatus = .declining
        }
        await store.receive(
            .declineClaimFinished(sequence: envelope.sequence, succeeded: false)
        ) {
            $0.inviteClaimStatus = .ready
            $0.claimDeclineFailed = true
        }
        await store.finish()
        XCTAssertEqual(routing.consumedSequences, [])
        XCTAssertEqual(permissions.calls, [])
        XCTAssertEqual(store.state.onboarding, onboarding)
    }

    @MainActor
    func testBlockClaimConfirmedBlocksAndConsumesRoute() async throws {
        let envelope = try claimEnvelope(sequence: 7)
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(
            expectedToken: try XCTUnwrap(
                CompetitionInviteClaimToken(rawValue: Self.claimToken)
            ),
            results: []
        )
        let permissions = PermissionOnboardingRecorder(health: .notRequested)
        let onboarding = MainTabFeature.PermissionOnboarding(steps: [.health])
        let store = TestStore(
            initialState: MainTabFeature.State(onboarding: onboarding)
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.permissionOnboardingClient = permissions.client
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        await store.send(.routeReceived(envelope)) {
            $0.pendingClaimRoute = envelope
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, envelope)
        await store.send(.blockClaimConfirmed) {
            $0.inviteClaimStatus = .declining
        }
        await store.receive(
            .declineClaimFinished(sequence: envelope.sequence, succeeded: true)
        ) {
            $0.pendingClaimRoute = nil
            $0.lastHandledClaimRouteSequence = envelope.sequence
            $0.inviteClaimPreview = nil
            $0.inviteClaimPreviewEvaluatedAt = nil
            $0.inviteClaimStatus = .idle
        }
        await store.finish()

        XCTAssertEqual(
            claims.blockedIDs,
            [CompetitionID(MainTabClaimRecorder.preview.competitionID)]
        )
        XCTAssertEqual(claims.declinedIDs, [])
        XCTAssertEqual(routing.consumedSequences, [envelope.sequence])
    }

    @MainActor
    func testFailedBlockClaimReturnsToTheSheet() async throws {
        let envelope = try claimEnvelope(sequence: 7)
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(
            expectedToken: try XCTUnwrap(
                CompetitionInviteClaimToken(rawValue: Self.claimToken)
            ),
            results: []
        )
        claims.declineSucceeds = false
        let permissions = PermissionOnboardingRecorder(health: .notRequested)
        let onboarding = MainTabFeature.PermissionOnboarding(steps: [.health])
        let store = TestStore(
            initialState: MainTabFeature.State(onboarding: onboarding)
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.permissionOnboardingClient = permissions.client
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        await store.send(.routeReceived(envelope)) {
            $0.pendingClaimRoute = envelope
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, envelope)
        await store.send(.blockClaimConfirmed) {
            $0.inviteClaimStatus = .declining
        }
        await store.receive(
            .declineClaimFinished(sequence: envelope.sequence, succeeded: false)
        ) {
            $0.inviteClaimStatus = .ready
            $0.claimDeclineFailed = true
        }
        await store.finish()
        XCTAssertEqual(claims.blockedIDs.count, 1)
        XCTAssertEqual(routing.consumedSequences, [])
    }

    /// Decline, Not Now, or a link you already accepted: each opens the
    /// waiting link over the Health step.
    @MainActor
    func testQueuedLinkOpensItsPreviewBeforeHealth() async throws {
        enum Exit: CaseIterable { case decline, notNow, alreadyAccepted }
        let accepted = CompetitionInvitePreview(
            competitionID: MainTabClaimRecorder.preview.competitionID,
            state: .accepted,
            sender: MainTabClaimRecorder.preview.sender,
            timeZoneIdentifier: "America/Los_Angeles",
            expiresAt: MainTabClaimRecorder.now
        )
        for exit in Exit.allCases {
            let first = try claimEnvelope(sequence: 7)
            let second = try claimEnvelope(
                sequence: 8,
                token: String(repeating: "N", count: 43)
            )
            let routing = MainTabRoutingRecorder()
            let claims = MainTabClaimRecorder(
                expectedToken: try XCTUnwrap(
                    CompetitionInviteClaimToken(rawValue: Self.claimToken)
                ),
                results: []
            )
            let onboarding = MainTabFeature.PermissionOnboarding(steps: [.health])
            var initial = MainTabFeature.State(onboarding: onboarding)
            if exit == .alreadyAccepted {
                // Both links arrived; the first one's preview is answering.
                initial.pendingClaimRoute = first
                initial.queuedClaimRoute = second
                initial.inviteClaimStatus = .loadingPreview
            }
            let store = TestStore(initialState: initial) {
                MainTabFeature()
            } withDependencies: {
                $0.competitionClient = claims.client
                $0.competitionRoutingClient = routing.client
                $0.date = .constant(MainTabClaimRecorder.now)
            }

            switch exit {
            case .decline, .notNow:
                await store.send(.routeReceived(first)) {
                    $0.pendingClaimRoute = first
                    $0.inviteClaimStatus = .loadingPreview
                }
                await receivePreview(store, first)
                await store.send(.routeReceived(second)) {
                    $0.queuedClaimRoute = second
                }
                if exit == .decline {
                    await store.send(.declineClaimConfirmed) {
                        $0.inviteClaimStatus = .declining
                    }
                    await store.receive(
                        .declineClaimFinished(sequence: first.sequence, succeeded: true)
                    ) {
                        $0.pendingClaimRoute = second
                        $0.queuedClaimRoute = nil
                        $0.lastHandledClaimRouteSequence = first.sequence
                        $0.inviteClaimPreview = nil
                        $0.inviteClaimPreviewEvaluatedAt = nil
                        $0.inviteClaimStatus = .loadingPreview
                    }
                } else {
                    await store.send(.notNowClaimTapped) {
                        $0.pendingClaimRoute = second
                        $0.queuedClaimRoute = nil
                        $0.lastHandledClaimRouteSequence = first.sequence
                        $0.inviteClaimPreview = nil
                        $0.inviteClaimPreviewEvaluatedAt = nil
                        $0.inviteClaimStatus = .loadingPreview
                    }
                }
            case .alreadyAccepted:
                await store.send(
                    .claimPreviewResponse(sequence: first.sequence, .success(accepted))
                ) {
                    $0.pendingClaimRoute = second
                    $0.queuedClaimRoute = nil
                    $0.lastHandledClaimRouteSequence = first.sequence
                    $0.inviteClaimStatus = .loadingPreview
                }
            }
            await receivePreview(store, second)
            await store.finish()
            XCTAssertEqual(routing.consumedSequences, [first.sequence], "\(exit)")
            XCTAssertEqual(claims.requestCount, 0, "\(exit)")
            XCTAssertEqual(store.state.onboarding, onboarding, "\(exit)")
        }
    }

    @MainActor
    func testFailedPreviewBeforeHealthRetries() async throws {
        let envelope = try claimEnvelope(sequence: 7)
        let claims = MainTabClaimRecorder(
            expectedToken: try XCTUnwrap(
                CompetitionInviteClaimToken(rawValue: Self.claimToken)
            ),
            results: []
        )
        claims.previewResult = .failure(.operationFailed)
        let onboarding = MainTabFeature.PermissionOnboarding(steps: [.health])
        let store = TestStore(
            initialState: MainTabFeature.State(onboarding: onboarding)
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = MainTabRoutingRecorder().client
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        await store.send(.routeReceived(envelope)) {
            $0.pendingClaimRoute = envelope
            $0.inviteClaimStatus = .loadingPreview
        }
        await store.receive(
            .claimPreviewResponse(sequence: envelope.sequence, .failure(.operationFailed))
        ) {
            $0.inviteClaimStatus = .retryable
        }
        claims.previewResult = .success(MainTabClaimRecorder.preview)
        await store.send(.retryClaimTapped) {
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, envelope)
        await store.finish()
        XCTAssertEqual(claims.requestCount, 0)
        XCTAssertEqual(store.state.onboarding, onboarding)
    }

    /// Health finished while the preview was loading, before the first
    /// publication: a link you already accepted still opens its match.
    @MainActor
    func testAlreadyAcceptedLinkAfterHealthBeforeFirstPublicationOpensTheMatch()
        async throws {
        let envelope = try claimEnvelope(sequence: 7)
        let matchID = CompetitionID(MainTabClaimRecorder.preview.competitionID)
        let accepted = CompetitionInvitePreview(
            competitionID: matchID.rawValue,
            state: .accepted,
            sender: MainTabClaimRecorder.preview.sender,
            timeZoneIdentifier: "America/Los_Angeles",
            expiresAt: MainTabClaimRecorder.now
        )
        let routing = MainTabRoutingRecorder()
        let store = TestStore(
            initialState: MainTabFeature.State(
                pendingClaimRoute: envelope,
                inviteClaimStatus: .loadingPreview
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionRoutingClient = routing.client
            $0.continuousClock = TestClock()
        }

        await store.send(
            .claimPreviewResponse(sequence: envelope.sequence, .success(accepted))
        ) {
            $0.claimRouteSequenceInFlight = envelope.sequence
        }
        await store.receive(
            .claimInviteResponse(
                sequence: envelope.sequence,
                .success(matchID, expectedRevision: 0)
            )
        ) {
            $0.pendingClaimRoute = nil
            $0.claimRouteSequenceInFlight = nil
            $0.lastHandledClaimRouteSequence = envelope.sequence
            $0.pendingClaimNavigation = .init(
                competitionID: matchID,
                expectedPublicationRevision: 0
            )
            $0.inviteClaimStatus = .waitingForCompetition
        }
        let first = publication(revision: 1, visibleID: matchID)
        await store.send(.competition(.publication(first))) {
            $0.competition.publication = first
            $0.path = [matchID]
            $0.pendingClaimNavigation = nil
            $0.inviteClaimStatus = .idle
        }
        await store.finish()
        XCTAssertEqual(routing.consumedSequences, [envelope.sequence])
    }

    /// A link from before this account can arrive after a newer, valid one.
    @MainActor
    func testWrongAccountNoticeReopensTheValidLinkBehindIt() async throws {
        let early = try claimEnvelope(sequence: 5, token: String(repeating: "E", count: 43))
        let later = try claimEnvelope(sequence: 6)
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(
            expectedToken: try XCTUnwrap(
                CompetitionInviteClaimToken(rawValue: Self.claimToken)
            ),
            results: []
        )
        var initial = MainTabFeature.State(
            onboarding: MainTabFeature.PermissionOnboarding(steps: [.health])
        )
        initial.claimLinksBeforeAccountThrough = 5
        let store = TestStore(initialState: initial) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        await store.send(.routeReceived(later)) {
            $0.pendingClaimRoute = later
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, later)
        await store.send(.routeReceived(early)) {
            $0.lastHandledClaimRouteSequence = early.sequence
            $0.inviteClaimStatus = .wrongAccount
        }
        await store.send(.dismissClaimStatus) {
            $0.inviteClaimPreview = nil
            $0.inviteClaimPreviewEvaluatedAt = nil
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, later)
        await store.finish()
        XCTAssertEqual(store.state.pendingClaimRoute, later)
        XCTAssertEqual(routing.consumedSequences, [early.sequence])
        XCTAssertEqual(claims.requestCount, 0)
    }

    @MainActor
    func testAlreadyAcceptedLinkBeforeHealthIsForgottenWithoutASheet()
        async throws {
        let envelope = try claimEnvelope(sequence: 7)
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(
            expectedToken: try XCTUnwrap(
                CompetitionInviteClaimToken(rawValue: Self.claimToken)
            ),
            results: []
        )
        let accepted = CompetitionInvitePreview(
            competitionID: MainTabClaimRecorder.preview.competitionID,
            state: .accepted,
            sender: MainTabClaimRecorder.preview.sender,
            timeZoneIdentifier: "America/Los_Angeles",
            expiresAt: MainTabClaimRecorder.now
        )
        claims.previewResult = .success(accepted)
        let onboarding = MainTabFeature.PermissionOnboarding(steps: [.health])
        let store = TestStore(
            initialState: MainTabFeature.State(onboarding: onboarding)
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        await store.send(.routeReceived(envelope)) {
            $0.pendingClaimRoute = envelope
            $0.inviteClaimStatus = .loadingPreview
        }
        // The match shows on Home once Health is set up.
        await store.receive(
            .claimPreviewResponse(sequence: envelope.sequence, .success(accepted))
        ) {
            $0.pendingClaimRoute = nil
            $0.lastHandledClaimRouteSequence = envelope.sequence
            $0.inviteClaimStatus = .idle
        }
        await store.finish()
        XCTAssertEqual(routing.consumedSequences, [envelope.sequence])
        XCTAssertEqual(claims.requestCount, 0)
        XCTAssertEqual(store.state.onboarding, onboarding)
    }

    @MainActor
    func testNewerClaimLinkWaitsBehindAnEarlierAcceptance() async throws {
        let first = try claimEnvelope(sequence: 7)
        // A different link: the same link again is ignored.
        let newer = try claimEnvelope(sequence: 8, token: String(repeating: "N", count: 43))
        let claims = MainTabClaimRecorder(
            expectedToken: try XCTUnwrap(
                CompetitionInviteClaimToken(rawValue: Self.claimToken)
            ),
            results: []
        )
        let store = TestStore(
            initialState: MainTabFeature.State(
                onboarding: MainTabFeature.PermissionOnboarding(steps: [.health])
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        await store.send(.routeReceived(first)) {
            $0.pendingClaimRoute = first
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, first)
        await store.send(.acceptClaimTapped) {
            $0.acceptsClaimOnStart = true
            $0.inviteClaimStatus = .idle
        }
        // The accepted link stays on screen; the newer one waits for it.
        await store.send(.routeReceived(newer)) {
            $0.queuedClaimRoute = newer
        }
        XCTAssertEqual(claims.requestCount, 0)
    }

    @MainActor
    func testClaimLinkFromBeforeNewAccountShowsWrongAccountWithoutClaiming()
        async throws {
        let early = try claimEnvelope(sequence: 5)
        let later = try claimEnvelope(sequence: 6)
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(
            expectedToken: try XCTUnwrap(
                CompetitionInviteClaimToken(rawValue: Self.claimToken)
            ),
            results: []
        )
        let onboarding = MainTabFeature.PermissionOnboarding(steps: [.health])
        var initial = MainTabFeature.State(onboarding: onboarding)
        initial.claimLinksBeforeAccountThrough = 5
        let store = TestStore(initialState: initial) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        await store.send(.routeReceived(early)) {
            $0.lastHandledClaimRouteSequence = 5
            $0.inviteClaimStatus = .wrongAccount
        }
        await store.finish()
        XCTAssertEqual(routing.consumedSequences, [5])
        XCTAssertEqual(claims.requestCount, 0)
        XCTAssertEqual(store.state.onboarding, onboarding)
        XCTAssertFalse(store.state.acceptsClaimOnStart)

        await store.send(.dismissClaimStatus) {
            $0.inviteClaimStatus = .idle
        }
        await store.send(.routeReceived(later)) {
            $0.pendingClaimRoute = later
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, later)
        XCTAssertEqual(claims.requestCount, 0)
    }

    @MainActor
    func testNotificationPromptWaitsForLiveOrPendingMatchThenDefersOnNotNow()
        async {
        let created = Date(timeIntervalSinceReferenceDate: 1)
        let lifecycles: [LocalCompetitionLifecyclePresentation] = [
            .pending(direction: .incoming, createdAt: created, expiresAt: nil),
            .pending(direction: .outgoing, createdAt: created, expiresAt: nil),
            .scheduled,
        ]
        for lifecycle in lifecycles {
            let clock = TestClock()
            let permissions = PermissionOnboardingRecorder()
            let store = TestStore(
                initialState: MainTabFeature.State(
                    competition: CompetitionFeature.State(
                        notificationAuthorizationState: .notDetermined
                    )
                )
            ) {
                MainTabFeature()
            } withDependencies: {
                $0.continuousClock = clock
                $0.permissionOnboardingClient = permissions.client
            }

            let closedOnly = publication(
                revision: 1,
                visibleIDs: [
                    competitionID("81000000-0000-0000-0000-000000000041"),
                ],
                lifecycle: .expired(at: created, direction: .outgoing)
            )
            await store.send(.competition(.publication(closedOnly))) {
                $0.competition.publication = closedOnly
            }
            let declinedOnly = publication(
                revision: 2,
                visibleID: competitionID("81000000-0000-0000-0000-000000000042"),
                lifecycle: .declined(at: created, direction: .incoming)
            )
            await store.send(.competition(.publication(declinedOnly))) {
                $0.competition.publication = declinedOnly
            }
            let finishedOnly = publication(
                revision: 3,
                visibleID: competitionID("81000000-0000-0000-0000-000000000043"),
                lifecycle: .completed(
                    outcome: .win,
                    basis: .stableAcrossPostBoundaryReads,
                    completedAt: created
                )
            )
            await store.send(.competition(.publication(finishedOnly))) {
                $0.competition.publication = finishedOnly
            }

            let withPerson = publication(
                revision: 4,
                visibleID: competitionID("81000000-0000-0000-0000-000000000044"),
                lifecycle: lifecycle
            )
            await store.send(.competition(.publication(withPerson))) {
                $0.competition.publication = withPerson
                $0.notificationPrompt = .scheduled
            }
            await clock.advance(by: .milliseconds(600))
            await store.receive(.notificationPromptReady) {
                $0.notificationPrompt = .presented
            }
            await store.send(.notificationPromptNotNowTapped) {
                $0.notificationPrompt = .finished
            }
            await store.finish()
            XCTAssertEqual(permissions.calls, ["deferNotifications"])

            let later = publication(
                revision: 5,
                visibleID: competitionID("81000000-0000-0000-0000-000000000045"),
                lifecycle: .active(dayOrdinal: 2)
            )
            await store.send(.competition(.publication(later))) {
                $0.competition.publication = later
            }
            await store.finish()
        }
    }

    @MainActor
    func testNotificationPromptTurnOnGoesThroughCompetitionAndCloses() async {
        var client = MainTabLifecycleRecorder().client
        client.requestNotificationAuthorization = { .authorized }
        var initial = MainTabFeature.State(
            competition: CompetitionFeature.State(
                notificationAuthorizationState: .notDetermined
            )
        )
        initial.notificationPrompt = .presented
        let store = TestStore(initialState: initial) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = client
        }

        await store.send(.notificationPromptTurnOnTapped)
        await store.receive(.competition(.enableNotificationsTapped)) {
            $0.competition.notificationAuthorizationRequestIsInFlight = true
        }
        await store.receive(
            .competition(.notificationAuthorizationRequestFinished(.authorized))
        ) {
            $0.competition.notificationAuthorizationState = .authorized
            $0.competition.notificationAuthorizationRequestIsInFlight = false
            $0.notificationPrompt = .finished
        }
        await store.finish()
    }

    @MainActor
    func testNotificationPromptSkipsWhenDeferredOrDecided() async {
        let match = publication(
            revision: 1,
            visibleID: competitionID("81000000-0000-0000-0000-000000000051")
        )
        let clock = TestClock()
        let deferred = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(
                    notificationAuthorizationState: .notDetermined
                )
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.permissionOnboardingClient = PermissionOnboardingRecorder(
                deferred: true
            ).client
        }
        await deferred.send(.competition(.publication(match))) {
            $0.competition.publication = match
            $0.notificationPrompt = .scheduled
        }
        await clock.advance(by: .milliseconds(600))
        await deferred.receive(.notificationPromptSkipped) {
            $0.notificationPrompt = .finished
        }
        await deferred.finish()

        let decided: [CompetitionNotificationAuthorizationState?] = [.denied, nil]
        for authorization in decided {
            let store = TestStore(
                initialState: MainTabFeature.State(
                    competition: CompetitionFeature.State(
                        notificationAuthorizationState: authorization
                    )
                )
            ) {
                MainTabFeature()
            }
            await store.send(.competition(.publication(match))) {
                $0.competition.publication = match
            }
            await store.finish()
        }
    }

    @MainActor
    func testNotificationPromptWaitsForClaimSheetAndOnboarding() async throws {
        let match = publication(
            revision: 1,
            visibleID: competitionID("81000000-0000-0000-0000-000000000061")
        )
        let authorized = CompetitionFeature.State(
            notificationAuthorizationState: .notDetermined
        )
        let pendingClaim = try claimEnvelope(sequence: 3)
        let claimSheet = TestStore(
            initialState: MainTabFeature.State(
                competition: authorized,
                pendingClaimRoute: pendingClaim,
                inviteClaimStatus: .ready
            )
        ) {
            MainTabFeature()
        }
        await claimSheet.send(.competition(.publication(match))) {
            $0.competition.publication = match
        }

        let onboarding = TestStore(
            initialState: MainTabFeature.State(
                competition: authorized,
                onboarding: MainTabFeature.PermissionOnboarding(steps: [.health])
            )
        ) {
            MainTabFeature()
        }
        await onboarding.send(.competition(.publication(match))) {
            $0.competition.publication = match
        }

        var scheduled = MainTabFeature.State(
            competition: authorized,
            inviteClaimStatus: .ready
        )
        scheduled.notificationPrompt = .scheduled
        let sheetUp = TestStore(initialState: scheduled) {
            MainTabFeature()
        }
        await sheetUp.send(.notificationPromptReady) {
            $0.notificationPrompt = .unscheduled
        }
    }

    @MainActor
    func testNotificationPromptWaitsForChallengeSheet() async {
        let clock = TestClock()
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(
                    notificationAuthorizationState: .notDetermined
                )
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.permissionOnboardingClient = PermissionOnboardingRecorder().client
        }
        let sent = publication(
            revision: 1,
            visibleID: competitionID("81000000-0000-0000-0000-000000000071"),
            lifecycle: .pending(
                direction: .outgoing,
                createdAt: Date(timeIntervalSinceReferenceDate: 1),
                expiresAt: nil
            )
        )

        await store.send(.challengeSheetVisibilityChanged(true)) {
            $0.isChallengeSheetOpen = true
        }
        await store.send(.competition(.publication(sent))) {
            $0.competition.publication = sent
        }
        await store.send(.challengeSheetVisibilityChanged(false)) {
            $0.isChallengeSheetOpen = false
            $0.notificationPrompt = .scheduled
        }
        await clock.advance(by: .milliseconds(600))
        await store.receive(.notificationPromptReady) {
            $0.notificationPrompt = .presented
        }
        await store.finish()
    }

    @MainActor
    func testNotificationPromptWaitsForAccountSheetAndRecoversADroppedPrompt()
        async {
        let clock = TestClock()
        let match = publication(
            revision: 1,
            visibleID: competitionID("81000000-0000-0000-0000-000000000081"),
            lifecycle: .active(dayOrdinal: 2)
        )
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(
                    notificationAuthorizationState: .notDetermined
                )
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.permissionOnboardingClient = PermissionOnboardingRecorder().client
        }

        await store.send(.accountPresentationChanged(true)) {
            $0.isAccountPresented = true
        }
        await store.send(.competition(.publication(match))) {
            $0.competition.publication = match
        }
        await store.send(.accountPresentationChanged(false)) {
            $0.isAccountPresented = false
            $0.notificationPrompt = .scheduled
        }
        // Account opens during the delay: the ready check backs off.
        await store.send(.accountPresentationChanged(true)) {
            $0.isAccountPresented = true
        }
        await clock.advance(by: .milliseconds(600))
        await store.receive(.notificationPromptReady) {
            $0.notificationPrompt = .unscheduled
        }
        await store.send(.accountPresentationChanged(false)) {
            $0.isAccountPresented = false
            $0.notificationPrompt = .scheduled
        }
        await clock.advance(by: .milliseconds(600))
        await store.receive(.notificationPromptReady) {
            $0.notificationPrompt = .presented
        }

        // A sheet opening while the prompt is "presented" means the
        // present was dropped; it retries when the sheet closes.
        await store.send(.accountPresentationChanged(true)) {
            $0.isAccountPresented = true
            $0.notificationPrompt = .unscheduled
        }
        await store.send(.accountPresentationChanged(false)) {
            $0.isAccountPresented = false
            $0.notificationPrompt = .scheduled
        }
        await clock.advance(by: .milliseconds(600))
        await store.receive(.notificationPromptReady) {
            $0.notificationPrompt = .presented
        }
        await store.send(.challengeSheetVisibilityChanged(true)) {
            $0.isChallengeSheetOpen = true
            $0.notificationPrompt = .unscheduled
        }
        await store.finish()
    }

    @MainActor
    func testAcceptedChallengeSchedulesNotificationPromptOnlyAfterTheClaim()
        async throws {
        let claimedID = competitionID("81000000-0000-0000-0000-000000000091")
        let liveID = competitionID("81000000-0000-0000-0000-000000000092")
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(rawValue: Self.claimToken)
        )
        let envelope = try claimEnvelope(sequence: 9)
        let claims = MainTabClaimRecorder(
            expectedToken: token,
            results: [.success(claimedID, expectedRevision: 2)]
        )
        let clock = TestClock()
        var initial = MainTabFeature.State(
            competition: CompetitionFeature.State(
                notificationAuthorizationState: .notDetermined
            ),
            pendingClaimRoute: envelope
        )
        // Accepted over the Health step, after the preview loaded.
        initial.inviteClaimPreview = MainTabClaimRecorder.preview
        initial.inviteClaimPreviewEvaluatedAt = MainTabClaimRecorder.now
        initial.acceptsClaimOnStart = true
        let store = TestStore(initialState: initial) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = MainTabRoutingRecorder().client
            $0.continuousClock = clock
            $0.permissionOnboardingClient = PermissionOnboardingRecorder().client
        }

        // A live match is already there, but the claim sheet is about to
        // show, so the prompt waits.
        let first = publication(
            revision: 1,
            visibleID: liveID,
            lifecycle: .active(dayOrdinal: 3)
        )
        await store.send(.competition(.publication(first))) {
            $0.competition.publication = first
            $0.acceptsClaimOnStart = false
        }
        await store.receive(.processPendingClaim) {
            $0.claimRouteSequenceInFlight = envelope.sequence
            $0.inviteClaimStatus = .claiming
        }
        await store.receive(
            .claimInviteResponse(
                sequence: envelope.sequence,
                .success(claimedID, expectedRevision: 2)
            )
        ) {
            $0.pendingClaimRoute = nil
            $0.claimRouteSequenceInFlight = nil
            $0.lastHandledClaimRouteSequence = envelope.sequence
            $0.inviteClaimPreview = nil
            $0.inviteClaimPreviewEvaluatedAt = nil
            $0.pendingClaimNavigation = .init(
                competitionID: claimedID,
                expectedPublicationRevision: 2
            )
            $0.inviteClaimStatus = .waitingForCompetition
        }

        let acknowledged = publication(
            revision: 2,
            visibleIDs: [liveID, claimedID],
            lifecycle: .scheduled
        )
        await store.send(.competition(.publication(acknowledged))) {
            $0.competition.publication = acknowledged
            $0.path = [claimedID]
            $0.pendingClaimNavigation = nil
            $0.inviteClaimStatus = .idle
            $0.notificationPrompt = .scheduled
        }
        await clock.advance(by: .milliseconds(600))
        await store.receive(.notificationPromptReady) {
            $0.notificationPrompt = .presented
        }
        await store.finish()
    }

    @MainActor
    func testHealthAccessRefreshesOnAccountAndForeground() async {
        let recorder = MainTabLifecycleRecorder()
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.localCompetitionClient = recorder.client
            $0.permissionOnboardingClient = PermissionOnboardingRecorder().client
        }

        await store.send(.scenePhaseChanged(.active))
        await store.receive(.competition(.sceneBecameActive))

        await store.send(.refreshHealthAccess)
        await store.receive(.healthAccessLoaded(.requested)) {
            $0.healthAccess = .requested
        }
        await store.send(.scenePhaseChanged(.active))
        await store.receive(.competition(.sceneBecameActive))
        await store.receive(.refreshHealthAccess)
        await store.receive(.healthAccessLoaded(.requested))
        await store.finish()
    }

    @MainActor
    func testConnectHealthRequestsAccessThenRereads() async {
        let permissions = PermissionOnboardingRecorder(health: .notRequested)
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.permissionOnboardingClient = permissions.client
        }

        await store.send(.connectHealthTapped)
        await store.receive(.healthAccessLoaded(.notRequested)) {
            $0.healthAccess = .notRequested
        }
        await store.finish()
        XCTAssertEqual(permissions.calls, ["health"])
    }

    @MainActor
    func testScenePhaseForwardsOnlyActiveAndNeverStopsOnBackground() async {
        let recorder = MainTabLifecycleRecorder()
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.localCompetitionClient = recorder.client
        }

        await store.send(.scenePhaseChanged(.inactive))
        await store.send(.scenePhaseChanged(.background))
        await store.send(.scenePhaseChanged(.active))
        await store.receive(.competition(.sceneBecameActive))
        await store.finish()

        XCTAssertEqual(recorder.reconcileTriggers, [.foreground])
        XCTAssertEqual(recorder.stopCount, 0)
    }

    @MainActor
    func testTimeZoneChangeForwardsExactAction() async {
        let recorder = MainTabLifecycleRecorder()
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.localCompetitionClient = recorder.client
        }

        await store.send(.timeZoneChanged)
        await store.receive(.competition(.timeZoneChanged))
        await store.finish()

        XCTAssertEqual(recorder.reconcileTriggers, [.timeZoneChange])
    }

    @MainActor
    func testStopForwardsToCompetitionChild() async {
        let recorder = MainTabLifecycleRecorder()
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.localCompetitionClient = recorder.client
        }

        await store.send(.stop)
        await store.receive(.competition(.stop))
        await store.finish()

        XCTAssertEqual(recorder.stopCount, 1)
    }

    @MainActor
    func testStopClearsInFlightInviteClaimState() async {
        let store = TestStore(
            initialState: {
                var state = MainTabFeature.State(
                    claimRouteSequenceInFlight: 42,
                    inviteClaimStatus: .claiming
                )
                state.acceptsClaimOnStart = true
                state.isChallengeSheetOpen = true
                state.notificationPrompt = .presented
                return state
            }()
        ) {
            MainTabFeature()
        }

        await store.send(.stop) {
            $0.claimRouteSequenceInFlight = nil
            $0.inviteClaimStatus = .idle
            $0.acceptsClaimOnStart = false
            $0.isChallengeSheetOpen = false
            $0.notificationPrompt = .unscheduled
        }
        await store.receive(.competition(.stop))
        await store.finish()
    }

    @MainActor
    func testColdRouteParksUntilCanonicalPublicationThenConsumesOnce()
        async {
        let id = competitionID("81000000-0000-0000-0000-000000000001")
        let routing = MainTabRoutingRecorder()
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.localCompetitionClient = MainTabLifecycleRecorder().client
            $0.competitionRoutingClient = routing.client
        }

        await store.send(.task)
        await store.receive(.onboardingChecked([]))
        await store.receive(.competition(.task))
        let envelope = routing.enqueue(.competition(id))
        await store.receive(.routeReceived(envelope)) {
            $0.pendingRoute = envelope
        }

        let publication = publication(revision: 1, visibleID: id)
        await store.send(.competition(.publication(publication))) {
            $0.competition.publication = publication
            $0.pendingRoute = nil
            $0.path = [id]
            $0.lastHandledRouteSequence = envelope.sequence
        }
        XCTAssertEqual(routing.consumedSequences, [envelope.sequence])

        await store.send(.stop)
        await store.receive(.competition(.stop))
        await store.finish()
    }

    @MainActor
    func testWarmVisibleRouteReplacesPathAndDuplicateSequenceIsIgnored()
        async {
        let oldID = competitionID("81000000-0000-0000-0000-000000000002")
        let routedID = competitionID("81000000-0000-0000-0000-000000000003")
        let routing = MainTabRoutingRecorder()
        let visible = publication(
            revision: 4,
            visibleIDs: [oldID, routedID]
        )
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(publication: visible),
                path: [oldID]
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionRoutingClient = routing.client
        }
        let envelope = CompetitionRouteEnvelope(
            sequence: 9,
            route: .competition(routedID)
        )

        await store.send(.routeReceived(envelope)) {
            $0.path = [routedID]
            $0.lastHandledRouteSequence = 9
        }
        await store.send(.routeReceived(envelope))

        XCTAssertEqual(routing.consumedSequences, [9])
        await store.finish()
    }

    @MainActor
    func testUnknownRouteHoldsTheStackAndRefreshesOnce() async {
        let archivedID = competitionID("81000000-0000-0000-0000-000000000004")
        let unknownID = competitionID("81000000-0000-0000-0000-000000000005")
        let routing = MainTabRoutingRecorder()
        let recorder = MainTabLifecycleRecorder()
        let archived = publication(
            revision: 5,
            visibleID: archivedID,
            lifecycle: archivedLifecycle
        )
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(publication: archived),
                path: [archivedID]
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionRoutingClient = routing.client
            $0.localCompetitionClient = recorder.client
            $0.continuousClock = TestClock()
        }
        let envelope = CompetitionRouteEnvelope(
            sequence: 2,
            route: .competition(unknownID)
        )

        await store.send(.routeReceived(envelope)) {
            $0.pendingRoute = envelope
            $0.heldRouteSequence = 2
        }
        await store.receive(.competition(.pullToRefresh))

        // A publication without the match keeps holding and doesn't refresh again.
        let unrelated = publication(
            revision: 6,
            visibleID: archivedID,
            lifecycle: archivedLifecycle
        )
        await store.send(.competition(.publication(unrelated))) {
            $0.competition.publication = unrelated
        }

        await store.send(.stop) {
            $0.heldRouteSequence = nil
        }
        await store.receive(.competition(.stop))
        await store.finish()
        XCTAssertEqual(recorder.reconcileTriggers, [.pullToRefresh])
        XCTAssertEqual(routing.consumedSequences, [])
    }

    @MainActor
    func testHeldRouteOpensWhenItsCompetitionAppears() async {
        let id = competitionID("81000000-0000-0000-0000-000000000007")
        let routing = MainTabRoutingRecorder()
        let empty = publication(revision: 1, visibleIDs: [])
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(publication: empty)
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionRoutingClient = routing.client
            $0.localCompetitionClient = MainTabLifecycleRecorder().client
            $0.continuousClock = TestClock()
        }
        let envelope = CompetitionRouteEnvelope(sequence: 2, route: .competition(id))

        await store.send(.routeReceived(envelope)) {
            $0.pendingRoute = envelope
            $0.heldRouteSequence = 2
        }
        await store.receive(.competition(.pullToRefresh))

        let loaded = publication(revision: 2, visibleID: id)
        await store.send(.competition(.publication(loaded))) {
            $0.competition.publication = loaded
            $0.pendingRoute = nil
            $0.heldRouteSequence = nil
            $0.lastHandledRouteSequence = 2
            $0.path = [id]
        }
        await store.finish()
        XCTAssertEqual(routing.consumedSequences, [2])
    }

    @MainActor
    func testHeldRouteTimesOutWithoutClearingTheStack() async {
        let archivedID = competitionID("81000000-0000-0000-0000-000000000008")
        let unknownID = competitionID("81000000-0000-0000-0000-000000000009")
        let routing = MainTabRoutingRecorder()
        let clock = TestClock()
        let archived = publication(
            revision: 5,
            visibleID: archivedID,
            lifecycle: archivedLifecycle
        )
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(publication: archived),
                path: [archivedID]
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionRoutingClient = routing.client
            $0.localCompetitionClient = MainTabLifecycleRecorder().client
            $0.continuousClock = clock
        }
        let envelope = CompetitionRouteEnvelope(
            sequence: 2,
            route: .competition(unknownID)
        )

        await store.send(.routeReceived(envelope)) {
            $0.pendingRoute = envelope
            $0.heldRouteSequence = 2
        }
        await store.receive(.competition(.pullToRefresh))
        await clock.advance(by: .seconds(15))
        await store.receive(.pendingRouteTimedOut(2)) {
            $0.pendingRoute = nil
            $0.heldRouteSequence = nil
            $0.lastHandledRouteSequence = 2
        }
        await store.finish()
        XCTAssertEqual(store.state.path, [archivedID])
        XCTAssertEqual(routing.consumedSequences, [2])
    }

    @MainActor
    func testRouteClosesHistoryAndAccountBeforeOpening() async {
        let id = competitionID("81000000-0000-0000-0000-00000000000A")
        let routing = MainTabRoutingRecorder()
        let visible = publication(revision: 1, visibleID: id)
        var initial = MainTabFeature.State(
            competition: CompetitionFeature.State(publication: visible),
            showsHistory: true,
            isAccountPresented: true
        )
        initial.historyPersonIdentity = "remote-profile:v1:x"
        let store = TestStore(initialState: initial) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionRoutingClient = routing.client
        }

        await store.send(
            .routeReceived(CompetitionRouteEnvelope(sequence: 3, route: .competition(id)))
        ) {
            $0.showsHistory = false
            $0.historyPersonIdentity = nil
            $0.isAccountPresented = false
            $0.path = [id]
            $0.lastHandledRouteSequence = 3
        }
        await store.finish()
        XCTAssertEqual(routing.consumedSequences, [3])
    }

    @MainActor
    func testHistoryAndAccountPresentationActionsSetState() async {
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        }

        await store.send(.historyPresentationChanged(true)) {
            $0.showsHistory = true
        }
        await store.send(.accountPresentationChanged(true)) {
            $0.isAccountPresented = true
        }
        await store.send(.historyPersonChanged("p")) {
            $0.historyPersonIdentity = "p"
        }
        await store.send(.historyPresentationChanged(false)) {
            $0.showsHistory = false
            $0.historyPersonIdentity = nil
        }
        await store.send(.accountPresentationChanged(false)) {
            $0.isAccountPresented = false
        }
    }

    private var archivedLifecycle: LocalCompetitionLifecyclePresentation {
        .archived(
            outcome: .win,
            basis: .stableAcrossPostBoundaryReads,
            completedAt: Date(timeIntervalSinceReferenceDate: 10),
            archivedAt: Date(timeIntervalSinceReferenceDate: 11)
        )
    }

    @MainActor
    func testCanonicalPublicationPrunesDeletedDestination() async {
        let id = competitionID("81000000-0000-0000-0000-000000000006")
        let first = publication(revision: 1, visibleID: id)
        let second = publication(revision: 2, visibleIDs: [])
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(publication: first),
                path: [id]
            )
        ) {
            MainTabFeature()
        }

        await store.send(.competition(.publication(second))) {
            $0.competition.publication = second
            $0.path = []
        }
        await store.finish()
    }

    @MainActor
    func testColdClaimWaitsForCanonicalPublicationAndNavigatesOnlyAfterAck()
        async throws {
        let claimedID = competitionID(
            "81000000-0000-0000-0000-000000000007"
        )
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(
                rawValue: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            )
        )
        let envelope = CompetitionRouteEnvelope(
            sequence: 7,
            route: .claimInvite(token)
        )
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(
            expectedToken: token,
            results: [.success(claimedID, expectedRevision: 3)]
        )
        let clock = TestClock()
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.date = .constant(MainTabClaimRecorder.now)
            $0.continuousClock = clock
        }

        await store.send(.routeReceived(envelope)) {
            $0.pendingClaimRoute = envelope
        }
        XCTAssertEqual(claims.requestCount, 0)

        let first = publication(revision: 1, visibleIDs: [])
        await store.send(.competition(.publication(first))) {
            $0.competition.publication = first
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, envelope)
        XCTAssertEqual(claims.requestCount, 0)

        await store.send(.acceptClaimTapped)
        await store.receive(.processPendingClaim) {
            $0.claimRouteSequenceInFlight = envelope.sequence
            $0.inviteClaimStatus = .claiming
        }
        await store.receive(
            .claimInviteResponse(
                sequence: envelope.sequence,
                .success(claimedID, expectedRevision: 3)
            )
        ) {
            $0.pendingClaimRoute = nil
            $0.claimRouteSequenceInFlight = nil
            $0.lastHandledClaimRouteSequence = envelope.sequence
            $0.inviteClaimPreview = nil
            $0.inviteClaimPreviewEvaluatedAt = nil
            $0.pendingClaimNavigation = .init(
                competitionID: claimedID,
                expectedPublicationRevision: 3
            )
            $0.inviteClaimStatus = .waitingForCompetition
        }
        XCTAssertEqual(claims.requestCount, 1)
        XCTAssertTrue(claims.allTokensMatched)
        XCTAssertEqual(routing.consumedSequences, [envelope.sequence])

        let early = publication(
            revision: 2,
            visibleID: claimedID,
            lifecycle: .pending(
                direction: .incoming,
                createdAt: Date(timeIntervalSinceReferenceDate: 2),
                expiresAt: nil
            )
        )
        await store.send(.competition(.publication(early))) {
            $0.competition.publication = early
        }
        XCTAssertEqual(store.state.path, [])

        let acknowledged = publication(
            revision: 3,
            visibleID: claimedID,
            lifecycle: .pending(
                direction: .incoming,
                createdAt: Date(timeIntervalSinceReferenceDate: 2),
                expiresAt: nil
            )
        )
        await store.send(.competition(.publication(acknowledged))) {
            $0.competition.publication = acknowledged
            $0.path = [claimedID]
            $0.pendingClaimNavigation = nil
            $0.inviteClaimStatus = .idle
        }
        await clock.advance(by: .seconds(15))
        await store.finish()
    }

    @MainActor
    func testClaimConfirmationTimeoutCanRefreshThenDismissWithoutReclaiming()
        async throws
    {
        let claimedID = competitionID(
            "81000000-0000-0000-0000-000000000014"
        )
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(
                rawValue: "HHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHH"
            )
        )
        let envelope = CompetitionRouteEnvelope(
            sequence: 14,
            route: .claimInvite(token)
        )
        let pendingNavigation = MainTabFeature.PendingClaimNavigation(
            competitionID: claimedID,
            expectedPublicationRevision: 3
        )
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(
            expectedToken: token,
            results: [.success(claimedID, expectedRevision: 3)]
        )
        let clock = TestClock()
        let initial = publication(revision: 1, visibleIDs: [])
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(publication: initial)
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.date = .constant(MainTabClaimRecorder.now)
            $0.continuousClock = clock
        }

        await store.send(.routeReceived(envelope)) {
            $0.pendingClaimRoute = envelope
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, envelope)
        await store.send(.acceptClaimTapped)
        await store.receive(.processPendingClaim) {
            $0.claimRouteSequenceInFlight = envelope.sequence
            $0.inviteClaimStatus = .claiming
        }
        await store.receive(
            .claimInviteResponse(
                sequence: envelope.sequence,
                .success(claimedID, expectedRevision: 3)
            )
        ) {
            $0.pendingClaimRoute = nil
            $0.claimRouteSequenceInFlight = nil
            $0.lastHandledClaimRouteSequence = envelope.sequence
            $0.inviteClaimPreview = nil
            $0.inviteClaimPreviewEvaluatedAt = nil
            $0.pendingClaimNavigation = pendingNavigation
            $0.inviteClaimStatus = .waitingForCompetition
        }

        await clock.advance(by: .seconds(15))
        await store.receive(.claimConfirmationTimedOut(pendingNavigation)) {
            $0.inviteClaimStatus = .confirmationTimedOut
        }

        await store.send(.retryClaimTapped) {
            $0.inviteClaimStatus = .waitingForCompetition
        }
        await store.receive(.competition(.pullToRefresh))

        await clock.advance(by: .seconds(15))
        await store.receive(.claimConfirmationTimedOut(pendingNavigation)) {
            $0.inviteClaimStatus = .confirmationTimedOut
        }
        await store.send(.dismissClaimStatus) {
            $0.pendingClaimNavigation = nil
            $0.inviteClaimStatus = .idle
        }

        XCTAssertEqual(claims.requestCount, 1)
        XCTAssertEqual(routing.consumedSequences, [envelope.sequence])
        await store.finish()
    }

    @MainActor
    func testUnavailableClaimIsConsumedOnceAndDuplicateSequenceIsIgnored()
        async throws {
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(
                rawValue: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
            )
        )
        let envelope = CompetitionRouteEnvelope(
            sequence: 8,
            route: .claimInvite(token)
        )
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(
            expectedToken: token,
            results: [.failure(.inviteUnavailable)]
        )
        let initial = publication(revision: 1, visibleIDs: [])
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(publication: initial)
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        await store.send(.routeReceived(envelope)) {
            $0.pendingClaimRoute = envelope
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, envelope)
        await store.send(.acceptClaimTapped)
        await store.receive(.processPendingClaim) {
            $0.claimRouteSequenceInFlight = envelope.sequence
            $0.inviteClaimStatus = .claiming
        }
        await store.receive(
            .claimInviteResponse(
                sequence: envelope.sequence,
                .failure(.inviteUnavailable)
            )
        ) {
            $0.pendingClaimRoute = nil
            $0.claimRouteSequenceInFlight = nil
            $0.lastHandledClaimRouteSequence = envelope.sequence
            $0.inviteClaimPreview = nil
            $0.inviteClaimPreviewEvaluatedAt = nil
            $0.inviteClaimStatus = .unavailable
        }
        await store.send(.routeReceived(envelope))

        XCTAssertEqual(claims.requestCount, 1)
        XCTAssertEqual(routing.consumedSequences, [envelope.sequence])
        await store.finish()
    }

    @MainActor
    func testOwnClaimShowsOwnChallenge() async throws {
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(
                rawValue: "OOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO"
            )
        )
        let envelope = CompetitionRouteEnvelope(
            sequence: 9,
            route: .claimInvite(token)
        )
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(
            expectedToken: token,
            results: [.failure(.forbidden)]
        )
        let initial = publication(revision: 1, visibleIDs: [])
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(publication: initial)
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        await store.send(.routeReceived(envelope)) {
            $0.pendingClaimRoute = envelope
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, envelope)
        await store.send(.acceptClaimTapped)
        await store.receive(.processPendingClaim) {
            $0.claimRouteSequenceInFlight = envelope.sequence
            $0.inviteClaimStatus = .claiming
        }
        await store.receive(
            .claimInviteResponse(
                sequence: envelope.sequence,
                .failure(.forbidden)
            )
        ) {
            $0.pendingClaimRoute = nil
            $0.claimRouteSequenceInFlight = nil
            $0.lastHandledClaimRouteSequence = envelope.sequence
            $0.inviteClaimPreview = nil
            $0.inviteClaimPreviewEvaluatedAt = nil
            $0.inviteClaimStatus = .ownChallenge
        }
        await store.send(.dismissClaimStatus) {
            $0.inviteClaimStatus = .idle
        }

        XCTAssertEqual(routing.consumedSequences, [envelope.sequence])
        await store.finish()
    }

    @MainActor
    func testRetryableClaimKeepsTokenPendingUntilExplicitRetry() async throws {
        let claimedID = competitionID(
            "81000000-0000-0000-0000-000000000008"
        )
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(
                rawValue: "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
            )
        )
        let envelope = CompetitionRouteEnvelope(
            sequence: 9,
            route: .claimInvite(token)
        )
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(
            expectedToken: token,
            results: [
                .failure(.retryableTransport),
                .success(claimedID, expectedRevision: 2),
            ]
        )
        let clock = TestClock()
        let initial = publication(revision: 1, visibleIDs: [])
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(publication: initial)
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.date = .constant(MainTabClaimRecorder.now)
            $0.continuousClock = clock
        }

        await store.send(.routeReceived(envelope)) {
            $0.pendingClaimRoute = envelope
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, envelope)
        await store.send(.acceptClaimTapped)
        await store.receive(.processPendingClaim) {
            $0.claimRouteSequenceInFlight = envelope.sequence
            $0.inviteClaimStatus = .claiming
        }
        await store.receive(
            .claimInviteResponse(
                sequence: envelope.sequence,
                .failure(.retryableTransport)
            )
        ) {
            $0.claimRouteSequenceInFlight = nil
            $0.inviteClaimStatus = .retryable
        }
        XCTAssertEqual(routing.consumedSequences, [])

        await store.send(.retryClaimTapped)
        await store.receive(.processPendingClaim) {
            $0.claimRouteSequenceInFlight = envelope.sequence
            $0.inviteClaimStatus = .claiming
        }
        await store.receive(
            .claimInviteResponse(
                sequence: envelope.sequence,
                .success(claimedID, expectedRevision: 2)
            )
        ) {
            $0.pendingClaimRoute = nil
            $0.claimRouteSequenceInFlight = nil
            $0.lastHandledClaimRouteSequence = envelope.sequence
            $0.inviteClaimPreview = nil
            $0.inviteClaimPreviewEvaluatedAt = nil
            $0.pendingClaimNavigation = .init(
                competitionID: claimedID,
                expectedPublicationRevision: 2
            )
            $0.inviteClaimStatus = .waitingForCompetition
        }

        XCTAssertEqual(claims.requestCount, 2)
        XCTAssertTrue(claims.allTokensMatched)
        XCTAssertEqual(routing.consumedSequences, [envelope.sequence])

        let acknowledged = publication(revision: 2, visibleID: claimedID)
        await store.send(.competition(.publication(acknowledged))) {
            $0.competition.publication = acknowledged
            $0.path = [claimedID]
            $0.pendingClaimNavigation = nil
            $0.inviteClaimStatus = .idle
        }
        await clock.advance(by: .seconds(15))
        await store.finish()
    }

    @MainActor
    func testUnrelatedPublicationDoesNotEraseRetryableClaimStatus()
        async throws
    {
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(
                rawValue: "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"
            )
        )
        let envelope = CompetitionRouteEnvelope(
            sequence: 11,
            route: .claimInvite(token)
        )
        let initial = publication(revision: 1, visibleIDs: [])
        let updated = publication(revision: 2, visibleIDs: [])
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(publication: initial),
                pendingClaimRoute: envelope,
                inviteClaimStatus: .retryable
            )
        ) {
            MainTabFeature()
        }

        await store.send(.competition(.publication(updated))) {
            $0.competition.publication = updated
        }
        await store.finish()
    }

    @MainActor
    func testNotNowOnRetryableClaimForgetsTheLink() async throws {
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(
                rawValue: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
            )
        )
        let envelope = CompetitionRouteEnvelope(
            sequence: 12,
            route: .claimInvite(token)
        )
        let routing = MainTabRoutingRecorder()
        let store = TestStore(
            initialState: MainTabFeature.State(
                pendingClaimRoute: envelope,
                inviteClaimStatus: .retryable
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionRoutingClient = routing.client
        }

        await store.send(.notNowClaimTapped) {
            $0.pendingClaimRoute = nil
            $0.lastHandledClaimRouteSequence = envelope.sequence
            $0.inviteClaimStatus = .idle
        }

        XCTAssertEqual(routing.consumedSequences, [envelope.sequence])
        await store.finish()
    }

    @MainActor
    func testNotNowConsumesRouteWithoutCallingServer() async throws {
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(
                rawValue: "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"
            )
        )
        let envelope = CompetitionRouteEnvelope(
            sequence: 10,
            route: .claimInvite(token)
        )
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(
            expectedToken: token,
            results: []
        )
        let initial = publication(revision: 1, visibleIDs: [])
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(publication: initial)
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        await store.send(.routeReceived(envelope)) {
            $0.pendingClaimRoute = envelope
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, envelope)
        await store.send(.notNowClaimTapped) {
            $0.pendingClaimRoute = nil
            $0.lastHandledClaimRouteSequence = envelope.sequence
            $0.inviteClaimStatus = .idle
            $0.inviteClaimPreview = nil
            $0.inviteClaimPreviewEvaluatedAt = nil
        }

        XCTAssertEqual(claims.requestCount, 0)
        XCTAssertEqual(routing.consumedSequences, [envelope.sequence])
        await store.finish()
    }

    @MainActor
    func testNotNowOnRetryableClaimConsumesRouteWithoutCallingServer()
        async throws
    {
        let token = try XCTUnwrap(
            CompetitionInviteClaimToken(
                rawValue: "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG"
            )
        )
        let envelope = CompetitionRouteEnvelope(
            sequence: 13,
            route: .claimInvite(token)
        )
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(expectedToken: token, results: [])
        let store = TestStore(
            initialState: MainTabFeature.State(
                pendingClaimRoute: envelope,
                inviteClaimStatus: .retryable
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        await store.send(.notNowClaimTapped) {
            $0.pendingClaimRoute = nil
            $0.lastHandledClaimRouteSequence = envelope.sequence
            $0.inviteClaimStatus = .idle
            $0.inviteClaimPreview = nil
            $0.inviteClaimPreviewEvaluatedAt = nil
        }

        XCTAssertEqual(claims.requestCount, 0)
        XCTAssertEqual(routing.consumedSequences, [envelope.sequence])
        await store.finish()
    }

    @MainActor
    func testSecondClaimLinkIsQueuedNotReplacedAndOpensAfterNotNow() async throws {
        let first = CompetitionRouteEnvelope(
            sequence: 20,
            route: .claimInvite(try XCTUnwrap(CompetitionInviteClaimToken(
                rawValue: "QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
            )))
        )
        let second = CompetitionRouteEnvelope(
            sequence: 21,
            route: .claimInvite(try XCTUnwrap(CompetitionInviteClaimToken(
                rawValue: "RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR"
            )))
        )
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(expectedToken: try XCTUnwrap(
            CompetitionInviteClaimToken(rawValue: "QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ")
        ), results: [])
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(
                    publication: publication(revision: 1, visibleIDs: [])
                )
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        await store.send(.routeReceived(first)) {
            $0.pendingClaimRoute = first
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, first)
        await store.send(.routeReceived(second)) {
            $0.queuedClaimRoute = second
        }
        // The same link again is ignored.
        let duplicate = CompetitionRouteEnvelope(sequence: 22, route: first.route)
        await store.send(.routeReceived(duplicate))
        XCTAssertEqual(store.state.pendingClaimRoute, first)

        await store.send(.notNowClaimTapped) {
            $0.pendingClaimRoute = second
            $0.queuedClaimRoute = nil
            $0.lastHandledClaimRouteSequence = first.sequence
            $0.inviteClaimPreview = nil
            $0.inviteClaimPreviewEvaluatedAt = nil
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, second)
        XCTAssertEqual(claims.requestCount, 0)
        XCTAssertEqual(routing.consumedSequences, [duplicate.sequence, first.sequence])
        await store.finish()
    }

    @MainActor
    func testSecondClaimLinkWaitsDuringColdStart() async throws {
        let firstToken = try XCTUnwrap(CompetitionInviteClaimToken(
            rawValue: "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW"
        ))
        let first = CompetitionRouteEnvelope(sequence: 60, route: .claimInvite(firstToken))
        let second = CompetitionRouteEnvelope(
            sequence: 61,
            route: .claimInvite(try XCTUnwrap(CompetitionInviteClaimToken(
                rawValue: "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
            )))
        )
        let claims = MainTabClaimRecorder(expectedToken: firstToken, results: [])
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = MainTabRoutingRecorder().client
            $0.date = .constant(MainTabClaimRecorder.now)
        }
        // No publication yet: the first link is still idle.
        await store.send(.routeReceived(first)) { $0.pendingClaimRoute = first }
        await store.send(.routeReceived(second)) { $0.queuedClaimRoute = second }

        let initial = publication(revision: 1, visibleIDs: [])
        await store.send(.competition(.publication(initial))) {
            $0.competition.publication = initial
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, first)
        XCTAssertEqual(store.state.queuedClaimRoute, second)
        await store.finish()
    }

    @MainActor
    func testSecondClaimLinkWaitsWhileTheAcceptedMatchLoads() async throws {
        let matchID = competitionID("81000000-0000-0000-0000-000000000070")
        let firstToken = try XCTUnwrap(CompetitionInviteClaimToken(
            rawValue: "YYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYY"
        ))
        let first = CompetitionRouteEnvelope(sequence: 70, route: .claimInvite(firstToken))
        let second = CompetitionRouteEnvelope(
            sequence: 71,
            route: .claimInvite(try XCTUnwrap(CompetitionInviteClaimToken(
                rawValue: "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"
            )))
        )
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(
            expectedToken: firstToken,
            results: [.success(matchID, expectedRevision: 2)]
        )
        let clock = TestClock()
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(
                    publication: publication(revision: 1, visibleIDs: [])
                )
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.continuousClock = clock
            $0.date = .constant(MainTabClaimRecorder.now)
        }
        await store.send(.routeReceived(first)) {
            $0.pendingClaimRoute = first
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, first)
        await store.send(.acceptClaimTapped)
        await store.receive(.processPendingClaim) {
            $0.claimRouteSequenceInFlight = first.sequence
            $0.inviteClaimStatus = .claiming
        }
        await store.receive(.claimInviteResponse(
            sequence: first.sequence,
            .success(matchID, expectedRevision: 2)
        )) {
            $0.pendingClaimRoute = nil
            $0.claimRouteSequenceInFlight = nil
            $0.lastHandledClaimRouteSequence = first.sequence
            $0.inviteClaimPreview = nil
            $0.inviteClaimPreviewEvaluatedAt = nil
            $0.pendingClaimNavigation = .init(competitionID: matchID, expectedPublicationRevision: 2)
            $0.inviteClaimStatus = .waitingForCompetition
        }
        // The second link waits for the match instead of starting.
        await store.send(.routeReceived(second)) { $0.queuedClaimRoute = second }

        let acknowledged = publication(revision: 2, visibleID: matchID)
        await store.send(.competition(.publication(acknowledged))) {
            $0.competition.publication = acknowledged
            $0.path = [matchID]
            $0.pendingClaimNavigation = nil
            $0.pendingClaimRoute = second
            $0.queuedClaimRoute = nil
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, second)
        await clock.advance(by: .seconds(15))
        await store.finish()
    }

    @MainActor
    func testDeclineConfirmedCallsDeclineAndConsumes() async throws {
        let token = try XCTUnwrap(CompetitionInviteClaimToken(
            rawValue: "SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS"
        ))
        let envelope = CompetitionRouteEnvelope(sequence: 30, route: .claimInvite(token))
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(expectedToken: token, results: [])
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(
                    publication: publication(revision: 1, visibleIDs: [])
                )
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        await store.send(.routeReceived(envelope)) {
            $0.pendingClaimRoute = envelope
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, envelope)
        await store.send(.declineClaimConfirmed) {
            $0.inviteClaimStatus = .declining
        }
        await store.receive(.declineClaimFinished(sequence: envelope.sequence, succeeded: true)) {
            $0.pendingClaimRoute = nil
            $0.lastHandledClaimRouteSequence = envelope.sequence
            $0.inviteClaimPreview = nil
            $0.inviteClaimPreviewEvaluatedAt = nil
            $0.inviteClaimStatus = .idle
        }
        XCTAssertEqual(
            claims.declinedIDs,
            [CompetitionID(MainTabClaimRecorder.preview.competitionID)]
        )
        XCTAssertEqual(claims.requestCount, 0)
        XCTAssertEqual(routing.consumedSequences, [envelope.sequence])
        await store.finish()
    }

    @MainActor
    func testDeclineFailureReturnsToReadyWithError() async throws {
        let token = try XCTUnwrap(CompetitionInviteClaimToken(
            rawValue: "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT"
        ))
        let envelope = CompetitionRouteEnvelope(sequence: 31, route: .claimInvite(token))
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(expectedToken: token, results: [])
        claims.declineSucceeds = false
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(
                    publication: publication(revision: 1, visibleIDs: [])
                )
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.date = .constant(MainTabClaimRecorder.now)
        }

        await store.send(.routeReceived(envelope)) {
            $0.pendingClaimRoute = envelope
            $0.inviteClaimStatus = .loadingPreview
        }
        await receivePreview(store, envelope)
        await store.send(.declineClaimConfirmed) {
            $0.inviteClaimStatus = .declining
        }
        await store.receive(.declineClaimFinished(sequence: envelope.sequence, succeeded: false)) {
            $0.inviteClaimStatus = .ready
            $0.claimDeclineFailed = true
        }
        XCTAssertEqual(routing.consumedSequences, [])
        await store.finish()
    }

    @MainActor
    func testPreviewOwnChallengeActiveMatchAndUnavailableStatuses() async throws {
        let token = try XCTUnwrap(CompetitionInviteClaimToken(
            rawValue: "UUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUU"
        ))
        for (failure, status) in [
            (CompetitionRemoteFailure.forbidden, MainTabFeature.InviteClaimStatus.ownChallenge),
            (.activeMatchExists, .activeMatchExists),
            (.inviteUnavailable, .unavailable),
        ] {
            let envelope = CompetitionRouteEnvelope(sequence: 40, route: .claimInvite(token))
            let routing = MainTabRoutingRecorder()
            let claims = MainTabClaimRecorder(expectedToken: token, results: [])
            claims.previewResult = .failure(failure)
            let store = TestStore(
                initialState: MainTabFeature.State(
                    competition: CompetitionFeature.State(
                        publication: publication(revision: 1, visibleIDs: [])
                    )
                )
            ) {
                MainTabFeature()
            } withDependencies: {
                $0.competitionClient = claims.client
                $0.competitionRoutingClient = routing.client
                $0.date = .constant(MainTabClaimRecorder.now)
            }
            await store.send(.routeReceived(envelope)) {
                $0.pendingClaimRoute = envelope
                $0.inviteClaimStatus = .loadingPreview
            }
            await store.receive(.claimPreviewResponse(sequence: envelope.sequence, .failure(failure))) {
                $0.pendingClaimRoute = nil
                $0.lastHandledClaimRouteSequence = envelope.sequence
                $0.inviteClaimStatus = status
            }
            await store.send(.dismissClaimStatus) { $0.inviteClaimStatus = .idle }
            XCTAssertEqual(routing.consumedSequences, [envelope.sequence])
            XCTAssertEqual(claims.requestCount, 0)
            await store.finish()
        }
    }

    @MainActor
    func testPreviewAlreadyAcceptedGoesToTheMatch() async throws {
        let token = try XCTUnwrap(CompetitionInviteClaimToken(
            rawValue: "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
        ))
        let envelope = CompetitionRouteEnvelope(sequence: 41, route: .claimInvite(token))
        let matchID = CompetitionID(MainTabClaimRecorder.preview.competitionID)
        let routing = MainTabRoutingRecorder()
        let claims = MainTabClaimRecorder(expectedToken: token, results: [])
        claims.previewResult = .success(CompetitionInvitePreview(
            competitionID: matchID.rawValue,
            state: .accepted,
            sender: MainTabClaimRecorder.preview.sender,
            timeZoneIdentifier: "America/Los_Angeles",
            expiresAt: MainTabClaimRecorder.now
        ))
        let visible = publication(revision: 4, visibleID: matchID)
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(publication: visible)
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = claims.client
            $0.competitionRoutingClient = routing.client
            $0.date = .constant(MainTabClaimRecorder.now)
        }
        await store.send(.routeReceived(envelope)) {
            $0.pendingClaimRoute = envelope
            $0.inviteClaimStatus = .loadingPreview
        }
        await store.receive(.claimPreviewResponse(
            sequence: envelope.sequence,
            .success(try claims.previewResult.get())
        )) {
            $0.claimRouteSequenceInFlight = envelope.sequence
        }
        await store.receive(.claimInviteResponse(
            sequence: envelope.sequence,
            .success(matchID, expectedRevision: 4)
        )) {
            $0.pendingClaimRoute = nil
            $0.claimRouteSequenceInFlight = nil
            $0.lastHandledClaimRouteSequence = envelope.sequence
            $0.path = [matchID]
            $0.inviteClaimStatus = .idle
        }
        XCTAssertEqual(claims.requestCount, 0)
        await store.finish()
    }

    @MainActor
    func testChallengeLinkResolvesToReadyAndPrefillsThePerson() async throws {
        let code = try XCTUnwrap(CompetitionChallengeLinkCode(rawValue: "Xb3kP9qL2mN8vR4tY6wZ1a"))
        // The link gives a name, and the sheet keeps the code to send by.
        let maya = CompetitionFeature.InviteRecipient(link: code, displayName: "Maya")
        let envelope = CompetitionRouteEnvelope(sequence: 50, route: .challengeLink(code))
        let routing = MainTabRoutingRecorder()
        var client = MainTabLifecycleRecorder().client
        client.resolveChallengeLink = { _ in "Maya" }
        let store = TestStore(
            initialState: MainTabFeature.State(
                competition: CompetitionFeature.State(
                    publication: publication(revision: 1, visibleIDs: [])
                )
            )
        ) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = client
            $0.competitionRoutingClient = routing.client
        }
        await store.send(.routeReceived(envelope)) {
            $0.lastHandledRouteSequence = envelope.sequence
            $0.challengeFromLink = .init(sequence: 50, code: code, status: .resolving)
        }
        await store.receive(.challengeLinkResolved(sequence: 50, .success("Maya"))) {
            $0.challengeFromLink?.status = .ready(displayName: "Maya")
        }
        await store.receive(.competition(.challengeRecipientChosen(maya))) {
            $0.competition.inviteRecipient = maya
            $0.competition.inviteRecipientCode = code.rawValue
        }
        await store.send(.dismissChallengeFromLink) {
            $0.challengeFromLink = nil
        }
        await store.receive(.competition(.challengeSheetDismissed)) {
            $0.competition.inviteRecipient = nil
            $0.competition.inviteRecipientCode = ""
        }
        XCTAssertEqual(routing.consumedSequences, [envelope.sequence])
        await store.finish()
    }

    @MainActor
    func testChallengeLinkResetBeforeSendShowsUnavailable() async throws {
        let code = try XCTUnwrap(CompetitionChallengeLinkCode(rawValue: "Xb3kP9qL2mN8vR4tY6wZ1a"))
        let key = UUID()
        var competition = CompetitionFeature.State(
            publication: publication(revision: 1, visibleIDs: []),
            inviteCreations: [.sheet: .init(recipient: .challengeLink(code), idempotencyKey: key, status: .creating)],
            inviteRecipient: .init(link: code, displayName: "Maya")
        )
        competition.inviteRecipientCode = code.rawValue
        var initial = MainTabFeature.State(competition: competition)
        initial.challengeFromLink = .init(sequence: 52, code: code, status: .ready(displayName: "Maya"))
        let store = TestStore(initialState: initial) {
            MainTabFeature()
        } withDependencies: {
            $0.competitionClient = MainTabLifecycleRecorder().client
            $0.competitionRoutingClient = MainTabRoutingRecorder().client
        }
        // The same collapsed copy as a link that never existed.
        await store.send(.competition(.createInviteResponse(.sheet, idempotencyKey: key, .failure(.recipientUnavailable)))) {
            $0.competition.inviteCreations[.sheet] = nil
            $0.competition.inviteRecipient = nil
            $0.competition.inviteRecipientStatus = .notFound
            $0.challengeFromLink?.status = .unavailable
        }
        await store.finish()
    }

    @MainActor
    func testChallengeLinkOwnUnavailableAndRetry() async throws {
        let code = try XCTUnwrap(CompetitionChallengeLinkCode(rawValue: "Own0wn0wn0wn0wn0wn0wn0"))
        for (failure, status) in [
            (CompetitionRemoteFailure.ownChallengeLink, MainTabFeature.ChallengeFromLink.Status.ownLink),
            (.recipientUnavailable, .unavailable),
            (.retryableTransport, .retryable),
        ] {
            var client = MainTabLifecycleRecorder().client
            client.resolveChallengeLink = { _ in throw failure }
            let store = TestStore(
                initialState: MainTabFeature.State(
                    competition: CompetitionFeature.State(
                        publication: publication(revision: 1, visibleIDs: [])
                    )
                )
            ) {
                MainTabFeature()
            } withDependencies: {
                $0.competitionClient = client
                $0.competitionRoutingClient = MainTabRoutingRecorder().client
            }
            await store.send(.routeReceived(.init(sequence: 51, route: .challengeLink(code)))) {
                $0.lastHandledRouteSequence = 51
                $0.challengeFromLink = .init(sequence: 51, code: code, status: .resolving)
            }
            await store.receive(.challengeLinkResolved(sequence: 51, .failure(failure))) {
                $0.challengeFromLink?.status = status
            }
            await store.finish()
        }
    }

    private func publication(
        revision: UInt64,
        visibleID: CompetitionID,
        lifecycle: LocalCompetitionLifecyclePresentation = .scheduled
    ) -> LocalCompetitionPublication {
        publication(
            revision: revision,
            visibleIDs: [visibleID],
            lifecycle: lifecycle
        )
    }

    private func publication(
        revision: UInt64,
        visibleIDs: [CompetitionID],
        lifecycle: LocalCompetitionLifecyclePresentation = .scheduled
    ) -> LocalCompetitionPublication {
        LocalCompetitionPublication(
            publicationRevision: revision,
            dashboard: LocalCompetitionDashboard(
                competitions: visibleIDs.map {
                    LocalCompetitionPresentation(
                        id: $0,
                        ownerDisplayName: "Naren",
                        opponentDisplayName: "Alex",
                        lifecycle: lifecycle,
                        acceptedConfiguration: nil,
                        userPoints: 0,
                        opponentPoints: 0,
                        days: [],
                        currentDayOrdinal: nil,
                        lastRefresh: nil,
                        tally: nil,
                        terminalResult: nil
                    )
                },
                awards: [],
                issues: [],
                hiddenTerminalCompetitionCount: 0
            )
        )
    }

    private func competitionID(_ value: String) -> CompetitionID {
        CompetitionID(UUID(uuidString: value)!)
    }

    private static let claimToken = "KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK"

    private func claimEnvelope(
        sequence: UInt64,
        token: String = MainTabFeatureTests.claimToken
    ) throws -> CompetitionRouteEnvelope {
        CompetitionRouteEnvelope(
            sequence: sequence,
            route: .claimInvite(
                try XCTUnwrap(CompetitionInviteClaimToken(rawValue: token))
            )
        )
    }

    /// The recorder's preview arrives and the sheet becomes ready.
    @MainActor
    private func receivePreview(
        _ store: TestStore<MainTabFeature.State, MainTabFeature.Action>,
        _ envelope: CompetitionRouteEnvelope,
        _ preview: CompetitionInvitePreview = MainTabClaimRecorder.preview
    ) async {
        await store.receive(
            .claimPreviewResponse(sequence: envelope.sequence, .success(preview))
        ) {
            $0.inviteClaimPreview = preview
            $0.inviteClaimPreviewEvaluatedAt = MainTabClaimRecorder.now
            $0.inviteClaimStatus = .ready
        }
    }
}

private final class MainTabRoutingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let hub = CompetitionRouteHub()
    private var consumed: [UInt64] = []

    var consumedSequences: [UInt64] {
        lock.withLock { consumed }
    }

    var client: CompetitionRoutingClient {
        CompetitionRoutingClient(
            routes: { [hub] in hub.stream() },
            enqueue: { [hub] route in _ = hub.enqueue(route) },
            consume: { [weak self, hub] sequence in
                self?.lock.withLock { self?.consumed.append(sequence) }
                hub.consume(sequence: sequence)
            }
        )
    }

    func enqueue(_ route: CompetitionRoute) -> CompetitionRouteEnvelope {
        hub.enqueue(route)!
    }
}

private final class MainTabLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var triggers: [ActivityRefreshTrigger] = []

    var startCount: Int {
        lock.withLock { starts }
    }

    var stopCount: Int {
        lock.withLock { stops }
    }

    var reconcileTriggers: [ActivityRefreshTrigger] {
        lock.withLock { triggers }
    }

    var client: LocalCompetitionClient {
        let publication = LocalCompetitionPublication(
            publicationRevision: 0,
            dashboard: LocalCompetitionDashboard(
                competitions: [],
                awards: [],
                issues: [],
                hiddenTerminalCompetitionCount: 0
            )
        )
        return LocalCompetitionClient(
            start: { [weak self] in
                self?.lock.withLock { self?.starts += 1 }
                return AsyncStream { $0.finish() }
            },
            updates: { AsyncStream { $0.finish() } },
            reconcileAll: { [weak self] trigger in
                self?.lock.withLock { self?.triggers.append(trigger) }
                return publication
            },
            accept: { _ in publication },
            decline: { _ in publication },
            archive: { _ in publication },
            rematch: { _ in publication },
            reinvite: { publication },
            waitUntil: { _ in },
            stop: { [weak self] in
                self?.lock.withLock { self?.stops += 1 }
            }
        )
    }
}

private final class PermissionOnboardingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let health: HealthAccessStatus
    private let deferred: Bool
    private var recorded: [String] = []

    init(health: HealthAccessStatus = .requested, deferred: Bool = false) {
        self.health = health
        self.deferred = deferred
    }

    var calls: [String] { lock.withLock { recorded } }

    var client: PermissionOnboardingClient {
        PermissionOnboardingClient(
            requestHealthAccess: { [weak self] in self?.record("health") },
            deferNotifications: { [weak self] in
                self?.record("deferNotifications")
            },
            healthAccess: { [health] in health },
            notificationsDeferred: { [deferred] in deferred }
        )
    }

    private func record(_ call: String) {
        lock.withLock { recorded.append(call) }
    }
}

private final class MainTabClaimRecorder: @unchecked Sendable {
    enum Result {
        case success(CompetitionID, expectedRevision: UInt64)
        case failure(CompetitionRemoteFailure)
    }

    private let lock = NSLock()
    private let lifecycle = MainTabLifecycleRecorder()
    private let expectedToken: CompetitionInviteClaimToken
    private var results: [Result]
    private var requests = 0
    private var matched = true

    init(expectedToken: CompetitionInviteClaimToken, results: [Result]) {
        self.expectedToken = expectedToken
        self.results = results
    }

    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let preview = CompetitionInvitePreview(
        competitionID: UUID(uuidString: "81000000-0000-0000-0000-0000000000ff")!,
        state: .pending,
        sender: AuthenticatedProfile(
            id: UUID(uuidString: "82000000-0000-0000-0000-0000000000ff")!,
            displayName: "Naren"
        ),
        timeZoneIdentifier: "America/Los_Angeles",
        expiresAt: now.addingTimeInterval(20 * 60 * 60)
    )

    private var storedPreviewResult: Swift.Result<
        CompetitionInvitePreview, CompetitionRemoteFailure
    > = .success(preview)
    /// Read on each preview request.
    var previewResult: Swift.Result<CompetitionInvitePreview, CompetitionRemoteFailure> {
        get { lock.withLock { storedPreviewResult } }
        set { lock.withLock { storedPreviewResult = newValue } }
    }
    var declineSucceeds = true
    private var declines: [CompetitionID] = []
    var declinedIDs: [CompetitionID] { lock.withLock { declines } }
    private var blocks: [CompetitionID] = []
    var blockedIDs: [CompetitionID] { lock.withLock { blocks } }

    var requestCount: Int { lock.withLock { requests } }
    var allTokensMatched: Bool { lock.withLock { matched } }

    var client: CompetitionClient {
        var client = lifecycle.client
        let declineSucceeds = declineSucceeds
        client.previewInvite = { [weak self] _ in
            guard let self else { throw CompetitionRemoteFailure.operationFailed }
            return try self.previewResult.get()
        }
        client.decline = { [weak self] id in
            self?.lock.withLock { self?.declines.append(id) }
            return LocalCompetitionPublication(
                publicationRevision: 0,
                dashboard: LocalCompetitionDashboard(
                    competitions: [],
                    awards: [],
                    issues: declineSucceeds ? [] : [.commandRejected(id)],
                    hiddenTerminalCompetitionCount: 0
                )
            )
        }
        client.block = { [weak self] id in
            self?.lock.withLock { self?.blocks.append(id) }
            return LocalCompetitionPublication(
                publicationRevision: 0,
                dashboard: LocalCompetitionDashboard(
                    competitions: [],
                    awards: [],
                    issues: declineSucceeds ? [] : [.commandRejected(id)],
                    hiddenTerminalCompetitionCount: 0
                )
            )
        }
        client.claimInvite = { [weak self] request in
            guard let self else { throw CompetitionRemoteFailure.operationFailed }
            return try self.lock.withLock {
                self.requests += 1
                self.matched = self.matched
                    && request.token == self.expectedToken.rawValue
                guard !self.results.isEmpty else {
                    throw CompetitionRemoteFailure.operationFailed
                }
                switch self.results.removeFirst() {
                case let .success(id, expectedRevision):
                    return CompetitionInviteClaimOutcome(
                        claim: try CompetitionInviteClaim(
                            competitionID: id.rawValue
                        ),
                        expectedPublicationRevision: expectedRevision
                    )
                case let .failure(failure):
                    throw failure
                }
            }
        }
        return client
    }
}

import CompetitionCore
import Foundation
import XCTest

@testable import HealthComp

final class RemoteCompetitionClientTests: XCTestCase {
    func testLiveClientMountsWhenAPNsEnvironmentIsUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "7f000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let provider = SupabaseClientProvider {
            throw SupabaseConfigurationError.missingURL
        }
        let client = CompetitionClient.live(
            provider: provider,
            installationEnvironment: nil
        )

        try await client.mountAuthenticatedProfile(profile, paths)
        await client.stop()
    }

    func testAuthenticatedProfileTeardownRemovesRegisteredInstallation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "80000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let installations = RemoteCompetitionInstallationProbe()
        let registration = RemoteCompetitionPushProbe(
            token: String(repeating: "ac", count: 32)
        )
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(
                listCompetitions: { [] },
                registerInstallation: { request in
                    try await installations.register(request)
                },
                removeInstallation: { id in
                    try await installations.remove(id)
                }
            ),
            environment: try environment(),
            pushRegistrationClient: registration.client,
            installationEnvironment: .sandbox
        )

        try await client.mountAuthenticatedProfile(profile, paths)
        try await client.prepareForProfileTeardown(
            requireRemoteInstallationRemoval: true
        )
        await client.stop()

        let requests = await installations.registrationRequests()
        let removals = await installations.removalIDs()
        let registrationCalls = await registration.recordedCalls()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(removals, requests.map(\.installationID))
        XCTAssertEqual(
            registrationCalls,
            ["register", "unregister"]
        )
    }

    func testProfileScopedAppAttestWrapperReusesStableInstallationOnRelaunch()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profileID = UUID(
            uuidString: "8a000000-0000-4000-8000-000000000001"
        )!
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profileID,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let probe = RemoteCompetitionAppAttestProbe()
        let service = RemoteCompetitionAppAttestServiceProbe()
        let rawAPI = remoteAPI(
            listCompetitions: { [] },
            issueAppAttestChallenge: { try await probe.issue($0) },
            submitAttestedScoreRevision: { try await probe.submit($0) }
        )

        let first = try await ProfileScopedAppAttestRemoteAPI.make(
            profileID: profileID,
            paths: paths,
            installationStore: CompetitionInstallationStateStore(
                directory: paths.installationsDirectory
            ),
            remoteAPI: rawAPI,
            service: service
        )
        _ = try await first.appendScoreRevision(
            appAttestScoreRequest(revision: 1)
        )
        let relaunched = try await ProfileScopedAppAttestRemoteAPI.make(
            profileID: profileID,
            paths: paths,
            installationStore: CompetitionInstallationStateStore(
                directory: paths.installationsDirectory
            ),
            remoteAPI: rawAPI,
            service: service
        )
        _ = try await relaunched.appendScoreRevision(
            appAttestScoreRequest(revision: 2)
        )

        let challenges = await probe.challengeRequests()
        let submissions = await probe.submissions()
        let generatedKeyCount = await service.generatedKeyCount()
        XCTAssertEqual(challenges.count, 2)
        XCTAssertEqual(
            Set(challenges.map(\.installationID)).count,
            1
        )
        XCTAssertEqual(
            submissions.map(\.appAttest.proofKind),
            [.attestation, .assertion]
        )
        XCTAssertEqual(generatedKeyCount, 1)
    }

    func testNotificationPreferenceReadCompletesBeforeProfileRemount()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "7f000000-0000-4000-8000-000000000002"
            )!,
            displayName: "Beta Alice"
        )
        let secondProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "7f000000-0000-4000-8000-000000000003"
            )!,
            displayName: "Beta Bob"
        )
        let firstPaths = AuthenticatedProfileStoragePaths(
            profileID: firstProfile.id,
            rootDirectory: root.appendingPathComponent("first")
        )
        let secondPaths = AuthenticatedProfileStoragePaths(
            profileID: secondProfile.id,
            rootDirectory: root.appendingPathComponent("second")
        )
        for directory in firstPaths.fixedDirectories
            + secondPaths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let probe = RemoteNotificationOperationOrderProbe()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: try environment(),
            notificationPreferencesFactory: { paths in
                if paths.profileID == firstProfile.id {
                    return probe.blockingClient
                }
                probe.record("second-mounted")
                return .constant(mutedOpponentIdentities: [])
            }
        )

        try await client.mountAuthenticatedProfile(firstProfile, firstPaths)
        let readTask = Task {
            try await client.loadMutedOpponentIdentities()
        }
        await probe.waitUntilReadStarts()
        let mountTask = Task {
            try await client.prepareForProfileTeardown(
                requireRemoteInstallationRemoval: false
            )
            await client.stop()
            try await client.mountAuthenticatedProfile(
                secondProfile,
                secondPaths
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        await probe.releaseRead()
        _ = try await readTask.value
        try await mountTask.value

        XCTAssertEqual(
            probe.events(),
            ["read-start", "read-end", "second-mounted"]
        )
        await client.stop()
    }

    func testAuthorizationPromptFinishesBeforeTerminalProfileRemount()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "7f000000-0000-4000-8000-000000000004"
            )!,
            displayName: "Beta Alice"
        )
        let secondProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "7f000000-0000-4000-8000-000000000005"
            )!,
            displayName: "Beta Bob"
        )
        let firstPaths = AuthenticatedProfileStoragePaths(
            profileID: firstProfile.id,
            rootDirectory: root.appendingPathComponent("first")
        )
        let secondPaths = AuthenticatedProfileStoragePaths(
            profileID: secondProfile.id,
            rootDirectory: root.appendingPathComponent("second")
        )
        for directory in firstPaths.fixedDirectories
            + secondPaths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let authorization = RemoteNotificationAuthorizationProbe()
        let secondMount = expectation(description: "second profile mounted")
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: try environment(),
            notificationClient: authorization.client,
            notificationPreferencesFactory: { paths in
                if paths.profileID == secondProfile.id {
                    secondMount.fulfill()
                }
                return .constant(mutedOpponentIdentities: [])
            }
        )

        try await client.mountAuthenticatedProfile(firstProfile, firstPaths)
        let authorizationTask = Task {
            await client.requestNotificationAuthorization()
        }
        await authorization.waitUntilRequestStarts()
        let mountTask = Task {
            try await client.prepareForProfileTeardown(
                requireRemoteInstallationRemoval: false
            )
            await client.stop()
            try await client.mountAuthenticatedProfile(
                secondProfile,
                secondPaths
            )
        }

        await authorization.releaseRequest()
        await fulfillment(of: [secondMount], timeout: 1)
        try await mountTask.value
        let state = await authorizationTask.value
        XCTAssertEqual(state, .authorized)
        await client.stop()
    }

    func testMountedRemoteClientPublishesEmptyCanonicalDashboard()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let probe = RemoteCompetitionClientProbe()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: {
                await probe.recordList()
                return []
            }),
            environment: try environment()
        )

        try await client.mountAuthenticatedProfile(profile, paths)
        var iterator = client.start().makeAsyncIterator()
        let nextPublication = await iterator.next()
        let publication = try XCTUnwrap(nextPublication)

        XCTAssertEqual(publication.publicationRevision, 1)
        XCTAssertEqual(publication.dashboard.competitions, [])
        XCTAssertEqual(publication.dashboard.awards, [])
        XCTAssertEqual(publication.dashboard.issues, [])
        let listCount = await probe.listCount()
        XCTAssertEqual(listCount, 1)
        await client.stop()
    }

    func testStartRequestsHealthAuthorizationAndPublishesFailure()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000002"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 13,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let days = try calendar.sevenDayWindow(startingOn: start)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: try calendar.startOfDay(start),
                    monotonic: MonotonicInstant(
                        epochID: "task13-remote-health-authorization",
                        nanoseconds: 1
                    )
                ),
                timeZoneIdentifier: calendar.timeZoneIdentifier,
                initialDays: days.map { .missing(day: $0) },
                initialAuthorizationState: .failure(
                    .healthDataUnavailable
                ),
                changes: []
            )
        )
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: source)
        )

        try await client.mountAuthenticatedProfile(profile, paths)
        var iterator = client.start().makeAsyncIterator()
        let nextPublication = await iterator.next()
        let publication = try XCTUnwrap(nextPublication)

        let authorizationRequestCount = await source.authorizationRequestCount()
        XCTAssertEqual(authorizationRequestCount, 1)
        XCTAssertEqual(
            publication.dashboard.issues,
            [.authorizationUnavailable]
        )

        let refreshedPublication = await client.reconcileAll(
            .reconciliationProbe
        )
        XCTAssertEqual(
            refreshedPublication.dashboard.issues,
            [.authorizationUnavailable]
        )
        await client.stop()
    }

    func testHealthAuthorizationPromptDoesNotPublishAcrossTerminalProfileRemount()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000003"
            )!,
            displayName: "Beta Alice"
        )
        let secondProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000004"
            )!,
            displayName: "Beta Bob"
        )
        let firstPaths = AuthenticatedProfileStoragePaths(
            profileID: firstProfile.id,
            rootDirectory: root.appendingPathComponent("first")
        )
        let secondPaths = AuthenticatedProfileStoragePaths(
            profileID: secondProfile.id,
            rootDirectory: root.appendingPathComponent("second")
        )
        for directory in firstPaths.fixedDirectories
            + secondPaths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 13,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let days = try calendar.sevenDayWindow(startingOn: start)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: try calendar.startOfDay(start),
                    monotonic: MonotonicInstant(
                        epochID: "task13-remote-health-remount",
                        nanoseconds: 1
                    )
                ),
                timeZoneIdentifier: calendar.timeZoneIdentifier,
                initialDays: days.map { .missing(day: $0) },
                changes: []
            )
        )
        await source.blockNextAuthorizationRequest()
        let lists = RemoteCompetitionClientProbe()
        let secondMount = expectation(description: "second profile mounted")
        let firstStreamFinished = expectation(
            description: "first profile stream finished after remount"
        )
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: {
                await lists.recordList()
                return []
            }),
            environment: .accelerated(source: source),
            notificationPreferencesFactory: { paths in
                if paths.profileID == secondProfile.id {
                    secondMount.fulfill()
                }
                return .constant(mutedOpponentIdentities: [])
            }
        )

        try await client.mountAuthenticatedProfile(firstProfile, firstPaths)
        var firstIterator = client.start().makeAsyncIterator()
        let firstStreamTask = Task {
            while await firstIterator.next() != nil {}
            firstStreamFinished.fulfill()
        }
        await source.waitUntilAuthorizationRequestIsBlocked()
        let mountTask = Task {
            try await client.prepareForProfileTeardown(
                requireRemoteInstallationRemoval: false
            )
            await client.stop()
            try await client.mountAuthenticatedProfile(
                secondProfile,
                secondPaths
            )
        }

        await fulfillment(of: [secondMount], timeout: 1)
        try await mountTask.value
        await fulfillment(of: [firstStreamFinished], timeout: 1)
        await firstStreamTask.value

        var secondIterator = client.start().makeAsyncIterator()
        let nextSecondPublication = await secondIterator.next()
        let secondStartPublication = try XCTUnwrap(nextSecondPublication)
        XCTAssertEqual(secondStartPublication.publicationRevision, 1)

        await source.releaseBlockedAuthorizationRequest()
        await source.waitUntilAuthorizationRequestCompletionCount(2)
        let reconciledPublication = await client.reconcileAll(
            .reconciliationProbe
        )
        XCTAssertEqual(reconciledPublication.publicationRevision, 2)
        let listCount = await lists.listCount()
        XCTAssertEqual(listCount, 3)
        await client.stop()
    }

    func testCreateAndClaimReturnCanonicalPublicationRevisions()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let competitionID = UUID(
            uuidString: "82000000-0000-4000-8000-000000000001"
        )!
        let token = Data(repeating: 0x42, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let invite = try CompetitionInvite(
            competitionID: competitionID,
            token: token
        )
        let claim = try CompetitionInviteClaim(
            competitionID: competitionID
        )
        let probe = RemoteCompetitionClientCommandProbe()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(
                listCompetitions: {
                    await probe.recordList()
                    return []
                },
                createInvite: { request in
                    await probe.recordCreate(request)
                    return invite
                },
                claimInvite: { request in
                    await probe.recordClaim(request)
                    return claim
                }
            ),
            environment: try environment()
        )
        let createRequest = try CompetitionInviteCreationRequest(
            timeZoneIdentifier: "America/Los_Angeles",
            rematchParentID: nil,
            idempotencyKey: UUID(
                uuidString: "83000000-0000-4000-8000-000000000001"
            )!
        )
        let claimRequest = try CompetitionInviteClaimRequest(token: token)

        try await client.mountAuthenticatedProfile(profile, paths)
        var iterator = client.start().makeAsyncIterator()
        let initialPublication = await iterator.next()
        XCTAssertEqual(initialPublication?.publicationRevision, 1)

        let creation = try await client.createInvite(createRequest)
        let nextCreationPublication = await iterator.next()
        let creationPublication = try XCTUnwrap(nextCreationPublication)
        XCTAssertEqual(creation.invite, invite)
        XCTAssertEqual(creation.expectedPublicationRevision, 2)
        XCTAssertEqual(creationPublication.publicationRevision, 2)
        XCTAssertEqual(creationPublication.dashboard.competitions, [])

        let claimed = try await client.claimInvite(claimRequest)
        let nextClaimPublication = await iterator.next()
        let claimPublication = try XCTUnwrap(nextClaimPublication)
        XCTAssertEqual(claimed.claim, claim)
        XCTAssertEqual(claimed.expectedPublicationRevision, 3)
        XCTAssertEqual(claimPublication.publicationRevision, 3)
        XCTAssertEqual(claimPublication.dashboard.competitions, [])

        let listCount = await probe.listCount()
        let createRequests = await probe.createRequests()
        let claimRequests = await probe.claimRequests()
        XCTAssertEqual(listCount, 3)
        XCTAssertEqual(createRequests, [createRequest])
        XCTAssertEqual(claimRequests, [claimRequest])
        await client.stop()
    }

    func testArchiveCallsServerThenReturnsCanonicalPublicationRevision()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let competitionID = CompetitionID(
            UUID(
                uuidString: "82000000-0000-4000-8000-000000000001"
            )!
        )
        let probe = RemoteCompetitionClientCommandProbe()
        var api = remoteAPI(listCompetitions: {
            await probe.recordList()
            return []
        })
        api.archiveCompetition = { id in
            await probe.recordArchive(id)
        }
        let client = CompetitionClient.remote(
            remoteAPI: api,
            environment: try environment()
        )

        try await client.mountAuthenticatedProfile(profile, paths)
        var iterator = client.start().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.publicationRevision, 1)

        let returned = await client.archive(competitionID)
        let canonical = await iterator.next()

        XCTAssertEqual(returned.publicationRevision, 2)
        XCTAssertEqual(canonical?.publicationRevision, 2)
        let archives = await probe.archiveRequests()
        XCTAssertEqual(archives, [competitionID.rawValue])
        await client.stop()
    }

    func testAnonymizedOpponentIdentityRemainsVisibleInRemoteHistory()
        throws
    {
        let ownerID = UUID(
            uuidString: "81000000-0000-4000-8000-000000000001"
        )!
        let opponentID = UUID(
            uuidString: "81000000-0000-4000-8000-000000000002"
        )!
        let profile = AuthenticatedProfile(
            id: ownerID,
            displayName: "Beta Alice"
        )
        let descriptor = try CompetitionDescriptor(
            competitionID: UUID(
                uuidString: "82000000-0000-4000-8000-000000000001"
            )!,
            creatorProfileID: ownerID,
            timeZoneIdentifier: "UTC",
            startDay: "2026-08-01",
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            lifecycle: .archived,
            invitationExpiresAt: Date(timeIntervalSince1970: 1_786_032_000),
            bestAvailableDeadline: Date(
                timeIntervalSince1970: 1_786_809_600
            ),
            rematchParentID: nil,
            nextServerSequence: 10,
            participants: [
                try CompetitionParticipantDescriptor(
                    profileID: ownerID,
                    role: .creator,
                    state: .accepted,
                    profile: try CompetitionProfilePresentation(
                        id: ownerID,
                        displayName: "Beta Alice"
                    )
                ),
                try CompetitionParticipantDescriptor(
                    profileID: opponentID,
                    role: .invitee,
                    state: .anonymized,
                    profile: try CompetitionProfilePresentation(
                        id: opponentID,
                        displayName: "Former competitor"
                    )
                ),
            ]
        )

        let participantPresentation = remoteCompetitionParticipantPresentation(
            descriptor: descriptor,
            profile: profile
        )

        XCTAssertEqual(participantPresentation.ownerName, "Beta Alice")
        XCTAssertEqual(
            participantPresentation.opponentName,
            "Former competitor"
        )
        XCTAssertEqual(participantPresentation.opponentID, opponentID)
        XCTAssertEqual(
            competitionResultTitle(
                outcome: .loss,
                opponentDisplayName: participantPresentation.opponentName
            ),
            "Former competitor Won"
        )
    }

    func testProfileSwitchAndStopTerminateTheirPriorCanonicalStreams()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let secondProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000002"
            )!,
            displayName: "Beta Bob"
        )
        let firstPaths = AuthenticatedProfileStoragePaths(
            profileID: firstProfile.id,
            rootDirectory: root.appendingPathComponent(
                "first",
                isDirectory: true
            )
        )
        let secondPaths = AuthenticatedProfileStoragePaths(
            profileID: secondProfile.id,
            rootDirectory: root.appendingPathComponent(
                "second",
                isDirectory: true
            )
        )
        for directory in firstPaths.fixedDirectories
            + secondPaths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let probe = RemoteCompetitionClientProbe()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: {
                await probe.recordList()
                return []
            }),
            environment: try environment()
        )

        try await client.mountAuthenticatedProfile(firstProfile, firstPaths)
        var firstIterator = client.start().makeAsyncIterator()
        let firstPublication = await firstIterator.next()
        XCTAssertEqual(firstPublication?.publicationRevision, 1)

        try await client.prepareForProfileTeardown(
            requireRemoteInstallationRemoval: false
        )
        await client.stop()
        try await client.mountAuthenticatedProfile(secondProfile, secondPaths)
        let terminalPublication = await firstIterator.next()
        XCTAssertEqual(terminalPublication?.publicationRevision, 2)
        let firstStreamTermination = await firstIterator.next()
        XCTAssertNil(firstStreamTermination)

        var secondIterator = client.start().makeAsyncIterator()
        let secondPublication = await secondIterator.next()
        XCTAssertEqual(secondPublication?.publicationRevision, 1)

        await client.stop()
        let secondStreamTermination = await secondIterator.next()
        XCTAssertNil(secondStreamTermination)
        let listCount = await probe.listCount()
        XCTAssertEqual(listCount, 3)
    }

    func testStartAfterStopCannotRestartUntilAProfileIsMountedAgain()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let startDay = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 13,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let initialDate = try calendar.startOfDay(startDay)
        let signalDate = initialDate.addingTimeInterval(60)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: initialDate,
                    monotonic: MonotonicInstant(
                        epochID: "task13-stop",
                        nanoseconds: 1
                    )
                ),
                timeZoneIdentifier: calendar.timeZoneIdentifier,
                initialDays: try calendar.sevenDayWindow(
                    startingOn: startDay
                ).map { .missing(day: $0) },
                changes: [
                    try FixtureActivityChange(
                        at: signalDate,
                        updates: [],
                        triggers: [.observerWakeupBackground]
                    ),
                ]
            )
        )
        let probe = RemoteCompetitionClientProbe()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: {
                await probe.recordList()
                return []
            }),
            environment: .accelerated(source: source)
        )
        try await client.mountAuthenticatedProfile(profile, paths)
        await client.stop()

        var stoppedIterator = client.start().makeAsyncIterator()
        let stoppedPublication = await stoppedIterator.next()
        XCTAssertNil(stoppedPublication)
        try await Task.sleep(nanoseconds: 50_000_000)
        let stoppedSubscriberCount = await source.signalSubscriberCount()
        try await source.advance(to: signalDate)
        try await Task.sleep(nanoseconds: 50_000_000)
        let stoppedListCount = await probe.listCount()
        let stoppedCompletionCount = await source.signalCompletionCount(
            "fixture-signal-1"
        )
        XCTAssertEqual(stoppedListCount, 0)
        XCTAssertEqual(stoppedSubscriberCount, 0)
        XCTAssertEqual(stoppedCompletionCount, 0)

        try await client.mountAuthenticatedProfile(profile, paths)
        var remountedIterator = client.start().makeAsyncIterator()
        let remountedPublication = await remountedIterator.next()
        let remountedListCount = await probe.listCount()
        XCTAssertEqual(remountedPublication?.publicationRevision, 1)
        XCTAssertEqual(remountedListCount, 1)
        await client.stop()
    }

    func testBackgroundObserverCompletionWaitsForDurableReceipt()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000021"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let startDay = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 13,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let initialDate = try calendar.startOfDay(startDay)
        let signalDate = initialDate.addingTimeInterval(60)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: initialDate,
                    monotonic: MonotonicInstant(
                        epochID: "remote-durable-background-receipt",
                        nanoseconds: 1
                    )
                ),
                timeZoneIdentifier: calendar.timeZoneIdentifier,
                initialDays: try calendar.sevenDayWindow(
                    startingOn: startDay
                ).map { .missing(day: $0) },
                changes: [
                    try FixtureActivityChange(
                        at: signalDate,
                        updates: [],
                        triggers: [.observerWakeupBackground]
                    ),
                ]
            )
        )
        let receiptStarted = expectation(
            description: "background receipt commit started"
        )
        let receiptGate = RemoteObserverDeliveryReceiptGate()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: source),
            observerDeliveryReceiptFactory: { _ in
                HealthKitObserverDeliveryReceiptClient { receipt in
                    await receiptGate.record(receipt)
                    receiptStarted.fulfill()
                    await receiptGate.waitForRelease()
                }
            }
        )

        try await client.mountAuthenticatedProfile(profile, paths)
        var iterator = client.start().makeAsyncIterator()
        _ = await iterator.next()
        let subscriberCount = await source.signalSubscriberCount()
        XCTAssertEqual(subscriberCount, 1)

        try await source.advance(to: signalDate)
        await fulfillment(of: [receiptStarted], timeout: 1)
        let completionCountBeforeReceipt = await source
            .signalCompletionCount("fixture-signal-1")
        XCTAssertEqual(completionCountBeforeReceipt, 0)

        await receiptGate.release()
        await waitForBoundedAsyncCondition("receipt completion") {
            await source.waitUntilSignalCompletionCount(
                "fixture-signal-1",
                minimum: 1
            )
        }
        let receiptCount = await receiptGate.receiptCount()
        let finalCompletionCount = await source
            .signalCompletionCount("fixture-signal-1")
        XCTAssertEqual(receiptCount, 1)
        XCTAssertEqual(finalCompletionCount, 1)
        await client.stop()
    }

    func testBackgroundObserverReceiptFailureRetriesBeforeCompletion()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000022",
            epochID: "remote-background-receipt-retry"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let receiptProbe = RemoteObserverDeliveryReceiptRetryProbe()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source),
            observerDeliveryReceiptFactory: { _ in
                HealthKitObserverDeliveryReceiptClient { receipt in
                    try await receiptProbe.commitFailingFirst(receipt)
                }
            }
        )
        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        var iterator = client.start().makeAsyncIterator()
        _ = await iterator.next()

        try await fixture.source.advance(to: fixture.signalDate)
        await waitForBoundedAsyncCondition("first receipt attempt") {
            await receiptProbe.waitUntilAttemptCount(1)
        }
        let completionAfterFailure = await fixture.source
            .signalCompletionCount("fixture-signal-1")
        XCTAssertEqual(completionAfterFailure, 0)

        _ = await client.reconcileAll(.foreground)

        let receipts = await receiptProbe.attemptedReceipts()
        let completionAfterRetry = await fixture.source
            .signalCompletionCount("fixture-signal-1")
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(receipts.first, receipts.last)
        XCTAssertEqual(
            receipts.map(\.trigger),
            [.observerWakeupBackground, .observerWakeupBackground]
        )
        XCTAssertEqual(completionAfterRetry, 1)
        await client.stop()
    }

    func testForegroundObserverCompletionWaitsForDurableReceiptAndPreservesTrigger()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000058",
            epochID: "remote-durable-foreground-receipt",
            trigger: .observerWakeupForeground
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let receiptStarted = expectation(
            description: "foreground observer receipt commit started"
        )
        let receiptGate = RemoteObserverDeliveryReceiptGate()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source),
            observerDeliveryReceiptFactory: { _ in
                HealthKitObserverDeliveryReceiptClient { receipt in
                    await receiptGate.record(receipt)
                    receiptStarted.fulfill()
                    await receiptGate.waitForRelease()
                }
            }
        )
        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        var iterator = client.start().makeAsyncIterator()
        _ = await iterator.next()

        try await fixture.source.advance(to: fixture.signalDate)
        await fulfillment(of: [receiptStarted], timeout: 1)
        let receiptsBeforeCommit = await receiptGate.recordedReceipts()
        let completionBeforeCommit = await fixture.source
            .signalCompletionCount("fixture-signal-1")
        XCTAssertEqual(
            receiptsBeforeCommit.map(\.trigger),
            [.observerWakeupForeground]
        )
        XCTAssertEqual(completionBeforeCommit, 0)

        await receiptGate.release()
        await waitForBoundedAsyncCondition("foreground receipt completion") {
            await fixture.source.waitUntilSignalCompletionCount(
                "fixture-signal-1",
                minimum: 1
            )
        }
        let completionAfterCommit = await fixture.source
            .signalCompletionCount("fixture-signal-1")
        XCTAssertEqual(completionAfterCommit, 1)
        await client.stop()
    }

    func testForegroundObserverReceiptFailureRetriesBeforeCompletionAndPreservesTrigger()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000059",
            epochID: "remote-foreground-receipt-retry",
            trigger: .observerWakeupForeground
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let receiptProbe = RemoteObserverDeliveryReceiptRetryProbe()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source),
            observerDeliveryReceiptFactory: { _ in
                HealthKitObserverDeliveryReceiptClient { receipt in
                    try await receiptProbe.commitFailingFirst(receipt)
                }
            }
        )
        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        var iterator = client.start().makeAsyncIterator()
        _ = await iterator.next()

        try await fixture.source.advance(to: fixture.signalDate)
        await waitForBoundedAsyncCondition("first foreground receipt attempt") {
            await receiptProbe.waitUntilAttemptCount(1)
        }
        let firstAttempts = await receiptProbe.attemptedReceipts()
        let completionAfterFailure = await fixture.source
            .signalCompletionCount("fixture-signal-1")
        XCTAssertEqual(
            firstAttempts.map(\.trigger),
            [.observerWakeupForeground]
        )
        XCTAssertEqual(completionAfterFailure, 0)

        _ = await client.reconcileAll(.foreground)

        let attempts = await receiptProbe.attemptedReceipts()
        let completionAfterRetry = await fixture.source
            .signalCompletionCount("fixture-signal-1")
        XCTAssertEqual(
            attempts.map(\.trigger),
            [.observerWakeupForeground, .observerWakeupForeground]
        )
        XCTAssertEqual(completionAfterRetry, 1)
        await client.stop()
    }

    func testStopLeavesCommittedCallbackPendingAndRemountCompletesReplay()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000023",
            epochID: "remote-background-receipt-remount",
            replaysPendingCompletionSignals: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cancellationObserved = expectation(
            description: "pending receipt commit observed cancellation"
        )
        let receiptStore = RemoteObserverDeliveryReceiptPersistenceGate {
            cancellationObserved.fulfill()
        }
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source),
            observerDeliveryReceiptFactory: { _ in
                HealthKitObserverDeliveryReceiptClient(
                    contains: { signalID in
                        await receiptStore.contains(signalID)
                    },
                    commit: { receipt in
                        await receiptStore.commitUntilCancelled(receipt)
                    }
                )
            }
        )
        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        var firstIterator = client.start().makeAsyncIterator()
        _ = await firstIterator.next()
        try await fixture.source.advance(to: fixture.signalDate)
        await waitForBoundedAsyncCondition("interrupted receipt commit") {
            await receiptStore.waitUntilCommitCount(1)
        }

        let stopTask = Task { await client.stop() }
        await fulfillment(of: [cancellationObserved], timeout: 1)
        await stopTask.value

        let completionAfterStop = await fixture.source
            .signalCompletionCount("fixture-signal-1")
        let receiptWasStored = await receiptStore.isStored(
            "fixture-signal-1"
        )
        XCTAssertEqual(completionAfterStop, 0)
        XCTAssertTrue(receiptWasStored)

        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        var secondIterator = client.start().makeAsyncIterator()
        _ = await secondIterator.next()
        await waitForBoundedAsyncCondition("receipt replay lookup") {
            await receiptStore.waitUntilContainsCount(2)
        }
        await waitForBoundedAsyncCondition("remount completion") {
            await fixture.source.waitUntilSignalCompletionCount(
                "fixture-signal-1",
                minimum: 1
            )
        }

        let finalCompletionCount = await fixture.source
            .signalCompletionCount("fixture-signal-1")
        let commitCount = await receiptStore.commitCount()
        XCTAssertEqual(finalCompletionCount, 1)
        XCTAssertEqual(commitCount, 1)
        await client.stop()
    }

    func testTerminalTeardownCancelsBlockedReceiptBeforeJoiningGate()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000048",
            epochID: "remote-background-terminal-blocked-receipt",
            replaysPendingCompletionSignals: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cancellationObserved = expectation(
            description: "terminal teardown cancelled receipt persistence"
        )
        let cancellationFlag = RemoteLockedFlag()
        let receiptStore = RemoteObserverDeliveryReceiptPersistenceGate {
            cancellationFlag.setTrue()
            cancellationObserved.fulfill()
        }
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source),
            observerDeliveryReceiptFactory: { _ in
                HealthKitObserverDeliveryReceiptClient(
                    contains: { signalID in
                        await receiptStore.contains(signalID)
                    },
                    commit: { receipt in
                        await receiptStore.commitUntilCancelled(receipt)
                    }
                )
            }
        )
        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        var iterator = client.start().makeAsyncIterator()
        _ = await iterator.next()
        try await fixture.source.advance(to: fixture.signalDate)
        await waitForBoundedAsyncCondition("blocked terminal receipt") {
            await receiptStore.waitUntilCommitCount(1)
        }

        let teardownTask = Task {
            try await client.prepareForProfileTeardown(
                requireRemoteInstallationRemoval: false
            )
        }
        await fulfillment(of: [cancellationObserved], timeout: 1)
        if !cancellationFlag.value {
            // Rescue the RED path so a regression fails promptly rather than
            // leaving an unbounded XCTest process behind.
            await client.stop()
        }
        try await teardownTask.value

        let receiptWasStored = await receiptStore.isStored(
            "fixture-signal-1"
        )
        let completionCount = await fixture.source.signalCompletionCount(
            "fixture-signal-1"
        )
        XCTAssertTrue(receiptWasStored)
        XCTAssertEqual(completionCount, 1)
        await client.stop()
    }

    func testTerminalTeardownDrainsNoSubscriberCallbackBeforeStorageDeletion()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000031",
            epochID: "remote-background-terminal-drain",
            replaysPendingCompletionSignals: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let replacementProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000032"
            )!,
            displayName: "Beta Bob"
        )
        let replacementPaths = AuthenticatedProfileStoragePaths(
            profileID: replacementProfile.id,
            rootDirectory: fixture.root.appendingPathComponent(
                "replacement-profile",
                isDirectory: true
            )
        )
        for directory in replacementPaths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let receiptProbe = RemoteProfileBoundObserverReceiptProbe(
            blockedProfileID: nil
        )
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source),
            observerDeliveryReceiptFactory: { paths in
                HealthKitObserverDeliveryReceiptClient(
                    contains: { signalID in
                        await receiptProbe.contains(
                            profileID: paths.profileID,
                            signalID: signalID
                        )
                    },
                    commit: { receipt in
                        await receiptProbe.commit(
                            profileID: paths.profileID,
                            receipt: receipt
                        )
                    }
                )
            }
        )
        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        await waitForBoundedAsyncCondition("no origin signal subscriber") {
            await fixture.source.waitUntilSignalSubscriberCount(0)
        }
        let originSubscriberCountBeforeTeardown = await fixture.source
            .signalSubscriberCount()
        XCTAssertEqual(originSubscriberCountBeforeTeardown, 0)
        try await fixture.source.advance(to: fixture.signalDate)

        try await client.prepareForProfileTeardown(
            requireRemoteInstallationRemoval: false
        )

        let completionCount = await fixture.source
            .signalCompletionCount("fixture-signal-1")
        let completionAttemptCount = await fixture.source
            .signalCompletionAttemptCount("fixture-signal-1")
        let commitCount = await receiptProbe.commitCount(
            profileID: fixture.profile.id
        )
        let containsCount = await receiptProbe.containsCount(
            profileID: fixture.profile.id
        )
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(completionAttemptCount, 1)
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(containsCount, 1)
        let originSubscriberCountAfterTeardown = await fixture.source
            .signalSubscriberCount()
        let signalProductionIsQuiesced = await fixture.source
            .signalProductionIsCurrentlyQuiesced()
        XCTAssertEqual(originSubscriberCountAfterTeardown, 0)
        XCTAssertTrue(signalProductionIsQuiesced)
        await client.stop()
        try FileManager.default.removeItem(at: fixture.paths.rootDirectory)

        try await client.mountAuthenticatedProfile(
            replacementProfile,
            replacementPaths
        )
        var replacementIterator = client.start().makeAsyncIterator()
        let replacementInitialState = await replacementIterator.next()
        XCTAssertNotNil(replacementInitialState)
        await waitForBoundedAsyncCondition("replacement subscription") {
            await fixture.source.waitUntilSignalSubscriptionCount(1)
        }
        try await fixture.source.advance(to: fixture.barrierDate)
        await waitForBoundedAsyncCondition("replacement barrier receipt") {
            await receiptProbe.waitUntilCommitted(
                signalID: "fixture-signal-2",
                profileID: replacementProfile.id
            )
        }
        await waitForBoundedAsyncCondition("replacement barrier completion") {
            await fixture.source.waitUntilSignalCompletionCount(
                "fixture-signal-2",
                minimum: 1
            )
        }
        let finalOriginContainsCount = await receiptProbe.containsCount(
            profileID: fixture.profile.id
        )
        let finalOriginCommitCount = await receiptProbe.commitCount(
            profileID: fixture.profile.id
        )
        let finalOriginCompletionCount = await fixture.source
            .signalCompletionCount("fixture-signal-1")
        let finalOriginCompletionAttempts = await fixture.source
            .signalCompletionAttemptCount("fixture-signal-1")
        let replacementContainsIDs = await receiptProbe.containedSignalIDs(
            profileID: replacementProfile.id
        )
        let replacementCommitIDs = await receiptProbe.committedSignalIDs(
            profileID: replacementProfile.id
        )
        XCTAssertEqual(finalOriginContainsCount, containsCount)
        XCTAssertEqual(finalOriginCommitCount, commitCount)
        XCTAssertEqual(finalOriginCompletionCount, completionCount)
        XCTAssertEqual(
            finalOriginCompletionAttempts,
            completionAttemptCount
        )
        XCTAssertEqual(replacementContainsIDs, ["fixture-signal-2"])
        XCTAssertEqual(replacementCommitIDs, ["fixture-signal-2"])
        let replacementCompletionCount = await fixture.source
            .signalCompletionCount("fixture-signal-2")
        XCTAssertEqual(replacementCompletionCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.rootDirectory.path
            )
        )
        await client.stop()
    }

    func testDifferentProfileCannotMountBeforeOriginOwnershipRetires()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000033",
            epochID: "remote-background-owner-activation-guard"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let replacementProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000034"
            )!,
            displayName: "Beta Bob"
        )
        let replacementPaths = AuthenticatedProfileStoragePaths(
            profileID: replacementProfile.id,
            rootDirectory: fixture.root.appendingPathComponent(
                "replacement-profile",
                isDirectory: true
            )
        )
        for directory in replacementPaths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source)
        )
        let sentinel = fixture.paths.rootDirectory.appendingPathComponent(
            "ordinary-stop-sentinel"
        )
        try Data("origin-retained".utf8).write(to: sentinel)
        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        await client.stop()

        do {
            try await client.mountAuthenticatedProfile(
                replacementProfile,
                replacementPaths
            )
            XCTFail("replacement profile mounted before origin retirement")
        } catch let error as EnvironmentSignalOwnershipError {
            XCTAssertEqual(error, .activeOwnerNotRetired)
        } catch {
            XCTFail("unexpected replacement mount error: \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))

        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        await client.stop()
    }

    func testCancelledBootstrapMountCannotResurrectProfileAfterStop()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000041",
            epochID: "remote-cancelled-bootstrap-mount"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let replacementProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000042"
            )!,
            displayName: "Beta Bob"
        )
        let replacementPaths = AuthenticatedProfileStoragePaths(
            profileID: replacementProfile.id,
            rootDirectory: fixture.root.appendingPathComponent(
                "replacement-profile",
                isDirectory: true
            )
        )
        for directory in replacementPaths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let sentinel = fixture.paths.rootDirectory.appendingPathComponent(
            "bootstrap-sentinel"
        )
        try Data("origin-retained".utf8).write(to: sentinel)
        let registration = RemoteBlockingCompetitionPushProbe()
        let lifecycleInvalidated = expectation(
            description: "stop invalidated bootstrap mount lease"
        )
        lifecycleInvalidated.assertForOverFulfill = false
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source),
            pushRegistrationClient: registration.client,
            installationEnvironment: .sandbox,
            lifecycleInvalidationObserver: {
                lifecycleInvalidated.fulfill()
            }
        )

        let mountTask = Task {
            try await client.mountAuthenticatedProfile(
                fixture.profile,
                fixture.paths
            )
        }
        await waitForBoundedAsyncCondition("bootstrap register entered") {
            await registration.waitUntilRegisterStarts()
        }
        mountTask.cancel()
        let stopTask = Task { await client.stop() }
        await fulfillment(of: [lifecycleInvalidated], timeout: 1)
        await registration.releaseRegister()

        do {
            try await mountTask.value
            XCTFail("cancelled bootstrap mount unexpectedly succeeded")
        } catch is CancellationError {
            // The invalidated mount lease must win over late bootstrap work.
        } catch {
            XCTFail("unexpected cancelled mount error: \(error)")
        }
        await stopTask.value

        var stoppedIterator = client.start().makeAsyncIterator()
        let stoppedInitialState = await stoppedIterator.next()
        XCTAssertNil(stoppedInitialState)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))

        try await client.mountAuthenticatedProfile(
            replacementProfile,
            replacementPaths
        )
        var replacementIterator = client.start().makeAsyncIterator()
        let replacementInitialState = await replacementIterator.next()
        XCTAssertNotNil(replacementInitialState)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        await client.stop()
    }

    func testCancelledCommittedSameProfileRemountRemainsTerminallyRetirable()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000049",
            epochID: "remote-cancelled-committed-same-profile-remount"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let replacementProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000050"
            )!,
            displayName: "Beta Bob"
        )
        let replacementPaths = AuthenticatedProfileStoragePaths(
            profileID: replacementProfile.id,
            rootDirectory: fixture.root.appendingPathComponent(
                "cancelled-commit-replacement",
                isDirectory: true
            )
        )
        for directory in replacementPaths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let lifecycleInvalidated = expectation(
            description: "stop invalidated committed remount lease"
        )
        lifecycleInvalidated.assertForOverFulfill = false
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source),
            lifecycleInvalidationObserver: {
                lifecycleInvalidated.fulfill()
            }
        )
        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        await fixture.source.blockNextSignalOwnershipCommit()

        let remountTask = Task {
            try await client.mountAuthenticatedProfile(
                fixture.profile,
                fixture.paths
            )
        }
        await waitForBoundedAsyncCondition("committed remount blocked") {
            await fixture.source.waitUntilSignalOwnershipCommitIsBlocked()
        }
        let stopTask = Task { await client.stop() }
        await fulfillment(of: [lifecycleInvalidated], timeout: 1)
        await fixture.source.releaseBlockedSignalOwnershipCommit()

        do {
            try await remountTask.value
            XCTFail("invalidated committed remount unexpectedly succeeded")
        } catch is CancellationError {
            // The committed source lease must remain terminally recoverable.
        } catch {
            XCTFail("unexpected committed remount error: \(error)")
        }
        await stopTask.value
        try await client.prepareForProfileTeardown(
            requireRemoteInstallationRemoval: false
        )
        await client.stop()

        try await client.mountAuthenticatedProfile(
            replacementProfile,
            replacementPaths
        )
        await client.stop()
    }

    func testFailedInitialMountReleasesNewOwnershipReservation() async throws {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000037",
            epochID: "remote-background-failed-new-activation"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(
            at: fixture.paths.installationsDirectory
        )
        try Data("not-a-directory".utf8).write(
            to: fixture.paths.installationsDirectory
        )
        let failedClient = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source),
            appAttestServiceFactory: {
                RemoteCompetitionAppAttestServiceProbe()
            }
        )

        do {
            try await failedClient.mountAuthenticatedProfile(
                fixture.profile,
                fixture.paths
            )
            XCTFail("mount unexpectedly succeeded with invalid storage")
        } catch let error as CompetitionInstallationStateStoreFailure {
            XCTAssertEqual(error, .invalidDirectory)
        } catch {
            XCTFail("unexpected post-activation storage error: \(error)")
        }

        let replacementProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000038"
            )!,
            displayName: "Beta Bob"
        )
        let replacementPaths = AuthenticatedProfileStoragePaths(
            profileID: replacementProfile.id,
            rootDirectory: fixture.root.appendingPathComponent(
                "replacement-profile",
                isDirectory: true
            )
        )
        for directory in replacementPaths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let replacementClient = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source)
        )

        try await replacementClient.mountAuthenticatedProfile(
            replacementProfile,
            replacementPaths
        )
        await replacementClient.stop()
    }

    func testFailedReplacementMountPreservesReusedOwnershipReservation()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000039",
            epochID: "remote-background-failed-reused-activation"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ownerClient = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source)
        )
        try await ownerClient.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        await ownerClient.stop()

        try FileManager.default.removeItem(
            at: fixture.paths.installationsDirectory
        )
        try Data("not-a-directory".utf8).write(
            to: fixture.paths.installationsDirectory
        )
        let failedReplacement = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source),
            appAttestServiceFactory: {
                RemoteCompetitionAppAttestServiceProbe()
            }
        )
        do {
            try await failedReplacement.mountAuthenticatedProfile(
                fixture.profile,
                fixture.paths
            )
            XCTFail("replacement mount unexpectedly succeeded")
        } catch let error as CompetitionInstallationStateStoreFailure {
            XCTAssertEqual(error, .invalidDirectory)
        } catch {
            XCTFail("unexpected replacement storage error: \(error)")
        }

        let otherProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000040"
            )!,
            displayName: "Beta Bob"
        )
        let otherPaths = AuthenticatedProfileStoragePaths(
            profileID: otherProfile.id,
            rootDirectory: fixture.root.appendingPathComponent(
                "other-profile",
                isDirectory: true
            )
        )
        for directory in otherPaths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let otherClient = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source)
        )
        do {
            try await otherClient.mountAuthenticatedProfile(
                otherProfile,
                otherPaths
            )
            XCTFail("failed replacement released a reused reservation")
        } catch let error as EnvironmentSignalOwnershipError {
            XCTAssertEqual(error, .activeOwnerNotRetired)
        } catch {
            XCTFail("unexpected other-profile mount error: \(error)")
        }

        try FileManager.default.removeItem(
            at: fixture.paths.installationsDirectory
        )
        try FileManager.default.createDirectory(
            at: fixture.paths.installationsDirectory,
            withIntermediateDirectories: true
        )
        try await ownerClient.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        try await ownerClient.prepareForProfileTeardown(
            requireRemoteInstallationRemoval: false
        )
        await ownerClient.stop()
    }

    func testFailedSameProfileRemountCanTerminallyRetireOriginOwnership()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000043",
            epochID: "remote-background-failed-remount-terminal-retirement"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originSentinel = fixture.paths.rootDirectory.appendingPathComponent(
            "failed-remount-origin-sentinel"
        )
        try Data("origin-retained".utf8).write(to: originSentinel)
        let originClient = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source)
        )
        try await originClient.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        await originClient.stop()

        try FileManager.default.removeItem(
            at: fixture.paths.installationsDirectory
        )
        try Data("not-a-directory".utf8).write(
            to: fixture.paths.installationsDirectory
        )
        let failedRemount = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source),
            appAttestServiceFactory: {
                RemoteCompetitionAppAttestServiceProbe()
            }
        )
        do {
            try await failedRemount.mountAuthenticatedProfile(
                fixture.profile,
                fixture.paths
            )
            XCTFail("same-profile remount unexpectedly succeeded")
        } catch let error as CompetitionInstallationStateStoreFailure {
            XCTAssertEqual(error, .invalidDirectory)
        } catch {
            XCTFail("unexpected same-profile remount error: \(error)")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: originSentinel.path)
        )

        try FileManager.default.removeItem(
            at: fixture.paths.installationsDirectory
        )
        try FileManager.default.createDirectory(
            at: fixture.paths.installationsDirectory,
            withIntermediateDirectories: true
        )
        try await failedRemount.prepareForProfileTeardown(
            requireRemoteInstallationRemoval: false
        )
        await failedRemount.stop()
        try FileManager.default.removeItem(at: fixture.paths.rootDirectory)

        let replacementProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000044"
            )!,
            displayName: "Beta Bob"
        )
        let replacementPaths = AuthenticatedProfileStoragePaths(
            profileID: replacementProfile.id,
            rootDirectory: fixture.root.appendingPathComponent(
                "replacement-profile",
                isDirectory: true
            )
        )
        for directory in replacementPaths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let replacementClient = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source)
        )
        do {
            try await replacementClient.mountAuthenticatedProfile(
                replacementProfile,
                replacementPaths
            )
        } catch {
            XCTFail(
                "replacement remained blocked after terminal retirement: "
                    + "\(error)"
            )
            return
        }
        await replacementClient.stop()
    }

    func testTerminalReceiptFailureKeepsCallbackRetryableAndBlocksReplacement()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000035",
            epochID: "remote-background-terminal-receipt-retry",
            replaysPendingCompletionSignals: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let receiptProbe = RemoteObserverDeliveryReceiptRetryProbe()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source),
            observerDeliveryReceiptFactory: { _ in
                HealthKitObserverDeliveryReceiptClient { receipt in
                    try await receiptProbe.commitFailingFirst(receipt)
                }
            }
        )
        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        try await fixture.source.advance(to: fixture.signalDate)

        do {
            try await client.prepareForProfileTeardown(
                requireRemoteInstallationRemoval: false
            )
            XCTFail("terminal teardown succeeded without a durable receipt")
        } catch {
            // The source callback and mounted receipt client remain retryable.
        }
        let completionAfterFailure = await fixture.source
            .signalCompletionCount("fixture-signal-1")
        let attemptsAfterFailure = await receiptProbe.attemptedReceipts()
        XCTAssertEqual(completionAfterFailure, 0)
        XCTAssertEqual(attemptsAfterFailure.count, 1)

        let replacementProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000047"
            )!,
            displayName: "Beta Bob"
        )
        let replacementPaths = AuthenticatedProfileStoragePaths(
            profileID: replacementProfile.id,
            rootDirectory: fixture.root.appendingPathComponent(
                "terminal-receipt-replacement",
                isDirectory: true
            )
        )
        for directory in replacementPaths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let replacementClient = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source)
        )
        do {
            try await replacementClient.mountAuthenticatedProfile(
                replacementProfile,
                replacementPaths
            )
            XCTFail("replacement mounted before terminal receipt retry")
        } catch let error as EnvironmentSignalOwnershipError {
            XCTAssertEqual(error, .activeOwnerNotRetired)
        } catch {
            XCTFail("unexpected replacement mount error: \(error)")
        }

        try await client.prepareForProfileTeardown(
            requireRemoteInstallationRemoval: false
        )
        let receipts = await receiptProbe.attemptedReceipts()
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(receipts.first, receipts.last)
        let completionAfterRetry = await fixture.source
            .signalCompletionCount("fixture-signal-1")
        XCTAssertEqual(completionAfterRetry, 1)
        await client.stop()
        try await replacementClient.mountAuthenticatedProfile(
            replacementProfile,
            replacementPaths
        )
        await replacementClient.stop()
    }

    func testConcurrentAndPostSuccessTerminalPreparationIsIdempotent()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000037",
            epochID: "remote-background-terminal-idempotent",
            replaysPendingCompletionSignals: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let receiptProbe = RemoteProfileBoundObserverReceiptProbe(
            blockedProfileID: fixture.profile.id
        )
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source),
            observerDeliveryReceiptFactory: { paths in
                HealthKitObserverDeliveryReceiptClient(
                    contains: { signalID in
                        await receiptProbe.contains(
                            profileID: paths.profileID,
                            signalID: signalID
                        )
                    },
                    commit: { receipt in
                        await receiptProbe.commit(
                            profileID: paths.profileID,
                            receipt: receipt
                        )
                    }
                )
            }
        )

        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        try await fixture.source.advance(to: fixture.signalDate)
        let firstPrepare = Task {
            try await client.prepareForProfileTeardown(
                requireRemoteInstallationRemoval: false
            )
        }
        await waitForBoundedAsyncCondition("first prepare receipt commit") {
            await receiptProbe.waitUntilCommitCount(
                1,
                profileID: fixture.profile.id
            )
        }

        let concurrentPrepareStarted = expectation(
            description: "concurrent prepare started"
        )
        let concurrentPrepare = Task {
            concurrentPrepareStarted.fulfill()
            try await client.prepareForProfileTeardown(
                requireRemoteInstallationRemoval: false
            )
        }
        await fulfillment(of: [concurrentPrepareStarted], timeout: 1)
        await receiptProbe.releaseBlockedCommit()
        try await firstPrepare.value
        try await concurrentPrepare.value

        try await client.prepareForProfileTeardown(
            requireRemoteInstallationRemoval: false
        )
        let containsCount = await receiptProbe.containsCount(
            profileID: fixture.profile.id
        )
        let commitCount = await receiptProbe.commitCount(
            profileID: fixture.profile.id
        )
        let completionCount = await fixture.source
            .signalCompletionCount("fixture-signal-1")
        let completionAttemptCount = await fixture.source
            .signalCompletionAttemptCount("fixture-signal-1")
        XCTAssertEqual(containsCount, 1)
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(completionAttemptCount, 1)
        await client.stop()
    }

    func testTerminalTeardownBlocksQueuedRemoteCommands() async throws {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000036",
            epochID: "remote-background-terminal-command-gate",
            replaysPendingCompletionSignals: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let token = Data(repeating: 0x42, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let competitionID = UUID(
            uuidString: "82000000-0000-4000-8000-000000000036"
        )!
        let invite = try CompetitionInvite(
            competitionID: competitionID,
            token: token
        )
        let claim = try CompetitionInviteClaim(competitionID: competitionID)
        let commandProbe = RemoteCompetitionClientCommandProbe()
        var api = remoteAPI(
            listCompetitions: {
                await commandProbe.recordList()
                return []
            },
            createInvite: { request in
                await commandProbe.recordCreate(request)
                return invite
            },
            claimInvite: { request in
                await commandProbe.recordClaim(request)
                return claim
            }
        )
        api.archiveCompetition = { id in
            await commandProbe.recordArchive(id)
        }
        let receiptProbe = RemoteProfileBoundObserverReceiptProbe(
            blockedProfileID: fixture.profile.id
        )
        let client = CompetitionClient.remote(
            remoteAPI: api,
            environment: .accelerated(source: fixture.source),
            observerDeliveryReceiptFactory: { paths in
                HealthKitObserverDeliveryReceiptClient(
                    contains: { signalID in
                        await receiptProbe.contains(
                            profileID: paths.profileID,
                            signalID: signalID
                        )
                    },
                    commit: { receipt in
                        await receiptProbe.commit(
                            profileID: paths.profileID,
                            receipt: receipt
                        )
                    }
                )
            }
        )
        let createRequest = try CompetitionInviteCreationRequest(
            timeZoneIdentifier: "America/Los_Angeles",
            rematchParentID: nil,
            idempotencyKey: UUID(
                uuidString: "83000000-0000-4000-8000-000000000036"
            )!
        )
        let claimRequest = try CompetitionInviteClaimRequest(token: token)

        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        try await fixture.source.advance(to: fixture.signalDate)
        let prepareTask = Task {
            try await client.prepareForProfileTeardown(
                requireRemoteInstallationRemoval: false
            )
        }
        await waitForBoundedAsyncCondition("blocked terminal receipt") {
            await receiptProbe.waitUntilCommitCount(
                1,
                profileID: fixture.profile.id
            )
        }

        let commandsStarted = expectation(
            description: "terminal commands queued"
        )
        commandsStarted.expectedFulfillmentCount = 4
        let reconcileTask = Task {
            commandsStarted.fulfill()
            return await client.reconcileAll(.pullToRefresh)
        }
        let archiveTask = Task {
            commandsStarted.fulfill()
            return await client.archive(CompetitionID(competitionID))
        }
        let createTask = Task {
            commandsStarted.fulfill()
            do {
                _ = try await client.createInvite(createRequest)
                return false
            } catch let error as EnvironmentSignalOwnershipError {
                return error == .activeOwnerNotRetired
            } catch {
                return false
            }
        }
        let claimTask = Task {
            commandsStarted.fulfill()
            do {
                _ = try await client.claimInvite(claimRequest)
                return false
            } catch let error as EnvironmentSignalOwnershipError {
                return error == .activeOwnerNotRetired
            } catch {
                return false
            }
        }
        await fulfillment(of: [commandsStarted], timeout: 1)
        await receiptProbe.releaseBlockedCommit()
        try await prepareTask.value

        let reconcilePublication = await reconcileTask.value
        let archivePublication = await archiveTask.value
        let createWasBlocked = await createTask.value
        let claimWasBlocked = await claimTask.value
        let listCount = await commandProbe.listCount()
        let createRequests = await commandProbe.createRequests()
        let claimRequests = await commandProbe.claimRequests()
        let archiveRequests = await commandProbe.archiveRequests()
        XCTAssertEqual(
            reconcilePublication.publicationRevision,
            archivePublication.publicationRevision
        )
        XCTAssertTrue(createWasBlocked)
        XCTAssertTrue(claimWasBlocked)
        XCTAssertEqual(listCount, 1)
        XCTAssertEqual(createRequests, [])
        XCTAssertEqual(claimRequests, [])
        XCTAssertEqual(archiveRequests, [])
        await client.stop()
    }

    func testCancelledQueuedCreateInviteDoesNotExecuteRemoteWrite()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000045",
            epochID: "remote-cancelled-command-gate"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = RemoteNotificationOperationGate()
        let commandProbe = RemoteCompetitionClientCommandProbe()
        let token = Data(repeating: 0x45, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let invite = try CompetitionInvite(
            competitionID: UUID(),
            token: token
        )
        let request = try CompetitionInviteCreationRequest(
            timeZoneIdentifier: "America/Los_Angeles",
            rematchParentID: nil,
            idempotencyKey: UUID()
        )
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(
                listCompetitions: {
                    await gate.enterAndWait()
                    await commandProbe.recordList()
                    return []
                },
                createInvite: { request in
                    await commandProbe.recordCreate(request)
                    return invite
                }
            ),
            environment: .accelerated(source: fixture.source)
        )
        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        let holdingOperation = Task {
            await client.reconcileAll(.pullToRefresh)
        }
        await gate.waitUntilEntered()

        let cancelledCreate = Task {
            try await client.createInvite(request)
        }
        for _ in 0..<20 { await Task.yield() }
        cancelledCreate.cancel()
        await gate.release()
        _ = await holdingOperation.value

        do {
            _ = try await cancelledCreate.value
            XCTFail("cancelled queued invite executed its remote write")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let createRequests = await commandProbe.createRequests()
        XCTAssertEqual(createRequests, [])
        await client.stop()
    }

    func testCancelledQueuedArchiveDoesNotExecuteRemoteWrite() async throws {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000046",
            epochID: "remote-cancelled-archive-gate"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = RemoteNotificationOperationGate()
        let commandProbe = RemoteCompetitionClientCommandProbe()
        let competitionID = CompetitionID(UUID())
        var api = remoteAPI(listCompetitions: {
            await gate.enterAndWait()
            await commandProbe.recordList()
            return []
        })
        api.archiveCompetition = { id in
            await commandProbe.recordArchive(id)
        }
        let client = CompetitionClient.remote(
            remoteAPI: api,
            environment: .accelerated(source: fixture.source)
        )
        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        let holdingOperation = Task {
            await client.reconcileAll(.pullToRefresh)
        }
        await gate.waitUntilEntered()

        let cancelledArchive = Task {
            await client.archive(competitionID)
        }
        for _ in 0..<20 { await Task.yield() }
        cancelledArchive.cancel()
        await gate.release()
        _ = await holdingOperation.value
        _ = await cancelledArchive.value

        let archiveRequests = await commandProbe.archiveRequests()
        XCTAssertEqual(archiveRequests, [])
        await client.stop()
    }

    func testPendingBackgroundCallbackStaysBoundToOriginProfile()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000024",
            epochID: "remote-background-receipt-profile-switch",
            replaysPendingCompletionSignals: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let replacementProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000025"
            )!,
            displayName: "Beta Bob"
        )
        let replacementPaths = AuthenticatedProfileStoragePaths(
            profileID: replacementProfile.id,
            rootDirectory: fixture.root.appendingPathComponent(
                "replacement-profile",
                isDirectory: true
            )
        )
        for directory in replacementPaths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let receiptProbe = RemoteProfileBoundObserverReceiptProbe(
            blockedProfileID: fixture.profile.id
        )
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source),
            observerDeliveryReceiptFactory: { paths in
                HealthKitObserverDeliveryReceiptClient(
                    contains: { signalID in
                        await receiptProbe.contains(
                            profileID: paths.profileID,
                            signalID: signalID
                        )
                    },
                    commit: { receipt in
                        await receiptProbe.commit(
                            profileID: paths.profileID,
                            receipt: receipt
                        )
                    }
                )
            }
        )

        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        var originIterator = client.start().makeAsyncIterator()
        _ = await originIterator.next()
        await waitForBoundedAsyncCondition("origin signal subscription") {
            await fixture.source.waitUntilSignalSubscriptionCount(1)
        }
        try await fixture.source.advance(to: fixture.signalDate)
        await waitForBoundedAsyncCondition("origin receipt commit") {
            await receiptProbe.waitUntilCommitCount(
                1,
                profileID: fixture.profile.id
            )
        }

        await client.stop()
        do {
            try await client.mountAuthenticatedProfile(
                replacementProfile,
                replacementPaths
            )
            XCTFail("replacement mounted before origin callback retirement")
        } catch let error as EnvironmentSignalOwnershipError {
            XCTAssertEqual(error, .activeOwnerNotRetired)
        } catch {
            XCTFail("unexpected replacement mount error: \(error)")
        }

        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        var recoveredIterator = client.start().makeAsyncIterator()
        _ = await recoveredIterator.next()
        await waitForBoundedAsyncCondition("recovered origin subscription") {
            await fixture.source.waitUntilSignalSubscriptionCount(2)
        }
        await waitForBoundedAsyncCondition("recovered origin completion") {
            await fixture.source.waitUntilSignalCompletionCount(
                "fixture-signal-1",
                minimum: 1
            )
        }

        let originContainsCount = await receiptProbe.containsCount(
            profileID: fixture.profile.id
        )
        let originCommitCount = await receiptProbe.commitCount(
            profileID: fixture.profile.id
        )
        let completionAfterOriginRemount = await fixture.source
            .signalCompletionCount("fixture-signal-1")
        let completionAttemptsAfterOriginRemount = await fixture.source
            .signalCompletionAttemptCount("fixture-signal-1")
        XCTAssertEqual(originContainsCount, 2)
        XCTAssertEqual(originCommitCount, 1)
        XCTAssertEqual(completionAfterOriginRemount, 1)
        XCTAssertEqual(completionAttemptsAfterOriginRemount, 1)

        try await client.prepareForProfileTeardown(
            requireRemoteInstallationRemoval: false
        )
        await client.stop()

        try await client.mountAuthenticatedProfile(
            replacementProfile,
            replacementPaths
        )
        var replacementIterator = client.start().makeAsyncIterator()
        _ = await replacementIterator.next()
        await waitForBoundedAsyncCondition("replacement subscription") {
            await fixture.source.waitUntilSignalSubscriptionCount(3)
        }
        try await fixture.source.advance(to: fixture.barrierDate)
        await waitForBoundedAsyncCondition("replacement barrier commit") {
            await receiptProbe.waitUntilCommitted(
                signalID: "fixture-signal-2",
                profileID: replacementProfile.id
            )
        }
        await waitForBoundedAsyncCondition("replacement barrier completion") {
            await fixture.source.waitUntilSignalCompletionCount(
                "fixture-signal-2",
                minimum: 1
            )
        }
        let replacementContainsSignalIDs = await receiptProbe
            .containedSignalIDs(profileID: replacementProfile.id)
        let replacementCommitSignalIDs = await receiptProbe
            .committedSignalIDs(profileID: replacementProfile.id)
        XCTAssertEqual(replacementContainsSignalIDs, ["fixture-signal-2"])
        XCTAssertEqual(replacementCommitSignalIDs, ["fixture-signal-2"])
        await client.stop()
    }

    func testBackgroundCallbackEmittedAfterStopRetainsPriorProfileOwner()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000026",
            epochID: "remote-background-no-subscriber-profile-switch",
            replaysPendingCompletionSignals: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let replacementProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000027"
            )!,
            displayName: "Beta Bob"
        )
        let replacementPaths = AuthenticatedProfileStoragePaths(
            profileID: replacementProfile.id,
            rootDirectory: fixture.root.appendingPathComponent(
                "replacement-profile",
                isDirectory: true
            )
        )
        for directory in replacementPaths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let receiptProbe = RemoteProfileBoundObserverReceiptProbe(
            blockedProfileID: nil
        )
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: { [] }),
            environment: .accelerated(source: fixture.source),
            observerDeliveryReceiptFactory: { paths in
                HealthKitObserverDeliveryReceiptClient(
                    contains: { signalID in
                        await receiptProbe.contains(
                            profileID: paths.profileID,
                            signalID: signalID
                        )
                    },
                    commit: { receipt in
                        await receiptProbe.commit(
                            profileID: paths.profileID,
                            receipt: receipt
                        )
                    }
                )
            }
        )

        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        var originIterator = client.start().makeAsyncIterator()
        _ = await originIterator.next()
        await waitForBoundedAsyncCondition("origin signal subscription") {
            await fixture.source.waitUntilSignalSubscriptionCount(1)
        }
        await client.stop()
        try FileManager.default.removeItem(at: fixture.paths.rootDirectory)
        await waitForBoundedAsyncCondition("zero signal subscribers") {
            await fixture.source.waitUntilSignalSubscriberCount(0)
        }
        let subscriberCountBeforeGapSignal = await fixture.source
            .signalSubscriberCount()
        XCTAssertEqual(subscriberCountBeforeGapSignal, 0)

        try await fixture.source.advance(to: fixture.signalDate)
        do {
            try await client.mountAuthenticatedProfile(
                replacementProfile,
                replacementPaths
            )
            XCTFail("replacement mounted before origin callback recovery")
        } catch let error as EnvironmentSignalOwnershipError {
            XCTAssertEqual(error, .activeOwnerNotRetired)
        } catch {
            XCTFail("unexpected replacement mount error: \(error)")
        }

        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        var recoveredIterator = client.start().makeAsyncIterator()
        _ = await recoveredIterator.next()
        await waitForBoundedAsyncCondition("recovered origin receipt") {
            await receiptProbe.waitUntilCommitted(
                signalID: "fixture-signal-1",
                profileID: fixture.profile.id
            )
        }
        await waitForBoundedAsyncCondition("recovered origin completion") {
            await fixture.source.waitUntilSignalCompletionCount(
                "fixture-signal-1",
                minimum: 1
            )
        }

        let originContainsCount = await receiptProbe.containsCount(
            profileID: fixture.profile.id
        )
        let originCommitCount = await receiptProbe.commitCount(
            profileID: fixture.profile.id
        )
        let completionAfterOriginRemount = await fixture.source
            .signalCompletionCount("fixture-signal-1")
        let completionAttemptsAfterOriginRemount = await fixture.source
            .signalCompletionAttemptCount("fixture-signal-1")
        XCTAssertEqual(originContainsCount, 1)
        XCTAssertEqual(originCommitCount, 1)
        XCTAssertEqual(completionAfterOriginRemount, 1)
        XCTAssertEqual(completionAttemptsAfterOriginRemount, 1)

        try await client.prepareForProfileTeardown(
            requireRemoteInstallationRemoval: false
        )
        await client.stop()

        try await client.mountAuthenticatedProfile(
            replacementProfile,
            replacementPaths
        )
        var replacementIterator = client.start().makeAsyncIterator()
        _ = await replacementIterator.next()
        await waitForBoundedAsyncCondition("replacement subscription") {
            await fixture.source.waitUntilSignalSubscriptionCount(3)
        }
        try await fixture.source.advance(to: fixture.barrierDate)
        await waitForBoundedAsyncCondition("replacement barrier commit") {
            await receiptProbe.waitUntilCommitted(
                signalID: "fixture-signal-2",
                profileID: replacementProfile.id
            )
        }
        await waitForBoundedAsyncCondition("replacement barrier completion") {
            await fixture.source.waitUntilSignalCompletionCount(
                "fixture-signal-2",
                minimum: 1
            )
        }
        let replacementContainsSignalIDs = await receiptProbe
            .containedSignalIDs(profileID: replacementProfile.id)
        let replacementCommitSignalIDs = await receiptProbe
            .committedSignalIDs(profileID: replacementProfile.id)
        XCTAssertEqual(replacementContainsSignalIDs, ["fixture-signal-2"])
        XCTAssertEqual(replacementCommitSignalIDs, ["fixture-signal-2"])
        await client.stop()
    }

    func testReplacementClientRecoversSameProfileBackgroundCallback()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000028",
            epochID: "remote-background-client-replacement",
            replaysPendingCompletionSignals: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let receiptProbe = RemoteProfileBoundObserverReceiptProbe(
            blockedProfileID: fixture.profile.id
        )
        let makeClient = {
            CompetitionClient.remote(
                remoteAPI: self.remoteAPI(listCompetitions: { [] }),
                environment: .accelerated(source: fixture.source),
                observerDeliveryReceiptFactory: { paths in
                    HealthKitObserverDeliveryReceiptClient(
                        contains: { signalID in
                            await receiptProbe.contains(
                                profileID: paths.profileID,
                                signalID: signalID
                            )
                        },
                        commit: { receipt in
                            await receiptProbe.commit(
                                profileID: paths.profileID,
                                receipt: receipt
                            )
                        }
                    )
                }
            )
        }

        do {
            let originClient = makeClient()
            try await originClient.mountAuthenticatedProfile(
                fixture.profile,
                fixture.paths
            )
            var originIterator = originClient.start().makeAsyncIterator()
            _ = await originIterator.next()
            await waitForBoundedAsyncCondition("origin subscription") {
                await fixture.source.waitUntilSignalSubscriptionCount(1)
            }
            try await fixture.source.advance(to: fixture.signalDate)
            await waitForBoundedAsyncCondition("origin receipt commit") {
                await receiptProbe.waitUntilCommitCount(
                    1,
                    profileID: fixture.profile.id
                )
            }
            await originClient.stop()
        }

        let replacementClient = makeClient()
        try await replacementClient.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        var replacementIterator = replacementClient.start()
            .makeAsyncIterator()
        _ = await replacementIterator.next()
        await waitForBoundedAsyncCondition("replacement subscription") {
            await fixture.source.waitUntilSignalSubscriptionCount(2)
        }
        try await fixture.source.advance(to: fixture.barrierDate)
        await waitForBoundedAsyncCondition("replacement barrier completion") {
            await fixture.source.waitUntilSignalCompletionCount(
                "fixture-signal-2",
                minimum: 1
            )
        }

        let originCompletionCount = await fixture.source
            .signalCompletionCount("fixture-signal-1")
        XCTAssertEqual(originCompletionCount, 1)
        await replacementClient.stop()
    }

    func testQueuedOriginSummarySignalCannotReconcileReplacementProfile()
        async throws
    {
        let fixture = try makeObserverSignalFixture(
            profileID: "81000000-0000-4000-8000-000000000029",
            epochID: "remote-summary-profile-switch"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let replacementProfile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000030"
            )!,
            displayName: "Beta Bob"
        )
        let replacementPaths = AuthenticatedProfileStoragePaths(
            profileID: replacementProfile.id,
            rootDirectory: fixture.root.appendingPathComponent(
                "replacement-profile",
                isDirectory: true
            )
        )
        for directory in replacementPaths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let listProbe = RemoteCompetitionClientProbe()
        let receiptProbe = RemoteProfileBoundObserverReceiptProbe(
            blockedProfileID: nil
        )
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: {
                await listProbe.recordList()
                return []
            }),
            environment: .accelerated(source: fixture.source),
            observerDeliveryReceiptFactory: { paths in
                HealthKitObserverDeliveryReceiptClient(
                    contains: { signalID in
                        await receiptProbe.contains(
                            profileID: paths.profileID,
                            signalID: signalID
                        )
                    },
                    commit: { receipt in
                        await receiptProbe.commit(
                            profileID: paths.profileID,
                            receipt: receipt
                        )
                    }
                )
            }
        )

        try await client.mountAuthenticatedProfile(
            fixture.profile,
            fixture.paths
        )
        var originIterator = client.start().makeAsyncIterator()
        _ = await originIterator.next()
        await waitForBoundedAsyncCondition("origin signal subscription") {
            await fixture.source.waitUntilSignalSubscriptionCount(1)
        }
        let originActivation = try await fixture.source.activateSignalOwnership(
            for: fixture.profile.id
        )
        let originScope = originActivation.scope
        try await client.prepareForProfileTeardown(
            requireRemoteInstallationRemoval: false
        )
        await client.stop()

        try await client.mountAuthenticatedProfile(
            replacementProfile,
            replacementPaths
        )
        var replacementIterator = client.start().makeAsyncIterator()
        _ = await replacementIterator.next()
        await waitForBoundedAsyncCondition("replacement subscription") {
            await fixture.source.waitUntilSignalSubscriptionCount(2)
        }
        let replacementActivation = try await fixture.source
            .activateSignalOwnership(
            for: replacementProfile.id
        )
        let replacementScope = replacementActivation.scope
        await fixture.source.emitSignal(
            .summaryUpdate,
            ownershipScope: originScope
        )
        await fixture.source.emitSignal(
            .observerWakeupBackground,
            ownershipScope: replacementScope
        )
        await waitForBoundedAsyncCondition("replacement barrier commit") {
            await receiptProbe.waitUntilCommitted(
                signalID: "fixture-signal-2",
                profileID: replacementProfile.id
            )
        }
        await waitForBoundedAsyncCondition("replacement barrier completion") {
            await fixture.source.waitUntilSignalCompletionCount(
                "fixture-signal-2",
                minimum: 1
            )
        }

        let replacementContainsSignalIDs = await receiptProbe
            .containedSignalIDs(profileID: replacementProfile.id)
        let replacementCommitSignalIDs = await receiptProbe
            .committedSignalIDs(profileID: replacementProfile.id)
        let listCount = await listProbe.listCount()
        let originCompletionAttempts = await fixture.source
            .signalCompletionAttemptCount("fixture-signal-1")
        XCTAssertEqual(listCount, 4)
        XCTAssertEqual(replacementContainsSignalIDs, ["fixture-signal-2"])
        XCTAssertEqual(replacementCommitSignalIDs, ["fixture-signal-2"])
        XCTAssertEqual(originCompletionAttempts, 0)
        await client.stop()
    }

    func testConcurrentReconciliationsUseOneSerializedCanonicalOperation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let probe = SerializedRemoteCompetitionListProbe()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: {
                await probe.listCompetitions()
            }),
            environment: try environment()
        )
        try await client.mountAuthenticatedProfile(profile, paths)

        let first = Task {
            await client.reconcileAll(.pullToRefresh)
        }
        await probe.waitUntilFirstCallEntered()
        let second = Task {
            await client.reconcileAll(.foreground)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let maximumBeforeRelease = await probe.maximumConcurrentCalls()
        await probe.releaseFirstCall()
        let firstPublication = await first.value
        let secondPublication = await second.value
        let maximumAfterRelease = await probe.maximumConcurrentCalls()

        XCTAssertEqual(maximumBeforeRelease, 1)
        XCTAssertEqual(maximumAfterRelease, 1)
        XCTAssertEqual(
            Set([
                firstPublication.publicationRevision,
                secondPublication.publicationRevision,
            ]),
            Set([1, 2])
        )
        await client.stop()
    }

    func testRelaunchOfflinePublishesProfileScopedDurableCache()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let competitionID = UUID(
            uuidString: "82000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let expiresAt = createdAt.addingTimeInterval(48 * 60 * 60)
        let descriptor = try pendingDescriptor(
            competitionID: competitionID,
            profile: profile,
            expiresAt: expiresAt
        )
        let page = try pendingHistoryPage(
            descriptor: descriptor,
            profileID: profile.id,
            createdAt: createdAt
        )
        let online = CompetitionClient.remote(
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { _, _ in page }
            ),
            environment: try environment()
        )

        try await online.mountAuthenticatedProfile(profile, paths)
        var onlineIterator = online.start().makeAsyncIterator()
        let nextOnlinePublication = await awaitNext(&onlineIterator)
        let onlinePublication = try XCTUnwrap(nextOnlinePublication)
        XCTAssertEqual(
            onlinePublication.dashboard.competitions.map(\.id),
            [CompetitionID(competitionID)]
        )
        XCTAssertEqual(onlinePublication.dashboard.issues, [])
        await online.stop()

        let offline = CompetitionClient.remote(
            remoteAPI: remoteAPI(listCompetitions: {
                throw CompetitionRemoteFailure.operationFailed
            }),
            environment: try environment()
        )
        try await offline.mountAuthenticatedProfile(profile, paths)
        var offlineIterator = offline.start().makeAsyncIterator()
        let nextOfflinePublication = await awaitNext(&offlineIterator)
        let offlinePublication = try XCTUnwrap(nextOfflinePublication)

        XCTAssertEqual(
            offlinePublication.dashboard.competitions.map(\.id),
            [CompetitionID(competitionID)]
        )
        XCTAssertEqual(
            offlinePublication.dashboard.issues,
            [.remoteUnavailable]
        )
        await offline.stop()
    }

    func testDiscoveryFailureIssueKeepsRemoteAndStorageFailuresDistinct() {
        XCTAssertNil(
            RemoteCompetitionRuntimeFailure.cancelled.competitionClientIssue
        )
        XCTAssertEqual(
            RemoteCompetitionRuntimeFailure.discoveryUnavailable
                .competitionClientIssue,
            .remoteUnavailable
        )
        XCTAssertEqual(
            RemoteCompetitionRuntimeFailure.storageUnavailable
                .competitionClientIssue,
            .storageUnavailable
        )
        let nonRetryableFailures: [RemoteCompetitionRuntimeFailure] = [
            .unauthenticated,
            .forbidden,
            .profileMismatch,
            .competitionNotMaterialized,
            .serverContractMismatch,
            .cursorRetryLimitExceeded,
        ]
        XCTAssertEqual(
            nonRetryableFailures.map(\.competitionClientIssue),
            Array(repeating: .remoteFailure, count: nonRetryableFailures.count)
        )
    }

    func testRemoteDiscoveryIssueHasTruthfulRetryingMessage() {
        XCTAssertEqual(
            competitionIssueSummary([.remoteUnavailable]),
            "Unable to connect. HealthComp will keep trying."
        )
        XCTAssertEqual(
            competitionIssueSummary([.storageUnavailable]),
            "Local competition storage is unavailable."
        )
        XCTAssertEqual(
            competitionIssueSummary([.remoteFailure]),
            "Competition data could not be refreshed."
        )
        XCTAssertEqual(
            competitionIssueSummary([
                .remoteUnavailable,
                .authorizationUnavailable,
            ]),
            "Activity authorization is unavailable."
        )
    }

    func testRemotePublicationSchedulesThroughRuntimeNeutralCoordinator()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let competitionID = UUID(
            uuidString: "82000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let descriptor = try pendingDescriptor(
            competitionID: competitionID,
            profile: profile,
            expiresAt: createdAt.addingTimeInterval(48 * 60 * 60)
        )
        let page = try pendingHistoryPage(
            descriptor: descriptor,
            profileID: profile.id,
            createdAt: createdAt
        )
        let notifications = RemoteCompetitionNotificationProbe()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { _, _ in page }
            ),
            environment: try environment(),
            notificationClient: notifications.client,
            notificationPreferencesFactory: { _ in
                .constant(mutedOpponentIdentities: [])
            }
        )

        try await client.mountAuthenticatedProfile(profile, paths)
        var iterator = client.start().makeAsyncIterator()
        _ = await iterator.next()
        let request = await notifications.firstUpsert()

        XCTAssertEqual(
            request.identifier,
            CompetitionNotificationIdentifier.scheduled(
                competitionID: CompetitionID(competitionID),
                family: .inviteExpiry
            )
        )
        XCTAssertEqual(request.route, .competition(CompetitionID(competitionID)))
        await client.stop()
    }

    func testStopCancelsPriorNotificationAfterTransientReconciliationFailure()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let competitionID = UUID(
            uuidString: "82000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let descriptor = try pendingDescriptor(
            competitionID: competitionID,
            profile: profile,
            expiresAt: createdAt.addingTimeInterval(48 * 60 * 60)
        )
        let page = try pendingHistoryPage(
            descriptor: descriptor,
            profileID: profile.id,
            createdAt: createdAt
        )
        let fetches = RemoteCompetitionFetchSequenceProbe(page: page)
        let notifications = RemoteCompetitionNotificationProbe()
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { _, _ in try await fetches.fetch() }
            ),
            environment: try environment(),
            notificationClient: notifications.client,
            notificationPreferencesFactory: { _ in
                .constant(mutedOpponentIdentities: [])
            }
        )

        try await client.mountAuthenticatedProfile(profile, paths)
        var iterator = client.start().makeAsyncIterator()
        _ = await iterator.next()
        let scheduled = await notifications.firstUpsert()
        let initiallyPending = await notifications.pendingIdentifiers()
        XCTAssertEqual(initiallyPending, [scheduled.identifier])
        await fetches.failSubsequentFetches()

        let failed = await client.reconcileAll(.pullToRefresh)
        XCTAssertEqual(
            failed.dashboard.issues,
            [.competitionFailures([CompetitionID(competitionID)])]
        )
        await client.stop()

        let remaining = await notifications.pendingIdentifiers()
        XCTAssertEqual(remaining, [], "Profile teardown must cancel prior work")
    }

    func testRelaunchResumesFromDurableServerCursor()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let competitionID = UUID(
            uuidString: "82000000-0000-4000-8000-000000000001"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let descriptor = try pendingDescriptor(
            competitionID: competitionID,
            profile: profile,
            expiresAt: createdAt.addingTimeInterval(48 * 60 * 60)
        )
        let bootstrapPage = try pendingHistoryPage(
            descriptor: descriptor,
            profileID: profile.id,
            createdAt: createdAt
        )
        let first = CompetitionClient.remote(
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { _, _ in bootstrapPage }
            ),
            environment: try environment()
        )
        try await first.mountAuthenticatedProfile(profile, paths)
        var firstIterator = first.start().makeAsyncIterator()
        let firstPublication = await awaitNext(&firstIterator)
        XCTAssertEqual(firstPublication?.dashboard.competitions.count, 1)
        await first.stop()

        let probe = RemoteCompetitionCursorProbe()
        let incrementalPage = try CompetitionChangePage(
            competitionID: competitionID,
            afterServerSequence: 1,
            snapshotServerSequence: 1,
            nextServerSequence: 1,
            hasMore: false,
            changes: []
        )
        let relaunched = CompetitionClient.remote(
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { cursor, pageSize in
                    await probe.record(cursor: cursor, pageSize: pageSize)
                    return incrementalPage
                }
            ),
            environment: try environment()
        )

        try await relaunched.mountAuthenticatedProfile(profile, paths)
        var relaunchedIterator = relaunched.start().makeAsyncIterator()
        let relaunchedPublication = await awaitNext(&relaunchedIterator)

        XCTAssertEqual(
            relaunchedPublication?.dashboard.competitions.map(\.id),
            [CompetitionID(competitionID)]
        )
        XCTAssertEqual(relaunchedPublication?.dashboard.issues, [])
        let observations = await probe.observations()
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(
            observations.first?.cursor.lastSeenServerSequence,
            1
        )
        XCTAssertEqual(observations.first?.pageSize, 200)
        await relaunched.stop()
    }

    func testActivityReadFailurePublishesMaterializedCompetitionAndIssue()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AuthenticatedProfile(
            id: UUID(
                uuidString: "81000000-0000-4000-8000-000000000001"
            )!,
            displayName: "Beta Bob"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let competitionID = UUID(
            uuidString: "82000000-0000-4000-8000-000000000001"
        )!
        let creatorID = UUID(
            uuidString: "82000000-0000-4000-8000-000000000002"
        )!
        let createdAt = Date(timeIntervalSince1970: 1_786_540_000)
        let descriptor = try scheduledDescriptor(
            competitionID: competitionID,
            creatorID: creatorID,
            inviteeID: profile.id,
            createdAt: createdAt
        )
        let page = try scheduledHistoryPage(
            descriptor: descriptor,
            creatorID: creatorID,
            inviteeID: profile.id,
            createdAt: createdAt
        )
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let startDay = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 13,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let days = try calendar.sevenDayWindow(startingOn: startDay)
        let dayOneNoon = try calendar.startOfDay(startDay)
            .addingTimeInterval(12 * 60 * 60)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: dayOneNoon,
                    monotonic: MonotonicInstant(
                        epochID: "client-activity-read-failure",
                        nanoseconds: 1
                    )
                ),
                timeZoneIdentifier: calendar.timeZoneIdentifier,
                initialDays: days.map { .missing(day: $0) },
                initialReadState: .failure(.healthDataUnavailable),
                changes: []
            )
        )
        let client = CompetitionClient.remote(
            remoteAPI: remoteAPI(
                listCompetitions: { [descriptor] },
                fetchChanges: { _, _ in page }
            ),
            environment: .accelerated(source: source)
        )

        try await client.mountAuthenticatedProfile(profile, paths)
        var iterator = client.start().makeAsyncIterator()
        let publication = await awaitNext(&iterator)

        XCTAssertEqual(
            publication?.dashboard.competitions.map(\.id),
            [CompetitionID(competitionID)]
        )
        XCTAssertEqual(
            publication?.dashboard.issues,
            [.activityFailures([CompetitionID(competitionID)])]
        )
        XCTAssertEqual(
            publication.map { competitionIssueSummary($0.dashboard.issues) },
            "Competition is available, but Activity could not be refreshed."
        )
        XCTAssertEqual(
            competitionIssueSummary([
                .activityFailures([CompetitionID(competitionID)]),
                .competitionFailures([CompetitionID(competitionID)]),
            ]),
            "Some competition activity could not be refreshed."
        )
        await client.stop()
    }

    private func makeObserverSignalFixture(
        profileID: String,
        epochID: String,
        trigger: ActivityRefreshTrigger = .observerWakeupBackground,
        replaysPendingCompletionSignals: Bool = false
    ) throws -> RemoteObserverSignalFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let profile = AuthenticatedProfile(
            id: UUID(uuidString: profileID)!,
            displayName: "Beta Alice"
        )
        let paths = AuthenticatedProfileStoragePaths(
            profileID: profile.id,
            rootDirectory: root.appendingPathComponent(
                "origin-profile",
                isDirectory: true
            )
        )
        for directory in paths.fixedDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let startDay = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 13,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let initialDate = try calendar.startOfDay(startDay)
        let signalDate = initialDate.addingTimeInterval(60)
        let barrierDate = signalDate.addingTimeInterval(60)
        let source = FixtureActivitySource(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: initialDate,
                    monotonic: MonotonicInstant(
                        epochID: epochID,
                        nanoseconds: 1
                    )
                ),
                timeZoneIdentifier: calendar.timeZoneIdentifier,
                initialDays: try calendar.sevenDayWindow(
                    startingOn: startDay
                ).map { .missing(day: $0) },
                changes: [
                    try FixtureActivityChange(
                        at: signalDate,
                        updates: [],
                        triggers: [trigger]
                    ),
                    try FixtureActivityChange(
                        at: barrierDate,
                        updates: [],
                        triggers: [trigger]
                    ),
                ]
            ),
            replaysPendingCompletionSignals:
                replaysPendingCompletionSignals
        )
        return RemoteObserverSignalFixture(
            root: root,
            profile: profile,
            paths: paths,
            source: source,
            signalDate: signalDate,
            barrierDate: barrierDate
        )
    }

    private func environment() throws -> CompetitionEnvironmentClient {
        let calendar = try CompetitionCalendar(
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let start = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 13,
            timeZoneIdentifier: calendar.timeZoneIdentifier
        )
        let days = try calendar.sevenDayWindow(startingOn: start)
        return .accelerated(
            fixture: try ActivityFixture(
                initialInstant: EnvironmentInstant(
                    wallDate: try calendar.startOfDay(start),
                    monotonic: MonotonicInstant(
                        epochID: "task13-remote-client",
                        nanoseconds: 1
                    )
                ),
                timeZoneIdentifier: calendar.timeZoneIdentifier,
                initialDays: days.map { .missing(day: $0) },
                changes: []
            )
        )
    }

    private func pendingDescriptor(
        competitionID: UUID,
        profile: AuthenticatedProfile,
        expiresAt: Date
    ) throws -> CompetitionDescriptor {
        try CompetitionDescriptor(
            competitionID: competitionID,
            creatorProfileID: profile.id,
            timeZoneIdentifier: nil,
            startDay: nil,
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            lifecycle: .pending,
            invitationExpiresAt: expiresAt,
            bestAvailableDeadline: nil,
            rematchParentID: nil,
            nextServerSequence: 2,
            participants: [
                try CompetitionParticipantDescriptor(
                    profileID: profile.id,
                    role: .creator,
                    state: .accepted,
                    profile: try CompetitionProfilePresentation(
                        id: profile.id,
                        displayName: profile.displayName
                    )
                ),
            ]
        )
    }

    private func scheduledDescriptor(
        competitionID: UUID,
        creatorID: UUID,
        inviteeID: UUID,
        createdAt: Date
    ) throws -> CompetitionDescriptor {
        try CompetitionDescriptor(
            competitionID: competitionID,
            creatorProfileID: creatorID,
            timeZoneIdentifier: "America/Los_Angeles",
            startDay: "2026-08-13",
            scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            lifecycle: .scheduled,
            invitationExpiresAt: createdAt.addingTimeInterval(48 * 60 * 60),
            bestAvailableDeadline: Date(
                timeIntervalSince1970: 1_787_299_200
            ),
            rematchParentID: nil,
            nextServerSequence: 4,
            participants: [
                try CompetitionParticipantDescriptor(
                    profileID: creatorID,
                    role: .creator,
                    state: .accepted,
                    profile: try CompetitionProfilePresentation(
                        id: creatorID,
                        displayName: "Beta Alice"
                    )
                ),
                try CompetitionParticipantDescriptor(
                    profileID: inviteeID,
                    role: .invitee,
                    state: .accepted,
                    profile: try CompetitionProfilePresentation(
                        id: inviteeID,
                        displayName: "Beta Bob"
                    )
                ),
            ]
        )
    }

    private func scheduledHistoryPage(
        descriptor: CompetitionDescriptor,
        creatorID: UUID,
        inviteeID: UUID,
        createdAt: Date
    ) throws -> CompetitionChangePage {
        let acceptedAt = createdAt.addingTimeInterval(3_600)
        return try CompetitionChangePage(
            competitionID: descriptor.competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: 3,
            nextServerSequence: 3,
            hasMore: false,
            changes: [
                try CompetitionChange(
                    serverSequence: 1,
                    kind: .participantAdded,
                    entityID: creatorID,
                    occurredAt: createdAt,
                    payload: .participant(
                        try CompetitionParticipantChange(
                            profileID: creatorID,
                            role: .creator,
                            state: .accepted
                        )
                    )
                ),
                try CompetitionChange(
                    serverSequence: 2,
                    kind: .participantAdded,
                    entityID: inviteeID,
                    occurredAt: acceptedAt,
                    payload: .participant(
                        try CompetitionParticipantChange(
                            profileID: inviteeID,
                            role: .invitee,
                            state: .accepted
                        )
                    )
                ),
                try CompetitionChange(
                    serverSequence: 3,
                    kind: .competitionLifecycleChanged,
                    entityID: descriptor.competitionID,
                    occurredAt: acceptedAt,
                    payload: .lifecycle(
                        try CompetitionLifecycleChange(
                            lifecycle: .scheduled,
                            timeZoneIdentifier: descriptor
                                .timeZoneIdentifier,
                            startDay: descriptor.startDay,
                            bestAvailableDeadline: descriptor
                                .bestAvailableDeadline,
                            scoringPolicyIdentity: descriptor
                                .scoringPolicyIdentity
                        )
                    )
                ),
            ]
        )
    }

    private func pendingHistoryPage(
        descriptor: CompetitionDescriptor,
        profileID: UUID,
        createdAt: Date
    ) throws -> CompetitionChangePage {
        try CompetitionChangePage(
            competitionID: descriptor.competitionID,
            afterServerSequence: 0,
            snapshotServerSequence: 1,
            nextServerSequence: 1,
            hasMore: false,
            changes: [
                try CompetitionChange(
                    serverSequence: 1,
                    kind: .participantAdded,
                    entityID: profileID,
                    occurredAt: createdAt,
                    payload: .participant(
                        try CompetitionParticipantChange(
                            profileID: profileID,
                            role: .creator,
                            state: .accepted
                        )
                    )
                ),
            ]
        )
    }

    private func awaitNext(
        _ iterator: inout AsyncStream<CompetitionPublication>.Iterator
    ) async -> CompetitionPublication? {
        await iterator.next()
    }

    private func appAttestScoreRequest(revision: Int64) throws
        -> CompetitionScoreRevisionRequest
    {
        try CompetitionScoreRevisionRequest(
            competitionID: UUID(
                uuidString: "8b000000-0000-4000-8000-000000000001"
            )!,
            semanticEventID: UUID(
                uuidString: String(
                    format: "8c000000-0000-4000-8000-%012lld",
                    revision
                )
            )!,
            dayOrdinal: 1,
            clientRevision: revision,
            evaluatedAt: Date(timeIntervalSince1970: 1_786_536_000),
            moveMode: "activeEnergyKilocalories",
            standMode: "standHours",
            moveBasisPoints: 10_000,
            exerciseBasisPoints: 9_000,
            standBasisPoints: 8_000,
            availabilityReason: "available",
            scoringPolicyIdentity: "healthcomp.activity-score.v1",
            wireContentSHA256: String(repeating: "d", count: 64)
        )
    }

    private func remoteAPI(
        listCompetitions: @escaping @Sendable () async throws ->
            [CompetitionDescriptor],
        createInvite: @escaping @Sendable (
            CompetitionInviteCreationRequest
        ) async throws -> CompetitionInvite = { _ in
            throw CompetitionRemoteFailure.operationFailed
        },
        claimInvite: @escaping @Sendable (
            CompetitionInviteClaimRequest
        ) async throws -> CompetitionInviteClaim = { _ in
            throw CompetitionRemoteFailure.operationFailed
        },
        fetchChanges: @escaping @Sendable (
            CompetitionSynchronizationCursor,
            Int
        ) async throws -> CompetitionChangePage = { _, _ in
            throw CompetitionRemoteFailure.operationFailed
        },
        registerInstallation: @escaping @Sendable (
            CompetitionInstallationRequest
        ) async throws -> CompetitionInstallation = { _ in
            throw CompetitionRemoteFailure.operationFailed
        },
        removeInstallation: @escaping @Sendable (
            UUID
        ) async throws -> CompetitionInstallation = { _ in
            throw CompetitionRemoteFailure.operationFailed
        },
        issueAppAttestChallenge: @escaping @Sendable (
            CompetitionAppAttestChallengeRequest
        ) async throws -> CompetitionAppAttestChallenge = { _ in
            throw CompetitionRemoteFailure.appAttestUnavailable
        },
        submitAttestedScoreRevision: @escaping @Sendable (
            CompetitionAttestedScoreRevisionRequest
        ) async throws -> CompetitionScoreRevisionResponse = { _ in
            throw CompetitionRemoteFailure.appAttestUnavailable
        }
    ) -> CompetitionRemoteAPI {
        CompetitionRemoteAPI(
            bootstrapProfile: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            updateProfile: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            listCompetitions: listCompetitions,
            fetchCompetition: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            createInvite: createInvite,
            claimInvite: claimInvite,
            appendScoreRevision: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            issueAppAttestChallenge: issueAppAttestChallenge,
            submitAttestedScoreRevision: submitAttestedScoreRevision,
            submitAttestation: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            fetchChanges: fetchChanges,
            registerInstallation: registerInstallation,
            removeInstallation: removeInstallation,
            requestAccountDeletion: {
                throw CompetitionRemoteFailure.operationFailed
            }
        )
    }

    private func waitForBoundedAsyncCondition(
        _ description: String,
        operation: @escaping @Sendable () async -> Void
    ) async {
        let completed = expectation(description: description)
        let waiter = Task {
            await operation()
            guard !Task.isCancelled else { return }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)
        waiter.cancel()
        await waiter.value
    }
}

private actor RemoteCompetitionInstallationProbe {
    private var registrations: [CompetitionInstallationRequest] = []
    private var removals: [UUID] = []

    func register(
        _ request: CompetitionInstallationRequest
    ) throws -> CompetitionInstallation {
        registrations.append(request)
        return try CompetitionInstallation(
            installationID: request.installationID,
            environment: request.environment,
            state: .active
        )
    }

    func remove(_ id: UUID) throws -> CompetitionInstallation {
        removals.append(id)
        return try CompetitionInstallation(
            installationID: id,
            environment: .sandbox,
            state: .revoked
        )
    }

    func registrationRequests() -> [CompetitionInstallationRequest] {
        registrations
    }

    func removalIDs() -> [UUID] { removals }
}

private actor RemoteObserverDeliveryReceiptGate {
    private var receipts: [HealthKitObserverDeliveryReceipt] = []
    private var isReleased = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func record(_ receipt: HealthKitObserverDeliveryReceipt) {
        receipts.append(receipt)
    }

    func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func receiptCount() -> Int { receipts.count }

    func recordedReceipts() -> [HealthKitObserverDeliveryReceipt] {
        receipts
    }
}

private struct RemoteObserverSignalFixture {
    let root: URL
    let profile: AuthenticatedProfile
    let paths: AuthenticatedProfileStoragePaths
    let source: FixtureActivitySource
    let signalDate: Date
    let barrierDate: Date
}

private struct RemoteObserverDeliveryInjectedFailure: Error {}

private actor RemoteObserverDeliveryReceiptRetryProbe {
    private struct AttemptWaiter {
        let minimum: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var attempts: [HealthKitObserverDeliveryReceipt] = []
    private var attemptWaiters: [UUID: AttemptWaiter] = [:]

    func commitFailingFirst(
        _ receipt: HealthKitObserverDeliveryReceipt
    ) throws {
        attempts.append(receipt)
        resumeAttemptWaiters()
        if attempts.count == 1 {
            throw RemoteObserverDeliveryInjectedFailure()
        }
    }

    func waitUntilAttemptCount(_ minimum: Int) async {
        guard attempts.count < minimum else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                attemptWaiters[waiterID] = AttemptWaiter(
                    minimum: minimum,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelAttemptWaiter(waiterID) }
        }
    }

    func attemptedReceipts() -> [HealthKitObserverDeliveryReceipt] {
        attempts
    }

    private func resumeAttemptWaiters() {
        let readyIDs = attemptWaiters.compactMap { id, waiter in
            attempts.count >= waiter.minimum ? id : nil
        }
        for id in readyIDs {
            attemptWaiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    private func cancelAttemptWaiter(_ id: UUID) {
        attemptWaiters.removeValue(forKey: id)?.continuation.resume()
    }
}

private final class RemoteLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool { lock.withLock { storedValue } }

    func setTrue() {
        lock.withLock { storedValue = true }
    }
}

private actor RemoteObserverDeliveryReceiptPersistenceGate {
    private struct CountWaiter {
        let minimum: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let onCancellation: @Sendable () -> Void
    private var storedBySignalID: [
        String: HealthKitObserverDeliveryReceipt
    ] = [:]
    private var commits: [HealthKitObserverDeliveryReceipt] = []
    private var containsCalls = 0
    private var commitWaiters: [UUID: CountWaiter] = [:]
    private var containsWaiters: [UUID: CountWaiter] = [:]
    private var commitRelease: CheckedContinuation<Void, Never>?

    init(onCancellation: @escaping @Sendable () -> Void) {
        self.onCancellation = onCancellation
    }

    func contains(_ signalID: String) -> Bool {
        containsCalls += 1
        resumeContainsWaiters()
        return storedBySignalID[signalID] != nil
    }

    func commitUntilCancelled(
        _ receipt: HealthKitObserverDeliveryReceipt
    ) async {
        commits.append(receipt)
        resumeCommitWaiters()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                commitRelease = continuation
            }
        } onCancel: {
            Task { await self.cancelCommit() }
        }
        storedBySignalID[receipt.signalID] = receipt
    }

    private func cancelCommit() {
        onCancellation()
        commitRelease?.resume()
        commitRelease = nil
    }

    func waitUntilCommitCount(_ minimum: Int) async {
        guard commits.count < minimum else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                commitWaiters[waiterID] = CountWaiter(
                    minimum: minimum,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelCommitWaiter(waiterID) }
        }
    }

    func waitUntilContainsCount(_ minimum: Int) async {
        guard containsCalls < minimum else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                containsWaiters[waiterID] = CountWaiter(
                    minimum: minimum,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelContainsWaiter(waiterID) }
        }
    }

    func isStored(_ signalID: String) -> Bool {
        storedBySignalID[signalID] != nil
    }

    func commitCount() -> Int { commits.count }

    private func resumeCommitWaiters() {
        let readyIDs = commitWaiters.compactMap { id, waiter in
            commits.count >= waiter.minimum ? id : nil
        }
        for id in readyIDs {
            commitWaiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    private func resumeContainsWaiters() {
        let readyIDs = containsWaiters.compactMap { id, waiter in
            containsCalls >= waiter.minimum ? id : nil
        }
        for id in readyIDs {
            containsWaiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    private func cancelCommitWaiter(_ id: UUID) {
        commitWaiters.removeValue(forKey: id)?.continuation.resume()
    }

    private func cancelContainsWaiter(_ id: UUID) {
        containsWaiters.removeValue(forKey: id)?.continuation.resume()
    }
}

private actor RemoteProfileBoundObserverReceiptProbe {
    private struct CommitWaiter {
        let profileID: UUID
        let minimum: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct SignalCommitWaiter {
        let profileID: UUID
        let signalID: String
        let continuation: CheckedContinuation<Void, Never>
    }

    private let blockedProfileID: UUID?
    private var storedSignalIDsByProfile: [UUID: Set<String>] = [:]
    private var containsCounts: [UUID: Int] = [:]
    private var commitCounts: [UUID: Int] = [:]
    private var containedSignalIDsByProfile: [UUID: [String]] = [:]
    private var committedSignalIDsByProfile: [UUID: [String]] = [:]
    private var committedReceiptsByProfile: [
        UUID: [HealthKitObserverDeliveryReceipt]
    ] = [:]
    private var commitWaiters: [UUID: CommitWaiter] = [:]
    private var signalCommitWaiters: [UUID: SignalCommitWaiter] = [:]
    private var blockedCommitContinuation: CheckedContinuation<Void, Never>?

    init(blockedProfileID: UUID?) {
        self.blockedProfileID = blockedProfileID
    }

    func contains(profileID: UUID, signalID: String) -> Bool {
        containsCounts[profileID, default: 0] += 1
        containedSignalIDsByProfile[profileID, default: []].append(signalID)
        return storedSignalIDsByProfile[profileID, default: []]
            .contains(signalID)
    }

    func commit(
        profileID: UUID,
        receipt: HealthKitObserverDeliveryReceipt
    ) async {
        commitCounts[profileID, default: 0] += 1
        committedSignalIDsByProfile[profileID, default: []].append(
            receipt.signalID
        )
        committedReceiptsByProfile[profileID, default: []].append(receipt)
        resumeCommitWaiters()
        resumeSignalCommitWaiters()
        if blockedProfileID == profileID,
           commitCounts[profileID] == 1 {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume()
                        return
                    }
                    blockedCommitContinuation = continuation
                }
            } onCancel: {
                Task { await self.releaseBlockedCommit() }
            }
        }
        storedSignalIDsByProfile[profileID, default: []].insert(
            receipt.signalID
        )
    }

    func waitUntilCommitCount(_ minimum: Int, profileID: UUID) async {
        guard commitCounts[profileID, default: 0] < minimum else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                commitWaiters[waiterID] = CommitWaiter(
                    profileID: profileID,
                    minimum: minimum,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelCommitWaiter(waiterID) }
        }
    }

    func waitUntilCommitted(signalID: String, profileID: UUID) async {
        guard !committedSignalIDsByProfile[profileID, default: []]
            .contains(signalID) else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                signalCommitWaiters[waiterID] = SignalCommitWaiter(
                    profileID: profileID,
                    signalID: signalID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelSignalCommitWaiter(waiterID) }
        }
    }

    func containsCount(profileID: UUID) -> Int {
        containsCounts[profileID, default: 0]
    }

    func commitCount(profileID: UUID) -> Int {
        commitCounts[profileID, default: 0]
    }

    func containedSignalIDs(profileID: UUID) -> [String] {
        containedSignalIDsByProfile[profileID, default: []]
    }

    func committedSignalIDs(profileID: UUID) -> [String] {
        committedSignalIDsByProfile[profileID, default: []]
    }

    func committedReceipts(
        profileID: UUID
    ) -> [HealthKitObserverDeliveryReceipt] {
        committedReceiptsByProfile[profileID, default: []]
    }

    func removeStoredProfile(_ profileID: UUID) {
        storedSignalIDsByProfile[profileID] = nil
    }

    func releaseBlockedCommit() {
        blockedCommitContinuation?.resume()
        blockedCommitContinuation = nil
    }

    private func resumeCommitWaiters() {
        let readyIDs = commitWaiters.compactMap { id, waiter in
            commitCounts[waiter.profileID, default: 0] >= waiter.minimum
                ? id
                : nil
        }
        for id in readyIDs {
            commitWaiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    private func resumeSignalCommitWaiters() {
        let readyIDs = signalCommitWaiters.compactMap { id, waiter in
            committedSignalIDsByProfile[waiter.profileID, default: []]
                .contains(waiter.signalID) ? id : nil
        }
        for id in readyIDs {
            signalCommitWaiters.removeValue(forKey: id)?
                .continuation.resume()
        }
    }

    private func cancelCommitWaiter(_ id: UUID) {
        commitWaiters.removeValue(forKey: id)?.continuation.resume()
    }

    private func cancelSignalCommitWaiter(_ id: UUID) {
        signalCommitWaiters.removeValue(forKey: id)?.continuation.resume()
    }
}

private actor RemoteCompetitionAppAttestServiceProbe:
    AppAttestServiceProtocol
{
    private let keyID = Data(repeating: 0x51, count: 32)
        .base64EncodedString()
    private var keyGenerationCount = 0

    func isSupported() -> Bool { true }

    func generateKey() -> String {
        keyGenerationCount += 1
        return keyID
    }

    func attestKey(_ keyID: String, clientDataHash: Data) -> Data {
        Data("attestation".utf8)
    }

    func generateAssertion(
        _ keyID: String,
        clientDataHash: Data
    ) -> Data {
        Data("assertion".utf8)
    }

    func generatedKeyCount() -> Int { keyGenerationCount }
}

private actor RemoteCompetitionAppAttestProbe {
    private var challenges: [CompetitionAppAttestChallengeRequest] = []
    private var submitted: [CompetitionAttestedScoreRevisionRequest] = []

    func issue(
        _ request: CompetitionAppAttestChallengeRequest
    ) throws -> CompetitionAppAttestChallenge {
        challenges.append(request)
        let ordinal = challenges.count
        let challengeID = UUID(
            uuidString: String(
                format: "8d000000-0000-4000-8000-%012d",
                ordinal
            )
        )!
        return try CompetitionAppAttestChallenge(
            challengeID: challengeID,
            challenge: Data(repeating: UInt8(ordinal), count: 32),
            expiresAt: Date().addingTimeInterval(300),
            proofKind: ordinal == 1 ? .attestation : .assertion
        )
    }

    func submit(
        _ request: CompetitionAttestedScoreRevisionRequest
    ) throws -> CompetitionScoreRevisionResponse {
        submitted.append(request)
        return try CompetitionScoreRevisionResponse(
            disposition: .appended,
            rejectionCode: nil,
            acceptedCentiPoints: 27_000,
            wireContentSHA256: request.score.wireContentSHA256,
            acceptedServerSequence: request.score.clientRevision,
            competitionCursor: request.score.clientRevision
        )
    }

    func challengeRequests() -> [CompetitionAppAttestChallengeRequest] {
        challenges
    }

    func submissions() -> [CompetitionAttestedScoreRevisionRequest] {
        submitted
    }
}

private actor RemoteCompetitionPushProbe {
    private let token: String
    private var calls: [String] = []

    init(token: String) {
        self.token = token
    }

    nonisolated var client: CompetitionPushRegistrationClient {
        CompetitionPushRegistrationClient(
            register: { [weak self] in await self?.record("register") },
            unregister: { [weak self] in
                await self?.record("unregister")
            },
            latestToken: { [weak self] in await self?.currentToken() },
            events: {
                AsyncStream<CompetitionPushRegistrationEvent> {
                    $0.finish()
                }
            }
        )
    }

    func recordedCalls() -> [String] { calls }

    private func currentToken() -> String { token }

    private func record(_ call: String) { calls.append(call) }
}

private actor RemoteBlockingCompetitionPushProbe {
    private var registerStarted = false
    private var registerReleased = false
    private var registerStartWaiters: [UUID: CheckedContinuation<Void, Never>] =
        [:]
    private var registerReleaseContinuation: CheckedContinuation<Void, Never>?

    nonisolated var client: CompetitionPushRegistrationClient {
        CompetitionPushRegistrationClient(
            register: { [weak self] in await self?.blockRegister() },
            unregister: {},
            latestToken: { nil },
            events: {
                AsyncStream<CompetitionPushRegistrationEvent> {
                    $0.finish()
                }
            }
        )
    }

    func waitUntilRegisterStarts() async {
        guard !registerStarted else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                registerStartWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelRegisterStartWaiter(waiterID) }
        }
    }

    func releaseRegister() {
        registerReleased = true
        registerReleaseContinuation?.resume()
        registerReleaseContinuation = nil
    }

    private func blockRegister() async {
        registerStarted = true
        let waiters = registerStartWaiters.values
        registerStartWaiters = [:]
        waiters.forEach { $0.resume() }
        guard !registerReleased else { return }
        await withCheckedContinuation { continuation in
            registerReleaseContinuation = continuation
        }
    }

    private func cancelRegisterStartWaiter(_ id: UUID) {
        registerStartWaiters.removeValue(forKey: id)?.resume()
    }
}

private actor RemoteCompetitionNotificationProbe {
    private var upserts: [CompetitionScheduledNotificationRequest] = []
    private var waiters: [
        CheckedContinuation<CompetitionScheduledNotificationRequest, Never>
    ] = []

    nonisolated var client: CompetitionNotificationClient {
        CompetitionNotificationClient(
            requestAuthorization: { true },
            authorizationState: { .authorized },
            upsert: { [weak self] request in
                await self?.record(request)
            },
            postNow: { _ in },
            pendingIDs: { [weak self] prefix in
                await self?.pendingIdentifiers(prefix: prefix) ?? []
            },
            deliveredIDs: { _ in [] },
            removePending: { [weak self] identifiers in
                await self?.removePending(identifiers)
            },
            removeDelivered: { _ in }
        )
    }

    func firstUpsert() async -> CompetitionScheduledNotificationRequest {
        if let first = upserts.first { return first }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func pendingIdentifiers(prefix: String? = nil) -> Set<String> {
        Set(upserts.map(\.identifier)).filter { identifier in
            prefix.map(identifier.hasPrefix) ?? true
        }
    }

    private func removePending(_ identifiers: [String]) {
        let removed = Set(identifiers)
        upserts.removeAll { removed.contains($0.identifier) }
    }

    private func record(_ request: CompetitionScheduledNotificationRequest) {
        upserts.append(request)
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume(returning: request) }
    }
}

private actor RemoteCompetitionFetchSequenceProbe {
    private let page: CompetitionChangePage
    private var shouldFail = false

    init(page: CompetitionChangePage) {
        self.page = page
    }

    func failSubsequentFetches() {
        shouldFail = true
    }

    func fetch() throws -> CompetitionChangePage {
        if shouldFail { throw CompetitionRemoteFailure.operationFailed }
        return page
    }
}

private actor RemoteCompetitionClientCommandProbe {
    private var lists = 0
    private var creates: [CompetitionInviteCreationRequest] = []
    private var claims: [CompetitionInviteClaimRequest] = []
    private var archives: [UUID] = []

    func recordList() {
        lists += 1
    }

    func recordCreate(_ request: CompetitionInviteCreationRequest) {
        creates.append(request)
    }

    func recordClaim(_ request: CompetitionInviteClaimRequest) {
        claims.append(request)
    }

    func recordArchive(_ competitionID: UUID) {
        archives.append(competitionID)
    }

    func listCount() -> Int {
        lists
    }

    func createRequests() -> [CompetitionInviteCreationRequest] {
        creates
    }

    func claimRequests() -> [CompetitionInviteClaimRequest] {
        claims
    }

    func archiveRequests() -> [UUID] {
        archives
    }
}

private actor RemoteCompetitionCursorProbe {
    struct Observation: Equatable, Sendable {
        let cursor: CompetitionSynchronizationCursor
        let pageSize: Int
    }

    private var values: [Observation] = []

    func record(
        cursor: CompetitionSynchronizationCursor,
        pageSize: Int
    ) {
        values.append(Observation(cursor: cursor, pageSize: pageSize))
    }

    func observations() -> [Observation] {
        values
    }
}

private actor RemoteCompetitionClientProbe {
    private var lists = 0

    func recordList() {
        lists += 1
    }

    func listCount() -> Int {
        lists
    }
}

private final class RemoteNotificationOperationOrderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = RemoteNotificationOperationGate()
    private var recordedEvents: [String] = []

    var blockingClient: CompetitionNotificationPreferencesClient {
        CompetitionNotificationPreferencesClient(
            mutedOpponentIdentities: { [self] in
                record("read-start")
                await gate.enterAndWait()
                record("read-end")
                return []
            },
            setMuted: { _, _ in }
        )
    }

    func record(_ event: String) {
        lock.withLock { recordedEvents.append(event) }
    }

    func events() -> [String] {
        lock.withLock { recordedEvents }
    }

    func waitUntilReadStarts() async {
        await gate.waitUntilEntered()
    }

    func releaseRead() async {
        await gate.release()
    }
}

private actor RemoteNotificationOperationGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waitingForEntry = entryWaiters
        entryWaiters.removeAll()
        waitingForEntry.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor RemoteNotificationAuthorizationProbe {
    private let gate = RemoteNotificationOperationGate()

    nonisolated var client: CompetitionNotificationClient {
        CompetitionNotificationClient(
            requestAuthorization: { [weak self] in
                guard let self else { return false }
                await self.request()
                return true
            },
            authorizationState: { .authorized },
            upsert: { _ in },
            postNow: { _ in },
            pendingIDs: { _ in [] },
            deliveredIDs: { _ in [] },
            removePending: { _ in },
            removeDelivered: { _ in }
        )
    }

    func waitUntilRequestStarts() async {
        await gate.waitUntilEntered()
    }

    func releaseRequest() async {
        await gate.release()
    }

    private func request() async {
        await gate.enterAndWait()
    }
}

private actor SerializedRemoteCompetitionListProbe {
    private var activeCalls = 0
    private var maximumActiveCalls = 0
    private var totalCalls = 0
    private var firstEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?

    func listCompetitions() async -> [CompetitionDescriptor] {
        totalCalls += 1
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        if totalCalls == 1 {
            let waiters = firstEntryWaiters
            firstEntryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstReleaseContinuation = continuation
            }
        }
        activeCalls -= 1
        return []
    }

    func waitUntilFirstCallEntered() async {
        guard totalCalls == 0 else { return }
        await withCheckedContinuation { continuation in
            firstEntryWaiters.append(continuation)
        }
    }

    func releaseFirstCall() {
        firstReleaseContinuation?.resume()
        firstReleaseContinuation = nil
    }

    func maximumConcurrentCalls() -> Int {
        maximumActiveCalls
    }
}

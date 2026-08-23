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

    func testAuthorizationPromptDoesNotBlockProfileRemount()
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
            try await client.mountAuthenticatedProfile(
                secondProfile,
                secondPaths
            )
        }

        await fulfillment(of: [secondMount], timeout: 1)
        await authorization.releaseRequest()
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

    func testHealthAuthorizationPromptDoesNotBlockOrPublishAcrossProfileRemount()
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
            if await firstIterator.next() == nil {
                firstStreamFinished.fulfill()
            }
        }
        await source.waitUntilAuthorizationRequestIsBlocked()
        let mountTask = Task {
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
        XCTAssertEqual(listCount, 2)
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

        try await client.mountAuthenticatedProfile(secondProfile, secondPaths)
        let firstStreamTermination = await firstIterator.next()
        XCTAssertNil(firstStreamTermination)

        var secondIterator = client.start().makeAsyncIterator()
        let secondPublication = await secondIterator.next()
        XCTAssertEqual(secondPublication?.publicationRevision, 1)

        await client.stop()
        let secondStreamTermination = await secondIterator.next()
        XCTAssertNil(secondStreamTermination)
        let listCount = await probe.listCount()
        XCTAssertEqual(listCount, 2)
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

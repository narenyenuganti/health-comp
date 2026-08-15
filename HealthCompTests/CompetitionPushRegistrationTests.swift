import Foundation
import UIKit
import XCTest
@testable import HealthComp

final class CompetitionPushRegistrationTests: XCTestCase {
    func testDebugBundleUsesSandboxAPNsEnvironment() throws {
        XCTAssertEqual(
            try CompetitionInstallationEnvironment.configured(bundle: .main),
            .sandbox
        )
    }

    @MainActor
    func testAppDelegateForwardsAPNsRegistrationCallbacksInMemory() {
        let hub = CompetitionPushRegistrationHub()
        let delegate = HealthCompAppDelegate(pushRegistrationHub: hub)
        let tokenData = Data(repeating: 0x7a, count: 32)

        delegate.application(
            UIApplication.shared,
            didRegisterForRemoteNotificationsWithDeviceToken: tokenData
        )
        XCTAssertEqual(
            hub.latestToken(),
            String(repeating: "7a", count: 32)
        )

        delegate.application(
            UIApplication.shared,
            didFailToRegisterForRemoteNotificationsWithError: NSError(
                domain: "CompetitionPushRegistrationTests",
                code: 1
            )
        )
        XCTAssertNil(hub.latestToken())
    }

    func testHubReplaysLatestTokenInMemoryAndClearsIt() async {
        let hub = CompetitionPushRegistrationHub()
        let tokenData = Data(repeating: 0xab, count: 32)
        let token = String(repeating: "ab", count: 32)

        hub.publishDeviceToken(tokenData)

        XCTAssertEqual(hub.latestToken(), token)
        var iterator = hub.events().makeAsyncIterator()
        let replay = await iterator.next()
        XCTAssertEqual(replay, .registered(token))

        hub.clear()
        XCTAssertNil(hub.latestToken())
    }

    func testInstallationIdentityPersistsWithoutPersistingAPNsToken()
        async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installationID = UUID(
            uuidString: "b1000000-0000-4000-8000-000000000001"
        )!
        let protection = JSONCompetitionEventStoreFileProtection { _, _ in }
        let first = CompetitionInstallationStateStore(
            directory: root,
            makeUUID: { installationID },
            fileProtection: protection
        )

        let initial = try await first.loadOrCreate()
        try await first.markRegistrationAttempted()
        let reloaded = try await CompetitionInstallationStateStore(
            directory: root,
            makeUUID: { UUID() },
            fileProtection: protection
        ).loadOrCreate()

        XCTAssertEqual(initial.installationID, installationID)
        XCTAssertFalse(initial.registrationAttempted)
        XCTAssertEqual(reloaded.installationID, installationID)
        XCTAssertTrue(reloaded.registrationAttempted)
        let persisted = try String(
            contentsOf: root.appendingPathComponent(
                "installation-state.v1.json",
                isDirectory: false
            ),
            encoding: .utf8
        )
        XCTAssertFalse(persisted.lowercased().contains("apns"))
        XCTAssertFalse(persisted.contains(String(repeating: "ab", count: 32)))
    }

    func testCoordinatorRegistersAndRemovesStableProfileInstallation()
        async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installationID = UUID(
            uuidString: "b1000000-0000-4000-8000-000000000001"
        )!
        let token = String(repeating: "cd", count: 32)
        let registration = PushRegistrationProbe(token: token)
        let remote = RemoteInstallationProbe()
        let store = CompetitionInstallationStateStore(
            directory: root,
            makeUUID: { installationID },
            fileProtection: JSONCompetitionEventStoreFileProtection {
                _, _ in
            }
        )
        let coordinator = CompetitionInstallationCoordinator(
            remoteAPI: remote.api,
            registration: registration.client,
            store: store,
            environment: .sandbox
        )

        try await coordinator.start()
        try await coordinator.prepareForProfileTeardown(
            requireRemoteRemoval: true
        )

        let registrationRequests = await remote.registrationRequests()
        let removalIDs = await remote.removalIDs()
        let registrationCalls = await registration.calls()
        XCTAssertEqual(
            registrationRequests,
            [
                try CompetitionInstallationRequest(
                    installationID: installationID,
                    apnsToken: token,
                    environment: .sandbox
                ),
            ]
        )
        XCTAssertEqual(removalIDs, [installationID])
        XCTAssertEqual(
            registrationCalls,
            ["register", "unregister"]
        )
        let clearedState = try await store.loadOrCreate()
        XCTAssertFalse(clearedState.registrationAttempted)
    }

    func testRequiredRemovalFailureStillUnregistersAndSurfacesFailure()
        async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = PushRegistrationProbe(
            token: String(repeating: "ef", count: 32)
        )
        let remote = RemoteInstallationProbe(
            removalFailure: .retryableTransport
        )
        let coordinator = CompetitionInstallationCoordinator(
            remoteAPI: remote.api,
            registration: registration.client,
            store: CompetitionInstallationStateStore(
                directory: root,
                fileProtection: JSONCompetitionEventStoreFileProtection {
                    _, _ in
                }
            ),
            environment: .production
        )
        try await coordinator.start()

        do {
            try await coordinator.prepareForProfileTeardown(
                requireRemoteRemoval: true
            )
            XCTFail("Required remote cleanup must surface transport failure.")
        } catch let failure as CompetitionRemoteFailure {
            XCTAssertEqual(failure, .retryableTransport)
        }

        let registrationCalls = await registration.calls()
        XCTAssertEqual(
            registrationCalls,
            ["register", "unregister"]
        )
    }

    func testStopAndRestartReregistersUnchangedDeviceToken() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = PushRegistrationProbe(
            token: String(repeating: "fa", count: 32)
        )
        let remote = RemoteInstallationProbe()
        let coordinator = CompetitionInstallationCoordinator(
            remoteAPI: remote.api,
            registration: registration.client,
            store: CompetitionInstallationStateStore(
                directory: root,
                fileProtection: JSONCompetitionEventStoreFileProtection {
                    _, _ in
                }
            ),
            environment: .sandbox
        )

        try await coordinator.start()
        await coordinator.stopListening()
        try await coordinator.start()

        let requests = await remote.registrationRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first, requests.last)
        await coordinator.stopListening()
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "push-registration-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }
}

private actor PushRegistrationProbe {
    private let token: String?
    private var recordedCalls: [String] = []

    init(token: String?) {
        self.token = token
    }

    nonisolated var client: CompetitionPushRegistrationClient {
        CompetitionPushRegistrationClient(
            register: { [weak self] in await self?.record("register") },
            unregister: { [weak self] in
                await self?.record("unregister")
            },
            latestToken: { [weak self] in self?.token },
            events: {
                AsyncStream<CompetitionPushRegistrationEvent> {
                    continuation in continuation.finish()
                }
            }
        )
    }

    func calls() -> [String] { recordedCalls }

    private func record(_ value: String) {
        recordedCalls.append(value)
    }
}

private actor RemoteInstallationProbe {
    private var registrations: [CompetitionInstallationRequest] = []
    private var removals: [UUID] = []
    private let removalFailure: CompetitionRemoteFailure?

    init(removalFailure: CompetitionRemoteFailure? = nil) {
        self.removalFailure = removalFailure
    }

    nonisolated var api: CompetitionRemoteAPI {
        CompetitionRemoteAPI(
            bootstrapProfile: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            updateProfile: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            listCompetitions: {
                throw CompetitionRemoteFailure.operationFailed
            },
            fetchCompetition: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            createInvite: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            claimInvite: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            appendScoreRevision: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            submitAttestation: { _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            fetchChanges: { _, _ in
                throw CompetitionRemoteFailure.operationFailed
            },
            registerInstallation: { [weak self] request in
                guard let self else {
                    throw CompetitionRemoteFailure.operationFailed
                }
                return try await self.register(request)
            },
            removeInstallation: { [weak self] id in
                guard let self else {
                    throw CompetitionRemoteFailure.operationFailed
                }
                return try await self.remove(id)
            },
            requestAccountDeletion: {
                throw CompetitionRemoteFailure.operationFailed
            }
        )
    }

    func registrationRequests() -> [CompetitionInstallationRequest] {
        registrations
    }

    func removalIDs() -> [UUID] { removals }

    private func register(
        _ request: CompetitionInstallationRequest
    ) throws -> CompetitionInstallation {
        registrations.append(request)
        return try CompetitionInstallation(
            installationID: request.installationID,
            environment: request.environment,
            state: .active
        )
    }

    private func remove(_ id: UUID) throws -> CompetitionInstallation {
        removals.append(id)
        if let removalFailure { throw removalFailure }
        return try CompetitionInstallation(
            installationID: id,
            environment: .sandbox,
            state: .revoked
        )
    }
}

import CompetitionCore
import Foundation
import XCTest
@testable import HealthComp

final class CompetitionNotificationClientTests: XCTestCase {
    func testNotificationOperationsForward() async throws {
        let id = CompetitionID(
            UUID(uuidString: "EAD172F8-531D-4327-823D-E82A4F696070")!
        )
        let route = CompetitionRoute.competition(id)
        let content = CompetitionNotificationContent(
            title: "Competition",
            body: "Open Activity Sharing for the latest result."
        )
        let immediate = CompetitionImmediateNotificationRequest(
            identifier: "competition-notification:v1:test:result",
            content: content,
            route: route
        )
        let scheduled = CompetitionScheduledNotificationRequest(
            identifier: "competition-notification:v1:test:final-day",
            content: content,
            dateComponents: DateComponents(
                calendar: Calendar(identifier: .gregorian),
                timeZone: TimeZone(identifier: "UTC"),
                year: 2026,
                month: 8,
                day: 10,
                hour: 9
            ),
            route: route
        )
        let recorder = NotificationClientRecorder()
        let client = recorder.client

        let authorization = await client.authorizationState()
        XCTAssertEqual(authorization, .provisional)
        try await client.upsert(scheduled)
        try await client.postNow(immediate)
        let pending = await client.pendingIDs(
            "competition-notification:v1:"
        )
        XCTAssertEqual(
            pending,
            [scheduled.identifier]
        )
        let delivered = await client.deliveredIDs(
            "competition-notification:v1:"
        )
        XCTAssertEqual(
            delivered,
            [immediate.identifier]
        )
        await client.removePending([scheduled.identifier])
        await client.removeDelivered([immediate.identifier])

        XCTAssertEqual(
            recorder.snapshot,
            NotificationClientRecorder.Snapshot(
                upserts: [scheduled],
                posts: [immediate],
                removedPending: [[scheduled.identifier]],
                removedDelivered: [[immediate.identifier]]
            )
        )
    }
}

private final class NotificationClientRecorder: @unchecked Sendable {
    struct Snapshot: Equatable {
        var upserts: [CompetitionScheduledNotificationRequest] = []
        var posts: [CompetitionImmediateNotificationRequest] = []
        var removedPending: [[String]] = []
        var removedDelivered: [[String]] = []
    }

    private let lock = NSLock()
    private var state = Snapshot()

    var snapshot: Snapshot { lock.withLock { state } }

    var client: CompetitionNotificationClient {
        CompetitionNotificationClient(
            requestAuthorization: { true },
            authorizationState: { .provisional },
            upsert: { [weak self] request in
                self?.lock.withLock { self?.state.upserts.append(request) }
            },
            postNow: { [weak self] request in
                self?.lock.withLock { self?.state.posts.append(request) }
            },
            pendingIDs: { _ in
                ["competition-notification:v1:test:final-day"]
            },
            deliveredIDs: { _ in
                ["competition-notification:v1:test:result"]
            },
            removePending: { [weak self] ids in
                self?.lock.withLock {
                    self?.state.removedPending.append(ids)
                }
            },
            removeDelivered: { [weak self] ids in
                self?.lock.withLock {
                    self?.state.removedDelivered.append(ids)
                }
            }
        )
    }
}

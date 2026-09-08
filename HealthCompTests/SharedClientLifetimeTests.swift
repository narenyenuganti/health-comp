import XCTest
@testable import HealthComp

final class SharedClientLifetimeTests: XCTestCase {
    func testListenerRetirementClosesAdmissionAndWaitsForSettlement() async throws {
        let tasks = AuthenticationLifetimeTasks()
        let entered = LifetimeTestBarrier()
        let release = LifetimeTestBarrier()
        let allowedToFinish = LifetimeTestFlag()
        let cancelled = expectation(description: "listener receives cancellation")
        let prematureDrain = expectation(description: "drain must wait for settlement")
        prematureDrain.isInverted = true
        let work = try tasks.start {
            await withTaskCancellationHandler {
                await entered.release()
                await release.wait()
            } onCancel: {
                cancelled.fulfill()
            }
        }
        await entered.wait()
        let stopping = Task {
            await tasks.cancelAndDrain()
            if !allowedToFinish.value { prematureDrain.fulfill() }
        }
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertThrowsError(try tasks.start {})
        await fulfillment(of: [prematureDrain], timeout: 0.05)
        allowedToFinish.set()
        await release.release()
        await stopping.value
        await work.value
        await tasks.cancelAndDrain()
        XCTAssertThrowsError(try tasks.start {})
    }

    func testOwnerBoundOperationRejectsUnownedRetiringAndRetiredClients() async throws {
        let registry = SharedClientLifetime { LifetimeTestClient() }
        let first = try registry.client()
        XCTAssertEqual(try registry.withActiveOwner(first) { 42 }, 42)
        XCTAssertThrowsError(try registry.withActiveOwner(LifetimeTestClient()) {
            XCTFail("Unowned operation ran")
        })
        let entered = LifetimeTestBarrier()
        let release = LifetimeTestBarrier()
        let retiring = Task {
            try await registry.retire(first) { _ in
                await entered.release()
                await release.wait()
            }
        }
        await entered.wait()
        XCTAssertThrowsError(try registry.withActiveOwner(first) {
            XCTFail("Retiring operation ran")
        })
        await release.release()
        try await retiring.value
        let second = try registry.beginFreshLifetime()
        XCTAssertThrowsError(try registry.withActiveOwner(first) {
            XCTFail("Prior owner operation ran")
        })
        XCTAssertEqual(try registry.withActiveOwner(second) { 43 }, 43)
    }

    func testConfirmedRetirementRequiresExplicitFreshAdmission() async throws {
        let registry = SharedClientLifetime { LifetimeTestClient() }
        let first = try registry.client()
        XCTAssertTrue(try registry.client() === first)
        try await registry.retire(first) { _ in }
        XCTAssertThrowsError(try registry.client())
        let second = try registry.beginFreshLifetime()
        XCTAssertFalse(first === second)
        XCTAssertTrue(try registry.client() === second)
        XCTAssertTrue(try registry.beginFreshLifetime() === second)
        do {
            try await registry.retire(first) { _ in XCTFail("Non-owning retirement was admitted") }
            XCTFail("Expected wrong-owner failure")
        } catch {}
        XCTAssertTrue(try registry.client() === second)
    }

    func testFailedRetirementBlocksReplacementUntilSameOwnerRetries() async throws {
        let registry = SharedClientLifetime { LifetimeTestClient() }
        let first = try registry.client()
        do {
            try await registry.retire(first) { _ in throw LifetimeTestFailure.expected }
            XCTFail("Expected confirmation failure")
        } catch {
            XCTAssertEqual(error as? LifetimeTestFailure, .expected)
        }
        XCTAssertThrowsError(try registry.client())
        XCTAssertThrowsError(try registry.beginFreshLifetime())
        try await registry.retire(first) { _ in }
        XCTAssertFalse(try registry.beginFreshLifetime() === first)
    }

    func testPendingRetirementRejectsAccessAdmissionAndDuplicateRetirement() async throws {
        let registry = SharedClientLifetime { LifetimeTestClient() }
        let first = try registry.client()
        let entered = LifetimeTestBarrier()
        let release = LifetimeTestBarrier()
        let pending = Task {
            try await registry.retire(first) { _ in
                await entered.release()
                await release.wait()
            }
        }
        await entered.wait()
        XCTAssertThrowsError(try registry.client())
        XCTAssertThrowsError(try registry.beginFreshLifetime())
        do {
            try await registry.retire(first) { _ in XCTFail("Duplicate confirmation was admitted") }
            XCTFail("Expected pending-retirement failure")
        } catch {}
        await release.release()
        try await pending.value
        XCTAssertFalse(try registry.beginFreshLifetime() === first)
    }
}

private final class LifetimeTestClient: Sendable {}
private final class LifetimeTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
private enum LifetimeTestFailure: Error { case expected }
private actor LifetimeTestBarrier {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

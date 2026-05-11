import XCTest
@testable import HealthComp

final class CompetitionNotificationClientTests: XCTestCase {

    func testScheduleAlertCalled() async throws {
        let alert = CompetitionAlert(
            id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            kind: .competitionCompleted(.won),
            modeName: "Apple Activity"
        )
        var scheduledAlert: CompetitionAlert?
        let client = CompetitionNotificationClient(
            requestAuthorization: { true },
            schedule: {
                scheduledAlert = $0
            }
        )

        let authorized = try await client.requestAuthorization()
        try await client.schedule(alert)

        XCTAssertTrue(authorized)
        XCTAssertEqual(scheduledAlert, alert)
    }
}

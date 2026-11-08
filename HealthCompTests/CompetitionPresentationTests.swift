import AVFoundation
import CompetitionCore
import SwiftUI
import UIKit
import XCTest
@testable import HealthComp

final class CompetitionPresentationTests: XCTestCase {
    @MainActor
    func testInvitationNamesGrowVerticallyInsteadOfTruncatingLongRecipients() {
        for size in [DynamicTypeSize.large, .accessibility3] {
            func height(_ name: String) -> CGFloat {
                let host = UIHostingController(rootView:
                    CompetitionInvitationFaceOff(opponentDisplayName: name)
                        .environment(\.dynamicTypeSize, size)
                )
                host.loadViewIfNeeded()
                return host.sizeThatFits(in: CGSize(width: 220, height: 2000)).height
            }
            XCTAssertGreaterThan(height("Alexandria Catherine Montgomery-Wellington"), height("Sam"),
                "The complete recipient name needs additional lines at \(size), not an ellipsis.")
        }
    }
    @MainActor
    func testFinalScoreLayoutReturnsFiniteSizesForEveryProposalShape() throws {
        let measurements = measureFinalScoreLayout()
        for proposal in FinalScoreLayoutProposal.allCases {
            let sizes = try XCTUnwrap(
                measurements[proposal],
                "The hosted layout did not measure \(proposal)."
            )
            XCTAssertFalse(sizes.isEmpty)
            for size in sizes {
                XCTAssertTrue(size.width.isFinite, "\(proposal): \(size)")
                XCTAssertTrue(size.height.isFinite, "\(proposal): \(size)")
                XCTAssertGreaterThanOrEqual(size.width, 0, "\(proposal): \(size)")
                XCTAssertGreaterThanOrEqual(size.height, 0, "\(proposal): \(size)")
            }
        }
    }

    @MainActor
    func testFinalScoreLayoutUsesLessHeightAtWideThanNarrowWidth() throws {
        let measurements = measureFinalScoreLayout()
        let narrow = try XCTUnwrap(measurements[.narrow]?.last)
        let wide = try XCTUnwrap(measurements[.wide]?.last)

        XCTAssertGreaterThan(narrow.height, 0)
        XCTAssertGreaterThan(wide.height, 0)
        XCTAssertLessThan(
            wide.height,
            narrow.height,
            "Wide layout must need less vertical room for these score fixtures."
        )
    }

    @MainActor
    private func measureFinalScoreLayout() -> [FinalScoreLayoutProposal: [CGSize]] {
        let recorder = FinalScoreLayoutMeasurements()
        let canvasSize = CGSize(width: 720, height: 960)
        let root = FinalScoreProposalProbeLayout(recorder: recorder) {
            CompetitionFinalScoreLayout {
                FinalScoreProbeOwner(name: "Beta Alice", points: "3,520")
                Text("–")
                    .font(.title2.weight(.medium))
                    .accessibilityHidden(true)
                FinalScoreProbeOwner(name: "Former competitor", points: "3,410")
            }
        }
        .environment(\.dynamicTypeSize, .large)

        // A finite, unattached host drives real SwiftUI layout without a window.
        // Only the test parent sends special proposals to its LayoutSubview.
        let host = UIHostingController(rootView: root)
        host.loadViewIfNeeded()
        host.view.frame = CGRect(origin: .zero, size: canvasSize)
        host.view.setNeedsLayout()
        _ = host.sizeThatFits(in: canvasSize)
        host.view.layoutIfNeeded()
        return recorder.sizes
    }

    func testArchivedRemoteHistoryCannotBeDeletedLocally() {
        XCTAssertEqual(
            competitionResultDataControl(
                source: .remoteParticipants,
                isArchived: false
            ),
            .archive
        )
        XCTAssertEqual(
            competitionResultDataControl(
                source: .remoteParticipants,
                isArchived: true
            ),
            .preservedHistory
        )
        XCTAssertEqual(
            competitionResultDataControl(
                source: .simulatedFixture,
                isArchived: true
            ),
            .deleteLocalData
        )
    }

    func testRemoteParticipantCopyUsesRealIdentityWithoutFixtureLanguage() {
        let source = CompetitionPublicationSource.remoteParticipants

        XCTAssertNil(
            competitionFixtureDisclosure(
                source: source,
                opponentDisplayName: "Priya"
            )
        )
        XCTAssertEqual(
            competitionInviteTitle(
                direction: .outgoing,
                opponentDisplayName: "Priya"
            ),
            "Challenge to Priya"
        )
        XCTAssertEqual(
            competitionResultTitle(
                outcome: .loss,
                opponentDisplayName: "Priya"
            ),
            "Priya won"
        )
        let tallyBody = competitionTallyCopy(
            LocalCompetitionTallyPresentation(
                attention: .opponentPlanUnavailable,
                consecutiveStableCompleteReads: 0,
                stabilityStart: nil,
                bestAvailableDeadline: .distantFuture
            ),
            opponentDisplayName: "Priya",
            now: .distantPast
        ).body
        XCTAssertTrue(tallyBody.contains("Priya"), tallyBody)

        let allCopy = [
            competitionInviteTitle(
                direction: .outgoing,
                opponentDisplayName: "Priya"
            ),
            competitionResultTitle(
                outcome: .loss,
                opponentDisplayName: "Priya"
            ),
            tallyBody,
        ].joined(separator: " ")
        XCTAssertFalse(allCopy.contains("Alex"))
        XCTAssertFalse(allCopy.localizedCaseInsensitiveContains("simulat"))
    }

    func testFixtureParticipantCopyRetainsExplicitSimulationDisclosure() {
        XCTAssertEqual(
            competitionFixtureDisclosure(
                source: .simulatedFixture,
                opponentDisplayName: "Alex"
            ),
            "Alex is simulated on this iPhone."
        )
    }

    func testScheduleCardShowsTheInclusiveWeek() throws {
        let timeZoneIdentifier = "America/Los_Angeles"
        let schedule = CompetitionSchedule(
            calendar: try CompetitionCalendar(
                timeZoneIdentifier: timeZoneIdentifier
            ),
            startDay: try CompetitionDay(
                era: 1,
                year: 2026,
                month: 8,
                day: 13,
                timeZoneIdentifier: timeZoneIdentifier
            )
        )

        XCTAssertEqual(
            competitionScheduleBoundaries(schedule)?.start,
            ISO8601DateFormatter().date(from: "2026-08-13T07:00:00Z")
        )
        XCTAssertEqual(
            competitionScheduleBoundaries(schedule)?.end,
            ISO8601DateFormatter().date(from: "2026-08-20T07:00:00Z")
        )
        let range = try XCTUnwrap(competitionScheduleDateRangeText(
            schedule,
            now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")),
            locale: Locale(identifier: "en_US")
        ))
        XCTAssertEqual(normalized(range), "Aug 13 – 19")
        XCTAssertFalse(range.contains(":"))
        XCTAssertFalse(range.contains("GMT"))
        XCTAssertEqual(schedule.startDay.day, 13)

        let mismatched = CompetitionSchedule(
            calendar: try CompetitionCalendar(timeZoneIdentifier: "UTC"),
            startDay: schedule.startDay
        )
        XCTAssertNil(competitionScheduleDateRangeText(mismatched))
    }

    func testAutumnScheduleEndUsesNextCanonicalDayAcrossDST() throws {
        let zone = "America/Los_Angeles"
        let schedule = CompetitionSchedule(
            calendar: try CompetitionCalendar(timeZoneIdentifier: zone),
            startDay: try CompetitionDay(
                era: 1, year: 2026, month: 10, day: 28,
                timeZoneIdentifier: zone
            )
        )
        let boundaries = try XCTUnwrap(competitionScheduleBoundaries(schedule))
        XCTAssertEqual(boundaries.start, ISO8601DateFormatter().date(from: "2026-10-28T07:00:00Z"))
        XCTAssertEqual(boundaries.end, ISO8601DateFormatter().date(from: "2026-11-04T08:00:00Z"))
        XCTAssertEqual(boundaries.end.timeIntervalSince(boundaries.start), 169 * 3_600)
        XCTAssertEqual(schedule.startDay.day, 28)
    }

    func testStatusTextNamesEveryLifecycleInEveryStyle() throws {
        let zone = "America/Los_Angeles"
        let la = try XCTUnwrap(TimeZone(identifier: zone))
        let en = Locale(identifier: "en_US")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z"))
        let schedule = try statusSchedule()
        func status(
            _ lifecycle: LocalCompetitionLifecyclePresentation,
            _ style: CompetitionStatusStyle,
            schedule: CompetitionSchedule? = nil
        ) -> CompetitionStatusText {
            competitionStatusText(
                lifecycle,
                schedule: schedule,
                opponentDisplayName: "Hermes",
                style: style,
                now: now,
                locale: en,
                timeZone: la
            )
        }
        func normalizedStatus(
            _ lifecycle: LocalCompetitionLifecyclePresentation,
            _ style: CompetitionStatusStyle
        ) -> [String?] {
            let text = status(lifecycle, style, schedule: schedule)
            return [text.title, text.timing.map(normalized)]
        }
        let created = Date(timeIntervalSince1970: 0)
        let win = LocalCompetitionLifecyclePresentation.completed(
            outcome: .win, basis: .stableAcrossPostBoundaryReads, completedAt: created
        )
        let loss = LocalCompetitionLifecyclePresentation.archived(
            outcome: .loss, basis: .stableAcrossPostBoundaryReads,
            completedAt: created, archivedAt: created
        )
        let tie = LocalCompetitionLifecyclePresentation.completed(
            outcome: .tie, basis: .bestAvailable, completedAt: created
        )
        let week = "Oct 28 – Nov 3"
        let expected: [(LocalCompetitionLifecyclePresentation, [CompetitionStatusStyle: [String?]])] = [
            (.pending(direction: .outgoing, createdAt: created, expiresAt: nil), [
                .row: ["Challenge sent", nil], .card: ["Challenge sent", nil],
                .notification: ["Challenge to Hermes", nil],
            ]),
            (.pending(direction: .incoming, createdAt: created, expiresAt: nil), [
                .row: ["Challenge received", nil], .card: ["Challenge received", nil],
                .notification: ["Hermes challenged you", nil],
            ]),
            (.declined(at: created, direction: .incoming), [
                .row: ["Declined", nil], .card: ["Declined", nil],
                .notification: ["Challenge declined", nil],
            ]),
            (.expired(at: created, direction: .outgoing), [
                .row: ["Expired", nil], .card: ["Expired", nil],
                .notification: ["Challenge expired", nil],
            ]),
            (.scheduled, [
                .row: ["Starts Wed, Oct 28", nil], .card: ["Scheduled", "Starts Wed, Oct 28"],
                .notification: ["Starts Wed, Oct 28", nil],
            ]),
            (.active(dayOrdinal: 4), [
                .row: ["Day 4 of 7", "Ends Tue night"], .card: ["Day 4 of 7", "Ends Tue night"],
                .notification: ["Day 4 of 7", nil],
            ]),
            (.endsToday, [
                .row: ["Last day", "Ends at midnight"], .card: ["Last day", "Ends at midnight"],
                .notification: ["Last day", nil],
            ]),
            (.tallying(startedAt: created), [
                .row: ["Final score pending", nil], .card: ["Final score pending", nil],
                .notification: ["Final score pending", nil],
            ]),
            (win, [
                .row: ["You won", week], .card: ["You won", week],
                .notification: ["You beat Hermes", nil],
            ]),
            (loss, [
                .row: ["Hermes won", week], .card: ["Hermes won", week],
                .notification: ["Hermes won", nil],
            ]),
            (tie, [
                .row: ["Tied", week], .card: ["Tied", week],
                .notification: ["All square with Hermes", nil],
            ]),
        ]
        for (lifecycle, styles) in expected {
            for (style, title) in styles {
                XCTAssertEqual(normalizedStatus(lifecycle, style), title, "\(lifecycle) \(style)")
            }
        }

        XCTAssertEqual(status(.active(dayOrdinal: 4), .row, schedule: schedule).line, "Day 4 of 7 · Ends Tue night")
        XCTAssertEqual(status(.scheduled, .card, schedule: schedule).line, "Scheduled · Starts Wed, Oct 28")
        XCTAssertNil(status(.active(dayOrdinal: 4), .row).timing)
        XCTAssertEqual(status(.scheduled, .card), CompetitionStatusText(title: "Scheduled", timing: nil))

        let presentation = LocalCompetitionPresentation(
            id: CompetitionID(UUID()),
            ownerDisplayName: "Naren",
            opponentDisplayName: "Hermes",
            lifecycle: win,
            acceptedConfiguration: LocalCompetitionAcceptedPresentation(
                schedule: schedule, difficulty: .balanced
            ),
            userPoints: 412,
            opponentPoints: 380,
            days: [],
            currentDayOrdinal: nil,
            lastRefresh: nil,
            tally: nil,
            terminalResult: nil,
            evaluatedAt: try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-02-01T12:00:00Z")),
            timeZoneIdentifier: zone
        )
        let timing = try XCTUnwrap(
            competitionStatusText(presentation, style: .row, locale: en, timeZone: la).timing
        )
        XCTAssertTrue(timing.contains("2026"), timing)
    }

    func testStatusTimingAddsCalendarZoneOnlyWhenOffsetDiffers() throws {
        let schedule = try statusSchedule()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z"))
        func timing(
            _ lifecycle: LocalCompetitionLifecyclePresentation,
            phone: String
        ) -> String? {
            competitionStatusText(
                lifecycle,
                schedule: schedule,
                opponentDisplayName: "Hermes",
                style: .card,
                now: now,
                locale: Locale(identifier: "en_US"),
                timeZone: TimeZone(identifier: phone)!
            ).timing
        }
        XCTAssertEqual(timing(.active(dayOrdinal: 4), phone: "Asia/Tokyo"), "Ends Tue night PST")
        XCTAssertEqual(timing(.endsToday, phone: "Asia/Tokyo"), "Ends at midnight PST")
        XCTAssertEqual(timing(.scheduled, phone: "Asia/Tokyo"), "Starts Wed, Oct 28 PDT")
        // Same offset under another zone name: no suffix. (Not Vancouver:
        // current tzdata keeps British Columbia on -07 from Nov 2026.)
        XCTAssertEqual(timing(.active(dayOrdinal: 4), phone: "US/Pacific"), "Ends Tue night")
        XCTAssertEqual(timing(.endsToday, phone: "US/Pacific"), "Ends at midnight")
        XCTAssertEqual(timing(.scheduled, phone: "US/Pacific"), "Starts Wed, Oct 28")
    }

    private func statusSchedule() throws -> CompetitionSchedule {
        let zone = "America/Los_Angeles"
        return CompetitionSchedule(
            calendar: try CompetitionCalendar(timeZoneIdentifier: zone),
            startDay: try CompetitionDay(
                era: 1, year: 2026, month: 10, day: 28,
                timeZoneIdentifier: zone
            )
        )
    }

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    func testRefreshFailureCopyMapsEveryPrivacySafeReason() {
        let expected: [(ActivityQueryFailureReason, String)] = [
            (
                .protectedDataUnavailable,
                "Health data is locked — unlock this iPhone to update."
            ),
            (
                .healthDataUnavailable,
                "Health data is unavailable on this device."
            ),
            (
                .queryCancelled,
                "Activity update was interrupted. HealthComp will try again."
            ),
            (
                .transientFailure,
                "Activity couldn’t be updated. HealthComp will try again."
            ),
            (
                .invalidResponse,
                "Activity data couldn’t be read. HealthComp will try again."
            ),
            (
                .unknown,
                "Activity couldn’t be updated. HealthComp will try again."
            ),
        ]

        for (reason, copy) in expected {
            XCTAssertEqual(
                competitionRefreshStatusText(.failed(reason: reason)),
                copy
            )
        }
        XCTAssertEqual(
            competitionRefreshStatusText(.completed),
            "Activity data updated."
        )
    }

    func testPerDayUnavailableReasonsStayDistinctAndNeutral() {
        let expected: [(ActivityUnavailableReason, String)] = [
            (
                .sourceDataUnavailable,
                "Activity source is temporarily unavailable."
            ),
            (
                .unsupportedActivityConfiguration,
                "This Activity configuration is not supported."
            ),
            (.invalidSourceData, "Activity data could not be used."),
        ]
        XCTAssertEqual(
            competitionOwnerAvailabilityText(.notSyncedYet, ordinal: 2),
            "Today hasn’t synced yet"
        )

        for (reason, copy) in expected {
            XCTAssertEqual(
                competitionOwnerAvailabilityText(
                    .unavailable(reason: reason),
                    ordinal: 2
                ),
                copy
            )
            XCTAssertTrue(
                competitionOwnerAccessibilityText(
                    presentation(
                        .unavailable(reason: reason),
                        points: nil
                    )
                ).contains(copy.replacingOccurrences(of: ".", with: ""))
            )
        }
    }

    func testCurrentFailureAndPriorSuccessfulReadAreBothDisclosed() {
        let failedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        let succeededAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let lines = competitionRefreshTimelineText(
            lastRefresh: LocalCompetitionRefreshPresentation(
                trigger: .dayBoundary,
                attemptedAt: failedAt,
                readAt: failedAt,
                status: .failed(reason: .protectedDataUnavailable)
            ),
            lastSuccessfulFullWindowRefreshAt: succeededAt,
            now: Date(timeIntervalSinceReferenceDate: 3_000),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "Asia/Tokyo")!
        )

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("Health data is locked"))
        XCTAssertTrue(normalized(lines[0]).contains("Mon 9:33 AM"), lines[0])
        XCTAssertFalse(lines[0].contains("GMT"))
        XCTAssertTrue(lines[1].contains("Last complete Activity read"))
        XCTAssertFalse(lines.joined(separator: " ").localizedCaseInsensitiveContains("sync"))
    }

    func testCompactChartDistinguishesFutureMissingUnavailableAndZero() throws {
        let day = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 9,
            timeZoneIdentifier: "UTC"
        )
        func presentation(
            _ availability: LocalCompetitionOwnerAvailability,
            points: Double?
        ) -> LocalCompetitionDayPresentation {
            LocalCompetitionDayPresentation(
                day: day,
                ordinal: 1,
                ownerAcceptedPoints: points,
                ownerLatestAvailability: availability,
                opponentRevealedPoints: nil
            )
        }

        XCTAssertEqual(
            competitionOwnerChartState(
                presentation(.notYetOccurred, points: nil)
            ),
            .future
        )
        XCTAssertEqual(
            competitionOwnerChartState(presentation(.missing, points: nil)),
            .missing
        )
        XCTAssertEqual(
            competitionOwnerChartState(presentation(.missing, points: 600)),
            .missingWithScore(600)
        )
        XCTAssertEqual(
            competitionOwnerChartState(
                presentation(
                    .unavailable(reason: .sourceDataUnavailable),
                    points: nil
                )
            ),
            .unavailable
        )
        XCTAssertEqual(
            competitionOwnerChartState(
                presentation(
                    .unavailable(reason: .sourceDataUnavailable),
                    points: 500
                )
            ),
            .unavailableWithScore(500)
        )
        XCTAssertEqual(
            competitionOwnerChartState(
                presentation(.observed, points: 0)
            ),
            .score(0)
        )
        let observedWithoutScore = presentation(.observed, points: nil)
        XCTAssertEqual(
            competitionOwnerChartState(observedWithoutScore),
            .unscored
        )
        XCTAssertEqual(
            competitionOwnerAccessibilityText(observedWithoutScore),
            "synced, no score yet"
        )
        let notSynced = presentation(.notSyncedYet, points: nil)
        XCTAssertEqual(competitionOwnerChartState(notSynced), .unscored)
        XCTAssertEqual(competitionOwnerAccessibilityText(notSynced), "not synced yet")
    }

    func testRingPanelRowsAddUpToTheAcceptedDayScore() throws {
        let snapshot = try rings(420, 36, 9)
        let panel = try XCTUnwrap(competitionRingPanel(
            ringDay(accepted: snapshot, latest: snapshot, points: 279),
            locale: Locale(identifier: "en_US")
        ))
        XCTAssertEqual(panel.rows.map(\.title), ["Move", "Exercise", "Stand"])
        XCTAssertEqual(panel.rows.map(\.detail), ["420/500 kcal", "36/30 min", "9/12 hr"])
        XCTAssertEqual(panel.rows.map(\.points), [84, 120, 75])
        XCTAssertNil(panel.note)
        XCTAssertFalse(panel.isPaused)
        XCTAssertEqual(panel.footer, "1 point per 1% of each ring. Your ring values stay on this iPhone.")
        XCTAssertEqual(
            panel.accessibilityLabel,
            "Your rings. Move, 420 of 500 kilocalories, 84 points. Exercise, 36 of 30 minutes, 120 points. Stand, 9 of 12 hours, 75 points."
        )
    }

    func testRingPanelSplitsACappedDayAndSaysSo() throws {
        let snapshot = try rings(1_100, 60, 24)
        let panel = try XCTUnwrap(competitionRingPanel(
            ringDay(accepted: snapshot, latest: snapshot, points: 600)
        ))
        let points = panel.rows.compactMap(\.points)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.reduce(0, +), 600)
        for part in points { XCTAssertEqual(part, part.rounded(), "\(part) is not whole") }
        XCTAssertTrue(panel.footer.hasPrefix("Capped at 600 points a day."), panel.footer)
    }

    func testRealMatchRingPanelCapsEachRingAt200() throws {
        let snapshot = try rings(1_500, 30, 12)
        let accepted = ringDay(accepted: snapshot, latest: snapshot, points: 400, policy: .remoteWireV1)
        let panel = try XCTUnwrap(competitionRingPanel(accepted))
        XCTAssertEqual(panel.rows.map(\.points), [200, 100, 100])
        XCTAssertEqual(
            panel.footer,
            "1 point per 1% of each ring, up to 200% per ring. Your ring values stay on this iPhone."
        )
        XCTAssertEqual(ringSegments(accepted).map(\.points), [200, 100, 100])

        let unsynced = try XCTUnwrap(competitionRingPanel(
            ringDay(accepted: nil, latest: snapshot, points: nil, policy: .remoteWireV1)
        ))
        XCTAssertEqual(unsynced.rows.map(\.points), [200, 100, 100])
        XCTAssertEqual(unsynced.note, "These points haven’t synced yet.")
    }

    func testRingPanelDrawsTheAcceptedSnapshotAndNotesANewerReading() throws {
        let accepted = try rings(420, 36, 9)
        let latest = try rings(480, 40, 10)
        let panel = try XCTUnwrap(competitionRingPanel(
            ringDay(accepted: accepted, latest: latest, points: 279),
            locale: Locale(identifier: "en_US")
        ))
        XCTAssertEqual(panel.rows.map(\.detail), ["420/500 kcal", "36/30 min", "9/12 hr"])
        XCTAssertEqual(panel.note, "Points use an earlier reading. Your rings have changed since.")
        XCTAssertTrue(panel.accessibilityLabel.hasSuffix(". Points use an earlier reading. Your rings have changed since."))
    }

    func testRingPanelMarksAScorableUnsyncedReading() throws {
        let panel = try XCTUnwrap(competitionRingPanel(
            ringDay(accepted: nil, latest: try rings(420, 36, 9), points: nil)
        ))
        XCTAssertEqual(panel.rows.map(\.points), [84, 120, 75])
        XCTAssertEqual(panel.note, "These points haven’t synced yet.")
    }

    func testRingPanelOmitsPointsForAPausedReading() throws {
        let paused = try makeSnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            pauseState: .paused
        )
        let panel = try XCTUnwrap(competitionRingPanel(
            ringDay(accepted: nil, latest: paused, points: nil)
        ))
        XCTAssertTrue(panel.rows.allSatisfy { $0.points == nil })
        XCTAssertTrue(panel.isPaused)
        XCTAssertNil(panel.note)
        XCTAssertTrue(panel.accessibilityLabel.contains("Activity tracking paused"))
        XCTAssertFalse(panel.accessibilityLabel.contains("points"))
    }

    func testRingPanelIsNilWithoutSnapshots() {
        XCTAssertNil(competitionRingPanel(ringDay(accepted: nil, latest: nil, points: 300)))
    }

    func testUnknownStandModeReadsStandOrRoll() throws {
        let snapshot = try makeSnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .unknown,
            pauseState: .unknown
        )
        let panel = try XCTUnwrap(competitionRingPanel(
            ringDay(accepted: snapshot, latest: snapshot, points: 600)
        ))
        XCTAssertTrue(panel.accessibilityLabel.contains("Stand or Roll"))
        XCTAssertFalse(panel.accessibilityLabel.lowercased().contains("pause"))
    }

    func testCompetitionDayYearFollowsTheViewersNewYearNotUTC() throws {
        let iso = ISO8601DateFormatter()
        let en = Locale(identifier: "en_US")
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let dec31 = try CompetitionDay(
            era: 1, year: 2026, month: 12, day: 31,
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let jan1 = try CompetitionDay(
            era: 1, year: 2027, month: 1, day: 1,
            timeZoneIdentifier: "Asia/Tokyo"
        )
        let dec25 = try CompetitionDay(
            era: 1, year: 2026, month: 12, day: 25,
            timeZoneIdentifier: "America/Los_Angeles"
        )
        // 5 PM Dec 31 in LA is already 2027 in UTC.
        let laEvening = try XCTUnwrap(iso.date(from: "2027-01-01T01:00:00Z"))
        XCTAssertEqual(
            competitionDayText(dec31, now: laEvening, locale: en, timeZone: la),
            "Thu, Dec 31"
        )
        XCTAssertEqual(
            normalized(competitionWeekText(dec25, dec31, now: laEvening, locale: en, timeZone: la)),
            "Dec 25 – 31"
        )
        // 8 AM Jan 1 in Tokyo is still 2026 in UTC.
        let tokyoMorning = try XCTUnwrap(iso.date(from: "2026-12-31T23:00:00Z"))
        XCTAssertEqual(
            competitionDayText(jan1, now: tokyoMorning, locale: en, timeZone: tokyo),
            "Fri, Jan 1"
        )
        // A different year still shows.
        XCTAssertEqual(
            competitionDayText(dec31, now: tokyoMorning, locale: en, timeZone: tokyo),
            "Thu, Dec 31, 2026"
        )
    }

    func testRingPanelMoveTimeRollUsesFullSpokenUnits() throws {
        let snapshot = try makeSnapshot(
            moveMode: .moveMinutes,
            standMode: .rollHours,
            pauseState: .running
        )
        let label = try XCTUnwrap(competitionRingPanel(
            ringDay(accepted: snapshot, latest: snapshot, points: 600),
            locale: Locale(identifier: "en_US")
        )).accessibilityLabel
        XCTAssertTrue(label.contains("Your rings"), label)
        XCTAssertTrue(label.contains("Move Time, 60 of 30 minutes, 200 points"), label)
        XCTAssertTrue(label.contains("Exercise, 60 of 30 minutes, 200 points"), label)
        XCTAssertTrue(label.contains("Roll, 24 of 12 hours, 200 points"), label)
    }

    func testFreshnessLineNamesBothSidesOnlyWhenBothExist() throws {
        let iso = ISO8601DateFormatter()
        let now = try XCTUnwrap(iso.date(from: "2026-10-31T16:41:00Z"))
        let them = try XCTUnwrap(iso.date(from: "2026-10-31T06:40:00Z"))
        func line(you: Date?, them: Date?) -> String? {
            competitionFreshnessText(
                LocalCompetitionPresentation(
                    id: CompetitionID(UUID()),
                    ownerDisplayName: "Naren",
                    opponentDisplayName: "Hermes",
                    lifecycle: .active(dayOrdinal: 3),
                    acceptedConfiguration: nil,
                    userPoints: 0,
                    opponentPoints: 0,
                    days: [],
                    currentDayOrdinal: 3,
                    lastRefresh: nil,
                    tally: nil,
                    terminalResult: nil,
                    evaluatedAt: now,
                    lastSuccessfulFullWindowRefreshAt: you,
                    opponentUpdatedAt: them
                ),
                locale: Locale(identifier: "en_US"),
                timeZone: TimeZone(identifier: "America/Los_Angeles")!
            ).map(normalized)
        }
        XCTAssertEqual(line(you: now, them: them), "You: updated 9:41 AM · Hermes: updated Fri 11:40 PM")
        XCTAssertEqual(line(you: now, them: nil), "Updated 9:41 AM")
        XCTAssertEqual(line(you: nil, them: them), "Hermes: updated Fri 11:40 PM")
        XCTAssertNil(line(you: nil, them: nil))
    }

    // MARK: What it takes

    func testWhatItTakesNamesThePointsAndTheRoomiestRings() throws {
        let takes = try XCTUnwrap(competitionWhatItTakes(
            takesCompetition(accepted: try takesRings(move: (410, 600), exercise: (24, 30), stand: (8, 12))),
            locale: en
        ))
        XCTAssertEqual(takes.headline, "39 to take the lead")
        XCTAssertEqual(takes.points, 39)
        XCTAssertEqual(takes.dayOrdinal, 5)
        XCTAssertEqual(takes.suggestion, "About 240 kcal of Move or 12 min of Exercise.")
        XCTAssertEqual(takes.detail, "About 240 kcal of Move or 12 min of Exercise. Sam can still add points today.")
        XCTAssertEqual(
            takes.accessibilityLabel,
            "39 points to take the lead. About 240 kilocalories of Move or 12 minutes of Exercise. Sam can still add points today."
        )
    }

    func testWhatItTakesIsOneWhenLevel() throws {
        let takes = try XCTUnwrap(competitionWhatItTakes(
            takesCompetition(user: 1_000, opponent: 1_000.2, accepted: try takesRings(move: (410, 600), exercise: (24, 30))),
            locale: en
        ))
        XCTAssertEqual(takes.headline, "1 to take the lead")
        XCTAssertEqual(takes.points, 1)
    }

    func testWhatItTakesHidesWhenYouLeadOrTheDayIsNotLive() throws {
        let snapshot = try takesRings(move: (410, 600), exercise: (24, 30))
        XCTAssertNil(competitionWhatItTakes(takesCompetition(user: 1_001, opponent: 1_000, accepted: snapshot)))
        XCTAssertNil(competitionWhatItTakes(takesCompetition(
            accepted: snapshot, lifecycle: .tallying(startedAt: Date(timeIntervalSince1970: 0))
        )))
        XCTAssertNil(competitionWhatItTakes(takesCompetition(accepted: snapshot, lifecycle: .scheduled)))
        XCTAssertNil(competitionWhatItTakes(takesCompetition(accepted: snapshot, ordinal: nil)))
        XCTAssertNotNil(competitionWhatItTakes(takesCompetition(accepted: snapshot, lifecycle: .endsToday)))
    }

    func testWhatItTakesSaysOutOfReachWhenMoveAndExerciseCantCoverTheGap() throws {
        func takes(_ user: Double, _ opponent: Double, today: Double, _ snapshot: ActivitySnapshot) throws -> CompetitionWhatItTakes {
            try XCTUnwrap(competitionWhatItTakes(
                takesCompetition(user: user, opponent: opponent, today: today, accepted: snapshot, lifecycle: .endsToday, ordinal: 7),
                locale: en
            ))
        }
        let room = try takes(2_010, 2_390, today: 390, try takesRings(move: (540, 600), exercise: (60, 30), stand: (12, 12)))
        XCTAssertEqual(room.headline, "Out of reach today")
        XCTAssertNil(room.points)
        XCTAssertEqual(room.dayOrdinal, 7)
        XCTAssertEqual(room.detail, "Sam is 380 ahead and you have 110 points left in Move and Exercise today.")
        XCTAssertEqual(room.suggestion, room.detail)
        XCTAssertEqual(
            room.accessibilityLabel,
            "Out of reach today. Sam is 380 points ahead and you have 110 points left in Move and Exercise today."
        )

        let full = try takesRings(move: (1_200, 600), exercise: (60, 30), stand: (24, 12))
        XCTAssertEqual(
            try takes(2_010, 2_390, today: 600, full).detail,
            "Sam is 380 ahead and you’ve reached today’s cap."
        )
        XCTAssertEqual(
            try takes(2_390, 2_390, today: 600, full).detail,
            "All square, and you’ve reached today’s cap."
        )
    }

    func testWhatItTakesNeverSuggestsStandWhenMoveAndExerciseAreCapped() throws {
        let snapshot = try takesRings(move: (1_200, 600), exercise: (60, 30), stand: (6, 12))
        let behind = try XCTUnwrap(competitionWhatItTakes(
            takesCompetition(user: 1_000, opponent: 1_038, today: 450, accepted: snapshot), locale: en
        ))
        XCTAssertEqual(behind.headline, "Out of reach today")
        XCTAssertEqual(behind.detail, "Sam is 38 ahead and Move and Exercise are at the 200% cap.")
        let level = try XCTUnwrap(competitionWhatItTakes(
            takesCompetition(user: 1_000, opponent: 1_000, today: 450, accepted: snapshot), locale: en
        ))
        XCTAssertEqual(level.detail, "All square, and Move and Exercise are at the 200% cap.")
    }

    func testWhatItTakesUsesOneWholeNumberForReachAndCopy() throws {
        let snapshot = try takesRings(move: (300, 600), exercise: (15, 30))
        let out = try XCTUnwrap(competitionWhatItTakes(
            takesCompetition(user: 1_000, opponent: 1_209, today: 390.4, accepted: snapshot), locale: en
        ))
        XCTAssertEqual(out.headline, "Out of reach today")
        XCTAssertEqual(out.detail, "Sam is 209 ahead and you have 209 points left in Move and Exercise today.")
        let reachable = try XCTUnwrap(competitionWhatItTakes(
            takesCompetition(user: 1_000, opponent: 1_208, today: 390.4, accepted: snapshot), locale: en
        ))
        XCTAssertEqual(reachable.headline, "209 to take the lead")
        XCTAssertEqual(
            reachable.detail,
            "About 900 kcal of Move and 18 min of Exercise. Sam can still add points today."
        )
    }

    func testWhatItTakesUsesMoveTimeMinutes() throws {
        let takes = try XCTUnwrap(competitionWhatItTakes(
            takesCompetition(accepted: try takesRings(move: (20, 30), exercise: (24, 30), moveMinutes: true)),
            locale: en
        ))
        XCTAssertEqual(takes.suggestion, "About 12 min of Move Time or 12 min of Exercise.")
        XCTAssertTrue(takes.accessibilityLabel.contains("About 12 minutes of Move Time or 12 minutes of Exercise."))
    }

    func testWhatItTakesSkipsARingAtItsCapAndSplitsWhenNoRingCoversItAlone() throws {
        let capped = try XCTUnwrap(competitionWhatItTakes(
            takesCompetition(accepted: try takesRings(move: (1_200, 600), exercise: (15, 30))), locale: en
        ))
        XCTAssertEqual(capped.suggestion, "About 12 min of Exercise.")

        let split = try XCTUnwrap(competitionWhatItTakes(
            takesCompetition(
                user: 1_000, opponent: 1_049, today: 445,
                accepted: try takesRings(move: (1_020, 600), exercise: (52.5, 30), stand: (6, 12))
            ),
            locale: en
        ))
        XCTAssertEqual(split.headline, "50 to take the lead")
        XCTAssertEqual(split.suggestion, "About 180 kcal of Move and 6 min of Exercise.")
    }

    func testWhatItTakesHasNoPerRingCapInTheLocalFixture() throws {
        let snapshot = try takesRings(move: (1_500, 600), exercise: (24, 30), stand: (8, 12))
        let local = try XCTUnwrap(competitionWhatItTakes(
            takesCompetition(today: 396.7, accepted: snapshot, policy: .healthKitCompatibility), locale: en
        ))
        XCTAssertEqual(local.suggestion, "About 240 kcal of Move or 12 min of Exercise.")
        let remote = try XCTUnwrap(competitionWhatItTakes(
            takesCompetition(today: 396.7, accepted: snapshot, policy: .remoteWireV1), locale: en
        ))
        XCTAssertEqual(remote.suggestion, "About 12 min of Exercise.")
    }

    func testWhatItTakesNeedsAnAcceptedSnapshotThatMatchesTheLatest() throws {
        let a = try takesRings(move: (410, 600), exercise: (24, 30))
        let b = try takesRings(move: (450, 600), exercise: (24, 30))
        XCTAssertNil(competitionWhatItTakes(takesCompetition(accepted: nil, latest: a)))
        XCTAssertNil(competitionWhatItTakes(takesCompetition(accepted: nil)))
        XCTAssertNil(competitionWhatItTakes(takesCompetition(accepted: a, latest: b)))
        XCTAssertNotNil(competitionWhatItTakes(takesCompetition(accepted: a, latest: .some(nil))))
    }

    func testWhatItTakesDropsTheMovingTargetWhenTheyAreAtTodaysCap() throws {
        let snapshot = try takesRings(move: (410, 600), exercise: (24, 30))
        XCTAssertEqual(
            competitionWhatItTakes(takesCompetition(accepted: snapshot, opponentToday: 600), locale: en)?.detail,
            "About 240 kcal of Move or 12 min of Exercise."
        )
        XCTAssertEqual(
            competitionWhatItTakes(takesCompetition(accepted: snapshot, opponentToday: nil), locale: en)?.detail,
            "About 240 kcal of Move or 12 min of Exercise. Sam can still add points today."
        )
    }

    func testWhatItTakesRoundsAmountsUpGroupsByLocaleAndSpeaksSingularUnits() throws {
        let exact = try XCTUnwrap(competitionWhatItTakes(
            takesCompetition(user: 1_000, opponent: 1_029, accepted: try takesRings(move: (0, 600), exercise: (0, 30))),
            locale: en
        ))
        XCTAssertEqual(exact.suggestion, "About 180 kcal of Move or 9 min of Exercise.")

        // 7 / 100 * 100 is 7.000000000000001 in doubles; without the 1e-9 it reads 8 min.
        let epsilon = try XCTUnwrap(competitionWhatItTakes(
            takesCompetition(user: 1_000, opponent: 1_006, accepted: try takesRings(move: (0, 600), exercise: (0, 100))),
            locale: en
        ))
        XCTAssertEqual(epsilon.suggestion, "About 50 kcal of Move or 7 min of Exercise.")

        let big = takesCompetition(user: 1_000, opponent: 1_123, accepted: try takesRings(move: (0, 1_000), exercise: (0, 30)))
        XCTAssertEqual(competitionWhatItTakes(big, locale: en)?.suggestion, "About 1,240 kcal of Move or 38 min of Exercise.")
        XCTAssertEqual(
            competitionWhatItTakes(big, locale: Locale(identifier: "de_DE"))?.suggestion,
            "About 1.240 kcal of Move or 38 min of Exercise."
        )

        let one = try XCTUnwrap(competitionWhatItTakes(
            takesCompetition(user: 0, opponent: 0, accepted: try takesRings(move: (0, 100), exercise: (0, 100))),
            locale: en
        ))
        XCTAssertEqual(
            one.accessibilityLabel,
            "1 point to take the lead. About 10 kilocalories of Move or 1 minute of Exercise. Sam can still add points today."
        )
    }

    private var en: Locale { Locale(identifier: "en_US") }

    private func takesRings(
        move: (Double, Double),
        exercise: (Double, Double),
        stand: (Double, Double) = (8, 12),
        moveMinutes: Bool = false
    ) throws -> ActivitySnapshot {
        ActivitySnapshot(
            moveMode: moveMinutes ? .moveMinutes : .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: move.0, goal: move.1),
            exercise: try ActivityRingReading(value: exercise.0, goal: exercise.1),
            standOrRoll: try ActivityRingReading(value: stand.0, goal: stand.1),
            pauseState: .running
        )
    }

    /// One live day against "Sam". `latest` defaults to `accepted`; pass
    /// `.some(nil)` for no latest reading.
    private func takesCompetition(
        user: Double = 1_112,
        opponent: Double = 1_150,
        today: Double? = 215,
        accepted: ActivitySnapshot?,
        latest: ActivitySnapshot?? = .none,
        policy: ActivityScoringPolicy = .remoteWireV1,
        lifecycle: LocalCompetitionLifecyclePresentation = .active(dayOrdinal: 5),
        ordinal: Int? = 5,
        opponentToday: Double? = 248
    ) -> LocalCompetitionPresentation {
        let day = LocalCompetitionDayPresentation(
            day: try! CompetitionDay(era: 1, year: 2026, month: 8, day: 9, timeZoneIdentifier: "UTC"),
            ordinal: ordinal ?? 5,
            ownerAcceptedPoints: today,
            ownerLatestAvailability: .observed,
            opponentRevealedPoints: opponentToday,
            ownerAcceptedSnapshot: accepted,
            ownerLatestSnapshot: latest ?? accepted,
            scoringPolicy: policy
        )
        return LocalCompetitionPresentation(
            id: CompetitionID(UUID()),
            ownerDisplayName: "Naren",
            opponentDisplayName: "Sam",
            lifecycle: lifecycle,
            acceptedConfiguration: nil,
            userPoints: user,
            opponentPoints: opponent,
            days: [day],
            currentDayOrdinal: ordinal,
            lastRefresh: nil,
            tally: nil,
            terminalResult: nil
        )
    }

    private func rings(_ move: Double, _ exercise: Double, _ stand: Double) throws -> ActivitySnapshot {
        ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: move, goal: 500),
            exercise: try ActivityRingReading(value: exercise, goal: 30),
            standOrRoll: try ActivityRingReading(value: stand, goal: 12),
            pauseState: .running
        )
    }

    private func ringDay(
        accepted: ActivitySnapshot?,
        latest: ActivitySnapshot?,
        points: Double?,
        policy: ActivityScoringPolicy = .healthKitCompatibility
    ) -> LocalCompetitionDayPresentation {
        LocalCompetitionDayPresentation(
            day: try! CompetitionDay(era: 1, year: 2026, month: 8, day: 9, timeZoneIdentifier: "UTC"),
            ordinal: 1,
            ownerAcceptedPoints: points,
            ownerLatestAvailability: .observed,
            opponentRevealedPoints: 200,
            ownerAcceptedSnapshot: accepted,
            ownerLatestSnapshot: latest,
            scoringPolicy: policy
        )
    }

    func testTallyCopyNamesWhoItWaitsOnAndWhetherToAct() throws {
        let iso = ISO8601DateFormatter()
        let deadline = try XCTUnwrap(iso.date(from: "2026-11-05T08:00:00Z"))
        let now = try XCTUnwrap(iso.date(from: "2026-11-04T05:00:00Z"))
        let en = Locale(identifier: "en_US")
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        func copy(
            _ attention: LocalCompetitionTallyAttention?,
            deadline: Date = deadline,
            now: Date = now
        ) -> CompetitionTallyCopy {
            competitionTallyCopy(
                LocalCompetitionTallyPresentation(
                    attention: attention,
                    consecutiveStableCompleteReads: 0,
                    stabilityStart: nil,
                    bestAvailableDeadline: deadline
                ),
                opponentDisplayName: "Hermes",
                now: now,
                locale: en,
                timeZone: la
            )
        }
        let nothingToDo = "Nothing for you to do. If it isn’t done by Wed night, the result uses what’s in."
        let openAgain = "Open HealthComp again before Wed night, or the result uses what’s in."
        let expected: [(LocalCompetitionTallyAttention?, CompetitionTallyCopy)] = [
            (.opponentPlanUnavailable, CompetitionTallyCopy(
                headline: "Waiting for Hermes to sync",
                body: "If Hermes doesn’t sync by Wed night, the result uses what’s in."
            )),
            (.awaitingOpponentCheck, CompetitionTallyCopy(
                headline: "Waiting for Hermes’s last check",
                body: "If Hermes doesn’t open HealthComp by Wed night, the result uses what’s in."
            )),
            (.incomplete(missingOrdinals: [7], unavailableOrdinals: []), CompetitionTallyCopy(
                headline: "Waiting for your Day 7",
                body: "Day 7 hasn’t synced from this iPhone. \(openAgain)"
            )),
            (.incomplete(missingOrdinals: [5], unavailableOrdinals: [7]), CompetitionTallyCopy(
                headline: "Waiting for your Days 5 and 7",
                body: "HealthComp couldn’t read Days 5 and 7 on this iPhone. \(openAgain)"
            )),
            (.incomplete(missingOrdinals: Set(1...7), unavailableOrdinals: []), CompetitionTallyCopy(
                headline: "Waiting for your Activity",
                body: "7 days haven’t synced from this iPhone. \(openAgain)"
            )),
            (.unacceptedScores(ordinals: [3, 4]), CompetitionTallyCopy(
                headline: "Scoring your Days 3 and 4",
                body: nothingToDo
            )),
            (.noRead, CompetitionTallyCopy(
                headline: "Checking Activity on this iPhone",
                body: nothingToDo
            )),
            (.awaitingStability, CompetitionTallyCopy(
                headline: "Checking the last scores",
                body: "Nothing for you to do. The result is final by Wed night at the latest."
            )),
            (nil, CompetitionTallyCopy(
                headline: "Checking the last scores",
                body: "Nothing for you to do. The result is final by Wed night at the latest."
            )),
        ]
        for (attention, wanted) in expected {
            let actual = copy(attention)
            XCTAssertEqual(actual, wanted, "\(String(describing: attention))")
            for text in [actual.headline, actual.body] {
                for jargon in ["days 7", "Missing days", "best available", "stable read"] {
                    XCTAssertFalse(text.contains(jargon), text)
                }
            }
        }
        XCTAssertFalse(copy(.opponentPlanUnavailable).body.contains("your"))
        XCTAssertFalse(copy(.awaitingOpponentCheck).body.contains("your"))

        XCTAssertEqual(
            copy(.incomplete(missingOrdinals: [7], unavailableOrdinals: []), now: deadline),
            CompetitionTallyCopy(
                headline: "Finishing the result",
                body: "The deadline passed, so the result uses what’s in. It appears here shortly."
            )
        )
        let evening = try XCTUnwrap(iso.date(from: "2026-11-05T05:00:00Z"))
        XCTAssertTrue(
            normalized(copy(.opponentPlanUnavailable, deadline: evening).body)
                .contains("by Wed 9:00 PM"),
            copy(.opponentPlanUnavailable, deadline: evening).body
        )
        XCTAssertEqual(competitionScoreTotalLabel(isProvisional: true), "Provisional total")
    }

    private func nudgePresentation(
        lifecycle: LocalCompetitionLifecyclePresentation,
        attention: LocalCompetitionTallyAttention? = nil,
        deadline: Date = .distantFuture,
        evaluatedAt: Date,
        opponentUpdatedAt: Date?,
        dayOneStart: Date? = nil,
        zone: String = "UTC"
    ) -> LocalCompetitionPresentation {
        let schedule = dayOneStart.map { start -> CompetitionSchedule in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            let parts = calendar.dateComponents([.year, .month, .day], from: start)
            return CompetitionSchedule(
                calendar: try! CompetitionCalendar(timeZoneIdentifier: zone),
                startDay: try! CompetitionDay(
                    era: 1, year: parts.year!, month: parts.month!, day: parts.day!,
                    timeZoneIdentifier: zone
                )
            )
        }
        let tally: LocalCompetitionTallyPresentation? = if case .tallying = lifecycle {
            LocalCompetitionTallyPresentation(
                attention: attention,
                consecutiveStableCompleteReads: 0,
                stabilityStart: nil,
                bestAvailableDeadline: deadline
            )
        } else {
            nil
        }
        return LocalCompetitionPresentation(
            id: CompetitionID(UUID()),
            ownerDisplayName: "Naren",
            opponentDisplayName: "Sam",
            lifecycle: lifecycle,
            acceptedConfiguration: schedule.map {
                LocalCompetitionAcceptedPresentation(schedule: $0, difficulty: .balanced)
            },
            userPoints: 0,
            opponentPoints: 0,
            days: [],
            currentDayOrdinal: nil,
            lastRefresh: nil,
            tally: tally,
            terminalResult: nil,
            evaluatedAt: evaluatedAt,
            timeZoneIdentifier: zone,
            opponentUpdatedAt: opponentUpdatedAt
        )
    }

    func testNudgeIsOfferedWhenTheResultWaitsOnTheOtherPerson() {
        let now = Date(timeIntervalSince1970: 1_786_979_520)
        func canNudge(
            _ attention: LocalCompetitionTallyAttention?,
            deadline: Date = Date(timeIntervalSince1970: 1_786_979_520 + 86_400)
        ) -> Bool {
            competitionCanNudge(nudgePresentation(
                lifecycle: .tallying(startedAt: now),
                attention: attention,
                deadline: deadline,
                evaluatedAt: now,
                opponentUpdatedAt: now
            ))
        }
        XCTAssertTrue(canNudge(.awaitingOpponentCheck))
        XCTAssertTrue(canNudge(.opponentPlanUnavailable))
        XCTAssertFalse(canNudge(.awaitingStability))
        XCTAssertFalse(canNudge(.incomplete(missingOrdinals: [7], unavailableOrdinals: [])))
        XCTAssertFalse(canNudge(.noRead))
        XCTAssertFalse(canNudge(nil))
        XCTAssertFalse(canNudge(.awaitingOpponentCheck, deadline: now))
        XCTAssertFalse(canNudge(.awaitingOpponentCheck, deadline: now.addingTimeInterval(-1)))
    }

    func testNudgeIsOfferedWhenALiveMatchIsTwelveHoursStale() {
        let now = Date(timeIntervalSince1970: 1_786_979_520)
        func canNudge(
            _ lifecycle: LocalCompetitionLifecyclePresentation = .active(dayOrdinal: 2),
            updatedAgo: TimeInterval?,
            dayOneAgo: TimeInterval? = nil
        ) -> Bool {
            competitionCanNudge(nudgePresentation(
                lifecycle: lifecycle,
                evaluatedAt: now,
                opponentUpdatedAt: updatedAgo.map { now.addingTimeInterval(-$0) },
                dayOneStart: dayOneAgo.map { now.addingTimeInterval(-$0) }
            ))
        }
        XCTAssertTrue(canNudge(updatedAgo: 12 * 3_600 + 60))
        XCTAssertFalse(canNudge(updatedAgo: 12 * 3_600))
        XCTAssertFalse(canNudge(updatedAgo: 12 * 3_600 - 60))
        XCTAssertTrue(canNudge(.endsToday, updatedAgo: 13 * 3_600))
        // Never uploaded: counted from Day 1's midnight (Aug 17, 15 h 12 m ago).
        XCTAssertTrue(canNudge(updatedAgo: nil, dayOneAgo: 13 * 3_600))
        XCTAssertFalse(canNudge(updatedAgo: nil, dayOneAgo: nil))
        XCTAssertFalse(canNudge(.scheduled, updatedAgo: 13 * 3_600))
        XCTAssertFalse(
            canNudge(.completed(outcome: .win, basis: .bestAvailable, completedAt: now), updatedAgo: 13 * 3_600)
        )
        // Day 1 started 2 hours ago.
        let early = Date(timeIntervalSince1970: 1_786_924_800 + 2 * 3_600)
        XCTAssertFalse(competitionCanNudge(nudgePresentation(
            lifecycle: .active(dayOrdinal: 1),
            evaluatedAt: early,
            opponentUpdatedAt: nil,
            dayOneStart: early
        )))
    }

    func testNudgeConfirmationLastsUntilTheMatchDayEnds() throws {
        let en = Locale(identifier: "en_US")
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let sentAt = Date(timeIntervalSince1970: 1_786_979_520)
        func display(at now: TimeInterval) -> CompetitionNudgeDisplay? {
            competitionNudgeDisplay(
                .sent(sentAt),
                competition: nudgePresentation(
                    lifecycle: .active(dayOrdinal: 3),
                    evaluatedAt: Date(timeIntervalSince1970: now),
                    opponentUpdatedAt: sentAt.addingTimeInterval(-86_400),
                    zone: "America/Los_Angeles"
                ),
                locale: en,
                timeZone: utc
            )
        }
        func sentText(_ display: CompetitionNudgeDisplay?) -> String? {
            if case let .sent(text)? = display { return normalized(text) }
            return nil
        }
        XCTAssertEqual(
            sentText(display(at: 1_787_007_600)),
            "Nudged at 3:12 PM. You can nudge again tomorrow."
        )
        XCTAssertEqual(
            sentText(display(at: 1_787_032_800)),
            "Nudged at Mon 3:12 PM. You can nudge again tomorrow."
        )
        XCTAssertEqual(display(at: 1_787_038_200), .button(error: nil, isSending: false))
    }

    func testNudgeSentAfterMidnightOnTheServerStillShowsAsSent() throws {
        let en = Locale(identifier: "en_US")
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        // The last projection is Sat 11:50 PM in Los Angeles; the server
        // accepted the nudge at Sun 12:01 AM.
        let projected = Date(timeIntervalSince1970: 1_786_863_000)
        let nudgedAt = projected.addingTimeInterval(11 * 60)
        let display = competitionNudgeDisplay(
            .sent(nudgedAt),
            competition: nudgePresentation(
                lifecycle: .active(dayOrdinal: 3),
                evaluatedAt: projected,
                opponentUpdatedAt: projected.addingTimeInterval(-86_400),
                zone: "America/Los_Angeles"
            ),
            locale: en,
            timeZone: zone
        )
        guard case let .sent(text)? = display else {
            return XCTFail("Expected the confirmation, got \(String(describing: display))")
        }
        XCTAssertEqual(normalized(text), "Nudged at 12:01 AM. You can nudge again tomorrow.")
    }

    func testNudgeFailureAndRefusalCopy() {
        let now = Date(timeIntervalSince1970: 1_786_979_520)
        let stale = nudgePresentation(
            lifecycle: .active(dayOrdinal: 2),
            evaluatedAt: now,
            opponentUpdatedAt: now.addingTimeInterval(-13 * 3_600)
        )
        XCTAssertEqual(
            competitionNudgeDisplay(.failed, competition: stale),
            .button(error: "Couldn’t send the nudge. Try again.", isSending: false)
        )
        XCTAssertEqual(
            competitionNudgeDisplay(.notNeeded(now), competition: stale),
            .notNeeded("Sam doesn’t need a nudge right now.")
        )
        XCTAssertEqual(
            competitionNudgeDisplay(.sending, competition: stale),
            .button(error: nil, isSending: true)
        )
        XCTAssertEqual(competitionNudgeDisplay(nil, competition: stale), .button(error: nil, isSending: false))
        // A refusal from yesterday no longer applies.
        XCTAssertEqual(
            competitionNudgeDisplay(.notNeeded(now.addingTimeInterval(-86_400)), competition: stale),
            .button(error: nil, isSending: false)
        )
        // Once they update, the whole control goes, confirmation included.
        let fresh = nudgePresentation(
            lifecycle: .active(dayOrdinal: 2),
            evaluatedAt: now,
            opponentUpdatedAt: now.addingTimeInterval(-60)
        )
        XCTAssertNil(competitionNudgeDisplay(.sent(now), competition: fresh))
    }

    func testLeadLineIsTheMarginAfterEachEndedDayWithAChangeAtEveryCrossing() throws {
        func day(_ ordinal: Int, _ you: Double?, _ them: Double?, occurred: Bool = true) -> LocalCompetitionDayPresentation {
            LocalCompetitionDayPresentation(
                day: try! CompetitionDay(era: 1, year: 2026, month: 8, day: ordinal, timeZoneIdentifier: "UTC"),
                ordinal: ordinal,
                ownerAcceptedPoints: you,
                ownerLatestAvailability: occurred ? .observed : .notYetOccurred,
                opponentRevealedPoints: them
            )
        }
        // Today (Day 7) waits until it ends.
        let week = [
            day(1, 124, 100), day(2, 100, 137), day(3, 100, 107), day(4, 130, 100),
            day(5, 100, 128), day(6, 166, 100), day(7, 300, 0),
        ]
        let line = try XCTUnwrap(competitionLeadLine(week, currentDayOrdinal: 7))
        XCTAssertEqual(line.margins, [0, 24, -13, -20, 10, -18, 48])
        XCTAssertEqual(line.changes.count, 4)
        for (change, expected) in zip(line.changes, [1 + 24.0 / 37, 3 + 20.0 / 30, 4 + 10.0 / 28, 5 + 18.0 / 66]) {
            XCTAssertEqual(change, expected, accuracy: 0.0001)
        }

        // Through a tie, the change sits on the tie; a missing score counts 0
        // and the line stops at the first day that hasn't happened.
        let tied = try XCTUnwrap(competitionLeadLine(
            [day(1, 110, 100), day(2, 90, 100), day(3, nil, 5), day(4, nil, nil, occurred: false)],
            currentDayOrdinal: nil
        ))
        XCTAssertEqual(tied.margins, [0, 10, 0, -5])
        XCTAssertEqual(tied.changes, [2])

        XCTAssertNil(competitionLeadLine([day(1, 50, 0)], currentDayOrdinal: 1))
    }

    func testDayListTextIsSingularPluralAndCapped() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(competitionDayListText([7], locale: en), "Day 7")
        XCTAssertEqual(competitionDayListText([7, 5], locale: en), "Days 5 and 7")
        XCTAssertEqual(competitionDayListText([3, 5, 7], locale: en), "Days 3, 5, and 7")
        XCTAssertNil(competitionDayListText([1, 2, 3, 4], locale: en))
        XCTAssertNil(competitionDayListText([], locale: en))
    }

    func testTallyingStatusShowsFinalScorePendingAndDeadline() throws {
        let iso = ISO8601DateFormatter()
        let deadline = try XCTUnwrap(iso.date(from: "2026-11-05T08:00:00Z"))
        let now = try XCTUnwrap(iso.date(from: "2026-11-04T05:00:00Z"))
        let en = Locale(identifier: "en_US")
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        func tallying(evaluatedAt: Date) -> LocalCompetitionPresentation {
            LocalCompetitionPresentation(
                id: CompetitionID(UUID()),
                ownerDisplayName: "Naren",
                opponentDisplayName: "Hermes",
                lifecycle: .tallying(startedAt: now),
                acceptedConfiguration: nil,
                userPoints: 3_413,
                opponentPoints: 3_398,
                days: [],
                currentDayOrdinal: nil,
                lastRefresh: nil,
                tally: LocalCompetitionTallyPresentation(
                    attention: .awaitingStability,
                    consecutiveStableCompleteReads: 0,
                    stabilityStart: nil,
                    bestAvailableDeadline: deadline
                ),
                terminalResult: nil,
                evaluatedAt: evaluatedAt
            )
        }
        let before = tallying(evaluatedAt: now)
        XCTAssertEqual(
            competitionStatusText(before, style: .card, locale: en, timeZone: la),
            CompetitionStatusText(title: "Final score pending", timing: "By Wed night")
        )
        XCTAssertEqual(
            competitionStatusText(before, style: .row, locale: en, timeZone: la).line,
            "Final score pending · By Wed night"
        )
        XCTAssertNil(
            competitionStatusText(before, style: .notification, locale: en, timeZone: la).timing
        )
        XCTAssertNil(
            competitionStatusText(
                tallying(evaluatedAt: deadline), style: .card, locale: en, timeZone: la
            ).timing
        )
    }

    func testDayOutcomeSeparatesWonLostTiedNoDataUpcomingToday() {
        func day(
            _ owner: Double?,
            _ opponent: Double?,
            availability: LocalCompetitionOwnerAvailability = .observed
        ) -> LocalCompetitionDayPresentation {
            LocalCompetitionDayPresentation(
                day: presentation(.observed, points: nil).day,
                ordinal: 2,
                ownerAcceptedPoints: owner,
                ownerLatestAvailability: availability,
                opponentRevealedPoints: opponent
            )
        }
        XCTAssertEqual(competitionDayOutcome(day(320, 300), currentDayOrdinal: nil), .won)
        XCTAssertEqual(competitionDayOutcome(day(300, 320), currentDayOrdinal: nil), .lost)
        XCTAssertEqual(competitionDayOutcome(day(300.4, 300.2), currentDayOrdinal: nil), .tied)
        XCTAssertEqual(competitionDayOutcome(day(0, 0), currentDayOrdinal: nil), .noData)
        XCTAssertEqual(competitionDayOutcome(day(320, nil), currentDayOrdinal: nil), .noData)
        XCTAssertEqual(
            competitionDayOutcome(day(nil, 300, availability: .missing), currentDayOrdinal: nil),
            .noData
        )
        XCTAssertEqual(
            competitionDayOutcome(day(nil, nil, availability: .notYetOccurred), currentDayOrdinal: nil),
            .upcoming
        )
        XCTAssertEqual(competitionDayOutcome(day(320, 300), currentDayOrdinal: 2), .today)
    }

    func testResultTitlesNameTheOtherPerson() {
        XCTAssertEqual(competitionResultTitle(outcome: .win, opponentDisplayName: "Hermes"), "You beat Hermes")
        XCTAssertEqual(competitionResultTitle(outcome: .loss, opponentDisplayName: "Hermes"), "Hermes won")
        XCTAssertEqual(competitionResultTitle(outcome: .tie, opponentDisplayName: "Hermes"), "All square with Hermes")
    }

    func testDaysSummarySplitsWonLostTiedAndSkipsMissingDays() {
        func day(_ owner: Double?, _ opponent: Double?) -> LocalCompetitionDayPresentation {
            LocalCompetitionDayPresentation(
                day: presentation(.observed, points: nil).day,
                ordinal: 1,
                ownerAcceptedPoints: owner,
                ownerLatestAvailability: owner == nil ? .missing : .observed,
                opponentRevealedPoints: opponent
            )
        }
        let won = day(320, 300), lost = day(300, 320), tied = day(300, 300)
        XCTAssertEqual(
            competitionDaysSummaryText([won, won, lost, lost, lost, lost, tied]),
            "won 2 days, lost 4, tied 1"
        )
        XCTAssertEqual(
            competitionDaysSummaryText([won, won, won, won, won, day(320, nil), day(0, 0)]),
            "won 5 days"
        )
        XCTAssertEqual(
            competitionDaysSummaryText([lost] + Array(repeating: day(nil, nil), count: 6)),
            "lost 1 day"
        )
        XCTAssertEqual(competitionDaysSummaryText(Array(repeating: tied, count: 7)), "tied 7 days")
        XCTAssertNil(competitionDaysSummaryText(Array(repeating: day(nil, 300), count: 7)))
    }

    func testMuteFailureTextNamesThePersonAndAction() {
        XCTAssertEqual(
            competitionMuteFailureText(.load, opponentName: "Hermes"),
            "Couldn’t check whether Hermes is muted."
        )
        XCTAssertEqual(
            competitionMuteFailureText(.mute, opponentName: "Hermes"),
            "Couldn’t mute Hermes. Try again from the More menu."
        )
        XCTAssertEqual(
            competitionMuteFailureText(.unmute, opponentName: "Hermes"),
            "Couldn’t unmute Hermes. Try again from the More menu."
        )
    }

    func testDayAccessibilityNamesTodayProgressClosedDateAndUpcomingState() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-31T12:00:00Z"))
        let en = Locale(identifier: "en_US")
        let observed = presentation(.observed, points: 321)
        let today = competitionDayAccessibilityLabel(
            observed,
            currentDayOrdinal: observed.ordinal,
            opponentName: "Alex",
            now: now,
            locale: en
        )
        XCTAssertTrue(today.contains("Day 2, Today, scores so far. You, 321 points."), today)

        let closed = competitionDayAccessibilityLabel(
            observed,
            currentDayOrdinal: nil,
            opponentName: "Alex",
            now: now,
            locale: en
        )
        XCTAssertTrue(closed.contains("Day 2, Sun, Aug 9, complete."), closed)
        XCTAssertTrue(closed.contains("You, 321 points"), closed)

        let future = competitionDayAccessibilityLabel(
            presentation(.notYetOccurred, points: nil),
            currentDayOrdinal: nil,
            opponentName: "Alex",
            now: now,
            locale: en
        )
        XCTAssertEqual(future, "Day 2, Sun, Aug 9, upcoming.")
        for label in [today, closed, future] {
            XCTAssertFalse(label.contains("--"), label)
        }
    }

    func testClosedDayWithoutOpponentScoreIsUnavailableRatherThanFuture() {
        let label = competitionDayAccessibilityLabel(
            presentation(.observed, points: 321),
            currentDayOrdinal: nil,
            opponentName: "Opponent"
        )

        XCTAssertTrue(label.contains("complete"))
        XCTAssertTrue(label.contains("Opponent, not synced."), label)
        XCTAssertFalse(label.contains("upcoming"))
        XCTAssertFalse(label.contains("--"))

        let base = presentation(.observed, points: 321)
        let reportedNoData = competitionDayAccessibilityLabel(
            LocalCompetitionDayPresentation(
                day: base.day,
                ordinal: base.ordinal,
                ownerAcceptedPoints: 321,
                ownerLatestAvailability: .observed,
                opponentRevealedPoints: nil,
                opponentReportedNoData: true
            ),
            currentDayOrdinal: nil,
            opponentName: "Opponent"
        )
        XCTAssertTrue(reportedNoData.contains("Opponent, no data."), reportedNoData)
    }

    func testRingPartsAddUpToTheDayTotal() {
        let total = 232.0
        let shares = [0.84, 22.0 / 30, 0.75]
        let parts = shares.map { total * $0 / shares.reduce(0, +) }
        let shown = competitionRoundedParts(parts, total: total)
        XCTAssertEqual(shown.reduce(0, +), 232)
        for part in shown {
            XCTAssertEqual(part, part.rounded(), "\(part) is not whole")
        }
    }

    func testTallyCallsTheLastDayDay7() {
        XCTAssertEqual(
            competitionScorePeriodLabel(.tallying(startedAt: .distantPast)),
            "Day 7"
        )
        XCTAssertEqual(
            competitionScorePeriodLabel(.active(dayOrdinal: 3)),
            "Today"
        )
        XCTAssertEqual(competitionScorePeriodLabel(.endsToday), "Today")
    }

    func testAwardsAreWinsOnlyNewestFirstWithOpponentIdentity() {
        let first = homePresentation(
            id: 101, name: "Hermes", identity: "remote-profile:v1:hermes",
            lifecycle: .completed(outcome: .win, basis: .stableAcrossPostBoundaryReads,
                                  completedAt: Date(timeIntervalSinceReferenceDate: 0))
        )
        let second = homePresentation(
            id: 102, name: "Andy",
            lifecycle: .completed(outcome: .loss, basis: .stableAcrossPostBoundaryReads,
                                  completedAt: Date(timeIntervalSinceReferenceDate: 86_400))
        )
        let third = homePresentation(
            id: 103, name: "Andy", identity: "remote-profile:v1:andy",
            lifecycle: .completed(outcome: .win, basis: .stableAcrossPostBoundaryReads,
                                  completedAt: Date(timeIntervalSinceReferenceDate: 172_800))
        )
        let awards = LocalCompetitionAward.fold(completed: [first, second, third])

        XCTAssertEqual(awards.map(\.competitionID), [third.id, first.id])
        XCTAssertEqual(awards.map(\.friendDisplayName), ["Andy", "Hermes"])
        XCTAssertEqual(
            awards.map(\.opponentIdentity),
            ["remote-profile:v1:andy", "remote-profile:v1:hermes"]
        )
        XCTAssertEqual(
            competitionSharingIdentifier(first),
            "competition.sharing.completed.00000000-0000-0000-0000-000000000101"
        )
    }

    // MARK: Belt

    private func beltWeek(
        _ id: Int,
        _ outcome: CompetitionOutcome,
        start: (Int, Int),
        name: String = "Sam",
        identity: String = "remote-profile:v1:sam"
    ) -> LocalCompetitionPresentation {
        homePresentation(
            id: id, name: name, identity: identity,
            lifecycle: .archived(outcome: outcome, basis: .stableAcrossPostBoundaryReads,
                                 completedAt: homeNow, archivedAt: homeNow),
            start: start
        )
    }

    private func beltRecord(_ weeks: [LocalCompetitionPresentation]) -> CompetitionOpponentRecord? {
        competitionOpponentRecords(weeks).first
    }

    func testWatchBeltCountsDefensesAndCardsPerResult() throws {
        let outcomes: [CompetitionOutcome] = [.win, .win, .tie, .win, .loss, .loss, .win]
        let starts = [(8, 4), (8, 11), (8, 18), (8, 25), (9, 1), (9, 8), (9, 15)]
        let weeks = outcomes.indices.map { beltWeek($0 + 1, outcomes[$0], start: starts[$0]) }
        func belt(_ index: Int, of all: [LocalCompetitionPresentation]) -> CompetitionWidgetSnapshot.Belt? {
            CompetitionWidgetSnapshot.Belt(for: all[index], records: competitionOpponentRecords(all), in: all)
        }

        let cards: [CompetitionWidgetSnapshot.Belt.Card?] = weeks.indices.map { belt($0, of: weeks)?.card }
        XCTAssertEqual(cards, [
            .earned,
            .defended(1),
            nil,  // a tie keeps the belt but isn't a defense
            .defended(2),
            .lost(weeks: 4, defenses: 2),
            nil,  // their defense earns you no card
            .taken(weeks: 2, defenses: 1),
        ])
        XCTAssertEqual(belt(6, of: weeks)?.holder, .you)
        XCTAssertEqual(belt(6, of: weeks)?.defenses, 0)

        let stillTheirs = Array(weeks.prefix(6))
        XCTAssertEqual(belt(5, of: stillTheirs)?.holder, .them)
        XCTAssertEqual(belt(5, of: stillTheirs)?.defenses, 1)
    }

    func testWatchBeltHasNoRowWhenVacantOrRetired() {
        let vacant = [beltWeek(1, .tie, start: (9, 1))]
        XCTAssertNil(CompetitionWidgetSnapshot.Belt(
            for: vacant[0], records: competitionOpponentRecords(vacant), in: vacant
        ))
        let retired = [beltWeek(1, .win, start: (9, 1), name: "Former competitor")]
        XCTAssertNil(CompetitionWidgetSnapshot.Belt(
            for: retired[0], records: competitionOpponentRecords(retired), in: retired
        ))
    }

    func testBeltGoesToTheFirstWinnerAndTiesLeaveIt() throws {
        let outcomes: [CompetitionOutcome] = [.tie, .win, .tie, .loss, .loss, .win]
        let starts = [(9, 1), (9, 8), (9, 15), (9, 22), (9, 29), (10, 6)]
        let weeks = outcomes.indices.map { beltWeek($0 + 1, outcomes[$0], start: starts[$0]) }
        let belt = try XCTUnwrap(beltRecord(weeks)).belt

        XCTAssertEqual(weeks.map { belt.events[$0.id] }, [
            .vacant,
            .took(by: .you, fromWeeks: nil),
            .kept(by: .you, weeks: 2),
            .took(by: .them, fromWeeks: 2),
            .defended(by: .them, weeks: 2, defenses: 1),
            .took(by: .you, fromWeeks: 2, fromDefenses: 1),
        ])
        XCTAssertEqual(belt.holder, .you)
        XCTAssertEqual(belt.current, CompetitionBeltReign(holder: .you, weeks: 1, startID: weeks[5].id))
        XCTAssertEqual(belt.changes, 3)
        // On equal length the more recent reign is the longest.
        XCTAssertEqual(
            belt.longest,
            CompetitionBeltReign(holder: .them, weeks: 2, startID: weeks[3].id, defenses: 1)
        )
    }

    func testBeltWithOnlyTiesHasNoHolder() throws {
        let weeks = [beltWeek(1, .tie, start: (9, 1)), beltWeek(2, .tie, start: (9, 8))]
        let belt = try XCTUnwrap(beltRecord(weeks)).belt

        XCTAssertNil(belt.holder)
        XCTAssertEqual(weeks.map { belt.events[$0.id] }, [.vacant, .vacant])
        XCTAssertEqual(belt.changes, 0)
    }

    func testBeltRetiresForAFormerCompetitor() throws {
        let weeks = [
            beltWeek(1, .win, start: (9, 1), name: "Former competitor"),
            beltWeek(2, .loss, start: (9, 8), name: "Former competitor"),
            beltWeek(3, .loss, start: (9, 15), name: "Former competitor"),
        ]
        let belt = try XCTUnwrap(beltRecord(weeks)).belt

        XCTAssertTrue(belt.isRetired)
        XCTAssertNil(belt.holder)
        XCTAssertEqual(belt.events.count, 3)
        XCTAssertEqual(
            belt.longest,
            CompetitionBeltReign(holder: .them, weeks: 2, startID: weeks[1].id, defenses: 1)
        )
        XCTAssertEqual(competitionBeltEvent(for: weeks[0], in: weeks), .took(by: .you, fromWeeks: nil))
    }

    func testBeltOrdersWeeksByEndThenID() throws {
        // Weeks 3 and 4 share an end; they fold in uuid order (3, then 4).
        let weeks = [
            beltWeek(4, .loss, start: (9, 8)),
            beltWeek(1, .win, start: (9, 1)),
            beltWeek(5, .win, start: (9, 15)),
            beltWeek(3, .win, start: (9, 8)),
        ]
        let closed = [
            homePresentation(id: 6, name: "Sam", identity: "remote-profile:v1:sam",
                             lifecycle: .cancelled(at: homeNow), start: (9, 22)),
            homePresentation(id: 7, name: "Sam", identity: "remote-profile:v1:sam",
                             lifecycle: .declined(at: homeNow, direction: .outgoing), start: (9, 29)),
            homePresentation(id: 8, name: "Sam", identity: "remote-profile:v1:sam",
                             lifecycle: .expired(at: homeNow, direction: .outgoing), start: (10, 6)),
        ]
        let record = try XCTUnwrap(beltRecord(weeks + closed))

        XCTAssertEqual(record.belt.events[weeks[3].id], .defended(by: .you, weeks: 2, defenses: 1))
        XCTAssertEqual(record.belt.events[weeks[0].id], .took(by: .them, fromWeeks: 2, fromDefenses: 1))
        XCTAssertEqual(record.belt.events[weeks[2].id], .took(by: .you, fromWeeks: 1))
        XCTAssertEqual(record.belt.events.count, 4)
        let direct = competitionBelt(weeks.reversed().map { week in
            (
                id: week.id,
                end: competitionScheduleBoundaries(week.acceptedConfiguration!.schedule)?.end,
                outcome: week.terminalResult!.outcome,
                margin: 0
            )
        })
        XCTAssertEqual(record.belt, direct)
        XCTAssertEqual(beltRecord(weeks)?.belt, direct)
    }

    private func titleFold(_ outcomes: [(CompetitionOutcome, Double)]) -> (
        belt: CompetitionBelt,
        events: [CompetitionBeltEvent?]
    ) {
        let weeks = outcomes.enumerated().map { index, week in
            (
                id: CompetitionID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", index))!),
                end: Date?.some(homeNow.addingTimeInterval(Double(index) * 604_800)),
                outcome: week.0,
                margin: week.1
            )
        }
        let belt = competitionBelt(weeks)
        return (belt, weeks.map { belt.events[$0.id] })
    }

    func testTitleDefenseIsAWinWhileHoldingTheBelt() {
        let (belt, events) = titleFold([(.win, 10), (.tie, 0), (.win, 20), (.tie, 0), (.win, 5)])

        XCTAssertEqual(events, [
            .took(by: .you, fromWeeks: nil),
            .kept(by: .you, weeks: 2),
            .defended(by: .you, weeks: 3, defenses: 1),
            .kept(by: .you, weeks: 4),
            .defended(by: .you, weeks: 5, defenses: 2),
        ])
        XCTAssertEqual(belt.current?.weeks, 5)
        XCTAssertEqual(belt.current?.defenses, 2)
        XCTAssertEqual(belt.you.defenses, 2)
    }

    func testTitleDefensesResetEachReignAndTotalAcrossReigns() {
        let (belt, events) = titleFold([
            (.win, 10), (.win, 10), (.win, 40),
            (.loss, 25), (.tie, 0), (.loss, 30),
            (.win, 15), (.win, 20),
        ])

        XCTAssertEqual(events[3], .took(by: .them, fromWeeks: 3, fromDefenses: 2))
        XCTAssertEqual(events[5], .defended(by: .them, weeks: 3, defenses: 1))
        XCTAssertEqual(events[6], .took(by: .you, fromWeeks: 3, fromDefenses: 1))
        XCTAssertEqual(events[7], .defended(by: .you, weeks: 2, defenses: 1))
        XCTAssertEqual(belt.current?.defenses, 1)
        XCTAssertEqual(belt.mostDefenses?.defenses, 2)
        XCTAssertEqual(belt.mostDefenses?.holder, .you)
        XCTAssertEqual(
            belt.you,
            CompetitionTitleStats(
                wins: 5, losses: 2, ties: 1, reigns: 2, defenses: 3,
                mostDefenses: 2, longestReign: 3, biggestWin: 40
            )
        )
        XCTAssertEqual(
            belt.them,
            CompetitionTitleStats(
                wins: 2, losses: 5, ties: 1, reigns: 1, defenses: 1,
                mostDefenses: 1, longestReign: 3, biggestWin: 30
            )
        )
    }

    func testMostDefensesIsNilUntilADefenseAndTheMoreRecentReignWinsATie() {
        XCTAssertNil(titleFold([(.win, 1), (.tie, 0), (.loss, 1)]).belt.mostDefenses)

        let belt = titleFold([(.win, 1), (.win, 1), (.loss, 1), (.loss, 1)]).belt
        XCTAssertEqual(belt.mostDefenses?.holder, .them)
    }

    func testTitleStatsStartEmpty() {
        let (belt, events) = titleFold([(.tie, 0)])

        XCTAssertEqual(events, [.vacant])
        XCTAssertEqual(belt.you, CompetitionTitleStats(ties: 1))
        XCTAssertEqual(belt.them, CompetitionTitleStats(ties: 1))
        XCTAssertEqual(CompetitionBelt.vacant.you, CompetitionTitleStats())
    }

    func testTitleStatsExcludePractice() throws {
        let won = LocalCompetitionLifecyclePresentation.completed(
            outcome: .win, basis: .stableAcrossPostBoundaryReads, completedAt: homeNow
        )
        let practice = practicePresentation(id: 1, lifecycle: won, start: (10, 14))
        let real = beltWeek(2, .win, start: (10, 21))

        let records = competitionOpponentRecords([practice, real])
        XCTAssertEqual(records.map(\.opponentIdentity), [real.opponentIdentity])
        let belt = try XCTUnwrap(records.first).belt
        XCTAssertEqual(belt.you.wins, 1)
        XCTAssertEqual(belt.you.reigns, 1)
        XCTAssertEqual(belt.events.count, 1)
    }

    func testHomeChipCountsDefensesFromTheFirst() {
        func chip(_ outcomes: [(CompetitionOutcome, Double)]) -> String? {
            competitionBeltChipText(titleFold(outcomes).belt, opponentName: "Sam")
        }
        XCTAssertNil(chip([(.tie, 0)]))
        XCTAssertEqual(chip([(.win, 1), (.tie, 0)]), "You hold the belt")
        XCTAssertEqual(chip([(.win, 1), (.win, 1)]), "You hold the belt · 1 defense")
        XCTAssertEqual(chip([(.loss, 1), (.loss, 1), (.loss, 1)]), "Sam holds the belt · 2 defenses")
        // A new reign starts the count again.
        XCTAssertEqual(chip([(.win, 1), (.win, 1), (.loss, 1)]), "Sam holds the belt")
    }

    func testTaleOfTheTapeReadsBothSides() {
        let belt = titleFold([(.win, 412.4), (.win, 10), (.tie, 0), (.loss, 268), (.loss, 1)]).belt
        let rows = competitionTaleOfTheTape(belt)

        XCTAssertEqual(rows.map(\.label), [
            "Record", "Title reigns", "Title defenses", "Most defenses", "Longest reign", "Biggest win",
        ])
        XCTAssertEqual(rows.map(\.you), ["2–2–1", "1", "1", "1", "3 weeks", "+412"])
        XCTAssertEqual(rows.map(\.them), ["2–2–1", "1", "1", "1", "2 weeks", "+268"])
        XCTAssertEqual(
            competitionTaleOfTheTape(titleFold([(.win, 5)]).belt).map(\.them),
            ["0–1", "0", "0", "0", "0 weeks", "–"]
        )
    }

    func testCeremonyForEachEventAndNothingElse() {
        func script(_ event: CompetitionBeltEvent?, _ name: String = "Sam") -> CompetitionBeltCeremonyScript? {
            competitionBeltCeremonyScript(event, opponentName: name)
        }
        XCTAssertEqual(
            script(.took(by: .you, fromWeeks: nil)),
            .init(clip: "earned", headline: "AND NEW", title: "You took the belt")
        )
        XCTAssertEqual(
            script(.took(by: .you, fromWeeks: 4, fromDefenses: 2)),
            .init(
                clip: "taken",
                headline: "AND NEW",
                title: "You took the belt from Sam",
                detail: "Sam's reign: 4 weeks · 2 defenses"
            )
        )
        XCTAssertEqual(
            script(.took(by: .them, fromWeeks: 1, fromDefenses: 0)),
            .init(
                clip: "lost",
                headline: "AND NEW",
                title: "Sam took the belt",
                detail: "Your reign: 1 week",
                isYours: false
            )
        )
        let defended = script(.defended(by: .you, weeks: 4, defenses: 3))
        XCTAssertEqual(
            defended,
            .init(clip: "defended", headline: "AND STILL", title: "3rd title defense", defenses: 3)
        )
        XCTAssertEqual(defended?.announcement, "AND STILL. 3rd title defense. 3 defenses")

        XCTAssertNil(script(.took(by: .them, fromWeeks: nil)))
        XCTAssertNil(script(.defended(by: .them, weeks: 2, defenses: 1)))
        XCTAssertNil(script(.kept(by: .you, weeks: 4)))
        XCTAssertNil(script(.vacant))
        XCTAssertNil(script(nil))
        XCTAssertNil(script(.took(by: .you, fromWeeks: nil), competitionFormerCompetitorName))
    }

    func testBundledClipsAreSilentHEVCWithBeats() async throws {
        for name in ["earned", "taken", "lost", "defended"] {
            let clip = try XCTUnwrap(CompetitionBeltCeremonyClip(named: name), name)
            let asset = AVURLAsset(url: clip.url)
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(audio.count, 0, name)
            let isPlayable = try await asset.load(.isPlayable)
            XCTAssertTrue(isPlayable, name)
            let formats = try await XCTUnwrap(video.first, name).load(.formatDescriptions)
            XCTAssertEqual(formats.map { CMFormatDescriptionGetMediaSubType($0) }, [kCMVideoCodecType_HEVC], name)
            let duration = try await asset.load(.duration).seconds
            XCTAssertLessThan(clip.settle, duration, name)
            XCTAssertFalse(clip.impacts.isEmpty, name)
            XCTAssertNotNil(UIImage(named: "\(name)-final.jpg"), name)
            // The words land on the last settle beat, where the hold starts.
            let json = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "json"))
            let file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
            let holdStart = try XCTUnwrap(file["holdStart"] as? Double, name)
            XCTAssertEqual(clip.settle, holdStart, accuracy: 0.001, name)
        }
        XCTAssertEqual(CompetitionBeltCeremonyClip(named: "lost")?.impacts.count, 1)
        XCTAssertNil(CompetitionBeltCeremonyClip(named: "missing"))
    }

    func testBeltChipWaitsWhileAnEarlierMatchWithThemIsUnfinished() {
        let earlier = homePresentation(id: 1, name: "Sam", lifecycle: .tallying(startedAt: homeNow),
                                       start: (10, 14))
        let next = homePresentation(id: 2, name: "Sam", lifecycle: .active(dayOrdinal: 1),
                                    start: (10, 21))
        let other = homePresentation(id: 3, name: "Max", lifecycle: .active(dayOrdinal: 1),
                                     start: (10, 28))

        XCTAssertTrue(competitionBeltWaitsOnAnEarlierMatch(next, in: [earlier, next, other]))
        XCTAssertFalse(competitionBeltWaitsOnAnEarlierMatch(earlier, in: [earlier, next, other]))
        XCTAssertFalse(competitionBeltWaitsOnAnEarlierMatch(other, in: [earlier, next, other]))

        let finished = homePresentation(
            id: 1, name: "Sam",
            lifecycle: .completed(outcome: .win, basis: .stableAcrossPostBoundaryReads, completedAt: homeNow),
            start: (10, 14)
        )
        XCTAssertFalse(competitionBeltWaitsOnAnEarlierMatch(next, in: [finished, next]))
    }

    func testBeltEventWaitsWhileAnEarlierMatchWithThemIsUnfinished() {
        let earlier = homePresentation(id: 1, name: "Sam", identity: "remote-profile:v1:sam",
                                       lifecycle: .tallying(startedAt: homeNow), start: (9, 1))
        let later = beltWeek(2, .win, start: (9, 3))

        XCTAssertNil(competitionBeltEvent(for: later, in: [earlier, later]))
        XCTAssertEqual(competitionBeltEvent(for: later, in: [later]), .took(by: .you, fromWeeks: nil))
    }

    func testBeltCopy() {
        XCTAssertEqual(competitionBeltStandingText(.you, opponentName: "Sam"), "You hold the belt")
        XCTAssertEqual(competitionBeltStandingText(.them, opponentName: "Sam"), "Sam holds the belt")
        XCTAssertEqual(competitionWeeksText(1), "1 week")
        XCTAssertEqual(competitionWeeksText(3), "3 weeks")

        func banner(_ event: CompetitionBeltEvent) -> [String?]? {
            competitionBeltResultText(event, opponentName: "Sam").map {
                [$0.holder == .you ? "you" : "them", $0.title, $0.detail]
            }
        }
        XCTAssertEqual(banner(.took(by: .you, fromWeeks: 3)), ["you", "You took the belt", "Sam held it for 3 weeks."])
        XCTAssertEqual(banner(.took(by: .them, fromWeeks: 1)), ["them", "Sam took the belt", "You held it for 1 week."])
        XCTAssertEqual(banner(.took(by: .you, fromWeeks: nil)), ["you", "You took the belt", nil])
        XCTAssertEqual(banner(.took(by: .them, fromWeeks: nil)), ["them", "Sam took the belt", nil])
        XCTAssertEqual(banner(.kept(by: .you, weeks: 4)), ["you", "You kept the belt", "4 weeks in a row."])
        XCTAssertEqual(banner(.kept(by: .them, weeks: 3)), ["them", "Sam kept the belt", "3 weeks in a row."])
        XCTAssertNil(banner(.kept(by: .you, weeks: 2)))
        XCTAssertEqual(
            banner(.defended(by: .you, weeks: 2, defenses: 1)),
            ["you", "1st title defense", "2 weeks in a row."]
        )
        XCTAssertEqual(
            banner(.defended(by: .them, weeks: 5, defenses: 3)),
            ["them", "Sam's 3rd title defense", "5 weeks in a row."]
        )
        XCTAssertEqual(
            [1, 2, 3, 4, 11, 12, 13, 21, 22].map(competitionTitleDefenseText),
            ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd"].map { "\($0) title defense" }
        )
        XCTAssertNil(banner(.vacant))
    }

    func testHomeRouteStackKeepsThePersonPageUnderHistory() {
        let id = CompetitionID(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        var path = [id]
        var showsHistory = true
        var person: String? = "p"
        let stack = CompetitionHomeRoute.stack(
            path: Binding(get: { path }, set: { path = $0 }),
            showsHistory: Binding(get: { showsHistory }, set: { showsHistory = $0 }),
            person: Binding(get: { person }, set: { person = $0 })
        )

        XCTAssertEqual(stack.wrappedValue, [.history, .person("p"), .competition(id)])

        stack.wrappedValue = [.history]
        XCTAssertTrue(showsHistory)
        XCTAssertNil(person)
        XCTAssertEqual(path, [])

        stack.wrappedValue = [.history, .person("q")]
        XCTAssertEqual(person, "q")

        stack.wrappedValue = []
        XCTAssertFalse(showsHistory)
        XCTAssertNil(person)
        XCTAssertEqual(path, [])
    }

    // MARK: Home and History

    func testHomeLayoutSingleLiveMatchIsTheHero() {
        let active = homePresentation(id: 1, lifecycle: .active(dayOrdinal: 4))
        let scheduled = homePresentation(id: 2, name: "Andy", lifecycle: .scheduled, start: (11, 2))

        let layout = competitionHomeLayout(homeDashboard([scheduled, active]), now: homeNow)

        XCTAssertEqual(layout.hero?.id, active.id)
        XCTAssertEqual(layout.live, [])
        XCTAssertEqual(layout.upNext.map(\.id), [scheduled.id])
    }

    func testHomeLayoutTwoLiveMatchesAreEqualCardsByEndTime() {
        let hermes = homePresentation(id: 1, name: "Hermes", lifecycle: .active(dayOrdinal: 3), start: (10, 28))
        let andy = homePresentation(id: 2, name: "Andy", lifecycle: .active(dayOrdinal: 4), start: (10, 27))
        let tallying = homePresentation(
            id: 3, name: "Sam", lifecycle: .tallying(startedAt: homeNow), start: (10, 21)
        )
        let layout = competitionHomeLayout(homeDashboard([hermes, andy, tallying]), now: homeNow)
        XCTAssertNil(layout.hero)
        XCTAssertEqual(layout.live.map(\.id), [tallying.id, andy.id, hermes.id])

        let zoe = homePresentation(id: 4, name: "Zoe", lifecycle: .active(dayOrdinal: 3))
        let amy = homePresentation(id: 5, name: "amy", lifecycle: .active(dayOrdinal: 3))
        XCTAssertEqual(
            competitionHomeLayout(homeDashboard([zoe, amy]), now: homeNow).live.map(\.id),
            [amy.id, zoe.id]
        )

        let sameA = homePresentation(id: 7, name: "Sam", lifecycle: .active(dayOrdinal: 3))
        let sameB = homePresentation(id: 6, name: "Sam", lifecycle: .active(dayOrdinal: 3))
        XCTAssertEqual(
            competitionHomeLayout(homeDashboard([sameA, sameB]), now: homeNow).live.map(\.id),
            [sameB.id, sameA.id]
        )
    }

    func testHomeLayoutGroupsEveryLifecycle() {
        func incoming(_ id: Int, expiresIn hours: Double?) -> LocalCompetitionPresentation {
            homePresentation(
                id: id,
                lifecycle: .pending(
                    direction: .incoming,
                    createdAt: homeNow.addingTimeInterval(-3_600),
                    expiresAt: hours.map { homeNow.addingTimeInterval($0 * 3_600) }
                ),
                start: nil
            )
        }
        let in5h = incoming(1, expiresIn: 5)
        let in1h = incoming(2, expiresIn: 1)
        let noExpiry = incoming(3, expiresIn: nil)
        let active = homePresentation(id: 4, lifecycle: .active(dayOrdinal: 3))
        let nov2 = homePresentation(id: 5, lifecycle: .scheduled, start: (11, 2))
        let nov1 = homePresentation(id: 6, lifecycle: .scheduled, start: (11, 1))
        let outgoing = homePresentation(
            id: 7,
            lifecycle: .pending(direction: .outgoing, createdAt: homeNow, expiresAt: nil),
            start: nil
        )
        let closed = homePresentation(
            id: 8,
            lifecycle: .declined(at: homeNow.addingTimeInterval(-60), direction: .outgoing),
            start: nil
        )
        let dayAgo = homePresentation(
            id: 9,
            lifecycle: .completed(outcome: .win, basis: .stableAcrossPostBoundaryReads,
                                  completedAt: homeNow.addingTimeInterval(-86_400)),
            start: (10, 24)
        )
        let twoDaysAgo = homePresentation(
            id: 10,
            lifecycle: .completed(outcome: .win, basis: .stableAcrossPostBoundaryReads,
                                  completedAt: homeNow.addingTimeInterval(-172_800)),
            start: (10, 24)
        )
        let archived = homePresentation(
            id: 11,
            lifecycle: .archived(outcome: .win, basis: .stableAcrossPostBoundaryReads,
                                 completedAt: homeNow.addingTimeInterval(-86_400),
                                 archivedAt: homeNow),
            start: (10, 24)
        )
        let leftHome = homePresentation(
            id: 12,
            lifecycle: .completed(outcome: .loss, basis: .stableAcrossPostBoundaryReads,
                                  completedAt: homeNow.addingTimeInterval(-14 * 86_400)),
            start: (10, 10)
        )

        let layout = competitionHomeLayout(
            homeDashboard([
                in5h, in1h, noExpiry, active, nov2, nov1, outgoing, closed,
                dayAgo, twoDaysAgo, archived, leftHome,
            ]),
            now: homeNow
        )

        XCTAssertEqual(layout.needsYou.map(\.id), [in1h.id, in5h.id, noExpiry.id])
        XCTAssertEqual(layout.hero?.id, active.id)
        XCTAssertEqual(layout.upNext.map(\.id), [nov1.id, nov2.id, outgoing.id, closed.id])
        XCTAssertEqual(layout.recentResults.map(\.id), [dayAgo.id, twoDaysAgo.id])
        let shown = Set(
            ([layout.hero].compactMap { $0 } + layout.needsYou + layout.live
                + layout.upNext + layout.recentResults).map(\.id)
        )
        XCTAssertFalse(shown.contains(archived.id))
        XCTAssertFalse(shown.contains(leftHome.id))
    }

    func testHomeLayoutScheduledLeadsOnlyWhenNothingIsLive() {
        let later = homePresentation(id: 1, lifecycle: .scheduled, start: (11, 2))
        let sooner = homePresentation(id: 2, lifecycle: .scheduled, start: (11, 1))

        let layout = competitionHomeLayout(homeDashboard([later, sooner]), now: homeNow)

        XCTAssertEqual(layout.hero?.id, sooner.id)
        XCTAssertEqual(layout.upNext.map(\.id), [later.id])
    }

    func testClosedChallengesShowOutgoingOnlyAndHonorDismissal() {
        let expired = homePresentation(
            id: 1,
            lifecycle: .expired(at: homeNow.addingTimeInterval(-3_600), direction: .outgoing),
            start: nil
        )
        let declinedIncoming = homePresentation(
            id: 2,
            lifecycle: .declined(at: homeNow.addingTimeInterval(-3_600), direction: .incoming),
            start: nil
        )
        let dashboard = homeDashboard([expired, declinedIncoming])

        XCTAssertEqual(
            competitionHomeLayout(dashboard, now: homeNow).upNext.map(\.id),
            [expired.id]
        )
        let dismissed = competitionHomeLayout(
            dashboard, now: homeNow, dismissedChallengeIDs: [expired.id]
        )
        XCTAssertEqual(dismissed.upNext, [])
        XCTAssertTrue(dismissed.isEmpty)
        XCTAssertTrue(
            competitionHomeLayout(homeDashboard([declinedIncoming]), now: homeNow).isEmpty
        )
    }

    func testHomeShapeChangesWithPlacementAndLifecycleButNotWithANewPublication() {
        let hermes = homePresentation(id: 1, lifecycle: .active(dayOrdinal: 4))
        let andy = homePresentation(id: 2, name: "Andy", lifecycle: .active(dayOrdinal: 3))
        func shape(_ competitions: [LocalCompetitionPresentation]) -> [[String]] {
            competitionHomeLayout(homeDashboard(competitions), now: homeNow).shape
        }

        // The next day, or a new `evaluatedAt`, moves nothing on Home.
        XCTAssertEqual(
            shape([hermes]),
            shape([homePresentation(
                id: 1,
                lifecycle: .active(dayOrdinal: 5),
                evaluatedAt: homeNow.addingTimeInterval(60)
            )])
        )
        // The same match moving from hero to Live does.
        XCTAssertNotEqual(shape([hermes]), shape([hermes, andy]))
        XCTAssertNotEqual(
            shape([hermes]),
            shape([homePresentation(id: 1, lifecycle: .tallying(startedAt: homeNow))])
        )
    }

    func testResultLeavesHomeOnTheFourthDayAfterTheWeek() throws {
        let onTime = homePresentation(
            id: 1,
            lifecycle: .completed(outcome: .win, basis: .stableAcrossPostBoundaryReads,
                                  completedAt: homeInstant("2026-10-31T08:00:00Z")),
            start: (10, 24)
        )
        let leave = try XCTUnwrap(competitionResultLeavesHome(onTime))
        XCTAssertEqual([leave.day.month, leave.day.day], [11, 3])
        XCTAssertEqual(leave.at, homeInstant("2026-11-03T08:00:00Z"))
        XCTAssertEqual(weekdayText(leave.day, locale: Locale(identifier: "en_US")), "Tue")

        let late = homePresentation(
            id: 2,
            lifecycle: .completed(outcome: .win, basis: .stableAcrossPostBoundaryReads,
                                  completedAt: homeInstant("2026-11-02T23:00:00Z")),
            start: (10, 24)
        )
        let lateLeave = try XCTUnwrap(competitionResultLeavesHome(late))
        XCTAssertEqual([lateLeave.day.month, lateLeave.day.day], [11, 4])

        XCTAssertNil(competitionResultLeavesHome(
            homePresentation(id: 3, lifecycle: .active(dayOrdinal: 2))
        ))
    }

    func testWidgetSnapshotKeepsLiveScheduledAndRecentResultsOnly() throws {
        let created = homeInstant("2026-10-29T17:00:00Z")
        let basis = FinalizationBasis.stableAcrossPostBoundaryReads
        let completed = homePresentation(
            id: 1,
            lifecycle: .completed(outcome: .win, basis: basis,
                                  completedAt: homeInstant("2026-10-31T08:00:00Z")),
            start: (10, 24)
        )
        let lateTally = homePresentation(
            id: 2,
            lifecycle: .completed(outcome: .loss, basis: basis,
                                  completedAt: homeInstant("2026-11-02T23:00:00Z")),
            start: (10, 24)
        )
        let live = homePresentation(id: 3, lifecycle: .active(dayOrdinal: 3))
        let scheduled = homePresentation(id: 4, lifecycle: .scheduled, start: (11, 2))
        let tallying = homePresentation(id: 5, lifecycle: .tallying(startedAt: created), start: (10, 21))
        let dropped = [
            homePresentation(id: 6, lifecycle: .pending(direction: .outgoing, createdAt: created, expiresAt: nil)),
            homePresentation(id: 7, lifecycle: .declined(at: created, direction: .outgoing)),
            homePresentation(id: 8, lifecycle: .expired(at: created, direction: .outgoing)),
            homePresentation(id: 9, lifecycle: .cancelled(at: created)),
            homePresentation(id: 10, lifecycle: .archived(outcome: .win, basis: basis,
                                                          completedAt: created, archivedAt: created)),
            homePresentation(id: 11, lifecycle: .active(dayOrdinal: 1), start: nil),
        ]

        let snapshot = CompetitionWidgetSnapshot(
            dashboard: homeDashboard([completed, lateTally, live, scheduled, tallying] + dropped)
        )

        XCTAssertEqual(
            snapshot.matches.map(\.id),
            [completed, lateTally, live, scheduled, tallying].map(\.id.rawValue)
        )
        XCTAssertFalse(snapshot.hasIncomingChallenge)
        let result = try XCTUnwrap(snapshot.matches.first)
        XCTAssertEqual(result.final?.outcome, .win)
        XCTAssertEqual(result.final?.leavesAt, competitionResultLeavesHome(completed)?.at)
        XCTAssertEqual(result.final?.leavesAt, homeInstant("2026-11-03T08:00:00Z"))
        // The tally finished on the 3rd day after Day 7: two days after that.
        XCTAssertEqual(snapshot.matches[1].final?.leavesAt, homeInstant("2026-11-04T08:00:00Z"))
        let week = snapshot.matches[2]
        XCTAssertNil(week.final)
        XCTAssertEqual(week.dayStarts.count, 7)
        XCTAssertEqual(week.dayStarts.first, homeInstant("2026-10-28T07:00:00Z"))
        XCTAssertEqual(
            week.endsAt,
            competitionScheduleBoundaries(try XCTUnwrap(live.acceptedConfiguration?.schedule))?.end
        )
        XCTAssertEqual(week.endsAt, homeInstant("2026-11-04T08:00:00Z"))
        XCTAssertEqual(week.personID, live.opponentIdentity)
        XCTAssertEqual(week.userDayPoints, Array(repeating: nil, count: 7))
    }

    func testWidgetSnapshotFlagsIncomingChallengeWithoutItsName() throws {
        let created = homeInstant("2026-10-29T17:00:00Z")
        let incoming = homePresentation(
            id: 1, name: "Riley",
            lifecycle: .pending(direction: .incoming, createdAt: created, expiresAt: nil)
        )
        let snapshot = CompetitionWidgetSnapshot(dashboard: homeDashboard([incoming]))
        XCTAssertTrue(snapshot.hasIncomingChallenge)
        XCTAssertEqual(snapshot.matches, [])
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(json.contains("Riley"))
    }

    func testWidgetSnapshotURLRoundTripsThroughCompetitionRoute() throws {
        let live = homePresentation(id: 3, lifecycle: .active(dayOrdinal: 3))
        let match = try XCTUnwrap(CompetitionWidgetSnapshot(dashboard: homeDashboard([live])).matches.first)
        XCTAssertEqual(CompetitionRoute(url: match.url), .competition(live.id))
    }

    func testWidgetSnapshotUpdatedAtIsTheNewerSide() throws {
        let base = homePresentation(id: 3, lifecycle: .active(dayOrdinal: 3))
        func updatedAt(you: Date?, them: Date?) throws -> Date? {
            let presentation = LocalCompetitionPresentation(
                id: base.id,
                ownerDisplayName: base.ownerDisplayName,
                opponentDisplayName: base.opponentDisplayName,
                opponentIdentity: base.opponentIdentity,
                lifecycle: base.lifecycle,
                acceptedConfiguration: base.acceptedConfiguration,
                userPoints: 1_204,
                opponentPoints: 1_150,
                days: [],
                currentDayOrdinal: 3,
                lastRefresh: nil,
                tally: nil,
                terminalResult: nil,
                evaluatedAt: homeNow,
                timeZoneIdentifier: base.timeZoneIdentifier,
                lastSuccessfulFullWindowRefreshAt: you,
                opponentUpdatedAt: them
            )
            let match = try XCTUnwrap(CompetitionWidgetSnapshot.Match(presentation: presentation))
            XCTAssertEqual(match.userPoints, 1_204)
            XCTAssertEqual(match.opponentPoints, 1_150)
            return match.updatedAt
        }
        let earlier = homeInstant("2026-10-30T15:00:00Z")
        let later = homeInstant("2026-10-30T16:30:00Z")
        XCTAssertEqual(try updatedAt(you: earlier, them: later), later)
        XCTAssertEqual(try updatedAt(you: later, them: earlier), later)
        XCTAssertEqual(try updatedAt(you: earlier, them: nil), earlier)
        XCTAssertNil(try updatedAt(you: nil, them: nil))
    }

    func testHomeStatusLineAddsChallengeExpiry() throws {
        let en = Locale(identifier: "en_US")
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        func line(
            _ direction: InvitationDirection,
            expiresAt: Date?
        ) -> String {
            normalized(competitionHomeStatusLine(
                homePresentation(
                    id: 1,
                    lifecycle: .pending(direction: direction, createdAt: homeNow, expiresAt: expiresAt),
                    start: nil
                ),
                locale: en,
                timeZone: la
            ))
        }
        XCTAssertEqual(
            line(.incoming, expiresAt: homeInstant("2026-11-01T22:14:00Z")),
            "Challenge received · Expires Sun 2:14 PM"
        )
        XCTAssertEqual(line(.outgoing, expiresAt: nil), "Challenge sent")
        XCTAssertEqual(
            line(.incoming, expiresAt: homeNow.addingTimeInterval(-60)),
            "Challenge received"
        )
    }

    func testOpponentRecordsGroupByIdentityAndShowTheNewestName() {
        func week(
            _ id: Int, _ name: String, _ identity: String,
            _ outcome: CompetitionOutcome, start: (Int, Int)
        ) -> LocalCompetitionPresentation {
            homePresentation(
                id: id, name: name, identity: identity,
                lifecycle: .archived(outcome: outcome, basis: .stableAcrossPostBoundaryReads,
                                     completedAt: homeNow, archivedAt: homeNow),
                start: start
            )
        }
        let weeks = [
            week(1, "Sam", "sam-a", .win, start: (10, 3)),
            week(2, "Sam", "sam-a", .tie, start: (10, 10)),
            week(3, "Sam", "sam-b", .win, start: (9, 26)),
            week(4, "Max", "max", .win, start: (9, 19)),
            week(5, "Max", "max", .loss, start: (9, 12)),
            week(6, "Maxine", "max", .win, start: (10, 17)),
        ]

        let records = competitionOpponentRecords(weeks)

        XCTAssertEqual(records.map(\.opponentIdentity), ["max", "sam-a", "sam-b"])
        XCTAssertEqual(records.map(\.opponentDisplayName), ["Maxine", "Sam", "Sam"])
        XCTAssertEqual(records.map(\.text), ["2–1", "1–0–1", "1–0"])
        XCTAssertEqual(records[1].accessibilityText, "Sam, 1 win, 0 losses, 1 tie")
        XCTAssertEqual(records[0].accessibilityText, "Maxine, 2 wins, 1 loss")
        XCTAssertEqual(records[0].latest.id, weeks[5].id)
    }

    func testHistorySummaryShowsTwoPeopleThenACount() {
        func record(_ name: String, _ wins: Int, _ losses: Int) -> CompetitionOpponentRecord {
            CompetitionOpponentRecord(
                opponentIdentity: name,
                opponentDisplayName: name,
                wins: wins,
                losses: losses,
                ties: 0,
                latest: homePresentation(id: 1, lifecycle: .active(dayOrdinal: 1))
            )
        }
        XCTAssertEqual(competitionHistorySummaryText([record("Alex", 3, 1)]), "Alex 3–1")
        let four = [record("Hermes", 2, 1), record("Andy", 1, 0), record("Sam", 0, 1), record("Max", 1, 1)]
        XCTAssertEqual(
            competitionHistorySummaryText(Array(four.prefix(2))),
            "Hermes 2–1 · Andy 1–0"
        )
        XCTAssertEqual(
            competitionHistorySummaryText(four),
            "Hermes 2–1 · Andy 1–0 · 2 more"
        )
        XCTAssertEqual(
            competitionHistorySummaryAccessibilityText(four),
            "Hermes, 2 wins, 1 loss. Andy, 1 win, 0 losses. 2 more people"
        )
    }

    func testHistoryWeeksAreNewestFirst() {
        func week(_ id: Int, start: (Int, Int)) -> LocalCompetitionPresentation {
            homePresentation(
                id: id,
                lifecycle: .completed(outcome: .win, basis: .stableAcrossPostBoundaryReads,
                                      completedAt: homeNow),
                start: start
            )
        }
        let weeks = [week(1, start: (9, 1)), week(2, start: (10, 1)), week(3, start: (9, 15))]
        let active = homePresentation(id: 4, lifecycle: .active(dayOrdinal: 2))

        XCTAssertEqual(
            competitionHistoryWeeks(weeks + [active]).map(\.id),
            [weeks[1].id, weeks[2].id, weeks[0].id]
        )
    }

    func testRowIssuePrefersCommandThenRefreshThenActivity() {
        let a = CompetitionID(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        let b = CompetitionID(UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
        XCTAssertEqual(
            competitionRowIssue(a, in: [
                .activityFailures([a]), .competitionFailures([a]), .commandRejected(a),
            ]),
            .command
        )
        XCTAssertEqual(
            competitionRowIssue(a, in: [.activityFailures([a]), .competitionFailures([a])]),
            .refresh
        )
        XCTAssertEqual(competitionRowIssue(a, in: [.activityFailures([a])]), .activity)
        XCTAssertNil(competitionRowIssue(a, in: [.commandRejected(b), .competitionFailures([b])]))
    }

    func testIssueSummaryShowsOnlyGlobalOrUnattributedProblems() {
        let a = CompetitionID(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        XCTAssertNil(competitionIssueSummary([.competitionFailures([a])], attributedIDs: [a]))
        XCTAssertEqual(
            competitionIssueSummary([.competitionFailures([a])], attributedIDs: []),
            "Some matches could not be refreshed."
        )
        XCTAssertEqual(
            competitionIssueSummary([.remoteUnavailable], attributedIDs: [a]),
            "Offline. Scores update when you reconnect."
        )
        XCTAssertEqual(
            competitionIssueSummary(
                [.commandRejected(LocalCompetitionIdentity.bootstrapCompetitionID)],
                attributedIDs: [a]
            ),
            "The last match action could not be completed."
        )
        XCTAssertNil(competitionIssueSummary([], attributedIDs: []))
    }

    func testNextHomeBoundaryIsTheEarliestChangeStillAhead() {
        let pending = homePresentation(
            id: 1,
            lifecycle: .pending(direction: .outgoing, createdAt: homeNow,
                                expiresAt: homeNow.addingTimeInterval(5 * 3_600)),
            start: nil
        )
        let closed = homePresentation(
            id: 2,
            lifecycle: .declined(at: homeNow.addingTimeInterval(-23 * 3_600), direction: .outgoing),
            start: nil
        )
        let result = homePresentation(
            id: 3,
            lifecycle: .completed(outcome: .win, basis: .stableAcrossPostBoundaryReads,
                                  completedAt: homeInstant("2026-10-31T08:00:00Z")),
            start: (10, 24)
        )
        XCTAssertEqual(
            homeDashboard([pending, closed, result]).nextHomeBoundary(after: homeNow),
            homeNow.addingTimeInterval(3_600)
        )
        XCTAssertEqual(
            homeDashboard([pending, result]).nextHomeBoundary(after: homeNow),
            homeNow.addingTimeInterval(5 * 3_600)
        )
        XCTAssertEqual(
            homeDashboard([result]).nextHomeBoundary(after: homeNow),
            homeInstant("2026-11-03T08:00:00Z")
        )
        XCTAssertNil(homeDashboard([]).nextHomeBoundary(after: homeNow))
    }

    private var homeNow: Date { homeInstant("2026-10-30T17:00:00Z") }

    private func homeInstant(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func homeDashboard(
        _ competitions: [LocalCompetitionPresentation]
    ) -> LocalCompetitionDashboard {
        LocalCompetitionDashboard(
            competitions: competitions,
            awards: [],
            issues: [],
            hiddenTerminalCompetitionCount: 0
        )
    }

    /// A match in an America/Los_Angeles calendar starting on 2026 (month, day).
    private func homePresentation(
        id: Int,
        name: String = "Hermes",
        identity: String? = nil,
        lifecycle: LocalCompetitionLifecyclePresentation,
        start: (month: Int, day: Int)? = (10, 28),
        evaluatedAt: Date? = nil,
        userPoints: Double = 0
    ) -> LocalCompetitionPresentation {
        let zone = "America/Los_Angeles"
        let schedule = start.map {
            CompetitionSchedule(
                calendar: try! CompetitionCalendar(timeZoneIdentifier: zone),
                startDay: try! CompetitionDay(
                    era: 1, year: 2026, month: $0.month, day: $0.day,
                    timeZoneIdentifier: zone
                )
            )
        }
        let terminal: LocalCompetitionTerminalPresentation? = switch lifecycle {
        case let .completed(outcome, basis, completedAt),
             let .archived(outcome, basis, completedAt, _):
            LocalCompetitionTerminalPresentation(
                userPoints: userPoints, opponentPoints: 0, outcome: outcome,
                basis: basis, completedAt: completedAt
            )
        default:
            nil
        }
        return LocalCompetitionPresentation(
            id: CompetitionID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", id))!),
            ownerDisplayName: "Naren",
            opponentDisplayName: name,
            opponentIdentity: identity ?? "remote-profile:v1:\(name.lowercased())",
            lifecycle: lifecycle,
            acceptedConfiguration: schedule.map {
                LocalCompetitionAcceptedPresentation(schedule: $0, difficulty: .balanced)
            },
            userPoints: 0,
            opponentPoints: 0,
            days: [],
            currentDayOrdinal: nil,
            lastRefresh: nil,
            tally: nil,
            terminalResult: terminal,
            evaluatedAt: evaluatedAt ?? homeNow,
            timeZoneIdentifier: zone
        )
    }

    func testWeekChartSplitsAcceptedPointsByRingShareAndKeepsTheTotal() throws {
        let day = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 9,
            day: 23,
            timeZoneIdentifier: "UTC"
        )
        let snapshot = ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: 420, goal: 500),
            exercise: try ActivityRingReading(value: 22, goal: 30),
            standOrRoll: try ActivityRingReading(value: 9, goal: 12),
            pauseState: .running
        )
        let split = ringSegments(
            LocalCompetitionDayPresentation(
                day: day,
                ordinal: 1,
                ownerAcceptedPoints: 232,
                ownerLatestAvailability: .observed,
                opponentRevealedPoints: 210,
                ownerAcceptedSnapshot: snapshot,
                ownerLatestSnapshot: snapshot
            )
        ).map { $0.points }

        XCTAssertEqual(split.count, 3)
        XCTAssertEqual(split.reduce(0, +), 232, accuracy: 0.0001)
        XCTAssertEqual(
            split[0],
            232 * 0.84 / (0.84 + 22.0 / 30 + 0.75),
            accuracy: 0.0001
        )

        let unsplit = ringSegments(
            LocalCompetitionDayPresentation(
                day: day,
                ordinal: 1,
                ownerAcceptedPoints: 232,
                ownerLatestAvailability: .observed,
                opponentRevealedPoints: nil
            )
        ).map { $0.points }
        XCTAssertEqual(unsplit, [232])

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        XCTAssertEqual(
            weekdayText(day),
            calendar.shortWeekdaySymbols[3],
            "September 23, 2026 is a Wednesday."
        )
    }

    private func makeSnapshot(
        moveMode: ActivityMoveMode,
        standMode: ActivityStandMode,
        pauseState: ActivityPauseState
    ) throws -> ActivitySnapshot {
        ActivitySnapshot(
            moveMode: moveMode,
            standMode: standMode,
            move: try ActivityRingReading(value: 60, goal: 30),
            exercise: try ActivityRingReading(value: 60, goal: 30),
            standOrRoll: try ActivityRingReading(value: 24, goal: 12),
            pauseState: pauseState
        )
    }

    private func presentation(
        _ availability: LocalCompetitionOwnerAvailability,
        points: Double?
    ) -> LocalCompetitionDayPresentation {
        let day = try! CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 9,
            timeZoneIdentifier: "UTC"
        )
        return LocalCompetitionDayPresentation(
            day: day,
            ordinal: 2,
            ownerAcceptedPoints: points,
            ownerLatestAvailability: availability,
            opponentRevealedPoints: nil
        )
    }

    func testTimeZoneTextUsesGenericName() {
        XCTAssertEqual(
            competitionTimeZoneText("America/Los_Angeles", locale: Locale(identifier: "en_US")),
            "Days run midnight to midnight, Pacific Time."
        )
        XCTAssertEqual(
            competitionTimeZoneText("Not/AZone", locale: Locale(identifier: "en_US")),
            "Days run midnight to midnight, Not/AZone."
        )
    }

    func testShareMessageCarriesSenderAndLink() throws {
        let token = try XCTUnwrap(CompetitionInviteClaimToken(rawValue: String(repeating: "A", count: 43)))
        let link = try XCTUnwrap(CompetitionInviteShareLink(host: "invites.healthcomp.example", token: token))
        let url = "https://invites.healthcomp.example/invite/" + String(repeating: "A", count: 43)
        XCTAssertEqual(
            competitionShareMessage(senderName: "Naren", link: link),
            "Naren challenged you to a week of rings on HealthComp: \(url)"
        )
        XCTAssertEqual(
            competitionShareMessage(senderName: nil, link: link),
            "Join me for a week of rings on HealthComp: \(url)"
        )
    }

    func testReceivedRematchCopy() {
        func challenge(expiresAt: Date?) -> LocalCompetitionPresentation {
            LocalCompetitionPresentation(
                id: CompetitionID(UUID()),
                ownerDisplayName: "Naren",
                opponentDisplayName: "Alex",
                lifecycle: .pending(direction: .incoming, createdAt: .distantPast, expiresAt: expiresAt),
                acceptedConfiguration: nil,
                userPoints: 0,
                opponentPoints: 0,
                days: [],
                currentDayOrdinal: nil,
                lastRefresh: nil,
                tally: nil,
                terminalResult: nil,
                evaluatedAt: Date(timeIntervalSince1970: 1_786_867_200)
            )
        }
        let locale = Locale(identifier: "en_US")
        let utc = TimeZone(identifier: "UTC")!
        let text = competitionReceivedRematchText(
            challenge(expiresAt: Date(timeIntervalSince1970: 1_786_867_200 + 14 * 3_600)),
            locale: locale,
            timeZone: utc
        )
        XCTAssertEqual(text.title, "Alex sent a rematch")
        // ICU puts a narrow no-break space before PM.
        XCTAssertEqual(
            text.detail?.replacingOccurrences(of: "\u{202F}", with: " "),
            "Expires Sun 10:00 PM"
        )
        let undated = competitionReceivedRematchText(challenge(expiresAt: nil), locale: locale, timeZone: utc)
        XCTAssertEqual(undated.title, "Alex sent a rematch")
        XCTAssertNil(undated.detail)
    }

    func testRecipientAndFailureCopy() {
        XCTAssertEqual(
            competitionInviteFailureText(.conflict, opponentName: "Maya"),
            "You already have a challenge or match with Maya."
        )
        XCTAssertNil(competitionRecipientErrorText(.idle))
        XCTAssertNil(competitionRecipientErrorText(.lookingUp))
        XCTAssertEqual(
            competitionRecipientErrorText(.invalidCode),
            "That isn’t a full challenge link. Ask them to share it again."
        )
        XCTAssertEqual(competitionRecipientErrorText(.ownCode), "That’s your own link. Ask them for theirs.")
        XCTAssertEqual(competitionRecipientErrorText(.notFound), "No account has this link. Check it and try again.")
        XCTAssertEqual(
            competitionRecipientErrorText(.connectionFailed),
            "Couldn’t look up that link. Check your connection and try again."
        )
        XCTAssertEqual(
            competitionInviteFailureText(.connection, opponentName: "Hermes"),
            "Couldn’t send the challenge. Check your connection and try again."
        )
        // Test builds are Debug, so the configuration line names the build.
        XCTAssertEqual(
            competitionInviteFailureText(.unavailable, opponentName: "Hermes"),
            "Challenge links are not configured for this build."
        )
        XCTAssertEqual(
            competitionInviteFailureText(.recipientGone, opponentName: "Hermes"),
            "You can’t challenge Hermes."
        )
        XCTAssertEqual(
            competitionInviteFailureText(.alreadyPending, opponentName: "Hermes"),
            "You already challenged Hermes. It expires 24 hours after you sent it."
        )
    }

    // MARK: Reactions

    private static let reactionMatchID = CompetitionID(
        UUID(uuidString: "86000000-0000-4000-8000-000000000001")!
    )

    private func reactionPresentation(
        lifecycle: LocalCompetitionLifecyclePresentation = .active(dayOrdinal: 3),
        opponentName: String = "Jordan",
        opponentIdentity: String = RemoteCompetitionOpponentIdentity.identity(
            for: UUID(uuidString: "86000000-0000-4000-8000-000000000002")!
        ),
        reactions: [CompetitionReaction] = [],
        days: [LocalCompetitionDayPresentation] = []
    ) -> LocalCompetitionPresentation {
        var presentation = LocalCompetitionPresentation(
            id: Self.reactionMatchID,
            ownerDisplayName: "You",
            opponentDisplayName: opponentName,
            opponentIdentity: opponentIdentity,
            lifecycle: lifecycle,
            acceptedConfiguration: nil,
            userPoints: 0,
            opponentPoints: 0,
            days: days,
            currentDayOrdinal: nil,
            lastRefresh: nil,
            tally: nil,
            terminalResult: nil
        )
        presentation.reactions = reactions
        return presentation
    }

    private func reaction(
        _ target: CompetitionReactionTarget,
        _ kind: CompetitionReactionKind,
        fromYou: Bool = false,
        at seconds: TimeInterval
    ) -> CompetitionReaction {
        CompetitionReaction(
            target: target, kind: kind, isFromYou: fromYou,
            updatedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    func testReactionCopy() {
        let jordanDay = reaction(.day(2), .huffing, at: 1)
        XCTAssertEqual(
            competitionReactionText(jordanDay, opponentName: "Jordan"),
            "Jordan reacted to your Day 2"
        )
        XCTAssertEqual(
            competitionReactionText(reaction(.result, .clap, at: 1), opponentName: "Morgan"),
            "Morgan reacted to the result"
        )
        XCTAssertEqual(
            competitionReactionText(reaction(.day(5), .fire, fromYou: true, at: 1), opponentName: "Jordan"),
            "You reacted to Jordan’s Day 5"
        )
        XCTAssertEqual(
            competitionReactionText(reaction(.result, .salute, fromYou: true, at: 1), opponentName: "Jordan"),
            "You reacted to the result"
        )
        XCTAssertEqual(
            competitionReactionAccessibilityText(jordanDay, opponentName: "Jordan"),
            "Huffing. Jordan reacted to your Day 2"
        )
        XCTAssertEqual(
            CompetitionReactionKind.allCases.map(\.spokenName),
            ["Clap", "Fire", "Huffing", "Salute"]
        )
        XCTAssertEqual(CompetitionReactionKind.allCases.map(\.emoji), ["👏", "🔥", "😤", "🫡"])
    }

    func testUnseenReactionIsTheLatestIncomingAfterTheSeenMark() {
        let older = reaction(.day(1), .clap, at: 100)
        let newest = reaction(.day(2), .huffing, at: 200)
        let yours = reaction(.day(3), .fire, fromYou: true, at: 300)
        let match = reactionPresentation(reactions: [yours, older, newest])
        let seen = CompetitionReactionsSeen()

        XCTAssertEqual(competitionUnseenReaction(match, seen: seen), newest)
        let marked = seen.marking(match)
        XCTAssertEqual(marked.seenAt[Self.reactionMatchID.rawValue.uuidString.lowercased()], 200)
        XCTAssertNil(competitionUnseenReaction(match, seen: marked))
        // Marking an older list never moves the mark back.
        XCTAssertEqual(marked.marking(reactionPresentation(reactions: [older])), marked)
        // Your own reactions alone leave the marks alone.
        XCTAssertEqual(seen.marking(reactionPresentation(reactions: [yours])), seen)

        let changed = reactionPresentation(reactions: [reaction(.day(2), .fire, at: 250), older])
        XCTAssertEqual(competitionUnseenReaction(changed, seen: marked)?.kind, .fire)
    }

    func testUnseenReactionIgnoresMatchesWithoutScores() {
        let incoming = [reaction(.day(2), .huffing, at: 200)]
        for lifecycle: LocalCompetitionLifecyclePresentation in [
            .cancelled(at: Date(timeIntervalSince1970: 300)),
            .scheduled,
        ] {
            XCTAssertNil(competitionUnseenReaction(
                reactionPresentation(lifecycle: lifecycle, reactions: incoming),
                seen: CompetitionReactionsSeen()
            ))
        }
    }

    func testWeekReactionsListResultFirstThenByDayYoursFirst() {
        let theirDay2 = reaction(.day(2), .huffing, at: 1)
        let yourDay2 = reaction(.day(2), .fire, fromYou: true, at: 2)
        let theirDay5 = reaction(.day(5), .clap, at: 3)
        let theirResult = reaction(.result, .salute, at: 4)
        XCTAssertEqual(
            competitionReactionsInWeekOrder([theirDay5, theirDay2, theirResult, yourDay2]),
            [theirResult, yourDay2, theirDay2, theirDay5]
        )
    }

    func testMotionSeenMarksAMomentForOneMatchAndSurvivesItsRawValue() {
        let id = CompetitionID(UUID())
        let other = CompetitionID(UUID())
        let marked = CompetitionMotionSeen().marking(.verdict, id)

        XCTAssertFalse(CompetitionMotionSeen().hasSeen(.verdict, id))
        XCTAssertTrue(marked.hasSeen(.verdict, id))
        XCTAssertFalse(marked.hasSeen(.verdict, other))

        let both = marked.marking(.verdict, other)
        XCTAssertEqual(CompetitionMotionSeen(rawValue: both.rawValue), both)
    }

    func testReactionRainsOnceForUnseenIncomingAndSurvivesItsRawValue() {
        let older = reaction(.day(1), .clap, at: 100)
        let newest = reaction(.day(2), .huffing, at: 200)
        let yours = reaction(.day(3), .fire, fromYou: true, at: 300)
        let match = reactionPresentation(reactions: [yours, older, newest])
        let seen = CompetitionReactionsSeen()

        let batch = competitionReactionRainBatch([match], seen: seen, motionSeen: CompetitionMotionSeen())
        XCTAssertEqual(batch?.kinds, [.huffing, .clap])
        XCTAssertEqual(
            batch?.announcement,
            "Huffing. Jordan reacted to your Day 2. Clap. Jordan reacted to your Day 1"
        )

        let rained = CompetitionMotionSeen().raining([match])
        XCTAssertNil(competitionReactionRainBatch([match], seen: seen, motionSeen: rained))
        XCTAssertEqual(CompetitionMotionSeen(rawValue: rained.rawValue), rained)
        // The rain mark leaves the Week's alone.
        XCTAssertFalse(rained.weekGained(match))

        // A newer one rains alone; one already seen on its screen never does.
        let changed = reactionPresentation(reactions: [reaction(.day(2), .fire, at: 250), older])
        XCTAssertEqual(
            competitionReactionRainBatch([changed], seen: seen, motionSeen: rained)?.kinds,
            [.fire]
        )
        XCTAssertNil(competitionReactionRainBatch(
            [changed], seen: seen.marking(changed), motionSeen: CompetitionMotionSeen()
        ))
    }

    func testReactionRainIsCappedAndSkipsPracticeAndMatchesWithoutScores() {
        let five = (1...5).map { reaction(.day($0), .salute, at: Double($0)) }
        XCTAssertEqual(
            competitionReactionRainBatch(
                [reactionPresentation(reactions: five)],
                seen: CompetitionReactionsSeen(), motionSeen: CompetitionMotionSeen()
            )?.kinds.count,
            4
        )
        let practice = reactionPresentation(
            opponentIdentity: PracticeMatch.opponentIdentity, reactions: five
        )
        let scheduled = reactionPresentation(lifecycle: .scheduled, reactions: five)
        XCTAssertNil(competitionReactionRainBatch(
            [practice, scheduled],
            seen: CompetitionReactionsSeen(), motionSeen: CompetitionMotionSeen()
        ))
    }

    func testRematchStageIgnoresThePresentationAndKeepsWhatResizesTheControl() {
        let earlier = reactionPresentation()
        let later = reactionPresentation(reactions: [reaction(.result, .salute, at: 1)])
        XCTAssertNotEqual(earlier, later)
        XCTAssertEqual(CompetitionRematchStage(.next(earlier)), CompetitionRematchStage(.next(later)))
        XCTAssertNotEqual(CompetitionRematchStage(.next(earlier)), CompetitionRematchStage(.received(earlier)))

        let id = CompetitionID(UUID())
        let unknown = CompetitionRematchStage(.sent(challengeID: id, expiresAt: nil, link: nil))
        XCTAssertEqual(
            unknown,
            CompetitionRematchStage(.sent(challengeID: CompetitionID(UUID()), expiresAt: nil, link: nil))
        )
        XCTAssertNotEqual(
            unknown,
            CompetitionRematchStage(.sent(challengeID: id, expiresAt: Date(), link: nil))
        )
        XCTAssertNotEqual(
            unknown,
            CompetitionRematchStage(.sent(challengeID: id, expiresAt: nil, link: .failed))
        )
    }

    func testReactionsSeenRawValueRoundTrips() {
        let match = reactionPresentation(reactions: [reaction(.result, .salute, at: 1_786_867_200.5)])
        let marked = CompetitionReactionsSeen().marking(match)
        XCTAssertEqual(CompetitionReactionsSeen(rawValue: marked.rawValue), marked)
        XCTAssertEqual(CompetitionReactionsSeen(rawValue: CompetitionReactionsSeen().rawValue), .init())
        XCTAssertNil(CompetitionReactionsSeen(rawValue: "not json"))
    }

    func testWeekGrowsOnlyWhenTheNewestScoredDayIsNew() {
        func match(_ points: [Double?]) -> LocalCompetitionPresentation {
            reactionPresentation(days: points.enumerated().map { index, points in
                LocalCompetitionDayPresentation(
                    day: presentation(.observed, points: nil).day,
                    ordinal: index + 1,
                    ownerAcceptedPoints: points,
                    ownerLatestAvailability: .observed,
                    opponentRevealedPoints: 100
                )
            })
        }
        let seen = CompetitionMotionSeen()

        XCTAssertFalse(seen.weekGained(match([nil, nil])), "no bars of yours to grow")
        XCTAssertTrue(seen.weekGained(match([120, nil])))

        let drawn = seen.drawingWeek(match([120, 200]))
        XCTAssertFalse(drawn.weekGained(match([120, 200])), "once a day, not once a push")
        XCTAssertFalse(drawn.weekGained(match([120, 240])), "a score moving is not a new day")
        XCTAssertFalse(drawn.weekGained(match([120, nil])))
        XCTAssertTrue(drawn.weekGained(match([120, 240, 10])))
        XCTAssertEqual(CompetitionMotionSeen(rawValue: drawn.rawValue), drawn)
        XCTAssertNil(CompetitionMotionSeen(rawValue: "not json"))
    }

    func testLeadSideComesFromTheNumbersAsShown() {
        XCTAssertEqual(competitionLeadSide(userPoints: 12, opponentPoints: 3), .you)
        XCTAssertEqual(competitionLeadSide(userPoints: 3, opponentPoints: 12), .them)
        XCTAssertEqual(competitionLeadSide(userPoints: 5, opponentPoints: 5), .square)
        XCTAssertEqual(competitionLeadSide(userPoints: 300.4, opponentPoints: 300.2), .square)
    }

    func testCanReactOnlyWithARealOtherPersonAfterTheMatchStarts() {
        let completed = LocalCompetitionLifecyclePresentation.completed(
            outcome: .win,
            basis: .stableAcrossPostBoundaryReads,
            completedAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertFalse(competitionCanReact(reactionPresentation(lifecycle: .scheduled)))
        XCTAssertTrue(competitionCanReact(reactionPresentation(lifecycle: .active(dayOrdinal: 1))))
        XCTAssertTrue(competitionCanReact(reactionPresentation(lifecycle: completed)))
        XCTAssertFalse(competitionCanReact(reactionPresentation(opponentName: "Former competitor")))
        XCTAssertFalse(competitionCanReact(reactionPresentation(
            opponentIdentity: LocalCompetitionIdentity.opponentIdentity
        )))
        XCTAssertFalse(competitionCanReact(reactionPresentation(opponentIdentity: "practice-pacer:v1")))
    }
}

private enum FinalScoreLayoutProposal: CaseIterable {
    case zero
    case unspecified
    case infinite
    case nilWidthFiniteHeight
    case finiteWidthNilHeight
    case finiteWidthInfiniteHeight
    case infiniteWidthFiniteHeight
    case narrow
    case wide

    var size: ProposedViewSize {
        switch self {
        case .zero:
            .zero
        case .unspecified:
            .unspecified
        case .infinite:
            .infinity
        case .nilWidthFiniteHeight:
            ProposedViewSize(width: nil, height: 400)
        case .finiteWidthNilHeight:
            ProposedViewSize(width: 320, height: nil)
        case .finiteWidthInfiniteHeight:
            ProposedViewSize(width: 320, height: .infinity)
        case .infiniteWidthFiniteHeight:
            ProposedViewSize(width: .infinity, height: 400)
        case .narrow:
            ProposedViewSize(width: 160, height: 600)
        case .wide:
            ProposedViewSize(width: 640, height: 600)
        }
    }
}

private final class FinalScoreLayoutMeasurements {
    private let lock = NSLock()
    private var storage: [FinalScoreLayoutProposal: [CGSize]] = [:]

    var sizes: [FinalScoreLayoutProposal: [CGSize]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ size: CGSize, for proposal: FinalScoreLayoutProposal) {
        lock.lock()
        defer { lock.unlock() }
        storage[proposal, default: []].append(size)
    }
}

private struct FinalScoreProposalProbeLayout: Layout {
    let recorder: FinalScoreLayoutMeasurements

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        if let child = subviews.first {
            for proposal in FinalScoreLayoutProposal.allCases {
                let size = child.sizeThatFits(proposal.size)
                recorder.append(size, for: proposal)
            }
        }
        return CGSize(width: 720, height: 960)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        for child in subviews {
            child.place(
                at: bounds.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
            )
        }
    }
}

private struct FinalScoreProbeOwner: View {
    let name: String
    let points: String

    var body: some View {
        VStack(spacing: 5) {
            Text(name)
                .font(.subheadline.weight(.semibold))
            Text(points)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()
            Text("points")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Practice match

extension CompetitionPresentationTests {
    private func practicePresentation(
        id: Int,
        lifecycle: LocalCompetitionLifecyclePresentation,
        start: (month: Int, day: Int)? = (10, 28)
    ) -> LocalCompetitionPresentation {
        homePresentation(
            id: id,
            name: PracticeMatch.opponentDisplayName,
            identity: PracticeMatch.opponentIdentity,
            lifecycle: lifecycle,
            start: start
        )
    }

    /// "Nothing leaves this iPhone" on the practice invite depends on this.
    func testPracticeNeverReachesTheWidgetsOrTheWatch() {
        let practice = practicePresentation(id: 1, lifecycle: .active(dayOrdinal: 3), start: (10, 28))
        XCTAssertNil(CompetitionWidgetSnapshot.Match(presentation: practice))
    }

    func testPracticeStatusIsLabeledOnCardsRowsButNotNotifications() throws {
        let en = Locale(identifier: "en_US")
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let won = LocalCompetitionLifecyclePresentation.completed(
            outcome: .win, basis: .stableAcrossPostBoundaryReads, completedAt: homeNow
        )
        let cases: [(LocalCompetitionLifecyclePresentation, (Int, Int))] = [
            (.scheduled, (11, 1)),
            (.active(dayOrdinal: 3), (10, 28)),
            (.tallying(startedAt: homeNow), (10, 21)),
            (won, (10, 21)),
        ]
        for (lifecycle, start) in cases {
            let practice = practicePresentation(id: 1, lifecycle: lifecycle, start: start)
            let real = homePresentation(id: 2, lifecycle: lifecycle, start: start)
            for style in [CompetitionStatusStyle.card, .row] {
                let practiceText = competitionStatusText(practice, style: style, locale: en, timeZone: la)
                let realText = competitionStatusText(real, style: style, locale: en, timeZone: la)
                XCTAssertEqual(practiceText.title, "Practice · \(realText.title)")
                XCTAssertEqual(practiceText.timing, realText.timing)
            }
            XCTAssertEqual(
                competitionStatusText(practice, style: .notification, locale: en, timeZone: la),
                competitionStatusText(
                    homePresentation(id: 2, name: "Pacer", lifecycle: lifecycle, start: start),
                    style: .notification, locale: en, timeZone: la
                )
            )
        }
        let result = practicePresentation(id: 3, lifecycle: won, start: (10, 21))
        XCTAssertTrue(
            competitionHomeStatusLine(result, locale: en, timeZone: la).hasPrefix("Practice · "),
            competitionHomeStatusLine(result, locale: en, timeZone: la)
        )
    }

    func testPersonalBestComparesALossWithYourLastFourEarlierRealWeeks() {
        func week(
            _ id: Int, _ start: (Int, Int), _ points: Double, _ outcome: CompetitionOutcome = .loss
        ) -> LocalCompetitionPresentation {
            homePresentation(
                id: id,
                lifecycle: .completed(
                    outcome: outcome, basis: .stableAcrossPostBoundaryReads, completedAt: homeNow
                ),
                start: start,
                userPoints: points
            )
        }
        let past = [
            week(1, (9, 23), 5_000),
            week(2, (9, 30), 1_000),
            week(3, (10, 7), 1_100),
            week(4, (10, 14), 900),
            week(5, (10, 21), 1_000, .win),
        ]
        let practice = practicePresentation(
            id: 9,
            lifecycle: .completed(outcome: .win, basis: .stableAcrossPostBoundaryReads, completedAt: homeNow),
            start: (10, 21)
        )
        let best = week(10, (10, 28), 1_400)
        // Week 1 is the fifth back, so its 5,000 never counts.
        XCTAssertEqual(
            competitionPersonalBestText(for: best, in: past + [practice, best], locale: en),
            "Your best week of your last 5, 400 points above your average"
        )
        let above = week(10, (10, 28), 1_050, .tie)
        XCTAssertEqual(
            competitionPersonalBestText(for: above, in: past + [above], locale: en),
            "50 points above your average week"
        )
        let usual = week(10, (10, 28), 1_000)
        XCTAssertNil(competitionPersonalBestText(for: usual, in: past + [usual], locale: en))
        let won = week(10, (10, 28), 1_400, .win)
        XCTAssertNil(competitionPersonalBestText(for: won, in: past + [won], locale: en))
        // Two earlier weeks, and one that overlaps this one, aren't enough.
        let overlapping = week(11, (10, 27), 100)
        XCTAssertNil(
            competitionPersonalBestText(
                for: best, in: Array(past.suffix(2)) + [overlapping, best], locale: en
            )
        )
    }

    func testRingSplitAddsEachSidesAcceptedRingsOnlyWhenEveryScoredDayHasThem() throws {
        let day = try CompetitionDay(era: 1, year: 2026, month: 10, day: 28, timeZoneIdentifier: "UTC")
        func split(_ ordinal: Int, you: [Double]?, them: [Double]?) -> LocalCompetitionDayPresentation {
            var presentation = LocalCompetitionDayPresentation(
                day: day,
                ordinal: ordinal,
                ownerAcceptedPoints: you?.reduce(0, +),
                ownerLatestAvailability: .observed,
                opponentRevealedPoints: them?.reduce(0, +)
            )
            presentation.ownerRingPoints = you
            presentation.opponentRingPoints = them
            return presentation
        }
        let days = [
            split(1, you: [100, 50, 25], them: [120, 20, 50]),
            split(2, you: [80, 60, 25], them: [90, 10, 50]),
            split(3, you: nil, them: nil),
        ]
        let result = try XCTUnwrap(competitionRingSplit(days))
        XCTAssertEqual(result.you, [180, 110, 50])
        XCTAssertEqual(result.them, [210, 30, 100])

        var missing = split(4, you: [1, 1, 1], them: [1, 1, 1])
        missing.opponentRingPoints = nil
        XCTAssertNil(competitionRingSplit(days + [missing]))
        XCTAssertNil(competitionRingSplit([split(1, you: nil, them: nil)]))

        XCTAssertEqual(competitionRingBasisPoints(17_500, 10_000, 5_000, 2_500), [10_000, 5_000, 2_500])
        XCTAssertNil(competitionRingBasisPoints(17_000, 10_000, 5_000, 2_500))
        XCTAssertNil(competitionRingBasisPoints(nil, nil, nil, nil))
    }

    func testHistoryWeeksAndRecordsLeavePracticeOut() {
        let won = LocalCompetitionLifecyclePresentation.completed(
            outcome: .win, basis: .stableAcrossPostBoundaryReads, completedAt: homeNow
        )
        let practice = practicePresentation(id: 1, lifecycle: won, start: (10, 14))
        let real = homePresentation(id: 2, lifecycle: won, start: (10, 21))

        XCTAssertEqual(competitionHistoryWeeks([practice, real]).map(\.id), [real.id])
        XCTAssertEqual(
            competitionOpponentRecords([practice, real]).map(\.opponentIdentity),
            [real.opponentIdentity]
        )
        XCTAssertEqual(competitionOpponentRecords([practice]), [])
        XCTAssertNil(competitionBeltEvent(for: practice, in: [practice, real]))
    }

    func testAccountLiveMatchCountLeavesPracticeOut() {
        XCTAssertEqual(
            accountLiveMatchCount([
                practicePresentation(id: 1, lifecycle: .active(dayOrdinal: 3)),
                homePresentation(id: 2, lifecycle: .active(dayOrdinal: 3)),
            ]),
            1
        )
    }

    func testMuteIdentityIsNilForPractice() {
        let practice = practicePresentation(id: 1, lifecycle: .active(dayOrdinal: 3))
        let real = homePresentation(id: 2, lifecycle: .active(dayOrdinal: 3))
        XCTAssertNil(competitionMuteIdentity(practice, authorization: .authorized))
        XCTAssertEqual(competitionMuteIdentity(real, authorization: .authorized), real.opponentIdentity)
    }

    func testHomeLayoutMakesAPracticeTheHeroOnlyWhenAlone() {
        let livePractice = practicePresentation(id: 1, lifecycle: .active(dayOrdinal: 3))
        let scheduledPractice = practicePresentation(id: 2, lifecycle: .scheduled, start: (10, 31))
        let realScheduled = homePresentation(id: 3, name: "Andy", lifecycle: .scheduled, start: (11, 2))
        let realLive = homePresentation(id: 4, lifecycle: .active(dayOrdinal: 3))
        func layout(_ competitions: [LocalCompetitionPresentation]) -> CompetitionHomeLayout {
            competitionHomeLayout(homeDashboard(competitions), now: homeNow)
        }

        XCTAssertEqual(layout([livePractice]).hero?.id, livePractice.id)
        XCTAssertEqual(layout([scheduledPractice]).hero?.id, scheduledPractice.id)

        let beside = layout([livePractice, realScheduled])
        XCTAssertEqual(beside.hero?.id, realScheduled.id)
        XCTAssertEqual(beside.live.map(\.id), [livePractice.id])
        XCTAssertEqual(beside.upNext, [])

        // The practice starts sooner, but the real match leads.
        let bothScheduled = layout([scheduledPractice, realScheduled])
        XCTAssertEqual(bothScheduled.hero?.id, realScheduled.id)
        XCTAssertEqual(bothScheduled.upNext.map(\.id), [scheduledPractice.id])

        let bothLive = layout([livePractice, realLive])
        XCTAssertNil(bothLive.hero)
        XCTAssertEqual(Set(bothLive.live.map(\.id)), [livePractice.id, realLive.id])

        let realLiveFirst = layout([realLive, scheduledPractice])
        XCTAssertEqual(realLiveFirst.hero?.id, realLive.id)
        XCTAssertEqual(realLiveFirst.upNext.map(\.id), [scheduledPractice.id])
    }

    func testPracticeIsLeftOutOfWidgetsAndLiveActivities() throws {
        let practice = practicePresentation(id: 1, lifecycle: .endsToday, start: (10, 24))
        let real = homePresentation(id: 2, lifecycle: .endsToday, start: (10, 24))
        XCTAssertNil(CompetitionWidgetSnapshot.Match(presentation: practice))
        XCTAssertNotNil(CompetitionWidgetSnapshot.Match(presentation: real))
        // 6 PM on the last day: a real match's card would start.
        func steps(_ p: LocalCompetitionPresentation) -> [CompetitionLiveActivityStep] {
            CompetitionLiveActivityPlanner.steps(
                presentations: [p],
                source: .remoteParticipants,
                knownCompetitionIDs: [p.id],
                current: [],
                started: [],
                isAllowed: true,
                now: homeNow.addingTimeInterval(8 * 3_600)
            )
        }
        XCTAssertEqual(steps(practice), [])
        XCTAssertEqual(steps(real).count, 1)
    }

    private func versusContent(
        _ match: LocalCompetitionPresentation,
        with others: [LocalCompetitionPresentation] = [],
        source: CompetitionPublicationSource = .remoteParticipants
    ) -> CompetitionVersusIntroContent? {
        competitionVersusIntroContent(
            match,
            in: LocalCompetitionPublication(
                publicationRevision: 1,
                dashboard: LocalCompetitionDashboard(
                    competitions: [match] + others,
                    awards: [],
                    issues: [],
                    hiddenTerminalCompetitionCount: 0
                ),
                source: source
            ),
            locale: Locale(identifier: "en_US")
        )
    }

    func testVersusIntroSaysFirstFightOrTitleOnTheLine() throws {
        let identity = "remote-profile:v1:sam"
        let scheduled = homePresentation(
            id: 9, name: "Sam", identity: identity, lifecycle: .scheduled, start: (10, 31)
        )

        let first = try XCTUnwrap(versusContent(scheduled))
        XCTAssertEqual(first.headline, "First fight")
        XCTAssertNil(first.holder)
        XCTAssertNil(first.yourTape)
        XCTAssertEqual(first.announcement, "You versus Sam. Day 1 is Saturday.")

        let dayOne = homePresentation(
            id: 9, name: "Sam", identity: identity, lifecycle: .active(dayOrdinal: 1), start: (10, 31)
        )
        XCTAssertEqual(versusContent(dayOne)?.dayLine, "Day 1 starts now")

        let weeks = [
            beltWeek(1, .win, start: (9, 1)),
            beltWeek(2, .loss, start: (9, 8)),
            beltWeek(3, .loss, start: (9, 15)),
        ]
        let rematch = try XCTUnwrap(versusContent(scheduled, with: weeks))
        XCTAssertEqual(rematch.headline, "Title on the line")
        XCTAssertEqual(rematch.holder, .them)
        XCTAssertEqual(rematch.yourTape, "1–2")
        XCTAssertEqual(rematch.theirTape, "2–1 · 1 defense")

        // Ties only: a record, but no belt to put on the line.
        let tied = try XCTUnwrap(versusContent(scheduled, with: [beltWeek(1, .tie, start: (9, 1))]))
        XCTAssertNil(tied.headline)
        XCTAssertNil(tied.holder)
        XCTAssertEqual(tied.theirTape, "0–0–1")

        // An earlier match still running could move the belt: nothing is claimed.
        let earlier = homePresentation(
            id: 8, name: "Sam", identity: identity, lifecycle: .active(dayOrdinal: 5), start: (10, 24)
        )
        let waiting = try XCTUnwrap(versusContent(scheduled, with: weeks + [earlier]))
        XCTAssertNil(waiting.headline)
        XCTAssertNil(waiting.holder)
        XCTAssertNil(try XCTUnwrap(versusContent(scheduled, with: [earlier])).headline)
    }

    func testVersusIntroIsOnlyForARealMatchThatHasJustBegun() {
        let scheduled = homePresentation(id: 1, lifecycle: .scheduled)
        XCTAssertNotNil(versusContent(scheduled))
        XCTAssertNil(versusContent(scheduled, source: .simulatedFixture))
        XCTAssertNil(versusContent(practicePresentation(id: 2, lifecycle: .scheduled)))
        XCTAssertNil(versusContent(practicePresentation(id: 2, lifecycle: .active(dayOrdinal: 1))))
        let won = LocalCompetitionLifecyclePresentation.completed(
            outcome: .win, basis: .stableAcrossPostBoundaryReads, completedAt: homeNow
        )
        let closed: [LocalCompetitionLifecyclePresentation] = [
            .pending(direction: .incoming, createdAt: homeNow, expiresAt: nil),
            .declined(at: homeNow, direction: .incoming),
            .expired(at: homeNow, direction: .outgoing),
            .cancelled(at: homeNow),
            .active(dayOrdinal: 2),
            .endsToday,
            .tallying(startedAt: homeNow),
            won,
        ]
        for lifecycle in closed {
            XCTAssertNil(versusContent(homePresentation(id: 1, lifecycle: lifecycle)), "\(lifecycle)")
        }
    }
}

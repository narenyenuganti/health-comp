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
                body: "Nothing for you to do. If Hermes doesn’t sync by Wed night, the result uses what’s in."
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

    func testMarginTextIsLabelledAndHiddenAtZero() {
        let en = Locale(identifier: "en_US")
        func margin(_ user: Double, _ opponent: Double, _ digits: Int) -> String? {
            competitionMarginText(
                userPoints: user, opponentPoints: opponent, fractionDigits: digits, locale: en
            )
        }
        XCTAssertEqual(margin(3410.2, 3180, 0), "Won by 230 points")
        XCTAssertEqual(margin(3180, 3410.2, 0), "Lost by 230 points")
        XCTAssertEqual(margin(413, 412, 0), "Won by 1 point")
        XCTAssertEqual(margin(412.3, 412.0, 2), "Won by 0.30 points")
        XCTAssertNil(margin(412, 412, 0))
        XCTAssertNil(margin(0.4, 0, 0))
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
            competitionVictoryCountText(1, friendDisplayName: "Alex"),
            "1 win against Alex"
        )
        XCTAssertEqual(
            competitionVictoryCountText(2, friendDisplayName: "Alex"),
            "2 wins against Alex"
        )
        XCTAssertEqual(
            competitionSharingIdentifier(first),
            "competition.sharing.completed.00000000-0000-0000-0000-000000000101"
        )
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
        evaluatedAt: Date? = nil
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
                userPoints: 0, opponentPoints: 0, outcome: outcome,
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
        XCTAssertEqual(text.detail, "Expires Sun 10:00 PM")
        let undated = competitionReceivedRematchText(challenge(expiresAt: nil), locale: locale, timeZone: utc)
        XCTAssertEqual(undated.title, "Alex sent a rematch")
        XCTAssertNil(undated.detail)
    }

    func testRecipientAndFailureCopy() {
        XCTAssertNil(competitionRecipientErrorText(.idle))
        XCTAssertNil(competitionRecipientErrorText(.lookingUp))
        XCTAssertEqual(
            competitionRecipientErrorText(.invalidCode),
            "That isn’t a full account code. Ask them to share it again."
        )
        XCTAssertEqual(competitionRecipientErrorText(.ownCode), "That’s your own code. Ask them for theirs.")
        XCTAssertEqual(competitionRecipientErrorText(.notFound), "No account has this code. Check it and try again.")
        XCTAssertEqual(
            competitionRecipientErrorText(.connectionFailed),
            "Couldn’t look up that code. Check your connection and try again."
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
            "Hermes isn’t on HealthComp anymore."
        )
        XCTAssertEqual(
            competitionInviteFailureText(.alreadyPending, opponentName: "Hermes"),
            "You already challenged Hermes. It expires 24 hours after you sent it."
        )
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

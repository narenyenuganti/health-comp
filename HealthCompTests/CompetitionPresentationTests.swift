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
            "Priya Won"
        )
        XCTAssertEqual(
            competitionResultSubtitle(
                outcome: .loss,
                opponentDisplayName: "Priya",
                source: source
            ),
            "Priya’s seven-day Activity total finished ahead."
        )
        XCTAssertEqual(
            competitionTallyAttentionText(
                .opponentPlanUnavailable,
                opponentDisplayName: "Priya",
                source: source
            ),
            "Finalizing Priya’s scores."
        )

        let allCopy = [
            competitionInviteTitle(
                direction: .outgoing,
                opponentDisplayName: "Priya"
            ),
            competitionResultTitle(
                outcome: .loss,
                opponentDisplayName: "Priya"
            ),
            competitionResultSubtitle(
                outcome: .loss,
                opponentDisplayName: "Priya",
                source: source
            ),
            competitionTallyAttentionText(
                .opponentPlanUnavailable,
                opponentDisplayName: "Priya",
                source: source
            ),
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
        XCTAssertEqual(
            competitionResultSubtitle(
                outcome: .loss,
                opponentDisplayName: "Alex",
                source: .simulatedFixture
            ),
            "Alex’s simulated seven-day total finished ahead."
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
            (.declined(at: created), [
                .row: ["Declined", nil], .card: ["Declined", nil],
                .notification: ["Challenge declined", nil],
            ]),
            (.expired(at: created), [
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
                .row: ["Tallying", nil], .card: ["Tallying", nil],
                .notification: ["Tallying", nil],
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
                .notification: ["You tied with Hermes", nil],
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
    }

    func testUnknownStandAndPauseStillSupportTruthfulSystemRings() throws {
        let snapshot = try makeSnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .unknown,
            pauseState: .unknown
        )

        XCTAssertTrue(activityRingSupportsSystemPresentation(snapshot))
        let label = activityRingAccessibilityLabel(
            snapshot,
            ownerDisplayName: "Naren",
            acceptedPoints: 1
        )
        XCTAssertTrue(label.contains("Naren activity"))
        XCTAssertTrue(label.contains("1 accepted point"))
        XCTAssertTrue(label.contains("Stand or Roll"))
        XCTAssertTrue(label.contains("pause status unknown"))
    }

    func testAcceptedPointsPluralizeOnTheShownNumber() throws {
        let snapshot = try makeSnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            pauseState: .running
        )
        func label(_ points: Double) -> String {
            activityRingAccessibilityLabel(
                snapshot, ownerDisplayName: "Naren", acceptedPoints: points
            )
        }
        for points in [0.6, 1.4] {
            XCTAssertTrue(label(points).contains("1 accepted point."), label(points))
        }
        XCTAssertTrue(label(1.6).contains("2 accepted points"), label(1.6))
        XCTAssertTrue(label(0.4).contains("0 accepted points"), label(0.4))
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

    func testMoveTimeRollAccessibilityUsesFullTruthfulUnits() throws {
        let snapshot = try makeSnapshot(
            moveMode: .moveMinutes,
            standMode: .rollHours,
            pauseState: .running
        )

        let label = activityRingAccessibilityLabel(
            snapshot,
            ownerDisplayName: "Naren",
            acceptedPoints: 600
        )

        XCTAssertTrue(label.contains("Move Time"))
        XCTAssertTrue(label.contains("60 of 30 minutes"))
        XCTAssertTrue(label.contains("Exercise, 60 of 30 minutes"))
        XCTAssertTrue(label.contains("Roll, 24 of 12 hours"))
        XCTAssertTrue(label.contains("600 accepted points"))
    }

    func testNilAcceptedSnapshotNeverClaimsEarlierHigherEvidence() throws {
        let day = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 9,
            timeZoneIdentifier: "UTC"
        )
        let latest = try makeSnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            pauseState: .running
        )
        let presentation = LocalCompetitionDayPresentation(
            day: day,
            ordinal: 1,
            ownerAcceptedPoints: nil,
            ownerLatestAvailability: .observed,
            opponentRevealedPoints: 200,
            ownerAcceptedSnapshot: nil,
            ownerLatestSnapshot: latest
        )

        let caption = activityEvidenceCaption(presentation)

        XCTAssertFalse(caption.contains("earlier higher"))
        XCTAssertTrue(caption.contains("No accepted score"))
    }

    func testDifferentAcceptedAndLatestSnapshotsUseNeutralPolicyCopy() throws {
        let day = try CompetitionDay(
            era: 1,
            year: 2026,
            month: 8,
            day: 9,
            timeZoneIdentifier: "UTC"
        )
        let accepted = try makeSnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            pauseState: .running
        )
        let latest = try makeSnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            pauseState: .paused
        )
        let presentation = LocalCompetitionDayPresentation(
            day: day,
            ordinal: 1,
            ownerAcceptedPoints: 600,
            ownerLatestAvailability: .observed,
            opponentRevealedPoints: 600,
            ownerAcceptedSnapshot: accepted,
            ownerLatestSnapshot: latest
        )

        let caption = activityEvidenceCaption(presentation)

        XCTAssertFalse(caption.contains("higher"))
        XCTAssertTrue(
            caption.contains("preserves earlier source evidence under the match scoring rules")
        )
    }

    func testTallyUsesProvisionalTotalsAndHonestDeadlineCopy() {
        let deadline = Date(timeIntervalSinceReferenceDate: 1_000)
        let tally = LocalCompetitionTallyPresentation(
            attention: .awaitingStability,
            consecutiveStableCompleteReads: 1,
            stabilityStart: nil,
            bestAvailableDeadline: deadline
        )

        XCTAssertEqual(
            competitionScoreTotalLabel(isProvisional: true),
            "Provisional total"
        )
        let copy = competitionTallyDeadlineText(
            tally,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertTrue(copy.contains("complete scores do not stabilize"))
        XCTAssertTrue(copy.contains("best available accepted data"))
        XCTAssertFalse(copy.contains("data is still incomplete"))
        XCTAssertFalse(copy.contains("finalizes by"))

        let incomplete = LocalCompetitionTallyPresentation(
            attention: .incomplete(
                missingOrdinals: [7],
                unavailableOrdinals: []
            ),
            consecutiveStableCompleteReads: 0,
            stabilityStart: nil,
            bestAvailableDeadline: deadline
        )
        let incompleteCopy = competitionTallyDeadlineText(
            incomplete,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertTrue(
            incompleteCopy.contains(
                "complete accepted scores are still unavailable"
            )
        )
        XCTAssertTrue(incompleteCopy.contains("best available accepted data"))
    }

    func testOpponentPlanAttentionUsesUserFacingSimulatedScoreCopy() {
        XCTAssertEqual(
            competitionTallyAttentionText(.opponentPlanUnavailable),
            "Finalizing Alex’s scores."
        )
    }

    func testEveryTallyAttentionHasUserFacingCopy() {
        let cases: [(LocalCompetitionTallyAttention, String)] = [
            (
                .noRead,
                "Waiting for the first complete Activity check after the match."
            ),
            (
                .incomplete(
                    missingOrdinals: [2],
                    unavailableOrdinals: [5]
                ),
                "Missing days: 2. Unavailable days: 5."
            ),
            (
                .unacceptedScores(ordinals: [3, 4]),
                "Waiting to accept scores for days 3, 4."
            ),
            (.opponentPlanUnavailable, "Finalizing Alex’s scores."),
            (.awaitingStability, "Waiting for one more stable read."),
        ]

        for (attention, expected) in cases {
            XCTAssertTrue(
                competitionTallyAttentionText(attention).contains(expected),
                "Missing tally copy for \(attention)"
            )
        }
    }

    func testMixedIncompleteTallyCopyNeverDropsAReason() {
        let first = competitionTallyAttentionText(
            .incomplete(
                missingOrdinals: [7],
                unavailableOrdinals: [2]
            )
        )
        XCTAssertTrue(first.contains("Missing days: 7"))
        XCTAssertTrue(first.contains("Unavailable days: 2"))

        let second = competitionTallyAttentionText(
            .incomplete(
                missingOrdinals: [2],
                unavailableOrdinals: [7]
            )
        )
        XCTAssertTrue(second.contains("Missing days: 2"))
        XCTAssertTrue(second.contains("Unavailable days: 7"))
    }

    func testOpponentPlanDeadlineDoesNotBlameAcceptedOwnerScores() {
        let tally = LocalCompetitionTallyPresentation(
            attention: .opponentPlanUnavailable,
            consecutiveStableCompleteReads: 0,
            stabilityStart: nil,
            bestAvailableDeadline: Date(timeIntervalSinceReferenceDate: 1_000)
        )

        let copy = competitionTallyDeadlineText(
            tally,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!
        )

        XCTAssertTrue(copy.contains("Alex’s final simulated scores"))
        XCTAssertFalse(copy.contains("accepted scores are still unavailable"))
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
        XCTAssertTrue(label.contains("Opponent, score not available."), label)
        XCTAssertFalse(label.contains("upcoming"))
        XCTAssertFalse(label.contains("--"))
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

    func testTallyScoreHeaderUsesFinalDayInsteadOfToday() {
        XCTAssertEqual(
            competitionScorePeriodLabel(.tallying(startedAt: .distantPast)),
            "Final day"
        )
        XCTAssertEqual(
            competitionScorePeriodLabel(.active(dayOrdinal: 3)),
            "Today"
        )
        XCTAssertEqual(competitionScorePeriodLabel(.endsToday), "Today")
    }

    func testAwardEarnedDateAndRivalrySummaryComeFromCanonicalDashboard() {
        let first = terminalPresentation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            outcome: .win,
            completedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let second = terminalPresentation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            outcome: .loss,
            completedAt: Date(timeIntervalSinceReferenceDate: 86_400)
        )
        let third = terminalPresentation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
            outcome: .tie,
            completedAt: Date(timeIntervalSinceReferenceDate: 172_800)
        )
        let competitions = [first, second, third]
        let awards = LocalCompetitionAward.fold(completed: competitions)
        let dashboard = LocalCompetitionDashboard(
            competitions: competitions,
            awards: awards,
            issues: [],
            hiddenTerminalCompetitionCount: 0
        )

        XCTAssertEqual(
            competitionRivalrySummary(dashboard),
            CompetitionRivalrySummary(
                completions: 3,
                ownerWins: 1,
                opponentWins: 1,
                ties: 1,
                latestOwnerVictoryAt: Date(timeIntervalSinceReferenceDate: 0)
            )
        )
        let victory = try! XCTUnwrap(
            awards.first(where: { $0.kind == .victory })
        )
        XCTAssertEqual(
            normalized(competitionAwardEarnedText(
                victory.awardedAt,
                now: Date(timeIntervalSinceReferenceDate: 2_592_000),
                locale: Locale(identifier: "en_US"),
                timeZone: TimeZone(identifier: "UTC")!
            )),
            "Earned Mon, Jan 1"
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

    private func terminalPresentation(
        id: UUID,
        outcome: CompetitionOutcome,
        completedAt: Date
    ) -> LocalCompetitionPresentation {
        let userPoints = outcome == .loss ? 100.0 : 200.0
        let opponentPoints: Double = switch outcome {
        case .win: 100
        case .loss: 200
        case .tie: 200
        }
        let terminal = LocalCompetitionTerminalPresentation(
            userPoints: userPoints,
            opponentPoints: opponentPoints,
            outcome: outcome,
            basis: .stableAcrossPostBoundaryReads,
            completedAt: completedAt
        )
        return LocalCompetitionPresentation(
            id: CompetitionID(id),
            ownerDisplayName: "Naren",
            opponentDisplayName: "Alex",
            lifecycle: .completed(
                outcome: outcome,
                basis: .stableAcrossPostBoundaryReads,
                completedAt: completedAt
            ),
            acceptedConfiguration: nil,
            userPoints: userPoints,
            opponentPoints: opponentPoints,
            days: [],
            currentDayOrdinal: nil,
            lastRefresh: nil,
            tally: nil,
            terminalResult: terminal,
            evaluatedAt: completedAt,
            timeZoneIdentifier: "UTC"
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

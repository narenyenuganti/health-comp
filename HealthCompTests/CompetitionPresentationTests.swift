import CompetitionCore
import SwiftUI
import UIKit
import XCTest
@testable import HealthComp

final class CompetitionPresentationTests: XCTestCase {
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
            "Outgoing invitation to Priya"
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

    func testScheduledCompetitionDisclosesConcreteFrozenDatesAndTimeZone()
        throws
    {
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
            competitionScheduleDateRangeText(
                schedule,
                locale: Locale(identifier: "en_US")
            ),
            "Aug 13, 2026–Aug 19, 2026 (America/Los_Angeles)"
        )
        XCTAssertEqual(
            competitionScheduleDateRangeText(
                schedule,
                locale: Locale(identifier: "fr_FR")
            ),
            "13 août 2026–19 août 2026 (America/Los_Angeles)"
        )
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
            timeZoneIdentifier: "UTC"
        )

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("Health data is locked"))
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
            "activity observed, no accepted score"
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
            caption.contains("preserves earlier source evidence under the competition scoring policy")
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
            timeZoneIdentifier: "UTC"
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
            timeZoneIdentifier: "UTC"
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
                "Waiting for the first complete post-competition Activity check."
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
            timeZoneIdentifier: "UTC"
        )

        XCTAssertTrue(copy.contains("Alex’s final simulated scores"))
        XCTAssertFalse(copy.contains("accepted scores are still unavailable"))
    }

    func testDayAccessibilityNamesTodayProgressClosedDateAndUpcomingState() {
        let observed = presentation(.observed, points: 321)
        let today = competitionDayAccessibilityLabel(
            observed,
            currentDayOrdinal: observed.ordinal,
            ownerName: "Naren",
            opponentName: "Alex"
        )
        XCTAssertTrue(today.contains("Today"))
        XCTAssertTrue(today.contains("so far"))

        let closed = competitionDayAccessibilityLabel(
            observed,
            currentDayOrdinal: nil,
            ownerName: "Naren",
            opponentName: "Alex"
        )
        XCTAssertTrue(closed.contains("August 9"))
        XCTAssertTrue(closed.contains("complete"))

        let future = competitionDayAccessibilityLabel(
            presentation(.notYetOccurred, points: nil),
            currentDayOrdinal: nil,
            ownerName: "Naren",
            opponentName: "Alex"
        )
        XCTAssertTrue(future.contains("upcoming"))
        XCTAssertTrue(future.contains("--"))
        XCTAssertFalse(future.contains("Alex final"))
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
            competitionAwardEarnedText(
                victory.awardedAt,
                timeZoneIdentifier: "UTC"
            ),
            "Earned Jan 1, 2001"
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

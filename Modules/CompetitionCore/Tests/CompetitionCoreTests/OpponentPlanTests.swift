import Foundation
import XCTest

@testable import CompetitionCore

final class OpponentPlanTests: XCTestCase {
    private let engine = CompetitionEngine()
    private let competitionID = CompetitionID(
        UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    )

    func testSHA256MatchesStandardVectors() {
        XCTAssertEqual(
            SHA256Digest.hexDigest(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            SHA256Digest.hexDigest(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            SHA256Digest.hexDigest(Data(repeating: 0x61, count: 1_000_000)),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }

    func testSplitMix64MatchesPinnedGoldenVector() {
        var generator = SplitMix64(seed: 0)

        XCTAssertEqual(generator.next(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(generator.next(), 0x6E78_9E6A_A1B9_65F4)
        XCTAssertEqual(generator.next(), 0x06C4_5D18_8009_454F)
        XCTAssertEqual(generator.next(), 0xF88B_B8A8_724C_81EC)
    }

    func testPinnedBoundedSamplingIsDeterministicAtEdgeBounds() {
        var first = SplitMix64(seed: 0)
        var second = SplitMix64(seed: 0)

        XCTAssertEqual(first.next(upperBound: 1), 0)
        XCTAssertEqual(second.next(upperBound: 1), 0)
        XCTAssertEqual(first.next(upperBound: 601), 157)
        XCTAssertEqual(second.next(upperBound: 601), 157)
    }

    func testBoundedSamplingGoldenForcesTheRejectionPath() {
        var generator = SplitMix64(seed: 3)

        XCTAssertEqual(
            generator.next(upperBound: 9_223_372_036_854_775_809),
            3_694_763_184_872_335_752
        )
    }

    func testBalancedGoldenPlanPinsTargetsCheckpointsAndCommitment() throws {
        let plan = try generate(seed: 42, difficulty: .balanced)

        XCTAssertEqual(plan.days.map(\.finalPoints), [345, 400, 386, 433, 284, 421, 478])
        XCTAssertEqual(
            plan.days[0].checkpoints,
            [
                try OpponentCheckpoint(progressBasisPoints: 0, cumulativePoints: 0),
                try OpponentCheckpoint(progressBasisPoints: 1_311, cumulativePoints: 45),
                try OpponentCheckpoint(progressBasisPoints: 3_041, cumulativePoints: 104),
                try OpponentCheckpoint(progressBasisPoints: 4_473, cumulativePoints: 154),
                try OpponentCheckpoint(progressBasisPoints: 5_762, cumulativePoints: 198),
                try OpponentCheckpoint(progressBasisPoints: 6_961, cumulativePoints: 240),
                try OpponentCheckpoint(progressBasisPoints: 8_411, cumulativePoints: 290),
                try OpponentCheckpoint(progressBasisPoints: 10_000, cumulativePoints: 345),
            ]
        )
        XCTAssertEqual(
            plan.commitmentHex,
            "e07fa4888f99d79a7d4107d0571b34cad2c1a0eadb7de7c6019e7896de1d09fb"
        )
        XCTAssertEqual(
            plan.contentIdentity,
            "opponent-plan:v1:g1:sha256:e07fa4888f99d79a7d4107d0571b34cad2c1a0eadb7de7c6019e7896de1d09fb"
        )
    }

    func testSameInputsProduceIdenticalCanonicalBytesAndHash() throws {
        let first = try generate(seed: 42, difficulty: .balanced)
        let second = try generate(seed: 42, difficulty: .balanced)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.canonicalBytes, second.canonicalBytes)
        XCTAssertEqual(first.commitmentHex, second.commitmentHex)
        XCTAssertEqual(try JSONDecoder().decode(OpponentPlan.self, from: JSONEncoder().encode(first)), first)
    }

    func testDifferentSeedChangesCommittedContent() throws {
        let first = try generate(seed: 42, difficulty: .balanced)
        let second = try generate(seed: 43, difficulty: .balanced)

        XCTAssertNotEqual(first.days, second.days)
        XCTAssertNotEqual(first.canonicalBytes, second.canonicalBytes)
        XCTAssertNotEqual(first.commitmentHex, second.commitmentHex)
    }

    func testCommitmentCoversValidInteriorCheckpointChangesBeyondFinalScores() throws {
        let original = try generate(seed: 42, difficulty: .balanced)
        var changedCheckpoints = original.days[0].checkpoints
        changedCheckpoints[1] = try OpponentCheckpoint(
            progressBasisPoints: changedCheckpoints[1].progressBasisPoints,
            cumulativePoints: changedCheckpoints[1].cumulativePoints + 1
        )
        var changedDays = original.days
        changedDays[0] = try OpponentDayPlan(
            ordinal: original.days[0].ordinal,
            finalPoints: original.days[0].finalPoints,
            checkpoints: changedCheckpoints
        )
        let changed = try OpponentPlan(
            schemaVersion: original.schemaVersion,
            generatorVersion: original.generatorVersion,
            seed: original.seed,
            difficulty: original.difficulty,
            schedule: original.schedule,
            days: changedDays
        )
        let owner = try ownerWindow(
            pointsByOrdinal: Dictionary(
                uniqueKeysWithValues: (1...7).map { ($0, 300) }
            )
        )
        let originalContent = try original.finalScoreWindow.completeWindowContent(
            ownerWindow: owner
        )
        let changedContent = try changed.finalScoreWindow.completeWindowContent(
            ownerWindow: owner
        )

        XCTAssertEqual(original.days.map(\.finalPoints), changed.days.map(\.finalPoints))
        XCTAssertNotEqual(original.commitmentHex, changed.commitmentHex)
        XCTAssertNotEqual(original.contentIdentity, changed.contentIdentity)
        XCTAssertEqual(originalContent.finalScoreSnapshot, changedContent.finalScoreSnapshot)
        XCTAssertNotEqual(originalContent.fingerprint, changedContent.fingerprint)

        let staleDigestPayload = try encodedJSONObject(for: original) { root in
            var days = root["days"] as! [[String: Any]]
            var checkpoints = days[0]["checkpoints"] as! [[String: Any]]
            checkpoints[1]["cumulativePoints"] = changedCheckpoints[1].cumulativePoints
            days[0]["checkpoints"] = checkpoints
            root["days"] = days
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(OpponentPlan.self, from: staleDigestPayload)
        )
    }

    func testGeneratedPlanHasExactlySevenCanonicalMonotoneDays() throws {
        let plan = try generate(seed: UInt64.max, difficulty: .challenging)

        XCTAssertEqual(plan.days.map(\.ordinal), Array(1...7))
        for day in plan.days {
            XCTAssertEqual(day.checkpoints.first, try OpponentCheckpoint(progressBasisPoints: 0, cumulativePoints: 0))
            XCTAssertEqual(day.checkpoints.last, try OpponentCheckpoint(progressBasisPoints: 10_000, cumulativePoints: day.finalPoints))
            XCTAssertEqual(day.checkpoints.map(\.progressBasisPoints), day.checkpoints.map(\.progressBasisPoints).sorted())
            XCTAssertEqual(day.checkpoints.map(\.cumulativePoints), day.checkpoints.map(\.cumulativePoints).sorted())
        }
    }

    func testCheckpointRejectsOutOfRangeCoordinatesAndPoints() {
        XCTAssertThrowsError(try OpponentCheckpoint(progressBasisPoints: -1, cumulativePoints: 0))
        XCTAssertThrowsError(try OpponentCheckpoint(progressBasisPoints: 10_001, cumulativePoints: 0))
        XCTAssertThrowsError(try OpponentCheckpoint(progressBasisPoints: 0, cumulativePoints: -1))
        XCTAssertThrowsError(try OpponentCheckpoint(progressBasisPoints: 0, cumulativePoints: 601))
    }

    func testDayRejectsMissingInitialOrTerminalCheckpoint() throws {
        XCTAssertThrowsError(
            try OpponentDayPlan(
                ordinal: 1,
                finalPoints: 300,
                checkpoints: [try OpponentCheckpoint(progressBasisPoints: 10_000, cumulativePoints: 300)]
            )
        )
        XCTAssertThrowsError(
            try OpponentDayPlan(
                ordinal: 1,
                finalPoints: 300,
                checkpoints: [try OpponentCheckpoint(progressBasisPoints: 0, cumulativePoints: 0)]
            )
        )
    }

    func testDayRejectsDuplicateProgressAndDecreasingPoints() throws {
        XCTAssertThrowsError(
            try OpponentDayPlan(
                ordinal: 1,
                finalPoints: 300,
                checkpoints: [
                    try OpponentCheckpoint(progressBasisPoints: 0, cumulativePoints: 0),
                    try OpponentCheckpoint(progressBasisPoints: 5_000, cumulativePoints: 200),
                    try OpponentCheckpoint(progressBasisPoints: 5_000, cumulativePoints: 250),
                    try OpponentCheckpoint(progressBasisPoints: 10_000, cumulativePoints: 300),
                ]
            )
        )
        XCTAssertThrowsError(
            try OpponentDayPlan(
                ordinal: 1,
                finalPoints: 300,
                checkpoints: [
                    try OpponentCheckpoint(progressBasisPoints: 0, cumulativePoints: 0),
                    try OpponentCheckpoint(progressBasisPoints: 5_000, cumulativePoints: 250),
                    try OpponentCheckpoint(progressBasisPoints: 7_500, cumulativePoints: 200),
                    try OpponentCheckpoint(progressBasisPoints: 10_000, cumulativePoints: 300),
                ]
            )
        )
    }

    func testDecodeRejectsCommitmentTampering() throws {
        let data = try encodedJSONObject(for: generate(seed: 42, difficulty: .balanced)) { root in
            root["commitmentHex"] = String(repeating: "0", count: 64)
        }

        XCTAssertThrowsError(try JSONDecoder().decode(OpponentPlan.self, from: data))
    }

    func testDecodeRejectsContentTamperingAndMalformedDays() throws {
        let data = try encodedJSONObject(for: generate(seed: 42, difficulty: .balanced)) { root in
            var days = root["days"] as! [[String: Any]]
            days[0]["finalPoints"] = 346
            root["days"] = Array(days.dropLast()) + [days[0]]
        }

        XCTAssertThrowsError(try JSONDecoder().decode(OpponentPlan.self, from: data))
    }

    func testDecodeRejectsNonCanonicalDayOrderWithoutNormalizingIt() throws {
        let data = try encodedJSONObject(for: generate(seed: 42, difficulty: .balanced)) { root in
            let days = root["days"] as! [[String: Any]]
            root["days"] = Array(days.reversed())
        }

        XCTAssertThrowsError(try JSONDecoder().decode(OpponentPlan.self, from: data))
    }

    func testDecodeRejectsUnknownSchemaAndNonCanonicalDigest() throws {
        let unknownSchema = try encodedJSONObject(for: generate(seed: 42, difficulty: .balanced)) { root in
            root["schemaVersion"] = 2
        }
        let uppercaseDigest = try encodedJSONObject(for: generate(seed: 42, difficulty: .balanced)) { root in
            root["commitmentHex"] = (root["commitmentHex"] as! String).uppercased()
        }

        XCTAssertThrowsError(try JSONDecoder().decode(OpponentPlan.self, from: unknownSchema))
        XCTAssertThrowsError(try JSONDecoder().decode(OpponentPlan.self, from: uppercaseDigest))
    }

    func testStructurallyValidUnknownGeneratorVersionCanReplayButCannotGenerate() throws {
        let current = try generate(seed: 42, difficulty: .balanced)
        let replayable = try OpponentPlan(
            schemaVersion: 1,
            generatorVersion: OpponentGeneratorVersion(rawValue: 99),
            seed: current.seed,
            difficulty: current.difficulty,
            schedule: current.schedule,
            days: current.days
        )

        XCTAssertEqual(
            try JSONDecoder().decode(OpponentPlan.self, from: JSONEncoder().encode(replayable)),
            replayable
        )
        XCTAssertNotEqual(replayable.commitmentHex, current.commitmentHex)
        XCTAssertNotEqual(replayable.contentIdentity, current.contentIdentity)
        XCTAssertThrowsError(
            try OpponentPlanGenerator.generate(
                seed: 42,
                generatorVersion: OpponentGeneratorVersion(rawValue: 99),
                difficulty: .balanced,
                schedule: schedule()
            )
        )
    }

    func testRevealIsPureRepeatableAndSupportsOutOfOrderReads() throws {
        let plan = try generate(seed: 42, difficulty: .balanced)
        let day = plan.days[0]
        let before = plan.canonicalBytes

        XCTAssertEqual(try plan.revealedPoints(dayOrdinal: 1, progressBasisPoints: 10_000), day.finalPoints)
        XCTAssertEqual(try plan.revealedPoints(dayOrdinal: 1, progressBasisPoints: 0), 0)
        XCTAssertEqual(try plan.revealedPoints(dayOrdinal: 1, progressBasisPoints: 2_000), 45)
        XCTAssertEqual(try plan.revealedPoints(dayOrdinal: 1, progressBasisPoints: 2_000), 45)
        XCTAssertEqual(plan.canonicalBytes, before)
    }

    func testRevealRejectsInvalidOrdinalAndProgress() throws {
        let plan = try generate(seed: 42, difficulty: .balanced)

        XCTAssertThrowsError(try plan.revealedPoints(dayOrdinal: 0, progressBasisPoints: 0))
        XCTAssertThrowsError(try plan.revealedPoints(dayOrdinal: 8, progressBasisPoints: 0))
        XCTAssertThrowsError(try plan.revealedPoints(dayOrdinal: 1, progressBasisPoints: -1))
        XCTAssertThrowsError(try plan.revealedPoints(dayOrdinal: 1, progressBasisPoints: 10_001))
    }

    func testDifficultyV1HardBoundsHoldAcrossSeedSweep() throws {
        let bounds: [(OpponentDifficulty, ClosedRange<Int>, ClosedRange<Int>)] = [
            (.relaxed, 180...360, 6...8),
            (.balanced, 260...480, 7...9),
            (.challenging, 360...600, 8...10),
        ]

        for (difficulty, pointsRange, checkpointRange) in bounds {
            var observedFinalPoints = Set<Int>()
            for seed in UInt64(0)..<UInt64(32) {
                let plan = try generate(seed: seed, difficulty: difficulty)
                for day in plan.days {
                    XCTAssertTrue(pointsRange.contains(day.finalPoints))
                    XCTAssertTrue(checkpointRange.contains(day.checkpoints.count))
                    observedFinalPoints.insert(day.finalPoints)
                }
            }
            XCTAssertGreaterThan(observedFinalPoints.count, 16)
        }
        let identities = try Set(
            OpponentDifficulty.allCases.map {
                try generate(seed: 42, difficulty: $0).contentIdentity
            }
        )
        XCTAssertEqual(identities.count, OpponentDifficulty.allCases.count)
    }

    func testDSTStartScheduleIsDeterministicAcrossAmbientTimeZoneAndLanguageChanges() throws {
        let explicitSchedule = try schedule(
            year: 2026,
            month: 3,
            startDay: 7
        )
        let baseline = try OpponentPlanGenerator.generate(
            seed: 77,
            generatorVersion: .v1,
            difficulty: .balanced,
            schedule: explicitSchedule
        )
        let previousTimeZone = NSTimeZone.default
        let previousLanguages = UserDefaults.standard.object(
            forKey: "AppleLanguages"
        )
        defer {
            NSTimeZone.default = previousTimeZone
            if let previousLanguages {
                UserDefaults.standard.set(
                    previousLanguages,
                    forKey: "AppleLanguages"
                )
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
        }

        NSTimeZone.default = TimeZone(identifier: "Pacific/Honolulu")!
        UserDefaults.standard.set(["tr-TR"], forKey: "AppleLanguages")
        let underDifferentAmbientSettings = try OpponentPlanGenerator.generate(
            seed: 77,
            generatorVersion: .v1,
            difficulty: .balanced,
            schedule: explicitSchedule
        )

        XCTAssertEqual(underDifferentAmbientSettings, baseline)
        XCTAssertEqual(
            underDifferentAmbientSettings.canonicalBytes,
            baseline.canonicalBytes
        )
    }

    func testPersistedStartDayParticipatesInPlanIdentityWithoutChangingInvariants() throws {
        let first = try OpponentPlanGenerator.generate(
            seed: 77,
            generatorVersion: .v1,
            difficulty: .balanced,
            schedule: schedule(startDay: 2)
        )
        let nextDay = try OpponentPlanGenerator.generate(
            seed: 77,
            generatorVersion: .v1,
            difficulty: .balanced,
            schedule: schedule(startDay: 3)
        )

        XCTAssertNotEqual(first.commitmentHex, nextDay.commitmentHex)
        XCTAssertEqual(first.days.map(\.ordinal), Array(1...7))
        XCTAssertEqual(nextDay.days.map(\.ordinal), Array(1...7))
    }

    func testFinalWindowUsesExactIntegerPointsAndCannotExceedFortyTwoHundred() throws {
        for difficulty in OpponentDifficulty.allCases {
            let window = try generate(
                seed: UInt64.max,
                difficulty: difficulty
            ).finalScoreWindow

            XCTAssertEqual(window.days.map(\.ordinal), Array(1...7))
            XCTAssertLessThanOrEqual(window.totalPoints, 4_200)
            for day in window.days {
                XCTAssertTrue((0...600).contains(day.points))
                XCTAssertEqual(Double(exactly: day.points), Double(day.points))
            }
        }
    }

    func testSamePlanNaturallyProducesLossTieAndWinWithoutOwnerCoupling() throws {
        let plan = try generate(seed: 42, difficulty: .balanced)
        let originalBytes = plan.canonicalBytes
        let opponentPoints = Dictionary(uniqueKeysWithValues: plan.days.map { ($0.ordinal, $0.finalPoints) })
        let low = try ownerWindow(pointsByOrdinal: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, 0) }))
        let equal = try ownerWindow(pointsByOrdinal: opponentPoints)
        let high = try ownerWindow(pointsByOrdinal: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, 600) }))

        let lowContent = try plan.finalScoreWindow.completeWindowContent(ownerWindow: low)
        let equalContent = try plan.finalScoreWindow.completeWindowContent(ownerWindow: equal)
        let highContent = try plan.finalScoreWindow.completeWindowContent(ownerWindow: high)
        let expectedOpponentPoints = plan.days.map { Double($0.finalPoints) }

        XCTAssertEqual(lowContent.finalScoreSnapshot.outcome, .loss)
        XCTAssertEqual(equalContent.finalScoreSnapshot.outcome, .tie)
        XCTAssertEqual(highContent.finalScoreSnapshot.outcome, .win)
        for content in [lowContent, equalContent, highContent] {
            XCTAssertEqual(content.days.map(\.opponentPoints), expectedOpponentPoints)
            XCTAssertEqual(content.opponentPlanVersion, plan.contentIdentity)
        }
        XCTAssertEqual(plan.canonicalBytes, originalBytes)
    }

    func testLivePairingPreservesLatestOwnerContentFingerprint() throws {
        var ledger = try ledger(pointsByOrdinal: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, 300) }))
        _ = try ledger.record(try snapshot(points: 100), forDayOrdinal: 1)
        let owner = try XCTUnwrap(ledger.completeLiveWindowObservation())
        let plan = try generate(seed: 42, difficulty: .balanced)

        let content = try plan.finalScoreWindow.completeWindowContent(ownerWindow: owner)

        XCTAssertEqual(content.days[0].userPoints, 300)
        XCTAssertEqual(content.days[0].activityContentFingerprint, owner.days[0].activityContentFingerprint.rawValue)
        XCTAssertEqual(content.opponentPlanVersion, plan.contentIdentity)
    }

    func testAcceptanceAtomicallyCarriesScheduleAndCompleteOpponentPlan() throws {
        var competition = pending()
        let acceptedAt = date(2026, 12, 31, 23, 30)
        let request = OpponentPlanGenerationRequest(
            seed: 42,
            generatorVersion: .v1,
            difficulty: .balanced
        )

        let event = try engine.accept(
            competition,
            at: acceptedAt,
            timeZoneIdentifier: "America/Los_Angeles",
            opponent: request
        )
        guard case let .invitationAccepted(configuration) = event.kind else {
            return XCTFail("Acceptance must carry one atomic configuration")
        }
        XCTAssertEqual(configuration.opponentPlan.days.count, 7)
        XCTAssertEqual(configuration.opponentPlan.seed, 42)

        try engine.apply(event, to: &competition)
        XCTAssertEqual(competition.schedule, configuration.schedule)
        XCTAssertEqual(competition.opponentPlan, configuration.opponentPlan)
    }

    func testAcceptedConfigurationRejectsScheduleThatDiffersFromCommittedPlan() throws {
        let plan = try generate(seed: 42, difficulty: .balanced)

        XCTAssertThrowsError(
            try AcceptedCompetitionConfiguration(
                schedule: schedule(startDay: 3),
                opponentPlan: plan
            )
        )

        let configuration = try AcceptedCompetitionConfiguration(
            schedule: plan.schedule,
            opponentPlan: plan
        )
        let tampered = try encodedJSONObject(for: configuration) { root in
            var schedule = root["schedule"] as! [String: Any]
            var startDay = schedule["startDay"] as! [String: Any]
            startDay["day"] = 3
            schedule["startDay"] = startDay
            root["schedule"] = schedule
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AcceptedCompetitionConfiguration.self,
                from: tampered
            )
        )
    }

    func testExpiredAcceptanceDoesNotGenerateOrStoreOpponentPlan() throws {
        let expiry = date(2026, 8, 10, 10)
        var competition = pending(expiresAt: expiry)
        let unsupportedRequest = OpponentPlanGenerationRequest(
            seed: 42,
            generatorVersion: OpponentGeneratorVersion(rawValue: 99),
            difficulty: .balanced
        )

        let event = try engine.accept(
            competition,
            at: expiry,
            timeZoneIdentifier: "America/Los_Angeles",
            opponent: unsupportedRequest
        )
        XCTAssertEqual(event.kind, .invitationExpired)
        try engine.apply(event, to: &competition)
        XCTAssertNil(competition.schedule)
        XCTAssertNil(competition.opponentPlan)
    }

    func testDuplicateAcceptanceReplayIsNoOpAndKeepsOriginalPlanBytes() throws {
        var competition = pending()
        let event = try engine.accept(
            competition,
            at: date(2026, 8, 9, 10),
            timeZoneIdentifier: "America/Los_Angeles",
            opponent: OpponentPlanGenerationRequest(
                seed: 42,
                generatorVersion: .v1,
                difficulty: .balanced
            )
        )
        try engine.apply(event, to: &competition)
        let afterFirstApply = competition

        try engine.apply(event, to: &competition)

        XCTAssertEqual(competition, afterFirstApply)
        XCTAssertEqual(competition.opponentPlan?.canonicalBytes, afterFirstApply.opponentPlan?.canonicalBytes)
        XCTAssertEqual(competition.appliedEventIDs.filter { $0 == event.id }.count, 1)
    }

    func testStableReadsWithWrongPlanIdentityAreRejectedWithoutMutation() throws {
        let competition = try tallyingCompetition()
        let correct = try sourceDerivedContent(for: competition)
        let forged = try CompleteWindowContent(
            days: correct.days,
            opponentPlanVersion: "opponent-plan:v1:g1:sha256:forged"
        )

        for (attempt, minute, monotonic) in [
            ("wrong-identity-1", 1, UInt64(100)),
            ("wrong-identity-2", 3, UInt64(200)),
        ] {
            let unchanged = competition
            XCTAssertThrowsError(
                try engine.recordFinalRead(
                    unchanged,
                    evidence: try completeEvidence(
                        attemptID: attempt,
                        minute: minute,
                        monotonicNanoseconds: monotonic,
                        content: forged
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? CompetitionEngine.EngineError,
                    .opponentPlanMismatch
                )
            }
            XCTAssertEqual(unchanged, competition)
        }
    }

    func testCorrectIdentityWithOneOrAllWrongOpponentDaysIsRejected() throws {
        let competition = try tallyingCompetition()
        let correct = try sourceDerivedContent(for: competition)
        for changedOrdinals in [Set([1]), Set(1...7)] {
            let forged = try CompleteWindowContent(
                days: correct.days.map { day in
                    WindowDayContent(
                        ordinal: day.ordinal,
                        userPoints: day.userPoints,
                        opponentPoints: changedOrdinals.contains(day.ordinal)
                            ? day.opponentPoints + 1
                            : day.opponentPoints,
                        activityContentFingerprint:
                            day.activityContentFingerprint
                    )
                },
                opponentPlanVersion: correct.opponentPlanVersion
            )

            XCTAssertThrowsError(
                try engine.recordFinalRead(
                    competition,
                    evidence: try completeEvidence(
                        attemptID: "wrong-points-\(changedOrdinals.count)",
                        minute: changedOrdinals.count,
                        monotonicNanoseconds: UInt64(changedOrdinals.count),
                        content: forged
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? CompetitionEngine.EngineError,
                    .opponentPlanMismatch
                )
            }
        }
    }

    func testDecodedForgedFinalReadEventIsRejectedAtApplyWithoutMutation() throws {
        var competition = try tallyingCompetition()
        let before = competition
        let correct = try sourceDerivedContent(for: competition)
        let forged = try CompleteWindowContent(
            days: correct.days.map { day in
                WindowDayContent(
                    ordinal: day.ordinal,
                    userPoints: day.userPoints,
                    opponentPoints: day.ordinal == 4
                        ? day.opponentPoints + 1
                        : day.opponentPoints,
                    activityContentFingerprint: day.activityContentFingerprint
                )
            },
            opponentPlanVersion: correct.opponentPlanVersion
        )
        let prebuilt = CompetitionEvent(
            competitionID: competition.id,
            occurredAt: date(2026, 8, 17, 0, 1),
            kind: .finalReadRecorded(
                FinalReadRecord(
                    evidence: try completeEvidence(
                        attemptID: "decoded-forged-read",
                        minute: 1,
                        monotonicNanoseconds: 100,
                        content: forged
                    )
                )
            )
        )
        let decoded = try JSONDecoder().decode(
            CompetitionEvent.self,
            from: JSONEncoder().encode(prebuilt)
        )

        XCTAssertThrowsError(try engine.apply(decoded, to: &competition)) {
            XCTAssertEqual(
                $0 as? CompetitionEngine.EngineError,
                .opponentPlanMismatch
            )
        }
        XCTAssertEqual(competition, before)
    }

    func testTamperedTallyCannotAuthorizeFinalizeOrApplyPrebuiltFinalization() throws {
        var competition = try tallyingCompetition()
        let correct = try sourceDerivedContent(for: competition)
        let forged = try CompleteWindowContent(
            days: correct.days,
            opponentPlanVersion: "forged-reconstructed-plan"
        )
        var tally = try XCTUnwrap(tallyState(competition))
        let first = try completeEvidence(
            attemptID: "reconstructed-forged-1",
            minute: 1,
            monotonicNanoseconds: 100,
            content: forged
        )
        let second = try completeEvidence(
            attemptID: "reconstructed-forged-2",
            minute: 3,
            monotonicNanoseconds: 200,
            content: forged
        )
        tally.reconciliation.record(first, boundary: tally.startedAt)
        tally.reconciliation.record(second, boundary: tally.startedAt)
        competition.lifecycle = .tallying(tally)
        let policy = finalizationPolicy()

        XCTAssertEqual(
            policy.decision(for: competition, at: date(2026, 8, 17, 0, 3)),
            .needsAttention(.opponentPlanContentMismatch)
        )

        let forgedAuthorization = FinalizationAuthorization(
            competitionID: competition.id,
            reconciliationRevision: tally.reconciliation.revision,
            eligibleAttemptID: second.attemptID,
            snapshot: forged.finalScoreSnapshot,
            basis: .stableAcrossPostBoundaryReads,
            policy: policy,
            decisionAt: date(2026, 8, 17, 0, 3)
        )
        XCTAssertThrowsError(
            try engine.finalize(
                competition,
                authorization: forgedAuthorization,
                at: date(2026, 8, 17, 0, 3)
            )
        )
        let prebuiltFinalization = CompetitionEvent(
            competitionID: competition.id,
            occurredAt: date(2026, 8, 17, 0, 3),
            kind: .competitionFinalized(
                FinalizationRecord(authorization: forgedAuthorization)
            )
        )
        XCTAssertThrowsError(
            try engine.apply(prebuiltFinalization, to: &competition)
        )
        guard case .tallying = competition.lifecycle else {
            return XCTFail("Forged finalization must not leave tallying")
        }
    }

    func testMissingOpponentPlanCannotRecordCompleteEvidenceOrAuthorize() throws {
        var competition = try tallyingCompetition()
        let content = try sourceDerivedContent(for: competition)
        competition.opponentPlan = nil

        XCTAssertThrowsError(
            try engine.recordFinalRead(
                competition,
                evidence: try completeEvidence(
                    attemptID: "missing-opponent-plan",
                    minute: 1,
                    monotonicNanoseconds: 100,
                    content: content
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionEngine.EngineError,
                .opponentPlanMismatch
            )
        }
        XCTAssertEqual(
            finalizationPolicy().decision(
                for: competition,
                at: date(2026, 8, 17, 0, 1)
            ),
            .needsAttention(.opponentPlanContentMismatch)
        )
    }

    func testSourceDerivedContentStillStabilizesAndFinalizes() throws {
        var competition = try tallyingCompetition()
        let content = try sourceDerivedContent(for: competition)
        for (attempt, minute, monotonic) in [
            ("source-derived-1", 1, UInt64(100)),
            ("source-derived-2", 3, UInt64(200)),
        ] {
            let event = try engine.recordFinalRead(
                competition,
                evidence: try completeEvidence(
                    attemptID: attempt,
                    minute: minute,
                    monotonicNanoseconds: monotonic,
                    content: content
                )
            )
            try engine.apply(event, to: &competition)
        }
        let policy = finalizationPolicy()
        guard case let .finalize(authorization) = policy.decision(
            for: competition,
            at: date(2026, 8, 17, 0, 3)
        ) else {
            return XCTFail("Source-derived content must authorize")
        }

        try engine.apply(
            engine.finalize(
                competition,
                authorization: authorization,
                at: date(2026, 8, 17, 0, 3)
            ),
            to: &competition
        )
        guard case .completed = competition.lifecycle else {
            return XCTFail("Source-derived finalization must complete")
        }
    }

    func testIncompleteOwnerEvidenceRemainsRecordableAndWaiting() throws {
        var competition = try tallyingCompetition()
        let evidence = try FinalReadEvidence(
            attemptID: "incomplete-owner-evidence",
            readAt: date(2026, 8, 17, 0, 1),
            monotonicInstant: MonotonicInstant(
                epochID: "opponent-binding-test",
                nanoseconds: 100
            ),
            evaluableOrdinals: Set(1...6),
            acceptedScoreOrdinals: Set(1...6),
            missingOrdinals: [7],
            unavailableOrdinals: [],
            completeWindowContent: nil,
            opponentPlanIsFinal: true
        )

        try engine.apply(
            engine.recordFinalRead(competition, evidence: evidence),
            to: &competition
        )

        XCTAssertEqual(
            finalizationPolicy().decision(
                for: competition,
                at: date(2026, 8, 17, 0, 2)
            ),
            .wait
        )
    }

    private func generate(seed: UInt64, difficulty: OpponentDifficulty) throws -> OpponentPlan {
        try OpponentPlanGenerator.generate(
            seed: seed,
            generatorVersion: .v1,
            difficulty: difficulty,
            schedule: schedule()
        )
    }

    private func tallyingCompetition() throws -> Competition {
        var competition = pending()
        try engine.apply(
            engine.accept(
                competition,
                at: date(2026, 8, 9, 10),
                timeZoneIdentifier: "America/Los_Angeles",
                opponent: OpponentPlanGenerationRequest(
                    seed: 42,
                    generatorVersion: .v1,
                    difficulty: .balanced
                )
            ),
            to: &competition
        )
        try engine.apply(
            engine.observeClock(
                competition,
                at: date(2026, 8, 17, 0, 0)
            ),
            to: &competition
        )
        return competition
    }

    private func sourceDerivedContent(
        for competition: Competition
    ) throws -> CompleteWindowContent {
        let plan = try XCTUnwrap(competition.opponentPlan)
        let owner = try ownerWindow(
            pointsByOrdinal: Dictionary(
                uniqueKeysWithValues: (1...7).map { ($0, 300) }
            )
        )
        return try plan.finalScoreWindow.completeWindowContent(
            ownerWindow: owner
        )
    }

    private func completeEvidence(
        attemptID: String,
        minute: Int,
        monotonicNanoseconds: UInt64,
        content: CompleteWindowContent,
        opponentPlanIsFinal: Bool = true
    ) throws -> FinalReadEvidence {
        try FinalReadEvidence(
            attemptID: attemptID,
            readAt: date(2026, 8, 17, 0, minute),
            monotonicInstant: MonotonicInstant(
                epochID: "opponent-binding-test",
                nanoseconds: monotonicNanoseconds
            ),
            evaluableOrdinals: Set(1...7),
            acceptedScoreOrdinals: Set(1...7),
            missingOrdinals: [],
            unavailableOrdinals: [],
            completeWindowContent: content,
            opponentPlanIsFinal: opponentPlanIsFinal
        )
    }

    private func tallyState(_ competition: Competition) -> TallyingCompetition? {
        guard case let .tallying(tally) = competition.lifecycle else {
            return nil
        }
        return tally
    }

    private func finalizationPolicy() -> FinalizationPolicy {
        FinalizationPolicy(
            minimumStabilityNanoseconds: 100,
            bestAvailableDeadline: date(2026, 8, 17, 0, 30)
        )
    }

    private func schedule(
        year: Int = 2027,
        month: Int = 1,
        startDay: Int = 2
    ) throws -> CompetitionSchedule {
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "America/Los_Angeles")
        return CompetitionSchedule(
            calendar: calendar,
            startDay: try CompetitionDay(
                era: 1,
                year: year,
                month: month,
                day: startDay,
                timeZoneIdentifier: "America/Los_Angeles"
            )
        )
    }

    private func encodedJSONObject<Value: Encodable>(
        for value: Value,
        mutate: (inout [String: Any]) -> Void
    ) throws -> Data {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        )
        mutate(&root)
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func ownerWindow(pointsByOrdinal: [Int: Int]) throws -> LiveScoreWindowObservation {
        let ledger = try ledger(pointsByOrdinal: pointsByOrdinal)
        return try XCTUnwrap(ledger.completeLiveWindowObservation())
    }

    private func ledger(pointsByOrdinal: [Int: Int]) throws -> ScoreLedger {
        var ledger = ScoreLedger()
        for ordinal in 1...7 {
            _ = try ledger.record(
                try snapshot(points: Double(try XCTUnwrap(pointsByOrdinal[ordinal]))),
                forDayOrdinal: ordinal
            )
        }
        return ledger
    }

    private func snapshot(points: Double) throws -> ActivitySnapshot {
        ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: points, goal: 100),
            exercise: try ActivityRingReading(value: 0, goal: 100),
            standOrRoll: try ActivityRingReading(value: 0, goal: 100),
            isPaused: false
        )
    }

    private func pending(expiresAt: Date? = nil) -> Competition {
        Competition.pending(
            id: competitionID,
            direction: .incoming,
            createdAt: date(2026, 8, 9, 10),
            expiresAt: expiresAt
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }
}

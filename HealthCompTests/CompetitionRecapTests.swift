import CompetitionCore
import LinkPresentation
import UIKit
import XCTest
@testable import HealthComp

final class CompetitionRecapTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    private func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2009}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// Nov 2 2026 is a Monday; ordinal 1...7 → Nov 2...8, UTC.
    private func day(_ ordinal: Int, _ you: Double?, _ them: Double?) throws -> LocalCompetitionDayPresentation {
        LocalCompetitionDayPresentation(
            day: try CompetitionDay(era: 1, year: 2026, month: 11, day: 1 + ordinal, timeZoneIdentifier: "UTC"),
            ordinal: ordinal,
            ownerAcceptedPoints: you,
            ownerLatestAvailability: .observed,
            opponentRevealedPoints: them,
            scoringPolicy: .remoteWireV1
        )
    }

    /// Mon 330/300, Tue 260/330, Wed 284/330, Thu 512/300, Fri 400/350,
    /// Sat 300/344, Sun 326/314: 2,412–2,268, won 4, lost 3, down 86 after Wed.
    private func days(_ changes: [Int: (Double, Double)] = [:]) throws -> [LocalCompetitionDayPresentation] {
        let base: [(Double, Double)] = [
            (330, 300), (260, 330), (284, 330), (512, 300), (400, 350), (300, 344), (326, 314),
        ]
        return try base.enumerated().map { offset, points in
            let (you, them) = changes[offset + 1] ?? points
            return try day(offset + 1, you, them)
        }
    }

    /// Totals default to the day sums; outcome defaults to the totals.
    private func match(
        _ days: [LocalCompetitionDayPresentation],
        user: Double? = nil,
        opponent: Double? = nil,
        outcome: CompetitionOutcome? = nil,
        basis: FinalizationBasis = .stableAcrossPostBoundaryReads,
        name: String = "Sam",
        terminal: Bool = true
    ) throws -> LocalCompetitionPresentation {
        let user = user ?? days.reduce(0) { $0 + ($1.ownerAcceptedPoints ?? 0) }
        let opponent = opponent ?? days.reduce(0) { $0 + ($1.opponentRevealedPoints ?? 0) }
        let outcome = outcome ?? (user > opponent ? .win : user < opponent ? .loss : .tie)
        let completedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-09T12:00:00Z"))
        let calendar = try CompetitionCalendar(timeZoneIdentifier: "UTC")
        let schedule = CompetitionSchedule(
            calendar: calendar,
            startDay: try CompetitionDay(era: 1, year: 2026, month: 11, day: 2, timeZoneIdentifier: "UTC")
        )
        return LocalCompetitionPresentation(
            id: CompetitionID(UUID()),
            ownerDisplayName: "Naren",
            opponentDisplayName: name,
            lifecycle: .completed(outcome: outcome, basis: basis, completedAt: completedAt),
            acceptedConfiguration: LocalCompetitionAcceptedPresentation(schedule: schedule, difficulty: .balanced),
            userPoints: user,
            opponentPoints: opponent,
            days: days,
            currentDayOrdinal: nil,
            lastRefresh: nil,
            tally: nil,
            terminalResult: terminal
                ? LocalCompetitionTerminalPresentation(
                    userPoints: user, opponentPoints: opponent, outcome: outcome,
                    basis: basis, completedAt: completedAt
                )
                : nil,
            evaluatedAt: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z"))
        )
    }

    private func recap(
        _ competition: LocalCompetitionPresentation,
        belt: CompetitionRecapBelt? = nil,
        hidesName: Bool = false
    ) -> CompetitionRecap {
        competitionRecap(competition, belt: belt, hidesName: hidesName, locale: en)
    }

    private func highlights(_ competition: LocalCompetitionPresentation) -> [[String]] {
        recap(competition).highlights.map { [$0.title, $0.value] }
    }

    private func strings(_ recap: CompetitionRecap) -> [String] {
        [recap.weekText, recap.headline, recap.opponentLabel, recap.userPointsText,
         recap.opponentPointsText, recap.marginText, recap.daysText, recap.beltText,
         recap.accessibilityText].compactMap { $0 }
            + recap.highlights.flatMap { [$0.title, $0.value, $0.accessibilityValue] }
    }

    func testRecapHeadlineAndLabelsFollowOutcomeAndHiddenName() throws {
        let win = recap(try match(days()))
        XCTAssertEqual(win.headline, "Match won")
        XCTAssertEqual(win.opponentLabel, "Sam")

        let loss = try match(days(), user: 2_268, opponent: 2_412)
        XCTAssertEqual(recap(loss).headline, "Sam won")
        XCTAssertEqual(recap(loss, hidesName: true).headline, "They won")
        XCTAssertEqual(recap(loss, hidesName: true).opponentLabel, "Them")

        XCTAssertEqual(recap(try match(days(), user: 2_300, opponent: 2_300)).headline, "All square")
    }

    func testHiddenNameNeverAppearsOnTheCard() throws {
        let loss = try match(days(), user: 2_268, opponent: 2_412)
        let hidden = recap(loss, belt: .theyKept(weeks: 4), hidesName: true)
        for text in strings(hidden) {
            XCTAssertFalse(text.contains("Sam"), text)
        }
        XCTAssertEqual(hidden.beltText, "They kept the belt · 4 weeks")
    }

    func testFormerCompetitorIsAlwaysHidden() throws {
        let former = try match(days(), user: 2_268, opponent: 2_412, name: "Former competitor")
        XCTAssertFalse(competitionRecapAllowsNameChoice(former))
        XCTAssertTrue(competitionRecapAllowsNameChoice(try match(days())))
        let shown = recap(former, belt: .theyTook, hidesName: false)
        XCTAssertEqual(shown.opponentLabel, "Them")
        XCTAssertEqual(shown.headline, "They won")
        for text in strings(shown) {
            XCTAssertFalse(text.contains("Former competitor"), text)
        }
    }

    func testRecapScoresAndSummaryMatchTheResultScreen() throws {
        let base = try match(days())
        let shown = recap(base)
        XCTAssertEqual(shown.userPointsText, "2,412")
        XCTAssertEqual(shown.opponentPointsText, "2,268")
        XCTAssertEqual(
            shown.marginText,
            competitionMarginText(userPoints: 2_412, opponentPoints: 2_268, fractionDigits: 0, locale: en)
        )
        XCTAssertEqual(shown.marginText, "Won by 144 points")
        XCTAssertTrue(shown.marginIsYours)
        XCTAssertEqual(shown.daysText, competitionDaysSummaryText(base.days))
        XCTAssertEqual(shown.daysText, "won 4 days, lost 3")

        let close = recap(try match(days(), user: 2_104.30, opponent: 2_104.00))
        XCTAssertEqual(close.userPointsText, "2,104.30")
        XCTAssertEqual(close.opponentPointsText, "2,104.00")
        XCTAssertEqual(close.marginText, "Won by 0.30 points")

        let lost = recap(try match(days(), user: 2_268, opponent: 2_412))
        XCTAssertFalse(lost.marginIsYours)
    }

    func testRecapWeekAlwaysShowsTheYear() throws {
        XCTAssertEqual(recap(try match(days())).weekText.map(normalized), "Nov 2 – 8, 2026")
        // No days: the week comes from the schedule.
        let empty = recap(try match([], user: 2_412, opponent: 2_268))
        XCTAssertEqual(empty.weekText.map(normalized), "Nov 2 – 8, 2026")
        XCTAssertTrue(empty.days.isEmpty)
        XCTAssertTrue(empty.highlights.isEmpty)
        XCTAssertNil(empty.daysText)
        XCTAssertEqual(empty.marginText, "Won by 144 points")
    }

    func testComebackNeedsAWinAfterTrailingByFifty() throws {
        XCTAssertEqual(
            highlights(try match(days())),
            [["Comeback", "Down 86 after Wed"], ["Best day", "Thu · 512"]]
        )
        // Down 46 at worst.
        XCTAssertFalse(highlights(try match(days([3: (324, 330)]))).contains { $0[0] == "Comeback" })
        let loss = try match(days(), user: 2_268, opponent: 2_412, outcome: .loss)
        XCTAssertFalse(highlights(loss).contains { $0[0] == "Comeback" })
        // Down 86 after Wed and the day sums agree (2,000–2,268): still a loss.
        let consistentLoss = try match(days([4: (100, 300)]))
        XCTAssertEqual(competitionResultOutcome(consistentLoss), .loss)
        XCTAssertFalse(highlights(consistentLoss).contains { $0[0] == "Comeback" })
    }

    func testComebackSkipsWhenDaySumsDisagreeWithTheFinalScore() throws {
        let revised = try match(days(), user: 2_420, basis: .bestAvailable)
        XCTAssertEqual(highlights(revised), [["Best day", "Thu · 512"]])
    }

    func testPhotoFinishIsUnderOnePercentOfTheWinner() throws {
        XCTAssertEqual(highlights(try match(days([7: (200, 314)]))).first, ["Photo finish", "Decided by 18"])
        XCTAssertFalse(highlights(try match(days(), opponent: 2_380)).contains { $0[0] == "Photo finish" })
        XCTAssertFalse(
            highlights(try match(days(), user: 2_300, opponent: 2_300)).contains { $0[0] == "Photo finish" }
        )
        let close = recap(try match(days(), user: 2_104.30, opponent: 2_104.00))
        XCTAssertEqual(close.highlights.first?.value, "Decided by 0.30")
        XCTAssertEqual(close.highlights.first?.accessibilityValue, "decided by 0.30 points")
    }

    func testPerfectDayTakesTheBestDaySlot() throws {
        let perfect = highlights(try match(days([4: (600, 300)])))
        XCTAssertTrue(perfect.contains(["Perfect day", "Thu · 600"]), "\(perfect)")
        XCTAssertFalse(perfect.contains { $0[0] == "Best day" })
        XCTAssertTrue(highlights(try match(days([4: (599.6, 300)]))).contains(["Perfect day", "Thu · 600"]))
        XCTAssertTrue(highlights(try match(days([4: (599.4, 300)]))).contains(["Best day", "Thu · 599"]))
        let two = recap(try match(days([4: (600, 300), 6: (600, 344)])))
        XCTAssertEqual(two.highlights.last?.value, "2 days at 600")
        XCTAssertEqual(two.highlights.last?.accessibilityValue, "2 days at 600 points")
    }

    func testHighlightsStopAtTwoInOrder() throws {
        XCTAssertEqual(
            highlights(try match(days([7: (200, 314)]))),
            [["Photo finish", "Decided by 18"], ["Comeback", "Down 86 after Wed"]]
        )
    }

    func testBeltTextAndGlyphCoverEveryCase() {
        let cases: [(CompetitionRecapBelt, String, String, Bool)] = [
            (.youTook, "Took the belt", "Took the belt", true),
            (.theyTook, "Sam took the belt", "They took the belt", false),
            (.youKept(weeks: 3), "Kept the belt · 3 weeks", "Kept the belt · 3 weeks", true),
            (.theyKept(weeks: 5), "Sam kept the belt · 5 weeks", "They kept the belt · 5 weeks", false),
        ]
        for (belt, shown, hidden, isYours) in cases {
            XCTAssertEqual(competitionRecapBeltText(belt, opponentName: "Sam"), shown)
            XCTAssertEqual(competitionRecapBeltText(belt, opponentName: nil), hidden)
            XCTAssertEqual(belt.isYours, isYours)
        }

        XCTAssertNil(competitionRecapBelt(nil, outcome: .win, isRetired: false))
        XCTAssertNil(competitionRecapBelt(.kept(by: .you, weeks: 4), outcome: .tie, isRetired: false))
        XCTAssertNil(competitionRecapBelt(.took(by: .you, fromWeeks: nil), outcome: .win, isRetired: true))
        XCTAssertNil(competitionRecapBelt(.kept(by: .you, weeks: 2), outcome: .win, isRetired: false))
        XCTAssertNil(competitionRecapBelt(.vacant, outcome: .win, isRetired: false))
        XCTAssertEqual(competitionRecapBelt(.took(by: .you, fromWeeks: 2), outcome: .win, isRetired: false), .youTook)
        XCTAssertEqual(competitionRecapBelt(.took(by: .them, fromWeeks: nil), outcome: .loss, isRetired: false), .theyTook)
        XCTAssertEqual(competitionRecapBelt(.kept(by: .you, weeks: 3), outcome: .win, isRetired: false), .youKept(weeks: 3))
        XCTAssertEqual(competitionRecapBelt(.kept(by: .them, weeks: 6), outcome: .loss, isRetired: false), .theyKept(weeks: 6))
    }

    func testRecapAccessibilityTextReadsTheCard() throws {
        XCTAssertEqual(
            recap(try match(days()), belt: .youTook).accessibilityText,
            "Match won. Nov 2 to 8, 2026. You 2,412 points. Sam 2,268 points. Won by 144 points, won 4 days, lost 3. Comeback: down 86 points after Wednesday. Best day: Thursday, 512 points. Took the belt."
        )
        XCTAssertTrue(
            recap(try match(days()), belt: .youKept(weeks: 3)).accessibilityText
                .hasSuffix("Kept the belt, 3 weeks.")
        )
    }

    @MainActor
    func testRecapImageIs1080By1350AndAlwaysLight() throws {
        let shown = recap(try match(days()), belt: .youTook)
        var rendered: UIImage?
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            rendered = competitionRecapImage(shown)
        }
        let image = try XCTUnwrap(rendered)
        XCTAssertEqual(image.size, CGSize(width: 360, height: 450))
        XCTAssertEqual(image.scale, 3)

        // Pixel (3, 3) from the top left is the card's light ground, 0xFAFAF7.
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(
            x: -3, y: -CGFloat(cgImage.height - 4),
            width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)
        ))
        for (channel, expected) in zip(pixel.prefix(3), [0xFA, 0xFA, 0xF7]) {
            XCTAssertLessThanOrEqual(abs(Int(channel) - expected), 2, "\(pixel)")
        }

        let png = try XCTUnwrap(UIImage(data: try XCTUnwrap(image.pngData())))
        XCTAssertEqual(png.size, CGSize(width: 1080, height: 1350))
        XCTAssertEqual(png.scale, 1)

        #if DEBUG
        // Cards for the preview artifact; not asserted.
        let cards: [(String, CompetitionRecap)] = [
            ("recap-card-win-took-belt", shown),
            ("recap-card-loss-hidden", recap(
                try match(days(), user: 2_268, opponent: 2_412), belt: .theyTook, hidesName: true
            )),
            ("recap-card-photo-finish", recap(
                try match(days([7: (200, 314)]), user: 2_104.30, opponent: 2_104.00), hidesName: true
            )),
            ("recap-card-tie-no-days", recap(try match([], user: 3_000, opponent: 3_000))),
            ("recap-card-long-name-loss", recap(
                try match(
                    days(), user: 2_268, opponent: 2_412,
                    name: "Maximiliana Alexandrovna Featherstonehaugh-Montgomery Wellington"
                ),
                belt: .theyKept(weeks: 4)
            )),
        ]
        for (name, card) in cards {
            guard let image = competitionRecapImage(card) else { continue }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        #endif
    }

    @MainActor
    func testShareItemHandsOverThePNGTitledWithTheHeadline() throws {
        let card = recap(try match(days()), belt: .youTook)
        let image = try XCTUnwrap(competitionRecapImage(card))
        let png = try XCTUnwrap(image.pngData())
        let item = CompetitionRecapShareItem(png: png, image: image, title: card.headline)
        let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        XCTAssertEqual(
            item.activityViewController(controller, itemForActivityType: .saveToCameraRoll) as? Data,
            png
        )
        XCTAssertEqual(
            item.activityViewController(controller, dataTypeIdentifierForActivityType: .message),
            "public.png"
        )
        XCTAssertEqual(item.activityViewControllerLinkMetadata(controller)?.title, "Match won")
    }

    func testResultOutcomeUsesTerminalThenShownTotals() throws {
        // The terminal result wins over the shown totals.
        XCTAssertEqual(competitionResultOutcome(try match(days(), outcome: .loss)), .loss)
        XCTAssertEqual(competitionResultOutcome(try match(days(), terminal: false)), .win)
        XCTAssertEqual(competitionResultOutcome(try match(days(), user: 1, opponent: 2, terminal: false)), .loss)
        XCTAssertEqual(competitionResultOutcome(try match(days(), user: 2, opponent: 2, terminal: false)), .tie)
    }
}

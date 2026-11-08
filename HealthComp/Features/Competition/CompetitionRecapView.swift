import CompetitionCore
import LinkPresentation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: Model

struct CompetitionRecapHighlight: Equatable {
    let title: String
    let value: String
    let accessibilityValue: String
}

/// The belt as the card tells it. Nil = no line (tie, retired, no data).
enum CompetitionRecapBelt: Equatable {
    case youTook, theyTook, youDefended(defenses: Int), theyDefended(defenses: Int)

    var isYours: Bool {
        switch self {
        case .youTook, .youDefended: true
        case .theyTook, .theyDefended: false
        }
    }
}

struct CompetitionRecap: Equatable {
    let weekText: String?
    /// "Match won" / "{Name} won" / "They won" / "All square"
    let headline: String
    /// "{Name}" or "Them"
    let opponentLabel: String
    let userPointsText: String
    let opponentPointsText: String
    let marginText: String?
    let marginIsYours: Bool
    let daysText: String?
    let days: [LocalCompetitionDayPresentation]
    /// 0...2
    let highlights: [CompetitionRecapHighlight]
    let belt: CompetitionRecapBelt?
    let beltText: String?
    let accessibilityText: String
}

/// The card's belt line from PR 1's per-match event: a take or a title
/// defense. Never on a tie or for a retired pair.
func competitionRecapBelt(
    _ event: CompetitionBeltEvent?,
    outcome: CompetitionOutcome,
    isRetired: Bool
) -> CompetitionRecapBelt? {
    guard !isRetired, outcome != .tie, let event else { return nil }
    switch event {
    case .took(.you, _, _): return .youTook
    case .took(.them, _, _): return .theyTook
    case let .defended(.you, _, defenses): return .youDefended(defenses: defenses)
    case let .defended(.them, _, defenses): return .theyDefended(defenses: defenses)
    default: return nil
    }
}

/// False for "Former competitor": that name is always hidden.
func competitionRecapAllowsNameChoice(_ competition: LocalCompetitionPresentation) -> Bool {
    competition.opponentDisplayName != competitionFormerCompetitorName
}

/// "Took the belt" / "Sam's 3rd title defense". A nil name is hidden: "They …".
func competitionRecapBeltText(_ belt: CompetitionRecapBelt, opponentName: String?) -> String {
    let they = opponentName ?? "They"
    return switch belt {
    case .youTook: "Took the belt"
    case .theyTook: "\(they) took the belt"
    case let .youDefended(defenses): competitionTitleDefenseText(defenses)
    case let .theyDefended(defenses):
        "\(opponentName.map { "\($0)'s" } ?? "Their") \(competitionTitleDefenseText(defenses))"
    }
}

func competitionRecap(
    _ competition: LocalCompetitionPresentation,
    belt: CompetitionRecapBelt?,
    hidesName: Bool,
    locale: Locale = .current
) -> CompetitionRecap {
    let hidden = hidesName || !competitionRecapAllowsNameChoice(competition)
    let name: String? = hidden ? nil : competition.opponentDisplayName
    let label = name ?? "Them"
    let user = competition.userPoints
    let opponent = competition.opponentPoints
    let digits = competitionFinalFractionDigits(userPoints: user, opponentPoints: opponent)
    let outcome = competitionResultOutcome(competition)
    let headline = switch outcome {
    case .win: "Match won"
    case .loss: "\(name ?? "They") won"
    case .tie: "All square"
    }

    var week: (first: CompetitionDay, last: CompetitionDay)?
    if let first = competition.days.first?.day, let last = competition.days.last?.day {
        week = (first, last)
    } else if let schedule = competition.acceptedConfiguration?.schedule,
              let window = try? schedule.calendar.sevenDayWindow(startingOn: schedule.startDay),
              let first = window.first, let last = window.last {
        week = (first, last)
    }
    let weekText = week.map {
        competitionWeekText($0.first, $0.last, includesYear: true, locale: locale)
    }

    let marginText = competitionMarginText(
        userPoints: user, opponentPoints: opponent, fractionDigits: digits, locale: locale
    )
    let daysText = competitionDaysSummaryText(competition.days)
    let highlights = competitionRecapHighlights(
        days: competition.days,
        userPoints: user,
        opponentPoints: opponent,
        outcome: outcome,
        fractionDigits: digits,
        locale: locale
    )
    let beltText = belt.map { competitionRecapBeltText($0, opponentName: name) }

    func spoken(_ points: Double) -> String {
        competitionPointsAccessibilityText(points, fractionDigits: digits, locale: locale)
    }
    let summary = [marginText, daysText].compactMap { $0 }.joined(separator: ", ")
    let parts: [String?] = [
        headline,
        weekText?.replacingOccurrences(of: #"\s*–\s*"#, with: " to ", options: .regularExpression),
        "You \(spoken(user))",
        "\(label) \(spoken(opponent))",
        summary.isEmpty ? nil : summary,
    ]
    let accessibilityText = (
        parts.compactMap { $0 }
            + highlights.map { "\($0.title): \($0.accessibilityValue)" }
            + [beltText].compactMap { $0 }
    ).joined(separator: ". ") + "."

    return CompetitionRecap(
        weekText: weekText,
        headline: headline,
        opponentLabel: label,
        userPointsText: competitionPointsText(user, fractionDigits: digits, locale: locale),
        opponentPointsText: competitionPointsText(opponent, fractionDigits: digits, locale: locale),
        marginText: marginText,
        marginIsYours: competitionDisplayedMargin(
            userPoints: user, opponentPoints: opponent, fractionDigits: digits
        ) > 0,
        daysText: daysText,
        days: competition.days,
        highlights: highlights,
        belt: belt,
        beltText: beltText,
        accessibilityText: accessibilityText
    )
}

/// Photo finish, comeback, then best (or perfect) day: the first two that exist.
/// Day values are whole points; only your own days count.
func competitionRecapHighlights(
    days: [LocalCompetitionDayPresentation],
    userPoints: Double,
    opponentPoints: Double,
    outcome: CompetitionOutcome,
    fractionDigits: Int,
    locale: Locale = .current
) -> [CompetitionRecapHighlight] {
    var highlights: [CompetitionRecapHighlight] = []
    func points(_ value: Double) -> String { competitionPointsText(value, locale: locale) }
    func spoken(_ value: Double) -> String { competitionPointsAccessibilityText(value, locale: locale) }

    // Photo finish: decided by under 1% of the higher score.
    let margin = competitionDisplayedMargin(
        userPoints: userPoints, opponentPoints: opponentPoints, fractionDigits: fractionDigits
    )
    if outcome != .tie, margin != 0, abs(margin) < 0.01 * max(userPoints, opponentPoints) {
        highlights.append(CompetitionRecapHighlight(
            title: "Photo finish",
            value: "Decided by \(competitionPointsText(abs(margin), fractionDigits: fractionDigits, locale: locale))",
            accessibilityValue: "decided by \(competitionPointsAccessibilityText(abs(margin), fractionDigits: fractionDigits, locale: locale))"
        ))
    }

    // Comeback: a win after trailing by 50+ at the end of some day 1–6, from
    // the final day scores, only when they add up to the final margin.
    let ordered = days.sorted { $0.ordinal < $1.ordinal }
    let sumUser = ordered.reduce(0.0) { $0 + ($1.ownerAcceptedPoints ?? 0) }
    let sumOpponent = ordered.reduce(0.0) { $0 + ($1.opponentRevealedPoints ?? 0) }
    if outcome == .win, !ordered.isEmpty,
       competitionDisplayedMargin(
           userPoints: sumUser, opponentPoints: sumOpponent, fractionDigits: fractionDigits
       ) == margin {
        var runningUser = 0.0
        var runningOpponent = 0.0
        var worst: (deficit: Double, day: CompetitionDay)?
        for day in ordered.prefix(6) {
            runningUser += day.ownerAcceptedPoints ?? 0
            runningOpponent += day.opponentRevealedPoints ?? 0
            let running = competitionDisplayedMargin(
                userPoints: runningUser, opponentPoints: runningOpponent, fractionDigits: fractionDigits
            )
            if running <= -50, -running > (worst?.deficit ?? 0) {
                worst = (-running, day.day)
            }
        }
        if let worst {
            highlights.append(CompetitionRecapHighlight(
                title: "Comeback",
                value: "Down \(points(worst.deficit)) after \(weekdayText(worst.day, locale: locale))",
                accessibilityValue: "down \(spoken(worst.deficit)) after \(weekdayName(worst.day, locale: locale))"
            ))
        }
    }

    // Best day, or perfect day when the shown value reaches 600.
    let scored = ordered.compactMap { day in
        day.ownerAcceptedPoints.map { (day: day.day, points: $0) }
    }.filter { $0.points.rounded(.toNearestOrAwayFromZero) > 0 }
    // max(by:) keeps the first of equal values: the earliest day.
    if let best = scored.max(by: { $0.points < $1.points }) {
        let perfect = scored.filter {
            $0.points.rounded(.toNearestOrAwayFromZero) >= ActivityScore.maximumDailyPoints
        }.count
        let title = perfect > 0 ? "Perfect day" : "Best day"
        if perfect > 1 {
            highlights.append(CompetitionRecapHighlight(
                title: title,
                value: "\(perfect) days at \(points(ActivityScore.maximumDailyPoints))",
                accessibilityValue: "\(perfect) days at \(spoken(ActivityScore.maximumDailyPoints))"
            ))
        } else {
            highlights.append(CompetitionRecapHighlight(
                title: title,
                value: "\(weekdayText(best.day, locale: locale)) · \(points(best.points))",
                accessibilityValue: "\(weekdayName(best.day, locale: locale)), \(spoken(best.points))"
            ))
        }
    }

    return Array(highlights.prefix(2))
}

// MARK: Card

/// Fixed-size card; never reads Dynamic Type.
struct CompetitionRecapCard: View {
    let recap: CompetitionRecap
    static let size = CGSize(width: 360, height: 450)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("HEALTHCOMP")
                    .font(.system(size: 13, weight: .heavy).width(.condensed))
                    .tracking(1.6)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                if let week = recap.weekText {
                    Text(week)
                        .textCase(.uppercase)
                        .font(.system(size: 13, weight: .bold).width(.condensed))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }

            // With no strip or highlights this and the footer spacer centre
            // the score, so the card doesn't end in an empty half.
            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 8) {
                Text(recap.headline)
                    .textCase(.uppercase)
                    .font(.system(size: 13, weight: .bold).width(.condensed))
                    .tracking(1.2)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                HStack(alignment: .lastTextBaseline, spacing: 16) {
                    side(label: "You", points: recap.userPointsText, tint: Theme.you, alignment: .leading)
                    Spacer(minLength: 0)
                    side(label: recap.opponentLabel, points: recap.opponentPointsText, tint: Theme.ink, alignment: .trailing)
                }
                summary
            }

            if !recap.days.isEmpty {
                Spacer(minLength: 12)
                CompetitionWeekStrip(days: recap.days, currentDayOrdinal: nil)
            }

            if !recap.highlights.isEmpty {
                Spacer(minLength: 12)
                HStack(alignment: .top, spacing: 16) {
                    ForEach(recap.highlights, id: \.title) { highlight in
                        VStack(alignment: .leading, spacing: 6) {
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                            Text(highlight.title)
                                .textCase(.uppercase)
                                .font(.system(size: 11, weight: .bold).width(.condensed))
                                .tracking(1.1)
                                .foregroundStyle(Theme.secondary)
                            Text(highlight.value)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                // One line, as in the mockup: shrink before wrapping.
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 10) {
                if recap.beltText != nil {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                // A belt line too long for the footer row gets a row of its own.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 8) {
                        beltLine(fits: true)
                        Spacer(minLength: 8)
                        domain
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        beltLine(fits: false)
                        domain.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        .padding(28)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Theme.ground)
    }

    private var domain: some View {
        Text("healthcomp.app")
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            .fixedSize()
    }

    /// Whole, or on its own row with the name truncated: "took the belt" /
    /// "'s 3rd title defense" is never cut.
    @ViewBuilder
    private func beltLine(fits: Bool) -> some View {
        if let belt = recap.belt, let text = recap.beltText {
            let verb = text.range(of: " took the belt") ?? text.range(of: "'s ", options: .backwards)
            HStack(spacing: 8) {
                if belt.isYours {
                    CompetitionBeltMark(holder: .you, width: 22)
                }
                HStack(spacing: 0) {
                    if fits || verb == nil {
                        Text(text).lineLimit(1).fixedSize(horizontal: fits, vertical: false)
                    } else if let verb {
                        Text(text[..<verb.lowerBound]).lineLimit(1)
                        Text(text[verb.lowerBound...]).fixedSize()
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            }
        }
    }

    private func side(
        label: String,
        points: String,
        tint: Color,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .textCase(.uppercase)
                .font(.system(size: 13, weight: .bold).width(.condensed))
                .tracking(1.2)
                .foregroundStyle(tint)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            Text(points)
                .font(.score(size: 60))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }

    @ViewBuilder
    private var summary: some View {
        let margin = recap.marginText.map {
            Text($0).bold().foregroundStyle(recap.marginIsYours ? Theme.you : Theme.ink)
        }
        let days = recap.daysText.map { Text($0).foregroundStyle(Theme.secondary) }
        if margin != nil || days != nil {
            let separator = margin != nil && days != nil
                ? Text(" · ").foregroundStyle(Theme.tertiary)
                : Text("")
            ((margin ?? Text("")) + separator + (days ?? Text("")))
                .font(.system(size: 15))
                .lineLimit(2)
        }
    }
}

// MARK: Image

/// What the share sheet receives: PNG bytes, so size and type are known,
/// titled with the card's headline.
final class CompetitionRecapShareItem: NSObject, UIActivityItemSource {
    let png: Data
    let image: UIImage
    let title: String

    init(png: Data, image: UIImage, title: String) {
        self.png = png
        self.image = image
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_: UIActivityViewController) -> Any { image }

    func activityViewController(
        _: UIActivityViewController,
        itemForActivityType _: UIActivity.ActivityType?
    ) -> Any? { png }

    func activityViewController(
        _: UIActivityViewController,
        dataTypeIdentifierForActivityType _: UIActivity.ActivityType?
    ) -> String { UTType.png.identifier }

    func activityViewControllerLinkMetadata(_: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.imageProvider = NSItemProvider(object: image)
        return metadata
    }
}

/// Presents the system share sheet over whatever is on screen. A ShareLink in
/// this sheet dismissed the sheet too once an action such as Save Image finished.
@MainActor
func competitionPresentShareSheet(_ item: CompetitionRecapShareItem) {
    guard var top = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .flatMap(\.windows)
        .first(where: \.isKeyWindow)?
        .rootViewController
    else { return }
    while let presented = top.presentedViewController, !presented.isBeingDismissed {
        top = presented
    }
    top.present(
        UIActivityViewController(activityItems: [item], applicationActivities: nil),
        animated: true
    )
}

/// 1080×1350 px, always light.
@MainActor
func competitionRecapImage(_ recap: CompetitionRecap) -> UIImage? {
    let renderer = ImageRenderer(content: CompetitionRecapCard(recap: recap)
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, .large))
    renderer.proposedSize = ProposedViewSize(CompetitionRecapCard.size)
    renderer.scale = 3
    renderer.isOpaque = true
    // The trait pins UIKit dynamic colors too, whatever the phone's appearance.
    var image: UIImage?
    UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
        image = renderer.uiImage
    }
    return image
}

// MARK: Sheet

@MainActor
struct CompetitionRecapSheet: View {
    let competition: LocalCompetitionPresentation
    let belt: CompetitionRecapBelt?

    @AppStorage("healthcomp.recapHidesName") private var hidesName = false
    @State private var renderFailed = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    private var recap: CompetitionRecap {
        competitionRecap(competition, belt: belt, hidesName: hidesName, locale: locale)
    }

    var body: some View {
        let recap = recap
        CompetitionDrawer(title: "Share Result", detents: [.large]) {
            preview(recap)
            if competitionRecapAllowsNameChoice(competition) {
                nameChoice
            }
            share(recap)
            if renderFailed {
                Text("Couldn’t make the image.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("competition.recap.error")
                    .transition(Motion.appear)
            }
        }
        .sensoryFeedback(.error, trigger: renderFailed) { _, failed in failed }
    }

    private func preview(_ recap: CompetitionRecap) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        // The real card, so the sheet slides up with it there. The image is
        // made on Share: making it here would drop frames from the slide.
        return Color.clear
            .aspectRatio(4 / 5, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    CompetitionRecapCard(recap: recap)
                        .environment(\.colorScheme, .light)
                        .environment(\.dynamicTypeSize, .large)
                        .scaleEffect(
                            proxy.size.width / CompetitionRecapCard.size.width,
                            anchor: .topLeading
                        )
                        // The text clipping audit flags every line of scaled
                        // Text, even hidden: to it, this is a picture.
                        .accessibilityRepresentation { Color.clear }
                }
            }
            .animation(Motion.fade, value: hidesName)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isImage)
            .accessibilityLabel(recap.accessibilityText)
            .accessibilityIdentifier("competition.recap.card")
    }

    @ViewBuilder
    private var nameChoice: some View {
        // A segmented label can't wrap; larger text gets a switch.
        if dynamicTypeSize < .xxLarge {
            Picker("Name on the image", selection: $hidesName) {
                Text("Show \(competition.opponentDisplayName)").tag(false)
                Text("Hide name").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("competition.recap.name")
        } else {
            Toggle("Hide name", isOn: $hidesName)
                .font(.body)
                .foregroundStyle(Theme.ink)
                .frame(minHeight: 44)
                // Q-notifs-5: the inherited ink tint hides the On thumb in dark mode.
                .tint(Color(uiColor: .systemGreen))
                .accessibilityIdentifier("competition.recap.name")
        }
    }

    private func share(_ recap: CompetitionRecap) -> some View {
        Button {
            guard let image = competitionRecapImage(recap), let png = image.pngData() else {
                renderFailed = true
                return
            }
            renderFailed = false
            competitionPresentShareSheet(
                CompetitionRecapShareItem(png: png, image: image, title: recap.headline)
            )
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(PrimaryButtonStyle())
        .accessibilityHint("Opens the system share sheet")
        .accessibilityIdentifier("competition.recap.share")
    }
}

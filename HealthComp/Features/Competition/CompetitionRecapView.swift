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
    /// The footer's one line, picked as on Home and the Verdict.
    let line: CompetitionHeadline?
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
        "\(opponentName.map { "\($0)’s" } ?? "Their") \(competitionTitleDefenseText(defenses))"
    }
}

func competitionRecap(
    _ competition: LocalCompetitionPresentation,
    belt: CompetitionRecapBelt?,
    hidesName: Bool,
    personalBest: String? = nil,
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
    let line = competitionHeadline(
        belt: belt, personalBest: personalBest, days: competition.days, opponentName: name
    )

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
            + [line?.text].compactMap { $0 }
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
        line: line,
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
                    .font(.score(size: 44))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
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
                if recap.line != nil {
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
    /// "’s 3rd title defense" is never cut. Any other line gets two rows.
    @ViewBuilder
    private func beltLine(fits: Bool) -> some View {
        if let line = recap.line {
            let text = line.text
            let verb = line.isBelt
                ? text.range(of: " took the belt") ?? text.range(of: "’s ", options: .backwards)
                : nil
            HStack(spacing: 8) {
                if line.isBelt, line.holder == .you {
                    CompetitionBeltMark(holder: .you, width: 22)
                }
                HStack(spacing: 0) {
                    if fits || verb == nil {
                        Text(text).lineLimit(fits ? 1 : 2).fixedSize(horizontal: fits, vertical: false)
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

// MARK: Sticker

/// The margin and the card's one headline: "Won by 110 points · 2nd title
/// defense". Nil on a tie with no headline.
func competitionRecapStickerLine(_ recap: CompetitionRecap) -> String? {
    let parts = [recap.marginText, recap.line?.text].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

/// The result on a clear ground, to lay over a photo: score, margin, the lead
/// line and the belt line. Points only. The card's size, so the preview slot
/// keeps still; never reads Dynamic Type. A light scheme is dark ink.
struct CompetitionRecapSticker: View {
    let recap: CompetitionRecap
    static let size = CompetitionRecapCard.size

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .lastTextBaseline, spacing: 16) {
                side(label: "You", points: recap.userPointsText, tint: Theme.you, alignment: .leading)
                Spacer(minLength: 0)
                side(label: recap.opponentLabel, points: recap.opponentPointsText, tint: Theme.ink, alignment: .trailing)
            }
            if let line = competitionLeadLine(recap.days, currentDayOrdinal: nil) {
                CompetitionLeadLineView(
                    line: line,
                    days: recap.days,
                    currentDayOrdinal: nil,
                    opponentName: recap.opponentLabel,
                    sideLabels: (you: "You ahead", them: "\(recap.opponentLabel) ahead")
                )
            }
            if let text = competitionRecapStickerLine(recap) {
                HStack(spacing: 8) {
                    if let line = recap.line, line.isBelt, line.holder == .you {
                        CompetitionBeltMark(holder: .you, width: 22)
                    }
                    Text(text)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(recap.marginIsYours ? Theme.you : Theme.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(28)
        .frame(width: Self.size.width, height: Self.size.height)
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
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(points)
                .font(.score(size: 60))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }
}

/// Says "clear" behind the sticker's preview; never in the image.
private struct CompetitionStickerGround: View {
    var body: some View {
        Canvas { context, size in
            let side = 15.0
            let squares = Path { path in
                for row in 0 ..< Int((size.height / side).rounded(.up)) {
                    for column in 0 ..< Int((size.width / side).rounded(.up))
                        where (row + column).isMultiple(of: 2) {
                        path.addRect(CGRect(
                            x: Double(column) * side, y: Double(row) * side, width: side, height: side
                        ))
                    }
                }
            }
            context.fill(squares, with: .color(Theme.control))
        }
        .background(Theme.ground)
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

@MainActor
func competitionRecapImage(_ recap: CompetitionRecap) -> UIImage? {
    competitionShareImage(CompetitionRecapCard(recap: recap))
}

/// A card at `CompetitionRecapCard.size` as 1080×1350 px, always light.
@MainActor
func competitionShareImage(_ card: some View) -> UIImage? {
    competitionRender(card, size: CompetitionRecapCard.size, scheme: .light, isOpaque: true)
}

/// 1080×1350 px on a clear ground. Light ink is the dark scheme's colours.
@MainActor
func competitionRecapStickerImage(_ recap: CompetitionRecap, lightInk: Bool) -> UIImage? {
    competitionRender(
        CompetitionRecapSticker(recap: recap),
        size: CompetitionRecapSticker.size,
        scheme: lightInk ? .dark : .light,
        isOpaque: false
    )
}

@MainActor
private func competitionRender(
    _ content: some View,
    size: CGSize,
    scheme: ColorScheme,
    isOpaque: Bool
) -> UIImage? {
    let renderer = ImageRenderer(content: content
        .environment(\.colorScheme, scheme)
        .environment(\.dynamicTypeSize, .large))
    renderer.proposedSize = ProposedViewSize(size)
    renderer.scale = 3
    renderer.isOpaque = isOpaque
    // The trait pins UIKit dynamic colors too, whatever the phone's appearance.
    var image: UIImage?
    UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light).performAsCurrent {
        image = renderer.uiImage
    }
    return image
}

// MARK: Sheet

@MainActor
struct CompetitionRecapSheet: View {
    let competition: LocalCompetitionPresentation
    let belt: CompetitionRecapBelt?
    var personalBest: String? = nil

    @AppStorage("healthcomp.recapHidesName") private var hidesName = false
    @State private var isSticker = false
    @State private var lightInk = false
    @State private var copied = false
    @State private var renderFailed = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    private var recap: CompetitionRecap {
        competitionRecap(
            competition, belt: belt, hidesName: hidesName, personalBest: personalBest, locale: locale
        )
    }

    var body: some View {
        let recap = recap
        CompetitionDrawer(title: "Share Result", detents: [.large]) {
            choice(
                "Image", selection: $isSticker, off: "Card", on: "Sticker",
                id: "competition.recap.kind"
            )
            preview(recap)
            if isSticker {
                choice(
                    "Ink", selection: $lightInk, off: "Dark ink", on: "Light ink",
                    id: "competition.recap.ink"
                )
                .transition(Motion.appear)
            }
            if competitionRecapAllowsNameChoice(competition) {
                choice(
                    "Name on the image", selection: $hidesName,
                    off: "Show \(competition.opponentDisplayName)", on: "Hide name",
                    id: "competition.recap.name"
                )
            }
            buttons(recap)
            if renderFailed {
                Text("Couldn’t make the image.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("competition.recap.error")
                    .transition(Motion.appear)
            }
        }
        .sensoryFeedback(.error, trigger: renderFailed) { _, failed in failed }
        .sensoryFeedback(.success, trigger: copied) { _, copied in copied }
        .onChange(of: [isSticker, lightInk, hidesName]) { copied = false }
    }

    private func preview(_ recap: CompetitionRecap) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        // The real card, so the sheet slides up with it there. The image is
        // made on Share: making it here would drop frames from the slide.
        return Color.clear
            .aspectRatio(4 / 5, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        if isSticker {
                            CompetitionRecapSticker(recap: recap)
                                .background(CompetitionStickerGround())
                                .environment(\.colorScheme, lightInk ? .dark : .light)
                                .transition(Motion.appear)
                                .zIndex(1)
                        } else {
                            CompetitionRecapCard(recap: recap)
                                .environment(\.colorScheme, .light)
                                .transition(Motion.appear)
                        }
                    }
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
            .animation(Motion.fade, value: lightInk)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isImage)
            .accessibilityLabel(recap.accessibilityText)
            .accessibilityIdentifier(isSticker ? "competition.recap.sticker" : "competition.recap.card")
    }

    /// Two answers. A segmented label can't wrap; larger text gets a switch.
    @ViewBuilder
    private func choice(
        _ title: String,
        selection: Binding<Bool>,
        off: String,
        on: String,
        id: String
    ) -> some View {
        if dynamicTypeSize < .xxLarge {
            Picker(title, selection: selection) {
                Text(off).tag(false)
                Text(on).tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(id)
        } else {
            Toggle(on, isOn: selection)
                .font(.body)
                .foregroundStyle(Theme.ink)
                .frame(minHeight: 44)
                // Amber, not the inherited ink, which hides the On thumb in dark mode.
                .tint(Theme.youFill)
                .accessibilityIdentifier(id)
        }
    }

    /// PNG bytes keep the sticker's clear ground on the pasteboard and in
    /// the share sheet.
    private func rendered(_ recap: CompetitionRecap) -> (image: UIImage, png: Data)? {
        let image = isSticker
            ? competitionRecapStickerImage(recap, lightInk: lightInk)
            : competitionRecapImage(recap)
        guard let image, let png = image.pngData() else {
            renderFailed = true
            return nil
        }
        renderFailed = false
        return (image, png)
    }

    @ViewBuilder
    private func buttons(_ recap: CompetitionRecap) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            if isSticker {
                Button {
                    guard let png = rendered(recap)?.png else { return }
                    UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityHint("Copies the sticker to paste over a photo")
                .accessibilityIdentifier("competition.recap.copy")
                .transition(Motion.appear)
            }
            Button {
                guard let made = rendered(recap) else { return }
                competitionPresentShareSheet(
                    CompetitionRecapShareItem(png: made.png, image: made.image, title: recap.headline)
                )
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityHint("Opens the system share sheet")
            .accessibilityIdentifier("competition.recap.share")
        }
    }
}

// MARK: Your month, your year

/// A calendar month, or the whole year when `month` is nil.
struct CompetitionRecapPeriod: Hashable, Identifiable, Sendable {
    let year: Int
    var month: Int? = nil
    var id: Self { self }

    func contains(_ day: CompetitionDay) -> Bool {
        day.year == year && (month == nil || day.month == month)
    }

    /// "October 2026", or "2026" for the year.
    func title(locale: Locale = .current) -> String {
        month.map { "\(competitionMonthName($0, locale: locale)) \(year)" } ?? String(year)
    }

    /// "Your October", or "Your 2026" for the year.
    func headline(locale: Locale = .current) -> String {
        "Your " + (month.map { competitionMonthName($0, locale: locale) } ?? String(year))
    }
}

private func competitionMonthName(_ month: Int, locale: Locale) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = locale
    return calendar.standaloneMonthSymbols[month - 1]
}

/// The day a finished week counts on: its last, in the match's calendar.
private func competitionRecapDay(_ week: LocalCompetitionPresentation) -> CompetitionDay? {
    week.acceptedConfiguration.flatMap {
        try? $0.schedule.calendar.sevenDayWindow(startingOn: $0.schedule.startDay).last
    } ?? week.days.last?.day
}

/// Today in the publication's zone.
func competitionRecapToday(_ publication: LocalCompetitionPublication) -> CompetitionDay? {
    try? CompetitionCalendar(timeZoneIdentifier: publication.timeZoneIdentifier)
        .day(containing: publication.evaluatedAt)
}

/// A period's finished real weeks, oldest first, across every rival.
func competitionRecapWeeks(
    _ competitions: [LocalCompetitionPresentation],
    in period: CompetitionRecapPeriod
) -> [LocalCompetitionPresentation] {
    competitionHistoryWeeks(competitions).reversed().filter {
        competitionRecapDay($0).map(period.contains) ?? false
    }
}

/// Every month once it has ended and every year from its 31 December, with
/// a finished week in it. Newest first, a year before its December. Built
/// from the weeks on the phone, so past months stay.
func competitionRecapPeriods(
    _ competitions: [LocalCompetitionPresentation],
    today: CompetitionDay
) -> [CompetitionRecapPeriod] {
    var periods = Set<CompetitionRecapPeriod>()
    for week in competitionHistoryWeeks(competitions) {
        guard let day = competitionRecapDay(week) else { continue }
        if (day.year, day.month) < (today.year, today.month) {
            periods.insert(CompetitionRecapPeriod(year: day.year, month: day.month))
        }
        if day.year < today.year || (today.month == 12 && today.day == 31) {
            periods.insert(CompetitionRecapPeriod(year: day.year))
        }
    }
    return periods.sorted { ($0.year, $0.month ?? 13) > ($1.year, $1.month ?? 13) }
}

/// Home's one row: last month from the 1st to the 3rd, the year from
/// 31 December to 3 January (it holds December). Nil without a finished week.
func competitionRecapOffer(
    _ competitions: [LocalCompetitionPresentation],
    today: CompetitionDay
) -> CompetitionRecapPeriod? {
    let period: CompetitionRecapPeriod
    if today.month == 12, today.day == 31 {
        period = CompetitionRecapPeriod(year: today.year)
    } else if today.month == 1, today.day <= 3 {
        period = CompetitionRecapPeriod(year: today.year - 1)
    } else if today.day <= 3 {
        period = CompetitionRecapPeriod(year: today.year, month: today.month - 1)
    } else {
        return nil
    }
    return competitionRecapPeriods(competitions, today: today).contains(period) ? period : nil
}

private func competitionRecapTally(
    _ weeks: [LocalCompetitionPresentation]
) -> (won: Int, lost: Int, tied: Int) {
    let outcomes = weeks.compactMap(\.terminalResult?.outcome)
    return (
        outcomes.filter { $0 == .win }.count,
        outcomes.filter { $0 == .loss }.count,
        outcomes.filter { $0 == .tie }.count
    )
}

/// "won 3, lost 1", leaving out what didn't happen.
private func competitionRecapTallyWords(_ tally: (won: Int, lost: Int, tied: Int)) -> String {
    [(tally.won, "won"), (tally.lost, "lost"), (tally.tied, "tied")]
        .filter { $0.0 > 0 }
        .map { "\($0.1) \($0.0)" }
        .joined(separator: ", ")
}

private func competitionSentenceCase(_ text: String) -> String {
    text.prefix(1).uppercased() + text.dropFirst()
}

/// "4 weeks · won 3, lost 1": the Home and History rows.
func competitionRecapSummaryLine(
    _ competitions: [LocalCompetitionPresentation],
    period: CompetitionRecapPeriod
) -> String {
    let weeks = competitionRecapWeeks(competitions, in: period)
    return "\(competitionWeeksText(weeks.count)) · \(competitionRecapTallyWords(competitionRecapTally(weeks)))"
}

/// One card of the deck. Rows link to History instead of repeating it.
struct CompetitionRecapPeriodCard: Equatable, Identifiable {
    enum Kind: String { case weeks, record, belt, bestDay, rings, rival }
    /// Amber you, ink them, grey even.
    enum Side: Equatable { case you, them, even }
    enum Value: Equatable {
        case text(String, side: Side?)
        case record(won: Int, lost: Int, tied: Int)
    }
    /// A week or a person, each opened from History.
    enum Link: Hashable {
        case week(CompetitionID)
        case person(String)

        var historyRoutes: [CompetitionHomeRoute] {
            switch self {
            case let .week(id): [.history, .competition(id)]
            case let .person(identity): [.history, .person(identity)]
            }
        }
    }
    struct Row: Equatable {
        let title: String
        let detail: String
        let side: Side?
        let link: Link
    }

    let kind: Kind
    let label: String
    let value: Value
    let detail: String
    var rows: [Row] = []
    var id: Kind { kind }

    /// "Your record: won 3, lost 1 across 4 weeks, 2 rivals": a detail that
    /// starts with the value carries on from it instead of repeating it.
    var accessibilityText: String {
        let spoken = switch value {
        case let .text(text, _): text
        case let .record(won, lost, tied): competitionRecapTallyWords((won: won, lost: lost, tied: tied))
        }
        if detail.lowercased().hasPrefix(spoken.lowercased()) {
            return "\(label): \(spoken)\(detail.dropFirst(spoken.count))"
        }
        return "\(label): \(spoken). \(detail)"
    }
}

/// Weeks played, your record, belt moves, your best day, rings you closed
/// (your own values) and, with two or more rivals, the closest one. Each
/// appears only once it's true; nothing without a finished week. Opponents
/// show only as points, wins and the belt. `hidesNames` is the shared image.
func competitionRecapCards(
    _ competitions: [LocalCompetitionPresentation],
    period: CompetitionRecapPeriod,
    hidesNames: Bool = false,
    now: Date,
    locale: Locale = .current
) -> [CompetitionRecapPeriodCard] {
    typealias Card = CompetitionRecapPeriodCard
    let weeks = competitionRecapWeeks(competitions, in: period)
    guard !weeks.isEmpty else { return [] }
    func points(_ value: Double) -> String { competitionPointsText(value, locale: locale) }
    func range(_ week: LocalCompetitionPresentation) -> String {
        week.acceptedConfiguration.flatMap {
            competitionScheduleDateRangeText($0.schedule, now: now, locale: locale)
        } ?? ""
    }
    func weekRow(_ week: LocalCompetitionPresentation) -> Card.Row {
        let name = week.opponentDisplayName
        let result: (detail: String, side: Card.Side) = switch week.terminalResult?.outcome {
        case .win: ("Beat \(name)", .you)
        case .loss: ("Lost to \(name)", .them)
        case .tie, nil: ("Tied with \(name)", .even)
        }
        return Card.Row(title: range(week), detail: result.detail, side: result.side, link: .week(week.id))
    }

    // Newest played first, named as in their newest week.
    var rivals: [(identity: String, name: String, weeks: [LocalCompetitionPresentation])] = []
    for week in weeks.reversed() {
        if let index = rivals.firstIndex(where: { $0.identity == week.opponentIdentity }) {
            rivals[index].weeks.append(week)
        } else {
            rivals.append((identity: week.opponentIdentity, name: week.opponentDisplayName, weeks: [week]))
        }
    }
    func hidden(_ name: String) -> Bool { hidesNames || name == competitionFormerCompetitorName }
    func personRow(_ rival: (identity: String, name: String, weeks: [LocalCompetitionPresentation])) -> Card.Row {
        let tally = competitionRecapTally(rival.weeks)
        let record = ([tally.won, tally.lost] + (tally.tied > 0 ? [tally.tied] : []))
            .map(String.init).joined(separator: "–")
        return Card.Row(
            title: rival.name,
            detail: "\(competitionWeeksText(rival.weeks.count)) · \(record)",
            side: nil,
            link: .person(rival.identity)
        )
    }
    let rivalCount = rivals.count == 1 ? "1 rival" : "\(rivals.count) rivals"
    var cards: [Card] = []

    let against = rivals.count > 2 || rivals.contains(where: { hidden($0.name) })
        ? rivalCount
        : rivals.map { $0.name }.joined(separator: " and ")
    cards.append(Card(
        kind: .weeks,
        label: "Weeks played",
        value: .text(String(weeks.count), side: nil),
        detail: "Against \(against)",
        // ponytail: five rows, so a year doesn't become a second History.
        rows: rivals.prefix(5).map(personRow)
    ))

    let tally = competitionRecapTally(weeks)
    cards.append(Card(
        kind: .record,
        label: "Your record",
        value: .record(won: tally.won, lost: tally.lost, tied: tally.tied),
        detail: competitionSentenceCase(competitionRecapTallyWords(tally))
            + " across \(competitionWeeksText(weeks.count))"
            + (rivals.count > 1 ? ", \(rivalCount)" : ""),
        rows: weeks.suffix(5).map(weekRow)
    ))

    var events: [CompetitionBeltEvent] = []
    var beltRows: [Card.Row] = []
    for week in weeks {
        let found = competitionBeltEvent(for: week, in: competitions)
        guard let outcome = week.terminalResult?.outcome,
              let belt = competitionRecapBelt(
                  found,
                  outcome: outcome,
                  isRetired: week.opponentDisplayName == competitionFormerCompetitorName
              ),
              let event = found
        else { continue }
        events.append(event)
        beltRows.append(Card.Row(
            title: range(week),
            detail: competitionRecapBeltText(belt, opponentName: week.opponentDisplayName),
            side: belt.isYours ? .you : .them,
            link: .week(week.id)
        ))
    }
    // Yours only: their defenses and their first win list below but don't count.
    func count(_ matches: (CompetitionBeltEvent) -> Bool) -> Int { events.filter(matches).count }
    let took = count { if case .took(.you, _, _) = $0 { true } else { false } }
    let defended = count { if case .defended(.you, _, _) = $0 { true } else { false } }
    let lost = count { if case .took(.them, .some, _) = $0 { true } else { false } }
    if took + defended + lost > 0 {
        cards.append(Card(
            kind: .belt,
            label: "Belt moves",
            value: .text(String(took + defended + lost), side: took + defended > 0 ? .you : .them),
            detail: competitionSentenceCase(
                [(took, "took"), (defended, "defended"), (lost, "lost")]
                    .filter { $0.0 > 0 }
                    .map { "\($0.1) \($0.0)" }
                    .joined(separator: ", ")
            ),
            rows: Array(beltRows.suffix(5))
        ))
    }

    // max(by:) keeps the first of equal values: the earliest day.
    let scored = weeks.flatMap { week in
        week.days.compactMap { day in day.ownerAcceptedPoints.map { (week: week, day: day, points: $0) } }
    }
    if let best = scored.max(by: { $0.points < $1.points }), best.points > 0 {
        cards.append(Card(
            kind: .bestDay,
            label: "Your best day",
            value: .text(points(best.points), side: .you),
            detail: competitionDayText(best.day.day, now: now, locale: locale),
            rows: [weekRow(best.week)]
        ))
    }

    let days = weeks.flatMap(\.days)
    var closed = [0, 0, 0]
    for day in days {
        for (ring, isClosed) in (competitionClosedRings(day) ?? []).enumerated() where isClosed {
            closed[ring] += 1
        }
    }
    if closed.reduce(0, +) > 0 {
        let names = ["Move", "Exercise", competitionStandTitle(days).capitalized]
        cards.append(Card(
            kind: .rings,
            label: "Rings you closed",
            value: .text(points(Double(closed.reduce(0, +))), side: .you),
            detail: zip(names, closed).map { "\($0) \(points(Double($1)))" }.joined(separator: ", ")
        ))
    }

    // The smallest average gap a week; on a tie the one played most recently.
    func gap(_ weeks: [LocalCompetitionPresentation]) -> Double {
        weeks.reduce(0) { total, week in
            total + abs((week.terminalResult?.userPoints ?? 0) - (week.terminalResult?.opponentPoints ?? 0))
        } / Double(weeks.count)
    }
    if rivals.count > 1, let closest = rivals.min(by: { gap($0.weeks) < gap($1.weeks) }) {
        let tally = competitionRecapTally(closest.weeks)
        let average = points(gap(closest.weeks))
        let apart = "\(average) \(average == "1" ? "point" : "points") apart on average"
        cards.append(Card(
            kind: .rival,
            label: "Closest rival",
            value: hidden(closest.name)
                ? .record(won: tally.won, lost: tally.lost, tied: tally.tied)
                : .text(closest.name, side: nil),
            detail: hidden(closest.name)
                ? competitionSentenceCase(apart)
                : "\(competitionSentenceCase(competitionRecapTallyWords(tally))) · \(apart)",
            rows: [personRow(closest)]
        ))
    }
    return cards
}

/// Move, Exercise and Stand closed from your own values: the Health reading
/// against its goal, else the ring's share of its goal (100 is closed).
func competitionClosedRings(_ day: LocalCompetitionDayPresentation) -> [Bool]? {
    if let snapshot = day.ownerAcceptedSnapshot {
        return [snapshot.move, snapshot.exercise, snapshot.standOrRoll].map { reading in
            guard let value = reading.value, let goal = reading.goal, goal > 0 else { return false }
            return value >= goal
        }
    }
    guard day.ownerAcceptedPoints != nil, let rings = day.ownerRingPoints, rings.count == 3 else {
        return nil
    }
    return rings.map { $0 >= 100 }
}

private func competitionRecapValueText(_ value: CompetitionRecapPeriodCard.Value) -> Text {
    switch value {
    case let .text(text, side):
        Text(text).foregroundStyle(side == .you ? Theme.you : side == .even ? Theme.secondary : Theme.ink)
    case let .record(won, lost, tied):
        Text(String(won)).foregroundStyle(Theme.you)
            + Text("–").fontWeight(.light).foregroundStyle(Theme.faint)
            + Text(String(lost)).foregroundStyle(Theme.ink)
            + (tied > 0
                ? Text("–").fontWeight(.light).foregroundStyle(Theme.faint) + Text(String(tied)).foregroundStyle(Theme.secondary)
                : Text(""))
    }
}

/// One card as the shared image: the recap card's size and frame, no rows.
struct CompetitionRecapPeriodShareCard: View {
    /// "October 2026".
    let title: String
    let card: CompetitionRecapPeriodCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("HEALTHCOMP")
                    .font(.system(size: 13, weight: .heavy).width(.condensed))
                    .tracking(1.6)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Text(title)
                    .textCase(.uppercase)
                    .font(.system(size: 13, weight: .bold).width(.condensed))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 8) {
                Text(card.label)
                    .textCase(.uppercase)
                    .font(.system(size: 13, weight: .bold).width(.condensed))
                    .tracking(1.2)
                    .foregroundStyle(Theme.secondary)
                competitionRecapValueText(card.value)
                    .font(.score(size: 120))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                Text(card.detail)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 12)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text("healthcomp.app")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 10)
        }
        .padding(28)
        .frame(
            width: CompetitionRecapCard.size.width,
            height: CompetitionRecapCard.size.height,
            alignment: .topLeading
        )
        .background(Theme.ground)
    }
}

/// A swipeable stack of a month's or a year's cards, each with its own Share.
@MainActor
struct CompetitionRecapDeck: View {
    let publication: LocalCompetitionPublication
    let period: CompetitionRecapPeriod
    let open: (CompetitionRecapPeriodCard.Link) -> Void

    @AppStorage("healthcomp.recapHidesName") private var hidesName = false
    @State private var shown = CompetitionRecapPeriodCard.Kind.weeks
    @State private var renderFailed = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize: CGFloat = 148

    var body: some View {
        let cards = competitionRecapCards(
            publication.dashboard.competitions,
            period: period,
            now: publication.evaluatedAt,
            locale: locale
        )
        let index = cards.firstIndex { $0.kind == shown } ?? 0
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(cards.indices, id: \.self) { item in
                    Capsule()
                        .fill(item <= index ? Theme.ink : Theme.track)
                        .frame(height: 4)
                }
            }
            .animation(Motion.fade, value: index)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Card \(index + 1) of \(cards.count)")
            HStack(spacing: 12) {
                Text(period.headline(locale: locale).uppercased())
                    .font(.themeLabel)
                    .tracking(1.2)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                CompetitionDrawerCloseButton { dismiss() }
            }
            if cards.isEmpty {
                Text("Finished matches appear here.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                Spacer()
            } else {
                TabView(selection: $shown) {
                    ForEach(cards) { card in
                        ScrollView {
                            page(card)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .tag(card.kind)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                share(cards[index])
                if renderFailed {
                    Text("Couldn’t make the image.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondary)
                        .transition(Motion.appear)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Theme.ground)
        .sensoryFeedback(.error, trigger: renderFailed) { _, failed in failed }
        .onChange(of: shown) { renderFailed = false }
        .accessibilityIdentifier("competition.recap.deck")
    }

    private func page(_ card: CompetitionRecapPeriodCard) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(card.label.uppercased())
                    .font(.themeLabel)
                    .tracking(1.2)
                    .foregroundStyle(Theme.secondary)
                competitionRecapValueText(card.value)
                    .font(.score(size: min(valueSize, 180)))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                Text(card.detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 56)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(card.accessibilityText)
            .accessibilityIdentifier("competition.recap.\(card.kind.rawValue)")

            if !card.rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(card.rows.enumerated()), id: \.offset) { item, row in
                        if item > 0 {
                            CompetitionRowDivider(inset: 16)
                        }
                        Button { open(row.link) } label: { rowLabel(row) }
                            .buttonStyle(CompetitionRowButtonStyle())
                            .accessibilityLabel("\(row.title), \(row.detail)")
                            .accessibilityHint({
                                if case .person = row.link { return "Opens their page in History" }
                                return "Opens this match in History"
                            }())
                    }
                }
                .themePanel()
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // At accessibility sizes the detail sits under the title.
    private func rowLabel(_ row: CompetitionRecapPeriodCard.Row) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return HStack(spacing: 12) {
            if let side = row.side {
                SlantedBar()
                    .fill(side == .you ? Theme.youFill : side == .them ? Theme.ink : Theme.faint)
                    .frame(width: 26, height: 16)
            }
            layout {
                Text(row.title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 8)
                }
                Text(row.detail)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(row.side == .you ? Theme.you : Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The image uses the Share Result sheet's Show / Hide name choice.
    private func share(_ card: CompetitionRecapPeriodCard) -> some View {
        Button {
            let shared = competitionRecapCards(
                publication.dashboard.competitions,
                period: period,
                hidesNames: hidesName,
                now: publication.evaluatedAt,
                locale: locale
            ).first { $0.kind == card.kind } ?? card
            guard let image = competitionShareImage(
                CompetitionRecapPeriodShareCard(title: period.title(locale: locale), card: shared)
            ),
                  let png = image.pngData()
            else {
                renderFailed = true
                return
            }
            renderFailed = false
            competitionPresentShareSheet(
                CompetitionRecapShareItem(png: png, image: image, title: period.headline(locale: locale))
            )
        } label: {
            Label("Share This Card", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(PrimaryButtonStyle())
        .accessibilityHint("Opens the system share sheet")
        .accessibilityIdentifier("competition.recap.deck.share")
    }
}

extension View {
    /// The month or year deck over everything. A row closes it and opens
    /// History at that week or person.
    func competitionRecapDeck(
        _ period: Binding<CompetitionRecapPeriod?>,
        publication: LocalCompetitionPublication?,
        openHistory: @escaping ([CompetitionHomeRoute]) -> Void
    ) -> some View {
        fullScreenCover(item: period) { shown in
            if let publication {
                CompetitionRecapDeck(publication: publication, period: shown) { link in
                    period.wrappedValue = nil
                    openHistory(link.historyRoutes)
                }
            }
        }
    }
}

/// The Home row and each History row: "Your October", "4 weeks · won 3, lost 1".
struct CompetitionRecapRow: View {
    let title: String
    let period: CompetitionRecapPeriod
    let competitions: [LocalCompetitionPresentation]
    /// Home's row is its own panel; History's sit in one.
    var isPanel = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text(competitionRecapSummaryLine(competitions, period: period))
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(isPanel ? Theme.panel : .clear, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
        }
        .accessibilityHint(period.month == nil ? "Opens your year" : "Opens your month")
    }
}

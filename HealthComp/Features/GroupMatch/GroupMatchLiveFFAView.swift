import CompetitionCore
import ComposableArchitecture
import SwiftUI

/// Live free-for-all: the lead line to the next place up, the standings,
/// what it takes, and the week.
struct GroupMatchLiveFFAView: View {
    let match: GroupMatchPresentation
    let store: StoreOf<GroupMatchFeature>

    @ScaledMetric(relativeTo: .title) private var placeSize: CGFloat = 28
    @ScaledMetric(relativeTo: .headline) private var avatarSize: CGFloat = 32
    @Environment(\.locale) private var locale

    var body: some View {
        GroupMatchLiveScreen(match: match, store: store) { openDay in
            if competitionShouldShowScores(match.lifecycle) {
                GroupMatchLeadLine(match: match)
            }
            // Banter's place: nothing shows until there's a line.
            Color.clear.frame(height: 0).accessibilityIdentifier("competition.group.banter")
            SectionLabel("STANDINGS")
            standings
            if let takes = match.whatItTakes {
                SectionLabel("WHAT IT TAKES")
                VStack(alignment: .leading, spacing: 6) {
                    GroupMatchHighlightedText(text: takes.target, points: takes.points)
                    if let chaser = takes.chaser {
                        Text(chaser)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .themePanel()
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("competition.group.what-it-takes")
            }
            if competitionShouldShowScores(match.lifecycle) {
                SectionLabel("THE WEEK")
                GroupWeekGrid(match: match, openDay: openDay)
                Text(footer)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: String {
        guard let bot = match.seats.first(where: \.isBot) else {
            return "A filled square won that day. Tap a day for everyone’s rings."
        }
        return "\(bot.name)’s week was set before Day 1. Bots can’t be nudged and don’t get reactions."
    }

    private var standings: some View {
        let rows = match.standingRows
        let top = max(rows.map(\.centipoints).max() ?? 0, 1)
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                if case let .seat(id) = row.subject, let seat = match.seats.first(where: { $0.id == id }) {
                    standingRow(row, seat: seat, share: Double(row.centipoints) / Double(top))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .themePanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.group.standings")
    }

    private func standingRow(_ row: GroupMatchStandingRow, seat: GroupMatchSeat, share: Double) -> some View {
        let isYou = seat.id == match.viewerSeatID
        let showsScores = competitionShouldShowScores(match.lifecycle)
        let points = Double(row.centipoints) / 100
        return HStack(spacing: 12) {
            if showsScores {
                Text("\(row.place)")
                    .font(.score(size: placeSize))
                    .foregroundStyle(isYou ? Theme.you : Theme.ink)
                    .frame(minWidth: 16, alignment: .leading)
            }
            PersonAvatar(name: seat.name, photo: seat.profileID, size: avatarSize, isYou: isYou, isBot: seat.isBot)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(isYou ? "You" : seat.name)
                        .fontWeight(isYou ? .bold : .regular)
                        .foregroundStyle(isYou ? Theme.you : Theme.ink)
                    if seat.isBot { GroupMatchTag("BOT") }
                    if match.hasLeft(seat) { GroupMatchTag("LEFT") }
                }
                if showsScores {
                    Capsule()
                        .fill(Theme.hairline)
                        .frame(height: 4)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(isYou ? Theme.youFill : Theme.ink)
                                .scaleEffect(x: share, anchor: .leading)
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsScores {
                Text(competitionPointsText(points, locale: locale))
                    .font(.score(size: placeSize).monospacedDigit())
                    .foregroundStyle(isYou ? Theme.you : Theme.ink)
                    .fixedSize()
            }
        }
        .frame(minHeight: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(standingLabel(row, seat: seat, isYou: isYou, showsScores: showsScores))
        .accessibilityIdentifier("competition.group.standing.\(row.place)")
    }

    private func standingLabel(
        _ row: GroupMatchStandingRow, seat: GroupMatchSeat, isYou: Bool, showsScores: Bool
    ) -> String {
        let parts: [String?] = [
            showsScores ? GroupMatchPresentation.placeText(row.place) : nil,
            isYou ? "You" : seat.name,
            seat.isBot ? "bot" : nil,
            match.hasLeft(seat) ? "left the match" : nil,
            showsScores ? competitionPointsAccessibilityText(Double(row.centipoints) / 100, locale: locale) : nil,
        ]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}

extension GroupMatchPresentation {
    /// "Outscore Sam by 49 from here to take 1st." and who's closest behind
    /// you. The gap is the current one, today's points included.
    /// Nil unless you're chasing someone today.
    var whatItTakes: (target: String, points: String, chaser: String?)? {
        guard liveDay != nil, !hasLeft(viewer), case let .chasing(_, gap, behind) = lead,
              let place = standingRows.first(where: { behind.contains($0.subject) })?.place
        else { return nil }
        // Whole points that pass them, not just tie.
        let points = Self.pointsText(gap / 100 * 100 + 100)
        let names = behind.map(name(of:)).formatted(.list(type: .and))
        let standings = projection.standings
        let chasers = standings.compactMap { standing -> (MatchStandingSubject, Int)? in
            guard let next = MatchScoring.nextPlaceUp(for: standing.subject, in: standings),
                  next.subjects.contains(viewerSubject)
            else { return nil }
            return (standing.subject, next.centipointsToTie)
        }
        let chaser = chasers.first.map { first in
            let names = chasers.map { name(of: $0.0) }.formatted(.list(type: .and))
            return "\(names) \(chasers.count == 1 ? "is" : "are") \(Self.pointsText(first.1)) behind you."
        }
        return ("Outscore \(names) by \(points) from here to take \(Self.placeText(place)).", points, chaser)
    }
}

/// What both live screens share: the status row, the ••• menu with Leave
/// Match, and the push into one day.
struct GroupMatchLiveScreen<Content: View>: View {
    let match: GroupMatchPresentation
    let store: StoreOf<GroupMatchFeature>
    @ViewBuilder let content: (_ openDay: @escaping (Int) -> Void) -> Content

    @State private var day: Int?
    @State private var confirmsLeave = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupMatchStatusRow(match: match)
                if store.failed.contains(.leave(match.id)) {
                    Text("Couldn’t leave the match. Check your connection and try again.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("competition.group.leave.error")
                }
                content { day = $0 }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Theme.ground)
        .navigationTitle(match.format.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if match.canLeave {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            confirmsLeave = true
                        } label: {
                            Label("Leave Match", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .disabled(store.inFlight.contains(.leave(match.id)))
                        .accessibilityIdentifier("competition.group.leave")
                    } label: {
                        CompetitionMoreLabel()
                    }
                    .accessibilityIdentifier("competition.more")
                }
            }
        }
        .confirmationDialog("Leave the match?", isPresented: $confirmsLeave, titleVisibility: .visible) {
            Button("Leave Match", role: .destructive) { store.send(.commandTapped(.leave(match.id))) }
            Button("Keep Playing", role: .cancel) {}
        } message: {
            Text(leaveMessage)
        }
        .navigationDestination(item: $day) { ordinal in
            GroupMatchDayView(match: match, ordinal: ordinal, store: store)
        }
    }

    private var leaveMessage: String {
        let partner = match.seats.first {
            $0.team != nil && $0.team == match.viewer.team && $0.id != match.viewerSeatID && !match.hasLeft($0)
        }
        return "Your synced points stay in. Points not sent yet won’t count."
            + (partner.map { " \($0.name) plays on." } ?? "")
    }
}

/// "● LIVE · DAY 4 OF 7 … ENDS WEDNESDAY NIGHT"
struct GroupMatchStatusRow: View {
    let match: GroupMatchPresentation

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let status = competitionStatusText(
            match.lifecycle, schedule: match.schedule, opponentDisplayName: "", style: .card,
            locale: locale, timeZone: timeZone
        )
        let isLive = match.liveDay != nil
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isLive {
                    Circle().fill(Theme.ink).frame(width: 8, height: 8)
                }
                Text(isLive ? "Live" : status.title).foregroundStyle(Theme.ink)
                    + Text(isLive ? " · \(status.title)" : "").foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let timing = status.timing {
                Text(timing)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.themeLabel)
        .tracking(1.2)
        .textCase(.uppercase)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(((isLive ? ["Live"] : []) + [status.line]).joined(separator: ", "))
        .accessibilityIdentifier("competition.group.status")
    }
}

/// "You're 2nd. 48 behind Sam.", the points in bold amber. Once you've
/// left: "You left on Day 4. Your 1,664 stays in."
struct GroupMatchLeadLine: View {
    let match: GroupMatchPresentation

    var body: some View {
        if let day = match.configuration.leaveCutoffs[match.viewerSeatID] {
            let points = GroupMatchPresentation.pointsText(match.projection.seatTotals[match.viewerSeatID] ?? 0)
            let stays = match.format == .doubles ? "stays with your team" : "stays in"
            GroupMatchHighlightedText(text: "You left on Day \(day). Your \(points) \(stays).", points: points)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("competition.group.lead")
        } else if let text = match.leadText {
            let points: Int? = switch match.lead {
            case let .chasing(_, gap, _): gap
            case let .ahead(margin): margin
            default: nil
            }
            GroupMatchHighlightedText(text: text, points: points.map(GroupMatchPresentation.pointsText))
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("competition.group.lead")
        }
    }
}

/// Ink text with its last `points` in bold amber: amber is always you.
struct GroupMatchHighlightedText: View {
    let text: String
    let points: String?

    var body: some View {
        var attributed = AttributedString(text)
        if let points, let range = attributed.range(of: points, options: .backwards) {
            attributed[range].foregroundColor = Theme.you
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(attributed)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

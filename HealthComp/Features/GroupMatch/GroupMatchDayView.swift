import CompetitionCore
import ComposableArchitecture
import SwiftUI

/// One day for everyone: each person's points and rings, best first, and a
/// reaction for anyone else's day. Doubles groups the same panels by team.
/// Bots show points only.
struct GroupMatchDayView: View {
    let match: GroupMatchPresentation
    let ordinal: Int
    let store: StoreOf<GroupMatchFeature>

    @State private var reactingTo: UUID?
    /// What you sent from here, shown until the match catches up; nil
    /// while removing. The match's own reactions are the rest.
    @State private var sent: [UUID: CompetitionReactionKind?] = [:]
    @ScaledMetric(relativeTo: .title) private var pointsSize: CGFloat = 28
    @ScaledMetric(relativeTo: .headline) private var avatarSize: CGFloat = 32
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Day \(ordinal) · \(stateText)")
                    .themeLabel()
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.secondary)
                    .accessibilityLabel("Day \(ordinal) · \(stateText)")
                    .accessibilityIdentifier("competition.group.day.status")
                ForEach(standings, id: \.subject, content: section)
                if canReact {
                    Text("Tap a player to react to their day. Everyone in the match sees reactions.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Theme.ground)
        .navigationTitle(dayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var standings: [MatchStanding] { match.dayStandings(ordinal: ordinal) }
    private var winners: [MatchStandingSubject] { match.finalDayWinners(ordinal: ordinal) }

    private var dayName: String {
        match.calendarDays.indices.contains(ordinal - 1)
            ? weekdayName(match.calendarDays[ordinal - 1], locale: locale) : "Day \(ordinal)"
    }

    private var stateText: String {
        if ordinal == match.liveDay { return "Today" }
        return winners.isEmpty ? "Not final yet" : "Final"
    }

    /// Day reactions close when the result lands, as in a duel.
    private var canReact: Bool {
        switch match.lifecycle {
        case .active, .endsToday, .tallying: match.seats.contains { canReact(to: $0) }
        default: false
        }
    }

    private func canReact(to seat: GroupMatchSeat) -> Bool {
        !seat.isBot && seat.id != match.viewerSeatID && !match.hasLeft(match.viewer)
            && match.dayCentipoints(seat, ordinal: ordinal) != nil
    }

    /// A player, or in doubles a team header and its two players.
    @ViewBuilder
    private func section(_ standing: MatchStanding) -> some View {
        let isTeam = match.format == .doubles
        let won = !isTeam && winners.contains(standing.subject)
        if isTeam {
            teamHeader(standing)
        }
        ForEach(match.members(of: standing.subject)) { seat in
            playerPanel(seat, won: won)
        }
    }

    private func teamHeader(_ standing: MatchStanding) -> some View {
        let isYours = standing.subject == match.viewerSubject
        let name = match.name(of: standing.subject)
        let points = Double(standing.centipoints) / 100
        let won = winners.contains(standing.subject)
        // The chip goes under the name, and at accessibility sizes the points too.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            VStack(alignment: .leading, spacing: 6) {
                Text(name.uppercased(with: locale))
                    .themeLabel()
                    .foregroundStyle(isYours ? Theme.you : Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if won { wonChip }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Text(competitionPointsText(points, locale: locale))
                .font(.title3.weight(.heavy).width(.condensed).monospacedDigit())
                .foregroundStyle(isYours ? Theme.you : Theme.ink)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(name)\(won ? ", won the day" : ""), \(competitionPointsAccessibilityText(points, locale: locale))")
    }

    private var wonChip: some View {
        Text("WON THE DAY")
            .font(.caption.weight(.bold).width(.condensed))
            .kerning(1.2)
            .foregroundStyle(Theme.onInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8))
            .fixedSize()
    }

    @ViewBuilder
    private func playerPanel(_ seat: GroupMatchSeat, won: Bool) -> some View {
        let panel = playerContent(seat, won: won)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .themePanel()
        VStack(alignment: .leading, spacing: 10) {
            if canReact(to: seat) {
                Button {
                    reactingTo = reactingTo == seat.id ? nil : seat.id
                } label: {
                    panel
                }
                .buttonStyle(CompetitionPressButtonStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(playerLabel(seat, won: won))
                .accessibilityHint("Shows reactions")
                .accessibilityAddTraits(.isButton)
                .modifier(CompetitionProfileAction(route: match.profileRoute(seat), name: seat.name))
                .accessibilityIdentifier("competition.group.day.player.\(seat.number)")
                if reactingTo == seat.id {
                    picker(seat)
                }
            } else {
                panel
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(playerLabel(seat, won: won))
                    .modifier(CompetitionProfileAction(route: match.profileRoute(seat), name: seat.name))
                    .accessibilityIdentifier("competition.group.day.player.\(seat.number)")
            }
        }
    }

    private func playerContent(_ seat: GroupMatchSeat, won: Bool) -> some View {
        let isYou = seat.id == match.viewerSeatID
        let points = match.dayCentipoints(seat, ordinal: ordinal).map { Double($0) / 100 }
        let rings = match.rings.first { $0.seatID == seat.id && $0.ordinal == ordinal }
        let isLarge = dynamicTypeSize.isAccessibilitySize
        let name = Text(isYou ? "You" : seat.name)
            .fontWeight(isYou ? .bold : .regular)
            .foregroundStyle(isYou ? Theme.you : Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
        let pointsText = Text(competitionPointsText(points, locale: locale).replacingOccurrences(of: "--", with: "–"))
            .font(.score(size: pointsSize).monospacedDigit())
            .foregroundStyle(isYou ? Theme.you : Theme.ink)
            .fixedSize()
        return VStack(alignment: .leading, spacing: 8) {
            if isLarge {
                // Stacked so the name keeps the line: avatar and name, then
                // the tags and chip, then the points.
                HStack(spacing: 12) {
                    PersonAvatar(name: seat.name, photo: seat.profileID, size: min(avatarSize, 56), isYou: isYou, isBot: seat.isBot)
                    name
                }
                // Another person opens their profile; the rest of the panel reacts.
                .modifier(CompetitionProfileTap(route: match.profileRoute(seat)))
                if seat.isBot { GroupMatchTag("BOT") }
                if match.hasLeft(seat) { GroupMatchTag("LEFT") }
                if won { wonChip }
                pointsText
            } else {
                HStack(spacing: 12) {
                    PersonAvatar(name: seat.name, photo: seat.profileID, size: avatarSize, isYou: isYou, isBot: seat.isBot)
                        .modifier(CompetitionProfileTap(route: match.profileRoute(seat)))
                    let tags = Group {
                        if seat.isBot { GroupMatchTag("BOT") }
                        if match.hasLeft(seat) { GroupMatchTag("LEFT") }
                    }
                    // One line beside the name when it fits; the chip drops under it otherwise.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            name
                            tags
                            if won { wonChip }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                name
                                tags
                            }
                            if won { wonChip }
                        }
                    }
                    Spacer(minLength: 8)
                    pointsText
                }
            }
            // Bots have points, never rings.
            if let rings, !seat.isBot {
                ringRows(rings.centipoints, isYou: isYou)
            }
            let shown = reactions(on: seat)
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(shown, id: \.authorSeatID) { reaction in
                        let layout = isLarge
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
                        layout {
                            CompetitionReactionEmoji(kind: reaction.kind)
                            Text("\(authorName(reaction)) reacted")
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// Everyone's reactions to this seat's day, yours first.
    private func reactions(on seat: GroupMatchSeat) -> [GroupMatchReaction] {
        let others = match.reactions.filter {
            $0.targetSeatID == seat.id && $0.ordinal == ordinal && $0.authorSeatID != match.viewerSeatID
        }
        guard let own = ownReaction(seat) else { return others }
        return [GroupMatchReaction(authorSeatID: match.viewerSeatID, targetSeatID: seat.id, ordinal: ordinal, kind: own)] + others
    }

    /// What you sent from here unless it failed, otherwise what the match has.
    private func ownReaction(_ seat: GroupMatchSeat) -> CompetitionReactionKind? {
        if !isFailed(seat), let local = sent[seat.id] { return local }
        return match.reactions.first {
            $0.authorSeatID == match.viewerSeatID && $0.targetSeatID == seat.id && $0.ordinal == ordinal
        }?.kind
    }

    private func authorName(_ reaction: GroupMatchReaction) -> String {
        reaction.authorSeatID == match.viewerSeatID
            ? "You" : match.seats.first { $0.id == reaction.authorSeatID }?.name ?? "Former competitor"
    }

    private func isTarget(_ seat: GroupMatchSeat) -> (GroupMatchCommand) -> Bool {
        { command in
            guard case let .react(id, seatID, day, _) = command else { return false }
            return id == match.id && seatID == seat.id && day == ordinal
        }
    }

    private func isFailed(_ seat: GroupMatchSeat) -> Bool {
        store.failed.contains(where: isTarget(seat))
    }

    private func ringRows(_ centipoints: [Int], isYou: Bool) -> some View {
        let colors = isYou ? [Theme.move, Theme.exercise, Theme.stand] : [Theme.ink, Theme.ink, Theme.ink]
        let rings = Array(["Move", "Exercise", "Stand"].enumerated())
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Label and value on one line, never broken; the bar under them.
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rings, id: \.offset) { index, title in
                        let percent = Self.percent(centipoints[index])
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(title)
                                    .foregroundStyle(Theme.secondary)
                                    .fixedSize()
                                Spacer(minLength: 8)
                                Text("\(percent)%")
                                    .fontWeight(.bold)
                                    .foregroundStyle(Theme.ink)
                                    .fixedSize()
                            }
                            ringBar(colors[index], percent)
                        }
                    }
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    ForEach(rings, id: \.offset) { index, title in
                        let percent = Self.percent(centipoints[index])
                        GridRow {
                            Text(title)
                                .foregroundStyle(Theme.secondary)
                            ringBar(colors[index], percent)
                            Text("\(percent)%")
                                .fontWeight(.bold)
                                .foregroundStyle(Theme.ink)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .font(.caption)
    }

    private func ringBar(_ color: Color, _ percent: Int) -> some View {
        Capsule()
            .fill(Theme.hairline)
            .frame(height: 8)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(color)
                    .scaleEffect(x: min(Double(percent), 200) / 200, anchor: .leading)
            }
    }

    /// A ring's points are its percent: 1 point per 1%.
    private static func percent(_ centipoints: Int) -> Int { (centipoints + 50) / 100 }

    private func playerLabel(_ seat: GroupMatchSeat, won: Bool) -> String {
        let points = match.dayCentipoints(seat, ordinal: ordinal).map { Double($0) / 100 }
        var parts = [seat.id == match.viewerSeatID ? "You" : seat.name]
        if seat.isBot { parts.append("bot") }
        if match.hasLeft(seat) { parts.append("left the match") }
        if won { parts.append("won the day") }
        parts.append(competitionPointsAccessibilityText(points, locale: locale))
        if !seat.isBot, let rings = match.rings.first(where: { $0.seatID == seat.id && $0.ordinal == ordinal }) {
            parts += zip(["Move", "Exercise", "Stand"], rings.centipoints).map { "\($0) \(Self.percent($1)) percent" }
        }
        parts += reactions(on: seat).map { "\(authorName($0)) reacted \($0.kind.spokenName)" }
        return parts.joined(separator: ", ")
    }

    private func picker(_ seat: GroupMatchSeat) -> some View {
        // A failed send isn't selected, so tapping it again retries it.
        let failed = isFailed(seat)
        let selection = failed ? nil : ownReaction(seat)
        return CompetitionReactionPicker(
            selection: selection,
            isPending: store.inFlight.contains(where: isTarget(seat)),
            failed: failed,
            select: { kind in
                let next = selection == kind ? nil : kind
                sent.updateValue(next, forKey: seat.id)
                store.send(.commandTapped(.react(match.id, seatID: seat.id, ordinal: ordinal, next)))
            }
        )
        .padding(.horizontal, 4)
    }
}

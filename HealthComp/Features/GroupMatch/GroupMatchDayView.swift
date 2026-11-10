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
    /// What you sent from here; the read model doesn't carry reactions yet.
    @State private var sent: [UUID: CompetitionReactionKind] = [:]
    @ScaledMetric(relativeTo: .title) private var pointsSize: CGFloat = 28
    @ScaledMetric(relativeTo: .headline) private var avatarSize: CGFloat = 32
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Day \(ordinal) · \(stateText)")
                    .font(.themeLabel)
                    .tracking(1.2)
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
            .padding(.horizontal, 20)
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
        return HStack(spacing: 8) {
            Text(name.uppercased(with: locale))
                .font(.themeLabel)
                .tracking(1.2)
                .foregroundStyle(isYours ? Theme.you : Theme.ink)
            if won { wonChip }
            Spacer(minLength: 8)
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
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(playerLabel(seat, won: won))
                .accessibilityHint("Shows reactions")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("competition.group.day.player.\(seat.number)")
                if reactingTo == seat.id {
                    picker(seat)
                }
            } else {
                panel
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(playerLabel(seat, won: won))
                    .accessibilityIdentifier("competition.group.day.player.\(seat.number)")
            }
        }
    }

    private func playerContent(_ seat: GroupMatchSeat, won: Bool) -> some View {
        let isYou = seat.id == match.viewerSeatID
        let points = match.dayCentipoints(seat, ordinal: ordinal).map { Double($0) / 100 }
        let rings = match.rings.first { $0.seatID == seat.id && $0.ordinal == ordinal }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                PersonAvatar(name: seat.name, photo: seat.profileID, size: avatarSize, isYou: isYou, isBot: seat.isBot)
                Text(isYou ? "You" : seat.name)
                    .fontWeight(isYou ? .bold : .regular)
                    .foregroundStyle(isYou ? Theme.you : Theme.ink)
                if seat.isBot { GroupMatchTag("BOT") }
                if match.hasLeft(seat) { GroupMatchTag("LEFT") }
                if won { wonChip }
                Spacer(minLength: 8)
                Text(competitionPointsText(points, locale: locale).replacingOccurrences(of: "--", with: "–"))
                    .font(.score(size: pointsSize).monospacedDigit())
                    .foregroundStyle(isYou ? Theme.you : Theme.ink)
                    .fixedSize()
            }
            // Bots have points, never rings.
            if let rings, !seat.isBot {
                ringRows(rings.centipoints, isYou: isYou)
            }
        }
    }

    private func ringRows(_ centipoints: [Int], isYou: Bool) -> some View {
        let colors = isYou ? [Theme.move, Theme.exercise, Theme.stand] : [Theme.ink, Theme.ink, Theme.ink]
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            ForEach(Array(["Move", "Exercise", "Stand"].enumerated()), id: \.offset) { index, title in
                let percent = Self.percent(centipoints[index])
                GridRow {
                    Text(title)
                        .foregroundStyle(Theme.secondary)
                    Capsule()
                        .fill(Theme.hairline)
                        .frame(height: 8)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(colors[index])
                                .scaleEffect(x: min(Double(percent), 200) / 200, anchor: .leading)
                        }
                    Text("\(percent)%")
                        .fontWeight(.bold)
                        .foregroundStyle(Theme.ink)
                        .gridColumnAlignment(.trailing)
                }
            }
        }
        .font(.caption)
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
        return parts.joined(separator: ", ")
    }

    private func picker(_ seat: GroupMatchSeat) -> some View {
        let isTarget = { (command: GroupMatchCommand) -> Bool in
            guard case let .react(id, seatID, day, _) = command else { return false }
            return id == match.id && seatID == seat.id && day == ordinal
        }
        return CompetitionReactionPicker(
            selection: sent[seat.id],
            isPending: store.inFlight.contains(where: isTarget),
            failed: store.failed.contains(where: isTarget),
            select: { kind in
                let next = sent[seat.id] == kind ? nil : kind
                sent[seat.id] = next
                store.send(.commandTapped(.react(match.id, seatID: seat.id, ordinal: ordinal, next)))
            }
        )
        .padding(.horizontal, 4)
    }
}

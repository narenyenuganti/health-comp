import CompetitionCore
import SwiftUI

/// Group matches in History, below the duel record and apart from it: finishes
/// for free-for-all, wins and losses per partner for doubles, then each week.
/// Nothing here touches a belt or a head-to-head record. Empty until a group
/// match has the server's result.
struct GroupMatchRecord: View {
    let matches: [GroupMatchPresentation]
    var now = Date()

    @Environment(\.locale) private var locale

    /// Finished, newest first.
    static func finished(_ matches: [GroupMatchPresentation]) -> [GroupMatchPresentation] {
        matches
            .filter { $0.frozenStandings != nil && $0.viewerRow != nil }
            .sorted { $0.startDate > $1.startDate }
    }

    var body: some View {
        let finished = Self.finished(matches)
        if !finished.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("GROUP MATCHES")
                    .padding(.horizontal, 4)
                VStack(spacing: 0) {
                    let freeForAll = finished.filter { $0.format != .doubles }
                    let doubles = finished.filter { $0.format == .doubles }
                    if !freeForAll.isEmpty {
                        freeForAllRow(freeForAll)
                    }
                    if !doubles.isEmpty {
                        if !freeForAll.isEmpty { CompetitionRowDivider(inset: 16) }
                        doublesRow(doubles)
                    }
                    ForEach(finished) { match in
                        CompetitionRowDivider(inset: 16)
                        weekRow(match)
                    }
                }
                .themePanel()
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("competition.group.record")
        }
    }

    // MARK: Record

    /// "1st twice, 2nd once"; "2 firsts of 5", shared firsts included.
    private func freeForAllRow(_ matches: [GroupMatchPresentation]) -> some View {
        let places = matches.compactMap { $0.viewerRow?.place }
        let finishes = Set(places).sorted().map { place in
            let count = places.filter { $0 == place }.count
            let times = switch count {
            case 1: "once"
            case 2: "twice"
            default: "\(count) times"
            }
            return "\(GroupMatchPresentation.placeText(place)) \(times)"
        }.joined(separator: ", ")
        let firsts = places.filter { $0 == 1 }.count
        return recordRow(
            title: "Free-for-all",
            detail: finishes,
            value: Text(String(firsts)).foregroundStyle(Theme.you)
                + Text(" \(firsts == 1 ? "first" : "firsts") of \(places.count)"),
            accessibility: "Free-for-all, first in \(firsts) of \(places.count). \(finishes)",
            identifier: "competition.group.record.free-for-all"
        )
    }

    /// Won, lost and tied with each partner of these finished matches, in
    /// their order (newest first in History): one record per
    /// person (by profile) or bot (by mode), under the newest name.
    static func partnerRecords(_ matches: [GroupMatchPresentation]) -> [(name: String, record: [Int])] {
        var partners: [GroupMatchSeat.Partner] = []
        var names: [GroupMatchSeat.Partner: String] = [:]
        var records: [GroupMatchSeat.Partner: [Int]] = [:]
        for match in matches where match.format == .doubles {
            guard let seat = match.partner else { continue }
            if records[seat.partnerKey] == nil {
                partners.append(seat.partnerKey)
                names[seat.partnerKey] = seat.name
            }
            records[seat.partnerKey, default: [0, 0, 0]][match.doublesOutcome.rawValue] += 1
        }
        return partners.map { (names[$0]!, records[$0]!) }
    }

    /// "2–0 with Priya, 1–1 with Sam"; ties only when there are some.
    private func doublesRow(_ matches: [GroupMatchPresentation]) -> some View {
        let partners = Self.partnerRecords(matches)
        func text(_ record: [Int]) -> String {
            (record[2] > 0 ? record : Array(record.prefix(2))).map(String.init).joined(separator: "–")
        }
        let total = partners.reduce(into: [0, 0, 0]) { sum, partner in
            for index in 0..<3 { sum[index] += partner.record[index] }
        }
        var value = Text(String(total[0])).foregroundStyle(Theme.you) + Text("–\(total[1])")
        if total[2] > 0 { value = value + Text("–\(total[2])").foregroundStyle(Theme.secondary) }
        return recordRow(
            title: "Doubles",
            detail: partners.map { "\(text($0.record)) with \($0.name)" }.joined(separator: ", "),
            value: value,
            accessibility: "Doubles, \(total[0]) won, \(total[1]) lost"
                + (total[2] > 0 ? ", \(total[2]) tied" : "") + ". "
                + partners.map { "\(text($0.record)) with \($0.name)" }.joined(separator: ", "),
            identifier: "competition.group.record.doubles"
        )
    }

    private func recordRow(
        title: String, detail: String, value: Text, accessibility: String, identifier: String
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                labels(title, detail)
                Spacer(minLength: 8)
                value.font(.title2.weight(.heavy).width(.condensed).monospacedDigit()).fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                labels(title, detail)
                value.font(.title2.weight(.heavy).width(.condensed).monospacedDigit())
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
        .accessibilityIdentifier(identifier)
    }

    private func labels(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Weeks

    /// "Four-Way · Nov 2 – 8 · Sam, Priya, Leo · 1st of 4", opening its result.
    private func weekRow(_ match: GroupMatchPresentation) -> some View {
        let others = match.seats.filter { $0.id != match.viewerSeatID }
        let title: String
        let names: String
        let verdict: String
        let isWin: Bool
        if match.format == .doubles {
            let outcome = match.doublesOutcome
            title = "Doubles with \(match.partner?.name ?? "")"
            names = "vs " + others.filter { $0.team != match.viewer.team }.map(\.name)
                .formatted(.list(type: .and))
            verdict = ["Won", "Lost", "Tied"][outcome.rawValue]
            isWin = outcome == .won
        } else {
            let place = match.viewerRow?.place ?? 0
            title = match.format.title
            names = others.map(\.name).joined(separator: ", ")
            verdict = "\(GroupMatchPresentation.placeText(place)) of \(match.seats.count)"
            isWin = place == 1
        }
        let detail = [weekText(match), names].compactMap { $0 }.joined(separator: " · ")
        // The chevron tells these rows from the record rows above, which don't open.
        let chevron = DisclosureChevron()
        return NavigationLink(value: CompetitionHomeRoute.competition(match.id)) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    labels(title, detail)
                    Spacer(minLength: 8)
                    Text(verdict).bold().foregroundStyle(isWin ? Theme.you : Theme.ink).fixedSize()
                    chevron
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        labels(title, detail)
                        Text(verdict).bold().foregroundStyle(isWin ? Theme.you : Theme.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    chevron
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(CompetitionRowButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(detail), \(verdict)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens this match")
        .accessibilityIdentifier("competition.group.record.week.\(match.id.rawValue.uuidString.lowercased())")
    }

    private func weekText(_ match: GroupMatchPresentation) -> String? {
        guard let schedule = match.schedule,
              let bounds = competitionScheduleBoundaries(schedule),
              let zone = TimeZone(identifier: schedule.calendar.timeZoneIdentifier)
        else { return nil }
        return competitionWeekText(
            bounds.start, bounds.end.addingTimeInterval(-1), now: now, locale: locale, timeZone: zone
        )
    }
}

private extension GroupMatchPresentation {
    enum DoublesOutcome: Int { case won, lost, tied }

    var viewerRow: GroupMatchStandingRow? {
        standingRows.first { $0.subject == viewerSubject }
    }

    var startDate: Date {
        schedule.flatMap { competitionScheduleBoundaries($0)?.start } ?? .distantPast
    }

    var partner: GroupMatchSeat? {
        seats.first { $0.id != viewerSeatID && $0.team == viewer.team }
    }

    /// From the server's places: both teams first is a tie.
    var doublesOutcome: DoublesOutcome {
        guard viewerRow?.place == 1 else { return .lost }
        return standingRows.filter { $0.place == 1 }.count > 1 ? .tied : .won
    }
}

private extension GroupMatchSeat {
    enum Partner: Hashable {
        case person(UUID)
        case bot(BotMode)
    }

    var partnerKey: Partner {
        switch occupant {
        case let .person(profileID, _): .person(profileID)
        case let .bot(mode): .bot(mode)
        }
    }
}

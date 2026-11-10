import ComposableArchitecture
import SwiftUI

/// A group match you were named in: the full lineup before you answer.
struct GroupMatchInviteView: View {
    let match: GroupMatchPresentation
    let store: StoreOf<GroupMatchFeature>

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @State private var confirmsDecline = false

    var body: some View {
        GroupMatchPage {
            Text("\(host) challenged you")
                .font(.themeLabel)
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Theme.secondary)
            GroupMatchHeading(match.format.title, detail: detail)
            VStack(alignment: .leading, spacing: 16) {
                GroupMatchLineupPanels(match: match, identifier: "competition.group.invite.seat", title: "WHO’S IN")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("competition.group.invite.lineup")
            Text("Everyone in the match sees each other’s name, photo and daily rings.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            if store.failed.contains(.accept(match.id)) || store.failed.contains(.decline(match.id)) {
                GroupMatchErrorLine("Couldn’t complete that. Check your connection and try again.")
            }
            Button {
                store.send(.commandTapped(.accept(match.id)))
            } label: {
                BusyLabel("Accept", isBusy: store.inFlight.contains(.accept(match.id)))
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isAnswering)
            .accessibilityIdentifier("competition.group.invite.accept")
            Button("Not Now") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("competition.group.invite.not-now")
            Button(role: .destructive) {
                confirmsDecline = true
            } label: {
                BusyLabel("Decline", isBusy: store.inFlight.contains(.decline(match.id)))
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(isAnswering)
            .accessibilityIdentifier("competition.group.invite.decline")
        }
        .navigationTitle("Challenge")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Decline this match?", isPresented: $confirmsDecline, titleVisibility: .visible) {
            Button("Decline Match", role: .destructive) {
                store.send(.commandTapped(.decline(match.id)))
            }
            .accessibilityIdentifier("competition.group.invite.decline.confirm")
            Button("Keep Challenge", role: .cancel) {}
        } message: {
            Text("It won’t start for anyone.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.group.invite")
    }

    private var host: String {
        match.seats.first { $0.number == 1 }?.name ?? ""
    }

    private var isAnswering: Bool {
        store.inFlight.contains(.accept(match.id)) || store.inFlight.contains(.decline(match.id))
    }

    private var detail: String {
        let format = match.format == .doubles
            ? "Seven days, two teams of two."
            : "Seven days, every player for themselves."
        let start = "Day 1 is the day after everyone accepts."
        guard case let .pending(_, createdAt, expiresAt?) = match.lifecycle else { return "\(format) \(start)" }
        // An invite lasts days, so its creation is close enough to now for the format.
        let moment = competitionMomentText(expiresAt, now: createdAt, locale: locale, timeZone: timeZone)
        return "\(format) \(start) Answer by \(moment)."
    }
}

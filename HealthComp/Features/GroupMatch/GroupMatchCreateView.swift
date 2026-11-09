import ComposableArchitecture
import SwiftUI

/// Stub: filled by the Create screen PR.
struct GroupMatchCreateView: View {
    enum Step: Equatable {
        case format, lineup(GroupMatchFormat), bots
    }

    let step: Step
    let store: StoreOf<GroupMatchFeature>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch step {
                case .format:
                    if GroupMatchRollout.showsFormatPicker {
                        Button("Duel") {}.accessibilityIdentifier("competition.group.format.duel")
                        ForEach(GroupMatchFormat.allCases, id: \.self) { format in
                            Button(format.title) {}
                                .accessibilityIdentifier("competition.group.format.\(format.rawValue)")
                        }
                    }
                    Button("Choose Players") {}.accessibilityIdentifier("competition.group.choose-players")
                case let .lineup(format):
                    ForEach(1...format.seatCount, id: \.self) { seat in
                        Text("Seat \(seat)").accessibilityIdentifier("competition.group.seat.\(seat)")
                        Button("Remove Seat \(seat)") {}
                            .accessibilityIdentifier("competition.group.seat.\(seat).remove")
                    }
                    Button("Add Sam") {}
                        .accessibilityIdentifier("competition.group.person.\(GroupMatchFixtures.samProfile.uuidString.lowercased()).add")
                    Button("Add Bot") {}.accessibilityIdentifier("competition.group.add-bot")
                    Button("Paste Link") {}.accessibilityIdentifier("competition.group.paste-link")
                    Button("Create Match") {}.accessibilityIdentifier("competition.group.create")
                case .bots:
                    ForEach(GroupMatchBotMode.allCases, id: \.self) { mode in
                        Button(mode.name) {}.accessibilityIdentifier("competition.group.bot.\(mode.rawValue)")
                    }
                    Button("Add Bot") {}.accessibilityIdentifier("competition.group.bot.add")
                }
            }
            .padding()
        }
        .background(Theme.ground)
    }
}

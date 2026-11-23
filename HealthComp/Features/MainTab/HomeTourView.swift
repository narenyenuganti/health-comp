import CompetitionCore
import SwiftUI

struct HomeTourView: View {
    enum Step: Int, CaseIterable {
        case rings, match, challenge, friends, history, account

        var title: String {
            switch self {
            case .rings: "The logo is a button"
            case .match: "This is a match"
            case .challenge: "Start a match"
            case .friends: "Find your friends"
            case .history: "Every result is kept"
            case .account: "This is you"
            }
        }

        var detail: String {
            switch self {
            case .rings: "It refreshes your scores and shows today’s rings."
            case .match: "Seven days, most points wins. Amber is always you. Tap a match to see each day."
            case .challenge: "Share your link, pick a friend, or practice against a bot."
            case .friends: "Search by name or username. Friends are one tap to challenge."
            case .history: "Your record against each person, and who holds the belt."
            case .account: "Your challenge link, notifications and privacy. Replay this tour here any time."
            }
        }

        var prompt: String {
            switch self {
            case .rings: "Tap the logo"
            case .match: "Tap the match"
            case .challenge: "Tap +"
            case .friends: "Tap Friends"
            case .history: "Tap History"
            case .account: "Tap your photo"
            }
        }
    }

    let name: String
    let finish: () -> Void

    @State private var step = Step.rings
    @State private var match: LocalCompetitionPresentation
    @State private var isLogoUpdating = false
    @State private var isRingsPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(name: String, finish: @escaping () -> Void) {
        self.name = name
        self.finish = finish
        _match = State(initialValue: HomeTourSample.match(name: name))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Button { tapped(.match) } label: {
                        CompetitionHeroCard(competition: match, source: .remoteParticipants)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CompetitionPressButtonStyle())
                    .accessibilityIdentifier("tour.match")
                    .tourTarget(.match, step: step, outset: 10)

                    Button { tapped(.history) } label: { historyRow }
                        .buttonStyle(CompetitionPressButtonStyle())
                        .accessibilityIdentifier("tour.history")
                        .tourTarget(.history, step: step)

                    Text("Sample match. Yours will show here.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .onChange(of: step) { _, step in
                withAnimation(reduceMotion ? nil : Motion.fade) { proxy.scrollTo(step, anchor: .center) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { bar }
        .safeAreaInset(edge: .bottom, spacing: 0) { coach }
        .background(Theme.ground)
        .sheet(isPresented: $isRingsPresented, onDismiss: advance) {
            CompetitionTodayRingsSheet(competitions: [match], activity: nil, loadActivity: {})
        }
        .sensoryFeedback(.selection, trigger: step)
        .environment(\.openCompetitionProfile, nil)
        .interactiveDismissDisabled()
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Button { tapped(.rings) } label: {
                BrandMark(spins: isLogoUpdating).frame(height: 26)
            }
            .accessibilityLabel("Today’s rings")
            .accessibilityIdentifier("tour.logo")
            .tourTarget(.rings, step: step, outset: 8)
            Spacer()
            CompetitionChallengeButton { tapped(.challenge) }
                .accessibilityIdentifier("tour.challenge")
                .tourTarget(.challenge, step: step, isRound: true)
            FriendsToolbarButton(requestCount: 0) { tapped(.friends) }
                .accessibilityIdentifier("tour.friends")
                .tourTarget(.friends, step: step, isRound: true)
            Button { tapped(.account) } label: {
                PersonAvatar(name: name, size: 34, isYou: true, initialFont: .headline.width(.condensed))
            }
            .accessibilityLabel("Account")
            .accessibilityIdentifier("tour.account")
            .tourTarget(.account, step: step, isRound: true)
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Theme.ground)
    }

    private var historyRow: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("History")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text("Alex \(competitionRecordText(wins: 2, losses: 1, ties: 0))")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            DisclosureChevron()
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .themePanel()
        .contentShape(Rectangle())
    }

    private var coach: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("TOUR · \(step.rawValue + 1) OF \(Step.allCases.count)")
                    .themeLabel()
                Spacer(minLength: 8)
                Button("Skip", action: finish)
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
                    .padding(.vertical, -12)
                    .accessibilityIdentifier("tour.skip")
            }
            .foregroundStyle(Theme.onInk.opacity(0.7))
            Text(step.title)
                .font(.title2.weight(.heavy).width(.condensed))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("tour.title")
            Text(step.detail)
                .font(.subheadline)
                .foregroundStyle(Theme.onInk.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Label(step.prompt, systemImage: "hand.tap.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
        }
        .foregroundStyle(Theme.onInk)
        .buttonStyle(.plain)
        .padding(18)
        .frame(maxWidth: 480, alignment: .leading)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .moving(Motion.fade, value: step)
    }

    private func tapped(_ target: Step) {
        guard target == step else { return }
        guard target == .rings else { return advance() }
        guard !isLogoUpdating else { return }
        isLogoUpdating = true
        Task {
            try? await Task.sleep(for: .seconds(0.75))
            isLogoUpdating = false
            isRingsPresented = true
        }
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        } else {
            finish()
        }
    }
}

private struct HomeTourTarget: ViewModifier {
    let isOn: Bool
    let isRound: Bool
    let outset: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(isOn ? 1 : 0.3)
            .overlay {
                if isOn {
                    HomeTourPulse(isRound: isRound)
                        .padding(-outset)
                        .transition(.opacity)
                }
            }
            .moving(Motion.settle, value: isOn)
    }
}

private struct HomeTourPulse: View {
    let isRound: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFaded = false

    var body: some View {
        RoundedRectangle(cornerRadius: isRound ? 100 : 20)
            .strokeBorder(Theme.ink, lineWidth: 2)
            .opacity(isFaded ? 0.2 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever()) { isFaded = true }
            }
    }
}

private extension View {
    func tourTarget(
        _ target: HomeTourView.Step,
        step: HomeTourView.Step,
        isRound: Bool = false,
        outset: CGFloat = 5
    ) -> some View {
        modifier(HomeTourTarget(isOn: target == step, isRound: isRound, outset: outset))
            .id(target)
    }
}

enum HomeTourSample {
    static func match(name: String, now: Date = .now) -> LocalCompetitionPresentation {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let zone = calendar.timeZone.identifier
        let scores: [(you: Double, them: Double)] = [(412, 430), (455, 401), (380, 350), (199, 172)]
        let days = (0..<7).compactMap { index -> LocalCompetitionDayPresentation? in
            guard let date = calendar.date(byAdding: .day, value: index - 3, to: now) else { return nil }
            let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
            guard let era = parts.era, let year = parts.year, let month = parts.month, let day = parts.day,
                  let competitionDay = try? CompetitionDay(
                      era: era, year: year, month: month, day: day, timeZoneIdentifier: zone
                  )
            else { return nil }
            let score = index < scores.count ? scores[index] : nil
            return LocalCompetitionDayPresentation(
                day: competitionDay,
                ordinal: index + 1,
                ownerAcceptedPoints: score?.you,
                ownerLatestAvailability: score == nil ? .notYetOccurred : .observed,
                opponentRevealedPoints: score?.them,
                ownerAcceptedSnapshot: index == 3 ? todaySnapshot : nil,
                ownerLatestSnapshot: index == 3 ? todaySnapshot : nil
            )
        }
        return LocalCompetitionPresentation(
            id: CompetitionID(UUID()),
            ownerDisplayName: name,
            opponentDisplayName: "Alex",
            opponentIdentity: "tour:alex",
            lifecycle: .active(dayOrdinal: 4),
            acceptedConfiguration: nil,
            userPoints: scores.map(\.you).reduce(0, +),
            opponentPoints: scores.map(\.them).reduce(0, +),
            days: days,
            currentDayOrdinal: 4,
            lastRefresh: nil,
            tally: nil,
            terminalResult: nil,
            evaluatedAt: now,
            timeZoneIdentifier: zone,
            lastSuccessfulFullWindowRefreshAt: now
        )
    }

    private static var todaySnapshot: ActivitySnapshot? {
        guard let move = try? ActivityRingReading(value: 310, goal: 500),
              let exercise = try? ActivityRingReading(value: 21, goal: 30),
              let stand = try? ActivityRingReading(value: 8, goal: 12)
        else { return nil }
        return ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: move,
            exercise: exercise,
            standOrRoll: stand,
            pauseState: .running
        )
    }
}

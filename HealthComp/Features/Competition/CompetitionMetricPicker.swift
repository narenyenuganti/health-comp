import CompetitionCore
import SwiftUI

extension CompetitionMetric {
    var color: Color {
        switch self {
        case .move: Theme.move
        case .exercise: Theme.exercise
        case .stand: Theme.stand
        case .sleep: Theme.sleep
        }
    }

    var rateLabel: String {
        self == .sleep ? "100/nt" : "200/day"
    }
}

extension CompetitionMetrics {
    var listText: String {
        let names = orderedMetrics.map(\.title)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " & " + names[names.count - 1]
        }
    }

    var badgeText: String {
        if self == .all { return "RINGS + SLEEP" }
        let items = orderedMetrics
        if items.count == 1 { return "\(items[0].shortTitle) ONLY" }
        return items.map(\.shortTitle).joined(separator: " · ")
    }

    var spokenSummary: String {
        "\(listText), up to \(Int(dailyMaximum)) points a day"
    }
}

struct CompetitionMetricPicker: View {
    @Binding var selection: CompetitionMetrics
    var requestSleepAccess: (() -> Void)? = nil

    @AppStorage(SleepBeta.introSeenKey) private var sleepIntroSeen = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsSleepPriming = false
    @State private var showsMinWarning = false
    @State private var errorPulse = 0

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    private var headerLeading: some View {
        SectionLabel("METRICS · \(selection.count) OF 4")
            .fixedSize(horizontal: false, vertical: true)
    }

    private var headerTrailing: some View {
        Text("\(Int(selection.dailyMaximum)) PTS/DAY")
            .themeLabel()
            .foregroundStyle(Theme.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    headerLeading
                    Spacer(minLength: 8)
                    headerTrailing
                }
                VStack(alignment: .leading, spacing: 2) {
                    headerLeading
                    headerTrailing
                }
            }
            .padding(.horizontal, 2)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(CompetitionMetric.allCases) { metric in
                    tile(metric)
                }
            }
            .sensoryFeedback(.selection, trigger: selection)
            .sensoryFeedback(.error, trigger: errorPulse)

            if showsMinWarning {
                Text("Pick at least 1 metric for the match.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.you)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .transition(Motion.appear)
                    .accessibilityIdentifier("competition.metrics.min-warning")
            } else if selection.includesSleep {
                Text("Beta. Players need Sleep in Apple Health, from an Apple Watch or Oura Ring. A night with nothing there scores 0.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .transition(Motion.appear)
                    .accessibilityIdentifier("competition.metrics.sleep-note")
            }
        }
        .moving(Motion.settle, value: selection)
        .moving(Motion.settle, value: showsMinWarning)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.metrics.picker")
        .sheet(isPresented: $showsSleepPriming) {
            SleepPrimingSheet {
                sleepIntroSeen = true
                showsSleepPriming = false
                requestSleepAccess?()
                if let next = selection.toggling(.sleep) {
                    selection = next
                }
                showsMinWarning = false
            } notNow: {
                showsSleepPriming = false
            }
        }
    }

    private func tile(_ metric: CompetitionMetric) -> some View {
        let isSelected = selection.contains(metric)
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        return Button {
            if metric == .sleep, !isSelected, !sleepIntroSeen, requestSleepAccess != nil {
                showsSleepPriming = true
                return
            }
            if let next = selection.toggling(metric) {
                selection = next
                showsMinWarning = false
            } else {
                showsMinWarning = true
                errorPulse += 1
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    Group {
                        if isSelected {
                            SlantedBar().fill(metric.color)
                        } else {
                            SlantedBar().stroke(Theme.outline, lineWidth: 1.5)
                        }
                    }
                    .frame(width: 22, height: 6)
                    Spacer(minLength: 4)
                    Text(metric.rateLabel)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    HStack(spacing: 5) {
                        Text(metric.title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.ink)
                        if metric.isBeta {
                            Text("BETA")
                                .font(.caption2.weight(.bold).width(.condensed))
                                .tracking(0.6)
                                .foregroundStyle(Theme.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.control, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.ink)
                        .opacity(isSelected ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(Theme.panel, in: shape)
            .overlay {
                shape.strokeBorder(isSelected ? Theme.ink : Theme.panel, lineWidth: 2)
                    .animation(Motion.fade, value: isSelected)
            }
            .contentShape(shape)
        }
        .buttonStyle(CompetitionPressButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title)\(metric.isBeta ? ", Beta" : ""), up to \(Int(metric.maximumDailyPoints)) points")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("competition.metrics.tile.\(metric.rawValue)")
    }
}

struct CompetitionMetricBadge: View {
    let metrics: CompetitionMetrics

    var body: some View {
        if !metrics.isDefaultRings {
            HStack(spacing: 5) {
                HStack(spacing: 2) {
                    ForEach(metrics.orderedMetrics) { metric in
                        SlantedBar()
                            .fill(metric.color)
                            .frame(width: 4, height: 9)
                    }
                }
                .accessibilityHidden(true)
                Text(metrics.badgeText)
                    .font(.caption2.weight(.bold).width(.condensed))
                    .tracking(0.9)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(metrics.spokenSummary)
            .accessibilityIdentifier("competition.metrics.badge")
        }
    }
}

struct CompetitionMetricTagStrip: View {
    let metrics: CompetitionMetrics

    var body: some View {
        if !metrics.isDefaultRings {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionLabel("METRICS IN THIS MATCH")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text("\(Int(metrics.dailyMaximum))/DAY")
                            .themeLabel()
                            .foregroundStyle(Theme.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        SectionLabel("METRICS IN THIS MATCH")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(Int(metrics.dailyMaximum))/DAY")
                            .themeLabel()
                            .foregroundStyle(Theme.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(metrics.orderedMetrics) { metric in
                        HStack(spacing: 6) {
                            SlantedBar()
                                .fill(metric.color)
                                .frame(width: 5, height: 10)
                            Text(metric.title)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.ink)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Metrics in this match: \(metrics.spokenSummary)")
            .accessibilityIdentifier("competition.metrics.strip")
        }
    }
}

struct SleepPrimingSheet: View {
    let proceed: () -> Void
    let notNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "bed.double.fill")
                .font(.largeTitle)
                .foregroundStyle(Theme.sleep)
                .accessibilityHidden(true)
            Text("Your sleep, scored")
                .font(.title2.weight(.heavy).width(.condensed))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("HealthComp reads when and how long you slept from Apple Health, from an Apple Watch or Oura Ring. Only each night’s points leave your iPhone.")
                .font(.body)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Continue", action: proceed)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("account.sleep.continue")
            Button("Not Now", action: notNow)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(24)
        .background(Theme.ground)
        .presentationDetents([.medium])
    }
}

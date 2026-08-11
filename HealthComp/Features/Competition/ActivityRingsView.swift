import CompetitionCore
import HealthKit
import HealthKitUI
import SwiftUI

struct ActivityRingsView: View {
    let snapshot: ActivitySnapshot
    var ownerDisplayName = LocalCompetitionIdentity.ownerDisplayName
    var acceptedPoints: Double?
    var animatesChanges = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if let content = ActivityRingContent(snapshot: snapshot),
               let summary = content.makeHealthKitSummary() {
                ringLayout {
                    SystemActivityRingView(
                        activitySummary: summary,
                        animated: animatesChanges && !reduceMotion
                    )
                    .frame(width: 96, height: 96)
                    .padding(8)
                    .background(
                        Color.black,
                        in: RoundedRectangle(
                            cornerRadius: 24,
                            style: .continuous
                        )
                    )
                    .frame(
                        maxWidth: dynamicTypeSize.isAccessibilitySize
                            ? .infinity
                            : nil
                    )
                    .accessibilityHidden(true)
                    ringText(content)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("competition.ownerRings")
                .accessibilityLabel(
                    activityRingAccessibilityLabel(
                        snapshot,
                        ownerDisplayName: ownerDisplayName,
                        acceptedPoints: acceptedPoints
                    )
                )
            } else {
                activityTextFallback
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("competition.ownerActivityText")
                    .accessibilityLabel(
                        activityRingAccessibilityLabel(
                            snapshot,
                            ownerDisplayName: ownerDisplayName,
                            acceptedPoints: acceptedPoints
                        )
                    )
            }
        }
    }

    private var ringLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 18))
    }

    private func ringText(_ content: ActivityRingContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ActivityValueRow(
                title: content.moveTitle,
                value: content.moveValueText,
                percent: content.movePercentText,
                tint: .pink
            )
            ActivityValueRow(
                title: "Exercise",
                value: content.exerciseValueText,
                percent: content.exercisePercentText,
                tint: .green
            )
            ActivityValueRow(
                title: content.standTitle,
                value: content.standValueText,
                percent: content.standPercentText,
                tint: .cyan
            )
            pauseText
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activityTextFallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Activity details", systemImage: "figure.walk.motion")
                .font(.headline)
            fallbackRow(title: moveTitle, reading: snapshot.move, unit: moveUnit)
            fallbackRow(
                title: "Exercise",
                reading: snapshot.exercise,
                unit: "minutes"
            )
            fallbackRow(
                title: standTitle,
                reading: snapshot.standOrRoll,
                unit: "hours"
            )
            pauseText
            Text("System Activity rings are unavailable for this summary.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fallbackRow(
        title: String,
        reading: ActivityRingReading,
        unit: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(activityReadingText(reading, unit: unit))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var pauseText: some View {
        Text(activityPauseText(snapshot.pauseState))
            .font(.caption.weight(.medium))
            .foregroundStyle(snapshot.pauseState == .paused ? .orange : .secondary)
    }

    private var moveTitle: String {
        snapshot.moveMode == .moveMinutes ? "Move Time" : "Move"
    }

    private var moveUnit: String {
        snapshot.moveMode == .moveMinutes ? "minutes" : "kilocalories"
    }

    private var standTitle: String {
        switch snapshot.standMode {
        case .standHours: "Stand"
        case .rollHours: "Roll"
        case .unknown: "Stand or Roll"
        }
    }
}

private struct ActivityValueRow: View {
    let title: String
    let value: String
    let percent: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(value)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(percent)
                .font(.caption.weight(.semibold).monospacedDigit())
        }
    }
}

private struct SystemActivityRingView: UIViewRepresentable {
    let activitySummary: HKActivitySummary
    let animated: Bool

    func makeUIView(context: Context) -> HKActivityRingView {
        let view = HKActivityRingView(frame: .zero)
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: HKActivityRingView, context: Context) {
        uiView.setActivitySummary(activitySummary, animated: animated)
    }
}

private struct ActivityRingContent {
    let snapshot: ActivitySnapshot
    let moveValue: Double
    let moveGoal: Double
    let exerciseValue: Double
    let exerciseGoal: Double
    let standValue: Double
    let standGoal: Double

    init?(snapshot: ActivitySnapshot) {
        guard let moveValue = snapshot.move.value,
              let moveGoal = snapshot.move.goal,
              let exerciseValue = snapshot.exercise.value,
              let exerciseGoal = snapshot.exercise.goal,
              let standValue = snapshot.standOrRoll.value,
              let standGoal = snapshot.standOrRoll.goal,
              [moveValue, moveGoal, exerciseValue, exerciseGoal, standValue, standGoal]
                .allSatisfy({ $0.isFinite && $0 >= 0 }),
              moveGoal > 0,
              exerciseGoal > 0,
              standGoal > 0
        else {
            return nil
        }
        self.snapshot = snapshot
        self.moveValue = moveValue
        self.moveGoal = moveGoal
        self.exerciseValue = exerciseValue
        self.exerciseGoal = exerciseGoal
        self.standValue = standValue
        self.standGoal = standGoal
    }

    func makeHealthKitSummary() -> HKActivitySummary? {
        let summary = HKActivitySummary()
        switch snapshot.moveMode {
        case .activeEnergyKilocalories:
            summary.activityMoveMode = .activeEnergy
            summary.activeEnergyBurned = HKQuantity(
                unit: .kilocalorie(),
                doubleValue: moveValue
            )
            summary.activeEnergyBurnedGoal = HKQuantity(
                unit: .kilocalorie(),
                doubleValue: moveGoal
            )
        case .moveMinutes:
            summary.activityMoveMode = .appleMoveTime
            summary.appleMoveTime = HKQuantity(
                unit: .minute(),
                doubleValue: moveValue
            )
            summary.appleMoveTimeGoal = HKQuantity(
                unit: .minute(),
                doubleValue: moveGoal
            )
        }
        summary.appleExerciseTime = HKQuantity(
            unit: .minute(),
            doubleValue: exerciseValue
        )
        summary.exerciseTimeGoal = HKQuantity(
            unit: .minute(),
            doubleValue: exerciseGoal
        )
        summary.appleStandHours = HKQuantity(
            unit: .count(),
            doubleValue: standValue
        )
        summary.standHoursGoal = HKQuantity(
            unit: .count(),
            doubleValue: standGoal
        )
        if #available(iOS 18.0, *), snapshot.pauseState != .unknown {
            summary.isPaused = snapshot.pauseState == .paused
        }
        return summary
    }

    var moveTitle: String {
        snapshot.moveMode == .moveMinutes ? "Move Time" : "Move"
    }

    var standTitle: String {
        switch snapshot.standMode {
        case .standHours: "Stand"
        case .rollHours: "Roll"
        case .unknown: "Stand or Roll"
        }
    }

    var moveValueText: String {
        let unit = snapshot.moveMode == .moveMinutes ? "minutes" : "kilocalories"
        return "\(activityNumber(moveValue)) of \(activityNumber(moveGoal)) \(unit)"
    }

    var exerciseValueText: String {
        "\(activityNumber(exerciseValue)) of \(activityNumber(exerciseGoal)) minutes"
    }

    var standValueText: String {
        "\(activityNumber(standValue)) of \(activityNumber(standGoal)) hours"
    }

    var movePercentText: String { activityPercent(moveValue, goal: moveGoal) }
    var exercisePercentText: String {
        activityPercent(exerciseValue, goal: exerciseGoal)
    }
    var standPercentText: String { activityPercent(standValue, goal: standGoal) }

    func accessibilityLabel(
        ownerDisplayName: String,
        acceptedPoints: Double?
    ) -> String {
        [
            "\(ownerDisplayName) activity",
            acceptedPoints.map(activityAcceptedPointsText),
            "\(moveTitle), \(moveValueText), \(movePercentText)",
            "Exercise, \(exerciseValueText), \(exercisePercentText)",
            "\(standTitle), \(standValueText), \(standPercentText)",
            activityPauseText(snapshot.pauseState),
        ].compactMap { $0 }.joined(separator: ". ")
    }
}

func activityRingSupportsSystemPresentation(_ snapshot: ActivitySnapshot) -> Bool {
    ActivityRingContent(snapshot: snapshot) != nil
}

func activityRingAccessibilityLabel(
    _ snapshot: ActivitySnapshot,
    ownerDisplayName: String,
    acceptedPoints: Double?
) -> String {
    if let content = ActivityRingContent(snapshot: snapshot) {
        return content.accessibilityLabel(
            ownerDisplayName: ownerDisplayName,
            acceptedPoints: acceptedPoints
        )
    }

    let moveTitle = snapshot.moveMode == .moveMinutes ? "Move Time" : "Move"
    let moveUnit = snapshot.moveMode == .moveMinutes ? "minutes" : "kilocalories"
    let standTitle: String = switch snapshot.standMode {
    case .standHours: "Stand"
    case .rollHours: "Roll"
    case .unknown: "Stand or Roll"
    }
    return [
        "\(ownerDisplayName) activity",
        acceptedPoints.map(activityAcceptedPointsText),
        "\(moveTitle), \(activityReadingText(snapshot.move, unit: moveUnit))",
        "Exercise, \(activityReadingText(snapshot.exercise, unit: "minutes"))",
        "\(standTitle), \(activityReadingText(snapshot.standOrRoll, unit: "hours"))",
        activityPauseText(snapshot.pauseState),
        "System Activity rings unavailable",
    ].compactMap { $0 }.joined(separator: ". ")
}

private func activityAcceptedPointsText(_ points: Double) -> String {
    "\(competitionPointsText(points)) accepted \(points == 1 ? "point" : "points")"
}

private func activityNumber(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...1)))
}

private func activityPercent(_ value: Double, goal: Double) -> String {
    let percentage = value / goal * 100
    return "\(percentage.formatted(.number.precision(.fractionLength(0)))) percent"
}

private func activityReadingText(
    _ reading: ActivityRingReading,
    unit: String
) -> String {
    guard let value = reading.value, let goal = reading.goal, goal > 0 else {
        return "value or goal unavailable"
    }
    return "\(activityNumber(value)) of \(activityNumber(goal)) \(unit), \(activityPercent(value, goal: goal))"
}

private func activityPauseText(_ state: ActivityPauseState) -> String {
    switch state {
    case .running: "Activity tracking running"
    case .paused: "Activity tracking paused"
    case .unknown: "Activity tracking pause status unknown"
    }
}

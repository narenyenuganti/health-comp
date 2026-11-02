import ActivityKit
import SwiftUI
import WidgetKit

/// The final-day Live Activity on the Lock Screen and in the Dynamic Island.
/// All data arrives as `ContentState`: no network, HealthKit or App Group.
struct MatchLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MatchActivityAttributes.self) { context in
            MatchActivityLockScreenView(
                attributes: context.attributes,
                state: context.state.resolved(isStale: context.isStale)
            )
            .activityBackgroundTint(Theme.ground)
            .activitySystemActionForegroundColor(Theme.ink)
            .widgetURL(context.attributes.url)
        } dynamicIsland: { context in
            let state = context.state.resolved(isStale: context.isStale)
            // Dark in every region, so amber stays you on black.
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MatchActivityScoreColumn(side: .you, state: state, size: 34)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                        .padding(.horizontal, 8)
                        .environment(\.colorScheme, .dark)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    MatchActivityScoreColumn(side: .them, state: state, size: 34)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                        .padding(.horizontal, 8)
                        .environment(\.colorScheme, .dark)
                }
                DynamicIslandExpandedRegion(.center) {
                    MatchActivityIslandHeader(attributes: context.attributes, state: state)
                        .environment(\.colorScheme, .dark)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    MatchActivityBottomRows(state: state)
                        .padding(.horizontal, 8)
                        .environment(\.colorScheme, .dark)
                }
            } compactLeading: {
                MatchActivityCompactScore(side: .you, state: state)
                    .environment(\.colorScheme, .dark)
            } compactTrailing: {
                MatchActivityCompactScore(side: .them, state: state)
                    .environment(\.colorScheme, .dark)
            } minimal: {
                MatchActivityMinimalLead(state: state)
                    .environment(\.colorScheme, .dark)
            }
            .widgetURL(context.attributes.url)
        }
    }
}

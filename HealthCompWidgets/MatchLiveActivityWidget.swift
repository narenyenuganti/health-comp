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
                    MatchActivityScoreColumn(side: .you, state: state, size: matchActivityIslandScoreSize)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                        .padding(.horizontal, 8)
                        .matchActivityIsland()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    MatchActivityScoreColumn(side: .them, state: state, size: matchActivityIslandScoreSize)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                        .padding(.horizontal, 8)
                        .matchActivityIsland()
                }
                DynamicIslandExpandedRegion(.center) {
                    MatchActivityIslandHeader(attributes: context.attributes, state: state)
                        .matchActivityIsland()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    MatchActivityIslandBottom(state: state)
                        .padding(.horizontal, 8)
                        .matchActivityIsland()
                }
            } compactLeading: {
                MatchActivityCompactScore(side: .you, state: state)
                    .matchActivityIsland()
            } compactTrailing: {
                MatchActivityCompactScore(side: .them, state: state)
                    .matchActivityIsland()
            } minimal: {
                MatchActivityMinimalLead(state: state)
                    .matchActivityIsland()
            }
            .widgetURL(context.attributes.url)
        }
    }
}

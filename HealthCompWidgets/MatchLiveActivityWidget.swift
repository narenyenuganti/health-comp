import ActivityKit
import SwiftUI
import WidgetKit

/// The final-day Live Activity on the Lock Screen and in the Dynamic Island.
/// All data arrives as `ContentState`: no network, HealthKit or App Group.
struct MatchLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MatchActivityAttributes.self) { context in
            let state = context.state.resolved(isStale: context.isStale)
            Group {
                if #available(iOS 18.0, *) {
                    MatchActivityFamilyView(attributes: context.attributes, state: state)
                } else {
                    MatchActivityLockScreenView(attributes: context.attributes, state: state)
                        .activityBackgroundTint(Theme.ground)
                }
            }
            .activitySystemActionForegroundColor(Theme.ink)
            .widgetURL(context.attributes.url)
        } dynamicIsland: { context in
            let state = context.state.resolved(isStale: context.isStale)
            // Dark in every region, so amber stays you on black.
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MatchActivityScoreColumn(side: .you, attributes: context.attributes, state: state, size: matchActivityIslandScoreSize)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                        .padding(.horizontal, 8)
                        .matchActivityIsland()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    MatchActivityScoreColumn(side: .them, attributes: context.attributes, state: state, size: matchActivityIslandScoreSize)
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
                MatchActivityCompactScore(side: .you, attributes: context.attributes, state: state)
                    .matchActivityIsland()
            } compactTrailing: {
                MatchActivityCompactScore(side: .them, attributes: context.attributes, state: state)
                    .matchActivityIsland()
            } minimal: {
                MatchActivityMinimalLead(attributes: context.attributes, state: state)
                    .matchActivityIsland()
            }
            .widgetURL(context.attributes.url)
        }
        .smallActivityFamily()
    }
}

/// The Smart Stack and CarPlay card, or the Lock Screen card. `activityFamily`
/// stays here: MatchActivityViews.swift has no WidgetKit context.
@available(iOS 18.0, *)
private struct MatchActivityFamilyView: View {
    let attributes: MatchActivityAttributes
    let state: MatchActivityAttributes.ContentState

    @Environment(\.activityFamily) private var family

    var body: some View {
        if family == .small {
            // Dark like the island, so amber stays you on black.
            MatchActivitySmallView(attributes: attributes, state: state)
                .matchActivityIsland()
                .activityBackgroundTint(.black)
        } else {
            MatchActivityLockScreenView(attributes: attributes, state: state)
                .activityBackgroundTint(Theme.ground)
        }
    }
}

private extension WidgetConfiguration {
    func smallActivityFamily() -> some WidgetConfiguration {
        if #available(iOS 18.0, *) {
            return supplementalActivityFamilies([.small])
        } else {
            return self
        }
    }
}

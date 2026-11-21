import ActivityKit
import SwiftUI
import WidgetKit

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

@available(iOS 18.0, *)
private struct MatchActivityFamilyView: View {
    let attributes: MatchActivityAttributes
    let state: MatchActivityAttributes.ContentState

    @Environment(\.activityFamily) private var family

    var body: some View {
        if family == .small {
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

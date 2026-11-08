import SwiftUI

@main
struct HealthCompWatchApp: App {
    /// A background wake may never build the scene, so the session starts here.
    init() {
        _ = WatchSnapshotModel.shared
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: .shared)
#if DEBUG
                // What wrist-down redaction leaves, for captures.
                .redacted(reason: ProcessInfo.processInfo.arguments.contains("--watch-redacted") ? .privacy : [])
#endif
        }
        .backgroundTask(.watchConnectivity) {
            await WatchSnapshotModel.shared.finishDelivery()
        }
    }
}

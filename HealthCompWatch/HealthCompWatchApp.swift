import SwiftUI

@main
struct HealthCompWatchApp: App {
    init() {
        _ = WatchSnapshotModel.shared
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: .shared)
#if DEBUG
                .redacted(reason: ProcessInfo.processInfo.arguments.contains("--watch-redacted") ? .privacy : [])
#endif
        }
        .backgroundTask(.watchConnectivity) {
            await WatchSnapshotModel.shared.finishDelivery()
        }
    }
}

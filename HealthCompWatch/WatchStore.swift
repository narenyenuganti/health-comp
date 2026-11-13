import Foundation
import UserNotifications
import WatchConnectivity
import WidgetKit

/// The last snapshot from the iPhone, kept in this watch's App Group so the
/// complication can read it. The group is per device, not shared with the phone.
@MainActor
final class WatchSnapshotModel: NSObject, ObservableObject, WCSessionDelegate, UNUserNotificationCenterDelegate {
    static let shared = WatchSnapshotModel()

    @Published private(set) var snapshot: CompetitionWidgetSnapshot?
    @Published private(set) var seen = CompetitionWatchSeen()
    /// The match of the alert just tapped on this watch, until the root opens it.
    @Published var tappedAlert: UUID?

    private let fileURL = CompetitionWidgetSnapshot.fileURL()
    private let seenURL = URL.applicationSupportDirectory.appendingPathComponent("WatchSeen.json")
    private var isFixture = false

    override init() {
        super.init()
        // Here, at launch, so a tap that launches the app isn't missed.
        UNUserNotificationCenter.current().delegate = self
        snapshot = .load(from: fileURL)
        if let data = try? Data(contentsOf: seenURL),
           let seen = try? JSONDecoder().decode(CompetitionWatchSeen.self, from: data) {
            self.seen = seen
        }
#if DEBUG
        // Deterministic UI tests and captures: no phone, no WatchConnectivity.
        let arguments = ProcessInfo.processInfo.arguments
        if let scenario = zip(arguments, arguments.dropFirst()).first(where: { $0.0 == "--watch-scenario" })?.1 {
            isFixture = true
            // An alert tap, as the delegate would report it.
            if let id = zip(arguments, arguments.dropFirst()).first(where: { $0.0 == "--watch-alert" })?.1 {
                tappedAlert = UUID(uuidString: id)
            }
            seen = CompetitionWatchSeen()
            try? FileManager.default.removeItem(at: seenURL)
            if let fixture = CompetitionWidgetSnapshot.testLab(scenario, now: Date(), scheme: "healthcomp"),
               let data = try? JSONEncoder().encode(fixture) {
                _ = write(data)
                snapshot = fixture
            } else {
                removeFile()
                snapshot = nil
            }
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
#endif
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Delivery to a suspended app stalled in the spike, so a look re-checks.
    func refresh() {
        guard !isFixture, WCSession.default.activationState == .activated else { return }
        if let payload = CompetitionWatchPayload(WCSession.default.receivedApplicationContext) {
            apply(payload)
        }
    }

    /// The system's wake for pending data. `hasContentPending` going false
    /// doesn't prove a delegate's hop to this actor ran, so this applies the
    /// context itself before the app can suspend.
    func finishDelivery() async {
        let deadline = Date().addingTimeInterval(5)
        while WCSession.default.hasContentPending, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        refresh()
    }

    func markSeen(_ id: UUID) {
        seen.finals.insert(id)
        saveSeen()
    }

    private func apply(_ payload: CompetitionWatchPayload) {
        switch payload.action(after: seen.sentAt) {
        case .ignore:
            return
        case .clear:
            removeFile()
            snapshot = nil
            seen = CompetitionWatchSeen(sentAt: payload.sentAt)
            saveSeen()
            WidgetCenter.shared.reloadAllTimelines()
        case let .store(next):
            // `sentAt` waits for the write, so a failed one retries.
            guard let data = payload.snapshot, write(data) else { return }
            let material = next.ignoringUpdatedAt != snapshot?.ignoringUpdatedAt
            snapshot = next
            seen.sentAt = payload.sentAt
            seen.prune(keeping: next)
            saveSeen()
            if material { WidgetCenter.shared.reloadAllTimelines() }
        }
    }

    private func write(_ data: Data) -> Bool {
        guard var url = fileURL else { return false }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    private func removeFile() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func saveSeen() {
        var url = seenURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(seen).write(to: url, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            // ponytail: a failed save replays a reveal once; nothing is lost
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// A mirrored iPhone alert tapped on the watch launches this app and lands
    /// here. No `willPresent`: alerts stay silent while the app is in front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = CompetitionWatchAlert.competitionID(response.notification.request.content.userInfo)
        else { return }
        await MainActor.run { tappedAlert = id }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {
        deliver(CompetitionWatchPayload(session.receivedApplicationContext))
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        deliver(CompetitionWatchPayload(context))
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        deliver(CompetitionWatchPayload(userInfo))
    }

    private nonisolated func deliver(_ payload: CompetitionWatchPayload?) {
        guard let payload else { return }
        Task { @MainActor in self.apply(payload) }
    }
}

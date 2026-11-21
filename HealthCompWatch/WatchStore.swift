import Combine
import Foundation
import Observation
import OSLog
import UserNotifications
import WatchConnectivity
import WidgetKit

@MainActor
@Observable
final class WatchSnapshotModel: NSObject, WCSessionDelegate, UNUserNotificationCenterDelegate {
    static let shared = WatchSnapshotModel()

    private(set) var snapshot: CompetitionWidgetSnapshot?
    private(set) var seen = CompetitionWatchSeen()
    var tappedAlert: UUID?

    @ObservationIgnored private let fileURL = CompetitionWidgetSnapshot.fileURL()
    @ObservationIgnored private let seenURL = URL.applicationSupportDirectory.appending(path: "WatchSeen.json")
    @ObservationIgnored private let logger = Logger(subsystem: "com.narenyenuganti.HealthComp.watchkitapp", category: "WatchStore")
    @ObservationIgnored private var isFixture = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        snapshot = .load(from: fileURL)
        if let data = try? Data(contentsOf: seenURL),
           let seen = try? JSONDecoder().decode(CompetitionWatchSeen.self, from: data) {
            self.seen = seen
        }
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let scenario = zip(arguments, arguments.dropFirst()).first(where: { $0.0 == "--watch-scenario" })?.1 {
            isFixture = true
            if let id = zip(arguments, arguments.dropFirst()).first(where: { $0.0 == "--watch-alert" })?.1 {
                tappedAlert = UUID(uuidString: id)
            }
            seen = CompetitionWatchSeen()
            try? FileManager.default.removeItem(at: seenURL)
            if let fixture = CompetitionWidgetSnapshot.testLab(scenario, now: .now, scheme: "healthcomp"),
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

    func refresh() {
        guard !isFixture, WCSession.default.activationState == .activated else { return }
        if let payload = CompetitionWatchPayload(WCSession.default.receivedApplicationContext) {
            apply(payload)
        }
    }

    func finishDelivery() async {
        let deadline = Date.now.addingTimeInterval(5)
        while WCSession.default.hasContentPending, Date.now < deadline {
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
            logger.error("Failed to save watch seen state: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = CompetitionWatchAlert.competitionID(response.notification.request.content.userInfo)
        else { return }
        await MainActor.run { tappedAlert = id }
    }

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

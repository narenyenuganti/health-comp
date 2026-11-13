import Foundation
import WatchConnectivity

/// Hands the widget snapshot to the paired Watch. Application context keeps
/// only the latest value, which is all a scoreboard needs; the file is the
/// source of truth, so there is no queue of unsent snapshots.
final class CompetitionWatchSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = CompetitionWatchSync()
    /// HealthKit wakes spend about 50 transfers a day fast, and evening is
    /// when scores matter.
    static let complicationTransferSpacing: TimeInterval = 30 * 60

    /// Serial, so a slow re-read can't get a newer `sentAt` than a later mirror.
    private let queue = DispatchQueue(label: "CompetitionWatchSync")
    private var lastComplicationTransfer: Date?

    func activate() {
        guard WCSession.isSupported() else { return }  // iPad
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Nil clears the watch.
    func mirror(_ snapshot: CompetitionWidgetSnapshot?, material: Bool) {
        guard WCSession.isSupported() else { return }
        queue.async { self.send(snapshot, material: material) }
    }

    static func spendsComplicationTransfer(isClear: Bool, last: Date?, now: Date) -> Bool {
        isClear || last.map { now.timeIntervalSince($0) >= complicationTransferSpacing } ?? true
    }

    private func send(_ snapshot: CompetitionWidgetSnapshot?, material: Bool) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let now = Date()
        let payload = CompetitionWatchPayload(snapshot: snapshot, sentAt: now.timeIntervalSince1970).dictionary
        try? session.updateApplicationContext(payload)
        if material,
           session.isComplicationEnabled,
           session.remainingComplicationUserInfoTransfers > 0,
           Self.spendsComplicationTransfer(isClear: snapshot == nil, last: lastComplicationTransfer, now: now) {
            session.transferCurrentComplicationUserInfo(payload)
            // A clear (every signed-out launch) must not hold back the first
            // real snapshot after sign-in.
            lastComplicationTransfer = snapshot == nil ? nil : now
        }
    }

    /// Covers a relaunch with unchanged data, a clear that raced activation
    /// and a watch app installed late. A file that exists but won't load
    /// (locked, corrupt, another version) sends nothing rather than a wipe.
    private func resend() {
        queue.async {
            guard let url = CompetitionWidgetSnapshot.fileURL() else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                // Material: a sign-out clear may never have reached the face.
                self.send(nil, material: true)
            } else if let snapshot = CompetitionWidgetSnapshot.load(from: url) {
                self.send(snapshot, material: false)
            }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        resend()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        resend()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The person switched watches: the new one needs its own session.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}

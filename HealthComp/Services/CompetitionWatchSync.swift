import Foundation
import WatchConnectivity

final class CompetitionWatchSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = CompetitionWatchSync()
    static let complicationTransferSpacing: TimeInterval = 30 * 60

    private let queue = DispatchQueue(label: "CompetitionWatchSync")
    private var lastComplicationTransfer: Date?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

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
            lastComplicationTransfer = snapshot == nil ? nil : now
        }
    }

    private func resend() {
        queue.async {
            guard let url = CompetitionWidgetSnapshot.fileURL() else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
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

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}

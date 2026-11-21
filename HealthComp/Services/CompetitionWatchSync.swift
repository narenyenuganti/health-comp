import Foundation
import WatchConnectivity

private actor CompetitionWatchSyncTransfer {
    private var lastComplicationTransfer: Date?

    func send(_ snapshot: CompetitionWidgetSnapshot?, material: Bool) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let now = Date.now
        let payload = CompetitionWatchPayload(snapshot: snapshot, sentAt: now.timeIntervalSince1970).dictionary
        try? session.updateApplicationContext(payload)
        if material,
           session.isComplicationEnabled,
           session.remainingComplicationUserInfoTransfers > 0,
           CompetitionWatchSync.spendsComplicationTransfer(
               isClear: snapshot == nil,
               last: lastComplicationTransfer,
               now: now
           ) {
            session.transferCurrentComplicationUserInfo(payload)
            lastComplicationTransfer = snapshot == nil ? nil : now
        }
    }

    func resend() {
        guard let url = CompetitionWidgetSnapshot.fileURL() else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            send(nil, material: true)
        } else if let snapshot = CompetitionWidgetSnapshot.load(from: url) {
            send(snapshot, material: false)
        }
    }
}

final class CompetitionWatchSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = CompetitionWatchSync()
    static let complicationTransferSpacing: TimeInterval = 30 * 60

    private let transfer = CompetitionWatchSyncTransfer()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func mirror(_ snapshot: CompetitionWidgetSnapshot?, material: Bool) {
        guard WCSession.isSupported() else { return }
        Task { await transfer.send(snapshot, material: material) }
    }

    static func spendsComplicationTransfer(isClear: Bool, last: Date?, now: Date) -> Bool {
        isClear || last.map { now.timeIntervalSince($0) >= complicationTransferSpacing } ?? true
    }

    private func resend() {
        Task { await transfer.resend() }
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

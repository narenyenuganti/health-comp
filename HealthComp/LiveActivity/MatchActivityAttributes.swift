import ActivityKit
import Foundation

struct MatchActivityAttributes: ActivityAttributes, Hashable {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable { case live, pending }

        var phase: Phase
        var title: String
        var timing: String?
        var opponentName: String
        var userPoints: Double
        var opponentPoints: Double
        var freshness: String?

        func resolved(isStale: Bool) -> Self {
            guard isStale, phase == .live else { return self }
            var pending = self
            pending.phase = .pending
            pending.title = MatchActivityCopy.pending
            pending.timing = nil
            return pending
        }
    }

    var matchID: String
    var endsAt: Date
    var url: URL
}

enum MatchActivityCopy {
    static let pending = "Final score pending"
}

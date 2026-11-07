import ActivityKit
import Foundation

/// The final-day Live Activity. Points, names and display strings only, no
/// Health values. The system may mirror it to a paired Watch.
struct MatchActivityAttributes: ActivityAttributes, Hashable {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable { case live, pending }

        var phase: Phase
        /// "Last day" or "Final score pending", from the shared formatter.
        var title: String
        /// "Ends at midnight" or "Ends at midnight PST"; nil when pending.
        var timing: String?
        /// Refreshed on every update, so a rename or "Former competitor" shows.
        var opponentName: String
        var userPoints: Double
        var opponentPoints: Double
        /// `competitionFreshnessText`, so the card claims no more than Home.
        var freshness: String?

        /// A live card past its stale date reads as pending without an app run.
        func resolved(isStale: Bool) -> Self {
            guard isStale, phase == .live else { return self }
            var pending = self
            pending.phase = .pending
            pending.title = MatchActivityCopy.pending
            pending.timing = nil
            return pending
        }
    }

    /// Lowercased match uuid.
    var matchID: String
    /// Match-local midnight after Day 7.
    var endsAt: Date
    var url: URL
}

enum MatchActivityCopy {
    /// Pinned to the formatter's tallying title by a unit test.
    static let pending = "Final score pending"
}

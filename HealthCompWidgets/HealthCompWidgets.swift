import AppIntents
import SwiftUI
import WidgetKit

// The extension only reads the app's snapshot file: no network, no HealthKit.

@main
struct HealthCompWidgetBundle: WidgetBundle {
    var body: some Widget {
        CompetitionMatchWidget()
        MatchLiveActivityWidget()
    }
}

struct CompetitionMatchWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "CompetitionMatchWidget",
            intent: CompetitionWidgetIntent.self,
            provider: CompetitionWidgetProvider()
        ) { entry in
            CompetitionMatchWidgetView(entry: entry)
        }
        .configurationDisplayName("Match")
        .description("The score of your match.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

// MARK: Person picker

/// Someone you have a live, scheduled or recent match with. No directory and
/// no lookup: the people come from the snapshot.
struct CompetitionPersonEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Person"
    static var defaultQuery = CompetitionPersonQuery()

    /// The snapshot's `personID`, or `soonestID`.
    let id: String
    let name: String

    /// "Ending soonest": nobody picked. Listed first, so a pick can be undone.
    static let soonestID = "soonest"
    static let soonest = CompetitionPersonEntity(id: soonestID, name: "Ending soonest")

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct CompetitionPersonQuery: EntityQuery {
    /// Every id gets an entity, so WidgetKit never drops a stored person and
    /// silently falls back to the default match.
    func entities(for identifiers: [String]) async throws -> [CompetitionPersonEntity] {
        let snapshot = CompetitionWidgetSnapshot.load(from: CompetitionWidgetSnapshot.fileURL())
        return identifiers.map {
            $0 == CompetitionPersonEntity.soonestID ? .soonest
                : CompetitionPersonEntity(id: $0, name: snapshot?.name(for: $0) ?? "The other person")
        }
    }

    func suggestedEntities() async throws -> [CompetitionPersonEntity] {
        let snapshot = CompetitionWidgetSnapshot.load(from: CompetitionWidgetSnapshot.fileURL())
        return [.soonest] + (snapshot?.suggestedPeople() ?? []).map {
            CompetitionPersonEntity(id: $0.id, name: $0.name)
        }
    }

    func defaultResult() async -> CompetitionPersonEntity? { .soonest }
}

struct CompetitionWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Match"
    static var description = IntentDescription(
        "Shows the match ending soonest, or your match with the person you pick."
    )

    @Parameter(title: "Person")
    var person: CompetitionPersonEntity?

    /// Nil for "Ending soonest".
    var personID: String? {
        person.flatMap { $0.id == CompetitionPersonEntity.soonestID ? nil : $0.id }
    }
}

// MARK: Timeline

struct CompetitionWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: CompetitionWidgetSnapshot?
    /// No name here: the view looks the person up in `snapshot`.
    let personID: String?

    static func sample(_ date: Date) -> Self {
        // never tapped: placeholder and gallery entries aren't interactive
        Self(
            date: date,
            snapshot: .sample(now: date, url: URL(fileURLWithPath: "/")),
            personID: nil
        )
    }
}

struct CompetitionWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CompetitionWidgetEntry {
        .sample(Date())
    }

    func snapshot(for configuration: CompetitionWidgetIntent, in context: Context) async -> CompetitionWidgetEntry {
        guard !context.isPreview else { return .sample(Date()) }
        return CompetitionWidgetEntry(
            date: Date(),
            snapshot: CompetitionWidgetSnapshot.load(from: CompetitionWidgetSnapshot.fileURL()),
            personID: configuration.personID
        )
    }

    /// Now, plus one entry at each day start, end and result leaving, so the
    /// widget moves on at the match calendar's midnight without the app.
    func timeline(for configuration: CompetitionWidgetIntent, in context: Context) async -> Timeline<CompetitionWidgetEntry> {
        let now = Date()
        let snapshot = CompetitionWidgetSnapshot.load(from: CompetitionWidgetSnapshot.fileURL())
        let boundaries = snapshot?.timelineDates(after: now) ?? []
        let entries = ([now] + boundaries).map {
            CompetitionWidgetEntry(date: $0, snapshot: snapshot, personID: configuration.personID)
        }
        return Timeline(entries: entries, policy: boundaries.isEmpty ? .never : .atEnd)
    }
}

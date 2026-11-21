import AppIntents
import SwiftUI
import WidgetKit

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

struct CompetitionPersonEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Person"
    static var defaultQuery = CompetitionPersonQuery()

    let id: String
    let name: String

    static let soonestID = "soonest"
    static let soonest = CompetitionPersonEntity(id: soonestID, name: "Ending soonest")

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct CompetitionPersonQuery: EntityQuery {
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

    var personID: String? {
        person.flatMap { $0.id == CompetitionPersonEntity.soonestID ? nil : $0.id }
    }
}

struct CompetitionWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: CompetitionWidgetSnapshot?
    let personID: String?

    static func sample(_ date: Date) -> Self {
        Self(
            date: date,
            snapshot: .sample(now: date, url: URL(fileURLWithPath: "/")),
            personID: nil
        )
    }
}

struct CompetitionWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CompetitionWidgetEntry {
        .sample(Date.now)
    }

    func snapshot(for configuration: CompetitionWidgetIntent, in context: Context) async -> CompetitionWidgetEntry {
        guard !context.isPreview else { return .sample(Date.now) }
        return CompetitionWidgetEntry(
            date: Date.now,
            snapshot: CompetitionWidgetSnapshot.load(from: CompetitionWidgetSnapshot.fileURL()),
            personID: configuration.personID
        )
    }

    func timeline(for configuration: CompetitionWidgetIntent, in context: Context) async -> Timeline<CompetitionWidgetEntry> {
        let now = Date.now
        let snapshot = CompetitionWidgetSnapshot.load(from: CompetitionWidgetSnapshot.fileURL())
        let boundaries = snapshot?.timelineDates(after: now) ?? []
        let entries = ([now] + boundaries).map {
            CompetitionWidgetEntry(date: $0, snapshot: snapshot, personID: configuration.personID)
        }
        return Timeline(entries: entries, policy: boundaries.isEmpty ? .never : .atEnd)
    }
}

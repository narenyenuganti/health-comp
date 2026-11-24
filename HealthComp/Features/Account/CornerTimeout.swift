import CompetitionCore
import SwiftUI

enum CornerTimeoutPreset: String, CaseIterable, Identifiable, Sendable {
    case forToday
    case untilMonday
    case untilNextMonth
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forToday: "For Today"
        case .untilMonday: "Until Monday"
        case .untilNextMonth: "Until Next Month"
        case .custom: "Custom Date"
        }
    }

    func endDate(from now: Date, calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .forToday:
            return calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        case .untilMonday:
            let weekday = calendar.component(.weekday, from: startOfToday)
            let daysUntilMonday = weekday == 2 ? 7 : ((9 - weekday) % 7)
            return calendar.date(byAdding: .day, value: max(1, daysUntilMonday), to: startOfToday) ?? now
        case .untilNextMonth:
            let comps = calendar.dateComponents([.year, .month], from: startOfToday)
            guard let first = calendar.date(from: comps),
                  let next = calendar.date(byAdding: .month, value: 1, to: first)
            else { return startOfToday }
            return next
        case .custom:
            return calendar.date(byAdding: .day, value: 7, to: startOfToday) ?? now
        }
    }
}

enum CornerTimeoutStorage {
    static let untilKey = "healthcomp.cornerTimeoutUntil"
    static let maxDays = 90

    static func currentUntil(defaults: UserDefaults = .standard) -> Date? {
        let raw = defaults.double(forKey: untilKey)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    static func setUntil(_ date: Date?, defaults: UserDefaults = .standard) {
        if let date {
            defaults.set(date.timeIntervalSince1970, forKey: untilKey)
        } else {
            defaults.removeObject(forKey: untilKey)
        }
    }

    static func isActive(at now: Date, until: Date?) -> Bool {
        guard let until else { return false }
        return until > now
    }

    static func summaryText(
        until: Date?,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let until, until > now else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        if let tomorrow, until <= tomorrow {
            return "Resting today"
        }
        let dateText = competitionFormattedDate(until, template: "EEEMMMd", locale: locale, timeZone: timeZone)
        return "Resting until \(dateText)"
    }
}

struct CompetitionPausedRingsBanner: View {
    var opponentName: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RINGS PAUSED IN APPLE FITNESS")
                .themeLabel(tracking: 1.0)
                .foregroundStyle(Theme.youFill)
            Text("Today scores 0 while paused")
                .font(.headline)
                .foregroundStyle(Theme.onInk)
            Text(
                opponentName.map {
                    "Automated nudges with \($0) are held until your rings resume."
                } ?? "Automated nudges are held until your rings resume."
            )
            .font(.subheadline)
            .foregroundStyle(Theme.onInk.opacity(0.78))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("competition.paused.banner")
    }
}

struct AccountCornerTimeoutPage: View {
    @AppStorage(CornerTimeoutStorage.untilKey) private var untilTimestamp: Double = 0
    @State private var customDate: Date = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    private var untilDate: Date? {
        untilTimestamp > 0 ? Date(timeIntervalSince1970: untilTimestamp) : nil
    }

    private var isActive: Bool {
        CornerTimeoutStorage.isActive(at: .now, until: untilDate)
    }

    private var maxDate: Date {
        Calendar.current.date(byAdding: .day, value: CornerTimeoutStorage.maxDays, to: .now) ?? .now
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isActive ? "Corner Timeout Active" : "Take a Rest Window")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text(
                        CornerTimeoutStorage.summaryText(
                            until: untilDate, now: .now, locale: locale, timeZone: timeZone
                        ) ?? "Hold automated nudges and pause new rematch prompts while you recover or travel. Resume anytime."
                    )
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Theme.panel)

            Section {
                ForEach([CornerTimeoutPreset.forToday, .untilMonday, .untilNextMonth]) { preset in
                    let target = preset.endDate(from: .now)
                    let selected = isActive && untilDate.map { abs($0.timeIntervalSince(target)) < 3_600 } == true
                    Button {
                        untilTimestamp = target.timeIntervalSince1970
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                Text(competitionFormattedDate(target, template: "EEEMMMd", locale: locale, timeZone: timeZone))
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(Theme.you)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("account.corner-timeout.\(preset.rawValue)")
                }

                DatePicker(
                    "Custom (up to 90 days)",
                    selection: $customDate,
                    in: Date.now...maxDate,
                    displayedComponents: .date
                )
                .tint(Theme.youFill)
                .onChange(of: customDate) { _, next in
                    untilTimestamp = next.timeIntervalSince1970
                }
                .accessibilityIdentifier("account.corner-timeout.custom")
            } header: {
                SectionLabel("PRESETS")
            }
            .listRowBackground(Theme.panel)

            if isActive {
                Section {
                    Button("Resume Anytime") {
                        untilTimestamp = 0
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("account.corner-timeout.resume")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .navigationTitle("Corner Timeout")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("account.corner-timeout.page")
    }
}

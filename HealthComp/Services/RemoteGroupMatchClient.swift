import CompetitionCore
import CryptoKit
import Foundation

/// One group match as `list_group_matches` returns it, validated. The server
/// owns the match; the phone keeps this read model and its own uploads.
struct GroupMatchReadModel: Codable, Equatable, Sendable {
    /// A person's accepted head for one day.
    struct Day: Codable, Equatable, Sendable {
        let ordinal: Int
        let clientRevision: Int64
        let serverSequence: Int64
        /// Nil when the day is unavailable (`availabilityReason` says why).
        let centipoints: Int?
        let availabilityReason: String
        let wireContentSHA256: String
        let ringBasisPoints: [Int]?
    }

    struct Seat: Codable, Equatable, Sendable {
        let id: UUID
        let index: Int
        let team: Int?
        /// Nil for a bot.
        let profileID: UUID?
        let displayName: String?
        /// pending, accepted, declined or anonymized; nil for a bot.
        let state: String?
        let leftAt: Date?
        let frozenThroughDay: Int?
        let botMode: BotMode?
        let botSeed: UInt64?
        /// Whole points, fixed when the last person accepts.
        let botDailyTotals: [Int]?
        let days: [Day]
    }

    struct Attestation: Codable, Equatable, Sendable {
        let version: Int64
        let basis: CompetitionAttestationBasis
        let acceptedRevisions: [Int64]
        let windowCommitmentSHA256: String
        let serverSequence: Int64
    }

    struct Standing: Codable, Equatable, Sendable {
        /// A seat id, or a team number in doubles.
        let subject: String
        let place: Int
        let centipoints: Int
    }

    /// One seat's frozen week in the result: points, or why a day has none.
    struct FrozenSeat: Codable, Equatable, Sendable {
        struct Day: Codable, Equatable, Sendable {
            let ordinal: Int
            /// available, unavailable or afterLeave.
            let status: String
            let centipoints: Int?
            let reason: String?
        }

        let seatIndex: Int
        let totalCentipoints: Int
        let days: [Day]
    }

    struct Result: Codable, Equatable, Sendable {
        let basis: CompetitionAttestationBasis
        let completedAt: Date
        let standings: [Standing]
        /// Nil until the server sends `result.seats` (version 1).
        var seats: [FrozenSeat]? = nil
    }

    let id: UUID
    let format: GroupMatchFormat
    /// Rejects a refresh older than what is cached.
    let serverVersion: UInt64
    let creatorProfileID: UUID
    let lifecycle: String
    let timeZoneIdentifier: String
    let startDay: String?
    let invitationExpiresAt: Date?
    let bestAvailableDeadline: Date?
    let closedAt: Date?
    let seats: [Seat]
    let ownerRevisionHighWater: Int64
    let ownerAttestation: Attestation?
    let result: Result?
}

extension GroupMatchFormat: Codable {}

// MARK: - Wire

enum GroupMatchWire {
    private static let matchKeys: Set<String> = [
        "version", "competition_id", "format", "server_version", "creator_profile_id", "lifecycle",
        "time_zone_identifier", "start_day", "scoring_policy_identity", "invitation_expires_at",
        "best_available_deadline", "closed_by_profile_id", "closed_at", "seats", "owner", "reactions", "result",
    ]
    private static let seatKeys: Set<String> = [
        "id", "seat_index", "team_number", "kind", "profile_id", "display_name", "can_view_photo", "state",
        "left_at", "frozen_through_day", "frozen_revisions", "attestation_basis", "bot_mode", "bot_seed",
        "bot_baseline", "bot_generator_version", "bot_daily_totals", "days",
    ]
    /// `daily_score_revisions` columns, as `002_privacy_columns` pins them.
    private static let dayKeys: Set<String> = [
        "id", "competition_id", "participant_profile_id", "day_ordinal", "semantic_event_id", "client_revision",
        "move_mode", "stand_mode", "move_basis_points", "exercise_basis_points", "stand_basis_points",
        "accepted_centi_points", "availability_reason", "scoring_policy_identity", "wire_digest_version",
        "wire_content_sha256", "server_seq", "evaluated_at", "received_at",
    ]
    private static let attestationKeys: Set<String> = [
        "id", "competition_id", "participant_profile_id", "basis", "window_commitment_sha256",
        "accepted_revisions", "server_seq", "attested_at", "semantic_event_id", "attestation_version",
    ]
    private static let reactionKeys: Set<String> = [
        "competition_id", "author_profile_id", "target_profile_id", "day_ordinal", "reaction", "created_at", "updated_at",
    ]
    private static let resultKeys: Set<String> = [
        "competition_id", "format", "finalization_basis", "completed_at", "standings", "immutable_hash", "server_seq",
    ]
    private static let lifecycles: Set<String> = [
        "pending", "scheduled", "active", "ends_today", "tallying", "completed", "archived",
        "declined", "expired", "cancelled",
    ]

    /// Exactly `{version: 1, matches}`. Any unreadable part rejects the whole
    /// response, so a partial read never replaces the cache.
    static func decodeList(_ data: Data, viewer: UUID) throws -> [GroupMatchReadModel] {
        do {
            let top = try WireObject(try JSONSerialization.jsonObject(with: data), keys: ["version", "matches"])
            guard try top.int("version") == 1 else { throw CompetitionRemoteFailure.serverContractMismatch }
            let matches = try top.array("matches").map { try match($0, viewer: viewer) }
            guard Set(matches.map(\.id)).count == matches.count else {
                throw CompetitionRemoteFailure.serverContractMismatch
            }
            return matches
        } catch {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
    }

    private static func match(_ value: Any, viewer: UUID) throws -> GroupMatchReadModel {
        let object = try WireObject(value, keys: matchKeys)
        let id = try object.uuid("competition_id")
        guard try object.int("version") == 1,
              let format = try formatValue(object.string("format")),
              try object.string("scoring_policy_identity") == RemoteScoringWireV1.policyIdentity,
              case let lifecycle = try object.string("lifecycle"), lifecycles.contains(lifecycle),
              case let timeZone = try object.string("time_zone_identifier"), TimeZone(identifier: timeZone) != nil
        else { throw CompetitionRemoteFailure.serverContractMismatch }
        let startDay = try object.optional("start_day") { try object.string($0) }
        if let startDay, startDay.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
        _ = try object.optional("closed_by_profile_id") { try object.uuid($0) }
        let seats = try object.array("seats").map { try seat($0, matchID: id, format: format) }
        let profiles = seats.compactMap(\.profileID)
        guard seats.map(\.index) == Array(1...format.seatCount),
              Set(seats.map(\.id)).count == seats.count, Set(profiles).count == profiles.count
        else { throw CompetitionRemoteFailure.serverContractMismatch }
        let owner = try WireObject(object.values["owner"], keys: ["profile_id", "revision_high_water", "attestation"])
        guard try owner.uuid("profile_id") == viewer,
              seats.contains(where: { $0.profileID == viewer })
        else { throw CompetitionRemoteFailure.serverContractMismatch }
        let attestation = try owner.optional("attestation") { try self.attestation(owner.values[$0], matchID: id, viewer: viewer) }
        for reaction in try object.array("reactions") {
            let row = try WireObject(reaction, keys: reactionKeys)
            guard try row.uuid("competition_id") == id,
                  CompetitionReactionKind(rawValue: try row.string("reaction")) != nil
            else { throw CompetitionRemoteFailure.serverContractMismatch }
            _ = try row.uuid("author_profile_id")
            _ = try row.optional("target_profile_id") { try row.uuid($0) }
            _ = try row.optional("day_ordinal") { try row.int($0) }
            _ = try row.date("created_at")
            _ = try row.date("updated_at")
        }
        return GroupMatchReadModel(
            id: id,
            format: format,
            serverVersion: try object.uint64("server_version"),
            creatorProfileID: try object.uuid("creator_profile_id"),
            lifecycle: lifecycle,
            timeZoneIdentifier: timeZone,
            startDay: startDay,
            invitationExpiresAt: try object.optional("invitation_expires_at") { try object.date($0) },
            bestAvailableDeadline: try object.optional("best_available_deadline") { try object.date($0) },
            closedAt: try object.optional("closed_at") { try object.date($0) },
            seats: seats,
            ownerRevisionHighWater: try owner.int64("revision_high_water"),
            ownerAttestation: attestation,
            result: try object.optional("result") { try result(object.values[$0], matchID: id, format: format) }
        )
    }

    private static func seat(_ value: Any, matchID: UUID, format: GroupMatchFormat) throws -> GroupMatchReadModel.Seat {
        let object = try WireObject(value, keys: seatKeys)
        let kind = try object.string("kind")
        let team = try object.optional("team_number") { try object.int($0) }
        guard (format == .doubles) == (team != nil), team.map({ (1...2).contains($0) }) ?? true,
              kind == "human" || kind == "bot"
        else { throw CompetitionRemoteFailure.serverContractMismatch }
        _ = try object.bool("can_view_photo")
        _ = try object.optional("attestation_basis") { try object.basis($0) }
        _ = try object.optional("bot_baseline") { try object.int($0) }
        _ = try object.optional("bot_generator_version") { try object.int($0) }
        let profileID = try object.optional("profile_id") { try object.uuid($0) }
        let days = try object.array("days").map { try day($0, matchID: matchID, profileID: profileID) }
        guard Set(days.map(\.ordinal)).count == days.count else { throw CompetitionRemoteFailure.serverContractMismatch }
        let frozenRevisions = try object.optional("frozen_revisions") { try object.int64Array($0) }
        let frozenThroughDay = try object.optional("frozen_through_day") { try object.int($0) }
        let leftAt = try object.optional("left_at") { try object.date($0) }
        guard (leftAt == nil) == (frozenThroughDay == nil), (leftAt == nil) == (frozenRevisions == nil),
              frozenRevisions.map({ $0.count == 7 }) ?? true,
              frozenThroughDay.map({ (0...7).contains($0) }) ?? true
        else { throw CompetitionRemoteFailure.serverContractMismatch }
        let state = try object.optional("state") { try object.string($0) }
        let botMode = try object.optional("bot_mode") { key -> BotMode in
            guard let mode = BotMode(rawValue: try object.string(key)) else {
                throw CompetitionRemoteFailure.serverContractMismatch
            }
            return mode
        }
        let botSeed = try object.optional("bot_seed") { key -> UInt64 in
            guard let seed = BotWeek.seed(decimal: try object.string(key)) else {
                throw CompetitionRemoteFailure.serverContractMismatch
            }
            return seed
        }
        let totals = try object.optional("bot_daily_totals") { try object.intArray($0) }
        if kind == "human" {
            guard profileID != nil, botMode == nil, botSeed == nil, totals == nil,
                  let state, ["pending", "accepted", "declined", "anonymized"].contains(state)
            else { throw CompetitionRemoteFailure.serverContractMismatch }
        } else {
            guard profileID == nil, state == nil, leftAt == nil, days.isEmpty, botMode != nil,
                  (botSeed == nil) == (totals == nil),
                  totals.map({ $0.count == 7 && $0.allSatisfy { (0...600).contains($0) } }) ?? true
            else { throw CompetitionRemoteFailure.serverContractMismatch }
        }
        return GroupMatchReadModel.Seat(
            id: try object.uuid("id"),
            index: try object.int("seat_index"),
            team: team,
            profileID: profileID,
            displayName: try object.optional("display_name") { try object.string($0) },
            state: state,
            leftAt: leftAt,
            frozenThroughDay: frozenThroughDay,
            botMode: botMode,
            botSeed: botSeed,
            botDailyTotals: totals,
            days: days.sorted { $0.ordinal < $1.ordinal }
        )
    }

    private static func day(_ value: Any, matchID: UUID, profileID: UUID?) throws -> GroupMatchReadModel.Day {
        let object = try WireObject(value, keys: dayKeys)
        let centipoints = try object.optional("accepted_centi_points") { try object.int($0) }
        let reason = try object.string("availability_reason")
        let ordinal = try object.int("day_ordinal")
        let digest = try object.string("wire_content_sha256")
        let move = try object.optional("move_basis_points") { try object.int($0) }
        let exercise = try object.optional("exercise_basis_points") { try object.int($0) }
        let stand = try object.optional("stand_basis_points") { try object.int($0) }
        guard try object.uuid("competition_id") == matchID,
              try object.uuid("participant_profile_id") == profileID,
              (1...7).contains(ordinal),
              (reason == "available") == (centipoints != nil),
              centipoints.map({ (0...60_000).contains($0) }) ?? true,
              try object.string("scoring_policy_identity") == RemoteScoringWireV1.policyIdentity,
              try object.int("wire_digest_version") == 1,
              isHexDigest(digest)
        else { throw CompetitionRemoteFailure.serverContractMismatch }
        _ = try object.uuid("id")
        _ = try object.uuid("semantic_event_id")
        _ = try object.date("evaluated_at")
        _ = try object.date("received_at")
        let revision = try object.int64("client_revision")
        let sequence = try object.int64("server_seq")
        guard revision > 0, sequence > 0, let profileID else { throw CompetitionRemoteFailure.serverContractMismatch }
        // The row's own fields must hash to its digest: this closes modes,
        // reasons and basis points with the wire's validators.
        let wire = try RemoteScoreRevisionWireV1(
            competitionID: matchID, participantID: profileID, dayOrdinal: ordinal,
            moveMode: try object.string("move_mode"), standMode: try object.string("stand_mode"),
            moveBasisPoints: move, exerciseBasisPoints: exercise, standBasisPoints: stand,
            availabilityReason: reason, scoringPolicyIdentity: RemoteScoringWireV1.policyIdentity,
            clientRevision: revision
        )
        let rings = competitionRingBasisPoints(centipoints, move, exercise, stand)
        guard wire.wireContentSHA256 == digest, wire.acceptedCentiPoints == centipoints,
              (centipoints == nil) == (rings == nil)
        else { throw CompetitionRemoteFailure.serverContractMismatch }
        return GroupMatchReadModel.Day(
            ordinal: ordinal,
            clientRevision: revision,
            serverSequence: sequence,
            centipoints: centipoints,
            availabilityReason: reason,
            wireContentSHA256: digest,
            ringBasisPoints: rings
        )
    }

    private static func attestation(_ value: Any?, matchID: UUID, viewer: UUID) throws -> GroupMatchReadModel.Attestation {
        let object = try WireObject(value, keys: attestationKeys)
        let commitment = try object.string("window_commitment_sha256")
        let revisions = try object.int64Array("accepted_revisions")
        guard try object.uuid("competition_id") == matchID,
              try object.uuid("participant_profile_id") == viewer,
              isHexDigest(commitment), revisions.count == 7
        else { throw CompetitionRemoteFailure.serverContractMismatch }
        _ = try object.uuid("id")
        _ = try object.uuid("semantic_event_id")
        _ = try object.date("attested_at")
        return GroupMatchReadModel.Attestation(
            version: try object.int64("attestation_version"),
            basis: try object.basis("basis"),
            acceptedRevisions: revisions,
            windowCommitmentSHA256: commitment,
            serverSequence: try object.int64("server_seq")
        )
    }

    private static func result(_ value: Any?, matchID: UUID, format: GroupMatchFormat) throws -> GroupMatchReadModel.Result {
        // `version` and `seats` arrive together, or not at all on older servers.
        let hasSeats = (value as? [String: Any])?["seats"] != nil
        let object = try WireObject(value, keys: hasSeats ? resultKeys.union(["version", "seats"]) : resultKeys)
        guard try object.uuid("competition_id") == matchID,
              try formatValue(object.string("format")) == format,
              isHexDigest(try object.string("immutable_hash"))
        else { throw CompetitionRemoteFailure.serverContractMismatch }
        _ = try object.int64("server_seq")
        let standings = try object.array("standings").map { value -> GroupMatchReadModel.Standing in
            let row = try WireObject(value, keys: ["subject", "place", "centipoints"])
            return GroupMatchReadModel.Standing(
                subject: try row.string("subject"),
                place: try row.int("place"),
                centipoints: try row.int("centipoints")
            )
        }
        var seats: [GroupMatchReadModel.FrozenSeat]?
        if hasSeats {
            guard try object.int("version") == 1 else { throw CompetitionRemoteFailure.serverContractMismatch }
            seats = try object.array("seats").map(frozenSeat)
            guard seats?.map(\.seatIndex) == Array(1...format.seatCount) else {
                throw CompetitionRemoteFailure.serverContractMismatch
            }
        }
        return GroupMatchReadModel.Result(
            basis: try object.basis("finalization_basis"),
            completedAt: try object.date("completed_at"),
            standings: standings,
            seats: seats
        )
    }

    private static func frozenSeat(_ value: Any) throws -> GroupMatchReadModel.FrozenSeat {
        let object = try WireObject(value, keys: ["seat_index", "total_centi_points", "days"])
        let days = try object.array("days").map { value -> GroupMatchReadModel.FrozenSeat.Day in
            let day = try WireObject(value, keys: ["ordinal", "status", "centi_points", "reason"])
            let status = try day.string("status")
            let points = try day.optional("centi_points") { Int(try day.int64($0)) }
            let reason = try day.optional("reason") { try day.string($0) }
            switch status {
            case "available":
                guard let points, (0...60_000).contains(points), reason == nil else {
                    throw CompetitionRemoteFailure.serverContractMismatch
                }
            case "unavailable":
                guard points == nil, let reason, reason != "afterLeave" else {
                    throw CompetitionRemoteFailure.serverContractMismatch
                }
            case "afterLeave":
                guard points == nil || points == 0, reason == "afterLeave" else {
                    throw CompetitionRemoteFailure.serverContractMismatch
                }
            default:
                throw CompetitionRemoteFailure.serverContractMismatch
            }
            return .init(ordinal: try day.int("ordinal"), status: status, centipoints: points, reason: reason)
        }
        let total = Int(try object.int64("total_centi_points"))
        guard days.map(\.ordinal) == Array(1...7), (0...420_000).contains(total),
              days.reduce(0, { $0 + ($1.centipoints ?? 0) }) == total
        else {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
        return .init(seatIndex: try object.int("seat_index"), totalCentipoints: total, days: days)
    }

    private static func formatValue(_ value: String) -> GroupMatchFormat? {
        switch value {
        case "three_way": .threeWay
        case "four_way": .fourWay
        case "doubles": .doubles
        default: nil
        }
    }

    /// `leave_group_match`'s answer exactly: the frozen vector and the bank
    /// `private.participant_projection_v2` builds from it.
    static func validateLeave(_ data: Data) throws {
        do {
            let top = try WireObject(
                try JSONSerialization.jsonObject(with: data),
                keys: ["left_at", "frozen_through_day", "accepted_revisions", "bank"]
            )
            _ = try top.date("left_at")
            let revisions = try top.int64Array("accepted_revisions")
            let bank = try WireObject(top.values["bank"], keys: ["profile_id", "total_centi_points", "window_commitment_sha256", "days"])
            _ = try bank.uuid("profile_id")
            let days = try bank.array("days").map {
                try WireObject($0, keys: [
                    "ordinal", "status", "source", "reason", "centi_points", "wire_content_sha256",
                    "client_revision", "server_seq", "scoring_policy_identity",
                ])
            }
            guard (0...7).contains(try top.int("frozen_through_day")),
                  revisions.count == 7, revisions.allSatisfy({ $0 >= 0 }),
                  isHexDigest(try bank.string("window_commitment_sha256")),
                  days.count == 7
            else { throw CompetitionRemoteFailure.serverContractMismatch }
            var total = 0
            for (index, day) in days.enumerated() {
                let points = try day.optional("centi_points", day.int)
                let revision = try day.optional("client_revision", day.int64)
                guard try day.int("ordinal") == index + 1,
                      revision == (revisions[index] == 0 ? nil : revisions[index]),
                      (try day.string("source")) == (revision == nil ? "deadline_missing" : "accepted_revision"),
                      (try day.string("status") == "points") == (points != nil),
                      (0...60_000).contains(points ?? 0)
                else { throw CompetitionRemoteFailure.serverContractMismatch }
                total += points ?? 0
            }
            guard try bank.int("total_centi_points") == total else { throw CompetitionRemoteFailure.serverContractMismatch }
        } catch {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
    }

    static func isHexDigest(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}

/// A JSON object with exactly these keys and typed, throwing reads.
private struct WireObject {
    let values: [String: Any]

    init(_ value: Any?, keys: Set<String>) throws {
        guard let values = value as? [String: Any], Set(values.keys) == keys else {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
        self.values = values
    }

    func optional<Value>(_ key: String, _ read: (String) throws -> Value) throws -> Value? {
        values[key] is NSNull ? nil : try read(key)
    }

    func string(_ key: String) throws -> String {
        guard let value = values[key] as? String else { throw CompetitionRemoteFailure.serverContractMismatch }
        return value
    }

    func bool(_ key: String) throws -> Bool {
        guard let number = values[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
        return number.boolValue
    }

    func uuid(_ key: String) throws -> UUID {
        let value = try string(key)
        guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value else {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
        return id
    }

    func int(_ key: String) throws -> Int { try Self.int(values[key]) }

    func intArray(_ key: String) throws -> [Int] { try array(key).map { try Self.int($0) } }

    /// 64-bit values are decimal strings on the wire, never JSON numbers.
    func int64(_ key: String) throws -> Int64 { try Self.int64(values[key]) }

    func int64Array(_ key: String) throws -> [Int64] { try array(key).map { try Self.int64($0) } }

    func uint64(_ key: String) throws -> UInt64 {
        let value = try string(key)
        guard let number = BotWeek.seed(decimal: value) else { throw CompetitionRemoteFailure.serverContractMismatch }
        return number
    }

    func date(_ key: String) throws -> Date { try CompetitionWireCodec.date(try string(key)) }

    func array(_ key: String) throws -> [Any] {
        guard let value = values[key] as? [Any] else { throw CompetitionRemoteFailure.serverContractMismatch }
        return value
    }

    func basis(_ key: String) throws -> CompetitionAttestationBasis {
        guard let basis = CompetitionAttestationBasis(rawValue: try string(key)) else {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
        return basis
    }

    private static func int(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let int = Int(exactly: number.doubleValue)
        else { throw CompetitionRemoteFailure.serverContractMismatch }
        return int
    }

    private static func int64(_ value: Any?) throws -> Int64 {
        guard let value = value as? String,
              let number = BotWeek.seed(decimal: value),
              let int = Int64(exactly: number)
        else { throw CompetitionRemoteFailure.serverContractMismatch }
        return int
    }
}

// MARK: - Storage

/// Profile-scoped group files: the last good read model (offline display)
/// and one owner-upload document per match. Exact pending requests and
/// attestation receipts live only in the outbox.
actor GroupMatchStore {
    struct OwnerDocument: Codable, Equatable, Sendable {
        var version = 1
        let profileID: UUID
        let competitionID: UUID
        /// The highest revision ever handed out, including spent ones.
        var allocatedRevision: Int64
        /// The newest accepted row per day.
        var accepted: [RemoteAcceptedScoreRow]
    }

    private struct ReadModelDocument: Codable {
        var version = 1
        let profileID: UUID
        let matches: [GroupMatchReadModel]
    }

    private let directory: URL
    private let profileID: UUID

    init(directory: URL, profileID: UUID) {
        self.directory = directory
        self.profileID = profileID
    }

    func readModel() -> [GroupMatchReadModel] {
        guard let document = try? JSONDecoder().decode(ReadModelDocument.self, from: Data(contentsOf: readModelURL)),
              document.version == 1, document.profileID == profileID
        else { return [] }
        return document.matches
    }

    func saveReadModel(_ matches: [GroupMatchReadModel]) throws {
        try write(ReadModelDocument(profileID: profileID, matches: matches), to: readModelURL)
    }

    func owner(_ competitionID: UUID) -> OwnerDocument? {
        guard let document = try? JSONDecoder().decode(OwnerDocument.self, from: Data(contentsOf: ownerURL(competitionID))),
              document.version == 1, document.profileID == profileID, document.competitionID == competitionID
        else { return nil }
        return document
    }

    func ownerIDs() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix("owner-"), name.hasSuffix(".json") else { return nil }
            return UUID(uuidString: String(name.dropFirst(6).dropLast(5)))
        }
    }

    func removeOwner(_ competitionID: UUID) {
        try? FileManager.default.removeItem(at: ownerURL(competitionID))
    }

    /// A known group match: it has an owner document or is in the cache.
    func isGroupMatch(_ competitionID: UUID) -> Bool {
        owner(competitionID) != nil || readModel().contains { $0.id == competitionID }
    }

    /// An outbox entry the group path queued: a score under the group
    /// semantic-id domain, or anything for a known group match.
    func owns(_ entry: CompetitionOutboxEntry) -> Bool {
        if case let .scoreRevision(request) = entry.payload,
           request.semanticEventID == RemoteGroupMatchSync.semanticEventID(wireContentSHA256: request.wireContentSHA256) {
            return true
        }
        return isGroupMatch(entry.payload.competitionID)
    }

    /// Takes the server's heads after a reinstall or another device's upload.
    /// Never moves a day back to an older revision.
    func rehydrate(_ competitionID: UUID, highWater: Int64, rows: [RemoteAcceptedScoreRow]) throws -> OwnerDocument {
        var document = owner(competitionID) ?? OwnerDocument(
            profileID: profileID, competitionID: competitionID, allocatedRevision: 0, accepted: []
        )
        let before = document
        document.allocatedRevision = max(document.allocatedRevision, highWater)
        for row in rows { Self.merge(row, into: &document) }
        if document != before { try write(document, to: ownerURL(competitionID)) }
        return document
    }

    /// Persists the next revision before anything is queued under it, so a
    /// crash leaves a gap and never a reused revision.
    func allocateRevision(_ competitionID: UUID, atLeast floor: Int64) throws -> Int64 {
        var document = owner(competitionID) ?? OwnerDocument(
            profileID: profileID, competitionID: competitionID, allocatedRevision: 0, accepted: []
        )
        let current = max(document.allocatedRevision, floor)
        guard current < Int64.max else { throw RemoteCompetitionRuntimeFailure.serverContractMismatch }
        document.allocatedRevision = current + 1
        try write(document, to: ownerURL(competitionID))
        return current + 1
    }

    /// The accepted-score path for group matches, validated as the duel
    /// journal path validates it. Idempotent, so a replay after a crash is safe.
    func recordAccepted(
        _ request: CompetitionScoreRevisionRequest,
        _ response: CompetitionScoreRevisionResponse
    ) throws {
        guard response.disposition == .appended || response.disposition == .duplicate,
              response.rejectionCode == nil,
              let digest = response.wireContentSHA256, digest == request.wireContentSHA256,
              let serverSequence = response.acceptedServerSequence,
              (request.availabilityReason == "available") == (response.acceptedCentiPoints != nil)
        else { throw CompetitionRemoteFailure.serverContractMismatch }
        let row = try RemoteAcceptedScoreRow(
            ordinal: request.dayOrdinal,
            acceptedCentiPoints: response.acceptedCentiPoints,
            availabilityReason: request.availabilityReason == "available" ? nil : request.availabilityReason,
            wireContentSHA256: digest,
            scoringPolicyIdentity: request.scoringPolicyIdentity,
            clientRevision: request.clientRevision,
            serverSequence: serverSequence,
            ringBasisPoints: competitionRingBasisPoints(
                response.acceptedCentiPoints, request.moveBasisPoints,
                request.exerciseBasisPoints, request.standBasisPoints
            )
        )
        var document = owner(request.competitionID) ?? OwnerDocument(
            profileID: profileID, competitionID: request.competitionID, allocatedRevision: 0, accepted: []
        )
        document.allocatedRevision = max(document.allocatedRevision, request.clientRevision)
        Self.merge(row, into: &document)
        try write(document, to: ownerURL(request.competitionID))
    }

    private static func merge(_ row: RemoteAcceptedScoreRow, into document: inout OwnerDocument) {
        if let existing = document.accepted.first(where: { $0.ordinal == row.ordinal }),
           existing.clientRevision >= row.clientRevision {
            return
        }
        document.accepted.removeAll { $0.ordinal == row.ordinal }
        document.accepted.append(row)
        document.accepted.sort { $0.ordinal < $1.ordinal }
    }

    private var readModelURL: URL { directory.appendingPathComponent("read-model.json") }

    private func ownerURL(_ competitionID: UUID) -> URL {
        directory.appendingPathComponent("owner-\(competitionID.uuidString.lowercased()).json")
    }

    // ponytail: atomic replace without the duel stores' fsync dance; a lost
    // write after a power cut is rebuilt from the server's heads on refresh.
    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(value).write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}

extension CompetitionAcceptedScorePersistence {
    /// Group scores go to their owner document, never the duel journal: a
    /// group request carries the group semantic id, and a known group match
    /// counts too. Everything else is a duel, as before.
    static func routing(groups: GroupMatchStore, duels store: any CompetitionEventStore) -> Self {
        let duels = eventStore(store)
        return Self { profileID, request, response, receivedAt in
            let isKnownGroup = await groups.isGroupMatch(request.competitionID)
            if isKnownGroup
                || request.semanticEventID == RemoteGroupMatchSync.semanticEventID(wireContentSHA256: request.wireContentSHA256) {
                // A missing document is recreated, never sent to the duel journal.
                try await groups.recordAccepted(request, response)
            } else {
                try await duels.persist(profileID, request, response, receivedAt)
            }
        }
    }
}

/// One family's view of the shared outbox, so group and duel uploads drain
/// on their own coordinators: a stalled request or failed write in one
/// never holds up the other. Writes go to the shared store unchanged.
struct GroupOutboxPartition: CompetitionOutboxStore {
    let base: any CompetitionOutboxStore
    let groups: GroupMatchStore
    let holdsGroups: Bool

    func enqueue(_ payload: CompetitionOutboxPayload, enqueuedAt: Date) async throws -> CompetitionOutboxEntry {
        try await base.enqueue(payload, enqueuedAt: enqueuedAt)
    }

    func entries() async throws -> [CompetitionOutboxEntry] {
        var mine: [CompetitionOutboxEntry] = []
        for entry in try await base.entries() where await groups.owns(entry) == holdsGroups {
            mine.append(entry)
        }
        return mine
    }

    func update(
        _ semanticEventID: UUID, expectedGeneration: UInt64, state: CompetitionOutboxState
    ) async throws -> CompetitionOutboxEntry {
        try await base.update(semanticEventID, expectedGeneration: expectedGeneration, state: state)
    }

    func remove(_ semanticEventID: UUID, expectedGeneration: UInt64) async throws {
        try await base.remove(semanticEventID, expectedGeneration: expectedGeneration)
    }
}

// MARK: - Sync

/// One pass over the signed-in person's group matches: refresh the read
/// model, upload their own days, and attest the final window. Never throws;
/// a failure keeps the cache and leaves duels alone.
struct RemoteGroupMatchSync: Sendable {
    let profileID: UUID
    let store: GroupMatchStore
    let remoteAPI: CompetitionRemoteAPI
    let environment: CompetitionEnvironmentClient?
    let outboxStore: (any CompetitionOutboxStore)?
    let syncCoordinator: CompetitionSyncCoordinator?
    let now: @Sendable () -> Date

    func run() async -> [GroupMatchReadModel] {
        await syncCoordinator?.wake()
        let listed = await refresh()
        var matches = listed.matches
        // Uploads need the server's current high-water: a cached one can
        // trail a revision accepted just before a power cut.
        guard listed.isFresh else {
            try? await removeMaterializedAcknowledgments(matches)
            return matches
        }
        var finalWindows: [(id: UUID, readSucceeded: Bool)] = []
        for match in matches {
            guard let window = uploadWindow(match),
                  let end = try? window.calendar.startOfDay(window.calendar.day(after: window.days[6]))
            else { continue }
            var readAt = try? await upload(match, window: window)
            if now() >= end {
                // Only a read that started after the week ended can seal it.
                if let started = readAt, started < end { readAt = try? await upload(match, window: window) }
                finalWindows.append((match.id, readAt.map { $0 >= end } ?? false))
            }
        }
        if !finalWindows.isEmpty, let syncCoordinator {
            // Drain, then refresh the owner heads the attestation is built on.
            await syncCoordinator.waitUntilIdle()
            let refreshed = await refresh()
            matches = refreshed.matches
            for (id, readSucceeded) in finalWindows {
                guard let match = matches.first(where: { $0.id == id }) else { continue }
                try? await attest(match, headsAreFresh: readSucceeded && refreshed.isFresh)
            }
        }
        try? await removeMaterializedAcknowledgments(matches)
        return matches
    }

    /// The server's list, merged over the cache: a match whose version is
    /// older than the cached one keeps the cached copy.
    func refresh() async -> (matches: [GroupMatchReadModel], isFresh: Bool) {
        let cached = await store.readModel()
        guard let fresh = try? await list() else { return (cached, false) }
        var keptCached = false
        let merged = fresh.map { match in
            guard let newer = cached.first(where: { $0.id == match.id && $0.serverVersion > match.serverVersion })
            else { return match }
            keptCached = true
            return newer
        }
        try? await store.saveReadModel(merged)
        await removeOrphanedOwners(keeping: Set(merged.map(\.id)))
        // A list older than the cache can't vouch for current heads.
        return (merged, !keptCached)
    }

    private func list() async throws -> [GroupMatchReadModel] {
        try GroupMatchWire.decodeList(try await remoteAPI.listGroupMatches(), viewer: profileID)
    }

    /// A match gone from the list keeps its owner document until the outbox
    /// holds nothing for it.
    private func removeOrphanedOwners(keeping ids: Set<UUID>) async {
        guard let entries = try? await outboxStore?.entries() ?? [] else { return }
        let queued = Set(entries.map(\.payload.competitionID))
        for id in await store.ownerIDs() where !ids.contains(id) && !queued.contains(id) {
            await store.removeOwner(id)
        }
    }

    /// The seven-day window while your seat may still upload.
    func uploadWindow(_ match: GroupMatchReadModel) -> CompetitionActivityWindow? {
        guard ["scheduled", "active", "ends_today", "tallying"].contains(match.lifecycle),
              match.result == nil,
              match.ownerAttestation?.basis != .stable,
              let seat = match.seats.first(where: { $0.profileID == profileID }),
              seat.state == "accepted", seat.leftAt == nil,
              let schedule = try? match.schedule(),
              let window = try? CompetitionActivityWindow(calendar: schedule.calendar, startDay: schedule.startDay),
              let start = try? schedule.calendar.startOfDay(schedule.startDay),
              now() >= start
        else { return nil }
        return window
    }

    /// Reads Health once and queues each started day whose reading changed.
    /// Returns when the read started, or nil when it failed.
    private func upload(_ match: GroupMatchReadModel, window: CompetitionActivityWindow) async throws -> Date? {
        let readStartedAt = now()
        guard let environment, let outboxStore, let syncCoordinator,
              let seat = match.seats.first(where: { $0.profileID == profileID }),
              let read = try? await environment.read(window)
        else { return nil }
        let evaluatedAt = now()
        // Outbox first, then the document: an upload accepted in between
        // writes its row before leaving the outbox, so it shows in one of them.
        var live: [CompetitionScoreRevisionRequest] = []
        var terminal: [CompetitionOutboxEntry] = []
        for entry in try await outboxStore.entries() {
            guard case let .scoreRevision(request) = entry.payload, request.competitionID == match.id else { continue }
            if case .permanentFailure = entry.state { terminal.append(entry) } else { live.append(request) }
        }
        let document = try await store.rehydrate(
            match.id,
            highWater: match.ownerRevisionHighWater,
            rows: try seat.days.map {
                try RemoteAcceptedScoreRow(
                    ordinal: $0.ordinal,
                    acceptedCentiPoints: $0.centipoints,
                    availabilityReason: $0.centipoints == nil ? $0.availabilityReason : nil,
                    wireContentSHA256: $0.wireContentSHA256,
                    clientRevision: $0.clientRevision,
                    serverSequence: $0.serverSequence,
                    ringBasisPoints: $0.ringBasisPoints
                )
            }
        )
        for (offset, result) in read.days.enumerated() {
            let ordinal = offset + 1
            guard try window.calendar.startOfDay(result.day) <= evaluatedAt else { continue }
            let evidence = try RemoteCompetitionRuntime.remoteEvidence(from: result)
            func digest(at revision: Int64) throws -> String {
                try RemoteCompetitionRuntime.wire(
                    competitionID: match.id, profileID: profileID, ordinal: ordinal,
                    evidence: evidence, clientRevision: revision
                ).wireContentSHA256
            }
            // A rejected request is never retried, so it can't stand in for
            // this reading; only a live one can.
            let queued = live.filter { $0.dayOrdinal == ordinal }.max { $0.clientRevision < $1.clientRevision }
            if let queued, try digest(at: queued.clientRevision) == queued.wireContentSHA256 {
                continue
            }
            let accepted = document.accepted.first { $0.ordinal == ordinal }
            // A newer different value still in flight would land over the
            // accepted one, so the accepted match only counts without it.
            if let accepted, queued.map({ $0.clientRevision < accepted.clientRevision }) ?? true,
               try digest(at: accepted.clientRevision) == accepted.wireContentSHA256 {
                try await removeSettledFailures(terminal, ordinal: ordinal, through: .max, outboxStore)
                continue
            }
            let revision = try await store.allocateRevision(
                match.id, atLeast: (live.map(\.clientRevision) + terminal.compactMap { entry -> Int64? in
                    guard case let .scoreRevision(request) = entry.payload else { return nil }
                    return request.clientRevision
                }).max() ?? 0
            )
            let wire = try RemoteCompetitionRuntime.wire(
                competitionID: match.id, profileID: profileID, ordinal: ordinal,
                evidence: evidence, clientRevision: revision
            )
            _ = try await syncCoordinator.enqueue(
                .scoreRevision(try CompetitionScoreRevisionRequest(
                    competitionID: wire.competitionID,
                    semanticEventID: Self.semanticEventID(wireContentSHA256: wire.wireContentSHA256),
                    dayOrdinal: wire.dayOrdinal,
                    clientRevision: wire.clientRevision,
                    evaluatedAt: evaluatedAt,
                    moveMode: wire.moveMode,
                    standMode: wire.standMode,
                    moveBasisPoints: wire.moveBasisPoints,
                    exerciseBasisPoints: wire.exerciseBasisPoints,
                    standBasisPoints: wire.standBasisPoints,
                    availabilityReason: wire.availabilityReason,
                    scoringPolicyIdentity: wire.scoringPolicyIdentity,
                    wireContentSHA256: wire.wireContentSHA256
                )),
                enqueuedAt: evaluatedAt
            )
        }
        await syncCoordinator.waitUntilIdle()
        return readStartedAt
    }

    /// Drops a day's rejected uploads at or below `revision`.
    private func removeSettledFailures(
        _ terminal: [CompetitionOutboxEntry], ordinal: Int, through revision: Int64,
        _ outboxStore: any CompetitionOutboxStore
    ) async throws {
        for entry in terminal {
            guard case let .scoreRevision(request) = entry.payload,
                  request.dayOrdinal == ordinal, request.clientRevision <= revision
            else { continue }
            try await outboxStore.remove(entry.semanticEventID, expectedGeneration: entry.generation)
        }
    }

    /// The final window over the server's own heads. Stable needs a fresh
    /// read, an empty upload queue and refreshed heads; otherwise only
    /// best-available, and only after its deadline.
    private func attest(_ match: GroupMatchReadModel, headsAreFresh: Bool) async throws {
        guard let outboxStore, let syncCoordinator, uploadWindow(match) != nil,
              let seat = match.seats.first(where: { $0.profileID == profileID })
        else { return }
        let entries = try await outboxStore.entries().filter { $0.payload.competitionID == match.id }
        let rows = (1...7).map { ordinal in seat.days.first { $0.ordinal == ordinal } }
        let revisions = rows.map { $0?.clientRevision ?? 0 }
        var hasFailedUpload = false
        for entry in entries {
            guard case let .scoreRevision(request) = entry.payload else { continue }
            guard case .permanentFailure = entry.state else { return }
            // A newer accepted row for that day replaced the rejected one.
            if revisions[request.dayOrdinal - 1] < request.clientRevision { hasFailedUpload = true }
        }
        // Heads older than a row this device saw accepted are a stale list.
        if let document = await store.owner(match.id),
           document.accepted.contains(where: { $0.clientRevision > revisions[$0.ordinal - 1] }) {
            return
        }
        let basis: CompetitionAttestationBasis
        if headsAreFresh, !hasFailedUpload, revisions.allSatisfy({ $0 > 0 }) {
            basis = .stable
        } else if let deadline = match.bestAvailableDeadline, now() >= deadline {
            basis = .bestAvailable
        } else {
            return
        }
        let days = try rows.enumerated().map { offset, row -> RemoteFinalizationDayV1 in
            guard let row else {
                return try RemoteFinalizationDayV1(
                    ordinal: offset + 1, status: .unavailable, source: .deadlineMissing, points: nil,
                    reason: "missing", wireContentSHA256: nil, clientRevision: nil, serverSequence: nil
                )
            }
            return try RemoteFinalizationDayV1(
                ordinal: offset + 1,
                status: row.centipoints == nil ? .unavailable : .points,
                source: .acceptedRevision,
                points: row.centipoints,
                reason: row.centipoints == nil ? row.availabilityReason : nil,
                wireContentSHA256: row.wireContentSHA256,
                clientRevision: row.clientRevision,
                serverSequence: row.serverSequence
            )
        }
        let commitment = try RemoteFinalizationWireV1.windowCommitment(
            competitionID: match.id, participantID: profileID, days: days
        )
        let queued = entries.compactMap { entry -> CompetitionAttestationRequest? in
            guard case let .finalWindowAttestation(request) = entry.payload else { return nil }
            return request
        }
        let isSame = { (b: CompetitionAttestationBasis, r: [Int64], c: String) in
            b == basis && r == revisions && c == commitment
        }
        if queued.contains(where: { isSame($0.basis, $0.acceptedRevisions, $0.windowCommitmentSHA256) }) { return }
        if let accepted = match.ownerAttestation,
           isSame(accepted.basis, accepted.acceptedRevisions, accepted.windowCommitmentSHA256) { return }
        let prior = max(match.ownerAttestation?.version ?? 0, queued.map(\.attestationVersion).max() ?? 0)
        guard prior < Int64.max else { throw RemoteCompetitionRuntimeFailure.serverContractMismatch }
        _ = try await syncCoordinator.enqueue(
            .finalWindowAttestation(try CompetitionAttestationRequest(
                competitionID: match.id,
                semanticEventID: RemoteCompetitionRuntime.attestationSemanticEventID(
                    competitionID: match.id, profileID: profileID, basis: basis,
                    acceptedRevisions: revisions, windowCommitmentSHA256: commitment,
                    attestationVersion: prior + 1
                ),
                attestationVersion: prior + 1,
                basis: basis,
                acceptedRevisions: revisions,
                windowCommitmentSHA256: commitment
            )),
            enqueuedAt: now()
        )
        await syncCoordinator.waitUntilIdle()
    }

    /// An acknowledged attestation leaves the outbox once the read model
    /// shows it, and a rejected upload once a newer row for its day is in.
    private func removeMaterializedAcknowledgments(_ matches: [GroupMatchReadModel]) async throws {
        guard let outboxStore else { return }
        for entry in try await outboxStore.entries() {
            if case let .scoreRevision(request) = entry.payload, case .permanentFailure = entry.state,
               let head = matches.first(where: { $0.id == request.competitionID })?
                   .seats.first(where: { $0.profileID == profileID })?
                   .days.first(where: { $0.ordinal == request.dayOrdinal }),
               head.clientRevision > request.clientRevision {
                try await outboxStore.remove(entry.semanticEventID, expectedGeneration: entry.generation)
                continue
            }
            guard case let .finalWindowAttestation(request) = entry.payload,
                  case let .attestationAcknowledged(receipt, _) = entry.state,
                  let attestation = matches.first(where: { $0.id == request.competitionID })?.ownerAttestation,
                  request.basis == attestation.basis,
                  request.acceptedRevisions == attestation.acceptedRevisions,
                  request.windowCommitmentSHA256 == attestation.windowCommitmentSHA256,
                  request.attestationVersion == attestation.version,
                  receipt.windowCommitmentSHA256 == attestation.windowCommitmentSHA256,
                  receipt.entityServerSequence == attestation.serverSequence
            else { continue }
            try await outboxStore.remove(entry.semanticEventID, expectedGeneration: entry.generation)
        }
    }

    /// Group uploads get their own semantic-id domain, which tags them in the
    /// shared outbox.
    static func semanticEventID(wireContentSHA256: String) -> UUID {
        var data = Data("healthcomp.remote-group-score-semantic-id.v1".utf8)
        data.append(Data(wireContentSHA256.utf8))
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

// MARK: - Presentation

extension GroupMatchReadModel {
    func schedule() throws -> CompetitionSchedule {
        guard let startDay else { throw RemoteCompetitionRuntimeFailure.serverContractMismatch }
        let parts = startDay.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { throw RemoteCompetitionRuntimeFailure.serverContractMismatch }
        return CompetitionSchedule(
            calendar: try CompetitionCalendar(timeZoneIdentifier: timeZoneIdentifier),
            startDay: try CompetitionDay(
                era: 1, year: parts[0], month: parts[1], day: parts[2], timeZoneIdentifier: timeZoneIdentifier
            )
        )
    }

    /// What the screens show at `now`: live standings projected locally with
    /// the core functions, a finished match as the server froze it. Nil when
    /// the match can't be shown (the core rejects its lineup).
    func presentation(viewer: UUID, now: Date) -> GroupMatchPresentation? {
        guard let viewerSeat = seats.first(where: { $0.profileID == viewer }) else { return nil }
        let schedule = try? schedule()
        let direction: InvitationDirection = creatorProfileID == viewer ? .outgoing : .incoming
        // The day the match is on: 1...7, 8 once the week has ended, 0 before.
        var dayOrdinal = 0
        var dayProgress = 0
        if let schedule, let today = try? schedule.calendar.day(containing: now),
           let days = try? schedule.calendar.sevenDayWindow(startingOn: schedule.startDay),
           let first = try? schedule.calendar.startOfDay(schedule.startDay) {
            if let index = days.firstIndex(of: today) {
                dayOrdinal = index + 1
                if let start = try? schedule.calendar.startOfDay(today),
                   let end = try? schedule.calendar.startOfDay(schedule.calendar.day(after: today)) {
                    dayProgress = min(10_000, max(0, Int(now.timeIntervalSince(start) / end.timeIntervalSince(start) * 10_000)))
                }
            } else if now >= first {
                dayOrdinal = 8
            }
        }
        let lifecycle: LocalCompetitionLifecyclePresentation
        switch self.lifecycle {
        case "pending":
            // The read model has no creation time; the screens don't show one.
            lifecycle = .pending(direction: direction, createdAt: .distantPast, expiresAt: invitationExpiresAt)
        case "declined": lifecycle = .declined(at: closedAt ?? .distantPast, direction: direction)
        case "expired": lifecycle = .expired(at: invitationExpiresAt ?? .distantPast, direction: direction)
        case "cancelled": lifecycle = .cancelled(at: closedAt ?? .distantPast)
        default:
            if let result {
                let mine = result.standings.first {
                    $0.subject == (format == .doubles ? viewerSeat.team.map(String.init) : viewerSeat.id.uuidString.lowercased())
                }
                let tied = result.standings.filter { $0.place == 1 }.count > 1
                lifecycle = .completed(
                    outcome: mine?.place == 1 ? (tied ? .tie : .win) : .loss,
                    basis: result.basis == .stable ? .stableAcrossPostBoundaryReads : .bestAvailable,
                    completedAt: result.completedAt
                )
            } else {
                switch dayOrdinal {
                case 0: lifecycle = .scheduled
                case 7: lifecycle = .endsToday
                case 8:
                    let ended = schedule.flatMap { try? $0.calendar.startOfDay($0.calendar.day(after: $0.calendar.sevenDayWindow(startingOn: $0.startDay)[6])) }
                    lifecycle = .tallying(startedAt: ended ?? now)
                default: lifecycle = .active(dayOrdinal: dayOrdinal)
                }
            }
        }
        let isFinished = result != nil
        var days: [MatchDayScore] = []
        var rings: [GroupMatchDayRings] = []
        var leaveCutoffs: [UUID: Int] = [:]
        for seat in seats {
            if let cutoff = seat.frozenThroughDay, cutoff > 0 { leaveCutoffs[seat.id] = cutoff }
            for day in seat.days where seat.frozenThroughDay.map({ day.ordinal <= $0 }) ?? true {
                if let value = try? MatchDayScore(
                    seatID: seat.id, ordinal: day.ordinal,
                    value: day.centipoints.map(MatchDayValue.centipoints) ?? .unavailable
                ) { days.append(value) }
                if let ring = day.ringBasisPoints {
                    rings.append(GroupMatchDayRings(seatID: seat.id, ordinal: day.ordinal, centipoints: ring))
                }
            }
            if let mode = seat.botMode, let seed = seat.botSeed, let totals = seat.botDailyTotals {
                let shown = isFinished ? 7 : min(dayOrdinal, 7)
                guard shown > 0 else { continue }
                for ordinal in 1...shown {
                    let points = ordinal < dayOrdinal || isFinished
                        ? totals[ordinal - 1]
                        : BotWeek.revealed(seed: seed, mode: mode, dayOrdinal: ordinal,
                                           finalPoints: totals[ordinal - 1], progressBasisPoints: dayProgress)
                    if let value = try? MatchDayScore(seatID: seat.id, ordinal: ordinal, value: .centipoints(points * 100)) {
                        days.append(value)
                    }
                }
            }
        }
        let presentationSeats = seats.map { seat in
            GroupMatchSeat(
                id: seat.id,
                number: seat.index,
                name: seat.botMode?.name ?? seat.displayName ?? "Former competitor",
                occupant: seat.profileID.map { profileID in
                    .person(profileID: profileID, invite: seat.state == "pending" ? .invited
                        : seat.state == "declined" ? .declined : .accepted)
                } ?? .bot(seat.botMode ?? .pacer),
                team: seat.team
            )
        }
        let frozen = result.map { result in
            result.standings.compactMap { standing -> GroupMatchStandingRow? in
                let subject: MatchStandingSubject? = format == .doubles
                    ? Int(standing.subject).map(MatchStandingSubject.team)
                    : UUID(uuidString: standing.subject).map(MatchStandingSubject.seat)
                return subject.map { GroupMatchStandingRow(subject: $0, place: standing.place, centipoints: standing.centipoints) }
            }
        }
        return try? GroupMatchPresentation(
            id: CompetitionID(id),
            lifecycle: lifecycle,
            format: format,
            seats: presentationSeats,
            viewerSeatID: viewerSeat.id,
            schedule: schedule,
            days: days,
            rings: rings,
            leaveCutoffs: leaveCutoffs,
            frozenStandings: frozen
        )
    }
}

// MARK: - Commands

/// A group match RPC as the server takes it.
enum GroupMatchRemoteCommand: Equatable, Sendable {
    /// Seat 1 is the creator; `draft` holds everyone else in seat order.
    case create(creator: UUID, GroupMatchDraft, timeZoneIdentifier: String, idempotencyKey: UUID)
    /// Decline before accepting, or withdraw after (both before the start).
    case accept(UUID), decline(UUID), cancel(UUID), leave(UUID)
    case nudge(UUID, recipient: UUID)
    /// Nil removes your reaction to that person's day.
    case react(UUID, target: UUID, ordinal: Int, CompetitionReactionKind?)

    /// The RPC name and its JSON parameters.
    func rpc() throws -> (name: String, parameters: [String: Any]) {
        func id(_ value: UUID) -> String { value.uuidString.lowercased() }
        switch self {
        case let .create(creator, draft, zone, key):
            let format = switch draft.format {
            case .threeWay: "three_way"
            case .fourWay: "four_way"
            case .doubles: "doubles"
            }
            var seats: [[String: Any]] = [["kind": "human", "profile_id": id(creator)]]
            if draft.format == .doubles { seats[0]["team_number"] = 1 }
            for seat in draft.seats {
                var entry: [String: Any]
                let team: Int?
                switch seat {
                case let .person(profileID, seatTeam):
                    entry = ["kind": "human", "profile_id": id(profileID)]
                    team = seatTeam
                case let .bot(mode, seatTeam):
                    entry = ["kind": "bot", "bot_mode": mode.rawValue]
                    team = seatTeam
                }
                if let team { entry["team_number"] = team }
                seats.append(entry)
            }
            guard seats.count == draft.format.seatCount else { throw CompetitionRemoteFailure.serverContractMismatch }
            return ("create_group_match", [
                "format": format, "seats": seats, "time_zone_identifier": zone,
                "creation_idempotency_key": id(key),
            ])
        case let .accept(match): return ("accept_group_match", ["competition_id": id(match)])
        case let .decline(match): return ("decline_group_match", ["competition_id": id(match)])
        case let .cancel(match): return ("cancel_group_match", ["competition_id": id(match)])
        case let .leave(match): return ("leave_group_match", ["competition_id": id(match)])
        case let .nudge(match, recipient):
            return ("nudge_competition_participant", ["competition_id": id(match), "recipient_profile_id": id(recipient)])
        case let .react(match, target, ordinal, kind):
            return ("set_competition_reaction", [
                "competition_id": id(match), "day_ordinal": ordinal,
                "reaction": kind?.rawValue ?? NSNull(), "target_profile_id": id(target),
            ])
        }
    }
}

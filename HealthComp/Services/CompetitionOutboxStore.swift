import Foundation

enum CompetitionOutboxPayload: Equatable, Sendable {
    case scoreRevision(CompetitionScoreRevisionRequest)
    case finalWindowAttestation(CompetitionAttestationRequest)

    var semanticEventID: UUID {
        switch self {
        case let .scoreRevision(request):
            request.semanticEventID
        case let .finalWindowAttestation(request):
            request.semanticEventID
        }
    }

    var competitionID: UUID {
        switch self {
        case let .scoreRevision(request):
            request.competitionID
        case let .finalWindowAttestation(request):
            request.competitionID
        }
    }
}

extension CompetitionOutboxPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case scoreRevision
        case finalWindowAttestation
    }

    private enum Kind: String, Codable {
        case scoreRevision = "score_revision"
        case finalWindowAttestation = "final_window_attestation"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .scoreRevision:
            guard container.contains(.scoreRevision),
                  !container.contains(.finalWindowAttestation)
            else {
                throw CompetitionOutboxStoreFailure.invalidDocument
            }
            self = .scoreRevision(
                try container.decode(
                    CompetitionScoreRevisionRequest.self,
                    forKey: .scoreRevision
                )
            )
        case .finalWindowAttestation:
            guard container.contains(.finalWindowAttestation),
                  !container.contains(.scoreRevision)
            else {
                throw CompetitionOutboxStoreFailure.invalidDocument
            }
            self = .finalWindowAttestation(
                try container.decode(
                    CompetitionAttestationRequest.self,
                    forKey: .finalWindowAttestation
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .scoreRevision(request):
            try container.encode(Kind.scoreRevision, forKey: .kind)
            try container.encode(request, forKey: .scoreRevision)
        case let .finalWindowAttestation(request):
            try container.encode(
                Kind.finalWindowAttestation,
                forKey: .kind
            )
            try container.encode(
                request,
                forKey: .finalWindowAttestation
            )
        }
    }
}

enum CompetitionOutboxState: Equatable, Sendable {
    case pending(attemptCount: Int, retryAt: Date?)
    case scoreAccepted(
        CompetitionScoreRevisionResponse,
        receivedAt: Date
    )
    case attestationAcknowledged(
        CompetitionAttestationReceipt,
        receivedAt: Date
    )
    case permanentFailure(
        CompetitionOutboxPermanentFailure,
        failedAt: Date
    )
}

enum CompetitionOutboxPermanentFailure:
    String,
    Codable,
    Equatable,
    Sendable
{
    case unauthenticated
    case forbidden
    case notFound
    case inviteUnavailable
    case divergentDuplicate
    case staleRevision
    case finalizedCompetition
    case incompatiblePolicy
    case serverContractMismatch
    case accountDeletionUnavailable
    case appAttestUnavailable
    case appAttestRejected
    case appAttestRejectedTerminal
    case operationFailed
}

extension CompetitionOutboxState: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case attemptCount
        case retryAt
        case scoreResponse
        case attestationReceipt
        case receivedAt
        case failure
        case failedAt
    }

    private enum Kind: String, Codable {
        case pending
        case scoreAccepted = "score_accepted"
        case attestationAcknowledged = "attestation_acknowledged"
        case permanentFailure = "permanent_failure"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .pending:
            let attemptCount = try container.decode(
                Int.self,
                forKey: .attemptCount
            )
            guard attemptCount >= 0 else {
                throw CompetitionOutboxStoreFailure.invalidDocument
            }
            self = .pending(
                attemptCount: attemptCount,
                retryAt: try container.decodeIfPresent(
                    Date.self,
                    forKey: .retryAt
                )
            )
        case .scoreAccepted:
            self = .scoreAccepted(
                try container.decode(
                    CompetitionScoreRevisionResponse.self,
                    forKey: .scoreResponse
                ),
                receivedAt: try container.decode(
                    Date.self,
                    forKey: .receivedAt
                )
            )
        case .attestationAcknowledged:
            self = .attestationAcknowledged(
                try container.decode(
                    CompetitionAttestationReceipt.self,
                    forKey: .attestationReceipt
                ),
                receivedAt: try container.decode(
                    Date.self,
                    forKey: .receivedAt
                )
            )
        case .permanentFailure:
            self = .permanentFailure(
                try container.decode(
                    CompetitionOutboxPermanentFailure.self,
                    forKey: .failure
                ),
                failedAt: try container.decode(
                    Date.self,
                    forKey: .failedAt
                )
            )
        }
        guard datesAreFinite else {
            throw CompetitionOutboxStoreFailure.invalidDocument
        }
    }

    func encode(to encoder: Encoder) throws {
        guard datesAreFinite else {
            throw CompetitionOutboxStoreFailure.invalidDocument
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pending(attemptCount, retryAt):
            guard attemptCount >= 0 else {
                throw CompetitionOutboxStoreFailure.invalidDocument
            }
            try container.encode(Kind.pending, forKey: .kind)
            try container.encode(attemptCount, forKey: .attemptCount)
            try container.encodeIfPresent(retryAt, forKey: .retryAt)
        case let .scoreAccepted(response, receivedAt):
            try container.encode(Kind.scoreAccepted, forKey: .kind)
            try container.encode(response, forKey: .scoreResponse)
            try container.encode(receivedAt, forKey: .receivedAt)
        case let .attestationAcknowledged(receipt, receivedAt):
            try container.encode(
                Kind.attestationAcknowledged,
                forKey: .kind
            )
            try container.encode(receipt, forKey: .attestationReceipt)
            try container.encode(receivedAt, forKey: .receivedAt)
        case let .permanentFailure(failure, failedAt):
            try container.encode(Kind.permanentFailure, forKey: .kind)
            try container.encode(failure, forKey: .failure)
            try container.encode(failedAt, forKey: .failedAt)
        }
    }

    private var datesAreFinite: Bool {
        switch self {
        case let .pending(_, retryAt):
            retryAt?.timeIntervalSinceReferenceDate.isFinite ?? true
        case let .scoreAccepted(_, receivedAt),
             let .attestationAcknowledged(_, receivedAt):
            receivedAt.timeIntervalSinceReferenceDate.isFinite
        case let .permanentFailure(_, failedAt):
            failedAt.timeIntervalSinceReferenceDate.isFinite
        }
    }
}

struct CompetitionOutboxEntry: Codable, Equatable, Sendable {
    let semanticEventID: UUID
    let enqueuedAt: Date
    let generation: UInt64
    let payload: CompetitionOutboxPayload
    let state: CompetitionOutboxState

    init(
        semanticEventID: UUID,
        enqueuedAt: Date,
        generation: UInt64,
        payload: CompetitionOutboxPayload,
        state: CompetitionOutboxState
    ) throws {
        guard semanticEventID == payload.semanticEventID,
              semanticEventID != Self.nilUUID,
              enqueuedAt.timeIntervalSinceReferenceDate.isFinite,
              generation > 0
        else {
            throw CompetitionOutboxStoreFailure.invalidDocument
        }
        switch (payload, state) {
        case (.scoreRevision, .pending),
             (.scoreRevision, .scoreAccepted),
             (.scoreRevision, .permanentFailure),
             (.finalWindowAttestation, .pending),
             (.finalWindowAttestation, .attestationAcknowledged),
             (.finalWindowAttestation, .permanentFailure):
            break
        case (.scoreRevision, .attestationAcknowledged),
             (.finalWindowAttestation, .scoreAccepted):
            throw CompetitionOutboxStoreFailure.invalidDocument
        }
        switch (payload, state) {
        case let (.scoreRevision(request), .scoreAccepted(response, _)):
            guard response.disposition == .appended
                    || response.disposition == .duplicate,
                  response.wireContentSHA256 == request.wireContentSHA256
            else {
                throw CompetitionOutboxStoreFailure.invalidDocument
            }
        case let (
            .finalWindowAttestation(request),
            .attestationAcknowledged(receipt, _)
        ):
            guard receipt.windowCommitmentSHA256
                    == request.windowCommitmentSHA256
            else {
                throw CompetitionOutboxStoreFailure.invalidDocument
            }
        default:
            break
        }
        self.semanticEventID = semanticEventID
        self.enqueuedAt = enqueuedAt
        self.generation = generation
        self.payload = payload
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case semanticEventID
        case enqueuedAt
        case generation
        case payload
        case state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            semanticEventID: try container.decode(
                UUID.self,
                forKey: .semanticEventID
            ),
            enqueuedAt: try container.decode(Date.self, forKey: .enqueuedAt),
            generation: try container.decode(UInt64.self, forKey: .generation),
            payload: try container.decode(
                CompetitionOutboxPayload.self,
                forKey: .payload
            ),
            state: try container.decode(
                CompetitionOutboxState.self,
                forKey: .state
            )
        )
    }

    private static let nilUUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!
}

enum CompetitionOutboxStoreFailure: Error, Equatable, Sendable {
    case invalidRootDirectory
    case unsafeFilesystemEntry
    case invalidDocument
    case semanticEventConflict(UUID)
    case entryNotFound(UUID)
    case generationConflict(expected: UInt64, actual: UInt64)
    case generationOverflow
    case injectedCrash(JSONCompetitionOutboxStoreFaultPoint)
    case io(operation: String, code: Int32)
}

protocol CompetitionOutboxStore: Sendable {
    func enqueue(
        _ payload: CompetitionOutboxPayload,
        enqueuedAt: Date
    ) async throws -> CompetitionOutboxEntry

    func entries() async throws -> [CompetitionOutboxEntry]

    func update(
        _ semanticEventID: UUID,
        expectedGeneration: UInt64,
        state: CompetitionOutboxState
    ) async throws -> CompetitionOutboxEntry

    func remove(
        _ semanticEventID: UUID,
        expectedGeneration: UInt64
    ) async throws

}

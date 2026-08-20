import Foundation
import Supabase

enum SupabaseCompetitionRemoteAPI {
    static func make(
        transport: CompetitionRemoteTransport
    ) -> CompetitionRemoteAPI {
        CompetitionRemoteAPI(
            bootstrapProfile: { suggestedDisplayName in
                if let suggestedDisplayName {
                    try validateDisplayName(suggestedDisplayName)
                }
                let response = try await send(
                    .rpc(
                        name: "bootstrap_current_profile",
                        parameters: try encode(
                            BootstrapProfileParameters(
                                suggestedDisplayName: suggestedDisplayName
                            )
                        )
                    ),
                    transport: transport
                )
                return try decode(
                    AuthenticatedProfile.self,
                    response.data,
                    contract: .profile
                )
            },
            updateProfile: { displayName in
                try validateDisplayName(displayName)
                let response = try await send(
                    .rpc(
                        name: "update_current_profile",
                        parameters: try encode(
                            UpdateProfileParameters(
                                newDisplayName: displayName
                            )
                        )
                    ),
                    transport: transport
                )
                return try decode(
                    AuthenticatedProfile.self,
                    response.data,
                    contract: .profile
                )
            },
            listCompetitions: {
                let response = try await sendReadOnly(
                    .listCompetitions,
                    transport: transport
                )
                do {
                    return try CompetitionWireCodec.decodeArray(
                        CompetitionDescriptor.self,
                        from: response.data,
                        elementContract: .competitionDescriptor
                    )
                } catch {
                    throw CompetitionRemoteFailure.serverContractMismatch
                }
            },
            fetchCompetition: { competitionID in
                try validateUUID(competitionID)
                let response = try await send(
                    .fetchCompetition(competitionID),
                    transport: transport
                )
                return try decode(
                    CompetitionDescriptor.self,
                    response.data,
                    contract: .competitionDescriptor
                )
            },
            createInvite: { request in
                let response = try await send(
                    .function(
                        name: "create-competition-invite",
                        body: try encodeWire(
                            request,
                            contract: .inviteCreationRequest
                        )
                    ),
                    transport: transport
                )
                return try decode(
                    CompetitionInvite.self,
                    response.data,
                    contract: .inviteCreationResponse
                )
            },
            claimInvite: { request in
                let response = try await send(
                    .function(
                        name: "claim-competition-invite",
                        body: try encodeWire(
                            request,
                            contract: .inviteClaimRequest
                        )
                    ),
                    transport: transport,
                    context: .claimInvite
                )
                return try decode(
                    CompetitionInviteClaim.self,
                    response.data,
                    contract: .inviteClaimResponse
                )
            },
            archiveCompetition: { competitionID in
                try validateUUID(competitionID)
                let response = try await send(
                    .rpc(
                        name: "archive_competition",
                        parameters: try encode(
                            ArchiveCompetitionParameters(
                                competitionID: competitionID
                            )
                        )
                    ),
                    transport: transport
                )
                let archivedID = try decodeArchiveResponse(response.data)
                guard archivedID == competitionID else {
                    throw CompetitionRemoteFailure.serverContractMismatch
                }
            },
            appendScoreRevision: { _ in
                throw CompetitionRemoteFailure.appAttestUnavailable
            },
            issueAppAttestChallenge: { request in
                let response = try await send(
                    .function(
                        name: "app-attest-challenge",
                        body: try encodeWire(
                            request,
                            contract: .appAttestChallengeRequest
                        )
                    ),
                    transport: transport,
                    context: .appAttestChallenge
                )
                return try decode(
                    CompetitionAppAttestChallenge.self,
                    response.data,
                    contract: .appAttestChallengeResponse
                )
            },
            submitAttestedScoreRevision: { request in
                let response = try await send(
                    .function(
                        name: "submit-score-revision",
                        body: try encodeWire(
                            request,
                            contract: .attestedScoreRevisionRequest
                        )
                    ),
                    transport: transport,
                    context: .appAttestSubmission,
                    acceptConflict: true
                )
                do {
                    return try decode(
                        CompetitionScoreRevisionResponse.self,
                        response.data,
                        contract: .scoreRevisionResponse
                    )
                } catch {
                    guard response.statusCode == 409,
                          !containsDisposition(response.data)
                    else { throw error }
                    throw classify(
                        statusCode: response.statusCode,
                        data: response.data,
                        context: .appAttestSubmission
                    )
                }
            },
            submitAttestation: { request in
                let response = try await send(
                    .function(
                        name: "attest-final-window",
                        body: try encodeWire(
                            request,
                            contract: .attestationRequest
                        )
                    ),
                    transport: transport
                )
                return try decode(
                    CompetitionAttestationReceipt.self,
                    response.data,
                    contract: .attestationResponse
                )
            },
            fetchChanges: { cursor, pageSize in
                guard (1...200).contains(pageSize) else {
                    throw CompetitionRemoteFailure.serverContractMismatch
                }
                let response = try await sendReadOnly(
                    .rpc(
                        name: "fetch_competition_changes",
                        parameters: try encode(
                            FetchChangesParameters(
                                competitionID: cursor.competitionID,
                                afterServerSequence:
                                    cursor.lastSeenServerSequence,
                                pageSize: pageSize
                            )
                        )
                    ),
                    transport: transport
                )
                let page = try decode(
                    CompetitionChangePage.self,
                    response.data,
                    contract: .changePage
                )
                guard page.changes.count <= pageSize else {
                    throw CompetitionRemoteFailure.serverContractMismatch
                }
                return page
            },
            registerInstallation: { request in
                let response = try await send(
                    .rpc(
                        name: "register_current_device_installation",
                        parameters: try encodeWire(
                            request,
                            contract: .installationRequest
                        )
                    ),
                    transport: transport
                )
                return try decode(
                    CompetitionInstallation.self,
                    response.data,
                    contract: .installationResponse
                )
            },
            removeInstallation: { installationID in
                try validateUUID(installationID)
                let response = try await send(
                    .rpc(
                        name: "remove_current_device_installation",
                        parameters: try encode(
                            RemoveInstallationParameters(
                                installationID: installationID
                            )
                        )
                    ),
                    transport: transport
                )
                return try decode(
                    CompetitionInstallation.self,
                    response.data,
                    contract: .installationResponse
                )
            },
            loadMutedOpponentProfileIDs: {
                let response = try await send(
                    .rpc(
                        name: "list_current_notification_mutes",
                        parameters: try encode(EmptyParameters())
                    ),
                    transport: transport
                )
                return try decodeNotificationMuteProfileIDs(response.data)
            },
            setOpponentMuted: { opponentProfileID, isMuted in
                try validateUUID(opponentProfileID)
                let response = try await send(
                    .rpc(
                        name: "set_current_notification_mute",
                        parameters: try encode(
                            SetNotificationMuteParameters(
                                opponentProfileID: opponentProfileID,
                                isMuted: isMuted
                            )
                        )
                    ),
                    transport: transport
                )
                try validateNotificationMuteMutation(
                    response.data,
                    expectedOpponentProfileID: opponentProfileID,
                    expectedIsMuted: isMuted
                )
            },
            requestAccountDeletion: {
                throw CompetitionRemoteFailure.accountDeletionUnavailable
            }
        )
    }

    static func live(
        provider: SupabaseClientProvider
    ) -> CompetitionRemoteAPI {
        make(transport: .live(provider: provider))
    }

    private static func sendReadOnly(
        _ request: CompetitionRemoteTransportRequest,
        transport: CompetitionRemoteTransport
    ) async throws -> CompetitionRemoteTransportResponse {
        do {
            return try await send(request, transport: transport)
        } catch CompetitionRemoteFailure.retryableTransport {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch is CancellationError {
                throw CompetitionRemoteFailure.cancelled
            }
            return try await send(request, transport: transport)
        }
    }

    private enum ErrorContext: Equatable {
        case general
        case claimInvite
        case appAttestChallenge
        case appAttestSubmission
    }

    private static func send(
        _ request: CompetitionRemoteTransportRequest,
        transport: CompetitionRemoteTransport,
        context: ErrorContext = .general,
        acceptConflict: Bool = false
    ) async throws -> CompetitionRemoteTransportResponse {
        do {
            try Task.checkCancellation()
            let response = try await transport.send(request)
            try Task.checkCancellation()
            guard (200..<300).contains(response.statusCode)
                    || acceptConflict && response.statusCode == 409
            else {
                throw classify(
                    statusCode: response.statusCode,
                    data: response.data,
                    context: context
                )
            }
            return response
        } catch let failure as CompetitionRemoteFailure {
            throw failure
        } catch is CancellationError {
            throw CompetitionRemoteFailure.cancelled
        } catch let failure as CompetitionRemoteTransportFailure {
            switch failure {
            case .cancelled:
                throw CompetitionRemoteFailure.cancelled
            case .network, .relay:
                throw CompetitionRemoteFailure.retryableTransport
            case let .server(statusCode, code, message):
                throw classify(
                    statusCode: statusCode,
                    code: code,
                    message: message,
                    context: context
                )
            case .other:
                throw CompetitionRemoteFailure.operationFailed
            }
        } catch {
            throw CompetitionRemoteFailure.operationFailed
        }
    }

    private static func classify(
        statusCode: Int,
        data: Data,
        context: ErrorContext
    ) -> CompetitionRemoteFailure {
        let envelope = try? JSONDecoder().decode(
            RemoteErrorEnvelope.self,
            from: data
        )
        return classify(
            statusCode: statusCode,
            code: envelope?.code,
            message: envelope?.message ?? "",
            context: context
        )
    }

    private static func classify(
        statusCode: Int?,
        code: String?,
        message: String,
        context: ErrorContext
    ) -> CompetitionRemoteFailure {
        let normalizedCode = code?.lowercased()
        switch normalizedCode {
        case "app_attest_proof_rejected":
            return .appAttestRejected
        case "app_attest_context_unavailable",
             "app_attest_grant_unavailable":
            return .appAttestContextUnavailable
        case "app_attest_proof_conflict":
            return .appAttestProofConflict
        case "installation_unavailable" where context == .appAttestChallenge:
            return .appAttestUnavailable
        default:
            break
        }
        if let statusCode,
           statusCode == 408
            || statusCode == 429
            || (500...599).contains(statusCode) {
            return .retryableTransport
        }

        let identifiers = Set(
            [code, message]
                .compactMap { $0?.lowercased() }
        )
        if statusCode == 401
            || !identifiers.isDisjoint(with: [
                "unauthorized",
                "authentication_required",
                "active_profile_required",
                "pgrst301",
                "pgrst302",
                "pgrst303",
            ]) {
            return .unauthenticated
        }
        if context == .claimInvite,
           let statusCode,
           (400...499).contains(statusCode) {
            return .inviteUnavailable
        }
        if !identifiers.isDisjoint(with: [
            "invite_unavailable",
            "invite_consumed",
            "self_claim_forbidden",
            "cannot_claim_own_invite",
        ]) {
            return .inviteUnavailable
        }
        if !identifiers.isDisjoint(with: [
            "divergent_duplicate",
            "idempotency_conflict",
        ]) {
            return .divergentDuplicate
        }
        if !identifiers.isDisjoint(with: [
            "revision_regression",
            "stale_revision",
            "attestation_regression",
            "attestation_downgrade",
        ]) {
            return .staleRevision
        }
        if !identifiers.isDisjoint(with: [
            "competition_finalized",
            "competition_terminal",
            "window_stable",
        ]) {
            return .finalizedCompetition
        }
        if !identifiers.isDisjoint(with: [
            "incompatible_policy",
            "scoring_policy_mismatch",
            "wrong_policy",
        ]) {
            return .incompatiblePolicy
        }
        if !identifiers.isDisjoint(with: [
            "server_contract_mismatch",
            "invalid_request",
            "invalid_installation_request",
            "invalid_notification_mute",
        ]) {
            return .serverContractMismatch
        }
        if !identifiers.isDisjoint(with: [
            "competition_not_found",
            "not_found",
            "pgrst116",
        ]) || statusCode == 404 {
            return .notFound
        }
        if !identifiers.isDisjoint(with: [
            "forbidden",
            "rematch_not_allowed",
            "installation_unavailable",
            "opponent_unavailable",
        ]) || statusCode == 403 {
            return .forbidden
        }
        if statusCode == 400 {
            return .serverContractMismatch
        }
        return .operationFailed
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        _ data: Data,
        contract: CompetitionWireContract
    ) throws -> Value {
        do {
            return try CompetitionWireCodec.decode(
                type,
                from: data,
                contract: contract
            )
        } catch {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
    }

    private static func decodeArchiveResponse(_ data: Data) throws -> UUID {
        guard let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
              Set(object.keys) == ["competition_id"],
              let value = object["competition_id"] as? String,
              let id = UUID(uuidString: value),
              id.uuidString.lowercased() == value
        else {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
        return id
    }

    private static func decodeNotificationMuteProfileIDs(
        _ data: Data
    ) throws -> Set<UUID> {
        guard let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
              Set(object.keys) == ["opponent_profile_ids"],
              let values = object["opponent_profile_ids"] as? [Any],
              values.count <= 1_000
        else {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
        var profileIDs: Set<UUID> = []
        for value in values {
            guard let string = value as? String,
                  let profileID = UUID(uuidString: string),
                  profileID.uuidString.lowercased() == string,
                  profileID.uuidString
                    != "00000000-0000-0000-0000-000000000000",
                  profileIDs.insert(profileID).inserted
            else {
                throw CompetitionRemoteFailure.serverContractMismatch
            }
        }
        return profileIDs
    }

    private static func validateNotificationMuteMutation(
        _ data: Data,
        expectedOpponentProfileID: UUID,
        expectedIsMuted: Bool
    ) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
              Set(object.keys) == ["is_muted", "opponent_profile_id"],
              let profileIDString = object["opponent_profile_id"] as? String,
              profileIDString
                == expectedOpponentProfileID.uuidString.lowercased(),
              let response = try? JSONDecoder().decode(
                NotificationMuteMutationResponse.self,
                from: data
              ),
              response.opponentProfileID == expectedOpponentProfileID,
              response.isMuted == expectedIsMuted
        else {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
    }

    private static func encode<Value: Encodable>(
        _ value: Value
    ) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(value)
        } catch {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
    }

    private static func encodeWire<Value: Encodable>(
        _ value: Value,
        contract: CompetitionWireContract
    ) throws -> Data {
        do {
            return try CompetitionWireCodec.encode(
                value,
                contract: contract
            )
        } catch {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
    }

    private static func validateDisplayName(_ value: String) throws {
        guard value == value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              (1...64).contains(value.count),
              value != "Former competitor",
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
    }

    private static func validateUUID(_ value: UUID) throws {
        guard value.uuidString
            != "00000000-0000-0000-0000-000000000000"
        else {
            throw CompetitionRemoteFailure.serverContractMismatch
        }
    }

    private static func containsDisposition(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else { return false }
        return object["disposition"] != nil
    }
}

private struct BootstrapProfileParameters: Encodable {
    let suggestedDisplayName: String?

    enum CodingKeys: String, CodingKey {
        case suggestedDisplayName = "suggested_display_name"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            suggestedDisplayName,
            forKey: .suggestedDisplayName
        )
    }
}

private struct EmptyParameters: Encodable {}

private struct SetNotificationMuteParameters: Encodable {
    let opponentProfileID: UUID
    let isMuted: Bool

    enum CodingKeys: String, CodingKey {
        case opponentProfileID = "opponent_profile_id"
        case isMuted = "is_muted"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            opponentProfileID.uuidString.lowercased(),
            forKey: .opponentProfileID
        )
        try container.encode(isMuted, forKey: .isMuted)
    }
}

private struct NotificationMuteMutationResponse: Decodable {
    let opponentProfileID: UUID
    let isMuted: Bool

    enum CodingKeys: String, CodingKey {
        case opponentProfileID = "opponent_profile_id"
        case isMuted = "is_muted"
    }
}

private struct UpdateProfileParameters: Encodable {
    let newDisplayName: String

    enum CodingKeys: String, CodingKey {
        case newDisplayName = "new_display_name"
    }
}

private struct ArchiveCompetitionParameters: Encodable {
    let competitionID: UUID

    enum CodingKeys: String, CodingKey {
        case competitionID = "competition_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            competitionID.uuidString.lowercased(),
            forKey: .competitionID
        )
    }
}

private struct FetchChangesParameters: Encodable {
    let competitionID: UUID
    let afterServerSequence: Int64
    let pageSize: Int

    enum CodingKeys: String, CodingKey {
        case competitionID = "competition_id"
        case afterServerSequence = "after_server_seq"
        case pageSize = "page_size"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            competitionID.uuidString.lowercased(),
            forKey: .competitionID
        )
        try container.encode(
            String(afterServerSequence),
            forKey: .afterServerSequence
        )
        try container.encode(pageSize, forKey: .pageSize)
    }
}

private struct RemoveInstallationParameters: Encodable {
    let installationID: UUID

    enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            installationID.uuidString.lowercased(),
            forKey: .installationID
        )
    }
}

private struct RemoteErrorEnvelope: Decodable {
    private struct ErrorBody: Decodable {
        let code: String?
        let message: String?
    }

    let code: String?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let body = try? container.decode(ErrorBody.self, forKey: .error) {
            self.code = body.code
            self.message = body.message
        } else {
            self.code = try container.decodeIfPresent(
                String.self,
                forKey: .code
            )
            self.message = try container.decodeIfPresent(
                String.self,
                forKey: .message
            )
        }
    }
}

private extension CompetitionRemoteTransport {
    static func live(provider: SupabaseClientProvider) -> Self {
        let clientBox = SupabaseCompetitionClientBox(provider: provider)
        return Self { request in
            try await clientBox.send(request)
        }
    }
}

private actor SupabaseCompetitionClientBox {
    private static let descriptorSelection = """
        id,creator_profile_id,time_zone_identifier,start_day,
        scoring_policy_identity,lifecycle,invitation_expires_at,
        best_available_deadline,rematch_parent_id,next_server_seq,
        participants:competition_participants(
          profile_id,role,state,profile:profiles(id,display_name)
        )
        """

    private let provider: SupabaseClientProvider
    private var cachedClient: SupabaseClient?

    init(provider: SupabaseClientProvider) {
        self.provider = provider
    }

    func send(
        _ request: CompetitionRemoteTransportRequest
    ) async throws -> CompetitionRemoteTransportResponse {
        do {
            try Task.checkCancellation()
            let client = try client()
            switch request {
            case let .rpc(name, parameters):
                let body = try JSONDecoder().decode(
                    AnyJSON.self,
                    from: parameters
                )
                let response = try await client
                    .rpc(name, params: body)
                    .retry(enabled: false)
                    .execute()
                return CompetitionRemoteTransportResponse(
                    statusCode: response.status,
                    data: response.data
                )
            case let .function(name, bodyData):
                let body = try JSONDecoder().decode(
                    AnyJSON.self,
                    from: bodyData
                )
                return try await client.functions.invoke(
                    name,
                    options: FunctionInvokeOptions(body: body)
                ) { data, response in
                    CompetitionRemoteTransportResponse(
                        statusCode: response.statusCode,
                        data: data
                    )
                }
            case .listCompetitions:
                let response = try await client
                    .from("competitions")
                    .select(Self.descriptorSelection)
                    .retry(enabled: false)
                    .execute()
                return CompetitionRemoteTransportResponse(
                    statusCode: response.status,
                    data: response.data
                )
            case let .fetchCompetition(competitionID):
                let response = try await client
                    .from("competitions")
                    .select(Self.descriptorSelection)
                    .eq(
                        "id",
                        value: competitionID.uuidString.lowercased()
                    )
                    .single()
                    .retry(enabled: false)
                    .execute()
                return CompetitionRemoteTransportResponse(
                    statusCode: response.status,
                    data: response.data
                )
            }
        } catch is CancellationError {
            throw CompetitionRemoteTransportFailure.cancelled
        } catch let error as FunctionsError {
            switch error {
            case .relayError:
                throw CompetitionRemoteTransportFailure.relay
            case let .httpError(code, data):
                return CompetitionRemoteTransportResponse(
                    statusCode: code,
                    data: data
                )
            }
        } catch let error as HTTPError {
            return CompetitionRemoteTransportResponse(
                statusCode: error.response.statusCode,
                data: error.data
            )
        } catch let error as PostgrestError {
            throw CompetitionRemoteTransportFailure.server(
                statusCode: nil,
                code: error.code,
                message: error.message
            )
        } catch let error as URLError {
            if error.code == .cancelled {
                throw CompetitionRemoteTransportFailure.cancelled
            }
            throw CompetitionRemoteTransportFailure.network
        } catch {
            throw CompetitionRemoteTransportFailure.other
        }
    }

    private func client() throws -> SupabaseClient {
        if let cachedClient { return cachedClient }
        let client = try provider.client()
        cachedClient = client
        return client
    }
}

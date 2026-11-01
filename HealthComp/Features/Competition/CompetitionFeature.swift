import CompetitionCore
import ComposableArchitecture
import Foundation

@Reducer
struct CompetitionFeature {
    /// Where a challenge is being created: the + sheet, or one result
    /// screen's rematch. Each slot keeps its own key, status and link.
    enum InviteSlot: Hashable, Sendable {
        case sheet
        case rematch(of: CompetitionID)
    }

    enum InviteCreationFailure: Equatable, Sendable {
        case connection, unavailable, recipientGone, alreadyPending
        /// The server knew of a challenge or match with them first.
        case conflict
    }

    struct InviteCreation: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case creating
            case sent(CompetitionID)
            case failed(InviteCreationFailure)
        }

        var recipientID: UUID
        var idempotencyKey: UUID
        var status: Status
    }

    enum InviteLinkState: Equatable, Sendable {
        case loading
        case ready(CompetitionInviteShareLink, minimumRevision: UInt64)
        case notOnThisPhone
        case failed
    }

    enum InviteRecipientStatus: Equatable, Sendable {
        case idle, lookingUp, invalidCode, ownCode, notFound, connectionFailed
    }

    enum ChallengeSheetStatus: Equatable, Sendable {
        case ready, creating
        case alreadyChallenged(LocalCompetitionPresentation)
        /// They already challenged you.
        case challengedYou(LocalCompetitionPresentation)
        /// You already have a match with them that hasn't ended.
        case inMatch(LocalCompetitionPresentation)
        case sent(
            challengeID: CompetitionID,
            challenge: LocalCompetitionPresentation?,
            link: CompetitionInviteShareLink?
        )
        case failed(InviteCreationFailure)
    }

    enum CompetitionRematchState: Equatable, Sendable {
        case available, sending
        case sent(challengeID: CompetitionID, expiresAt: Date?, link: InviteLinkState?)
        /// The other person rematched you; it opens their challenge.
        case received(LocalCompetitionPresentation)
        case next(LocalCompetitionPresentation)
        case alreadyChallenged(LocalCompetitionPresentation)
        case challengedYou(LocalCompetitionPresentation)
        case inMatch(LocalCompetitionPresentation)
        case failed(InviteCreationFailure)
    }

    enum InviteCreationResponse: Equatable, Sendable {
        case success(
            link: CompetitionInviteShareLink,
            competitionID: CompetitionID,
            expectedRevision: UInt64
        )
        case failure(CompetitionRemoteFailure)
        case configurationUnavailable
    }

    @ObservableState
    struct State: Equatable {
        var publication: CompetitionPublication?
        var commandIDsInFlight: Set<CompetitionID>
        var commandExpectedPublicationRevisions: [CompetitionID: UInt64]
        var mutedOpponentIdentities: Set<String>
        var muteOpponentIdentitiesInFlight: Set<String>
        var mutePreferencesLoadFailed: Bool
        /// Per person: the `isMuted` value that failed to save.
        var muteSaveFailures: [String: Bool]
        var notificationAuthorizationState:
            CompetitionNotificationAuthorizationState?
        var notificationAuthorizationRequestIsInFlight: Bool
        var inviteCreations: [InviteSlot: InviteCreation]
        var inviteLinks: [CompetitionID: InviteLinkState]
        // The + sheet's person; a rematch never writes these.
        var inviteRecipient: AuthenticatedProfile?
        var inviteRecipientCode = ""
        var inviteRecipientStatus: InviteRecipientStatus = .idle
        /// The signed-in profile, so Home can draw its initial.
        var ownProfile: AuthenticatedProfile?
        /// Your reusable challenge link, once loaded.
        var challengeLink: URL?
        var challengeLinkLoadFailed = false

        init(
            publication: CompetitionPublication? = nil,
            commandIDsInFlight: Set<CompetitionID> = [],
            commandExpectedPublicationRevisions: [CompetitionID: UInt64] = [:],
            mutedOpponentIdentities: Set<String> = [],
            muteOpponentIdentitiesInFlight: Set<String> = [],
            mutePreferencesLoadFailed: Bool = false,
            muteSaveFailures: [String: Bool] = [:],
            notificationAuthorizationState:
                CompetitionNotificationAuthorizationState? = nil,
            notificationAuthorizationRequestIsInFlight: Bool = false,
            inviteCreations: [InviteSlot: InviteCreation] = [:],
            inviteLinks: [CompetitionID: InviteLinkState] = [:],
            inviteRecipient: AuthenticatedProfile? = nil,
            ownProfile: AuthenticatedProfile? = nil
        ) {
            self.publication = publication
            self.commandIDsInFlight = commandIDsInFlight
            self.commandExpectedPublicationRevisions =
                commandExpectedPublicationRevisions
            self.mutedOpponentIdentities = mutedOpponentIdentities
            self.muteOpponentIdentitiesInFlight =
                muteOpponentIdentitiesInFlight
            self.mutePreferencesLoadFailed = mutePreferencesLoadFailed
            self.muteSaveFailures = muteSaveFailures
            self.notificationAuthorizationState =
                notificationAuthorizationState
            self.notificationAuthorizationRequestIsInFlight =
                notificationAuthorizationRequestIsInFlight
            self.inviteCreations = inviteCreations
            self.inviteLinks = inviteLinks
            self.inviteRecipient = inviteRecipient
            self.ownProfile = ownProfile
        }

        func isCommandInFlight(_ id: CompetitionID) -> Bool {
            commandIDsInFlight.contains(id)
        }
    }

    enum Action: Equatable, Sendable {
        case task
        case publication(CompetitionPublication)
        case inviteRecipientCodeChanged(String)
        case findInviteRecipientTapped
        /// The trimmed input that was looked up, and its answer.
        case inviteRecipientResponse(String, Result<AuthenticatedProfile, CompetitionRemoteFailure>)
        /// Someone's challenge link resolved: prefill the + sheet's person.
        case challengeRecipientChosen(AuthenticatedProfile)
        case cancelTapped(CompetitionID)
        case challengeLinkRequested
        case challengeLinkResponse(URL?)
        case createInviteTapped
        case createInviteResponse(
            InviteSlot,
            idempotencyKey: UUID,
            InviteCreationResponse
        )
        case challengeSheetDismissed
        case inviteLinkNeeded(CompetitionID)
        case inviteLinkResponse(CompetitionID, InviteLinkState)
        case acceptTapped(CompetitionID)
        case declineTapped(CompetitionID)
        case archiveTapped(CompetitionID)
        case rematchTapped(CompetitionID)
        case challengeAgainTapped(CompetitionID)
        case reinviteTapped
        case deleteTapped(CompetitionID)
        case commandFinished(CompetitionID, expectedRevision: UInt64)
        case mutePreferencesLoaded(Set<String>?)
        case muteTapped(String)
        case muteFinished(String, isMuted: Bool, succeeded: Bool)
        case notificationAuthorizationLoaded(
            CompetitionNotificationAuthorizationState
        )
        case enableNotificationsTapped
        case notificationAuthorizationRequestFinished(
            CompetitionNotificationAuthorizationState
        )
        case pullToRefresh
        case sceneBecameActive
        case timeZoneChanged
        case stop
    }

    @Dependency(\.competitionClient) var competitionClient
    @Dependency(\.competitionInviteLinkClient) var competitionInviteLinkClient

    private enum CancelID {
        case publications
        case inviteCreation
        case inviteRecipient
        case inviteLink
        case challengeLink
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                let currentAuthorization = state.notificationAuthorizationState
                return .merge(
                    .run { send in
                        for await publication in competitionClient.start() {
                            guard !Task.isCancelled else { return }
                            await send(.publication(publication))
                        }
                    }
                    .cancellable(
                        id: CancelID.publications,
                        cancelInFlight: true
                    ),
                    loadMutePreferences(state: state),
                    loadNotificationAuthorization(current: currentAuthorization)
                )

            case let .publication(publication):
                guard publication.publicationRevision
                    > (state.publication?.publicationRevision ?? 0)
                else {
                    return .none
                }
                state.publication = publication
                pruneInviteLinks(state: &state)
                let acknowledgedIDs = state
                    .commandExpectedPublicationRevisions
                    .compactMap { id, expectedRevision in
                        expectedRevision <= publication.publicationRevision
                            ? id
                            : nil
                    }
                for id in acknowledgedIDs {
                    state.commandIDsInFlight.remove(id)
                    state.commandExpectedPublicationRevisions[id] = nil
                }
                return .none

            case let .inviteRecipientCodeChanged(code):
                guard !state.isChallengeSheetLocked,
                      state.inviteRecipientCode != code else { return .none }
                state.inviteRecipientCode = code
                state.inviteRecipient = nil
                state.inviteRecipientStatus = .idle
                dropFailedSheetCreation(state: &state)
                return .cancel(id: CancelID.inviteRecipient)

            case .findInviteRecipientTapped:
                let input = state.inviteRecipientCode
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !state.isChallengeSheetLocked,
                      state.inviteRecipientStatus != .lookingUp,
                      !input.isEmpty else { return .none }
                // A challenge link (either URL form) or its bare code, or a
                // 1.0.2 account code.
                let lookup: @Sendable () async throws -> AuthenticatedProfile
                var expectedID: UUID?
                if let code = Self.challengeLinkCode(in: input) {
                    lookup = { [competitionClient] in
                        try await competitionClient.resolveChallengeLink(code)
                    }
                } else if let id = UUID(uuidString: input),
                          id != UUID(uuidString: "00000000-0000-0000-0000-000000000000") {
                    // Your own code never reaches the server.
                    guard id != state.ownProfile?.id else {
                        state.inviteRecipientStatus = .ownCode
                        return .none
                    }
                    expectedID = id
                    lookup = { [competitionClient] in
                        try await competitionClient.resolveInviteRecipient(id)
                    }
                } else {
                    state.inviteRecipientStatus = .invalidCode
                    return .none
                }
                state.inviteRecipient = nil
                state.inviteRecipientStatus = .lookingUp
                dropFailedSheetCreation(state: &state)
                return .run { [expectedID] send in
                    do {
                        let recipient = try await lookup()
                        guard !Task.isCancelled else { return }
                        guard expectedID.map({ $0 == recipient.id }) ?? true else {
                            await send(.inviteRecipientResponse(input, .failure(.notFound)))
                            return
                        }
                        await send(.inviteRecipientResponse(input, .success(recipient)))
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled else { return }
                        await send(.inviteRecipientResponse(input, .failure(
                            (error as? CompetitionRemoteFailure) ?? .operationFailed
                        )))
                    }
                }
                .cancellable(id: CancelID.inviteRecipient, cancelInFlight: true)

            case let .inviteRecipientResponse(input, result):
                guard state.inviteRecipientStatus == .lookingUp,
                      state.inviteRecipientCode.trimmingCharacters(in: .whitespacesAndNewlines) == input
                else { return .none }
                state.inviteRecipient = nil
                switch result {
                case let .success(recipient) where recipient.id == state.ownProfile?.id:
                    state.inviteRecipientStatus = .ownCode
                case let .success(recipient):
                    state.inviteRecipient = recipient
                    state.inviteRecipientStatus = .idle
                case .failure(.ownChallengeLink):
                    state.inviteRecipientStatus = .ownCode
                case .failure(.recipientUnavailable), .failure(.notFound):
                    state.inviteRecipientStatus = .notFound
                case .failure:
                    state.inviteRecipientStatus = .connectionFailed
                }
                return .none

            case let .challengeRecipientChosen(recipient):
                state.inviteCreations[.sheet] = nil
                state.inviteRecipient = recipient
                state.inviteRecipientCode = recipient.id.uuidString.lowercased()
                state.inviteRecipientStatus = .idle
                return .cancel(id: CancelID.inviteRecipient)

            case let .cancelTapped(id):
                guard state.commandIDsInFlight.insert(id).inserted else {
                    return .none
                }
                return .run { send in
                    let returned = await competitionClient.cancel(id)
                    await send(
                        .commandFinished(
                            id,
                            expectedRevision: returned.publicationRevision
                        )
                    )
                }

            case .challengeLinkRequested:
                guard state.challengeLink == nil else { return .none }
                state.challengeLinkLoadFailed = false
                return .run { send in
                    let code = try? await competitionClient.loadChallengeLinkCode()
                    await send(.challengeLinkResponse(
                        code.flatMap(competitionInviteLinkClient.makeChallengeLink)
                    ))
                }
                .cancellable(id: CancelID.challengeLink, cancelInFlight: true)

            case let .challengeLinkResponse(url):
                state.challengeLink = url
                state.challengeLinkLoadFailed = url == nil
                return .none

            case .createInviteTapped:
                switch state.challengeSheetStatus {
                case .alreadyChallenged, .challengedYou, .inMatch:
                    return .none
                default:
                    break
                }
                return beginInviteCreation(
                    state: &state,
                    slot: .sheet,
                    recipient: state.inviteRecipient
                )

            case let .createInviteResponse(slot, idempotencyKey, response):
                // The link belongs to the challenge, so it is kept even when
                // the sheet closed while the challenge was being created.
                if case let .success(link, competitionID, expectedRevision) = response {
                    state.inviteLinks[competitionID] = .ready(
                        link,
                        minimumRevision: expectedRevision
                    )
                }
                guard var creation = state.inviteCreations[slot],
                      creation.idempotencyKey == idempotencyKey,
                      creation.status == .creating
                else {
                    return .none
                }
                var effect = Effect<Action>.none
                switch response {
                case let .success(_, competitionID, _):
                    creation.status = .sent(competitionID)
                case .failure(.pendingInvitationExists):
                    creation.status = .failed(.alreadyPending)
                    // The existing challenge shows up, then offers Open Challenge.
                    effect = reconcile(trigger: .pullToRefresh)
                case .failure(.activeMatchExists), .failure(.incomingChallengeExists):
                    creation.status = .failed(.conflict)
                    // Once the dashboard catches up, the derived row replaces this.
                    effect = reconcile(trigger: .pullToRefresh)
                case .failure(.recipientUnavailable), .failure(.forbidden):
                    guard slot == .sheet else {
                        creation.status = .failed(.recipientGone)
                        break
                    }
                    state.inviteCreations[slot] = nil
                    state.inviteRecipient = nil
                    state.inviteRecipientStatus = .notFound
                    return .none
                case .failure(.divergentDuplicate):
                    // A new key, so a changed request can't stay pinned to a
                    // conflicting one.
                    creation.idempotencyKey = competitionInviteLinkClient
                        .makeIdempotencyKey()
                    creation.status = .failed(.connection)
                case .failure:
                    creation.status = .failed(.connection)
                case .configurationUnavailable:
                    creation.status = .failed(.unavailable)
                }
                state.inviteCreations[slot] = creation
                pruneInviteLinks(state: &state)
                return effect

            case .challengeSheetDismissed:
                state.inviteCreations[.sheet] = nil
                state.inviteRecipientCode = ""
                state.inviteRecipient = nil
                state.inviteRecipientStatus = .idle
                return .cancel(id: CancelID.inviteRecipient)

            case let .inviteLinkNeeded(id):
                guard state.publication?.source == .remoteParticipants else {
                    return .none
                }
                switch state.inviteLinks[id] {
                case nil, .failed?:
                    break
                default:
                    return .none
                }
                state.inviteLinks[id] = .loading
                return .run { send in
                    do {
                        let outcome = try await competitionClient.restoreInvite(id)
                        guard outcome.invite.competitionID == id.rawValue,
                              let link = competitionInviteLinkClient
                                .makeShareLink(outcome.invite.token)
                        else {
                            await send(.inviteLinkResponse(id, .notOnThisPhone))
                            return
                        }
                        await send(.inviteLinkResponse(id, .ready(
                            link,
                            minimumRevision: outcome.expectedPublicationRevision
                        )))
                    } catch is CancellationError {
                        return
                    } catch CompetitionRemoteFailure.cancelled {
                        return
                    } catch CompetitionRemoteFailure.notFound,
                            CompetitionRemoteFailure.divergentDuplicate {
                        await send(.inviteLinkResponse(id, .notOnThisPhone))
                    } catch {
                        await send(.inviteLinkResponse(id, .failed))
                    }
                }
                .cancellable(id: CancelID.inviteLink, cancelInFlight: false)

            case let .inviteLinkResponse(id, linkState):
                guard state.inviteLinks[id] == .loading else { return .none }
                state.inviteLinks[id] = linkState
                return .none

            case let .acceptTapped(id):
                guard state.commandIDsInFlight.insert(id).inserted else {
                    return .none
                }
                return .run { send in
                    let returned = await competitionClient.accept(id)
                    await send(
                        .commandFinished(
                            id,
                            expectedRevision: returned.publicationRevision
                        )
                    )
                }

            case let .declineTapped(id):
                guard state.commandIDsInFlight.insert(id).inserted else {
                    return .none
                }
                return .run { send in
                    let returned = await competitionClient.decline(id)
                    await send(
                        .commandFinished(
                            id,
                            expectedRevision: returned.publicationRevision
                        )
                    )
                }

            case let .archiveTapped(id):
                guard state.commandIDsInFlight.insert(id).inserted else {
                    return .none
                }
                return .run { send in
                    let returned = await competitionClient.archive(id)
                    await send(
                        .commandFinished(
                            id,
                            expectedRevision: returned.publicationRevision
                        )
                    )
                }

            case let .rematchTapped(id):
                if state.publication?.source == .remoteParticipants {
                    guard let parent = state.publication?.dashboard.competitions.first(where: { $0.id == id }),
                          let profileID = RemoteCompetitionOpponentIdentity.profileID(parent.opponentIdentity)
                    else { return .none }
                    switch state.rematchState(for: parent) {
                    case .available, .failed(.connection):
                        break
                    default:
                        return .none
                    }
                    return beginInviteCreation(
                        state: &state,
                        slot: .rematch(of: id),
                        recipient: AuthenticatedProfile(
                            id: profileID,
                            displayName: parent.opponentDisplayName
                        )
                    )
                }
                guard state.commandIDsInFlight.insert(id).inserted else {
                    return .none
                }
                return .run { send in
                    let returned = await competitionClient.rematch(id)
                    await send(
                        .commandFinished(
                            id,
                            expectedRevision: returned.publicationRevision
                        )
                    )
                }

            // Prefills the Challenge sheet with the same account as a closed
            // challenge. Nothing is created until Create is tapped.
            case let .challengeAgainTapped(id):
                guard state.publication?.source == .remoteParticipants,
                      let parent = state.publication?.dashboard.competitions.first(where: { $0.id == id }),
                      let profileID = RemoteCompetitionOpponentIdentity.profileID(parent.opponentIdentity)
                else { return .none }
                state.inviteCreations[.sheet] = nil
                state.inviteRecipient = AuthenticatedProfile(id: profileID, displayName: parent.opponentDisplayName)
                state.inviteRecipientCode = profileID.uuidString.lowercased()
                state.inviteRecipientStatus = .idle
                return .cancel(id: CancelID.inviteRecipient)

            case .reinviteTapped:
                let id = LocalCompetitionIdentity.bootstrapCompetitionID
                guard state.commandIDsInFlight.insert(id).inserted else {
                    return .none
                }
                return .run { send in
                    let returned = await competitionClient.reinvite()
                    await send(
                        .commandFinished(
                            id,
                            expectedRevision: returned.publicationRevision
                        )
                    )
                }

            case let .deleteTapped(id):
                guard state.commandIDsInFlight.insert(id).inserted else {
                    return .none
                }
                return .run { send in
                    let returned = await competitionClient.delete(id)
                    await send(
                        .commandFinished(
                            id,
                            expectedRevision: returned.publicationRevision
                        )
                    )
                }

            case let .mutePreferencesLoaded(identities):
                guard let identities else {
                    state.mutePreferencesLoadFailed = true
                    return .none
                }
                state.mutedOpponentIdentities = identities
                state.mutePreferencesLoadFailed = false
                return .none

            case let .muteTapped(identity):
                guard !identity.isEmpty,
                      state.muteOpponentIdentitiesInFlight
                        .insert(identity).inserted
                else {
                    return .none
                }
                let isMuted = !state.mutedOpponentIdentities
                    .contains(identity)
                if isMuted {
                    state.mutedOpponentIdentities.insert(identity)
                } else {
                    state.mutedOpponentIdentities.remove(identity)
                }
                state.muteSaveFailures[identity] = nil
                return .run { send in
                    do {
                        try await competitionClient
                            .setNotificationMuted(identity, isMuted)
                        await send(
                            .muteFinished(
                                identity,
                                isMuted: isMuted,
                                succeeded: true
                            )
                        )
                    } catch {
                        await send(
                            .muteFinished(
                                identity,
                                isMuted: isMuted,
                                succeeded: false
                            )
                        )
                    }
                }

            case let .muteFinished(identity, isMuted, succeeded):
                state.muteOpponentIdentitiesInFlight.remove(identity)
                // A save that worked proves the store is reachable again, so
                // a stale load failure gets another chance to clear.
                guard !succeeded else {
                    return state.mutePreferencesLoadFailed
                        ? loadMutePreferences(state: state)
                        : .none
                }
                if isMuted {
                    state.mutedOpponentIdentities.remove(identity)
                } else {
                    state.mutedOpponentIdentities.insert(identity)
                }
                state.muteSaveFailures[identity] = isMuted
                return .none

            case let .notificationAuthorizationLoaded(authorization):
                state.notificationAuthorizationState = authorization
                return .none

            case .enableNotificationsTapped:
                guard state.notificationAuthorizationState
                    == .notDetermined,
                    !state.notificationAuthorizationRequestIsInFlight
                else {
                    return .none
                }
                state.notificationAuthorizationRequestIsInFlight = true
                return .run { send in
                    await send(
                        .notificationAuthorizationRequestFinished(
                            await competitionClient
                                .requestNotificationAuthorization()
                        )
                    )
                }

            case let .notificationAuthorizationRequestFinished(
                authorization
            ):
                state.notificationAuthorizationState = authorization
                state.notificationAuthorizationRequestIsInFlight = false
                return .none

            case let .commandFinished(id, expectedRevision):
                if (state.publication?.publicationRevision ?? 0)
                    >= expectedRevision {
                    state.commandIDsInFlight.remove(id)
                    state.commandExpectedPublicationRevisions[id] = nil
                } else {
                    state.commandExpectedPublicationRevisions[id] = max(
                        state.commandExpectedPublicationRevisions[id] ?? 0,
                        expectedRevision
                    )
                }
                return .none

            case .pullToRefresh:
                return reconcile(trigger: .pullToRefresh)

            case .sceneBecameActive:
                // Changes made in iOS Settings show without a relaunch.
                return .merge(
                    reconcile(trigger: .foreground),
                    loadMutePreferences(state: state),
                    loadNotificationAuthorization(
                        current: state.notificationAuthorizationState
                    )
                )

            case .timeZoneChanged:
                return reconcile(trigger: .timeZoneChange)

            case .stop:
                state.inviteCreations = [:]
                state.inviteLinks = [:]
                state.inviteRecipient = nil
                state.inviteRecipientCode = ""
                state.inviteRecipientStatus = .idle
                state.challengeLink = nil
                state.challengeLinkLoadFailed = false
                return .concatenate(
                    .merge(
                        .cancel(id: CancelID.publications),
                        .cancel(id: CancelID.inviteRecipient),
                        .cancel(id: CancelID.inviteCreation),
                        .cancel(id: CancelID.inviteLink),
                        .cancel(id: CancelID.challengeLink)
                    ),
                    .run { _ in await competitionClient.stop() }
                )
            }
        }
    }

    /// A challenge link URL (https or the app's scheme) or a bare 22-character code.
    static func challengeLinkCode(in input: String) -> CompetitionChallengeLinkCode? {
        if let url = URL(string: input),
           case let .challengeLink(code)? = CompetitionRoute(url: url) {
            return code
        }
        return CompetitionChallengeLinkCode(rawValue: input)
    }

    private func dropFailedSheetCreation(state: inout State) {
        if case .failed? = state.inviteCreations[.sheet]?.status {
            state.inviteCreations[.sheet] = nil
        }
    }

    /// Drops links whose challenge is no longer pending. A missing challenge
    /// only counts once discovery is complete.
    private func pruneInviteLinks(state: inout State) {
        guard let publication = state.publication else { return }
        for (id, link) in state.inviteLinks {
            var minimumRevision: UInt64 = 0
            if case let .ready(_, revision) = link { minimumRevision = revision }
            guard publication.publicationRevision >= minimumRevision else { continue }
            if let challenge = publication.dashboard.competitions.first(where: { $0.id == id }) {
                if case let .pending(_, _, expiresAt) = challenge.lifecycle,
                   expiresAt.map({ $0 > publication.evaluatedAt }) ?? true {
                    continue
                }
            } else if discoveryIsIncomplete(for: id, in: publication) {
                continue
            }
            state.inviteLinks[id] = nil
            for (slot, creation) in state.inviteCreations
            where slot != .sheet && creation.status == .sent(id) {
                state.inviteCreations[slot] = nil
            }
        }
    }

    // A partial/failed discovery is not evidence that the server retired this invitation.
    private func discoveryIsIncomplete(
        for id: CompetitionID,
        in publication: CompetitionPublication
    ) -> Bool {
        publication.dashboard.issues.contains { issue in
            switch issue {
            case .storageUnavailable, .remoteUnavailable, .remoteFailure,
                 .bootstrapIdentityRetired, .publicationRevisionExhausted, .unimplemented:
                true
            case let .competitionFailures(ids):
                ids.contains(id)
            case let .commandRejected(rejectedID):
                rejectedID == id
            case .authorizationUnavailable, .activityFailures:
                false
            }
        }
    }

    /// Reads the muted list. Skipped while a mute is saving, so the read can't
    /// undo that optimistic change.
    private func loadMutePreferences(state: State) -> Effect<Action> {
        guard state.muteOpponentIdentitiesInFlight.isEmpty else { return .none }
        let current = state.mutedOpponentIdentities
        let loadFailed = state.mutePreferencesLoadFailed
        return .run { send in
            do {
                let loaded = try await competitionClient
                    .loadMutedOpponentIdentities()
                // A success after a failure clears the failure, even when
                // nothing changed.
                if loaded != current || loadFailed {
                    await send(.mutePreferencesLoaded(loaded))
                }
            } catch {
                await send(.mutePreferencesLoaded(nil))
            }
        }
    }

    private func loadNotificationAuthorization(
        current: CompetitionNotificationAuthorizationState?
    ) -> Effect<Action> {
        .run { send in
            guard let loaded = await competitionClient
                .loadNotificationAuthorizationState(),
                loaded != current
            else {
                return
            }
            await send(.notificationAuthorizationLoaded(loaded))
        }
    }

    private func reconcile(
        trigger: ActivityRefreshTrigger
    ) -> Effect<Action> {
        .run { _ in
            _ = await competitionClient.reconcileAll(trigger)
        }
    }

    private func beginInviteCreation(
        state: inout State,
        slot: InviteSlot,
        recipient: AuthenticatedProfile?
    ) -> Effect<Action> {
        guard let recipient else { return .none }
        let existing = state.inviteCreations[slot]
        switch existing?.status {
        case .creating?, .sent?:
            return .none
        case nil, .failed?:
            break
        }
        guard competitionInviteLinkClient.canCreateShareLink() else {
            state.inviteCreations[slot] = InviteCreation(
                recipientID: recipient.id,
                idempotencyKey: competitionInviteLinkClient.makeIdempotencyKey(),
                status: .failed(.unavailable)
            )
            return .none
        }
        // Try Again after a lost connection replays the same request.
        let idempotencyKey: UUID
        if let existing,
           existing.recipientID == recipient.id,
           existing.status == .failed(.connection) {
            idempotencyKey = existing.idempotencyKey
        } else {
            idempotencyKey = competitionInviteLinkClient.makeIdempotencyKey()
        }
        state.inviteCreations[slot] = InviteCreation(
            recipientID: recipient.id,
            idempotencyKey: idempotencyKey,
            status: .creating
        )
        var rematchParentID: CompetitionID?
        if case let .rematch(of: parentID) = slot { rematchParentID = parentID }
        let timeZoneIdentifier = competitionInviteLinkClient
            .currentTimeZoneIdentifier()
        return .run { send in
            do {
                let request = try CompetitionInviteCreationRequest(
                    recipientProfileID: recipient.id,
                    timeZoneIdentifier: timeZoneIdentifier,
                    rematchParentID: rematchParentID?.rawValue,
                    idempotencyKey: idempotencyKey
                )
                let outcome = try await competitionClient.createInvite(
                    request
                )
                guard let link = competitionInviteLinkClient
                    .makeShareLink(outcome.invite.token)
                else {
                    await send(
                        .createInviteResponse(
                            slot,
                            idempotencyKey: idempotencyKey,
                            .configurationUnavailable
                        )
                    )
                    return
                }
                await send(
                    .createInviteResponse(
                        slot,
                        idempotencyKey: idempotencyKey,
                        .success(
                            link: link,
                            competitionID: CompetitionID(
                                outcome.invite.competitionID
                            ),
                            expectedRevision: outcome
                                .expectedPublicationRevision
                        )
                    )
                )
            } catch let failure as CompetitionRemoteFailure {
                await send(
                    .createInviteResponse(
                        slot,
                        idempotencyKey: idempotencyKey,
                        .failure(failure)
                    )
                )
            } catch is CancellationError {
                return
            } catch {
                await send(
                    .createInviteResponse(
                        slot,
                        idempotencyKey: idempotencyKey,
                        .failure(.operationFailed)
                    )
                )
            }
        }
        .cancellable(
            id: CancelID.inviteCreation,
            cancelInFlight: false
        )
    }
}

extension CompetitionFeature.State {
    /// The sheet can't change person once its challenge is being created or sent.
    var isChallengeSheetLocked: Bool {
        switch inviteCreations[.sheet]?.status {
        case .creating?, .sent?: true
        case nil, .failed?: false
        }
    }

    /// A pending outgoing challenge to this person. After PR 4 the remote
    /// dashboard never carries a lapsed pending challenge, so no expiry check.
    func pendingOutgoingChallenge(
        to opponentIdentity: String
    ) -> LocalCompetitionPresentation? {
        guard let publication, publication.source == .remoteParticipants else {
            return nil
        }
        return publication.dashboard.competitions.first {
            guard case .pending(.outgoing, _, _) = $0.lifecycle else { return false }
            return $0.opponentIdentity == opponentIdentity
        }
    }

    var challengeSheetStatus: CompetitionFeature.ChallengeSheetStatus {
        let creation = inviteCreations[.sheet]
        if creation?.status == .creating { return .creating }
        if case let .sent(id)? = creation?.status {
            var link: CompetitionInviteShareLink?
            if case let .ready(ready, _)? = inviteLinks[id] { link = ready }
            return .sent(
                challengeID: id,
                challenge: publication?.dashboard.competitions.first { $0.id == id },
                link: link
            )
        }
        if let inviteRecipient {
            let identity = RemoteCompetitionOpponentIdentity.identity(for: inviteRecipient.id)
            if let existing = pendingOutgoingChallenge(to: identity) {
                return .alreadyChallenged(existing)
            }
            if let incoming = incomingChallenge(from: identity) {
                return .challengedYou(incoming)
            }
            if let match = matchInProgress(with: identity) {
                return .inMatch(match)
            }
        }
        if case let .failed(failure)? = creation?.status { return .failed(failure) }
        return .ready
    }

    /// Their pending challenge to you.
    func incomingChallenge(from opponentIdentity: String) -> LocalCompetitionPresentation? {
        guard let publication, publication.source == .remoteParticipants else { return nil }
        return publication.dashboard.competitions.first {
            guard case .pending(.incoming, _, _) = $0.lifecycle else { return false }
            return $0.opponentIdentity == opponentIdentity
        }
    }

    /// A match with them whose week hasn't ended, earliest start first.
    /// Tallying doesn't count, matching the server.
    func matchInProgress(with opponentIdentity: String) -> LocalCompetitionPresentation? {
        guard let publication, publication.source == .remoteParticipants else { return nil }
        return publication.dashboard.competitions.filter {
            switch $0.lifecycle {
            case .scheduled, .active, .endsToday:
                return $0.opponentIdentity == opponentIdentity
            default:
                return false
            }
        }.min {
            let lhs = $0.acceptedConfiguration.flatMap { competitionScheduleBoundaries($0.schedule)?.start }
                ?? .distantFuture
            let rhs = $1.acceptedConfiguration.flatMap { competitionScheduleBoundaries($0.schedule)?.start }
                ?? .distantFuture
            return lhs < rhs
        }
    }

    func rematchState(
        for parent: LocalCompetitionPresentation
    ) -> CompetitionFeature.CompetitionRematchState {
        let children = (publication?.dashboard.competitions ?? []).filter {
            guard $0.rematchParentID == parent.id else { return false }
            switch $0.lifecycle {
            // A closed child counts as no child; Home already shows how it closed.
            case .declined, .expired, .cancelled: return false
            default: return true
            }
        }
        func isUnderway(_ c: LocalCompetitionPresentation) -> Bool {
            switch c.lifecycle {
            case .scheduled, .active, .endsToday, .tallying: true
            default: false
            }
        }
        func isPendingChild(_ c: LocalCompetitionPresentation, _ direction: InvitationDirection) -> Bool {
            if case .pending(direction, _, _) = c.lifecycle { return true }
            return false
        }
        // Either person can rematch; only your own pending rematch has a link here.
        if let child = children.first(where: { isPendingChild($0, .outgoing) })
            ?? children.first(where: { isPendingChild($0, .incoming) })
            ?? children.first(where: isUnderway)
            ?? children.first {
            switch child.lifecycle {
            case let .pending(.outgoing, _, expiresAt):
                return .sent(
                    challengeID: child.id,
                    expiresAt: expiresAt,
                    link: inviteLinks[child.id]
                )
            case .pending(.incoming, _, _):
                return .received(child)
            default:
                return .next(child)
            }
        }
        guard publication?.source == .remoteParticipants else {
            return isCommandInFlight(parent.id) ? .sending : .available
        }
        let creation = inviteCreations[.rematch(of: parent.id)]
        switch creation?.status {
        case .creating?:
            return .sending
        case let .sent(id)?:
            return .sent(challengeID: id, expiresAt: nil, link: inviteLinks[id])
        case nil, .failed?:
            break
        }
        if let existing = pendingOutgoingChallenge(to: parent.opponentIdentity) {
            return .alreadyChallenged(existing)
        }
        if let match = matchInProgress(with: parent.opponentIdentity) {
            return .inMatch(match)
        }
        if let incoming = incomingChallenge(from: parent.opponentIdentity) {
            return .challengedYou(incoming)
        }
        if case let .failed(failure)? = creation?.status { return .failed(failure) }
        return .available
    }
}

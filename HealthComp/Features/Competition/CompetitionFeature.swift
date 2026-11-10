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

        var recipient: CompetitionInviteRecipient
        var idempotencyKey: UUID
        var status: Status
    }

    enum InviteLinkState: Equatable, Sendable {
        case loading
        case ready(CompetitionInviteShareLink, minimumRevision: UInt64)
        case notOnThisPhone
        case failed
    }

    /// The + sheet's person. Someone found by their challenge link is kept
    /// as the link's code: the link never gives out their account id.
    struct InviteRecipient: Equatable, Sendable {
        let target: CompetitionInviteRecipient
        let displayName: String

        init(_ profile: AuthenticatedProfile) {
            target = .profile(profile.id)
            displayName = profile.displayName
        }

        init(link code: CompetitionChallengeLinkCode, displayName: String) {
            target = .challengeLink(code)
            self.displayName = displayName
        }

        /// Only an account id lets the sheet see an existing challenge or
        /// match first; for a link, the server says so on Send.
        var profileID: UUID? {
            if case let .profile(id) = target { id } else { nil }
        }
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

    enum NudgeStatus: Equatable, Sendable {
        case sending
        case sent(Date)
        case failed
        /// The server said no: they updated, or the result no longer waits on them.
        case notNeeded(Date)
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
        var inviteRecipient: InviteRecipient?
        var inviteRecipientCode = ""
        var inviteRecipientStatus: InviteRecipientStatus = .idle
        /// The signed-in profile, so Home can draw its initial.
        var ownProfile: AuthenticatedProfile?
        /// Your reusable challenge link, once loaded.
        var challengeLink: URL?
        var challengeLinkLoadFailed = false
        var challengeLinkIsResetting = false
        var challengeLinkResetFailed = false
        /// People you blocked, newest first; nil until Account loads them.
        var blockedPeople: [AuthenticatedProfile]?
        var unblocksInFlight: Set<UUID> = []
        /// The person whose last Unblock failed; the error shows in their row.
        var unblockFailed: UUID?
        /// Per match; not persisted.
        var nudges: [CompetitionID: NudgeStatus] = [:]
        /// Reactions being saved: the kind being set, or nil while removing.
        var pendingReactions: [CompetitionReactionKey: CompetitionReactionKind?] = [:]
        var reactionFailures: Set<CompetitionReactionKey> = []
        /// Photos you may see, by profile id; anyone missing shows initials.
        var profilePhotos: [UUID: ProfilePhoto] = [:]
        /// People whose photo you reported on this iPhone.
        var reportedPhotoOwners: Set<UUID> = []
        var photoReportsInFlight: Set<UUID> = []
        var ownPhoto = OwnPhotoState()
        var friendSettings = FriendSettingsFeature.State()
        var friends = FriendsFeature.State()
        var group = GroupMatchFeature.State()

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
            inviteRecipient: InviteRecipient? = nil,
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

        /// What `PersonAvatar` reads from the environment.
        var profilePhotoImages: ProfilePhotoImages {
            ProfilePhotoImages(ownID: ownProfile?.id, photos: profilePhotos)
        }

        var photoOwners: [UUID] { photoOwners(claimSender: nil) }

        /// You, the sender of a challenge being claimed (they sent it to
        /// you, so you may see theirs), everyone on a real match or group
        /// match, your Friends lists and the search results, sorted so it
        /// can key a task.
        func photoOwners(claimSender: UUID?) -> [UUID] {
            guard publication?.source == .remoteParticipants else {
                return claimSender.map { [$0] } ?? []
            }
            // Most likely on screen first. Separate statements: as one
            // expression, Xcode 16's compiler gives up type-checking it.
            var owners: [UUID] = []
            if let id = ownProfile?.id { owners.append(id) }
            if let claimSender { owners.append(claimSender) }
            let results: [FriendPerson] = friends.results ?? []
            owners += results.map(\.id)
            let list: FriendsList = friends.list ?? FriendsList()
            owners += list.incoming.map(\.id)
            let competitions: [LocalCompetitionPresentation] = publication?.dashboard.competitions ?? []
            owners += competitions.compactMap(\.opponentProfileID)
            let groupMatches: [GroupMatchPresentation] = publication?.dashboard.groupMatches ?? []
            owners += groupMatches.flatMap { $0.seats.compactMap(\.profileID) }
            owners += list.friends.map(\.id)
            owners += list.outgoing.map(\.id)
            // ponytail: past 200 people the rest stay initials; page the
            // lookup if anyone gets there.
            var seen: Set<UUID> = []
            return owners.filter { seen.insert($0).inserted }
                .prefix(CompetitionFeature.maxPhotoOwners)
                .sorted { $0.uuidString < $1.uuidString }
        }

        /// One match's reaction state, for its match and result screens.
        func reactionControl(
            for id: CompetitionID,
            send: @escaping (Action) -> Void
        ) -> CompetitionReactionControl {
            CompetitionReactionControl(
                pending: Dictionary(uniqueKeysWithValues: pendingReactions
                    .filter { $0.key.competitionID == id }
                    .map { ($0.key.target, $0.value) }),
                failed: Set(reactionFailures.filter { $0.competitionID == id }.map(\.target)),
                react: { send(.reactionTapped(id, $0, $1)) }
            )
        }
    }

    /// Your photo in Account: saving or removing it, and why it's gone.
    struct OwnPhotoState: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case idle, saving, saveFailed, removing, removeFailed
        }

        var status: Status = .idle
        /// A reviewer removed your last photo; cleared once you set or remove one.
        var removedByReview = false
    }

    enum Action: Equatable, Sendable {
        case task
        case publication(CompetitionPublication)
        case inviteRecipientCodeChanged(String)
        case findInviteRecipientTapped
        /// The trimmed input that was looked up, and its answer.
        case inviteRecipientResponse(String, Result<InviteRecipient, CompetitionRemoteFailure>)
        /// Someone's challenge link resolved: prefill the + sheet's person.
        case challengeRecipientChosen(InviteRecipient)
        case cancelTapped(CompetitionID)
        case nudgeTapped(CompetitionID)
        case nudgeResponse(
            CompetitionID,
            tappedAt: Date,
            Result<Date, CompetitionRemoteFailure>
        )
        case reactionTapped(CompetitionID, CompetitionReactionTarget, CompetitionReactionKind)
        case reactionFinished(CompetitionReactionKey, succeeded: Bool)
        case challengeLinkRequested
        case challengeLinkResponse(URL?)
        /// Reset Link, after its confirmation.
        case challengeLinkResetConfirmed
        case challengeLinkResetResponse(URL?)
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
        /// Decline and block the sender.
        case blockTapped(CompetitionID)
        case blockedPeopleRequested
        case blockedPeopleResponse([AuthenticatedProfile]?)
        case unblockTapped(UUID)
        case unblockFinished(UUID, succeeded: Bool)
        case archiveTapped(CompetitionID)
        case rematchTapped(CompetitionID)
        case challengeAgainTapped(CompetitionID)
        case reinviteTapped
        case practiceStartTapped(OpponentDifficulty)
        case deleteTapped(CompetitionID)
        case commandFinished(CompetitionID, expectedRevision: UInt64)
        case mutePreferencesLoaded(Set<String>?)
        case muteTapped(String)
        case muteFinished(String, isMuted: Bool, succeeded: Bool)
        case notificationAuthorizationLoaded(
            CompetitionNotificationAuthorizationState
        )
        case enableNotificationsTapped
        case notificationChoicesChanged
        case notificationAuthorizationRequestFinished(
            CompetitionNotificationAuthorizationState
        )
        case pullToRefresh
        case sceneBecameActive
        case timeZoneChanged
        case stop
        /// Shown people's photos: this iPhone's cache first, then the server.
        case profilePhotosNeeded([UUID])
        case profilePhotosListed(
            owners: [UUID],
            visible: [ProfilePhotoReference],
            reported: Set<UUID>
        )
        case profilePhotoLoaded(UUID, ProfilePhoto)
        case ownPhotoRequested
        case ownPhotoLoaded(OwnProfilePhoto)
        /// A `ProfilePhotoImage.jpeg(from:crop:)` result.
        case ownPhotoSaveTapped(Data)
        case ownPhotoSaveFinished(ProfilePhoto?)
        /// Move and Scale closed without saving.
        case ownPhotoCropClosed
        case ownPhotoRemoveConfirmed
        case ownPhotoRemoveFinished(succeeded: Bool)
        case photoReportConfirmed(UUID)
        case photoReportFinished(UUID, succeeded: Bool)
        case friendSettings(FriendSettingsFeature.Action)
        case friends(FriendsFeature.Action)
        case group(GroupMatchFeature.Action)
    }

    /// `list_profile_photos` takes at most this many ids.
    static let maxPhotoOwners = 200

    @Dependency(\.competitionClient) var competitionClient
    @Dependency(\.competitionInviteLinkClient) var competitionInviteLinkClient

    private enum CancelID {
        case publications
        case inviteCreation
        case inviteRecipient
        case inviteLink
        case challengeLink
        case challengeLinkReset
        case blockedPeople
        case nudge
        case reaction
        case profilePhotos
        case ownPhoto
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.friendSettings, action: \.friendSettings) { FriendSettingsFeature() }
        Scope(state: \.friends, action: \.friends) { FriendsFeature() }
        Scope(state: \.group, action: \.group) {
            GroupMatchFeature()
        }
        Reduce { state, action in
            switch action {
            // A list load already running may have read before this block
            // and would bring nobody back, so it's dropped as Unblock does.
            case .friends(.blockTapped):
                return .cancel(id: CancelID.blockedPeople)

            case let .friends(.blockFinished(_, .success(profile))):
                // Unknown stays unknown until the list loads.
                state.blockedPeople = state.blockedPeople.map { [profile] + $0.filter { $0.id != profile.id } }
                let owners = state.photoOwners
                return .merge(
                    state.blockedPeople == nil ? .send(.blockedPeopleRequested) : .none,
                    // The server cancelled any challenge between you.
                    reconcile(trigger: .pullToRefresh),
                    // It hides their photo now, as for Decline and Block.
                    owners.isEmpty ? .none : .send(.profilePhotosNeeded(owners))
                )

            case .friends(.blockFinished(_, .failure)):
                // A connection lost after sending may hide a block the server
                // applied: ask it rather than assume either way. Friends
                // reloads its list as well.
                return .send(.blockedPeopleRequested)

            case let .group(.delegate(.published(publication))):
                return .send(.publication(publication))

            case .friendSettings, .friends, .group:
                return .none

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
                // Each realtime wakeup publishes, so a request sent or
                // answered elsewhere reaches the badge and lists here too.
                let friendsInUse = state.friends.list != nil || state.friends.loadFailed
                guard publication.source == .remoteParticipants, friendsInUse else { return .none }
                return .send(.friends(.requested))

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
                let lookup: @Sendable () async throws -> InviteRecipient
                var expectedID: UUID?
                if let code = Self.challengeLinkCode(in: input) {
                    lookup = { [competitionClient] in
                        InviteRecipient(
                            link: code,
                            displayName: try await competitionClient.resolveChallengeLink(code)
                        )
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
                        InviteRecipient(try await competitionClient.resolveInviteRecipient(id))
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
                        guard expectedID.map({ $0 == recipient.profileID }) ?? true else {
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
                case let .success(recipient)
                    where recipient.profileID != nil && recipient.profileID == state.ownProfile?.id:
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
                state.inviteRecipientCode = switch recipient.target {
                case let .profile(id): id.uuidString.lowercased()
                case let .challengeLink(code): code.rawValue
                }
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

            case let .nudgeTapped(id):
                guard state.nudges[id] != .sending else { return .none }
                state.nudges[id] = .sending
                let tappedAt = state.publication?.dashboard.competitions
                    .first { $0.id == id }?.evaluatedAt ?? .distantPast
                return .run { send in
                    let result: Result<Date, CompetitionRemoteFailure>
                    do {
                        result = .success(try await competitionClient.nudge(id))
                    } catch {
                        result = .failure(
                            (error as? CompetitionRemoteFailure) ?? .operationFailed
                        )
                    }
                    await send(.nudgeResponse(id, tappedAt: tappedAt, result))
                }
                // No cancelInFlight: nudges for two matches can both run.
                .cancellable(id: CancelID.nudge)

            case let .reactionTapped(id, target, kind):
                let key = CompetitionReactionKey(competitionID: id, target: target)
                guard state.pendingReactions[key] == nil,
                      let competition = state.publication?.dashboard.competitions
                        .first(where: { $0.id == id })
                else { return .none }
                // The same preset again removes it.
                let next: CompetitionReactionKind? =
                    competition.ownReaction(target)?.kind == kind ? nil : kind
                // Must be .some: assigning nil would remove the key.
                state.pendingReactions[key] = .some(next)
                state.reactionFailures.remove(key)
                return .run { send in
                    do {
                        let publication = try await competitionClient.setReaction(id, target, next)
                        // Before finishing, so the chip never flickers back.
                        await send(.publication(publication))
                        await send(.reactionFinished(key, succeeded: true))
                    } catch {
                        await send(.reactionFinished(key, succeeded: false))
                    }
                }
                .cancellable(id: CancelID.reaction)

            case let .reactionFinished(key, succeeded):
                state.pendingReactions[key] = nil
                if !succeeded { state.reactionFailures.insert(key) }
                return .none

            case let .nudgeResponse(id, tappedAt, result):
                switch result {
                case let .success(nudgedAt):
                    state.nudges[id] = .sent(nudgedAt)
                case .failure(.forbidden), .failure(.notFound):
                    state.nudges[id] = .notNeeded(tappedAt)
                    // Not .pullToRefresh: Staging wraps that in operator capture.
                    return reconcile(trigger: .foreground)
                case .failure:
                    state.nudges[id] = .failed
                }
                return .none

            // Loaded each time it's shown, so a reset on another iPhone
            // shows here too. A reset in flight answers for itself.
            case .challengeLinkRequested:
                guard !state.challengeLinkIsResetting else { return .none }
                state.challengeLinkLoadFailed = false
                return .run { send in
                    let code = try? await competitionClient.loadChallengeLinkCode()
                    await send(.challengeLinkResponse(
                        code.flatMap(competitionInviteLinkClient.makeChallengeLink)
                    ))
                }
                .cancellable(id: CancelID.challengeLink, cancelInFlight: true)

            // A failed refresh keeps the link already shown. A different
            // link means a reset that looked failed did happen.
            case let .challengeLinkResponse(url):
                if let url, url != state.challengeLink {
                    state.challengeLink = url
                    state.challengeLinkResetFailed = false
                }
                state.challengeLinkLoadFailed = state.challengeLink == nil
                return .none

            case .challengeLinkResetConfirmed:
                guard !state.challengeLinkIsResetting else { return .none }
                state.challengeLinkIsResetting = true
                state.challengeLinkResetFailed = false
                return .merge(
                    // A load started before the reset could bring back the old code.
                    .cancel(id: CancelID.challengeLink),
                    .run { send in
                        let code = try? await competitionClient.resetChallengeLinkCode()
                        await send(.challengeLinkResetResponse(
                            code.flatMap(competitionInviteLinkClient.makeChallengeLink)
                        ))
                    }
                    .cancellable(id: CancelID.challengeLinkReset, cancelInFlight: true)
                )

            // A failed reset may still have happened on the server, so the
            // link is loaded again to show what the server has.
            case let .challengeLinkResetResponse(url):
                state.challengeLinkIsResetting = false
                state.challengeLinkResetFailed = url == nil
                guard let url else { return .send(.challengeLinkRequested) }
                state.challengeLink = url
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
                    // A friend, Challenge Again or an id: the person is known,
                    // so only a link that found them can be wrong.
                    guard slot == .sheet, state.inviteRecipient?.profileID == nil else {
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

            case let .blockTapped(id):
                guard state.commandIDsInFlight.insert(id).inserted else {
                    return .none
                }
                let owners = state.photoOwners
                return .run { send in
                    let returned = await competitionClient.block(id)
                    await send(
                        .commandFinished(
                            id,
                            expectedRevision: returned.publicationRevision
                        )
                    )
                    // The server hides their photo now; a fresh lookup drops
                    // it here and from the disk cache.
                    if !owners.isEmpty {
                        await send(.profilePhotosNeeded(owners))
                    }
                }

            case .blockedPeopleRequested:
                state.unblockFailed = nil
                return .run { send in
                    await send(.blockedPeopleResponse(
                        try? await competitionClient.loadBlockedProfiles()
                    ))
                }
                .cancellable(id: CancelID.blockedPeople, cancelInFlight: true)

            case let .blockedPeopleResponse(people):
                // A failed refresh keeps whatever was shown.
                if let people { state.blockedPeople = people }
                return .none

            case let .unblockTapped(id):
                guard state.unblocksInFlight.insert(id).inserted else {
                    return .none
                }
                state.unblockFailed = nil
                // A list load already running may have read before this
                // unblock and would bring the row back, so it's dropped.
                // Not cancellable: the server call finishes.
                return .merge(
                    .cancel(id: CancelID.blockedPeople),
                    .run { send in
                        let succeeded = (try? await competitionClient.unblock(id)) != nil
                        await send(.unblockFinished(id, succeeded: succeeded))
                    }
                )

            case let .unblockFinished(id, succeeded):
                // stop clears the set, so a late result never marks the next account.
                guard state.unblocksInFlight.remove(id) != nil else { return .none }
                if succeeded {
                    state.blockedPeople?.removeAll { $0.id == id }
                } else {
                    state.unblockFailed = id
                }
                return .none

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
                        recipient: InviteRecipient(AuthenticatedProfile(
                            id: profileID,
                            displayName: parent.opponentDisplayName
                        ))
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
                state.inviteRecipient = InviteRecipient(
                    AuthenticatedProfile(id: profileID, displayName: parent.opponentDisplayName)
                )
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

            case let .practiceStartTapped(difficulty):
                let id = PracticeMatch.startCommandID
                guard state.commandIDsInFlight.insert(id).inserted else {
                    return .none
                }
                return .run { send in
                    let returned = await competitionClient.startPractice(difficulty)
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

            case .notificationChoicesChanged:
                // Replans with the new switches, ends a switched-off Live
                // Activity and re-registers the installation.
                return .run { _ in
                    await competitionClient.reconcileNotifications()
                }

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
                    ),
                    // Only a link already shown is refreshed.
                    state.challengeLink == nil ? .none : .send(.challengeLinkRequested)
                )

            case .timeZoneChanged:
                return reconcile(trigger: .timeZoneChange)

            case .stop:
                state.group = GroupMatchFeature.State()
                state.inviteCreations = [:]
                state.inviteLinks = [:]
                state.inviteRecipient = nil
                state.inviteRecipientCode = ""
                state.inviteRecipientStatus = .idle
                state.challengeLink = nil
                state.challengeLinkLoadFailed = false
                state.challengeLinkIsResetting = false
                state.challengeLinkResetFailed = false
                state.blockedPeople = nil
                state.unblocksInFlight = []
                state.unblockFailed = nil
                state.nudges = [:]
                state.pendingReactions = [:]
                state.reactionFailures = []
                state.profilePhotos = [:]
                state.reportedPhotoOwners = []
                state.photoReportsInFlight = []
                state.ownPhoto = OwnPhotoState()
                state.friendSettings = FriendSettingsFeature.State()
                state.friends = FriendsFeature.State()
                return .concatenate(
                    .merge(
                        .cancel(id: FriendsFeature.CancelID.load),
                        .cancel(id: FriendsFeature.CancelID.search),
                        .cancel(id: FriendsFeature.CancelID.change),
                        .cancel(id: FriendsFeature.CancelID.safety),
                        .cancel(id: FriendSettingsFeature.CancelID.load),
                        .cancel(id: FriendSettingsFeature.CancelID.save),
                        .cancel(id: FriendSettingsFeature.CancelID.availability),
                        .cancel(id: CancelID.profilePhotos),
                        .cancel(id: CancelID.ownPhoto),
                        .cancel(id: CancelID.reaction),
                        .cancel(id: CancelID.publications),
                        .cancel(id: CancelID.inviteRecipient),
                        .cancel(id: CancelID.inviteCreation),
                        .cancel(id: CancelID.inviteLink),
                        .cancel(id: CancelID.challengeLink),
                        .cancel(id: CancelID.challengeLinkReset),
                        .cancel(id: CancelID.blockedPeople),
                        .cancel(id: CancelID.nudge),
                        .cancel(id: GroupMatchFeature.CancelID.commands)
                    ),
                    .run { _ in await competitionClient.stop() }
                )

            case let .profilePhotosNeeded(owners):
                guard !owners.isEmpty else { return .none }
                let missing = owners.filter { state.profilePhotos[$0] == nil }
                let versions = state.profilePhotos.compactMapValues(\.version)
                // Each lookup replaces the last. A failure leaves initials
                // and tries again next time.
                return .run { send in
                    for owner in missing {
                        if let data = await competitionClient.cachedProfilePhotoData(owner),
                           let photo = ProfilePhoto(jpeg: data, version: nil) {
                            await send(.profilePhotoLoaded(owner, photo))
                        }
                    }
                    guard let visible = try? await competitionClient.loadProfilePhotos(owners) else {
                        return
                    }
                    let shown = Set(visible.map(\.ownerProfileID))
                    var reported: Set<UUID> = []
                    for owner in owners where !shown.contains(owner) {
                        if await competitionClient.isProfilePhotoReported(owner) {
                            reported.insert(owner)
                        }
                    }
                    await send(.profilePhotosListed(owners: owners, visible: visible, reported: reported))
                    for reference in visible where versions[reference.ownerProfileID] != reference.version {
                        guard let data = try? await competitionClient.profilePhotoData(reference),
                              let photo = ProfilePhoto(jpeg: data, version: reference.version)
                        else { continue }
                        await send(.profilePhotoLoaded(reference.ownerProfileID, photo))
                    }
                }
                .cancellable(id: CancelID.profilePhotos, cancelInFlight: true)

            case let .profilePhotosListed(owners, visible, reported):
                // Removed, blocked, reported or no longer shared: back to the initial.
                let shown = Set(visible.map(\.ownerProfileID))
                for owner in owners where !shown.contains(owner) {
                    state.profilePhotos[owner] = nil
                }
                state.reportedPhotoOwners.formUnion(reported)
                return .none

            case let .profilePhotoLoaded(owner, photo):
                guard !state.reportedPhotoOwners.contains(owner) else { return .none }
                state.profilePhotos[owner] = photo
                return .none

            case .ownPhotoRequested:
                return .run { send in
                    if let own = try? await competitionClient.loadOwnProfilePhoto() {
                        await send(.ownPhotoLoaded(own))
                    }
                }
                .cancellable(id: CancelID.ownPhoto)

            case let .ownPhotoLoaded(own):
                state.ownPhoto.removedByReview = own.removedByReview
                if own.reference == nil, let id = state.ownProfile?.id {
                    state.profilePhotos[id] = nil
                }
                return .none

            case let .ownPhotoSaveTapped(jpeg):
                guard state.ownPhoto.status != .saving, state.ownPhoto.status != .removing else {
                    return .none
                }
                state.ownPhoto.status = .saving
                return .run { send in
                    let reference = try? await competitionClient.setProfilePhoto(jpeg)
                    await send(.ownPhotoSaveFinished(
                        reference.flatMap { ProfilePhoto(jpeg: jpeg, version: $0.version) }
                    ))
                }
                .cancellable(id: CancelID.ownPhoto)

            case let .ownPhotoSaveFinished(photo):
                guard state.ownPhoto.status == .saving else { return .none }
                guard let photo, let id = state.ownProfile?.id else {
                    state.ownPhoto.status = .saveFailed
                    return .none
                }
                state.profilePhotos[id] = photo
                state.ownPhoto = OwnPhotoState()
                return .none

            case .ownPhotoCropClosed:
                if state.ownPhoto.status == .saveFailed { state.ownPhoto.status = .idle }
                return .none

            case .ownPhotoRemoveConfirmed:
                guard state.ownPhoto.status != .saving, state.ownPhoto.status != .removing else {
                    return .none
                }
                state.ownPhoto.status = .removing
                return .run { send in
                    let succeeded = (try? await competitionClient.removeProfilePhoto()) != nil
                    await send(.ownPhotoRemoveFinished(succeeded: succeeded))
                }
                .cancellable(id: CancelID.ownPhoto)

            case let .ownPhotoRemoveFinished(succeeded):
                guard state.ownPhoto.status == .removing else { return .none }
                guard succeeded else {
                    state.ownPhoto.status = .removeFailed
                    return .none
                }
                if let id = state.ownProfile?.id { state.profilePhotos[id] = nil }
                state.ownPhoto = OwnPhotoState()
                return .none

            case let .photoReportConfirmed(owner):
                guard !state.reportedPhotoOwners.contains(owner),
                      state.photoReportsInFlight.insert(owner).inserted
                else { return .none }
                // Not cancellable: the server call finishes.
                return .run { send in
                    let succeeded = (try? await competitionClient.reportProfilePhoto(owner)) != nil
                    await send(.photoReportFinished(owner, succeeded: succeeded))
                }

            case let .photoReportFinished(owner, succeeded):
                // stop clears the set, so a late result never marks the next account.
                guard state.photoReportsInFlight.remove(owner) != nil else { return .none }
                if succeeded {
                    state.profilePhotos[owner] = nil
                    state.reportedPhotoOwners.insert(owner)
                }
                return .none
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
        recipient: InviteRecipient?
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
                recipient: recipient.target,
                idempotencyKey: competitionInviteLinkClient.makeIdempotencyKey(),
                status: .failed(.unavailable)
            )
            return .none
        }
        // Try Again after a lost connection replays the same request.
        let idempotencyKey: UUID
        if let existing,
           existing.recipient == recipient.target,
           existing.status == .failed(.connection) {
            idempotencyKey = existing.idempotencyKey
        } else {
            idempotencyKey = competitionInviteLinkClient.makeIdempotencyKey()
        }
        state.inviteCreations[slot] = InviteCreation(
            recipient: recipient.target,
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
                    recipient: recipient.target,
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
        if let profileID = inviteRecipient?.profileID {
            let identity = RemoteCompetitionOpponentIdentity.identity(for: profileID)
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

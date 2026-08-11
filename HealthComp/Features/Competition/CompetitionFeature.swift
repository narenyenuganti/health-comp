import CompetitionCore
import ComposableArchitecture

@Reducer
struct CompetitionFeature {
    @ObservableState
    struct State: Equatable {
        var publication: LocalCompetitionPublication?
        var commandIDsInFlight: Set<CompetitionID>
        var commandExpectedPublicationRevisions: [CompetitionID: UInt64]
        var mutedOpponentIdentities: Set<String>
        var muteOpponentIdentitiesInFlight: Set<String>
        var notificationPreferenceSaveFailed: Bool
        var notificationAuthorizationState:
            CompetitionNotificationAuthorizationState?
        var notificationAuthorizationRequestIsInFlight: Bool

        init(
            publication: LocalCompetitionPublication? = nil,
            commandIDsInFlight: Set<CompetitionID> = [],
            commandExpectedPublicationRevisions: [CompetitionID: UInt64] = [:],
            mutedOpponentIdentities: Set<String> = [],
            muteOpponentIdentitiesInFlight: Set<String> = [],
            notificationPreferenceSaveFailed: Bool = false,
            notificationAuthorizationState:
                CompetitionNotificationAuthorizationState? = nil,
            notificationAuthorizationRequestIsInFlight: Bool = false
        ) {
            self.publication = publication
            self.commandIDsInFlight = commandIDsInFlight
            self.commandExpectedPublicationRevisions =
                commandExpectedPublicationRevisions
            self.mutedOpponentIdentities = mutedOpponentIdentities
            self.muteOpponentIdentitiesInFlight =
                muteOpponentIdentitiesInFlight
            self.notificationPreferenceSaveFailed =
                notificationPreferenceSaveFailed
            self.notificationAuthorizationState =
                notificationAuthorizationState
            self.notificationAuthorizationRequestIsInFlight =
                notificationAuthorizationRequestIsInFlight
        }

        func isCommandInFlight(_ id: CompetitionID) -> Bool {
            commandIDsInFlight.contains(id)
        }
    }

    enum Action: Equatable, Sendable {
        case task
        case publication(LocalCompetitionPublication)
        case acceptTapped(CompetitionID)
        case declineTapped(CompetitionID)
        case archiveTapped(CompetitionID)
        case rematchTapped(CompetitionID)
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

    @Dependency(\.localCompetitionClient) var localCompetitionClient

    private enum CancelID {
        case publications
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                let currentMutedIdentities = state.mutedOpponentIdentities
                let currentAuthorization = state.notificationAuthorizationState
                return .merge(
                    .run { send in
                        for await publication in localCompetitionClient.start() {
                            guard !Task.isCancelled else { return }
                            await send(.publication(publication))
                        }
                    }
                    .cancellable(
                        id: CancelID.publications,
                        cancelInFlight: true
                    ),
                    .run { send in
                        do {
                            let loaded = try await localCompetitionClient
                                .loadMutedOpponentIdentities()
                            if loaded != currentMutedIdentities {
                                await send(.mutePreferencesLoaded(loaded))
                            }
                        } catch {
                            await send(.mutePreferencesLoaded(nil))
                        }
                    },
                    .run { send in
                        guard let loaded = await localCompetitionClient
                            .loadNotificationAuthorizationState(),
                            loaded != currentAuthorization
                        else {
                            return
                        }
                        await send(.notificationAuthorizationLoaded(loaded))
                    }
                )

            case let .publication(publication):
                guard publication.publicationRevision
                    > (state.publication?.publicationRevision ?? 0)
                else {
                    return .none
                }
                state.publication = publication
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

            case let .acceptTapped(id):
                guard state.commandIDsInFlight.insert(id).inserted else {
                    return .none
                }
                return .run { send in
                    let returned = await localCompetitionClient.accept(id)
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
                    let returned = await localCompetitionClient.decline(id)
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
                    let returned = await localCompetitionClient.archive(id)
                    await send(
                        .commandFinished(
                            id,
                            expectedRevision: returned.publicationRevision
                        )
                    )
                }

            case let .rematchTapped(id):
                guard state.commandIDsInFlight.insert(id).inserted else {
                    return .none
                }
                return .run { send in
                    let returned = await localCompetitionClient.rematch(id)
                    await send(
                        .commandFinished(
                            id,
                            expectedRevision: returned.publicationRevision
                        )
                    )
                }

            case .reinviteTapped:
                let id = LocalCompetitionIdentity.bootstrapCompetitionID
                guard state.commandIDsInFlight.insert(id).inserted else {
                    return .none
                }
                return .run { send in
                    let returned = await localCompetitionClient.reinvite()
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
                    let returned = await localCompetitionClient.delete(id)
                    await send(
                        .commandFinished(
                            id,
                            expectedRevision: returned.publicationRevision
                        )
                    )
                }

            case let .mutePreferencesLoaded(identities):
                guard let identities else {
                    state.notificationPreferenceSaveFailed = true
                    return .none
                }
                state.mutedOpponentIdentities = identities
                state.notificationPreferenceSaveFailed = false
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
                state.notificationPreferenceSaveFailed = false
                return .run { send in
                    do {
                        try await localCompetitionClient
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
                guard !succeeded else { return .none }
                if isMuted {
                    state.mutedOpponentIdentities.remove(identity)
                } else {
                    state.mutedOpponentIdentities.insert(identity)
                }
                state.notificationPreferenceSaveFailed = true
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
                            await localCompetitionClient
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
                return reconcile(trigger: .foreground)

            case .timeZoneChanged:
                return reconcile(trigger: .timeZoneChange)

            case .stop:
                return .concatenate(
                    .cancel(id: CancelID.publications),
                    .run { _ in await localCompetitionClient.stop() }
                )
            }
        }
    }

    private func reconcile(
        trigger: ActivityRefreshTrigger
    ) -> Effect<Action> {
        .run { _ in
            _ = await localCompetitionClient.reconcileAll(trigger)
        }
    }
}

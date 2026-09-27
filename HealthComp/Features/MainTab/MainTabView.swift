import CompetitionCore
import ComposableArchitecture
import Foundation
import SwiftUI

struct MainTabView: View {
    let store: StoreOf<MainTabFeature>
    /// Shows the avatar that opens Account. Test Lab hosts omit it.
    var openAccount: (() -> Void)?

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let onboarding = store.onboarding {
                PermissionOnboardingView(
                    step: onboarding.step,
                    isRequesting: onboarding.isRequesting,
                    continueTapped: { store.send(.onboardingContinueTapped) },
                    notNowTapped: { store.send(.onboardingNotNowTapped) }
                )
            } else {
                home
            }
        }
        .task {
            await store.send(.task).finish()
        }
        .onChange(of: scenePhase) { _, newValue in
            store.send(.scenePhaseChanged(Self.sceneState(newValue)))
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name.NSSystemTimeZoneDidChange
            )
        ) { _ in
            store.send(.timeZoneChanged)
        }
        .sheet(isPresented: claimSheetPresented) {
            ClaimCompetitionView(
                status: store.inviteClaimStatus,
                accept: { store.send(.acceptClaimTapped) },
                decline: { store.send(.declineClaimTapped) },
                retry: { store.send(.retryClaimTapped) },
                dismiss: { store.send(.dismissClaimStatus) }
            )
        }
    }

    private var home: some View {
        NavigationStack(path: navigationPath) {
            Group {
                if let publication = store.competition.publication {
                    CompetitionSharingView(
                        publication: publication,
                        inviteCreationStatus: store.competition
                            .inviteCreationRematchParentID == nil
                                ? store.competition.inviteCreationStatus
                                : .idle,
                        createdInviteLink: store.competition
                            .inviteCreationRematchParentID == nil
                                ? store.competition.createdInviteLink
                                : nil,
                        createInvite: {
                            store.send(.competition(.createInviteTapped))
                        },
                        selectCompetition: {
                            store.send(.pathChanged([$0]))
                        },
                        reinvite: {
                            store.send(.competition(.reinviteTapped))
                        },
                        isReinviteInFlight: store.competition
                            .isCommandInFlight(
                                LocalCompetitionIdentity
                                    .bootstrapCompetitionID
                            ),
                        notificationAuthorization: store.competition
                            .notificationAuthorizationState,
                        notificationAuthorizationRequestIsInFlight:
                            store.competition
                                .notificationAuthorizationRequestIsInFlight,
                        requestNotificationAuthorization: {
                            store.send(
                                .competition(.enableNotificationsTapped)
                            )
                        }
                    )
                    .refreshable {
                        await store.send(.competition(.pullToRefresh)).finish()
                    }
                } else {
                    ProgressView("Loading local competition…")
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.ground)
                }
            }
            .toolbar { homeToolbar }
            .navigationDestination(for: CompetitionID.self) { id in
                destination(for: id)
                    .toolbarRole(.editor)
            }
        }
    }

    @ToolbarContentBuilder
    private var homeToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            BrandMark().frame(height: 26)
        }
        if let openAccount {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openAccount) {
                    Group {
                        if let accountInitial {
                            Text(accountInitial)
                                .font(.headline.width(.condensed))
                                .foregroundStyle(Theme.you)
                        } else {
                            Image(systemName: "person.fill")
                                .foregroundStyle(Theme.ink)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .background(Theme.control, in: Circle())
                }
                .accessibilityLabel("Account")
                .accessibilityIdentifier("app.account")
            }
        }
    }

    // Every competition shares the owner's display name.
    private var accountInitial: String? {
        store.competition.publication?.dashboard.competitions.first?
            .ownerDisplayName.first.map { String($0).uppercased() }
    }

    private var navigationPath: Binding<[CompetitionID]> {
        Binding(
            get: { store.path },
            set: { store.send(.pathChanged($0)) }
        )
    }

    private var claimSheetPresented: Binding<Bool> {
        Binding(
            get: { store.inviteClaimStatus != .idle },
            set: { isPresented in
                guard !isPresented else { return }
                switch store.inviteClaimStatus {
                case .ready:
                    store.send(.declineClaimTapped)
                case .retryable:
                    store.send(.dismissRetryableClaim)
                case .unavailable:
                    store.send(.dismissClaimStatus)
                case .confirmationTimedOut:
                    store.send(.dismissClaimStatus)
                case .idle, .claiming, .waitingForCompetition:
                    break
                }
            }
        )
    }

    @ViewBuilder
    private func destination(for id: CompetitionID) -> some View {
        if let publication = store.competition.publication,
           let competition = publication.dashboard.competitions.first(
               where: { $0.id == id }
           ) {
            switch competition.lifecycle {
            case .pending:
                CompetitionInviteView(
                    competition: competition,
                    source: publication.source,
                    isCommandInFlight: store.competition
                        .isCommandInFlight(id),
                    send: sendCompetitionAction
                )

            case .scheduled, .active, .endsToday, .tallying:
                CompetitionDetailView(
                    competition: competition,
                    source: publication.source,
                    muteButton: muteButton(for: competition)
                )

            case .completed, .archived:
                CompetitionResultView(
                    competition: competition,
                    awards: publication.dashboard.awards,
                    source: publication.source,
                    inviteCreationStatus: store.competition
                        .inviteCreationRematchParentID == id
                            ? store.competition.inviteCreationStatus
                            : .idle,
                    createdInviteLink: store.competition
                        .inviteCreationRematchParentID == id
                            ? store.competition.createdInviteLink
                            : nil,
                    isCommandInFlight: store.competition
                        .isCommandInFlight(id),
                    send: sendCompetitionAction,
                    muteButton: muteButton(for: competition)
                )

            case .declined, .expired:
                ContentUnavailableView(
                    "Invitation Closed",
                    systemImage: "person.crop.circle.badge.xmark",
                    description: Text("Return to Sharing to see current competitions.")
                )
            }
        } else {
            ContentUnavailableView(
                "Competition Unavailable",
                systemImage: "exclamationmark.circle",
                description: Text("Return to Sharing to refresh this competition.")
            )
        }
    }

    private func sendCompetitionAction(_ action: CompetitionFeature.Action) {
        store.send(.competition(action))
    }

    private func muteButton(
        for competition: LocalCompetitionPresentation
    ) -> CompetitionMuteButton? {
        guard let identity = competitionMuteIdentity(
            competition,
            authorization: store.competition.notificationAuthorizationState
        ) else {
            return nil
        }
        return CompetitionMuteButton(
            opponentName: competition.opponentDisplayName,
            isMuted: store.competition.mutedOpponentIdentities
                .contains(identity),
            isInFlight: store.competition.muteOpponentIdentitiesInFlight
                .contains(identity),
            saveFailed: store.competition.notificationPreferenceSaveFailed,
            toggle: { store.send(.competition(.muteTapped(identity))) }
        )
    }

    private static func sceneState(
        _ scenePhase: ScenePhase
    ) -> MainTabFeature.SceneState {
        switch scenePhase {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .inactive
        }
    }
}

func competitionPointsText(_ points: Double?) -> String {
    guard let points else { return "--" }
    return points.formatted(.number.precision(.fractionLength(0...1)))
}

import ComposableArchitecture
import SwiftUI

struct AccountSettingsView: View {
    let store: StoreOf<AccountFeature>

    @AppStorage(AppAppearance.storageKey)
    private var appearance = AppAppearance.system

    var body: some View {
        List {
            profileSection
            appearanceSection
            privacySection
            signOutSection
            deleteSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .foregroundStyle(Theme.ink)
        .tint(Theme.ink)
        .navigationTitle("Account")
        .task { store.send(.appeared) }
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if store.isRequestInFlight {
                ProgressView()
                    .tint(Theme.ink)
                    .accessibilityLabel(
                        store.isDeletingAccount
                            ? "Deleting account"
                            : "Saving account changes"
                    )
            }
        }
        .alert(
            "Delete Account?",
            isPresented: Binding(
                get: { store.isDeleteConfirmationPresented },
                set: { isPresented in
                    if !isPresented && store.isDeleteConfirmationPresented {
                        store.send(.deleteAccountConfirmationCancelled)
                    }
                }
            )
        ) {
            Button("Delete Account", role: .destructive) {
                store.send(.deleteAccountConfirmationAccepted)
            }
            .accessibilityIdentifier("account.delete.confirm")
            if store.isBrowserDeletionAvailable {
                Button("Delete with Apple in Browser", role: .destructive) {
                    store.send(.browserDeleteConfirmationAccepted)
                }
                .accessibilityIdentifier("account.delete.browser.confirm")
            }
            Button("Cancel", role: .cancel) {
                store.send(.deleteAccountConfirmationCancelled)
            }
        } message: {
            Text(
                "You will confirm with Sign in with Apple. This permanently deletes your account and cannot be undone."
            )
        }
    }

    private var profileSection: some View {
        Section {
            if store.isEditingDisplayName {
                TextField(
                    "Display name",
                    text: Binding(
                        get: { store.displayName },
                        set: { store.send(.displayNameChanged($0)) }
                    )
                )
                .textContentType(.nickname)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit {
                    store.send(.saveDisplayNameButtonTapped)
                }
                .accessibilityIdentifier("account.settings.display-name")

                HStack(spacing: 12) {
                    Button("Cancel", role: .cancel) {
                        store.send(.cancelDisplayNameButtonTapped)
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button("Save") {
                        store.send(.saveDisplayNameButtonTapped)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier(
                        "account.settings.save-display-name"
                    )
                }
                .disabled(store.isRequestInFlight)
            } else {
                HStack(spacing: 14) {
                    Text(store.displayName.first.map { String($0).uppercased() } ?? "")
                        .font(.title3.weight(.heavy).width(.condensed))
                        .foregroundStyle(Theme.you)
                        .frame(width: 44, height: 44)
                        .background(Theme.control, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.displayName)
                            .font(.title3.weight(.bold).width(.condensed))
                            .foregroundStyle(Theme.you)
                            .multilineTextAlignment(.leading)
                        Text("Display name · shown to competitors")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Display name, \(store.displayName)"
                )

                Button("Edit Display Name") {
                    store.send(.editDisplayNameButtonTapped)
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier(
                    "account.settings.edit-display-name"
                )
            }

            if let message = store.message {
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("account.message")
            }
        } header: {
            SectionLabel("PROFILE")
        }
        .listRowBackground(Theme.panel)
    }

    private var appearanceSection: some View {
        Section {
            AppearancePicker(selection: $appearance)
        } header: {
            SectionLabel("APPEARANCE")
        } footer: {
            Text("System follows your iPhone’s setting.")
                .foregroundStyle(Theme.secondary)
        }
        .listRowBackground(Theme.panel)
    }

    private var privacySection: some View {
        Section {
            Label(
                "Raw Health data stays on this iPhone",
                systemImage: "lock.iphone"
            )
            Label(
                "Competitors receive daily points, rounded Activity percentages and modes",
                systemImage: "person.2.shield"
            )
        } header: {
            SectionLabel("PRIVACY")
        }
        .listRowBackground(Theme.panel)
    }

    // Red means Move, so the destructive actions keep their role but stay neutral.
    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                store.send(.signOutButtonTapped)
            } label: {
                Text("Sign Out").foregroundStyle(Theme.ink)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(store.isRequestInFlight)
            .accessibilityIdentifier("account.sign-out")
            .accessibilityValue(
                store.isRequestInFlight ? "Signing out" : ""
            )
        } footer: {
            Text(
                "Signing out removes this profile’s local competition cache from this device. Completed shared history remains on the server."
            )
            .foregroundStyle(Theme.secondary)
        }
        .listRowBackground(Theme.panel)
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                store.send(.deleteAccountButtonTapped)
            } label: {
                Text("Delete Account").foregroundStyle(Theme.ink)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(store.isRequestInFlight)
            .accessibilityIdentifier("account.delete")
            .accessibilityValue(
                store.isDeletingAccount ? "Deleting account" : ""
            )
        } footer: {
            Text(
                "Deletion is permanent. Active competitions are cancelled, this profile’s local data is removed, and completed shared history remains for the other participant as Former competitor."
            )
            .foregroundStyle(Theme.secondary)
        }
        .listRowBackground(Theme.panel)
    }
}

/// System / Light / Dark, each previewed as a tiny Home screen.
private struct AppearancePicker: View {
    @Binding var selection: AppAppearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            ForEach(AppAppearance.allCases) { option in
                Button {
                    selection = option
                } label: {
                    VStack(spacing: 8) {
                        AppearanceThumbnail(
                            option: option,
                            isSelected: selection == option
                        )
                        Text(option.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Image(
                            systemName: selection == option
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.title3)
                        .foregroundStyle(
                            selection == option ? Theme.ink : Theme.tertiary
                        )
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Appearance, \(option.title)")
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(.vertical, 8)
    }
}

private struct AppearanceThumbnail: View {
    let option: AppAppearance
    let isSelected: Bool

    var body: some View {
        Group {
            switch option {
            case .light:
                screen.environment(\.colorScheme, .light)
            case .dark:
                screen.environment(\.colorScheme, .dark)
            case .system:
                HStack(spacing: 0) {
                    screen.environment(\.colorScheme, .light)
                    screen.environment(\.colorScheme, .dark)
                }
            }
        }
        .frame(width: 56, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? Theme.ink : Theme.outline,
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .accessibilityHidden(true)
    }

    // Theme colors resolve against the overridden color scheme.
    private var screen: some View {
        VStack(spacing: 6) {
            BrandMark().frame(width: 22)
            HStack(spacing: 2) {
                SlantedBar().fill(Theme.youFill).frame(width: 12, height: 4)
                SlantedBar().fill(Theme.ink).frame(width: 10, height: 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
    }
}

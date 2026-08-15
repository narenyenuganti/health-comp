import ComposableArchitecture
import SwiftUI

struct AccountSettingsView: View {
    let store: StoreOf<AccountFeature>

    var body: some View {
        List {
            Section("Profile") {
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
                        .frame(maxWidth: .infinity, minHeight: 44)

                        Button("Save") {
                            store.send(.saveDisplayNameButtonTapped)
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier(
                            "account.settings.save-display-name"
                        )
                    }
                    .disabled(store.isRequestInFlight)
                } else {
                    LabeledContent("Display name") {
                        Text(store.displayName)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
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
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("account.message")
                }
            }

            Section("Privacy") {
                Label(
                    "Raw Health data stays on this iPhone",
                    systemImage: "lock.iphone"
                )
                Label(
                    "Competitors receive only daily competition points",
                    systemImage: "person.2.shield"
                )
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    store.send(.signOutButtonTapped)
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
            }

            Section {
                Button("Delete Account", role: .destructive) {
                    store.send(.deleteAccountButtonTapped)
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
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if store.isRequestInFlight {
                ProgressView()
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
            Button("Cancel", role: .cancel) {
                store.send(.deleteAccountConfirmationCancelled)
            }
        } message: {
            Text(
                "You will confirm with Sign in with Apple. This permanently deletes your account and cannot be undone."
            )
        }
    }
}

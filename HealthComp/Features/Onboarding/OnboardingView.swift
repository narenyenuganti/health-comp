import ComposableArchitecture
import SwiftUI

struct OnboardingView: View {
    @Bindable var store: StoreOf<OnboardingFeature>

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Set Up Your Profile")
                        .font(.title.bold())
                    Text("Choose a username and display name to get started.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)

                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Username")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("username", text: $store.username.sending(\.usernameChanged))
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        if let available = store.isUsernameAvailable {
                            Label(
                                available ? "Available" : "Taken",
                                systemImage: available ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(available ? .green : .red)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Display Name")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("Display Name", text: $store.displayName.sending(\.displayNameChanged))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.horizontal, 24)

                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    store.send(.submitTapped)
                } label: {
                    if store.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    } else {
                        Text("Continue")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(store.isSubmitDisabled || store.isLoading)
                .padding(.horizontal, 24)

                Spacer()
            }
        }
    }
}

#Preview {
    OnboardingView(
        store: Store(
            initialState: OnboardingFeature.State(
                userId: UUID()
            )
        ) {
            OnboardingFeature()
        }
    )
}

import AuthenticationServices
import ComposableArchitecture
import SwiftUI

struct AuthView: View {
    let store: StoreOf<AuthFeature>

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "figure.run.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.green)

                Text("HealthComp")
                    .font(.largeTitle.bold())

                Text("Challenge friends. Compete. Get healthier.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 16) {
                if store.isLoading {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { _ in
                        store.send(.signInWithAppleTapped)
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 50)
                    .cornerRadius(12)
                }

                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .onTapGesture {
                            store.send(.dismissErrorTapped)
                        }
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 60)
        }
        .background(Color(.systemBackground))
    }
}

#Preview {
    AuthView(
        store: Store(initialState: AuthFeature.State()) {
            AuthFeature()
        }
    )
}

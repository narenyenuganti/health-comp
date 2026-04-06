import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct ProfileClient: Sendable {
    var isUsernameAvailable: @Sendable (_ username: String) async throws -> Bool
    var createProfile: @Sendable (_ userId: UUID, _ username: String, _ displayName: String) async throws -> User
    var fetchProfile: @Sendable (_ userId: UUID) async throws -> User?
    var updateProfile: @Sendable (_ user: User) async throws -> User
}

extension ProfileClient: TestDependencyKey {
    static let testValue = ProfileClient()
}

extension DependencyValues {
    var profileClient: ProfileClient {
        get { self[ProfileClient.self] }
        set { self[ProfileClient.self] = newValue }
    }
}

// MARK: - Live Implementation

import Supabase

extension ProfileClient: DependencyKey {
    static let liveValue: ProfileClient = {
        let supabase = SupabaseService.shared

        return ProfileClient(
            isUsernameAvailable: { username in
                let available: Bool = try await supabase
                    .rpc("is_username_available", params: ["desired_username": username])
                    .execute()
                    .value
                return available
            },
            createProfile: { userId, username, displayName in
                struct CreatePayload: Encodable {
                    let id: UUID
                    let username: String
                    let display_name: String
                }

                let payload = CreatePayload(
                    id: userId,
                    username: username,
                    display_name: displayName
                )

                let user: User = try await supabase
                    .from("users")
                    .insert(payload)
                    .select()
                    .single()
                    .execute()
                    .value

                return user
            },
            fetchProfile: { userId in
                let user: User? = try? await supabase
                    .from("users")
                    .select()
                    .eq("id", value: userId.uuidString)
                    .single()
                    .execute()
                    .value
                return user
            },
            updateProfile: { user in
                let updated: User = try await supabase
                    .from("users")
                    .update(user)
                    .eq("id", value: user.id.uuidString)
                    .select()
                    .single()
                    .execute()
                    .value
                return updated
            }
        )
    }()
}

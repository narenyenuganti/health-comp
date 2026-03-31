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

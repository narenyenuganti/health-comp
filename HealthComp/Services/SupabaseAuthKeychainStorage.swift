import Foundation
import Security
import Supabase

// Preserve the SDK's namespace and writes, while giving the storage protocol
// precise absence semantics without interpreting private SDK error strings.
struct SupabaseAuthKeychainStorage: AuthLocalStorage {
    private let service: String

    init(service: String = "supabase.gotrue.swift") {
        self.service = service
    }

    func store(key: String, value: Data) throws {
        try KeychainLocalStorage(service: service).store(key: key, value: value)
    }

    func retrieve(key: String) throws -> Data? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return try Self.readResult(status: status, data: result as? Data)
    }

    func remove(key: String) throws {
        try Self.verifyRemovalStatus(SecItemDelete(baseQuery(key: key) as CFDictionary))
    }

    static func readResult(status: OSStatus, data: Data?) throws -> Data? {
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data else {
            throw AuthenticationClientFailure.operationFailed
        }
        return data
    }

    static func verifyRemovalStatus(_ status: OSStatus) throws {
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthenticationClientFailure.operationFailed
        }
    }

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

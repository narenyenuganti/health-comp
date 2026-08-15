import DeviceCheck
import Foundation

struct DeviceCheckAppAttestClient: AppAttestServiceProtocol {
    func isSupported() async -> Bool {
        DCAppAttestService.shared.isSupported
    }

    func generateKey() async throws -> String {
        do {
            return try await DCAppAttestService.shared.generateKey()
        } catch {
            throw Self.failure(error)
        }
    }

    func attestKey(
        _ keyID: String,
        clientDataHash: Data
    ) async throws -> Data {
        do {
            return try await DCAppAttestService.shared.attestKey(
                keyID,
                clientDataHash: clientDataHash
            )
        } catch {
            throw Self.failure(error)
        }
    }

    func generateAssertion(
        _ keyID: String,
        clientDataHash: Data
    ) async throws -> Data {
        do {
            return try await DCAppAttestService.shared.generateAssertion(
                keyID,
                clientDataHash: clientDataHash
            )
        } catch {
            throw Self.failure(error)
        }
    }

    private static func failure(_ error: any Error) -> AppAttestServiceFailure {
        let error = error as NSError
        guard error.domain == DCError.errorDomain else {
            return .operationFailed
        }
        if error.code == DCError.Code.serverUnavailable.rawValue {
            return .serverUnavailable
        }
        if error.code == DCError.Code.invalidKey.rawValue {
            return .invalidKey
        }
        return .operationFailed
    }
}

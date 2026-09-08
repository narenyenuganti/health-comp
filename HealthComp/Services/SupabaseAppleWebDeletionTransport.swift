import Foundation
import Supabase

struct SupabaseAppleWebDeletionTransport: Sendable {
    let provider: SupabaseClientProvider

    func begin(_ request: AppleWebDeletionBeginRequest) async throws -> AppleWebDeletionBeginResponse {
        try Task.checkCancellation()
        return try await provider.client().functions.invoke(
            "apple-deletion-begin",
            options: FunctionInvokeOptions(method: .post, body: request)
        ) { data, response in
            guard response.statusCode == 200, data.count <= 16_384 else {
                throw AppleWebAccountDeletionFailure.invalidResponse
            }
            return try JSONDecoder().decode(AppleWebDeletionBeginResponse.self, from: data)
        }
    }

    func complete(_ request: AppleWebDeletionCompletionRequest) async throws -> AppleWebDeletionReceipt {
        try Task.checkCancellation()
        do {
            return try await provider.client().functions.invoke(
                "apple-deletion-complete",
                options: FunctionInvokeOptions(method: .post, body: request)
            ) { data, response in
                try AppleWebDeletionHTTP.decodeCompletion(statusCode: response.statusCode, data: data)
            }
        } catch let FunctionsError.httpError(code, data) {
            return try AppleWebDeletionHTTP.decodeCompletion(statusCode: code, data: data)
        }
    }
}

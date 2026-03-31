import Supabase
import Foundation

enum SupabaseService {
    /// Shared client — all live dependencies use this single instance
    /// so auth state (session tokens) is consistent across the app.
    static let shared = SupabaseClient(
        supabaseURL: Secrets.supabaseURL,
        supabaseKey: Secrets.supabaseAnonKey
    )
}

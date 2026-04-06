import Foundation

enum Secrets {
    // Replace with your Supabase project values.
    // The anon key is safe to include in the app binary — RLS protects data.
    static let supabaseURL = URL(string: "https://YOUR_PROJECT.supabase.co")!
    static let supabaseAnonKey = "YOUR_ANON_KEY"
}

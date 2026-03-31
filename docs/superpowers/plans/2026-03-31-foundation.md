# Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set up the iOS project with authentication (Apple Sign In via Supabase), user profile creation, and a 4-tab shell — the scaffolding every other layer builds on.

**Architecture:** SwiftUI app using The Composable Architecture (TCA) for state management. Supabase handles auth and Postgres storage. Each feature is a TCA `@Reducer` with its own state, actions, and dependency clients. The app root composes Auth → Onboarding → MainTab.

**Tech Stack:** Swift 5.9+, SwiftUI, TCA 1.17+, supabase-swift 2.x, XcodeGen, XCTest

**Spec:** `docs/superpowers/specs/2026-03-31-health-comp-design.md`

---

## File Structure

```
HealthComp/
├── project.yml                                  # XcodeGen project definition
├── HealthComp/
│   ├── App/
│   │   ├── HealthCompApp.swift                  # SwiftUI app entry point
│   │   └── AppFeature.swift                     # Root reducer: auth check → routing
│   ├── Config/
│   │   └── Secrets.swift                        # Supabase URL + anon key
│   ├── Models/
│   │   └── User.swift                           # User profile model
│   ├── Features/
│   │   ├── Auth/
│   │   │   ├── AuthClient.swift                 # TCA dependency: sign in/out operations
│   │   │   ├── AuthFeature.swift                # Auth reducer: sign in state machine
│   │   │   └── AuthView.swift                   # Apple Sign In button screen
│   │   ├── Onboarding/
│   │   │   ├── ProfileClient.swift              # TCA dependency: profile CRUD
│   │   │   ├── OnboardingFeature.swift          # Onboarding reducer: username/display name setup
│   │   │   └── OnboardingView.swift             # Profile setup screen
│   │   └── MainTab/
│   │       ├── MainTabFeature.swift             # Tab bar reducer: 4 tabs
│   │       └── MainTabView.swift                # Tab bar UI with placeholder tabs
│   └── Services/
│       └── SupabaseService.swift                # Supabase client as TCA dependency
├── HealthCompTests/
│   ├── UserTests.swift                          # User model serialization tests
│   ├── AuthFeatureTests.swift                   # Auth state machine tests
│   ├── OnboardingFeatureTests.swift             # Onboarding flow tests
│   ├── MainTabFeatureTests.swift                # Tab switching tests
│   └── AppFeatureTests.swift                    # Root routing tests
└── Supabase/
    └── migrations/
        └── 001_create_users.sql                 # Users table, RLS policies
```

---

### Task 1: Project Scaffolding & Dependencies

**Files:**
- Create: `HealthComp/project.yml`
- Create: `HealthComp/HealthComp/App/HealthCompApp.swift`
- Create: `HealthComp/HealthComp/Config/Secrets.swift`

- [ ] **Step 1: Create the directory structure**

```bash
cd /Users/narenyenuganti/repo/health-comp
mkdir -p HealthComp/HealthComp/{App,Config,Models,Features/{Auth,Onboarding,MainTab},Services,Resources}
mkdir -p HealthComp/HealthCompTests
```

- [ ] **Step 2: Create the XcodeGen project definition**

Create `HealthComp/project.yml`:

```yaml
name: HealthComp
options:
  bundleIdPrefix: com.narenyenuganti
  deploymentTarget:
    iOS: "17.0"
  xcodeVersion: "16.0"
  createIntermediateGroups: true

packages:
  ComposableArchitecture:
    url: https://github.com/pointfreeco/swift-composable-architecture
    from: "1.17.0"
  Supabase:
    url: https://github.com/supabase/supabase-swift
    from: "2.0.0"

targets:
  HealthComp:
    type: application
    platform: iOS
    sources:
      - path: HealthComp
    settings:
      base:
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES
        INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        INFOPLIST_KEY_UISupportedInterfaceOrientations: UIInterfaceOrientationPortrait
        INFOPLIST_KEY_NSHealthShareUsageDescription: "HealthComp reads your activity data to score competitions with friends."
        INFOPLIST_KEY_NSHealthUpdateUsageDescription: "HealthComp does not write health data."
        CODE_SIGN_ENTITLEMENTS: HealthComp/Resources/HealthComp.entitlements
        SWIFT_VERSION: "5.9"
    dependencies:
      - package: ComposableArchitecture
      - package: Supabase
        product: Supabase

  HealthCompTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: HealthCompTests
    dependencies:
      - target: HealthComp
    settings:
      base:
        SWIFT_VERSION: "5.9"
```

- [ ] **Step 3: Create the entitlements file**

Create `HealthComp/HealthComp/Resources/HealthComp.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.healthkit</key>
    <true/>
    <key>com.apple.developer.healthkit.access</key>
    <array/>
    <key>com.apple.developer.applesignin</key>
    <array>
        <string>Default</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 4: Create the Secrets config**

Create `HealthComp/HealthComp/Config/Secrets.swift`:

```swift
import Foundation

enum Secrets {
    // Replace with your Supabase project values.
    // The anon key is safe to include in the app binary — RLS protects data.
    static let supabaseURL = URL(string: "https://YOUR_PROJECT.supabase.co")!
    static let supabaseAnonKey = "YOUR_ANON_KEY"
}
```

- [ ] **Step 5: Create the minimal app entry point**

Create `HealthComp/HealthComp/App/HealthCompApp.swift`:

```swift
import SwiftUI

@main
struct HealthCompApp: App {
    var body: some Scene {
        WindowGroup {
            Text("HealthComp")
        }
    }
}
```

- [ ] **Step 6: Generate the Xcode project and verify it builds**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodegen generate
xcodebuild -project HealthComp.xcodeproj -scheme HealthComp -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add HealthComp/
git commit -m "feat: scaffold HealthComp iOS project with TCA and Supabase dependencies"
```

---

### Task 2: Supabase Database Migration

**Files:**
- Create: `HealthComp/Supabase/migrations/001_create_users.sql`

- [ ] **Step 1: Write the users table migration**

Create `HealthComp/Supabase/migrations/001_create_users.sql`:

```sql
-- Users profile table (extends Supabase auth.users)
CREATE TABLE public.users (
    id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    username text UNIQUE NOT NULL,
    display_name text NOT NULL,
    avatar_url text,
    bio text,
    cosmetics jsonb NOT NULL DEFAULT '{}',
    cp_balance integer NOT NULL DEFAULT 0,
    cp_lifetime integer NOT NULL DEFAULT 0,
    privacy jsonb NOT NULL DEFAULT '{
        "profileVisibility": "public",
        "activityVisibility": "friendsOnly",
        "discoverableByContacts": true
    }',
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX idx_users_username ON public.users (username);

-- Row Level Security
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- Anyone can read public profiles
CREATE POLICY "Public profiles are viewable by authenticated users"
    ON public.users FOR SELECT
    TO authenticated
    USING (
        privacy->>'profileVisibility' = 'public'
        OR id = auth.uid()
    );

-- Users can insert their own profile (on first sign-in)
CREATE POLICY "Users can insert own profile"
    ON public.users FOR INSERT
    TO authenticated
    WITH CHECK (id = auth.uid());

-- Users can update their own profile
CREATE POLICY "Users can update own profile"
    ON public.users FOR UPDATE
    TO authenticated
    USING (id = auth.uid())
    WITH CHECK (id = auth.uid());

-- Username uniqueness check function (callable before insert to give nice errors)
CREATE OR REPLACE FUNCTION public.is_username_available(desired_username text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
AS $$
    SELECT NOT EXISTS (
        SELECT 1 FROM public.users WHERE username = lower(desired_username)
    );
$$;
```

- [ ] **Step 2: Apply the migration to your Supabase project**

Run via Supabase dashboard SQL editor or Supabase CLI:

```bash
supabase db push
```

Or paste the SQL into the Supabase Dashboard → SQL Editor → Run.

- [ ] **Step 3: Configure Apple Sign In in Supabase**

In Supabase Dashboard:
1. Go to Authentication → Providers
2. Enable "Apple"
3. Add your Apple Services ID, Team ID, Key ID, and private key
4. Set the callback URL in your Apple Developer Console to: `https://YOUR_PROJECT.supabase.co/auth/v1/callback`

- [ ] **Step 4: Commit**

```bash
git add HealthComp/Supabase/
git commit -m "feat: add users table migration with RLS policies"
```

---

### Task 3: User Model (TDD)

**Files:**
- Create: `HealthComp/HealthComp/Models/User.swift`
- Create: `HealthComp/HealthCompTests/UserTests.swift`

- [ ] **Step 1: Write the failing test**

Create `HealthComp/HealthCompTests/UserTests.swift`:

```swift
import XCTest
@testable import HealthComp

final class UserTests: XCTestCase {

    func testUserDecodesFromSupabaseJSON() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "username": "naren",
            "display_name": "Naren Y",
            "avatar_url": null,
            "bio": "Competing daily",
            "cosmetics": {"avatar": "default", "frame": "none", "theme": "dark"},
            "cp_balance": 250,
            "cp_lifetime": 1200,
            "privacy": {
                "profileVisibility": "public",
                "activityVisibility": "friendsOnly",
                "discoverableByContacts": true
            },
            "created_at": "2026-03-31T12:00:00Z"
        }
        """.data(using: .utf8)!

        let user = try JSONDecoder.supabase.decode(User.self, from: json)

        XCTAssertEqual(user.id, UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertEqual(user.username, "naren")
        XCTAssertEqual(user.displayName, "Naren Y")
        XCTAssertNil(user.avatarURL)
        XCTAssertEqual(user.bio, "Competing daily")
        XCTAssertEqual(user.cpBalance, 250)
        XCTAssertEqual(user.cosmetics.avatar, "default")
        XCTAssertEqual(user.privacy.profileVisibility, .public)
    }

    func testUserEncodesToSupabaseJSON() throws {
        let user = User(
            id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            username: "naren",
            displayName: "Naren Y",
            avatarURL: nil,
            bio: nil,
            cosmetics: .default,
            cpBalance: 0,
            cpLifetime: 0,
            privacy: .default,
            createdAt: Date(timeIntervalSince1970: 0)
        )

        let data = try JSONEncoder.supabase.encode(user)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["username"] as? String, "naren")
        XCTAssertEqual(dict["display_name"] as? String, "Naren Y")
        XCTAssertEqual(dict["cp_balance"] as? Int, 0)
    }

    func testDefaultCosmetics() {
        let cosmetics = User.Cosmetics.default
        XCTAssertEqual(cosmetics.avatar, "default")
        XCTAssertEqual(cosmetics.frame, "none")
        XCTAssertEqual(cosmetics.theme, "dark")
    }

    func testDefaultPrivacy() {
        let privacy = User.Privacy.default
        XCTAssertEqual(privacy.profileVisibility, .public)
        XCTAssertEqual(privacy.activityVisibility, .friendsOnly)
        XCTAssertTrue(privacy.discoverableByContacts)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild test -project HealthComp.xcodeproj -scheme HealthCompTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```

Expected: Compile error — `User` type not found.

- [ ] **Step 3: Write the User model**

Create `HealthComp/HealthComp/Models/User.swift`:

```swift
import Foundation

struct User: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var username: String
    var displayName: String
    var avatarURL: URL?
    var bio: String?
    var cosmetics: Cosmetics
    var cpBalance: Int
    var cpLifetime: Int
    var privacy: Privacy
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case bio
        case cosmetics
        case cpBalance = "cp_balance"
        case cpLifetime = "cp_lifetime"
        case privacy
        case createdAt = "created_at"
    }
}

// MARK: - Nested Types

extension User {
    struct Cosmetics: Codable, Equatable, Sendable {
        var avatar: String
        var frame: String
        var theme: String

        static let `default` = Cosmetics(avatar: "default", frame: "none", theme: "dark")
    }

    struct Privacy: Codable, Equatable, Sendable {
        var profileVisibility: Visibility
        var activityVisibility: ActivityVisibility
        var discoverableByContacts: Bool

        static let `default` = Privacy(
            profileVisibility: .public,
            activityVisibility: .friendsOnly,
            discoverableByContacts: true
        )

        enum Visibility: String, Codable, Sendable {
            case `public`
            case friendsOnly
            case `private`
        }

        enum ActivityVisibility: String, Codable, Sendable {
            case friendsOnly
            case competitorsOnly
        }
    }
}

// MARK: - JSON Coders (snake_case for Supabase)

extension JSONDecoder {
    static let supabase: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let supabase: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild test -project HealthComp.xcodeproj -scheme HealthCompTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Suite|Test Case|Executed|FAIL)"
```

Expected: All 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add HealthComp/HealthComp/Models/User.swift HealthComp/HealthCompTests/UserTests.swift
git commit -m "feat: add User model with Codable support for Supabase"
```

---

### Task 4: Supabase Shared Client

**Files:**
- Create: `HealthComp/HealthComp/Services/SupabaseService.swift`

- [ ] **Step 1: Create the shared Supabase client**

Create `HealthComp/HealthComp/Services/SupabaseService.swift`:

```swift
import Dependencies
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
```

- [ ] **Step 2: Verify it builds**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild -project HealthComp.xcodeproj -scheme HealthComp -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add HealthComp/HealthComp/Services/SupabaseService.swift
git commit -m "feat: add Supabase service as TCA dependency"
```

---

### Task 5: Auth Client & Auth Feature (TDD)

**Files:**
- Create: `HealthComp/HealthComp/Features/Auth/AuthClient.swift`
- Create: `HealthComp/HealthComp/Features/Auth/AuthFeature.swift`
- Create: `HealthComp/HealthCompTests/AuthFeatureTests.swift`

- [ ] **Step 1: Write the failing auth feature tests**

Create `HealthComp/HealthCompTests/AuthFeatureTests.swift`:

```swift
import ComposableArchitecture
import XCTest
@testable import HealthComp

final class AuthFeatureTests: XCTestCase {

    @MainActor
    func testSignInWithAppleSuccess() async {
        let testUser = User(
            id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            username: "naren",
            displayName: "Naren Y",
            avatarURL: nil,
            bio: nil,
            cosmetics: .default,
            cpBalance: 0,
            cpLifetime: 0,
            privacy: .default,
            createdAt: Date()
        )

        let store = TestStore(initialState: AuthFeature.State()) {
            AuthFeature()
        } withDependencies: {
            $0.authClient.signInWithApple = { .existingUser(testUser) }
        }

        await store.send(\.signInWithAppleTapped) {
            $0.isLoading = true
        }
        await store.receive(\.signInResponse.success) {
            $0.isLoading = false
        }
    }

    @MainActor
    func testSignInWithAppleNewUser() async {
        let userId = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!

        let store = TestStore(initialState: AuthFeature.State()) {
            AuthFeature()
        } withDependencies: {
            $0.authClient.signInWithApple = { .newUser(userId) }
        }

        await store.send(\.signInWithAppleTapped) {
            $0.isLoading = true
        }
        await store.receive(\.signInResponse.success) {
            $0.isLoading = false
        }
    }

    @MainActor
    func testSignInWithAppleFailure() async {
        let store = TestStore(initialState: AuthFeature.State()) {
            AuthFeature()
        } withDependencies: {
            $0.authClient.signInWithApple = {
                throw AuthError.signInFailed("User cancelled")
            }
        }

        await store.send(\.signInWithAppleTapped) {
            $0.isLoading = true
        }
        await store.receive(\.signInResponse.failure) {
            $0.isLoading = false
            $0.errorMessage = "User cancelled"
        }
    }

    @MainActor
    func testDismissError() async {
        var state = AuthFeature.State()
        state.errorMessage = "Something went wrong"

        let store = TestStore(initialState: state) {
            AuthFeature()
        }

        await store.send(\.dismissErrorTapped) {
            $0.errorMessage = nil
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild test -project HealthComp.xcodeproj -scheme HealthCompTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```

Expected: Compile error — `AuthFeature` not found.

- [ ] **Step 3: Create the AuthClient dependency**

Create `HealthComp/HealthComp/Features/Auth/AuthClient.swift`:

```swift
import Dependencies
import DependenciesMacros
import Foundation

enum AuthResult: Equatable, Sendable {
    case existingUser(User)
    case newUser(UUID)
}

enum AuthError: Error, Equatable, LocalizedError {
    case signInFailed(String)
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .signInFailed(let message): return message
        case .sessionExpired: return "Session expired. Please sign in again."
        }
    }
}

@DependencyClient
struct AuthClient: Sendable {
    var signInWithApple: @Sendable () async throws -> AuthResult
    var signOut: @Sendable () async throws -> Void
    var currentUserId: @Sendable () async -> UUID? = { nil }
    var restoreSession: @Sendable () async throws -> AuthResult
}

extension AuthClient: TestDependencyKey {
    static let testValue = AuthClient()
}

extension DependencyValues {
    var authClient: AuthClient {
        get { self[AuthClient.self] }
        set { self[AuthClient.self] = newValue }
    }
}
```

- [ ] **Step 4: Create the AuthFeature reducer**

Create `HealthComp/HealthComp/Features/Auth/AuthFeature.swift`:

```swift
import ComposableArchitecture
import Foundation

@Reducer
struct AuthFeature {
    @ObservableState
    struct State: Equatable {
        var isLoading = false
        var errorMessage: String?
    }

    enum Action: Equatable, Sendable {
        case signInWithAppleTapped
        case signInResponse(Result<AuthResult, AuthError>)
        case dismissErrorTapped
    }

    @Dependency(\.authClient) var authClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .signInWithAppleTapped:
                state.isLoading = true
                state.errorMessage = nil
                return .run { send in
                    do {
                        let result = try await authClient.signInWithApple()
                        await send(.signInResponse(.success(result)))
                    } catch let error as AuthError {
                        await send(.signInResponse(.failure(error)))
                    } catch {
                        await send(.signInResponse(.failure(.signInFailed(error.localizedDescription))))
                    }
                }

            case .signInResponse(.success):
                state.isLoading = false
                return .none

            case .signInResponse(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .dismissErrorTapped:
                state.errorMessage = nil
                return .none
            }
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild test -project HealthComp.xcodeproj -scheme HealthCompTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Case|Executed|FAIL)"
```

Expected: All 4 auth tests pass.

- [ ] **Step 6: Commit**

```bash
git add HealthComp/HealthComp/Features/Auth/ HealthComp/HealthCompTests/AuthFeatureTests.swift
git commit -m "feat: add AuthFeature with Apple Sign In state machine (TDD)"
```

---

### Task 6: Auth View

**Files:**
- Create: `HealthComp/HealthComp/Features/Auth/AuthView.swift`

- [ ] **Step 1: Create the Auth sign-in screen**

Create `HealthComp/HealthComp/Features/Auth/AuthView.swift`:

```swift
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
```

- [ ] **Step 2: Verify it builds**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild -project HealthComp.xcodeproj -scheme HealthComp -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add HealthComp/HealthComp/Features/Auth/AuthView.swift
git commit -m "feat: add Apple Sign In screen UI"
```

---

### Task 7: Onboarding — Profile Client & Feature (TDD)

**Files:**
- Create: `HealthComp/HealthComp/Features/Onboarding/ProfileClient.swift`
- Create: `HealthComp/HealthComp/Features/Onboarding/OnboardingFeature.swift`
- Create: `HealthComp/HealthCompTests/OnboardingFeatureTests.swift`

- [ ] **Step 1: Write the failing onboarding tests**

Create `HealthComp/HealthCompTests/OnboardingFeatureTests.swift`:

```swift
import ComposableArchitecture
import XCTest
@testable import HealthComp

final class OnboardingFeatureTests: XCTestCase {

    @MainActor
    func testUsernameAvailableAndProfileCreated() async {
        let createdUser = User(
            id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            username: "naren",
            displayName: "Naren Y",
            avatarURL: nil,
            bio: nil,
            cosmetics: .default,
            cpBalance: 0,
            cpLifetime: 0,
            privacy: .default,
            createdAt: Date()
        )

        let store = TestStore(
            initialState: OnboardingFeature.State(
                userId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
            )
        ) {
            OnboardingFeature()
        } withDependencies: {
            $0.profileClient.isUsernameAvailable = { _ in true }
            $0.profileClient.createProfile = { _, _, _ in createdUser }
        }

        await store.send(\.usernameChanged, "naren") {
            $0.username = "naren"
        }
        await store.send(\.displayNameChanged, "Naren Y") {
            $0.displayName = "Naren Y"
        }
        await store.send(\.submitTapped) {
            $0.isLoading = true
        }
        await store.receive(\.usernameCheckResponse.success) {
            $0.isUsernameAvailable = true
        }
        await store.receive(\.profileCreateResponse.success) {
            $0.isLoading = false
        }
    }

    @MainActor
    func testUsernameTaken() async {
        let store = TestStore(
            initialState: OnboardingFeature.State(
                userId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
            )
        ) {
            OnboardingFeature()
        } withDependencies: {
            $0.profileClient.isUsernameAvailable = { _ in false }
        }

        await store.send(\.usernameChanged, "taken_name") {
            $0.username = "taken_name"
        }
        await store.send(\.displayNameChanged, "Test") {
            $0.displayName = "Test"
        }
        await store.send(\.submitTapped) {
            $0.isLoading = true
        }
        await store.receive(\.usernameCheckResponse.success) {
            $0.isUsernameAvailable = false
            $0.isLoading = false
            $0.errorMessage = "Username is taken. Try another."
        }
    }

    @MainActor
    func testSubmitDisabledWhenFieldsEmpty() async {
        let state = OnboardingFeature.State(
            userId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        )
        XCTAssertTrue(state.isSubmitDisabled)
    }

    @MainActor
    func testSubmitEnabledWhenFieldsFilled() async {
        var state = OnboardingFeature.State(
            userId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        )
        state.username = "naren"
        state.displayName = "Naren"
        XCTAssertFalse(state.isSubmitDisabled)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild test -project HealthComp.xcodeproj -scheme HealthCompTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```

Expected: Compile error — `OnboardingFeature` not found.

- [ ] **Step 3: Create the ProfileClient dependency**

Create `HealthComp/HealthComp/Features/Onboarding/ProfileClient.swift`:

```swift
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
```

- [ ] **Step 4: Create the OnboardingFeature reducer**

Create `HealthComp/HealthComp/Features/Onboarding/OnboardingFeature.swift`:

```swift
import ComposableArchitecture
import Foundation

@Reducer
struct OnboardingFeature {
    @ObservableState
    struct State: Equatable {
        let userId: UUID
        var username = ""
        var displayName = ""
        var isLoading = false
        var isUsernameAvailable: Bool?
        var errorMessage: String?

        var isSubmitDisabled: Bool {
            username.trimmingCharacters(in: .whitespaces).isEmpty
            || displayName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    enum Action: Equatable, Sendable {
        case usernameChanged(String)
        case displayNameChanged(String)
        case submitTapped
        case usernameCheckResponse(Result<Bool, ProfileError>)
        case profileCreateResponse(Result<User, ProfileError>)
    }

    @Dependency(\.profileClient) var profileClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .usernameChanged(let value):
                state.username = value
                state.isUsernameAvailable = nil
                state.errorMessage = nil
                return .none

            case .displayNameChanged(let value):
                state.displayName = value
                state.errorMessage = nil
                return .none

            case .submitTapped:
                state.isLoading = true
                state.errorMessage = nil
                let username = state.username.trimmingCharacters(in: .whitespaces).lowercased()
                let displayName = state.displayName.trimmingCharacters(in: .whitespaces)
                let userId = state.userId
                return .run { send in
                    do {
                        let available = try await profileClient.isUsernameAvailable(username)
                        await send(.usernameCheckResponse(.success(available)))
                        if available {
                            let user = try await profileClient.createProfile(userId, username, displayName)
                            await send(.profileCreateResponse(.success(user)))
                        }
                    } catch let error as ProfileError {
                        await send(.usernameCheckResponse(.failure(error)))
                    } catch {
                        await send(.usernameCheckResponse(.failure(.unknown(error.localizedDescription))))
                    }
                }

            case .usernameCheckResponse(.success(let available)):
                state.isUsernameAvailable = available
                if !available {
                    state.isLoading = false
                    state.errorMessage = "Username is taken. Try another."
                }
                return .none

            case .usernameCheckResponse(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .profileCreateResponse(.success):
                state.isLoading = false
                return .none

            case .profileCreateResponse(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none
            }
        }
    }
}

enum ProfileError: Error, Equatable, LocalizedError {
    case usernameTaken
    case networkError(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .usernameTaken: return "Username is already taken."
        case .networkError(let msg): return msg
        case .unknown(let msg): return msg
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild test -project HealthComp.xcodeproj -scheme HealthCompTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Case|Executed|FAIL)"
```

Expected: All 4 onboarding tests pass.

- [ ] **Step 6: Commit**

```bash
git add HealthComp/HealthComp/Features/Onboarding/ HealthComp/HealthCompTests/OnboardingFeatureTests.swift
git commit -m "feat: add OnboardingFeature with username validation (TDD)"
```

---

### Task 8: Onboarding View

**Files:**
- Create: `HealthComp/HealthComp/Features/Onboarding/OnboardingView.swift`

- [ ] **Step 1: Create the onboarding profile setup screen**

Create `HealthComp/HealthComp/Features/Onboarding/OnboardingView.swift`:

```swift
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
```

- [ ] **Step 2: Verify it builds**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild -project HealthComp.xcodeproj -scheme HealthComp -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add HealthComp/HealthComp/Features/Onboarding/OnboardingView.swift
git commit -m "feat: add onboarding profile setup screen"
```

---

### Task 9: Main Tab Feature (TDD)

**Files:**
- Create: `HealthComp/HealthComp/Features/MainTab/MainTabFeature.swift`
- Create: `HealthComp/HealthComp/Features/MainTab/MainTabView.swift`
- Create: `HealthComp/HealthCompTests/MainTabFeatureTests.swift`

- [ ] **Step 1: Write the failing tab tests**

Create `HealthComp/HealthCompTests/MainTabFeatureTests.swift`:

```swift
import ComposableArchitecture
import XCTest
@testable import HealthComp

final class MainTabFeatureTests: XCTestCase {

    @MainActor
    func testDefaultTabIsCompete() {
        let state = MainTabFeature.State()
        XCTAssertEqual(state.selectedTab, .compete)
    }

    @MainActor
    func testTabSelection() async {
        let store = TestStore(initialState: MainTabFeature.State()) {
            MainTabFeature()
        }

        await store.send(\.tabSelected, .friends) {
            $0.selectedTab = .friends
        }
        await store.send(\.tabSelected, .awards) {
            $0.selectedTab = .awards
        }
        await store.send(\.tabSelected, .profile) {
            $0.selectedTab = .profile
        }
        await store.send(\.tabSelected, .compete) {
            $0.selectedTab = .compete
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild test -project HealthComp.xcodeproj -scheme HealthCompTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```

Expected: Compile error — `MainTabFeature` not found.

- [ ] **Step 3: Create the MainTabFeature reducer**

Create `HealthComp/HealthComp/Features/MainTab/MainTabFeature.swift`:

```swift
import ComposableArchitecture

@Reducer
struct MainTabFeature {
    @ObservableState
    struct State: Equatable {
        var selectedTab: Tab = .compete
    }

    enum Tab: String, Equatable, Sendable, CaseIterable {
        case compete
        case friends
        case awards
        case profile
    }

    enum Action: Equatable, Sendable {
        case tabSelected(Tab)
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .tabSelected(let tab):
                state.selectedTab = tab
                return .none
            }
        }
    }
}
```

- [ ] **Step 4: Create the MainTabView**

Create `HealthComp/HealthComp/Features/MainTab/MainTabView.swift`:

```swift
import ComposableArchitecture
import SwiftUI

struct MainTabView: View {
    @Bindable var store: StoreOf<MainTabFeature>

    var body: some View {
        TabView(selection: $store.selectedTab.sending(\.tabSelected)) {
            Tab("Compete", systemImage: "figure.run", value: .compete) {
                NavigationStack {
                    VStack {
                        Image(systemName: "figure.run.circle")
                            .font(.system(size: 60))
                            .foregroundStyle(.green)
                        Text("Active Competitions")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .navigationTitle("Compete")
                }
            }

            Tab("Friends", systemImage: "person.2", value: .friends) {
                NavigationStack {
                    VStack {
                        Image(systemName: "person.2.circle")
                            .font(.system(size: 60))
                            .foregroundStyle(.blue)
                        Text("Friends Activity")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .navigationTitle("Friends")
                }
            }

            Tab("Awards", systemImage: "trophy", value: .awards) {
                NavigationStack {
                    VStack {
                        Image(systemName: "trophy.circle")
                            .font(.system(size: 60))
                            .foregroundStyle(.yellow)
                        Text("Badges & Cosmetics")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .navigationTitle("Awards")
                }
            }

            Tab("Profile", systemImage: "person.crop.circle", value: .profile) {
                NavigationStack {
                    VStack {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.purple)
                        Text("Your Profile")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .navigationTitle("Profile")
                }
            }
        }
    }
}

#Preview {
    MainTabView(
        store: Store(initialState: MainTabFeature.State()) {
            MainTabFeature()
        }
    )
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild test -project HealthComp.xcodeproj -scheme HealthCompTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Case|Executed|FAIL)"
```

Expected: All 2 tab tests pass.

- [ ] **Step 6: Commit**

```bash
git add HealthComp/HealthComp/Features/MainTab/ HealthComp/HealthCompTests/MainTabFeatureTests.swift
git commit -m "feat: add MainTabFeature with 4-tab navigation (TDD)"
```

---

### Task 10: App Root — Composing Auth → Onboarding → MainTab (TDD)

**Files:**
- Create: `HealthComp/HealthCompTests/AppFeatureTests.swift`
- Create: `HealthComp/HealthComp/App/AppFeature.swift`
- Modify: `HealthComp/HealthComp/App/HealthCompApp.swift`

- [ ] **Step 1: Write the failing app root tests**

Create `HealthComp/HealthCompTests/AppFeatureTests.swift`:

```swift
import ComposableArchitecture
import XCTest
@testable import HealthComp

final class AppFeatureTests: XCTestCase {

    @MainActor
    func testInitialStateIsLoading() {
        let state = AppFeature.State()
        XCTAssertEqual(state.screen, .loading)
    }

    @MainActor
    func testSessionRestoreExistingUser() async {
        let testUser = User(
            id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            username: "naren",
            displayName: "Naren Y",
            avatarURL: nil,
            bio: nil,
            cosmetics: .default,
            cpBalance: 0,
            cpLifetime: 0,
            privacy: .default,
            createdAt: Date()
        )

        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.authClient.restoreSession = { .existingUser(testUser) }
        }

        await store.send(\.onAppear)
        await store.receive(\.sessionRestored.success) {
            $0.screen = .mainTab(MainTabFeature.State())
            $0.currentUser = testUser
        }
    }

    @MainActor
    func testSessionRestoreNoSession() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.authClient.restoreSession = { throw AuthError.sessionExpired }
        }

        await store.send(\.onAppear)
        await store.receive(\.sessionRestored.failure) {
            $0.screen = .auth(AuthFeature.State())
        }
    }

    @MainActor
    func testAuthSuccessNewUserGoesToOnboarding() async {
        let userId = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!

        let store = TestStore(
            initialState: AppFeature.State(screen: .auth(AuthFeature.State()))
        ) {
            AppFeature()
        } withDependencies: {
            $0.authClient.signInWithApple = { .newUser(userId) }
        }

        await store.send(\.auth.signInWithAppleTapped) {
            $0.auth?.isLoading = true
        }
        await store.receive(\.auth.signInResponse.success) {
            $0.auth?.isLoading = false
        }
        await store.receive(\.navigateToOnboarding) {
            $0.screen = .onboarding(OnboardingFeature.State(userId: userId))
        }
    }

    @MainActor
    func testAuthSuccessExistingUserGoesToMainTab() async {
        let testUser = User(
            id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            username: "naren",
            displayName: "Naren Y",
            avatarURL: nil,
            bio: nil,
            cosmetics: .default,
            cpBalance: 0,
            cpLifetime: 0,
            privacy: .default,
            createdAt: Date()
        )

        let store = TestStore(
            initialState: AppFeature.State(screen: .auth(AuthFeature.State()))
        ) {
            AppFeature()
        } withDependencies: {
            $0.authClient.signInWithApple = { .existingUser(testUser) }
        }

        await store.send(\.auth.signInWithAppleTapped) {
            $0.auth?.isLoading = true
        }
        await store.receive(\.auth.signInResponse.success) {
            $0.auth?.isLoading = false
        }
        await store.receive(\.navigateToMainTab) {
            $0.screen = .mainTab(MainTabFeature.State())
            $0.currentUser = testUser
        }
    }

    @MainActor
    func testOnboardingCompleteGoesToMainTab() async {
        let userId = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        let createdUser = User(
            id: userId,
            username: "naren",
            displayName: "Naren Y",
            avatarURL: nil,
            bio: nil,
            cosmetics: .default,
            cpBalance: 0,
            cpLifetime: 0,
            privacy: .default,
            createdAt: Date()
        )

        let store = TestStore(
            initialState: AppFeature.State(
                screen: .onboarding(OnboardingFeature.State(userId: userId))
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.profileClient.isUsernameAvailable = { _ in true }
            $0.profileClient.createProfile = { _, _, _ in createdUser }
        }

        await store.send(\.onboarding.usernameChanged, "naren") {
            $0.onboarding?.username = "naren"
        }
        await store.send(\.onboarding.displayNameChanged, "Naren Y") {
            $0.onboarding?.displayName = "Naren Y"
        }
        await store.send(\.onboarding.submitTapped) {
            $0.onboarding?.isLoading = true
        }
        await store.receive(\.onboarding.usernameCheckResponse.success) {
            $0.onboarding?.isUsernameAvailable = true
        }
        await store.receive(\.onboarding.profileCreateResponse.success) {
            $0.onboarding?.isLoading = false
        }
        await store.receive(\.navigateToMainTab) {
            $0.screen = .mainTab(MainTabFeature.State())
            $0.currentUser = createdUser
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild test -project HealthComp.xcodeproj -scheme HealthCompTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```

Expected: Compile error — `AppFeature` not found.

- [ ] **Step 3: Create the AppFeature root reducer**

Create `HealthComp/HealthComp/App/AppFeature.swift`:

```swift
import ComposableArchitecture
import Foundation

@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable {
        var screen: Screen = .loading
        var currentUser: User?

        enum Screen: Equatable {
            case loading
            case auth(AuthFeature.State)
            case onboarding(OnboardingFeature.State)
            case mainTab(MainTabFeature.State)
        }

        // Computed accessors for child state (used by tests and Scope)
        var auth: AuthFeature.State? {
            get {
                guard case .auth(let state) = screen else { return nil }
                return state
            }
            set {
                guard let newValue else { return }
                screen = .auth(newValue)
            }
        }

        var onboarding: OnboardingFeature.State? {
            get {
                guard case .onboarding(let state) = screen else { return nil }
                return state
            }
            set {
                guard let newValue else { return }
                screen = .onboarding(newValue)
            }
        }

        var mainTab: MainTabFeature.State? {
            get {
                guard case .mainTab(let state) = screen else { return nil }
                return state
            }
            set {
                guard let newValue else { return }
                screen = .mainTab(newValue)
            }
        }
    }

    enum Action: Equatable, Sendable {
        case onAppear
        case sessionRestored(Result<AuthResult, AuthError>)
        case navigateToOnboarding(UUID)
        case navigateToMainTab(User)
        case auth(AuthFeature.Action)
        case onboarding(OnboardingFeature.Action)
        case mainTab(MainTabFeature.Action)
    }

    @Dependency(\.authClient) var authClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .run { send in
                    do {
                        let result = try await authClient.restoreSession()
                        await send(.sessionRestored(.success(result)))
                    } catch let error as AuthError {
                        await send(.sessionRestored(.failure(error)))
                    } catch {
                        await send(.sessionRestored(.failure(.sessionExpired)))
                    }
                }

            case .sessionRestored(.success(.existingUser(let user))):
                state.currentUser = user
                state.screen = .mainTab(MainTabFeature.State())
                return .none

            case .sessionRestored(.success(.newUser(let userId))):
                state.screen = .onboarding(OnboardingFeature.State(userId: userId))
                return .none

            case .sessionRestored(.failure):
                state.screen = .auth(AuthFeature.State())
                return .none

            // Auth child actions — intercept success to navigate
            case .auth(.signInResponse(.success(.newUser(let userId)))):
                return .send(.navigateToOnboarding(userId))

            case .auth(.signInResponse(.success(.existingUser(let user)))):
                return .send(.navigateToMainTab(user))

            case .auth:
                return .none

            // Onboarding child actions — intercept profile creation to navigate
            case .onboarding(.profileCreateResponse(.success(let user))):
                return .send(.navigateToMainTab(user))

            case .onboarding:
                return .none

            case .navigateToOnboarding(let userId):
                state.screen = .onboarding(OnboardingFeature.State(userId: userId))
                return .none

            case .navigateToMainTab(let user):
                state.currentUser = user
                state.screen = .mainTab(MainTabFeature.State())
                return .none

            case .mainTab:
                return .none
            }
        }
        .ifLet(\.auth, action: \.auth) {
            AuthFeature()
        }
        .ifLet(\.onboarding, action: \.onboarding) {
            OnboardingFeature()
        }
        .ifLet(\.mainTab, action: \.mainTab) {
            MainTabFeature()
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild test -project HealthComp.xcodeproj -scheme HealthCompTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Case|Executed|FAIL)"
```

Expected: All 5 app feature tests pass.

- [ ] **Step 5: Update HealthCompApp to use AppFeature**

Replace `HealthComp/HealthComp/App/HealthCompApp.swift`:

```swift
import ComposableArchitecture
import SwiftUI

@main
struct HealthCompApp: App {
    let store = Store(initialState: AppFeature.State()) {
        AppFeature()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(store: store)
        }
    }
}

struct AppRootView: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        Group {
            switch store.screen {
            case .loading:
                ProgressView("Loading...")

            case .auth:
                if let authStore = store.scope(state: \.auth, action: \.auth) {
                    AuthView(store: authStore)
                }

            case .onboarding:
                if let onboardingStore = store.scope(state: \.onboarding, action: \.onboarding) {
                    OnboardingView(store: onboardingStore)
                }

            case .mainTab:
                if let mainTabStore = store.scope(state: \.mainTab, action: \.mainTab) {
                    MainTabView(store: mainTabStore)
                }
            }
        }
        .onAppear {
            store.send(.onAppear)
        }
    }
}
```

- [ ] **Step 6: Verify full build succeeds**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild -project HealthComp.xcodeproj -scheme HealthComp -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Run all tests**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild test -project HealthComp.xcodeproj -scheme HealthCompTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Case|Executed|FAIL)"
```

Expected: All tests pass (User: 4, Auth: 4, Onboarding: 4, MainTab: 2, App: 5 = 19 total).

- [ ] **Step 8: Commit**

```bash
git add HealthComp/HealthComp/App/ HealthComp/HealthCompTests/AppFeatureTests.swift
git commit -m "feat: add AppFeature root router — auth → onboarding → main tab (TDD)"
```

---

### Task 11: Live AuthClient Implementation

**Files:**
- Modify: `HealthComp/HealthComp/Features/Auth/AuthClient.swift`

This wires the AuthClient to real Supabase auth + Apple Sign In. Until now, all tests used the mock. This task adds the live implementation.

- [ ] **Step 1: Add the live AuthClient implementation**

Add to the bottom of `HealthComp/HealthComp/Features/Auth/AuthClient.swift`:

```swift
import AuthenticationServices
import Supabase

extension AuthClient: DependencyKey {
    static let liveValue: AuthClient = {
        let supabase = SupabaseService.shared

        return AuthClient(
            signInWithApple: {
                let helper = AppleSignInHelper()
                let credential = try await helper.performSignIn()

                guard let tokenData = credential.identityToken,
                      let idToken = String(data: tokenData, encoding: .utf8) else {
                    throw AuthError.signInFailed("Missing identity token from Apple")
                }

                let session = try await supabase.auth.signInWithIdToken(
                    credentials: .init(provider: .apple, idToken: idToken)
                )

                let profile: User? = try? await supabase
                    .from("users")
                    .select()
                    .eq("id", value: session.user.id.uuidString)
                    .single()
                    .execute()
                    .value

                if let profile {
                    return .existingUser(profile)
                } else {
                    return .newUser(session.user.id)
                }
            },
            signOut: {
                try await supabase.auth.signOut()
            },
            currentUserId: {
                try? await supabase.auth.session.user.id
            },
            restoreSession: {
                let session = try await supabase.auth.session

                let profile: User? = try? await supabase
                    .from("users")
                    .select()
                    .eq("id", value: session.user.id.uuidString)
                    .single()
                    .execute()
                    .value

                if let profile {
                    return .existingUser(profile)
                } else {
                    return .newUser(session.user.id)
                }
            }
        )
    }()
}

// MARK: - Apple Sign In Helper

@MainActor
final class AppleSignInHelper: NSObject, ASAuthorizationControllerDelegate {
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

    func performSignIn() async throws -> ASAuthorizationAppleIDCredential {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.fullName, .email]

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.performRequests()
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                continuation?.resume(throwing: AuthError.signInFailed("Invalid credential type"))
                return
            }
            continuation?.resume(returning: credential)
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            continuation?.resume(throwing: AuthError.signInFailed(error.localizedDescription))
        }
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild -project HealthComp.xcodeproj -scheme HealthComp -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Run all tests still pass**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild test -project HealthComp.xcodeproj -scheme HealthCompTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep "Executed"
```

Expected: 19 tests, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add HealthComp/HealthComp/Features/Auth/AuthClient.swift
git commit -m "feat: wire live AuthClient to Supabase + Apple Sign In"
```

---

### Task 12: Live ProfileClient Implementation

**Files:**
- Modify: `HealthComp/HealthComp/Features/Onboarding/ProfileClient.swift`

- [ ] **Step 1: Add the live ProfileClient implementation**

Add to the bottom of `HealthComp/HealthComp/Features/Onboarding/ProfileClient.swift`:

```swift
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
```

- [ ] **Step 2: Verify it builds**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild -project HealthComp.xcodeproj -scheme HealthComp -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Run all tests still pass**

```bash
cd /Users/narenyenuganti/repo/health-comp/HealthComp
xcodebuild test -project HealthComp.xcodeproj -scheme HealthCompTests -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep "Executed"
```

Expected: 19 tests, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add HealthComp/HealthComp/Features/Onboarding/ProfileClient.swift
git commit -m "feat: wire live ProfileClient to Supabase for profile CRUD"
```

---

## Summary

After completing all 12 tasks you have:

- **Xcode project** with TCA and Supabase dependencies
- **Supabase database** with users table, RLS policies, and username check function
- **User model** with full Codable support for Supabase JSON
- **Apple Sign In** end-to-end: Apple credential → Supabase auth → profile lookup
- **Onboarding flow** with username availability check and profile creation
- **4-tab shell** (Compete, Friends, Awards, Profile) with placeholder content
- **App root router** that handles: loading → auth → onboarding → main tab
- **19 unit tests** covering all state transitions via TCA TestStore
- **12 git commits** with clean history

**Next plan:** Plan 2: Health Data Pipeline — HealthKit provider protocol, HealthKitProvider implementation, local SwiftData cache, sync to Supabase.

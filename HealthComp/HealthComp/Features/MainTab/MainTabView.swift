import ComposableArchitecture
import SwiftUI

struct MainTabView: View {
    @Bindable var store: StoreOf<MainTabFeature>

    var body: some View {
        TabView(selection: $store.selectedTab.sending(\.tabSelected)) {
            CompeteView(store: store.scope(state: \.compete, action: \.compete))
                .tabItem { Label("Compete", systemImage: "figure.run") }
                .tag(MainTabFeature.Tab.compete)

            FriendsView(store: store.scope(state: \.friends, action: \.friends))
                .tabItem { Label("Friends", systemImage: "person.2") }
                .tag(MainTabFeature.Tab.friends)

            AwardsView(store: store.scope(state: \.awards, action: \.awards))
                .tabItem { Label("Awards", systemImage: "trophy") }
                .tag(MainTabFeature.Tab.awards)

            ProfileTabView(user: store.currentUser)
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            .tag(MainTabFeature.Tab.profile)
        }
    }
}

private struct ProfileTabView: View {
    let user: User

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    profileHeroCard

                    LazyVGrid(columns: columns, spacing: 12) {
                        ProfileStatCard(
                            title: "Current CP",
                            value: user.cpBalance.formatted(),
                            systemImage: "bolt.fill",
                            tint: .green
                        )
                        ProfileStatCard(
                            title: "Lifetime CP",
                            value: user.cpLifetime.formatted(),
                            systemImage: "trophy.fill",
                            tint: .orange
                        )
                    }

                    ProfileSectionCard(title: "About", systemImage: "figure.walk.motion") {
                        Text(user.profileBioSummary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ProfileSectionCard(title: "Privacy", systemImage: "lock.shield") {
                        ProfileInfoRow(label: "Profile", value: user.profileVisibilitySummary)
                        ProfileInfoRow(label: "Activity", value: user.activityVisibilitySummary)
                        ProfileInfoRow(label: "Contacts", value: user.contactDiscoverySummary)
                    }

                    ProfileSectionCard(title: "Cosmetics", systemImage: "sparkles") {
                        ProfileInfoRow(label: "Avatar", value: user.avatarSummary)
                        ProfileInfoRow(label: "Frame", value: user.frameSummary)
                        ProfileInfoRow(label: "Theme", value: user.themeSummary)
                    }

                    ProfileSectionCard(title: "Account", systemImage: "calendar") {
                        ProfileInfoRow(label: "Username", value: "@\(user.username)")
                        ProfileInfoRow(
                            label: "Member since",
                            value: user.createdAt.formatted(date: .abbreviated, time: .omitted)
                        )
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Profile")
        }
    }

    private var profileHeroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.green.opacity(0.85), Color.blue.opacity(0.75)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Text(user.profileInitials)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: 80, height: 80)

                VStack(alignment: .leading, spacing: 6) {
                    Text(user.displayName)
                        .font(.title2.weight(.bold))
                    Text("@\(user.username)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Label(user.profileVisibilitySummary, systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }

                Spacer()
            }

            HStack(spacing: 12) {
                ProfileMetricPill(
                    title: "Balance",
                    value: "\(user.cpBalance.formatted()) CP",
                    tint: .green
                )
                ProfileMetricPill(
                    title: "Lifetime",
                    value: "\(user.cpLifetime.formatted()) CP",
                    tint: .orange
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.green.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct ProfileSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

private struct ProfileStatCard: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)

            Text(value)
                .font(.title2.weight(.bold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

private struct ProfileMetricPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }
}

private struct ProfileInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

#Preview {
    MainTabView(
        store: Store(initialState: MainTabFeature.State(
            currentUser: User(
                id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
                username: "naren",
                displayName: "Naren Y",
                avatarURL: nil,
                bio: "Competing daily and building consistency.",
                cosmetics: .default,
                cpBalance: 250,
                cpLifetime: 1200,
                privacy: .default,
                createdAt: Date(timeIntervalSince1970: 0)
            )
        )) {
            MainTabFeature()
        }
    )
}

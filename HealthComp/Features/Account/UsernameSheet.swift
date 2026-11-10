import SwiftUI

/// Picks or changes the name friends find you by.
struct UsernameSheet: View {
    let friends: AccountFriendSettings

    /// Here rather than a store binding: a filtered character doesn't change
    /// the store's value, so the field would keep showing it.
    @State private var text: String
    @FocusState private var isFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(friends: AccountFriendSettings) {
        self.friends = friends
        _text = State(initialValue: friends.state.sheet?.draft ?? "")
    }

    private var sheet: FriendSettingsFeature.UsernameSheet {
        friends.state.sheet ?? .init()
    }

    private var isAvailable: Bool { sheet.availability == .available }

    var body: some View {
        // Accessibility sizes scroll the buttons with the text; pinned, they
        // would squeeze both.
        let pinsButtons = !dynamicTypeSize.isAccessibilitySize
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pick a username")
                    .font(.title.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Friends find you by it.")
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                field.padding(.top, 10)
                messages
                if !pinsButtons { buttons }
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            if pinsButtons {
                buttons
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(Theme.ground)
            }
        }
        .moving(Motion.settle, value: sheet.availability)
        .moving(Motion.settle, value: sheet.failure)
        .foregroundStyle(Theme.ink)
        .tint(Theme.ink)
        .background(Theme.ground)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.ground)
        .interactiveDismissDisabled(sheet.isSaving)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account.username.sheet")
        .onAppear { isFocused = true }
        // Disabling the field while saving drops its focus; a failed save
        // leaves you typing again.
        .onChange(of: sheet.isSaving) { _, isSaving in
            if !isSaving { isFocused = true }
        }
        // Only redraws the field without a filtered character; the store
        // hears about every edit from `textBinding`.
        .onChange(of: text) { _, newValue in
            let sanitized = FriendSettings.sanitizedUsername(newValue)
            if sanitized != newValue { text = sanitized }
        }
    }

    /// Tells the store from the setter, not from `onChange(of: text)`: on a
    /// busy iPhone SwiftUI can skip the onChange for the last keystroke of a
    /// quick burst, leaving the store checking and saving a shorter name than
    /// the field shows.
    private var textBinding: Binding<String> {
        Binding(
            get: { text },
            set: { newValue in
                text = newValue
                friends.send(.usernameChanged(FriendSettings.sanitizedUsername(newValue)))
            }
        )
    }

    private var field: some View {
        HStack(spacing: 2) {
            Text(verbatim: "@")
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            TextField("Username", text: textBinding, prompt: Text(verbatim: ""))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.continue)
                .focused($isFocused)
                .disabled(sheet.isSaving)
                .onSubmit { friends.send(.usernameContinueTapped) }
                .accessibilityIdentifier("account.username.field")
            if isAvailable {
                Image(systemName: "checkmark")
                    .fontWeight(.bold)
                    .accessibilityHidden(true)
                    .transition(Motion.appear)
            }
        }
        .font(.body)
        .padding(.horizontal, 14)
        // Keeps the caret off the border at accessibility sizes.
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.ink, lineWidth: 2)
        }
    }

    @ViewBuilder
    private var messages: some View {
        if isAvailable || sheet.availability == .taken {
            Text(isAvailable ? "Available" : "Taken")
                .font(.subheadline)
                .foregroundStyle(isAvailable ? Theme.secondary : Theme.ink)
                .accessibilityIdentifier("account.username.status")
                .transition(Motion.appear)
        }
        if let failure = sheet.failure {
            Text(failure == .invalid
                ? "Use 3 to 20 letters, numbers or underscores."
                : "Couldn’t save. Check your connection and try again.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account.username.error")
                .transition(Motion.appear)
        }
    }

    private var buttons: some View {
        VStack(spacing: 4) {
            Button { friends.send(.usernameContinueTapped) } label: {
                BusyLabel("Continue", isBusy: sheet.isSaving)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!sheet.canContinue)
            .accessibilityValue(sheet.isSaving ? "Saving" : "")
            .accessibilityIdentifier("account.username.continue")
            Button("Not Now") { friends.send(.usernameSheetClosed) }
                .buttonStyle(QuietButtonStyle())
                .disabled(sheet.isSaving)
                .accessibilityIdentifier("account.username.not-now")
        }
    }
}

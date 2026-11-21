import SwiftUI
import UIKit

struct UsernameSheet: View {
    let friends: AccountFriendSettings

    @State private var focusRequest = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var sheet: FriendSettingsFeature.UsernameSheet {
        friends.state.sheet ?? .init()
    }

    private var isAvailable: Bool { sheet.availability == .available }

    var body: some View {
        let pinsButtons = !dynamicTypeSize.isAccessibilitySize
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pick a username")
                    .font(.largeTitle.weight(.heavy).width(.condensed))
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
        .onAppear { focusRequest += 1 }
        .onChange(of: sheet.availability) { _, new in
            if new == .available || new == .taken {
                AccessibilityNotification.Announcement(new == .available ? "Available" : "Taken").post()
            }
        }
        .onChange(of: sheet.failure) { _, new in
            if let new {
                AccessibilityNotification.Announcement(Self.text(for: new)).post()
            }
        }
        .onChange(of: sheet.isSaving) { _, isSaving in
            if !isSaving { focusRequest += 1 }
        }
    }

    private var field: some View {
        HStack(spacing: 2) {
            Text(verbatim: "@")
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            UsernameField(
                initialText: sheet.draft,
                isEnabled: !sheet.isSaving,
                focusRequest: focusRequest,
                changed: { friends.send(.usernameChanged($0)) },
                submitted: { friends.send(.usernameContinueTapped) }
            )
            if isAvailable {
                Image(systemName: "checkmark")
                    .bold()
                    .accessibilityHidden(true)
                    .transition(Motion.appear)
            }
        }
        .font(.body)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
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
            Text(Self.text(for: failure))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account.username.error")
                .transition(Motion.appear)
        }
    }

    private static func text(for failure: FriendSettingsFeature.UsernameFailure) -> String {
        failure == .invalid
            ? "Use 3 to 20 letters, numbers or underscores."
            : "Couldn’t save. Check your connection and try again."
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

struct UsernameField: UIViewRepresentable {
    let initialText: String
    let isEnabled: Bool
    let focusRequest: Int
    let changed: (String) -> Void
    let submitted: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> FocusingField {
        let field = FocusingField()
        field.text = initialText
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = Theme.inkUI
        field.tintColor = Theme.inkUI
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.keyboardType = .asciiCapable
        field.returnKeyType = .continue
        field.accessibilityLabel = "Username"
        field.accessibilityIdentifier = "account.username.field"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: FocusingField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = isEnabled
        if focusRequest != context.coordinator.focusRequest {
            context.coordinator.focusRequest = focusRequest
            field.focusWhenShown()
        }
    }

    static func filteredEdit(
        _ current: String,
        _ range: NSRange,
        _ replacement: String
    ) -> (text: String, caret: Int, isClean: Bool)? {
        guard let bounds = Range(range, in: current) else { return nil }
        let proposed: String = current.replacingCharacters(in: bounds, with: replacement)
        let text: String = FriendSettings.sanitizedUsername(proposed)
        let kept: Int = FriendSettings.sanitizedUsername(String(current[..<bounds.lowerBound]) + replacement).count
        return (text, min(kept, text.count), text == proposed)
    }

    final class FocusingField: UITextField {
        private var wantsFocus = false

        func focusWhenShown() {
            wantsFocus = true
            Task { @MainActor in self.focusIfShown() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            focusIfShown()
        }

        private func focusIfShown() {
            guard wantsFocus, window != nil, isEnabled else { return }
            wantsFocus = !becomeFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: UsernameField?
        var focusRequest = 0

        func textField(
            _ field: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            if field.markedTextRange != nil { return true }
            let current: String = field.text ?? ""
            guard let edit = UsernameField.filteredEdit(current, range, string) else { return false }
            if edit.isClean { return true }
            if edit.text != current { field.text = edit.text }
            if let caret = field.position(from: field.beginningOfDocument, offset: edit.caret) {
                field.selectedTextRange = field.textRange(from: caret, to: caret)
            }
            if edit.text != current { parent?.changed(edit.text) }
            return false
        }

        @objc func editingChanged(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            let text: String = field.text ?? ""
            let filtered: String = FriendSettings.sanitizedUsername(text)
            if filtered != text { field.text = filtered }
            parent?.changed(filtered)
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent?.submitted()
            return false
        }
    }
}

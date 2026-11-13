import SwiftUI
import UIKit

/// Picks or changes the name friends find you by.
struct UsernameSheet: View {
    let friends: AccountFriendSettings

    /// Bumped to put the caret in the field.
    @State private var focusRequest = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                    // GroupMatchHeading's font; not uppercased, as UI tests read the label.
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
        // VoiceOver hears what appears under the field.
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
        // Disabling the field while saving drops its focus; a failed save
        // leaves you typing again.
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

/// UIKit's text field, filtered before an edit lands, so it never shows a
/// character the name can't have. SwiftUI's `TextField` shows the keystroke
/// first and relies on a later redraw to take it out, and on a busy iPhone
/// that redraw (and the onChange that told the store) can be skipped: the
/// field showed `betaalice!`, or a longer name than the one being checked
/// and saved. The field owns the text; the store hears every change from it.
struct UsernameField: UIViewRepresentable {
    /// Only read when the field is made: nothing else edits the name.
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

    /// The field after replacing `range` with `replacement`, keeping only
    /// what a username can have, and where the caret goes: after what was
    /// kept of the replacement. Nil for a range outside the text. `isClean`
    /// when nothing was filtered, so UIKit can apply the edit itself.
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

        /// Waits for a window: the sheet asks before it's on screen.
        func focusWhenShown() {
            wantsFocus = true
            DispatchQueue.main.async { self.focusIfShown() }
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
            // Mid-composition (marked text) the edit goes through as is;
            // `editingChanged` filters once it ends.
            if field.markedTextRange != nil { return true }
            let current: String = field.text ?? ""
            guard let edit = UsernameField.filteredEdit(current, range, string) else { return false }
            // UIKit applies a clean edit itself and reports it in `editingChanged`.
            if edit.isClean { return true }
            if edit.text != current { field.text = edit.text }
            // Even when nothing changed (a selection replaced by characters
            // that filter away), the selection collapses, so the next key
            // doesn't overwrite it.
            if let caret = field.position(from: field.beginningOfDocument, offset: edit.caret) {
                field.selectedTextRange = field.textRange(from: caret, to: caret)
            }
            if edit.text != current { parent?.changed(edit.text) }
            return false
        }

        /// Also catches input that skips the delegate, such as dictation or
        /// an accepted prediction, once any composition (marked text) ends.
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

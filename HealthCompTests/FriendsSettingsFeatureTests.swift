import ComposableArchitecture
import UIKit
import XCTest

@testable import HealthComp

@MainActor
final class FriendsSettingsFeatureTests: XCTestCase {
    private typealias Feature = FriendSettingsFeature

    private let unset = FriendSettings(username: nil, showInSearch: true, challengePolicy: .friendsAndLink)
    private let named = FriendSettings(username: "alice", showInSearch: true, challengePolicy: .friendsAndLink)

    private func makeStore(
        _ state: Feature.State? = nil,
        clock: any Clock<Duration> = ImmediateClock(),
        client configure: (inout CompetitionClient) -> Void = { _ in }
    ) -> TestStoreOf<Feature> {
        var client = CompetitionClient.testValue
        configure(&client)
        return TestStore(initialState: state ?? Feature.State(saved: unset)) { Feature() } withDependencies: {
            $0.competitionClient = client
            $0.continuousClock = clock
        }
    }

    func testUsernameRules() {
        XCTAssertEqual(FriendSettings.sanitizedUsername("Be-ta Alice!"), "betaalice")
        XCTAssertEqual(FriendSettings.sanitizedUsername("été_9"), "t_9")
        XCTAssertEqual(FriendSettings.sanitizedUsername(String(repeating: "a", count: 25)).count, 20)
        for good in ["abc", "a_1", String(repeating: "z", count: 20)] {
            XCTAssertTrue(FriendSettings.isValidUsername(good), good)
        }
        for bad in ["", "ab", "Abc", "a b", "ab-c", "abç", String(repeating: "z", count: 21)] {
            XCTAssertFalse(FriendSettings.isValidUsername(bad), bad)
        }
    }

    func testLoadShowsTheRowsAndAFailedRefreshKeepsThem() async {
        let answers = LockIsolated<[Result<FriendSettings, CompetitionRemoteFailure>]>([
            .failure(.notFound), .success(named), .failure(.retryableTransport),
        ])
        let store = makeStore(.init()) { client in
            client.getFriendSettings = { try answers.withValue { $0.removeFirst() }.get() }
        }
        // A server without Friends leaves the rows hidden.
        await store.send(.requested)
        await store.receive(.loaded(nil))
        await store.send(.requested)
        await store.receive(.loaded(named)) { $0.saved = self.named }
        await store.send(.requested)
        await store.receive(.loaded(nil))
    }

    func testSearchSaveShowsTheChangeWhileSavingThenKeepsTheServersAnswer() async {
        var off = unset
        off.showInSearch = false
        let sent = LockIsolated<[Bool]>([])
        let store = makeStore { client in
            client.updateFriendSettings = { show, policy in
                sent.withValue { $0.append(show) }
                return FriendSettings(username: nil, showInSearch: show, challengePolicy: policy)
            }
        }
        await store.send(.showInSearchChanged(false)) { $0.saving = off }
        XCTAssertEqual(store.state.shown, off)
        await store.receive(.saveFinished(off)) {
            $0.saving = nil
            $0.saved = off
        }
        XCTAssertEqual(sent.value, [false])
    }

    func testFailedSavesRollBackAndNameTheRowThatFailed() async {
        let store = makeStore { client in
            client.updateFriendSettings = { _, _ in throw CompetitionRemoteFailure.invalidFriendSettings }
        }
        var off = unset
        off.showInSearch = false
        await store.send(.showInSearchChanged(false)) { $0.saving = off }
        await store.receive(.saveFinished(nil)) {
            $0.saving = nil
            $0.failedField = .showInSearch
        }
        XCTAssertEqual(store.state.shown, unset)

        var friendsOnly = unset
        friendsOnly.challengePolicy = .friendsOnly
        await store.send(.challengePolicyChanged(.friendsOnly)) {
            $0.saving = friendsOnly
            $0.failedField = nil
        }
        await store.receive(.saveFinished(nil)) {
            $0.saving = nil
            $0.failedField = .challengePolicy
        }
        XCTAssertEqual(store.state.shown, unset)
    }

    func testNoSecondSaveOrRefreshRunsWhileOneIsSaving() async {
        let gate = AsyncStream<Void>.makeStream()
        let calls = LockIsolated(0)
        var off = unset
        off.showInSearch = false
        let store = makeStore { client in
            client.updateFriendSettings = { show, policy in
                calls.withValue { $0 += 1 }
                for await _ in gate.stream { break }
                return FriendSettings(username: nil, showInSearch: show, challengePolicy: policy)
            }
        }
        await store.send(.showInSearchChanged(false)) { $0.saving = off }
        await store.send(.challengePolicyChanged(.friendsOnly))
        await store.send(.requested)
        await store.send(.usernameSheetOpened)
        gate.continuation.yield()
        await store.receive(.saveFinished(off)) {
            $0.saving = nil
            $0.saved = off
        }
        XCTAssertEqual(calls.value, 1)
    }

    func testAvailabilityWaitsForTypingToStopAndAsksOnlyAboutTheLastName() async {
        let clock = TestClock()
        let asked = LockIsolated<[String]>([])
        let store = makeStore(clock: clock) { client in
            client.usernameAvailable = { name in
                asked.withValue { $0.append(name) }
                return true
            }
        }
        await store.send(.usernameSheetOpened) { $0.sheet = .init() }
        await store.send(.usernameChanged("nar")) {
            $0.sheet?.draft = "nar"
            $0.sheet?.edit = 1
        }
        await clock.advance(by: .milliseconds(200))
        await store.send(.usernameChanged("nare")) {
            $0.sheet?.draft = "nare"
            $0.sheet?.edit = 2
        }
        await clock.advance(by: .milliseconds(399))
        // The wait for "nar" ends, but the field has moved on.
        await store.receive(.usernameDebounced(edit: 1))
        XCTAssertEqual(asked.value, [])
        await clock.advance(by: .milliseconds(1))
        await store.receive(.usernameDebounced(edit: 2))
        await store.receive(.usernameChecked(edit: 2, isAvailable: true)) {
            $0.sheet?.availability = .available
        }
        XCTAssertEqual(asked.value, ["nare"])

        // An edit clears the answer, and an invalid name never asks.
        await store.send(.usernameChanged("na")) {
            $0.sheet?.draft = "na"
            $0.sheet?.edit = 3
            $0.sheet?.availability = .unknown
        }
        await clock.run()
        XCTAssertEqual(asked.value, ["nare"])
    }

    /// Clearing the field mid-check and typing a new name: only the new
    /// name is answered, and Continue saves exactly that name.
    func testRetypingDuringASlowCheckChecksAndSavesTheLastName() async {
        let clock = TestClock()
        let asked = LockIsolated<[String]>([])
        let saved = LockIsolated<[String]>([])
        var state = Feature.State(saved: unset)
        state.sheet = .init(draft: "betaalice", availability: .available)
        let store = makeStore(state, clock: clock) { client in
            client.usernameAvailable = { name in
                asked.withValue { $0.append(name) }
                try await clock.sleep(for: .milliseconds(300))
                return true
            }
            client.setUsername = { name in
                saved.withValue { $0.append(name) }
                return FriendSettings(username: name, showInSearch: true, challengePolicy: .friendsAndLink)
            }
        }
        await store.send(.usernameChanged("betaal")) {
            $0.sheet?.draft = "betaal"
            $0.sheet?.edit = 1
            $0.sheet?.availability = .unknown
        }
        await clock.advance(by: .milliseconds(500))
        await store.receive(.usernameDebounced(edit: 1))
        XCTAssertEqual(asked.value, ["betaal"])
        let retyped: [String] = ["off", "offline_na", "offline_name"]
        await store.send(.usernameChanged("")) {
            $0.sheet?.draft = ""
            $0.sheet?.edit = 2
        }
        for (index, draft) in retyped.enumerated() {
            await store.send(.usernameChanged(draft)) {
                $0.sheet?.draft = draft
                $0.sheet?.edit = 3 + index
            }
        }
        await clock.advance(by: .milliseconds(700))
        // The slow answer about "betaal" lands after the edits and is dropped.
        await store.receive(.usernameChecked(edit: 1, isAvailable: true))
        for edit in 3...5 { await store.receive(.usernameDebounced(edit: edit)) }
        await store.receive(.usernameChecked(edit: 5, isAvailable: true)) {
            $0.sheet?.availability = .available
        }
        XCTAssertEqual(asked.value, ["betaal", "offline_name"])

        await store.send(.usernameContinueTapped) { $0.sheet?.isSaving = true }
        await store.receive(.usernameSaveFinished(.success(FriendSettings(
            username: "offline_name", showInSearch: true, challengePolicy: .friendsAndLink
        )))) {
            $0.saved?.username = "offline_name"
            $0.sheet = nil
        }
        XCTAssertEqual(saved.value, ["offline_name"])
    }

    // MARK: Username field

    /// A selection replaced by characters that filter away (or to the same
    /// text) leaves the caret after it, so the next key inserts there.
    func testAFilteredReplacementOverASelectionLeavesTheCaretAfterIt() throws {
        let upper = try XCTUnwrap(UsernameField.filteredEdit("abc", NSRange(location: 1, length: 1), "B"))
        XCTAssertEqual(upper.text, "abc")
        XCTAssertEqual(upper.caret, 2)
        XCTAssertFalse(upper.isClean)
        let next = try XCTUnwrap(UsernameField.filteredEdit(upper.text, NSRange(location: upper.caret, length: 0), "d"))
        XCTAssertEqual(next.text, "abdc")
        XCTAssertEqual(next.caret, 3)
        XCTAssertTrue(next.isClean)

        let dropped = try XCTUnwrap(UsernameField.filteredEdit("abc", NSRange(location: 1, length: 1), "!"))
        XCTAssertEqual(dropped.text, "ac")
        XCTAssertEqual(dropped.caret, 1)
        let after = try XCTUnwrap(UsernameField.filteredEdit(dropped.text, NSRange(location: dropped.caret, length: 0), "d"))
        XCTAssertEqual(after.text, "adc")

        let pasted = try XCTUnwrap(UsernameField.filteredEdit("ab", NSRange(location: 1, length: 0), "X-y z"))
        XCTAssertEqual(pasted.text, "axyzb")
        XCTAssertEqual(pasted.caret, 4)
        XCTAssertNil(UsernameField.filteredEdit("ab", NSRange(location: 5, length: 1), "c"))
    }

    /// Input that skips the delegate (dictation, an accepted prediction)
    /// still ends up filtered, and the store hears the filtered name.
    func testTextThatSkipsTheFilterIsFilteredWhenItChanges() {
        let sent = LockIsolated<[String]>([])
        let coordinator = UsernameField.Coordinator()
        coordinator.parent = UsernameField(
            initialText: "",
            isEnabled: true,
            focusRequest: 0,
            changed: { name in sent.withValue { $0.append(name) } },
            submitted: {}
        )
        let field = UITextField()
        field.text = "Be-ta Alice!"
        coordinator.editingChanged(field)
        XCTAssertEqual(field.text, "betaalice")
        XCTAssertEqual(sent.value, ["betaalice"])
    }

    func testAnAnswerAboutAnOlderDraftIsDropped() async {
        var state = Feature.State(saved: unset)
        state.sheet = .init(draft: "newer", edit: 2)
        let store = makeStore(state)
        await store.send(.usernameChecked(edit: 1, isAvailable: false))
        await store.send(.usernameChecked(edit: 2, isAvailable: nil))
        XCTAssertEqual(store.state.sheet?.availability, .unknown)
    }

    /// alice, alice2, alice inside one wait: the first alice's wait ends
    /// early but belongs to an earlier edit, so only the last edit asks, once,
    /// and an answer for an earlier edit of the same text changes nothing.
    func testReturningToANameAsksOnceForTheLatestEdit() async {
        let clock = TestClock()
        let asked = LockIsolated<[String]>([])
        let store = makeStore(clock: clock) { client in
            client.usernameAvailable = { name in
                asked.withValue { $0.append(name) }
                return true
            }
        }
        await store.send(.usernameSheetOpened) { $0.sheet = .init() }
        for (index, draft) in ["alice", "alice2", "alice"].enumerated() {
            await store.send(.usernameChanged(draft)) {
                $0.sheet?.draft = draft
                $0.sheet?.edit = index + 1
            }
            await clock.advance(by: .milliseconds(100))
        }
        await clock.advance(by: .milliseconds(100))
        await store.receive(.usernameDebounced(edit: 1))
        await clock.advance(by: .milliseconds(100))
        await store.receive(.usernameDebounced(edit: 2))
        XCTAssertEqual(asked.value, [])
        await clock.advance(by: .milliseconds(100))
        await store.receive(.usernameDebounced(edit: 3))
        await store.receive(.usernameChecked(edit: 3, isAvailable: true)) {
            $0.sheet?.availability = .available
        }
        XCTAssertEqual(asked.value, ["alice"])

        // Delivered late, the first alice's answer changes nothing.
        await store.send(.usernameChecked(edit: 1, isAvailable: false))
        await store.send(.usernameDebounced(edit: 1))
        XCTAssertEqual(asked.value, ["alice"])
    }

    func testYourOwnNameIsNotChecked() async {
        var state = Feature.State(saved: named)
        state.sheet = .init(draft: "alice2", availability: .taken)
        let store = makeStore(state) { client in
            client.usernameAvailable = { _ in
                XCTFail("Should not ask about your own name")
                return false
            }
        }
        await store.send(.usernameChanged("alice")) {
            $0.sheet?.draft = "alice"
            $0.sheet?.edit = 1
            $0.sheet?.availability = .unknown
        }
    }

    func testTakenNameCantContinue() async {
        var state = Feature.State(saved: unset)
        state.sheet = .init(draft: "taken", availability: .taken)
        let store = makeStore(state)
        XCTAssertFalse(store.state.sheet?.canContinue ?? true)
        await store.send(.usernameContinueTapped)
    }

    func testContinueSavesAndClosesTheSheet() async {
        var state = Feature.State(saved: unset)
        state.sheet = .init(draft: "alice", availability: .available)
        let store = makeStore(state) { client in
            client.setUsername = { name in
                FriendSettings(username: name, showInSearch: true, challengePolicy: .friendsAndLink)
            }
        }
        await store.send(.usernameContinueTapped) { $0.sheet?.isSaving = true }
        await store.receive(.usernameSaveFinished(.success(named))) {
            $0.saved = self.named
            $0.sheet = nil
        }
    }

    func testTheSheetCantCloseOrEditWhileSaving() async {
        let gate = AsyncStream<Void>.makeStream()
        var state = Feature.State(saved: unset)
        state.sheet = .init(draft: "alice", availability: .available)
        let named = self.named
        let store = makeStore(state) { client in
            client.setUsername = { _ in
                for await _ in gate.stream { break }
                return named
            }
        }
        await store.send(.usernameContinueTapped) { $0.sheet?.isSaving = true }
        await store.send(.usernameSheetClosed)
        await store.send(.usernameChanged("other"))
        gate.continuation.yield()
        await store.receive(.usernameSaveFinished(.success(named))) {
            $0.saved = named
            $0.sheet = nil
        }
    }

    func testAnUnansweredCheckDoesntHoldUpContinue() {
        let sheet = Feature.UsernameSheet(draft: "alice", availability: .unknown)
        XCTAssertTrue(sheet.canContinue)
    }

    func testSaveErrorsStayOnTheSheet() async {
        let cases: [(CompetitionRemoteFailure, Feature.UsernameAvailability, Feature.UsernameFailure?)] = [
            (.usernameUnavailable, .taken, nil),
            (.invalidUsername, .available, .invalid),
            (.retryableTransport, .available, .failed),
        ]
        for (failure, availability, expected) in cases {
            var state = Feature.State(saved: unset)
            state.sheet = .init(draft: "alice", availability: .available)
            let store = makeStore(state) { client in
                client.setUsername = { _ in throw failure }
            }
            await store.send(.usernameContinueTapped) { $0.sheet?.isSaving = true }
            await store.receive(.usernameSaveFinished(.failure(failure))) {
                $0.sheet?.isSaving = false
                $0.sheet?.availability = availability
                $0.sheet?.failure = expected
            }
        }
    }

    // MARK: Sign-out

    /// A server call held open until released, recording its cancellation.
    private final class HeldCall: Sendable {
        private let isEntered = LockIsolated(false)
        private let isCancelled = LockIsolated(false)
        private let gate = AsyncStream<Void>.makeStream()

        var wasCancelled: Bool { isCancelled.value }

        func hold() async {
            isEntered.setValue(true)
            await withTaskCancellationHandler {
                for await _ in gate.stream { break }
            } onCancel: { [isCancelled] in
                isCancelled.setValue(true)
            }
        }

        func waitUntilEntered() async {
            for _ in 0..<500 where !isEntered.value {
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(isEntered.value, "The call never started.")
        }

        func release() { gate.continuation.yield() }
    }

    private func makeSignOutStore(
        _ friendSettings: Feature.State = .init(),
        client configure: (inout CompetitionClient) -> Void
    ) -> TestStoreOf<CompetitionFeature> {
        var client = CompetitionClient.testValue
        configure(&client)
        var initial = CompetitionFeature.State()
        initial.friendSettings = friendSettings
        return TestStore(initialState: initial) { CompetitionFeature() } withDependencies: {
            $0.competitionClient = client
            $0.continuousClock = ImmediateClock()
        }
    }

    /// The last account's answer, arriving after the next account's, is dropped.
    func testSignOutCancelsAHeldLoad() async {
        let held = HeldCall()
        let calls = LockIsolated(0)
        let (first, second) = (named, FriendSettings(
            username: "bob", showInSearch: false, challengePolicy: .friendsOnly
        ))
        let store = makeSignOutStore { client in
            client.getFriendSettings = {
                guard calls.withValue({ $0 += 1; return $0 }) == 1 else { return second }
                await held.hold()
                return first
            }
        }
        await store.send(.friendSettings(.requested))
        await held.waitUntilEntered()
        await store.send(.stop)
        await store.send(.friendSettings(.requested))
        await store.receive(.friendSettings(.loaded(second))) { $0.friendSettings.saved = second }
        held.release()
        await store.finish()
        XCTAssertTrue(held.wasCancelled)
        XCTAssertEqual(store.state.friendSettings.saved, second)
    }

    func testSignOutCancelsAHeldSave() async {
        let held = HeldCall()
        var off = unset
        off.showInSearch = false
        let store = makeSignOutStore(.init(saved: unset)) { client in
            client.updateFriendSettings = { [off] _, _ in
                await held.hold()
                return off
            }
        }
        await store.send(.friendSettings(.showInSearchChanged(false))) {
            $0.friendSettings.saving = off
        }
        await held.waitUntilEntered()
        await store.send(.stop) { $0.friendSettings = .init() }
        held.release()
        await store.finish()
        XCTAssertTrue(held.wasCancelled)
    }

    func testSignOutCancelsAHeldUsernameSave() async {
        let held = HeldCall()
        var state = Feature.State(saved: unset)
        state.sheet = .init(draft: "alice", availability: .available)
        let store = makeSignOutStore(state) { [named] client in
            client.setUsername = { _ in
                await held.hold()
                return named
            }
        }
        await store.send(.friendSettings(.usernameContinueTapped)) {
            $0.friendSettings.sheet?.isSaving = true
        }
        await held.waitUntilEntered()
        await store.send(.stop) { $0.friendSettings = .init() }
        held.release()
        await store.finish()
        XCTAssertTrue(held.wasCancelled)
    }

    func testSignOutCancelsAHeldAvailabilityCheck() async {
        let held = HeldCall()
        var state = Feature.State(saved: unset)
        state.sheet = .init()
        let store = makeSignOutStore(state) { client in
            client.usernameAvailable = { _ in
                await held.hold()
                return true
            }
        }
        await store.send(.friendSettings(.usernameChanged("alice"))) {
            $0.friendSettings.sheet?.draft = "alice"
            $0.friendSettings.sheet?.edit = 1
        }
        await store.receive(.friendSettings(.usernameDebounced(edit: 1)))
        await held.waitUntilEntered()
        await store.send(.stop) { $0.friendSettings = .init() }
        held.release()
        await store.finish()
        XCTAssertTrue(held.wasCancelled)
    }
}

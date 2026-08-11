import CompetitionCore
import Foundation
import XCTest

@testable import HealthComp

final class JSONCompetitionEventStoreTests: XCTestCase {
    func testRootAndDurableFilesUsePrivateModesAndFirstAuthenticationProtection() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let protectionRecorder = FileProtectionRecorder()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o777)]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o777)],
            ofItemAtPath: root.path
        )
        let store = JSONCompetitionEventStore(
            rootDirectory: root,
            faultInjector: .none,
            fileProtection: .live.observing { url, protection in
                try protectionRecorder.record(protection, for: url)
            }
        )
        let genesis = try makeGenesis()
        let created = try await store.create(genesis)
        let current = try await store.append(
            [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
            to: genesis.competitionID,
            expectedCursor: created.cursor
        )
        let lock = root.appendingPathComponent("store.lock")
        let primary = primaryURL(root: root, id: genesis.competitionID)
        let previous = previousURL(root: root, id: genesis.competitionID)

        try assertPrivateAttributes(
            root,
            permissions: 0o700,
            protectionRecorder: protectionRecorder
        )
        for url in [lock, primary, previous] {
            try assertPrivateAttributes(
                url,
                permissions: 0o600,
                protectionRecorder: protectionRecorder
            )
        }
        let lockInode = try systemFileNumber(lock)

        try await store.delete(
            genesis.competitionID,
            expectedCursor: current.cursor
        )
        try assertPrivateAttributes(
            tombstoneURL(root: root, id: genesis.competitionID),
            permissions: 0o600,
            protectionRecorder: protectionRecorder
        )
        try assertPrivateAttributes(
            lock,
            permissions: 0o600,
            protectionRecorder: protectionRecorder
        )
        XCTAssertEqual(try systemFileNumber(lock), lockInode)
    }

    func testStoreLockSymlinkIsRejectedWithoutMutatingItsTarget() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let target = root.appendingPathComponent("lock-target")
        let targetBytes = Data("must not become the lock inode".utf8)
        try targetBytes.write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: target.path
        )
        let lock = root.appendingPathComponent("store.lock")
        try FileManager.default.createSymbolicLink(
            at: lock,
            withDestinationURL: target
        )

        do {
            _ = try await JSONCompetitionEventStore(rootDirectory: root).ids()
            XCTFail("Expected lock symlink refusal")
        } catch {
            XCTAssertEqual(
                error as? JSONCompetitionEventStoreError,
                .posix(operation: "open store lock", code: ELOOP)
            )
        }

        XCTAssertEqual(try Data(contentsOf: target), targetBytes)
        let targetMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: target.path)[
                .posixPermissions
            ] as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(targetMode, 0o644)
    }

    func testTemporaryFileUsesPrivateModeAndFirstAuthenticationProtection() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let protectionRecorder = FileProtectionRecorder()
        let genesis = try makeGenesis()
        let store = JSONCompetitionEventStore(
            rootDirectory: root,
            faultInjector: JSONCompetitionEventStoreFaultInjector(
                crashAt: .newTemporaryCreated
            ),
            fileProtection: .live.observing { url, protection in
                try protectionRecorder.record(protection, for: url)
            }
        )

        do {
            _ = try await store.create(genesis)
            XCTFail("Expected injected crash")
        } catch {
            XCTAssertEqual(
                error as? JSONCompetitionEventStoreError,
                .injectedCrash(.newTemporaryCreated)
            )
        }

        let temporaries = try temporaryURLs(
            root: root,
            id: genesis.competitionID
        )
        try assertPrivateAttributes(
            XCTUnwrap(temporaries.first),
            permissions: 0o600,
            protectionRecorder: protectionRecorder
        )
    }

    func testCandidateResolutionSelectsTrueDescendantInEitherSlot() async throws {
        let genesis = try makeGenesis()
        var base = try CompetitionJournal(genesis: genesis)
        _ = try base.append(
            [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
            expectedCursor: base.cursor
        )
        var descendant = base
        _ = try descendant.append(
            [
                .activityRefreshAttemptRecorded(
                    try makeActivityRefreshEvent(
                        id: "ancestry-descendant",
                        genesis: genesis,
                        points: 300
                    )
                ),
            ],
            expectedCursor: descendant.cursor
        )
        XCTAssertEqual(descendant.relationship(to: base), .descendant)

        for newerIsPrimary in [true, false] {
            let root = makeTemporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let primaryJournal = newerIsPrimary ? descendant : base
            let previousJournal = newerIsPrimary ? base : descendant
            let primary = primaryURL(root: root, id: genesis.competitionID)
            let previous = previousURL(root: root, id: genesis.competitionID)
            let originalPrimaryBytes = try pinnedEncoder().encode(
                primaryJournal
            )
            let newerBytes = try pinnedEncoder().encode(descendant)
            try originalPrimaryBytes.write(to: primary)
            try pinnedEncoder().encode(previousJournal).write(to: previous)

            let optionalLoaded = try await JSONCompetitionEventStore(
                rootDirectory: root
            ).load(genesis.competitionID)
            let loaded = try XCTUnwrap(optionalLoaded)

            XCTAssertEqual(loaded.journal, descendant)
            XCTAssertEqual(
                loaded.source,
                newerIsPrimary ? .primary : .recoveredPrevious
            )
            XCTAssertEqual(try Data(contentsOf: primary), newerBytes)
            if newerIsPrimary {
                XCTAssertEqual(
                    try quarantineURLs(root: root, id: genesis.competitionID),
                    []
                )
            } else {
                let quarantines = try quarantineURLs(
                    root: root,
                    id: genesis.competitionID
                )
                XCTAssertEqual(quarantines.count, 1)
                XCTAssertEqual(
                    try Data(contentsOf: quarantines[0]),
                    originalPrimaryBytes
                )
            }
        }
    }

    func testCandidateResolutionRejectsEnvelopePrefixInsideAtomicCommitBothWays() async throws {
        let genesis = try makeGenesis()
        let acceptance = try makeAcceptanceEvent(genesis: genesis)
        let activity = try makeActivityRefreshEvent(
            id: "same-commit-second-event",
            genesis: genesis,
            points: 300
        )
        var oneEventCommit = try CompetitionJournal(genesis: genesis)
        _ = try oneEventCommit.append(
            [.lifecycle(acceptance)],
            expectedCursor: oneEventCommit.cursor
        )
        var twoEventCommit = try CompetitionJournal(genesis: genesis)
        _ = try twoEventCommit.append(
            [.lifecycle(acceptance), .activityRefreshAttemptRecorded(activity)],
            expectedCursor: twoEventCommit.cursor
        )
        XCTAssertEqual(
            oneEventCommit.envelopes,
            Array(twoEventCommit.envelopes.prefix(1))
        )
        XCTAssertEqual(
            oneEventCommit.relationship(to: twoEventCommit),
            .divergent
        )

        for primaryHasOneEvent in [true, false] {
            let root = makeTemporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let primaryJournal = primaryHasOneEvent
                ? oneEventCommit
                : twoEventCommit
            let previousJournal = primaryHasOneEvent
                ? twoEventCommit
                : oneEventCommit
            let primary = primaryURL(root: root, id: genesis.competitionID)
            let previous = previousURL(root: root, id: genesis.competitionID)
            let primaryBytes = try pinnedEncoder().encode(primaryJournal)
            let previousBytes = try pinnedEncoder().encode(previousJournal)
            try primaryBytes.write(to: primary)
            try previousBytes.write(to: previous)

            do {
                _ = try await JSONCompetitionEventStore(rootDirectory: root)
                    .load(genesis.competitionID)
                XCTFail("Expected mid-commit divergence")
            } catch {
                XCTAssertEqual(
                    error as? JSONCompetitionEventStoreError,
                    .divergentSnapshots
                )
            }
            XCTAssertEqual(try Data(contentsOf: primary), primaryBytes)
            XCTAssertEqual(try Data(contentsOf: previous), previousBytes)
        }
    }

    func testRecoveryCrashCheckpointsResumeWithoutLosingQuarantineEvidence() async throws {
        let beforeRecoveryRename: [JSONCompetitionEventStoreFaultInjector.FaultPoint] = [
            .recoveryTemporaryCreated,
            .recoveryTemporaryWritten,
            .recoveryTemporarySynced,
            .corruptPrimaryQuarantined,
            .quarantineDirectorySynced,
        ]
        let afterRecoveryRename: [JSONCompetitionEventStoreFaultInjector.FaultPoint] = [
            .recoveryPrimaryRenamed,
            .recoveryDirectorySynced,
        ]

        for point in beforeRecoveryRename + afterRecoveryRename {
            let root = makeTemporaryRoot()
            let normalStore = JSONCompetitionEventStore(rootDirectory: root)
            let genesis = try makeGenesis()
            let created = try await normalStore.create(genesis)
            _ = try await normalStore.append(
                [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
                to: genesis.competitionID,
                expectedCursor: created.cursor
            )
            let primary = primaryURL(root: root, id: genesis.competitionID)
            let previous = previousURL(root: root, id: genesis.competitionID)
            let previousBytes = try Data(contentsOf: previous)
            let corruptBytes = Data("recovery-crash-corrupt-\(point.rawValue)".utf8)
            try corruptBytes.write(to: primary)
            let crashingStore = JSONCompetitionEventStore(
                rootDirectory: root,
                faultInjector: JSONCompetitionEventStoreFaultInjector(
                    crashAt: point
                )
            )

            do {
                _ = try await crashingStore.load(genesis.competitionID)
                XCTFail("Expected recovery crash at \(point)")
            } catch {
                XCTAssertEqual(
                    error as? JSONCompetitionEventStoreError,
                    .injectedCrash(point)
                )
            }
            if beforeRecoveryRename.contains(point) {
                XCTAssertFalse(
                    try temporaryURLs(
                        root: root,
                        id: genesis.competitionID
                    ).isEmpty
                )
            }

            let restarted = JSONCompetitionEventStore(rootDirectory: root)
            let optionalLoaded = try await restarted.load(
                genesis.competitionID
            )
            let loaded = try XCTUnwrap(optionalLoaded)
            XCTAssertEqual(loaded.journal.cursor, created.cursor)
            XCTAssertEqual(
                loaded.source,
                beforeRecoveryRename.contains(point)
                    ? .recoveredPrevious
                    : .primary
            )
            XCTAssertEqual(try Data(contentsOf: primary), previousBytes)
            XCTAssertEqual(
                try temporaryURLs(root: root, id: genesis.competitionID),
                []
            )
            let quarantines = try quarantineURLs(
                root: root,
                id: genesis.competitionID
            )
            XCTAssertEqual(quarantines.count, 1)
            XCTAssertEqual(try Data(contentsOf: quarantines[0]), corruptBytes)
            try FileManager.default.removeItem(at: root)
        }
    }

    func testDeleteCrashCheckpointsRespectTombstoneCommitBoundary() async throws {
        let beforeTombstoneRename: [JSONCompetitionEventStoreFaultInjector.FaultPoint] = [
            .tombstoneTemporaryCreated,
            .tombstoneTemporaryWritten,
            .tombstoneTemporarySynced,
        ]
        let afterTombstoneRename: [JSONCompetitionEventStoreFaultInjector.FaultPoint] = [
            .tombstoneRenamed,
            .tombstoneDirectorySynced,
            .cleanupUnlinked,
            .cleanupDirectorySynced,
        ]

        for point in beforeTombstoneRename + afterTombstoneRename {
            let root = makeTemporaryRoot()
            let normalStore = JSONCompetitionEventStore(rootDirectory: root)
            let genesis = try makeGenesis()
            let created = try await normalStore.create(genesis)
            let current = try await normalStore.append(
                [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
                to: genesis.competitionID,
                expectedCursor: created.cursor
            )
            let crashingStore = JSONCompetitionEventStore(
                rootDirectory: root,
                faultInjector: JSONCompetitionEventStoreFaultInjector(
                    crashAt: point
                )
            )

            do {
                try await crashingStore.delete(
                    genesis.competitionID,
                    expectedCursor: current.cursor
                )
                XCTFail("Expected delete crash at \(point)")
            } catch {
                XCTAssertEqual(
                    error as? JSONCompetitionEventStoreError,
                    .injectedCrash(point)
                )
            }
            if beforeTombstoneRename.contains(point) {
                XCTAssertFalse(
                    try temporaryURLs(
                        root: root,
                        id: genesis.competitionID
                    ).isEmpty
                )
            }

            let restarted = JSONCompetitionEventStore(rootDirectory: root)
            let loaded = try await restarted.load(genesis.competitionID)
            if beforeTombstoneRename.contains(point) {
                XCTAssertNotNil(loaded)
                try await restarted.delete(
                    genesis.competitionID,
                    expectedCursor: current.cursor
                )
            } else {
                XCTAssertNil(loaded)
                try await restarted.delete(
                    genesis.competitionID,
                    expectedCursor: created.cursor
                )
            }

            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: tombstoneURL(
                        root: root,
                        id: genesis.competitionID
                    ).path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: primaryURL(
                        root: root,
                        id: genesis.competitionID
                    ).path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: previousURL(
                        root: root,
                        id: genesis.competitionID
                    ).path
                )
            )
            XCTAssertEqual(
                try temporaryURLs(root: root, id: genesis.competitionID),
                []
            )
            try FileManager.default.removeItem(at: root)
        }
    }

    func testExactEncodedCandidateIsValidatedBeforeBackupOrTempMutation() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let normalStore = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()
        let created = try await normalStore.create(genesis)
        let primary = primaryURL(root: root, id: genesis.competitionID)
        let primaryBytes = try Data(contentsOf: primary)
        let faultyStore = JSONCompetitionEventStore(
            rootDirectory: root,
            faultInjector: JSONCompetitionEventStoreFaultInjector(
                encodedCandidateBehavior: .replaceWith(
                    Data("not a journal".utf8)
                )
            )
        )

        do {
            _ = try await faultyStore.append(
                [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
                to: genesis.competitionID,
                expectedCursor: created.cursor
            )
            XCTFail("Expected exact encoded-candidate validation failure")
        } catch {
            XCTAssertEqual(
                error as? JSONCompetitionEventStoreError,
                .invalidEncodedCandidate
            )
        }

        XCTAssertEqual(try Data(contentsOf: primary), primaryBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: previousURL(
                    root: root,
                    id: genesis.competitionID
                ).path
            )
        )
        XCTAssertEqual(
            try temporaryURLs(root: root, id: genesis.competitionID),
            []
        )
    }

    func testCreateCrashCheckpointsAreRetriableAsAbsentOrCommitted() async throws {
        let beforeCommit: [JSONCompetitionEventStoreFaultInjector.FaultPoint] = [
            .newTemporaryCreated,
            .newTemporaryWritten,
            .newTemporarySynced,
        ]
        let afterCommit: [JSONCompetitionEventStoreFaultInjector.FaultPoint] = [
            .primaryRenamed,
            .primaryDirectorySynced,
        ]

        for point in beforeCommit + afterCommit {
            let root = makeTemporaryRoot()
            let genesis = try makeGenesis()
            let crashingStore = JSONCompetitionEventStore(
                rootDirectory: root,
                faultInjector: JSONCompetitionEventStoreFaultInjector(
                    crashAt: point
                )
            )
            do {
                _ = try await crashingStore.create(genesis)
                XCTFail("Expected injected crash at \(point)")
            } catch {
                XCTAssertEqual(
                    error as? JSONCompetitionEventStoreError,
                    .injectedCrash(point)
                )
            }

            let staleTemporaries = try temporaryURLs(
                root: root,
                id: genesis.competitionID
            )
            if beforeCommit.contains(point) {
                XCTAssertFalse(
                    staleTemporaries.isEmpty,
                    "A simulated crash at \(point) must preserve temp residue"
                )
            }

            let restarted = JSONCompetitionEventStore(rootDirectory: root)
            let restartedIDs = try await restarted.ids()
            XCTAssertEqual(
                restartedIDs,
                beforeCommit.contains(point)
                    ? []
                    : [genesis.competitionID]
            )
            XCTAssertEqual(
                try temporaryURLs(root: root, id: genesis.competitionID),
                [],
                "A fresh locked operation must reap stale temps after \(point)"
            )
            let loaded = try await restarted.load(genesis.competitionID)
            let retried = try await restarted.create(genesis)
            if beforeCommit.contains(point) {
                XCTAssertNil(loaded, "Unexpected commit at \(point)")
                XCTAssertTrue(retried.created)
            } else {
                XCTAssertEqual(loaded?.journal.genesis, genesis)
                XCTAssertFalse(retried.created)
            }
            try FileManager.default.removeItem(at: root)
        }
    }

    func testAppendCrashCheckpointsPreserveOldOrPublishNewPrefix() async throws {
        let beforePrimaryRename: [JSONCompetitionEventStoreFaultInjector.FaultPoint] = [
            .newTemporaryCreated,
            .newTemporaryWritten,
            .newTemporarySynced,
            .backupTemporaryCreated,
            .backupTemporaryWritten,
            .backupTemporarySynced,
            .backupRenamed,
            .backupDirectorySynced,
        ]
        let afterPrimaryRename: [JSONCompetitionEventStoreFaultInjector.FaultPoint] = [
            .primaryRenamed,
            .primaryDirectorySynced,
        ]

        for point in beforePrimaryRename + afterPrimaryRename {
            let root = makeTemporaryRoot()
            let normalStore = JSONCompetitionEventStore(rootDirectory: root)
            let genesis = try makeGenesis()
            let created = try await normalStore.create(genesis)
            let accepted = try await normalStore.append(
                [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
                to: genesis.competitionID,
                expectedCursor: created.cursor
            )
            let event = CompetitionDomainEvent.activityRefreshAttemptRecorded(
                try makeActivityRefreshEvent(
                    id: "crash-\(point.rawValue)",
                    genesis: genesis,
                    points: 350
                )
            )
            let crashingStore = JSONCompetitionEventStore(
                rootDirectory: root,
                faultInjector: JSONCompetitionEventStoreFaultInjector(
                    crashAt: point
                )
            )
            do {
                _ = try await crashingStore.append(
                    [event],
                    to: genesis.competitionID,
                    expectedCursor: accepted.cursor
                )
                XCTFail("Expected injected crash at \(point)")
            } catch {
                XCTAssertEqual(
                    error as? JSONCompetitionEventStoreError,
                    .injectedCrash(point)
                )
            }


            let staleTemporaries = try temporaryURLs(
                root: root,
                id: genesis.competitionID
            )
            if beforePrimaryRename.contains(point) {
                XCTAssertFalse(
                    staleTemporaries.isEmpty,
                    "A simulated crash at \(point) must preserve temp residue"
                )
            }

            let restarted = JSONCompetitionEventStore(rootDirectory: root)
            let restartedIDs = try await restarted.ids()
            XCTAssertEqual(restartedIDs, [genesis.competitionID])
            XCTAssertEqual(
                try temporaryURLs(root: root, id: genesis.competitionID),
                [],
                "A fresh locked operation must reap stale temps after \(point)"
            )
            let optionalLoaded = try await restarted.load(genesis.competitionID)
            let loaded = try XCTUnwrap(optionalLoaded)
            if beforePrimaryRename.contains(point) {
                XCTAssertEqual(loaded.journal.cursor, accepted.cursor)
                let retried = try await restarted.append(
                    [event],
                    to: genesis.competitionID,
                    expectedCursor: accepted.cursor
                )
                XCTAssertEqual(retried.appendedCount, 1)
            } else {
                XCTAssertEqual(loaded.journal.cursor.eventCount, 2)
                let retried = try await restarted.append(
                    [event],
                    to: genesis.competitionID,
                    expectedCursor: accepted.cursor
                )
                XCTAssertEqual(retried.appendedCount, 0)
                XCTAssertEqual(retried.cursor, loaded.journal.cursor)
            }
            try FileManager.default.removeItem(at: root)
        }
    }

    func testWriteLoopRetriesEINTRAndShortWrites() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionEventStore(
            rootDirectory: root,
            faultInjector: JSONCompetitionEventStoreFaultInjector(
                writeBehaviors: [
                    .interrupted,
                    .maximumBytes(1),
                    .maximumBytes(2),
                    .maximumBytes(3),
                ]
            )
        )
        let genesis = try makeGenesis()

        _ = try await store.create(genesis)
        let optionalLoaded = try await store.load(genesis.competitionID)

        XCTAssertEqual(try XCTUnwrap(optionalLoaded).journal.genesis, genesis)
    }

    func testZeroByteWriteFailsWithoutPublishingPrimary() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionEventStore(
            rootDirectory: root,
            faultInjector: JSONCompetitionEventStoreFaultInjector(
                writeBehaviors: [.zero]
            )
        )
        let genesis = try makeGenesis()

        do {
            _ = try await store.create(genesis)
            XCTFail("Expected zero-byte write failure")
        } catch {
            XCTAssertEqual(
                error as? JSONCompetitionEventStoreError,
                .shortWrite
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: primaryURL(root: root, id: genesis.competitionID).path
            )
        )
    }

    func testWriteFailureLeavesPublishedJournalAndBackupNamespaceUnchanged() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let normalStore = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()
        let created = try await normalStore.create(genesis)
        let primary = primaryURL(root: root, id: genesis.competitionID)
        let primaryBytes = try Data(contentsOf: primary)
        let failingStore = JSONCompetitionEventStore(
            rootDirectory: root,
            faultInjector: JSONCompetitionEventStoreFaultInjector(
                writeBehaviors: [.fail(code: ENOSPC)]
            )
        )

        do {
            _ = try await failingStore.append(
                [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
                to: genesis.competitionID,
                expectedCursor: created.cursor
            )
            XCTFail("Expected injected write failure")
        } catch {
            XCTAssertEqual(
                error as? JSONCompetitionEventStoreError,
                .posix(operation: "write journal temporary", code: ENOSPC)
            )
        }

        XCTAssertEqual(try Data(contentsOf: primary), primaryBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: previousURL(
                    root: root,
                    id: genesis.competitionID
                ).path
            )
        )
        XCTAssertEqual(
            try temporaryURLs(root: root, id: genesis.competitionID),
            []
        )
    }

    func testFullSyncFailureIsTypedAndDoesNotPublishPrimary() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let genesis = try makeGenesis()
        let store = JSONCompetitionEventStore(
            rootDirectory: root,
            faultInjector: JSONCompetitionEventStoreFaultInjector(
                fullSyncFailureCode: EIO
            )
        )

        do {
            _ = try await store.create(genesis)
            XCTFail("Expected full-sync failure")
        } catch {
            XCTAssertEqual(
                error as? JSONCompetitionEventStoreError,
                .posix(operation: "full fsync new temporary", code: EIO)
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: primaryURL(
                    root: root,
                    id: genesis.competitionID
                ).path
            )
        )
        XCTAssertEqual(
            try temporaryURLs(root: root, id: genesis.competitionID),
            []
        )
    }

    func testDeleteRequiresCurrentCursorBeforeTombstoneCommit() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()
        let created = try await store.create(genesis)
        let current = try await store.append(
            [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
            to: genesis.competitionID,
            expectedCursor: created.cursor
        )
        let primary = primaryURL(root: root, id: genesis.competitionID)
        let before = try Data(contentsOf: primary)

        do {
            try await store.delete(
                genesis.competitionID,
                expectedCursor: created.cursor
            )
            XCTFail("Expected cursor conflict")
        } catch {
            XCTAssertEqual(
                error as? CompetitionEventStoreError,
                .cursorConflict(
                    expected: created.cursor,
                    actual: current.cursor
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: primary), before)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tombstoneURL(root: root, id: genesis.competitionID).path
            )
        )
    }

    func testDurableTombstonePreventsResurrectionAndMakesDeleteRetryIdempotent() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()
        let created = try await store.create(genesis)
        let current = try await store.append(
            [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
            to: genesis.competitionID,
            expectedCursor: created.cursor
        )
        let primary = primaryURL(root: root, id: genesis.competitionID)
        let previous = previousURL(root: root, id: genesis.competitionID)
        let primaryBytes = try Data(contentsOf: primary)
        let previousBytes = try Data(contentsOf: previous)

        try await store.delete(
            genesis.competitionID,
            expectedCursor: current.cursor
        )
        try await store.delete(
            genesis.competitionID,
            expectedCursor: created.cursor
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tombstoneURL(root: root, id: genesis.competitionID).path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: primary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
        let loadedAfterDelete = try await store.load(genesis.competitionID)
        XCTAssertNil(loadedAfterDelete)
        let idsAfterDelete = try await store.ids()
        XCTAssertEqual(idsAfterDelete, [])

        try primaryBytes.write(to: primary)
        try previousBytes.write(to: previous)
        let loadedAfterRestore = try await store.load(genesis.competitionID)
        XCTAssertNil(loadedAfterRestore)
        let idsAfterRestore = try await store.ids()
        XCTAssertEqual(idsAfterRestore, [])

        do {
            _ = try await store.create(genesis)
            XCTFail("Expected tombstoned identity rejection")
        } catch {
            XCTAssertEqual(
                error as? CompetitionEventStoreError,
                .identityWasDeleted
            )
        }
        do {
            _ = try await store.append(
                [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
                to: genesis.competitionID,
                expectedCursor: current.cursor
            )
            XCTFail("Expected tombstoned identity rejection")
        } catch {
            XCTAssertEqual(
                error as? CompetitionEventStoreError,
                .identityWasDeleted
            )
        }
    }

    func testFutureVersionsNeverFallbackOrMutateFiles() async throws {
        let cases: [(FutureVersionField, CompetitionJournalError)] = [
            (
                .genesis,
                .upgradeRequiredGenesisVersion(found: 999)
            ),
            (
                .journal,
                .upgradeRequiredJournalVersion(found: 999)
            ),
            (
                .envelope,
                .upgradeRequiredEnvelopeVersion(sequence: 1, found: 999)
            ),
            (
                .payload,
                .upgradeRequiredPayloadVersion(sequence: 1, found: 999)
            ),
        ]

        for (field, expectedError) in cases {
            for futureIsPrimary in [true, false] {
                let root = makeTemporaryRoot()
                let store = JSONCompetitionEventStore(rootDirectory: root)
                let genesis = try makeGenesis()
                let created = try await store.create(genesis)
                let accepted = try await store.append(
                    [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
                    to: genesis.competitionID,
                    expectedCursor: created.cursor
                )
                _ = try await store.append(
                    [
                        .activityRefreshAttemptRecorded(
                            try makeActivityRefreshEvent(
                                id: "future-version-source",
                                genesis: genesis,
                                points: 300
                            )
                        ),
                    ],
                    to: genesis.competitionID,
                    expectedCursor: accepted.cursor
                )
                let primary = primaryURL(
                    root: root,
                    id: genesis.competitionID
                )
                let previous = previousURL(
                    root: root,
                    id: genesis.competitionID
                )
                let originalPrimary = try Data(contentsOf: primary)
                let originalPrevious = try Data(contentsOf: previous)
                let futureURL = futureIsPrimary ? primary : previous
                let futureBytes = try futureVersionData(
                    from: futureIsPrimary
                        ? originalPrimary
                        : originalPrevious,
                    field: field
                )
                try futureBytes.write(to: futureURL)
                let staleTemporary = staleTemporaryURL(
                    root: root,
                    id: genesis.competitionID,
                    role: "new"
                )
                let staleBytes = Data("must survive upgrade refusal".utf8)
                try staleBytes.write(to: staleTemporary)

                do {
                    _ = try await store.load(genesis.competitionID)
                    XCTFail(
                        "Expected upgrade requirement for \(field) in "
                            + (futureIsPrimary ? "primary" : "previous")
                    )
                } catch {
                    XCTAssertEqual(
                        error as? CompetitionEventStoreError,
                        .journal(expectedError),
                        "Unexpected error for \(field)"
                    )
                }
                XCTAssertEqual(
                    try Data(contentsOf: primary),
                    futureIsPrimary ? futureBytes : originalPrimary
                )
                XCTAssertEqual(
                    try Data(contentsOf: previous),
                    futureIsPrimary ? originalPrevious : futureBytes
                )
                XCTAssertEqual(
                    try Data(contentsOf: staleTemporary),
                    staleBytes
                )
                XCTAssertEqual(
                    try quarantineURLs(root: root, id: genesis.competitionID),
                    []
                )
                try FileManager.default.removeItem(at: root)
            }
        }
    }

    func testDivergentValidCandidatesFailClosedWithoutMutation() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let genesis = try makeGenesis()
        var primaryJournal = try CompetitionJournal(genesis: genesis)
        _ = try primaryJournal.append(
            [
                .lifecycle(
                    try makeAcceptanceEvent(genesis: genesis, seed: 42)
                ),
            ],
            expectedCursor: primaryJournal.cursor
        )
        var previousJournal = try CompetitionJournal(genesis: genesis)
        _ = try previousJournal.append(
            [
                .lifecycle(
                    try makeAcceptanceEvent(genesis: genesis, seed: 99)
                ),
            ],
            expectedCursor: previousJournal.cursor
        )
        XCTAssertEqual(
            primaryJournal.relationship(to: previousJournal),
            .divergent
        )
        let primary = primaryURL(root: root, id: genesis.competitionID)
        let previous = previousURL(root: root, id: genesis.competitionID)
        let primaryBytes = try pinnedEncoder().encode(primaryJournal)
        let previousBytes = try pinnedEncoder().encode(previousJournal)
        try primaryBytes.write(to: primary)
        try previousBytes.write(to: previous)

        do {
            _ = try await JSONCompetitionEventStore(rootDirectory: root)
                .load(genesis.competitionID)
            XCTFail("Expected divergent-candidate failure")
        } catch {
            XCTAssertEqual(
                error as? JSONCompetitionEventStoreError,
                .divergentSnapshots
            )
        }
        XCTAssertEqual(try Data(contentsOf: primary), primaryBytes)
        XCTAssertEqual(try Data(contentsOf: previous), previousBytes)
    }

    func testBothCorruptCandidatesFailClosedWithoutMutation() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()
        let created = try await store.create(genesis)
        _ = try await store.append(
            [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
            to: genesis.competitionID,
            expectedCursor: created.cursor
        )
        let primary = primaryURL(root: root, id: genesis.competitionID)
        let previous = previousURL(root: root, id: genesis.competitionID)
        let primaryBytes = Data("corrupt primary".utf8)
        let previousBytes = Data("corrupt previous".utf8)
        try primaryBytes.write(to: primary)
        try previousBytes.write(to: previous)

        do {
            _ = try await store.load(genesis.competitionID)
            XCTFail("Expected corrupt-candidate failure")
        } catch {
            XCTAssertEqual(
                error as? JSONCompetitionEventStoreError,
                .corruptPrimaryAndPrevious
            )
        }

        XCTAssertEqual(try Data(contentsOf: primary), primaryBytes)
        XCTAssertEqual(try Data(contentsOf: previous), previousBytes)
        let quarantineCount = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".corrupt.") }.count
        XCTAssertEqual(quarantineCount, 0)
    }

    func testJournalIdentityMustMatchRequestedFilenameIdentity() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let storedGenesis = try makeGenesis()
        let requestedID = CompetitionID(
            UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        )
        let mismatchedBytes = try pinnedEncoder().encode(
            CompetitionJournal(genesis: storedGenesis)
        )
        let requestedPrimary = primaryURL(root: root, id: requestedID)
        try mismatchedBytes.write(to: requestedPrimary)

        do {
            _ = try await JSONCompetitionEventStore(rootDirectory: root)
                .load(requestedID)
            XCTFail("Expected filename/journal identity mismatch to fail closed")
        } catch {
            XCTAssertEqual(
                error as? JSONCompetitionEventStoreError,
                .corruptPrimaryAndPrevious
            )
        }
        XCTAssertEqual(try Data(contentsOf: requestedPrimary), mismatchedBytes)
        XCTAssertEqual(try quarantineURLs(root: root, id: requestedID), [])
    }

    func testPrimaryReadIOFailureNeverFallsBackOrMutatesNamespace() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let normalStore = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()
        let created = try await normalStore.create(genesis)
        _ = try await normalStore.append(
            [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
            to: genesis.competitionID,
            expectedCursor: created.cursor
        )
        let primary = primaryURL(root: root, id: genesis.competitionID)
        let previous = previousURL(root: root, id: genesis.competitionID)
        let primaryBytes = try Data(contentsOf: primary)
        let previousBytes = try Data(contentsOf: previous)
        let staleTemporary = staleTemporaryURL(
            root: root,
            id: genesis.competitionID,
            role: "recovery"
        )
        let staleBytes = Data("read-error-temp-must-remain".utf8)
        try staleBytes.write(to: staleTemporary)
        let failingStore = JSONCompetitionEventStore(
            rootDirectory: root,
            faultInjector: JSONCompetitionEventStoreFaultInjector(
                readFailure: .init(role: .primary, code: EIO)
            )
        )

        do {
            _ = try await failingStore.load(genesis.competitionID)
            XCTFail("Expected injected primary read error")
        } catch {
            XCTAssertEqual(
                error as? JSONCompetitionEventStoreError,
                .posix(operation: "read journal primary", code: EIO)
            )
        }

        XCTAssertEqual(try Data(contentsOf: primary), primaryBytes)
        XCTAssertEqual(try Data(contentsOf: previous), previousBytes)
        XCTAssertEqual(try Data(contentsOf: staleTemporary), staleBytes)
        XCTAssertEqual(
            try quarantineURLs(root: root, id: genesis.competitionID),
            []
        )
    }

    func testCorruptPrimaryRecoversPreviousAndQuarantinesExactBytes() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()
        let created = try await store.create(genesis)
        _ = try await store.append(
            [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
            to: genesis.competitionID,
            expectedCursor: created.cursor
        )
        let primary = primaryURL(root: root, id: genesis.competitionID)
        let previous = previousURL(root: root, id: genesis.competitionID)
        let previousBytes = try Data(contentsOf: previous)
        let corruptBytes = Data("not valid journal json".utf8)
        try corruptBytes.write(to: primary)

        let optionalLoaded = try await JSONCompetitionEventStore(
            rootDirectory: root
        ).load(genesis.competitionID)
        let loaded = try XCTUnwrap(optionalLoaded)
        let quarantineURLs = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(
                "\(genesis.competitionID.rawValue.uuidString.lowercased()).corrupt."
            )
        }

        XCTAssertEqual(loaded.source, .recoveredPrevious)
        XCTAssertEqual(loaded.journal.cursor, created.cursor)
        XCTAssertEqual(try Data(contentsOf: primary), previousBytes)
        XCTAssertEqual(quarantineURLs.count, 1)
        XCTAssertEqual(try Data(contentsOf: quarantineURLs[0]), corruptBytes)
        XCTAssertEqual(try Data(contentsOf: previous), previousBytes)
    }

    func testIndependentStoresSerializeIdenticalAppendAsOneCommitAndOneRetry() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = JSONCompetitionEventStore(rootDirectory: root)
        let secondStore = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()
        let created = try await firstStore.create(genesis)
        let accepted = try await firstStore.append(
            [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
            to: genesis.competitionID,
            expectedCursor: created.cursor
        )
        let event = CompetitionDomainEvent.activityRefreshAttemptRecorded(
            try makeActivityRefreshEvent(
                id: "concurrent-identical",
                genesis: genesis,
                points: 300
            )
        )

        async let firstAttempt = appendAttempt(
            store: firstStore,
            event: event,
            id: genesis.competitionID,
            cursor: accepted.cursor
        )
        async let secondAttempt = appendAttempt(
            store: secondStore,
            event: event,
            id: genesis.competitionID,
            cursor: accepted.cursor
        )
        let attempts = await [firstAttempt, secondAttempt]
        let successes = attempts.compactMap(\.result)
        let optionalLoaded = try await firstStore.load(genesis.competitionID)
        let loaded = try XCTUnwrap(optionalLoaded)

        XCTAssertEqual(successes.count, 2)
        XCTAssertEqual(successes.map(\.appendedCount).sorted(), [0, 1])
        XCTAssertTrue(attempts.allSatisfy { $0.error == nil })
        XCTAssertEqual(loaded.journal.cursor, successes[0].cursor)
        XCTAssertEqual(loaded.journal.cursor, successes[1].cursor)
    }

    func testIndependentStoresSerializeIdenticalCreateAsOneCommitAndOneRetry() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = JSONCompetitionEventStore(rootDirectory: root)
        let secondStore = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()

        async let first = createAttempt(store: firstStore, genesis: genesis)
        async let second = createAttempt(store: secondStore, genesis: genesis)
        let attempts = await [first, second]
        let successes = attempts.compactMap(\.result)

        XCTAssertTrue(attempts.allSatisfy { $0.error == nil })
        XCTAssertEqual(successes.count, 2)
        XCTAssertEqual(successes.filter(\.created).count, 1)
        XCTAssertEqual(successes.filter { !$0.created }.count, 1)
        XCTAssertEqual(successes[0].cursor, successes[1].cursor)
        let optionalLoaded = try await firstStore.load(genesis.competitionID)
        XCTAssertEqual(
            try XCTUnwrap(optionalLoaded).journal.cursor,
            successes[0].cursor
        )
    }

    func testIndependentStoresSerializeDistinctSameCursorAppends() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = JSONCompetitionEventStore(rootDirectory: root)
        let secondStore = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()
        let created = try await firstStore.create(genesis)
        let accepted = try await firstStore.append(
            [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
            to: genesis.competitionID,
            expectedCursor: created.cursor
        )
        let firstEvent = try makeActivityRefreshEvent(
            id: "concurrent-first",
            genesis: genesis,
            points: 300
        )
        let secondEvent = try makeCompetitionStartedEvent(genesis: genesis)

        async let firstAttempt = appendAttempt(
            store: firstStore,
            event: .activityRefreshAttemptRecorded(firstEvent),
            id: genesis.competitionID,
            cursor: accepted.cursor
        )
        async let secondAttempt = appendAttempt(
            store: secondStore,
            event: .lifecycle(secondEvent),
            id: genesis.competitionID,
            cursor: accepted.cursor
        )
        let attempts = await [firstAttempt, secondAttempt]
        let successes = attempts.compactMap(\.result)
        let failures = attempts.compactMap(\.error)
        let optionalLoaded = try await firstStore.load(genesis.competitionID)
        let loaded = try XCTUnwrap(optionalLoaded)

        XCTAssertEqual(successes.count, 1)
        XCTAssertEqual(successes.first?.appendedCount, 1)
        XCTAssertEqual(failures.count, 1)
        guard case let .cursorConflict(expected, actual) = failures.first else {
            return XCTFail("Expected one cursor conflict, got \(failures)")
        }
        XCTAssertEqual(expected, accepted.cursor)
        XCTAssertEqual(actual, successes[0].cursor)
        XCTAssertEqual(loaded.journal.cursor, successes[0].cursor)
    }

    func testIndependentStoresSerializeAppendAgainstDelete() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let appendStore = JSONCompetitionEventStore(rootDirectory: root)
        let deleteStore = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()
        let created = try await appendStore.create(genesis)
        let accepted = try await appendStore.append(
            [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
            to: genesis.competitionID,
            expectedCursor: created.cursor
        )
        let event = CompetitionDomainEvent.activityRefreshAttemptRecorded(
            try makeActivityRefreshEvent(
                id: "append-delete-race",
                genesis: genesis,
                points: 300
            )
        )

        async let append = appendAttempt(
            store: appendStore,
            event: event,
            id: genesis.competitionID,
            cursor: accepted.cursor
        )
        async let delete = deleteAttempt(
            store: deleteStore,
            id: genesis.competitionID,
            cursor: accepted.cursor
        )
        let (appendResult, deleteResult) = await (append, delete)

        if let committedAppend = appendResult.result {
            XCTAssertFalse(deleteResult.succeeded)
            XCTAssertEqual(
                deleteResult.error,
                .cursorConflict(
                    expected: accepted.cursor,
                    actual: committedAppend.cursor
                )
            )
            let optionalLoaded = try await appendStore.load(
                genesis.competitionID
            )
            XCTAssertEqual(
                try XCTUnwrap(optionalLoaded).journal.cursor,
                committedAppend.cursor
            )
        } else {
            XCTAssertEqual(appendResult.error, .identityWasDeleted)
            XCTAssertTrue(deleteResult.succeeded)
            let loadedAfterDelete = try await appendStore.load(
                genesis.competitionID
            )
            XCTAssertNil(loadedAfterDelete)
        }
    }

    func testStaleCursorWithNewEventDoesNotMutatePrimary() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()
        let created = try await store.create(genesis)
        let acceptance = try makeAcceptanceEvent(genesis: genesis)
        let current = try await store.append(
            [.lifecycle(acceptance)],
            to: genesis.competitionID,
            expectedCursor: created.cursor
        )
        let event = try makeActivityRefreshEvent(
            id: "new-reading",
            genesis: genesis,
            points: 300
        )
        let primary = primaryURL(root: root, id: genesis.competitionID)
        let before = try Data(contentsOf: primary)

        do {
            _ = try await store.append(
                [.activityRefreshAttemptRecorded(event)],
                to: genesis.competitionID,
                expectedCursor: created.cursor
            )
            XCTFail("Expected cursor conflict")
        } catch {
            XCTAssertEqual(
                error as? CompetitionEventStoreError,
                .cursorConflict(
                    expected: created.cursor,
                    actual: current.cursor
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: primary), before)
    }

    func testInvalidBatchIsAtomicAndDoesNotMutatePrimary() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()
        let created = try await store.create(genesis)
        let acceptance = try makeAcceptanceEvent(genesis: genesis)
        let activityBeforeAcceptance = try makeActivityRefreshEvent(
            id: "out-of-order-reading",
            genesis: genesis,
            points: 300
        )
        let primary = primaryURL(root: root, id: genesis.competitionID)
        let before = try Data(contentsOf: primary)

        do {
            _ = try await store.append(
                [
                    .activityRefreshAttemptRecorded(activityBeforeAcceptance),
                    .lifecycle(acceptance),
                ],
                to: genesis.competitionID,
                expectedCursor: created.cursor
            )
            XCTFail("Expected invalid transition")
        } catch {
            XCTAssertEqual(
                error as? CompetitionEventStoreError,
                .journal(.invalidDomainTransition(sequence: 1))
            )
        }
        XCTAssertEqual(try Data(contentsOf: primary), before)
    }

    func testSemanticConflictDoesNotMutatePrimary() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()
        let created = try await store.create(genesis)
        let acceptance = try makeAcceptanceEvent(genesis: genesis)
        let accepted = try await store.append(
            [.lifecycle(acceptance)],
            to: genesis.competitionID,
            expectedCursor: created.cursor
        )
        let original = try makeActivityRefreshEvent(
            id: "same-reading",
            genesis: genesis,
            points: 300
        )
        let appended = try await store.append(
            [.activityRefreshAttemptRecorded(original)],
            to: genesis.competitionID,
            expectedCursor: accepted.cursor
        )
        let conflicting = try makeActivityRefreshEvent(
            id: "same-reading",
            genesis: genesis,
            points: 400
        )
        let primary = primaryURL(root: root, id: genesis.competitionID)
        let before = try Data(contentsOf: primary)

        do {
            _ = try await store.append(
                [.activityRefreshAttemptRecorded(conflicting)],
                to: genesis.competitionID,
                expectedCursor: appended.cursor
            )
            XCTFail("Expected semantic conflict")
        } catch {
            XCTAssertEqual(
                error as? CompetitionEventStoreError,
                .journal(
                    .semanticEventConflict(
                        eventID: original.semanticEventID
                    )
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: primary), before)
    }

    func testExactDuplicateWithStaleCursorDoesNotRewritePrimary() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()
        let created = try await store.create(genesis)
        let acceptance = try makeAcceptanceEvent(genesis: genesis)
        let accepted = try await store.append(
            [.lifecycle(acceptance)],
            to: genesis.competitionID,
            expectedCursor: created.cursor
        )
        let event = try makeActivityRefreshEvent(
            id: "duplicate-reading",
            genesis: genesis,
            points: 300
        )
        let first = try await store.append(
            [.activityRefreshAttemptRecorded(event)],
            to: genesis.competitionID,
            expectedCursor: accepted.cursor
        )
        let primary = primaryURL(root: root, id: genesis.competitionID)
        let bytesBefore = try Data(contentsOf: primary)
        let dateBefore = try modificationDate(primary)

        let retry = try await store.append(
            [.activityRefreshAttemptRecorded(event)],
            to: genesis.competitionID,
            expectedCursor: accepted.cursor
        )

        XCTAssertEqual(retry.appendedCount, 0)
        XCTAssertEqual(retry.cursor, first.cursor)
        XCTAssertEqual(try Data(contentsOf: primary), bytesBefore)
        XCTAssertEqual(try modificationDate(primary), dateBefore)
    }

    func testIdenticalCreateIsIdempotentWithoutRewritingPrimary() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()
        let first = try await store.create(genesis)
        let primary = primaryURL(root: root, id: genesis.competitionID)
        let bytesBefore = try Data(contentsOf: primary)
        let dateBefore = try modificationDate(primary)

        let second = try await store.create(genesis)

        XCTAssertTrue(first.created)
        XCTAssertFalse(second.created)
        XCTAssertEqual(second.cursor, first.cursor)
        XCTAssertEqual(try Data(contentsOf: primary), bytesBefore)
        XCTAssertEqual(try modificationDate(primary), dateBefore)
    }

    func testAppendPersistsAndReplaysActivityRefreshEvent() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()
        let created = try await store.create(genesis)
        let event = try makeActivityRefreshEvent(
            id: "day-1-reading",
            genesis: genesis,
            points: 325
        )
        let acceptance = try makeAcceptanceEvent(genesis: genesis)

        let appended = try await store.append(
            [
                .lifecycle(acceptance),
                .activityRefreshAttemptRecorded(event),
            ],
            to: genesis.competitionID,
            expectedCursor: created.cursor
        )
        let optionalLoaded = try await store.load(genesis.competitionID)
        let loaded = try XCTUnwrap(optionalLoaded)

        XCTAssertEqual(appended.appendedCount, 2)
        XCTAssertEqual(appended.cursor, loaded.journal.cursor)
        XCTAssertEqual(
            loaded.projection.scoreLedger.entry(forDayOrdinal: 1)?
                .acceptedScore?.points,
            325
        )
    }

    func testIDsListsCreatedCompetition() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()

        let initially = try await store.ids()
        XCTAssertEqual(initially, [])
        _ = try await store.create(genesis)

        let afterCreate = try await store.ids()
        XCTAssertEqual(afterCreate, [genesis.competitionID])
    }

    func testIDsDiscoversPreviousOnlyCandidateAndLoadRecoversIt() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()
        let created = try await store.create(genesis)
        _ = try await store.append(
            [.lifecycle(try makeAcceptanceEvent(genesis: genesis))],
            to: genesis.competitionID,
            expectedCursor: created.cursor
        )
        let primary = primaryURL(root: root, id: genesis.competitionID)
        let previous = previousURL(root: root, id: genesis.competitionID)
        let previousBytes = try Data(contentsOf: previous)
        try FileManager.default.removeItem(at: primary)

        let restarted = JSONCompetitionEventStore(rootDirectory: root)
        let ids = try await restarted.ids()
        let optionalLoaded = try await restarted.load(genesis.competitionID)
        let loaded = try XCTUnwrap(optionalLoaded)

        XCTAssertEqual(ids, [genesis.competitionID])
        XCTAssertEqual(loaded.journal.cursor, created.cursor)
        XCTAssertEqual(try Data(contentsOf: primary), previousBytes)
    }

    func testIDsResumesTombstonedCleanupWithoutDeletingQuarantineOnlyEvidence() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let deletedGenesis = try makeGenesis()
        let evidenceOnlyID = CompetitionID(
            UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )
        _ = try await JSONCompetitionEventStore(rootDirectory: root).ids()
        let tombstone = tombstoneURL(
            root: root,
            id: deletedGenesis.competitionID
        )
        let deletedQuarantine = root.appendingPathComponent(
            "\(deletedGenesis.competitionID.rawValue.uuidString.lowercased())"
                + ".corrupt.11111111-1111-1111-1111-111111111111.json"
        )
        let evidenceOnlyQuarantine = root.appendingPathComponent(
            "\(evidenceOnlyID.rawValue.uuidString.lowercased())"
                + ".corrupt.22222222-2222-2222-2222-222222222222.json"
        )
        try Data("deleted".utf8).write(to: tombstone)
        try Data("must be cleaned".utf8).write(to: deletedQuarantine)
        try Data("must remain".utf8).write(to: evidenceOnlyQuarantine)

        let ids = try await JSONCompetitionEventStore(rootDirectory: root)
            .ids()

        XCTAssertEqual(ids, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombstone.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: deletedQuarantine.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: evidenceOnlyQuarantine.path
            )
        )
    }

    func testCreateThenLoadReplaysGenesisFromPrimary() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONCompetitionEventStore(rootDirectory: root)
        let genesis = try makeGenesis()

        let created = try await store.create(genesis)
        let optionalLoaded = try await store.load(genesis.competitionID)
        let loaded = try XCTUnwrap(optionalLoaded)

        XCTAssertTrue(created.created)
        XCTAssertEqual(created.cursor, loaded.journal.cursor)
        XCTAssertEqual(loaded.source, .primary)
        XCTAssertEqual(loaded.journal.genesis, genesis)
        XCTAssertEqual(
            loaded.projection.competition,
            genesis.makeCompetition()
        )
        XCTAssertEqual(
            loaded.projection.scoreLedger,
            genesis.makeScoreLedger()
        )
    }

    private func makeTemporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "health-comp-event-store-tests-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func primaryURL(root: URL, id: CompetitionID) -> URL {
        root.appendingPathComponent(
            "\(id.rawValue.uuidString.lowercased()).journal.json"
        )
    }

    private func previousURL(root: URL, id: CompetitionID) -> URL {
        root.appendingPathComponent(
            "\(id.rawValue.uuidString.lowercased()).journal.previous.json"
        )
    }

    private func tombstoneURL(root: URL, id: CompetitionID) -> URL {
        root.appendingPathComponent(
            "\(id.rawValue.uuidString.lowercased()).deleted"
        )
    }

    private func staleTemporaryURL(
        root: URL,
        id: CompetitionID,
        role: String
    ) -> URL {
        root.appendingPathComponent(
            ".\(id.rawValue.uuidString.lowercased()).\(role)."
                + "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.tmp"
        )
    }

    private func temporaryURLs(
        root: URL,
        id: CompetitionID
    ) throws -> [URL] {
        let prefix = ".\(id.rawValue.uuidString.lowercased())."
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(prefix)
                && $0.lastPathComponent.hasSuffix(".tmp")
        }
    }

    private func quarantineURLs(
        root: URL,
        id: CompetitionID
    ) throws -> [URL] {
        let prefix = "\(id.rawValue.uuidString.lowercased()).corrupt."
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(prefix)
                && $0.lastPathComponent.hasSuffix(".json")
        }
    }

    private func modificationDate(_ url: URL) throws -> Date {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[
                .modificationDate
            ] as? Date
        )
    }

    private func systemFileNumber(_ url: URL) throws -> UInt64 {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[
                .systemFileNumber
            ] as? NSNumber
        ).uint64Value
    }

    private func assertPrivateAttributes(
        _ url: URL,
        permissions: Int,
        protectionRecorder: FileProtectionRecorder
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let actualPermissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(actualPermissions, permissions, url.lastPathComponent)
        XCTAssertEqual(
            try protectionRecorder.protectionApplied(to: url),
            .completeUntilFirstUserAuthentication,
            url.lastPathComponent
        )
    }

    private func pinnedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.nonConformingFloatEncodingStrategy = .throw
        return encoder
    }

    private enum FutureVersionField: Equatable, CustomStringConvertible {
        case genesis
        case journal
        case envelope
        case payload

        var description: String {
            switch self {
            case .genesis: "genesis"
            case .journal: "journal"
            case .envelope: "envelope"
            case .payload: "payload"
            }
        }
    }

    private func futureVersionData(
        from data: Data,
        field: FutureVersionField
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        switch field {
        case .genesis:
            var genesis = try XCTUnwrap(
                object["genesis"] as? [String: Any]
            )
            genesis["version"] = 999
            object["genesis"] = genesis
        case .journal:
            object["journalVersion"] = 999
        case .envelope, .payload:
            var envelopes = try XCTUnwrap(
                object["envelopes"] as? [[String: Any]]
            )
            XCTAssertFalse(envelopes.isEmpty)
            envelopes[0][
                field == .envelope ? "envelopeVersion" : "payloadVersion"
            ] = 999
            object["envelopes"] = envelopes
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    private func makeGenesis(
        id: CompetitionID = CompetitionID(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
    ) throws -> CompetitionGenesis {
        try CompetitionGenesis(
            competitionID: id,
            direction: .incoming,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            expiresAt: Date(timeIntervalSinceReferenceDate: 200),
            scoringPolicy: .appleCompatibility,
            downwardRevisionPolicy: .maximumObserved
        )
    }

    private func makeActivityRefreshEvent(
        id: String,
        genesis: CompetitionGenesis,
        points: Double
    ) throws -> ActivityRefreshAttemptRecorded {
        var competition = genesis.makeCompetition()
        let engine = CompetitionEngine()
        try engine.apply(
            try makeAcceptanceEvent(genesis: genesis),
            to: &competition
        )
        let schedule = try XCTUnwrap(competition.schedule)
        let days = try schedule.calendar.sevenDayWindow(
            startingOn: schedule.startDay
        )
        let readAt = try schedule.calendar.startOfDay(days[0])
            .addingTimeInterval(1)
        let snapshot = ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: points / 100, goal: 1),
            exercise: try ActivityRingReading(value: 0, goal: 1),
            standOrRoll: try ActivityRingReading(value: 0, goal: 1),
            isPaused: false
        )
        return try ActivityRefreshAttemptRecorded(
            attemptID: id,
            competitionID: genesis.competitionID,
            attemptOrdinal: 1,
            trigger: .foreground,
            attemptedAt: readAt.addingTimeInterval(-1),
            readAt: readAt,
            monotonicInstant: MonotonicInstant(
                epochID: "json-store-tests",
                nanoseconds: 1_000
            ),
            readStatus: .completed,
            days: zip(1...7, days).map { ordinal, day in
                ActivityDayObservation(
                    day: day,
                    ordinal: ordinal,
                    availability: ordinal == 1
                        ? .observed(snapshot)
                        : .notYetOccurred
                )
            }
        )
    }

    private func makeCompetitionStartedEvent(
        genesis: CompetitionGenesis
    ) throws -> CompetitionEvent {
        var competition = genesis.makeCompetition()
        let engine = CompetitionEngine()
        try engine.apply(
            try makeAcceptanceEvent(genesis: genesis),
            to: &competition
        )
        let schedule = try XCTUnwrap(competition.schedule)
        let startedAt = try schedule.calendar.startOfDay(schedule.startDay)
        return try XCTUnwrap(
            engine.observeClock(competition, at: startedAt).first
        )
    }

    private func makeAcceptanceEvent(
        genesis: CompetitionGenesis,
        seed: UInt64 = 42
    ) throws -> CompetitionEvent {
        try CompetitionEngine().accept(
            genesis.makeCompetition(),
            at: Date(timeIntervalSinceReferenceDate: 150),
            timeZoneIdentifier: "America/Los_Angeles",
            opponent: OpponentPlanGenerationRequest(
                seed: seed,
                generatorVersion: .v1,
                difficulty: .balanced
            )
        )
    }

    private struct AppendAttempt: Sendable {
        let result: CompetitionJournalAppendResult?
        let error: CompetitionEventStoreError?
    }

    private struct CreateAttempt: Sendable {
        let result: CompetitionEventStoreCreateResult?
        let error: CompetitionEventStoreError?
    }

    private struct DeleteAttempt: Sendable {
        let succeeded: Bool
        let error: CompetitionEventStoreError?
    }

    private func appendAttempt(
        store: JSONCompetitionEventStore,
        event: CompetitionDomainEvent,
        id: CompetitionID,
        cursor: CompetitionJournalCursor
    ) async -> AppendAttempt {
        do {
            return AppendAttempt(
                result: try await store.append(
                    [event],
                    to: id,
                    expectedCursor: cursor
                ),
                error: nil
            )
        } catch {
            return AppendAttempt(
                result: nil,
                error: error as? CompetitionEventStoreError
            )
        }
    }

    private func createAttempt(
        store: JSONCompetitionEventStore,
        genesis: CompetitionGenesis
    ) async -> CreateAttempt {
        do {
            return CreateAttempt(
                result: try await store.create(genesis),
                error: nil
            )
        } catch {
            return CreateAttempt(
                result: nil,
                error: error as? CompetitionEventStoreError
            )
        }
    }


    private func deleteAttempt(
        store: JSONCompetitionEventStore,
        id: CompetitionID,
        cursor: CompetitionJournalCursor
    ) async -> DeleteAttempt {
        do {
            try await store.delete(id, expectedCursor: cursor)
            return DeleteAttempt(succeeded: true, error: nil)
        } catch {
            return DeleteAttempt(
                succeeded: false,
                error: error as? CompetitionEventStoreError
            )
        }
    }
}

private final class FileProtectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var protectionByFileNumber: [UInt64: FileProtectionType] = [:]

    func record(
        _ protection: FileProtectionType,
        for url: URL
    ) throws {
        let fileNumber = try systemFileNumber(url)
        lock.lock()
        protectionByFileNumber[fileNumber] = protection
        lock.unlock()
    }

    func protectionApplied(
        to url: URL
    ) throws -> FileProtectionType? {
        let fileNumber = try systemFileNumber(url)
        lock.lock()
        defer { lock.unlock() }
        return protectionByFileNumber[fileNumber]
    }

    private func systemFileNumber(_ url: URL) throws -> UInt64 {
        guard let value = try FileManager.default.attributesOfItem(
            atPath: url.path
        )[.systemFileNumber] as? NSNumber else {
            throw FileProtectionRecorderError.missingSystemFileNumber
        }
        return value.uint64Value
    }
}

private enum FileProtectionRecorderError: Error {
    case missingSystemFileNumber
}

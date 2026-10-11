import XCTest
import MeloNXOperationCore
@testable import MeloNXSaveSyncCore

final class SaveSyncEngineTests: XCTestCase {
    @MainActor func testCancelDuringRestoreKeepsLeaseUntilWorkerEnds() async throws {
        let f = SaveEngineFixture(); defer { f.dispose() }
        let snapshot = try await f.installSnapshot()
        await f.engine.prepareDownload(f.game)
        let entered = expectation(description: "native restore entered")
        await f.worker.configureRestore(hold: true, onEntered: { entered.fulfill() })
        let task = Task { await f.engine.restorePrepared(generation: snapshot.generation, allowUserBinding: false) }
        await fulfillment(of: [entered], timeout: 5)
        f.engine.cancel()
        XCTAssertEqual(f.engine.phase, .finishing); XCTAssertTrue(f.gate.busy)
        await f.worker.finish(status: .safelyStopped)
        await task.value
        XCTAssertFalse(f.gate.busy)
        let key = await f.key()
        XCTAssertNil(try f.bindings.read(key: key))
    }
    @MainActor func testStableExportReleasesLocalGateWhileUploadIsStillUnconfirmed() async throws {
        let f = SaveEngineFixture(); defer { f.dispose() }
        let observing = expectation(description: "cloud transfer observing")
        await f.cloud.holdUploads(onEntered: { observing.fulfill() })
        let task = Task { await f.engine.upload(f.game) }
        await fulfillment(of: [observing], timeout: 5)
        XCTAssertFalse(f.gate.busy)
        let lease = try f.gate.acquire(.launch, gameID: 0x100)
        try lease.finish(workerHasEnded: true)
        let key = await f.key()
        XCTAssertNil(try f.bindings.read(key: key))
        await f.cloud.confirmAllFilesUploaded(); await task.value
        let snapshot = await f.cloud.published!
        XCTAssertEqual(f.engine.phase, .uploaded)
        XCTAssertEqual(try f.bindings.read(key: key)?.lastGeneration, snapshot.generation)
    }
    @MainActor func testQueuedUploadSurvivesNewEngineAndRetryDoesNotExportAnotherProgress() async throws {
        let f = SaveEngineFixture(); defer { f.dispose() }
        await f.cloud.setQueued(true)
        await f.engine.upload(f.game)
        XCTAssertEqual(f.engine.phase, .queued)
        let key = await f.key()
        XCTAssertNil(try f.bindings.read(key: key))
        let first = await f.cloud.published!
        await f.cloud.setQueued(false)
        let restarted = SaveSyncEngine(gate: f.gate, native: f.worker, cloud: f.cloud, bindings: f.bindings, ownedRoot: f.root, installationID: UUID())
        await restarted.upload(f.game)
        let exports = await f.worker.exportCount, publications = await f.cloud.publishCount
        XCTAssertEqual(exports, 1); XCTAssertEqual(publications, 1)
        XCTAssertEqual(try f.bindings.read(key: key)?.lastGeneration, first.generation)
    }
    @MainActor func testForeignUserRequiresExplicitBindingBeforeNativeMutation() async throws {
        let f = SaveEngineFixture(); defer { f.dispose() }
        let snapshot = try await f.installSnapshot(owner: foreignFixtureUID)
        await f.engine.prepareDownload(f.game)
        await f.engine.restorePrepared(generation: snapshot.generation, allowUserBinding: false)
        let first = await f.worker.restoreCount
        XCTAssertEqual(first, 0)
        let key = await f.key(); XCTAssertNil(try f.bindings.read(key: key))
        await f.engine.restorePrepared(generation: snapshot.generation, allowUserBinding: true)
        let second = await f.worker.restoreCount
        XCTAssertEqual(second, 1)
        XCTAssertEqual(try f.bindings.read(key: key)?.cloudUID, foreignFixtureUID)
    }
    @MainActor func testChangedCloudAccountCannotReachLocalRestore() async throws {
        let f = SaveEngineFixture(); defer { f.dispose() }
        let snapshot = try await f.installSnapshot()
        await f.engine.prepareDownload(f.game)
        await f.cloud.switchIdentity()
        await f.engine.restorePrepared(generation: snapshot.generation, allowUserBinding: false)
        let calls = await f.worker.restoreCount
        XCTAssertEqual(calls, 0); XCTAssertFalse(f.gate.busy)
    }
    @MainActor func testCompletedButUnpersistedBindingBlocksGameAndDoesNotAcknowledge() async throws {
        let f = SaveEngineFixture(write: { _, _ in throw SaveSyncError.restoreFailed }); defer { f.dispose() }
        let snapshot = try await f.installSnapshot()
        await f.engine.prepareDownload(f.game)
        await f.engine.restorePrepared(generation: snapshot.generation, allowUserBinding: false)
        XCTAssertEqual(f.engine.phase, .recoveryRequired)
        XCTAssertFalse(f.gate.canAcquire(.launch, gameID: 0x100))
        let ack = await f.worker.ackCount
        XCTAssertEqual(ack, 0)
    }
    @MainActor func testPendingNoJITLaunchCannotBeBypassedBySaveExport() async throws {
        let f = SaveEngineFixture(); defer { f.dispose() }
        let launch = try f.gate.acquire(.launch, gameID: 0x100)
        await f.engine.upload(f.game)
        let calls = await f.worker.describeCount
        XCTAssertEqual(calls, 0); XCTAssertTrue(f.gate.busy)
        try launch.finish(workerHasEnded: true)
    }

    @MainActor func testCompletedRestoreRepairsOriginalAccountAfterIdentityChanges() async throws {
        let f = SaveEngineFixture(); defer { f.dispose() }
        let snapshot = try await f.installSnapshot()
        await f.engine.prepareDownload(f.game)
        let original = await f.key()
        let entered = expectation(description: "restore entered")
        await f.worker.configureRestore(hold: true, onEntered: { entered.fulfill() })
        let task = Task { await f.engine.restorePrepared(generation: snapshot.generation, allowUserBinding: false) }
        await fulfillment(of: [entered], timeout: 5)
        await f.cloud.switchIdentity()
        await f.worker.finish(status: .completed); await task.value
        let changed = await f.key()
        XCTAssertEqual(try f.bindings.read(key: original)?.lastGeneration, snapshot.generation)
        XCTAssertNil(try f.bindings.read(key: changed))
        XCTAssertEqual(f.engine.phase, .failed); XCTAssertFalse(f.gate.busy)
    }
    @MainActor func testCancellationAfterCompletedCannotUndoBindingOrClaimRollback() async throws {
        let f = SaveEngineFixture(); defer { f.dispose() }
        let snapshot = try await f.installSnapshot()
        await f.engine.prepareDownload(f.game)
        let entered = expectation(description: "restore entered")
        await f.worker.configureRestore(hold: true, onEntered: { entered.fulfill() })
        let task = Task { await f.engine.restorePrepared(generation: snapshot.generation, allowUserBinding: false) }
        await fulfillment(of: [entered], timeout: 5)
        f.engine.cancel()
        await f.worker.finish(status: .completed); await task.value
        let key = await f.key(), acks = await f.worker.ackCount
        XCTAssertEqual(try f.bindings.read(key: key)?.lastGeneration, snapshot.generation)
        XCTAssertEqual(acks, 1); XCTAssertEqual(f.engine.restoredGeneration, snapshot.generation)
        XCTAssertTrue(f.gate.canAcquire(.launch, gameID: 0x100))
    }
    @MainActor func testQueuedOldBranchCannotReplaceLaterCompletedBinding() async throws {
        let f = SaveEngineFixture(); defer { f.dispose() }
        await f.cloud.setQueued(true); await f.engine.upload(f.game)
        let key = await f.key(), restored = UUID()
        try f.bindings.recordUploaded(key: key, cloudUID: fixtureUID, generation: restored)
        await f.cloud.setQueued(false); await f.engine.upload(f.game)
        let exports = await f.worker.exportCount
        XCTAssertEqual(exports, 1); XCTAssertEqual(f.engine.error, .conflict)
        XCTAssertEqual(try f.bindings.read(key: key)?.lastGeneration, restored)
    }
    @MainActor func testPendingSuccessorNeverDefaultsToVerifiedParent() async throws {
        let f = SaveEngineFixture(); defer { f.dispose() }
        let parent = try await f.installSnapshot()
        let child = try writeSaveFixture(root: f.root.appendingPathComponent("child-fixture"), generation: UUID(), owner: fixtureUID, parent: parent.generation)
        await f.cloud.setListing(CloudListing(versions: [VisibleSnapshot(snapshot: parent, availability: .verified), VisibleSnapshot(snapshot: child, availability: .pending)], unreadableGenerations: []))
        await f.engine.prepareDownload(f.game)
        XCTAssertNil(f.engine.defaultGeneration)
        XCTAssertEqual(f.engine.pendingGenerations, [child.generation])
    }
    @MainActor func testRollbackRequiredStaysBlockedUntilJournalRecoveryActuallyReturns() async throws {
        let f = SaveEngineFixture(); defer { f.dispose() }
        let snapshot = try await f.installSnapshot(); await f.engine.prepareDownload(f.game)
        let entered = expectation(description: "restore entered")
        await f.worker.configureRestore(hold: true, onEntered: { entered.fulfill() })
        let task = Task { await f.engine.restorePrepared(generation: snapshot.generation, allowUserBinding: false) }
        await fulfillment(of: [entered], timeout: 5)
        await f.worker.finish(status: .recoveryRequired); await task.value
        XCTAssertFalse(f.gate.canAcquire(.launch, gameID: 0x100)); XCTAssertFalse(f.gate.busy)
        await f.engine.retryRecovery()
        XCTAssertTrue(f.gate.canAcquire(.launch, gameID: 0x100))
    }

    @MainActor func testChangingGameSelectionCannotRestorePriorGamesPreparedSnapshot() async throws {
        let f = SaveEngineFixture(); defer { f.dispose() }
        let snapshot = try await f.installSnapshot(); await f.engine.prepareDownload(f.game)
        f.engine.resetSelection()
        await f.engine.restorePrepared(generation: snapshot.generation, allowUserBinding: true)
        let restores = await f.worker.restoreCount
        XCTAssertEqual(restores, 0)
        XCTAssertTrue(f.engine.versions.isEmpty)
    }

    @MainActor func testPublicationCancellationAfterLastManifestResumesSameGeneration() async throws {
        let f = SaveEngineFixture(); defer { f.dispose() }
        await f.cloud.setPublicationFailure(true)
        await f.engine.upload(f.game)
        let first = await f.cloud.published!
        await f.cloud.setPublicationFailure(false)
        let restarted = SaveSyncEngine(gate: f.gate, native: f.worker, cloud: f.cloud, bindings: f.bindings, ownedRoot: f.root, installationID: UUID())
        await restarted.upload(f.game)
        let exports = await f.worker.exportCount, latest = await f.cloud.published!
        XCTAssertEqual(exports, 1)
        XCTAssertEqual(latest.generation, first.generation)
        XCTAssertEqual(restarted.phase, .uploaded)
    }
    @MainActor func testQueuedSnapshotRetiresAfterCompletedRestoreAndNextUploadUsesNewParent() async throws {
        let f = SaveEngineFixture(); defer { f.dispose() }
        await f.cloud.setQueued(true); await f.engine.upload(f.game)
        let old = await f.cloud.published!
        let restored = try await f.installSnapshot()
        await f.engine.prepareDownload(f.game)
        await f.engine.restorePrepared(generation: restored.generation, allowUserBinding: false)
        await f.cloud.setQueued(false)
        let restarted = SaveSyncEngine(gate: f.gate, native: f.worker, cloud: f.cloud, bindings: f.bindings, ownedRoot: f.root, installationID: UUID())
        await restarted.upload(f.game)
        let latest = await f.cloud.published!, count = await f.worker.exportCount
        XCTAssertEqual(count, 2)
        XCTAssertEqual(latest.parent, restored.generation)
        XCTAssertNotEqual(latest.generation, old.generation)
        XCTAssertEqual(restarted.phase, .uploaded)
    }
}

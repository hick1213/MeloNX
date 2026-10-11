import XCTest
@testable import MeloNXOperationCore

final class LocalOperationGateTests: XCTestCase {
    @MainActor func testPendingGameCannotReleaseWhileBorrowedJITWorkerRuns() async throws {
        let gate = LocalOperationGate()
        let launch = try gate.acquire(.launch, gameID: 0x100)
        let worker = try launch.retainWorker()
        XCTAssertThrowsError(try launch.finish(workerHasEnded: true))
        XCTAssertTrue(gate.busy)
        try worker.finish()
        try launch.finish(workerHasEnded: true)
        XCTAssertFalse(gate.busy)
    }
    @MainActor func testCancellationDoesNotReleaseLiveLease() async throws {
        let gate = LocalOperationGate()
        let lease = try gate.acquire(.saveRestore, gameID: 0x100)
        XCTAssertThrowsError(try lease.finish(workerHasEnded: false))
        XCTAssertThrowsError(try gate.acquire(.launch, gameID: 0x100))
        try lease.finish(workerHasEnded: true)
        XCTAssertFalse(gate.busy)
    }
    @MainActor func testWaitingForJITBlocksSaveWithoutAnEmulationThread() async throws {
        let gate = LocalOperationGate()
        let launch = try gate.acquire(.launch, gameID: 0x100)
        XCTAssertThrowsError(try gate.acquire(.saveExport, gameID: 0x100))
        try launch.finish(workerHasEnded: true)
        let save = try gate.acquire(.saveExport, gameID: 0x100)
        try save.finish(workerHasEnded: true)
    }
    @MainActor func testRunningGameBlocksOtherGamesSaveAndImport() async throws {
        let gate = LocalOperationGate()
        let game = try gate.acquire(.emulation, gameID: 0x100)
        XCTAssertThrowsError(try gate.acquire(.saveRestore, gameID: 0x200))
        XCTAssertThrowsError(try gate.acquire(.packageImport, gameID: nil))
        try game.finish(workerHasEnded: true)
    }
    @MainActor func testStaleLeaseCannotReleaseNextOperation() async throws {
        let gate = LocalOperationGate()
        let old = try gate.acquire(.saveExport, gameID: 0x100)
        try old.finish(workerHasEnded: true)
        let current = try gate.acquire(.packageImport, gameID: 0x200)
        XCTAssertThrowsError(try old.finish(workerHasEnded: true))
        XCTAssertTrue(gate.busy)
        try current.finish(workerHasEnded: true)
    }
    @MainActor func testUnresolvedRecoveryBlocksOnlyAffectedGame() async throws {
        let gate = LocalOperationGate()
        gate.block(gameIDs: [0x100])
        XCTAssertThrowsError(try gate.acquire(.launch, gameID: 0x100))
        let other = try gate.acquire(.launch, gameID: 0x200)
        try other.finish(workerHasEnded: true)
        let recovery = try gate.acquire(.recovery, gameID: 0x100)
        try recovery.finish(workerHasEnded: true)
        gate.unblock(gameID: 0x100)
        let game = try gate.acquire(.launch, gameID: 0x100)
        try game.finish(workerHasEnded: true)
    }
    @MainActor func testUnknownPackageImportCannotBypassBlockedGame() async throws {
        let gate = LocalOperationGate()
        gate.block(gameIDs: [0x100])
        XCTAssertThrowsError(try gate.acquire(.packageImport, gameID: nil))
    }
    @MainActor func testBootstrapBarrierBlocksLaunchUntilJournalsScanned() async throws {
        let gate = LocalOperationGate()
        gate.setStartupReady(false)
        XCTAssertThrowsError(try gate.acquire(.launch, gameID: 0x200))
        let recovery = try gate.acquire(.recovery, gameID: nil)
        try recovery.finish(workerHasEnded: true)
        gate.setStartupReady(true)
        let launch = try gate.acquire(.launch, gameID: 0x200)
        try launch.finish(workerHasEnded: true)
    }
    @MainActor func testEndingImportBeforeWorkerJoinCannotStartSave() async throws {
        let gate = LocalOperationGate()
        let importing = try gate.acquire(.packageImport, gameID: 0x100)
        XCTAssertThrowsError(try importing.finish(workerHasEnded: false))
        XCTAssertThrowsError(try gate.acquire(.saveExport, gameID: 0x100))
        try importing.finish(workerHasEnded: true)
        let save = try gate.acquire(.saveExport, gameID: 0x100)
        try save.finish(workerHasEnded: true)
    }
}

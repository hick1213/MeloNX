import XCTest
@testable import MeloNXImportCore

@MainActor final class NSZImportEngineTests: XCTestCase {
    func testCancelHoldsWorkerUntilConfirmedEndAndSuppressesCommittedPath() async {
        let engine = NSZImportEngine(), id = UUID(), held = HeldNSZImportWorker()
        held.id = id
        let work = Task { await engine.importFile(worker: held, id: id) }
        await held.waitUntilStarted()
        engine.cancel(id: id)
        XCTAssertEqual(engine.phase, .stopping)
        XCTAssertFalse(engine.canStart)
        XCTAssertTrue(held.cancelRequested)
        held.finishCommitted()
        let result = await work.value
        XCTAssertNil(result)
        XCTAssertEqual(engine.phase, .cancelled)
        XCTAssertTrue(engine.canStart)
    }
    func testStaleCancelAndProgressCannotAffectActiveImport() async {
        let engine = NSZImportEngine(), id = UUID(), held = HeldNSZImportWorker()
        held.id = id
        let work = Task { await engine.importFile(worker: held, id: id) }
        await held.waitUntilStarted()
        engine.cancel(id: UUID())
        engine.updateProgress(id: UUID(), phase: .validating, completed: 5, total: 10)
        XCTAssertFalse(held.cancelRequested)
        XCTAssertEqual(engine.phase, .preparing)
        engine.updateProgress(id: id, phase: .converting, completed: 5, total: 10)
        XCTAssertEqual(engine.completedBytes, 5)
        XCTAssertEqual(engine.phase, .converting)
        held.finishCommitted()
        let result = await work.value
        XCTAssertEqual(result?.operationID, id)
        XCTAssertEqual(engine.phase, .succeeded)
    }
    func testDuplicateWorkerCannotRunOrReleaseFirstWorker() async {
        let engine = NSZImportEngine(), first = HeldNSZImportWorker(), second = HeldNSZImportWorker()
        let work = Task { await engine.importFile(worker: first, id: first.id) }
        await first.waitUntilStarted()
        let duplicate = await engine.importFile(worker: second, id: second.id)
        XCTAssertNil(duplicate)
        XCTAssertFalse(second.started)
        XCTAssertFalse(engine.canStart)
        first.finishCommitted()
        _ = await work.value
    }
    func testTaskCancellationRevokesIntentButStillWaitsForNativeWorker() async {
        let engine = NSZImportEngine(), held = HeldNSZImportWorker()
        let work = Task { await engine.importFile(worker: held, id: held.id) }
        await held.waitUntilStarted(); work.cancel()
        while !held.cancelRequested { await Task.yield() }
        XCTAssertFalse(engine.canStart)
        held.finishCommitted()
        let result = await work.value
        XCTAssertNil(result)
        XCTAssertTrue(engine.canStart)
    }
    func testForeignResultAndWorkerErrorHaveOneTerminalFailure() async {
        let engine = NSZImportEngine(), held = HeldNSZImportWorker()
        let work = Task { await engine.importFile(worker: held, id: UUID()) }
        await held.waitUntilStarted(); held.finishCommitted()
        let result = await work.value
        XCTAssertNil(result)
        XCTAssertEqual(engine.phase, .failed)
        let errorWorker = HeldNSZImportWorker()
        let errorWork = Task { await engine.importFile(worker: errorWorker, id: errorWorker.id) }
        await errorWorker.waitUntilStarted(); errorWorker.finishError()
        _ = await errorWork.value
        XCTAssertEqual(engine.phase, .failed)
        XCTAssertTrue(engine.canStart)
    }
    func testAsyncReturnDoesNotPermitRetryBeforeConfirmedWorkerEnd() async {
        let engine = NSZImportEngine(), held = HeldNSZImportWorker()
        let work = Task { await engine.importFile(worker: held, id: held.id) }
        await held.waitUntilStarted(); held.finishCommitted(ended: false)
        while engine.phase != .stopping { await Task.yield() }
        XCTAssertFalse(engine.canStart)
        held.confirmEnd()
        _ = await work.value
        XCTAssertTrue(engine.canStart)
    }
    func testCancelledEarlyReturnKeepsMainActorResponsiveWhileWaitingForEnd() async {
        let engine = NSZImportEngine(), held = HeldNSZImportWorker()
        let work = Task { await engine.importFile(worker: held, id: held.id) }
        await held.waitUntilStarted(); held.finishCommitted(ended: false); work.cancel()
        while !held.cancelRequested { await Task.yield() }
        let heartbeat = await Task { @MainActor in true }.value
        XCTAssertTrue(heartbeat); XCTAssertFalse(engine.canStart)
        held.confirmEnd()
        let result = await work.value
        XCTAssertNil(result); XCTAssertTrue(engine.canStart)
    }
    func testAccessLeaseReleasesOnlyAcquiredScopeAndOnlyOnce() {
        var starts = 0, stops = 0
        let lease = NSZAccessLease(start: { starts += 1; return true }, stop: { stops += 1 })
        XCTAssertEqual(starts, 1); XCTAssertEqual(stops, 0)
        lease.release(); lease.release()
        XCTAssertEqual(stops, 1)
        let local = NSZAccessLease(start: { false }, stop: { stops += 100 })
        local.release(); XCTAssertEqual(stops, 1)
    }
    func testRoutingUsesCaseInsensitiveNSZAndExactPackageIdentity() {
        XCTAssertTrue(NSZImportRouting.isNSZ(extension: "NSZ"))
        XCTAssertFalse(NSZImportRouting.isNSZ(extension: "ncz"))
        XCTAssertTrue(NSZImportRouting.accepts(kind: 1, applicationID: 0xfedcba9876543210, expectedKind: 1, expectedApplicationID: 0xfedcba9876543210))
        XCTAssertFalse(NSZImportRouting.accepts(kind: 2, applicationID: 0x100, expectedKind: 1, expectedApplicationID: 0x100))
        XCTAssertFalse(NSZImportRouting.accepts(kind: 1, applicationID: 0x200, expectedKind: 1, expectedApplicationID: 0x100))
    }
    func testNativeHandleCannotBeBorrowedAfterFreeAndEarlyCancelIsRemembered() {
        let lifetime = NSZHandleLifetime()
        var cancellations = 0, frees = 0
        lifetime.cancel { _ in cancellations += 1 }
        XCTAssertEqual(cancellations, 0)
        XCTAssertTrue(lifetime.install(UnsafeMutableRawPointer(bitPattern: 1)!) { _ in cancellations += 1 })
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(lifetime.borrow { _ in 42 }, 42)
        lifetime.finish { _ in frees += 1 }
        XCTAssertNil(lifetime.borrow { _ in 42 })
        lifetime.cancel { _ in cancellations += 1 }
        lifetime.finish { _ in frees += 1 }
        XCTAssertEqual(frees, 1)
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(lifetime.install(UnsafeMutableRawPointer(bitPattern: 2)!) { _ in })
    }
}

@MainActor final class HeldNSZImportWorker: NSZImportWorker {
    var id = UUID()
    private(set) var hasEnded = false
    private(set) var started = false
    private(set) var cancelRequested = false
    private var continuation: CheckedContinuation<NSZImportedFile, Error>?
    func run() async throws -> NSZImportedFile {
        started = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func cancel() { cancelRequested = true }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func finishCommitted(ended: Bool = true) {
        hasEnded = ended
        continuation?.resume(returning: NSZImportedFile(operationID: id, path: "/owned/game.nsp", kind: 0, applicationID: 0x100))
        continuation = nil
    }
    func finishError() {
        hasEnded = true
        continuation?.resume(throwing: NSError(domain: "test", code: 1))
        continuation = nil
    }
    func confirmEnd() { hasEnded = true }
}

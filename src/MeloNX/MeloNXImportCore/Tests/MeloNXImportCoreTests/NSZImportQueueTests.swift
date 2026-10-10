import XCTest
@testable import MeloNXImportCore

@MainActor final class NSZImportQueueTests: XCTestCase {
    func testMultipleSelectedFilesRunInOrder() async {
        let queue = NSZImportQueue(), first = HeldNSZImportWorker(), second = HeldNSZImportWorker()
        let work = Task { await queue.importFiles(workers: [first, second], ids: [first.id, second.id]) }
        await first.waitUntilStarted()
        XCTAssertFalse(second.started); XCTAssertFalse(queue.canStart)
        first.finishCommitted(); await second.waitUntilStarted()
        XCTAssertFalse(queue.canStart)
        second.finishCommitted()
        let result = await work.value
        XCTAssertEqual(result?.map(\.operationID), [first.id, second.id])
        XCTAssertTrue(queue.canStart)
    }
    func testCancellingQueueDoesNotStartLaterItemsOrReleaseActiveWorker() async {
        let queue = NSZImportQueue(), first = HeldNSZImportWorker(), second = HeldNSZImportWorker()
        let work = Task { await queue.importFiles(workers: [first, second], ids: [first.id, second.id]) }
        await first.waitUntilStarted(); queue.cancel()
        XCTAssertTrue(first.cancelRequested); XCTAssertFalse(queue.canStart)
        first.finishCommitted()
        let result = await work.value
        XCTAssertNil(result); XCTAssertFalse(second.started); XCTAssertTrue(queue.canStart)
    }
    func testFirstErrorStopsQueueAndNeverRegistersCompletedResult() async {
        let queue = NSZImportQueue(), first = HeldNSZImportWorker(), second = HeldNSZImportWorker()
        let work = Task { await queue.importFiles(workers: [first, second], ids: [first.id, second.id]) }
        await first.waitUntilStarted(); first.finishError()
        let result = await work.value
        XCTAssertNil(result); XCTAssertFalse(second.started); XCTAssertNotNil(queue.engine.error)
    }
    func testValidationHasNoSuccessfulProgressBeforeWorkerEnds() async {
        let engine = NSZImportEngine(), held = HeldNSZImportWorker()
        let work = Task { await engine.importFile(worker: held, id: held.id) }
        await held.waitUntilStarted()
        engine.updateProgress(id: held.id, phase: .validating, completed: 100, total: 100)
        XCTAssertEqual(engine.phase, .validating); XCTAssertFalse(engine.canStart)
        held.finishError(); _ = await work.value
        XCTAssertEqual(engine.phase, .failed)
    }
    func testSuccessThenFailureKeepsAndRegistersFirstCompletedItem() async {
        let queue = NSZImportQueue(), first = HeldNSZImportWorker(), second = HeldNSZImportWorker()
        var registered: [UUID] = []
        queue.onImported = { registered.append($0.operationID) }
        let work = Task { await queue.importFiles(workers: [first, second], ids: [first.id, second.id]) }
        await first.waitUntilStarted(); first.finishCommitted(); await second.waitUntilStarted()
        XCTAssertEqual(registered, [first.id])
        second.finishError(); _ = await work.value
        XCTAssertEqual(queue.completedFiles.map(\.operationID), [first.id])
        XCTAssertEqual(registered, [first.id])
        XCTAssertNotNil(queue.error)
    }
    func testRegistrationFailureStopsFurtherWorkButRetainsCompletedPath() async {
        let queue = NSZImportQueue(), first = HeldNSZImportWorker(), second = HeldNSZImportWorker()
        queue.onImported = { _ in throw CocoaError(.fileWriteOutOfSpace) }
        let work = Task { await queue.importFiles(workers: [first, second], ids: [first.id, second.id]) }
        await first.waitUntilStarted(); first.finishCommitted(); _ = await work.value
        XCTAssertFalse(second.started)
        XCTAssertEqual(queue.completedFiles.map(\.path), ["/owned/game.nsp"])
        XCTAssertNotNil(queue.error)
    }
    func testUncompressedMultipleSelectionIsRejectedExplicitly() {
        XCTAssertTrue(NSZImportRouting.acceptsSelection(extensions: ["NSZ", "nsZ"]))
        XCTAssertTrue(NSZImportRouting.acceptsSelection(extensions: ["xci"]))
        XCTAssertFalse(NSZImportRouting.acceptsSelection(extensions: ["nsp", "xci"]))
        XCTAssertFalse(NSZImportRouting.acceptsSelection(extensions: ["nsp", "nsp"]))
    }
    func testLateCancelReportsRetainedPathWithoutRegisteringIt() async {
        let queue = NSZImportQueue(), held = HeldNSZImportWorker()
        var registrations = 0; queue.onImported = { _ in registrations += 1 }
        let work = Task { await queue.importFiles(workers: [held], ids: [held.id]) }
        await held.waitUntilStarted(); held.finishCancelled(path: "/owned/retained.nsp")
        _ = await work.value
        XCTAssertEqual(registrations, 0)
        XCTAssertEqual((queue.error as? NSZImportCancellation)?.retainedPath, "/owned/retained.nsp")
        XCTAssertEqual(queue.engine.phase, .cancelled)
    }
}

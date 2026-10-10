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
}

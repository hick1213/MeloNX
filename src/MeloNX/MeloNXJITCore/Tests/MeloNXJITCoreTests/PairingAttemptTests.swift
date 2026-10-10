import XCTest
@testable import MeloNXJITCore

final class PairingAttemptTests: XCTestCase {
    func testOldCallbackDoesNotOwnRetry() throws {
        var attempt = PairingAttemptState()
        let old = try attempt.begin()
        XCTAssertTrue(attempt.ownsCallback(id: old))
        _ = attempt.finish(id: old)
        let retry = try attempt.begin()
        XCTAssertFalse(attempt.ownsCallback(id: old))
        XCTAssertTrue(attempt.ownsCallback(id: retry))
    }

    func testCancelledAcceptCannotStoreAndBlocksNewSessionUntilReturned() throws {
        var attempt = PairingAttemptState()
        let id = try attempt.begin()
        attempt.cancel(id: id)
        XCTAssertThrowsError(try attempt.begin())
        XCTAssertFalse(attempt.finish(id: id))
        let next = try attempt.begin()
        XCTAssertFalse(attempt.finish(id: id))
        XCTAssertEqual(attempt.activeID, next)
        XCTAssertTrue(attempt.finish(id: next))
    }
}

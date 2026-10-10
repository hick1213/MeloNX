import XCTest
@testable import MeloNXJITCore

final class JITSessionStateTests: XCTestCase {
    func testCancelledMappingCannotLaunchOrRetryBeforeTeardown() throws {
        var state = JITSessionState()
        let id = try state.begin(pid: 123, launchID: UUID())
        XCTAssertTrue(state.transition(id: id, to: .mapping))
        state.cancel(id: id)
        state.complete(id: id, mapped: true, helperEnded: false, tracing: true)
        XCTAssertEqual(state.phase, .stopping)
        XCTAssertNil(state.allowedLaunchID)
        XCTAssertFalse(state.canRetry)
        state.complete(id: id, mapped: true, helperEnded: true, tracing: false)
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertTrue(state.canRetry)
        XCTAssertNil(state.allowedLaunchID)
    }

    func testReadyRequiresMappingHelperCompletionAndConfirmedDetach() throws {
        var state = JITSessionState()
        let launch = UUID()
        let id = try state.begin(pid: 123, launchID: launch)
        state.complete(id: id, mapped: true, helperEnded: true, tracing: nil)
        XCTAssertNotEqual(state.phase, .ready)
        XCTAssertFalse(state.canRetry)
        state.complete(id: id, mapped: true, helperEnded: true, tracing: true)
        XCTAssertNotEqual(state.phase, .ready)
        state.complete(id: id, mapped: true, helperEnded: true, tracing: false)
        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.allowedLaunchID, launch)
    }

    func testOldCompletionCannotAffectNextLaunch() throws {
        var state = JITSessionState()
        let old = try state.begin(pid: 123, launchID: UUID())
        state.cancel(id: old)
        state.complete(id: old, mapped: false, helperEnded: true, tracing: false)
        let launch = UUID()
        let current = try state.begin(pid: 123, launchID: launch)
        state.complete(id: old, mapped: true, helperEnded: true, tracing: false)
        XCTAssertEqual(state.activeID, current)
        XCTAssertNil(state.allowedLaunchID)
        XCTAssertFalse(state.transition(id: old, to: .ready))
    }

    func testDuplicateAndInvalidPIDAreRejected() throws {
        var state = JITSessionState()
        XCTAssertThrowsError(try state.begin(pid: 0, launchID: nil))
        XCTAssertThrowsError(try state.begin(pid: -1, launchID: nil))
        _ = try state.begin(pid: 123, launchID: nil)
        XCTAssertThrowsError(try state.begin(pid: 123, launchID: nil))
    }

    func testFailedMappingAllowsRetryOnlyAfterConfirmedTeardown() throws {
        var state = JITSessionState()
        let id = try state.begin(pid: 123, launchID: UUID())
        state.complete(id: id, mapped: false, helperEnded: false, tracing: false)
        XCTAssertEqual(state.phase, .stopping)
        XCTAssertFalse(state.canRetry)
        state.complete(id: id, mapped: false, helperEnded: true, tracing: false)
        XCTAssertEqual(state.phase, .failed)
        XCTAssertTrue(state.canRetry)
        XCTAssertNil(state.allowedLaunchID)
    }
}

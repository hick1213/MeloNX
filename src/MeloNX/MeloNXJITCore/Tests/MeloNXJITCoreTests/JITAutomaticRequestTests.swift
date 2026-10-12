import XCTest
@testable import MeloNXJITCore

@MainActor final class JITAutomaticRequestTests: XCTestCase {
    func testStartupAndForegroundShareOneAcquisition() async {
        let request = JITAutomaticRequest()
        var calls = 0
        var release: CheckedContinuation<Bool, Never>?
        let startup = Task { await request.run {
            calls += 1
            return await withCheckedContinuation { release = $0 }
        } }
        while release == nil { await Task.yield() }
        let foreground = Task { await request.run { calls += 1; return false } }
        let game = Task { await request.waitForCurrent() }
        await Task.yield()
        XCTAssertTrue(request.isRunning)
        release?.resume(returning: true)
        let results = await (startup.value, foreground.value, game.value)
        XCTAssertTrue(results.0); XCTAssertTrue(results.1); XCTAssertTrue(results.2)
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(request.isRunning)
    }

    func testFailureCanRetryOnNextExplicitLifecycleEvent() async {
        let request = JITAutomaticRequest()
        let first = await request.run { false }
        XCTAssertFalse(first)
        XCTAssertFalse(request.isRunning)
        let second = await request.run { true }
        XCTAssertTrue(second)
    }

    func testCancelledWaiterDoesNotInterruptSharedAcquisition() async {
        let request = JITAutomaticRequest()
        var gameStarts = 0
        var release: CheckedContinuation<Bool, Never>?
        let startup = Task { await request.run { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        let waiter = Task {
            _ = await request.waitForCurrent()
            if !Task.isCancelled { gameStarts += 1 }
        }
        waiter.cancel()
        release?.resume(returning: true)
        let ready = await startup.value
        _ = await waiter.value
        XCTAssertTrue(ready)
        XCTAssertFalse(request.isRunning)
        XCTAssertEqual(gameStarts, 0)
    }
}

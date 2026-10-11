import XCTest
@testable import MeloNXOperationCore

final class GameExecutionLifetimeTests: XCTestCase {
    @MainActor func testExitKeepsLaunchBlockedUntilNativeWorkerReturns() throws {
        var lifetime = GameExecutionLifetime()
        let gate = LocalOperationGate(), game: UInt64 = 0x100
        let lease = try gate.acquire(.launch, gameID: game)
        XCTAssertTrue(lifetime.begin())
        XCTAssertTrue(lifetime.requestStop())
        XCTAssertFalse(lifetime.begin())
        XCTAssertThrowsError(try lease.finish(workerHasEnded: !lifetime.nativeActive))
        XCTAssertFalse(gate.canAcquire(.launch, gameID: game))
        lifetime.workerEnded()
        try lease.finish(workerHasEnded: !lifetime.nativeActive)
        XCTAssertTrue(gate.canAcquire(.launch, gameID: game))
        XCTAssertTrue(lifetime.begin())
    }
    func testRepeatedStopIsIdempotentAndIdleDoesNotBecomeStopping() {
        var lifetime = GameExecutionLifetime()
        XCTAssertFalse(lifetime.requestStop())
        XCTAssertTrue(lifetime.begin())
        XCTAssertTrue(lifetime.requestStop())
        XCTAssertFalse(lifetime.requestStop())
        XCTAssertTrue(lifetime.isStopping)
        lifetime.workerEnded()
        XCTAssertFalse(lifetime.isStopping)
    }
}

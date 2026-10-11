import XCTest
import MeloNXOperationCore
@testable import MeloNXSaveSyncCore

final class SaveWorkerLifetimeTests: XCTestCase {
    func testStopBeforeInstallationIsDeliveredAndEndedHandleCannotBeBorrowed() throws {
        let lifetime = SaveHandleLifetime()
        let pointer = UnsafeMutableRawPointer(bitPattern: 42)!
        var stops = 0, frees = 0
        lifetime.requestStop { _ in stops += 1 }
        XCTAssertTrue(lifetime.install(pointer) { _ in stops += 1 })
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(lifetime.hasEnded)
        XCTAssertEqual(lifetime.borrow { $0 }, pointer)
        lifetime.finish { _ in frees += 1 }
        lifetime.finish { _ in frees += 1 }
        XCTAssertEqual(frees, 1)
        XCTAssertTrue(lifetime.hasEnded)
        XCTAssertNil(lifetime.borrow { $0 })
        XCTAssertFalse(lifetime.install(pointer) { _ in stops += 1 })
    }

    func testFinishingWaitsForActualBorrower() {
        let lifetime = SaveHandleLifetime(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        XCTAssertTrue(lifetime.install(UnsafeMutableRawPointer(bitPattern: 43)!) { _ in })
        DispatchQueue.global().async {
            _ = lifetime.borrow { _ in entered.signal(); XCTAssertEqual(release.wait(timeout: .now() + 5), .success) }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async { lifetime.finish { _ in }; finished.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
    }

    @MainActor func testBootstrapBlocksAllEntryPointsAndKeepsBarrierOnFailure() async {
        let gate = LocalOperationGate()
        let bootstrap = SaveRecoveryBarrier(gate: gate)
        XCTAssertFalse(gate.canAcquire(.launch, gameID: 1))
        let ok = await bootstrap.run { throw SaveSyncError.restoreFailed }
        XCTAssertFalse(ok)
        XCTAssertFalse(gate.canAcquire(.packageImport, gameID: nil))
        XCTAssertFalse(gate.canAcquire(.launch, gameID: nil))
        XCTAssertFalse(gate.busy)
        let retry = await bootstrap.run { [2] }
        XCTAssertTrue(retry)
        XCTAssertTrue(gate.canAcquire(.launch, gameID: 1))
        XCTAssertFalse(gate.canAcquire(.launch, gameID: 2))
    }
}

import XCTest
@testable import MeloNXSaveSyncCore

final class SaveSyncPresentationTests: XCTestCase {
    func testActiveAndSafeFinishingDoNotExposeRetry() {
        for phase in [SaveSyncPhase.exporting, .publishing, .listing, .downloading, .validating, .restoring, .finishing] {
            XCTAssertFalse(SaveSyncPresentation(phase: phase, error: nil).canRetry)
        }
        XCTAssertTrue(SaveSyncPresentation(phase: .queued, error: .queued).canRetry)
        XCTAssertTrue(SaveSyncPresentation(phase: .recoveryRequired, error: .rollbackRequired).canRetry)
    }
    func testConflictRequiresChoiceButUniqueReadySaveDoesNot() {
        XCTAssertTrue(SaveSyncPresentation(phase: .awaitingRestoreConfirmation, error: .conflict).showsVersionChoice)
        XCTAssertFalse(SaveSyncPresentation(phase: .awaitingRestoreConfirmation, error: nil).showsVersionChoice)
        XCTAssertFalse(SaveSyncPresentation(phase: .finishing, error: .conflict).showsVersionChoice)
    }
}

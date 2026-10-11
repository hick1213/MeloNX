import XCTest
@testable import MeloNXSaveSyncCore

final class SaveUserBindingsTests: XCTestCase {
    func testCompletedIntentRepairsOriginalAccountIdempotently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = UUID(), other = UUID(), transaction = UUID(), generation = UUID()
        let uid = String(repeating: "a", count: 32), cloud = String(repeating: "b", count: 32)
        let intent = SaveBindingIntent(accountKey: account, container: "iCloud.test", titleID: 1, localUID: uid, cloudUID: cloud, generation: generation)
        let bindings = SaveUserBindings(root: root)
        try bindings.applyCompleted(intent: intent, transactionID: transaction)
        let reopened = SaveUserBindings(root: root)
        try reopened.applyCompleted(intent: intent, transactionID: transaction)
        let key = SaveBindingKey(localCloudAccountUUID: account, container: "iCloud.test", titleID: 1, localUID: uid)
        XCTAssertEqual(try reopened.read(key: key), SaveBinding(cloudUID: cloud, lastGeneration: generation))
        XCTAssertNil(try reopened.read(key: SaveBindingKey(localCloudAccountUUID: other, container: "iCloud.test", titleID: 1, localUID: uid)))
        // An already applied transaction cannot overwrite a later successful upload.
        let later = UUID()
        try reopened.recordUploaded(key: key, cloudUID: cloud, generation: later)
        try reopened.applyCompleted(intent: intent, transactionID: transaction)
        XCTAssertEqual(try reopened.read(key: key)?.lastGeneration, later)
    }
    func testFailedDurableWriteDoesNotAcknowledgeOrChangeExistingBinding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = String(repeating: "a", count: 32), cloud = String(repeating: "b", count: 32)
        let key = SaveBindingKey(localCloudAccountUUID: UUID(), container: "iCloud.test", titleID: 1, localUID: uid)
        let old = UUID(), new = UUID(), transaction = UUID()
        try SaveUserBindings(root: root).recordUploaded(key: key, cloudUID: uid, generation: old)
        let failing = SaveUserBindings(root: root, write: { _, _ in throw SaveSyncError.restoreFailed })
        let intent = SaveBindingIntent(accountKey: key.localCloudAccountUUID, container: key.container, titleID: 1, localUID: uid, cloudUID: cloud, generation: new)
        XCTAssertThrowsError(try failing.applyCompleted(intent: intent, transactionID: transaction))
        XCTAssertEqual(try SaveUserBindings(root: root).read(key: key)?.lastGeneration, old)
        try SaveUserBindings(root: root).applyCompleted(intent: intent, transactionID: transaction)
        XCTAssertEqual(try SaveUserBindings(root: root).read(key: key)?.lastGeneration, new)
    }
}

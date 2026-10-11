import XCTest
@testable import MeloNXSaveSyncCore

final class SaveQueuedUploadTests: XCTestCase {
    func testAcknowledgedMarkerCannotReapplyOldParentAfterAnotherCompletedBinding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("save-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = UUID(), key = SaveBindingKey(localCloudAccountUUID: UUID(), container: "iCloud.test", titleID: 0x100, localUID: fixtureUID)
        let stage = SaveQueuedUpload.root(root, generation: generation)
        let snapshot = try writeSaveFixture(root: stage, generation: generation, owner: fixtureUID)
        let marker = SaveQueuedUpload(version: 1, key: key, snapshot: snapshot)
        try marker.persist(ownedRoot: root)
        try marker.acknowledge(ownedRoot: root)
        let later = SaveBinding(cloudUID: fixtureUID, lastGeneration: UUID())
        XCTAssertNil(try SaveQueuedUpload.load(ownedRoot: root, key: key, binding: later))
    }
}

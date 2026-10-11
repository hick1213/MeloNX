import XCTest
@testable import MeloNXSaveSyncCore

final class SaveDownloadStagingTests: XCTestCase {
    func testCancelledOrFullDiskDownloadCanRetrySameGeneration() async throws {
        for failure in [CancellationError() as Error, NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-retry-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let generation = UUID(), original = root.appendingPathComponent("source")
            let snapshot = try writeSaveFixture(root: original, generation: generation, owner: fixtureUID)
            let final = SaveQueuedUpload.root(root, generation: generation)
            // The prior implementation could leave a partial final directory.
            try FileManager.default.createDirectory(at: final.appendingPathComponent("partial"), withIntermediateDirectories: true)
            do {
                try await SaveDownloadStaging.download(destination: final, snapshot: snapshot) { working in
                    try FileManager.default.createDirectory(at: working.appendingPathComponent("first-record"), withIntermediateDirectories: true)
                    throw failure
                }
                XCTFail("Interrupted download succeeded")
            } catch { }
            try await SaveDownloadStaging.download(destination: final, snapshot: snapshot) { working in
                _ = try writeSaveFixture(root: working, generation: generation, owner: snapshot.ownerUserID, installation: snapshot.installationID)
            }
            _ = try SnapshotLocalVerifier.verify(root: final, snapshot: snapshot)
        }
    }
    func testReferencedUploadStagingIsNeverRemovedToRepairDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-protected-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try writeSaveFixture(root: root.appendingPathComponent("source"), generation: UUID(), owner: fixtureUID)
        let final = SaveQueuedUpload.root(root, generation: snapshot.generation)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        let receipt = final.appendingPathComponent("queued-upload.json")
        try Data([1]).write(to: receipt)
        do {
            try await SaveDownloadStaging.download(destination: final, snapshot: snapshot) { _ in XCTFail("Protected staging was rewritten") }
            XCTFail("Malformed referenced staging was accepted")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: receipt), Data([1]))
    }
}

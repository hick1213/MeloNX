import XCTest
@testable import MeloNXSaveSyncCore

final class CloudStoreTests: XCTestCase {
    func testManifestArrivalAndLocalPublicationDoNotConfirmWholeUpload() throws {
        let identity = CloudIdentity(localAccountKey: UUID(), container: "iCloud.test")
        let confirmation = CloudTransferConfirmation(identity: identity, requiredFiles: ["game.json", "record.json", "payload.bin"])
        var states: [String: CloudFileState] = [:]
        XCTAssertFalse(try confirmation.confirm(current: identity, states: states, direction: .upload))
        states["game.json"] = CloudFileState(uploaded: true, downloaded: true)
        states["record.json"] = CloudFileState(uploaded: true, downloaded: true)
        states["payload.bin"] = CloudFileState(uploaded: false, downloaded: true)
        XCTAssertFalse(try confirmation.confirm(current: identity, states: states, direction: .upload))
        states["payload.bin"] = CloudFileState(uploaded: true, downloaded: true)
        XCTAssertTrue(try confirmation.confirm(current: identity, states: states, direction: .upload))
    }
    func testChangedIdentityQuotaAndConflictCannotBecomeSuccess() throws {
        let identity = CloudIdentity(localAccountKey: UUID(), container: "iCloud.test")
        let confirmation = CloudTransferConfirmation(identity: identity, requiredFiles: ["file"])
        let uploaded = CloudFileState(uploaded: true, downloaded: true)
        XCTAssertThrowsError(try confirmation.confirm(current: CloudIdentity(localAccountKey: UUID(), container: identity.container), states: ["file": uploaded], direction: .upload))
        XCTAssertThrowsError(try confirmation.confirm(current: identity, states: ["file": CloudFileState(uploaded: true, downloaded: true, conflicted: true)], direction: .upload))
        XCTAssertThrowsError(try confirmation.confirm(current: identity, states: ["file": CloudFileState(uploaded: false, downloaded: true, error: .quota)], direction: .upload))
        XCTAssertFalse(try confirmation.confirm(current: identity, states: ["file": CloudFileState(uploaded: true, downloaded: false)], direction: .download))
    }
    func testDownloadedSnapshotChecksActualHashLengthAndEmptyDirectories() throws {
        let source = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: source, to: root)
        let snapshot = try SnapshotValidation.decodeSnapshot(Data(contentsOf: root.appendingPathComponent("snapshot.json")))
        let device = snapshot.records.first { $0.key.type == .device }!
        let payload = root.appendingPathComponent(device.manifestRelativePath).deletingLastPathComponent().appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload.appendingPathComponent("empty/sub"), withIntermediateDirectories: true)
        let account = snapshot.records.first { $0.key.type == .account }!
        let accountPayload = root.appendingPathComponent(account.manifestRelativePath).deletingLastPathComponent().appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: accountPayload.appendingPathComponent("empty/sub"), withIntermediateDirectories: true)
        let gameManifest = root.appendingPathComponent(SnapshotPaths.gameManifest(titleID: snapshot.titleID, generation: snapshot.generation))
        try FileManager.default.createDirectory(at: gameManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SnapshotValidation.encode(snapshot).write(to: gameManifest)
        let files = try SnapshotLocalVerifier.verify(root: root, snapshot: snapshot)
        XCTAssertTrue(files.contains(SnapshotPaths.gameManifest(titleID: snapshot.titleID, generation: snapshot.generation)))
        let save = accountPayload.appendingPathComponent("progress.bin")
        let original = try Data(contentsOf: save)
        try Data(repeating: 1, count: original.count).write(to: save)
        XCTAssertThrowsError(try SnapshotLocalVerifier.verify(root: root, snapshot: snapshot))
        try (original + Data([1])).write(to: save)
        XCTAssertThrowsError(try SnapshotLocalVerifier.verify(root: root, snapshot: snapshot))
        try original.write(to: save)
        let unlisted = accountPayload.appendingPathComponent("unlisted.bin")
        try Data([2]).write(to: unlisted)
        XCTAssertThrowsError(try SnapshotLocalVerifier.verify(root: root, snapshot: snapshot))
        try FileManager.default.removeItem(at: unlisted)
        try FileManager.default.removeItem(at: save)
        try FileManager.default.createSymbolicLink(at: save, withDestinationURL: root.appendingPathComponent("snapshot.json"))
        XCTAssertThrowsError(try SnapshotLocalVerifier.verify(root: root, snapshot: snapshot))
        try FileManager.default.removeItem(at: save)
        try original.write(to: save)
        try FileManager.default.removeItem(at: payload.appendingPathComponent("empty/sub"))
        XCTAssertThrowsError(try SnapshotLocalVerifier.verify(root: root, snapshot: snapshot))
    }
    func testDuplicateManifestKeysAndExcessiveDepthAreRejected() throws {
        let url = Bundle.module.url(forResource: "snapshot", withExtension: "json", subdirectory: "Fixtures")!
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertThrowsError(try SnapshotValidation.decodeSnapshot(Data(text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1").utf8)))
        let nested = String(repeating: "{\"a\":", count: 65) + "0" + String(repeating: "}", count: 65)
        let deep = text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"ignored\":\(nested),\"schemaVersion\":1")
        XCTAssertThrowsError(try SnapshotValidation.decodeSnapshot(Data(deep.utf8)))
    }
}
